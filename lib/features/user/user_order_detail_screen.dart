import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/review_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/order_chat_service.dart';
import '../../core/utils/order_number_format.dart';
import '../../core/utils/friendly_error.dart';

/// Statuses from which CANCELLED is a legal transition
/// (see transition_order_status whitelist in 0003_functions.sql).
const _cancellableStatuses = {
  'CREATED',
  'PENDING_PROVIDER',
  'ACCEPTED',
  'PAYMENT_PENDING',
  'APPROVED',
  'STARTED',
};

/// Shared status → color mapping for order UIs.
Color orderStatusColor(String status) {
  switch (status) {
    case 'COMPLETED':
    case 'REFUNDED':
      return AppTheme.success;
    case 'CANCELLED':
    case 'REJECTED':
      return AppTheme.error;
    case 'DISPUTED':
      return AppTheme.gold;
    case 'CREATED':
    case 'PENDING_PROVIDER':
    case 'PAYMENT_PENDING':
    case 'PAYMENT_VERIFICATION':
      return AppTheme.gold;
    default: // ACCEPTED, APPROVED, STARTED
      return AppTheme.teal;
  }
}

/// Shared order detail view. `viewerRole` is 'user' (default) or 'provider' —
/// it controls which action buttons are offered. All status changes go
/// through the existing order-transition Edge Function.
class UserOrderDetailScreen extends ConsumerStatefulWidget {
  final String orderId;
  final String viewerRole;
  const UserOrderDetailScreen({
    super.key,
    required this.orderId,
    this.viewerRole = 'user',
  });
  @override
  ConsumerState<UserOrderDetailScreen> createState() =>
      _UserOrderDetailScreenState();
}

class _UserOrderDetailScreenState
    extends ConsumerState<UserOrderDetailScreen> {
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _timeline = [];
  Map<String, String> _actorNames = {};
  String? _proofUrl;
  bool _reviewed = false;
  bool _loading = true;
  bool _acting = false;
  String? _error;

  // Escrow-gated live location (buyer share / provider directions).
  geo.Position? _myPos;
  bool _locSharing = false;
  bool _directionsLaunching = false;

  // In-order chat (buyer ↔ provider).
  final _chatCtrl = TextEditingController();
  bool _sendingChat = false;

  @override
  void dispose() {
    _chatCtrl.dispose();
    super.dispose();
  }

  bool get _isProvider => widget.viewerRole == 'provider';

  @override
  void initState() {
    super.initState();
    _load();
    if (_isProvider) _primeProviderGps();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final order = await client
          .from('orders')
          .select(
              '*, provider_profiles(business_name), order_items(product_id, quantity, unit_price, subtotal, products(name, price, currency))')
          .eq('id', widget.orderId)
          .single();
      final timeline = await client
          .from('order_status_history')
          .select('*')
          .eq('order_id', widget.orderId)
          .order('created_at', ascending: true);

      // Resolve actor names (best-effort; timeline still shows without them).
      final names = <String, String>{};
      try {
        final actorIds = (timeline as List)
            .map((t) => t['changed_by'] as String?)
            .whereType<String>()
            .toSet()
            .toList();
        if (actorIds.isNotEmpty) {
          final profiles = await client
              .from('profiles')
              .select('id, full_name')
              .inFilter('id', actorIds);
          for (final p in profiles as List) {
            names[p['id'] as String] = p['full_name'] as String? ?? '';
          }
        }
      } catch (_) {}

      String? proofUrl;
      final proof = await client
          .from('payment_proofs')
          .select('storage_path')
          .eq('order_id', widget.orderId)
          .maybeSingle();
      if (proof != null && proof['storage_path'] != null) {
        proofUrl = await client.storage
            .from('payment-proofs')
            .createSignedUrl(proof['storage_path'] as String, 3600);
      }

      // Whether the current user already reviewed this order (best-effort).
      var reviewed = false;
      try {
        reviewed = await ReviewService.instance
            .hasUserReviewedOrder(widget.orderId);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _order = order;
          _timeline = List<Map<String, dynamic>>.from(timeline as List);
          _actorNames = names;
          _proofUrl = proofUrl;
          _reviewed = reviewed;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load order';
        });
      }
    }
  }

  bool get _canCancel {
    final status = _order?['status'] as String?;
    return status != null && _cancellableStatuses.contains(status);
  }

  /// In-order chat: text coordination any time, location sharing gated by
  /// the same escrow reveal window as the GPS card above (enforced both
  /// client-side for messaging and server-side in migration 0036).
  Widget _chatCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.forum_outlined,
                    size: 18, color: AppTheme.teal),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Order Chat',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                ),
                if (!_deliveryRevealed)
                  const Text('Location sharing after payment verified',
                      style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
              ],
            ),
          ),
          SizedBox(
            height: 300,
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: OrderChatService.instance.streamMessages(widget.orderId),
              builder: (context, snap) {
                // A realtime subscribe failure is not a data error. Show it
                // inline and keep whatever was already loaded rather than
                // pretending the conversation is empty.
                if (snap.hasError && !snap.hasData) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Chat is reconnecting… messages will reappear shortly.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                    ),
                  );
                }
                final msgs = (snap.data ?? const [])
                    .map(OrderChatMessage.fromRow)
                    .toList();
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text(
                        'No messages yet — say hello or ask about this order.',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  );
                }
                final myId =
                    Supabase.instance.client.auth.currentUser?.id;
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: msgs.length,
                  itemBuilder: (_, i) => _chatBubble(msgs[i], mine: msgs[i].senderId == myId),
                );
              },
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Share live location',
                    onPressed: _sendingChat ? null : _shareChatLocation,
                    icon: const Icon(Icons.share_location_outlined,
                        color: AppTheme.teal),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _chatCtrl,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendChatText(),
                      decoration: const InputDecoration(
                        hintText: 'Message…',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _sendingChat ? null : _sendChatText,
                    icon: _sendingChat
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send, size: 18),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chatBubble(OrderChatMessage m, {required bool mine}) {
    final align = mine ? Alignment.centerRight : Alignment.centerLeft;
    final who = mine ? 'You' : (_isProvider ? 'Buyer' : 'Provider');
    final time =
        '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Align(
        alignment: align,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7),
          decoration: BoxDecoration(
            color: m.isLocation
                ? AppTheme.teal.withOpacity(0.08)
                : (mine
                    ? AppTheme.primaryGreen.withOpacity(0.08)
                    : AppTheme.creamDark),
            borderRadius: BorderRadius.circular(12),
            border: m.isLocation
                ? Border.all(color: AppTheme.teal.withOpacity(0.4))
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$who · $time',
                  style: const TextStyle(
                      fontSize: 10, color: AppTheme.textMuted)),
              const SizedBox(height: 4),
              if (m.isLocation)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.location_on_outlined,
                            size: 16, color: AppTheme.teal),
                        SizedBox(width: 4),
                        Text('Live location shared',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary)),
                      ],
                    ),
                    if (m.locationLabel != null &&
                        m.locationLabel!.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(m.locationLabel!,
                            style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textSecondary)),
                      ),
                    TextButton.icon(
                      onPressed: (m.lat == null || m.lng == null)
                          ? null
                          : () => LocationService.instance.openDirectionsTo(
                                destLat: m.lat!,
                                destLng: m.lng!,
                                label: m.locationLabel ?? 'Shared location',
                              ),
                      icon: const Icon(Icons.navigation_outlined, size: 16),
                      label: const Text('Get directions',
                          style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                          foregroundColor: AppTheme.teal,
                          padding: const EdgeInsets.symmetric(horizontal: 4)),
                    ),
                  ],
                )
              else
                SelectableText(m.body ?? '',
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textPrimary)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _sendChatText() async {
    final text = _chatCtrl.text.trim();
    if (text.isEmpty || _sendingChat) return;
    setState(() => _sendingChat = true);
    try {
      await OrderChatService.instance
          .sendText(orderId: widget.orderId, body: text);
      _chatCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not send your message'))));
      }
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  /// One-shot live GPS share into the chat. Server-side gate (0036)
  /// enforces the escrow reveal window; mirror the error here.
  Future<void> _shareChatLocation() async {
    setState(() => _sendingChat = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!r.success) {
      if (mounted) {
        setState(() => _sendingChat = false);
        final openSettings = r.status == LocationStatus.deniedForever ||
            r.status == LocationStatus.serviceDisabled;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(openSettings
              ? 'Enable location services to share your location'
              : 'Location permission is needed to share your location'),
          action: openSettings
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: () =>
                      LocationService.instance.openLocationSettings())
              : null,
        ));
      }
      return;
    }
    try {
      await OrderChatService.instance.sendLocation(
        orderId: widget.orderId,
        lat: r.position!.latitude,
        lng: r.position!.longitude,
      );
    } on LocationNotRevealedException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location sharing unlocks once the payment is verified.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not share your location'))));
      }
    } finally {
      if (mounted) setState(() => _sendingChat = false);
    }
  }

  /// Escrow reveal window: payment verified (APPROVED) or delivery in
  /// progress (STARTED) — the same statuses the DB gate (0032) enforces.
  bool get _deliveryRevealed {
    final status = _order?['status'] as String?;
    return status == 'APPROVED' || status == 'STARTED';
  }

  /// Buyer side: grab a fresh live GPS fix and share it for this order.
  Future<void> _shareMyLocation() async {
    setState(() => _locSharing = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!r.success) {
      if (mounted) {
        setState(() => _locSharing = false);
        final openSettings = r.status == LocationStatus.deniedForever ||
            r.status == LocationStatus.serviceDisabled;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(openSettings
              ? 'Enable location services to share your delivery point'
              : 'Location permission is needed to share your delivery point'),
          action: openSettings
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: () =>
                      LocationService.instance.openLocationSettings())
              : null,
        ));
      }
      return;
    }
    try {
      await Supabase.instance.client.rpc('set_order_delivery_location', params: {
        'p_order_id': widget.orderId,
        'p_lat': r.position!.latitude,
        'p_lng': r.position!.longitude,
      });
      if (mounted) {
        setState(() {
          _myPos = r.position;
          _locSharing = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Live location shared with the provider')));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _locSharing = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not share your location'))));
      }
    }
  }

  /// Provider side: fetch the buyer-shared GPS point (only exists after the
  /// buyer shared it post-approval) and launch directions to it.
  Future<void> _openBuyerDirections() async {
    setState(() => _directionsLaunching = true);
    try {
      final data = await Supabase.instance.client
          .rpc('get_order_delivery_location', params: {'p_order_id': widget.orderId});
      final rows = (data as List?) ?? const [];
      if (!mounted) return;
      if (rows.isEmpty || rows.first['lat'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Buyer has not shared their live location yet — ask them to tap "Share live location" on the order')));
        return;
      }
      final lat = (rows.first['lat'] as num).toDouble();
      final lng = (rows.first['lng'] as num).toDouble();
      final pos = _myPos;
      await LocationService.instance.openDirectionsTo(
        destLat: lat,
        destLng: lng,
        label: 'Delivery location',
        originLat: pos?.latitude,
        originLng: pos?.longitude,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not get your location'))));
      }
    } finally {
      if (mounted) setState(() => _directionsLaunching = false);
    }
  }

  /// Provider side: directions to their own business location pickup.
  Future<void> _openBusinessDirections() async {
    final providerId = _order?['provider_id'] as String?;
    if (providerId == null) return;
    setState(() => _directionsLaunching = true);
    try {
      final data = await Supabase.instance.client.rpc(
          'get_provider_public_location',
          params: {'p_provider_id': providerId});
      final rows = (data as List?) ?? const [];
      if (!mounted) return;
      if (rows.isEmpty || rows.first['lat'] == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No business location set — add it in the business profile')));
        return;
      }
      final lat = (rows.first['lat'] as num).toDouble();
      final lng = (rows.first['lng'] as num).toDouble();
      final label = (rows.first['address_text'] as String?) ?? 'Business location';
      final pos = _myPos;
      await LocationService.instance.openDirectionsTo(
        destLat: lat,
        destLng: lng,
        label: label,
        originLat: pos?.latitude,
        originLng: pos?.longitude,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not get your location'))));
      }
    } finally {
      if (mounted) setState(() => _directionsLaunching = false);
    }
  }

  /// Provider side: prime own live GPS so routes start from the real position.
  Future<void> _primeProviderGps() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (mounted && r.success) setState(() => _myPos = r.position);
  }

  /// Provider status actions allowed by the transition whitelist.
  List<({String status, String label, IconData icon})>
      get _providerActions {
    final status = _order?['status'] as String?;
    switch (status) {
      case 'PENDING_PROVIDER':
        return [
          (
            status: 'ACCEPTED',
            label: 'Accept Order',
            icon: Icons.check_circle_outline,
          ),
          (
            status: 'REJECTED',
            label: 'Reject',
            icon: Icons.cancel_outlined,
          ),
        ];
      case 'ACCEPTED':
        return [
          (
            status: 'PAYMENT_PENDING',
            label: 'Request Payment',
            icon: Icons.payment,
          ),
        ];
      case 'APPROVED':
        return [
          (
            status: 'STARTED',
            label: 'Mark In Progress',
            icon: Icons.play_circle_outline,
          ),
        ];
      case 'STARTED':
        return [
          (
            status: 'COMPLETED',
            label: 'Mark Completed',
            icon: Icons.flag_outlined,
          ),
        ];
      default:
        return [];
    }
  }

  Future<void> _cancelOrder() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Cancel order?'),
        content: const Text(
            'This will cancel the order. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => dctx.pop(false),
              child: const Text('KEEP ORDER')),
          TextButton(
              onPressed: () => dctx.pop(true),
              child: const Text('CANCEL ORDER')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _transition('CANCELLED', note: 'Cancelled by customer');
  }

  Future<void> _transition(String newStatus, {String? note}) async {
    setState(() => _acting = true);
    try {
      await Supabase.instance.client.functions.invoke('order-transition',
          body: {
            'order_id': widget.orderId,
            'new_status': newStatus,
            if (note != null) 'note': note,
          });
      if (!mounted) return;
      setState(() => _acting = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Order ${_label(newStatus)}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting = false);
      // This used to show the exception verbatim after stripping only the
      // FunctionException prefix, so a PostgREST error surfaced here in full.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              friendlyError(e, context: 'Could not complete that action'))));
    }
  }

  String _label(String status) => status.replaceAll('_', ' ');

  /// First product id in the order, used to target a product review.
  String? get _firstProductId {
    final items = (_order?['order_items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    return (items.first as Map<String, dynamic>)['product_id'] as String?;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order Details')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: AppTheme.textMuted),
                      const SizedBox(height: 12),
                      Text(_error!,
                          style:
                              const TextStyle(color: AppTheme.textMuted)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _headerCard(),
                        const SizedBox(height: 16),
                        if (_deliveryRevealed) ...[
                          _locationCard(),
                          const SizedBox(height: 16),
                        ],
                        _itemsCard(),
                        const SizedBox(height: 16),
                        if (_proofUrl != null) _proofCard(),
                        if (_proofUrl != null) const SizedBox(height: 16),
                        _chatCard(),
                        const SizedBox(height: 16),
                        _timelineCard(),
                        const SizedBox(height: 20),
                        if (_isProvider && _providerActions.isNotEmpty)
                          ..._providerActions.map((a) => Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: a.status == 'REJECTED'
                                      ? OutlinedButton.icon(
                                          onPressed: _acting
                                              ? null
                                              : () => _transition(a.status),
                                          icon: Icon(a.icon,
                                              size: 18,
                                              color: AppTheme.error),
                                          label: Text(a.label),
                                          style: OutlinedButton.styleFrom(
                                              foregroundColor:
                                                  AppTheme.error),
                                        )
                                      : PrimaryButton(
                                          label: a.label,
                                          icon: a.icon,
                                          isLoading: _acting,
                                          onPressed: () =>
                                              _transition(a.status),
                                        ),
                                ),
                              )),
                        if (!_isProvider && _canCancel)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _acting ? null : _cancelOrder,
                              icon: const Icon(Icons.cancel_outlined,
                                  size: 18, color: AppTheme.error),
                              label: const Text('CANCEL ORDER'),
                              style: OutlinedButton.styleFrom(
                                  foregroundColor: AppTheme.error),
                            ),
                          ),
                        if (!_isProvider &&
                            (_order?['status'] as String?) == 'COMPLETED')
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: SizedBox(
                              width: double.infinity,
                              child: PrimaryButton(
                                label: _reviewed
                                    ? 'EDIT YOUR REVIEW'
                                    : 'LEAVE A REVIEW',
                                icon: Icons.rate_review_outlined,
                                isOutlined: true,
                                onPressed: () async {
                                  await context.push('/review/new', extra: {
                                    'orderId': widget.orderId,
                                    'productId': _firstProductId,
                                    'providerId': _order?['provider_id'],
                                  });
                                  if (mounted) _load();
                                },
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
    );
  }

  /// Escrow-gated live location card. Visible only once payment is verified
  /// (APPROVED) or delivery started — matching the DB-side gate exactly.
  Widget _locationCard() {
    final status = (_order?['status'] as String?) ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.teal.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.teal.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.share_location_outlined,
                  size: 18, color: AppTheme.teal),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Live Location',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ),
              Text(status == 'STARTED' ? 'Delivery in progress' : 'Payment verified',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _isProvider
                ? 'Navigate to the buyer\'s shared live GPS position, or to your business pickup point.'
                : 'Share your live GPS position so the provider can navigate to you. Your location is never visible before payment is confirmed.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          if (_isProvider) ...[
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO BUYER LOCATION',
                icon: Icons.navigation_outlined,
                isLoading: _directionsLaunching,
                onPressed: _openBuyerDirections,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO MY BUSINESS',
                icon: Icons.store_outlined,
                isOutlined: true,
                onPressed: _openBusinessDirections,
              ),
            ),
          ] else ...[
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'SHARE LIVE LOCATION',
                icon: Icons.my_location,
                isLoading: _locSharing,
                onPressed: _shareMyLocation,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'DIRECTIONS TO PROVIDER',
                icon: Icons.store_outlined,
                isOutlined: true,
                onPressed: _openBusinessDirections,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headerCard() {
    final o = _order!;
    final status = (o['status'] as String?) ?? 'UNKNOWN';
    final provider =
        (o['provider_profiles'] as Map<String, dynamic>?) ?? const {};
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Order ${orderLabel(o)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: orderStatusColor(status).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_label(status),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: orderStatusColor(status))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Created ${_fmtDate(DateTime.parse(o['created_at'] as String))}',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
          if (provider['business_name'] != null) ...[
            const SizedBox(height: 4),
            Text(provider['business_name'] as String,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.teal)),
          ],
        ],
      ),
    );
  }

  Widget _itemsCard() {
    final o = _order!;
    final items = (o['order_items'] as List?) ?? const [];
    final total = (o['total_amount'] as num).toDouble();
    final currency = o['currency'] as String? ?? 'ETB';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Items',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_itemName(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      '${item['quantity']} × '
                      '${(item['unit_price'] as num).toDouble().toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary)),
                  const SizedBox(width: 12),
                  Text(
                      _lineTotal(item),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              Text('${total.toStringAsFixed(2)} $currency',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryGreen)),
            ],
          ),
        ],
      ),
    );
  }

  String _itemName(Map<String, dynamic> item) {
    final product = item['products'] as Map<String, dynamic>?;
    if (product == null) return 'Product unavailable';
    return product['name'] as String? ?? 'Product unavailable';
  }

  String _lineTotal(Map<String, dynamic> item) {
    final lineTotal = (item['subtotal'] as num?)?.toDouble() ??
        (item['quantity'] as num).toDouble() *
            (item['unit_price'] as num).toDouble();
    return lineTotal.toStringAsFixed(2);
  }

  Widget _proofCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Payment Proof',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: _proofUrl!,
              height: 140,
              width: double.infinity,
              fit: BoxFit.cover,
              errorWidget: (_, __, ___) => Container(
                height: 140,
                color: AppTheme.creamDark,
                child: const Center(
                    child: Icon(Icons.image_outlined,
                        size: 40, color: AppTheme.textMuted)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timelineCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Timeline',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_timeline.isEmpty)
            const Text('No status history yet',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted))
          else
            ..._timeline.map((t) => _timelineEntry(t)),
        ],
      ),
    );
  }

  Widget _timelineEntry(Map<String, dynamic> t) {
    final from = t['from_status'] as String?;
    final to = t['to_status'] as String? ?? 'UNKNOWN';
    final actor = t['changed_by'] as String?;
    final actorName = actor != null
        ? (_actorNames[actor] ?? '#${actor.substring(0, 8)}')
        : null;
    final note = t['note'] as String?;
    final when = t['created_at'] != null
        ? _fmtDate(DateTime.parse(t['created_at'] as String))
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: orderStatusColor(to),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  from == null
                      ? 'Order created'
                      : '${_label(from)} → ${_label(to)}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                Text(when,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
                if (actorName != null)
                  Text('by $actorName',
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary)),
                if (note != null && note.isNotEmpty)
                  Text(note,
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                          fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}