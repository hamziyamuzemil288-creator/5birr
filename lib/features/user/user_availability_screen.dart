import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/cart_service.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

/// THE AVAILABILITY GATE — the screen between "Buy" and checkout.
///
/// The report this exists for, twice: a buyer could go straight to payment
/// while the provider was never asked whether the item exists. Every entry
/// into checkout (the shared Buy/Book button, the product page's buy-now,
/// the cart's CHECKOUT) now pushes THIS route instead, and
/// `user_checkout_screen` pushReplaces itself with it as a backstop for deep
/// links — so there is no way to reach payment without an answer.
///
/// The flow:
///   ask      — "Is this product available?" calls
///              create_availability_requests(provider, products[]), which is
///              idempotent (an existing PENDING row is resumed, an existing
///              ACCEPTED one is returned as-is) and notifies the provider.
///   wait     — a 15:00 countdown (the server's expires_at, not a local
///              guess), realtime on availability_requests plus a 15-second
///              poll as the fallback, and a CANCEL that stands the request
///              down. At zero the screen takes the buyer back to the
///              dashboard — the same place the server's cron lands the row.
///   accepted — every product answered YES inside its window: pushReplacement
///              into /user/checkout. The server re-checks and claims the
///              rows (used_at) when the order is actually placed, so one
///              answer can never cover two orders.
///   rejected — "Not available" with the provider's reason, and a way out.
///
/// Degradation is deliberate: if the server has not run migration
/// 20261006000006 yet, the RPCs do not exist — and neither does the server
/// gate — so the buyer is let through to checkout instead of being trapped
/// by a decoration. The moment the migration is live the gate is the rule
/// again, enforced by create_order_secure regardless of what this screen
/// does.
class UserAvailabilityScreen extends StatefulWidget {
  const UserAvailabilityScreen({super.key, required this.providerId});

  /// The provider whose stock is being asked about, carried as route `extra`
  /// exactly like `/user/checkout`. Empty is tolerated (a stale deep link):
  /// the screen then derives it from the buyer's cart.
  final String providerId;

  @override
  State<UserAvailabilityScreen> createState() =>
      _UserAvailabilityScreenState();
}

enum _GatePhase { loading, error, empty, ask, waiting, rejected, accepted }

class _UserAvailabilityScreenState extends State<UserAvailabilityScreen> {
  List<CartItem> _items = [];
  List<Map<String, dynamic>> _rows = [];
  String _providerId = '';
  bool _loading = true;
  bool _asking = false;
  String? _error;

  /// 1 = the request window has just closed. One `setState` per second only,
  /// so the countdown costs one rebuild a second and nothing else.
  int _remainingSeconds = 0;
  int _pollTicks = 0;
  Timer? _ticker;
  ResilientSubscription<List<Map<String, dynamic>>>? _live;

  /// True once this visit has been in the WAITING phase — the flag that
  /// separates "the cron expired the row we were watching" (walk the buyer
  /// to the dashboard) from "an old EXPIRED row from a previous visit"
  /// (show the ask panel again).
  bool _wasWaiting = false;

  /// Re-entrancy guard for [_timeout]: the ticker and the realtime refresh
  /// can both notice the same expiry in the same second.
  bool _timingOut = false;

  /// Guards every navigation out of this screen: accepted → checkout and
  /// timeout → dashboard must each happen exactly once, no matter how many
  /// refreshes or realtime frames agree on the answer.
  bool _navigated = false;

  SupabaseClient get _client => Supabase.instance.client;

  List<String> get _productIds =>
      _items.map((i) => i.productId).toSet().toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _live?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = await CartService.instance.getCart();
      final items = widget.providerId.isEmpty
          ? all
          : all.where((i) => i.providerId == widget.providerId).toList();
      if (items.isEmpty) {
        if (mounted) {
          setState(() {
            _items = [];
            _loading = false;
          });
        }
        return;
      }
      _providerId = widget.providerId.isNotEmpty
          ? widget.providerId
          : items.first.providerId;
      _items = items;
      await _refreshRows();
      if (mounted) setState(() => _loading = false);
      _subscribe();
      _startTicker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not check availability');
        });
      }
    }
  }

  /// Re-reads this buyer's rows for this basket. Both the realtime
  /// subscription and the poll funnel through here so there is exactly one
  /// place that decides what the screen shows.
  Future<void> _refreshRows() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || _providerId.isEmpty || _productIds.isEmpty) return;
    try {
      final data = await _client
          .from('availability_requests')
          .select()
          .eq('buyer_id', uid)
          .eq('provider_id', _providerId)
          .inFilter('product_id', _productIds)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() => _rows = List<Map<String, dynamic>>.from(data as List));
      _evaluate();
    } catch (_) {
      // A database that has not run 20261006000006 has no such table. The
      // ask panel (and its own, explicit fallback) handles that case; this
      // read must not turn a missing table into a red error screen.
    }
  }

  void _subscribe() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || _providerId.isEmpty) return;
    _live?.cancel();
    _live = ResilientSubscription<List<Map<String, dynamic>>>(
      stream: _client
          .from('availability_requests')
          .stream(primaryKey: ['id'])
          .eq('buyer_id', uid)
          .order('created_at'),
      onData: (_) => _refreshRows(),
      // Connection quality only changes how much the poll matters; the poll
      // runs either way, so there is nothing to render here.
      onState: (_) {},
    );
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    if (!mounted || _navigated) return;
    final phase = _phase();
    if (phase == _GatePhase.waiting) {
      _wasWaiting = true;
      final expiry = _pendingExpiry();
      final remain =
          expiry == null ? 0 : expiry.difference(DateTime.now().toUtc()).inSeconds;
      if (remain <= 0) {
        _timeout();
        return;
      }
      if (remain != _remainingSeconds) {
        setState(() => _remainingSeconds = remain);
      }
      // Fallback for a realtime socket that never delivered the answer:
      // re-read every 15 ticks instead of trusting a dead stream.
      if (++_pollTicks >= 15) {
        _pollTicks = 0;
        _refreshRows();
      }
    }
  }

  /// The newest row per product (rows arrive newest-first).
  Map<String, Map<String, dynamic>> _latestByProduct() {
    final latest = <String, Map<String, dynamic>>{};
    for (final r in _rows) {
      final pid = r['product_id'] as String?;
      if (pid == null || latest.containsKey(pid)) continue;
      latest[pid] = r;
    }
    return latest;
  }

  _GatePhase _phase() {
    if (_loading) return _GatePhase.loading;
    if (_error != null) return _GatePhase.error;
    if (_items.isEmpty) return _GatePhase.empty;

    final latest = _latestByProduct();
    final now = DateTime.now().toUtc();
    var anyPending = false;
    var anyRejected = false;
    var allUsable = true;

    for (final item in _items) {
      final r = latest[item.productId];
      if (r == null) {
        allUsable = false;
        continue;
      }
      final status = r['status'];
      if (status == 'PENDING') anyPending = true;
      if (status == 'REJECTED') anyRejected = true;
      if (status != 'ACCEPTED') {
        allUsable = false;
      } else {
        final exp = DateTime.tryParse('${r['expires_at']}');
        if (r['used_at'] != null || exp == null || !exp.isAfter(now)) {
          allUsable = false;
        }
      }
    }

    if (anyPending) return _GatePhase.waiting;
    if (anyRejected) return _GatePhase.rejected;
    if (allUsable) return _GatePhase.accepted;
    // Nothing live: no row yet, or every row dead (expired, cancelled,
    // already consumed) — all of which mean "ask again".
    return _GatePhase.ask;
  }

  DateTime? _pendingExpiry() {
    final latest = _latestByProduct();
    DateTime? earliest;
    for (final item in _items) {
      final r = latest[item.productId];
      if (r == null || r['status'] != 'PENDING') continue;
      final exp = DateTime.tryParse('${r['expires_at']}');
      if (exp == null) continue;
      if (earliest == null || exp.isBefore(earliest)) earliest = exp;
    }
    return earliest;
  }

  /// Reacts to the current phase exactly once: accepted walks into checkout,
  /// a cron-expired wait walks back to the dashboard.
  void _evaluate() {
    if (!mounted || _navigated) return;
    final phase = _phase();
    if (phase == _GatePhase.accepted) {
      _navigated = true;
      _ticker?.cancel();
      context.pushReplacement('/user/checkout', extra: _providerId);
      return;
    }
    if (phase == _GatePhase.waiting) {
      _wasWaiting = true;
      return;
    }
    // We WERE waiting and now nothing is live, and at least one row died on
    // the server: the cron answered "no". The buyer is done here — same
    // destination the timeout takes them to.
    if (_wasWaiting && phase == _GatePhase.ask) {
      final anyExpired = _latestByProduct()
          .values
          .any((r) => r['status'] == 'EXPIRED');
      if (anyExpired) _timeout();
    }
  }

  /// The 15 minutes ran out. Best-effort, in this order:
  ///  1. re-read once, because an answer that landed in the last second
  ///     beats a timeout;
  ///  2. stand the stale PENDING rows down (cancel is idempotent for
  ///     EXPIRED/CANCELLED) so the unique index is free and the buyer can
  ///     re-ask immediately instead of colliding with a row the cron has
  ///     not flipped yet;
  ///  3. walk back to the dashboard.
  Future<void> _timeout() async {
    if (_navigated || _timingOut || !mounted) return;
    _timingOut = true;
    try {
      // Re-read once: an answer that landed in the last second beats a
      // timeout, and _evaluate navigates to checkout if so.
      await _refreshRows();
      if (_navigated || !mounted) return;
      final phase = _phase();
      if (phase == _GatePhase.accepted) return; // _evaluate navigated
      // Only a clock that has actually run out times out: the cron may not
      // have flipped a PENDING row yet, but if this row still has seconds
      // on it there is nothing to time out FROM.
      final expiry = _pendingExpiry();
      if (expiry != null && expiry.isAfter(DateTime.now().toUtc())) return;

      _navigated = true;
      _ticker?.cancel();
      // Stand the stale rows down so the unique index is free: without
      // this, re-asking would collide with a PENDING row the cron has not
      // expired yet and the buyer would wait on a dead request.
      for (final id in _pendingIds()) {
        try {
          await _client.rpc('cancel_availability_request',
              params: {'p_request_id': id});
        } catch (_) {
          // The cron owns the row; a failed stand-down changes nothing.
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The provider did not answer in time. '
              'You can ask again from any product page.'),
        ),
      );
      context.go('/user');
    } finally {
      _timingOut = false;
    }
  }

  List<String> _pendingIds() {
    final latest = _latestByProduct();
    return latest.values
        .where((r) => r['status'] == 'PENDING')
        .map((r) => r['id'] as String)
        .toList();
  }

  Future<void> _ask() async {
    if (_asking) return;
    setState(() => _asking = true);
    try {
      final result = await _client.rpc(
        'create_availability_requests',
        params: {
          'p_provider_id': _providerId,
          'p_product_ids': _productIds,
        },
      );
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(result as List);
        _asking = false;
        _wasWaiting = false;
      });
      _evaluate();
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      // The server predates 20261006000006: no RPC, no table — and no
      // server-side gate either. Letting the buyer through matches exactly
      // what create_order_secure would do; trapping them would not.
      if (raw.contains('create_availability_requests') ||
          raw.contains('availability_requests')) {
        setState(() => _asking = false);
        _navigated = true;
        _ticker?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Availability check is unavailable right now — '
                'continuing to checkout.'),
          ),
        );
        context.pushReplacement('/user/checkout', extra: _providerId);
        return;
      }
      setState(() => _asking = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyError(e,
              context: 'Could not ask the provider — try again')),
        ),
      );
    }
  }

  Future<void> _cancel() async {
    final ids = _pendingIds();
    if (ids.isEmpty) return;
    try {
      for (final id in ids) {
        await _client.rpc('cancel_availability_request',
            params: {'p_request_id': id});
      }
    } catch (_) {
      // Idempotent server-side; a failure just means the row waits for the
      // cron, and the refresh below shows whatever actually happened.
    }
    _wasWaiting = false;
    await _refreshRows();
  }

  String _countdown() {
    final m = (_remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_remainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String? _rejectionReason() {
    final latest = _latestByProduct();
    for (final item in _items) {
      final r = latest[item.productId];
      if (r != null && r['status'] == 'REJECTED') {
        final reason = (r['reason'] as String?)?.trim();
        if (reason != null && reason.isNotEmpty) return reason;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Availability check')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: switch (_phase()) {
            _GatePhase.loading => _centered(
                const CircularProgressIndicator(color: AppTheme.primaryGreen)),
            _GatePhase.error => _messagePanel(
                icon: Icons.error_outline,
                iconColor: AppTheme.error,
                title: 'Something went wrong',
                body: _error ?? 'Could not check availability.',
                actions: [
                  PrimaryButton(
                    label: 'TRY AGAIN',
                    onPressed: _load,
                  ),
                  const SizedBox(height: 10),
                  _textAction('BACK TO HOME', () => context.go('/user')),
                ]),
            _GatePhase.empty => _messagePanel(
                icon: Icons.shopping_bag_outlined,
                iconColor: AppTheme.textMuted,
                title: 'Your cart is empty',
                body: 'Add something to your cart first — the provider is '
                    'asked about an item before you pay for it.',
                actions: [
                  PrimaryButton(
                    label: 'BROWSE PRODUCTS',
                    onPressed: () => context.go('/user'),
                  ),
                ]),
            _GatePhase.ask => _askPanel(),
            _GatePhase.waiting => _waitingPanel(),
            _GatePhase.rejected => _rejectedPanel(),
            _GatePhase.accepted => _centered(_acceptedPanel()),
          },
        ),
      ),
    );
  }

  Widget _centered(Widget child) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Center(child: child),
      );

  Widget _basket() => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('You are asking about',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            ..._items.map((i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      const Icon(Icons.shopping_bag_outlined,
                          size: 15, color: AppTheme.teal),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${i.name}  × ${_fmtQty(i.quantity)}',
                          style: const TextStyle(fontSize: 13.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      );

  static String _fmtQty(double q) =>
      q == q.roundToDouble() ? q.toInt().toString() : q.toString();

  Widget _askPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _basket(),
        const SizedBox(height: 24),
        const Icon(Icons.help_outline, size: 44, color: AppTheme.teal),
        const SizedBox(height: 12),
        const Text(
          'Is this product available?',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Before you pay, the provider confirms the item is in stock. '
          'They have 15 minutes to answer.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'ASK THE PROVIDER',
          icon: Icons.schedule,
          isLoading: _asking,
          onPressed: _asking ? null : _ask,
        ),
        const SizedBox(height: 10),
        _textAction('NOT NOW', () => context.go('/user')),
      ],
    );
  }

  Widget _waitingPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _basket(),
        const SizedBox(height: 24),
        const SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(
              strokeWidth: 3, color: AppTheme.primaryGreen),
        ),
        const SizedBox(height: 16),
        const Text(
          'Waiting for the provider…',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          'Answer in ${_countdown()}',
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppTheme.primaryGreen,
              fontFeatures: []),
        ),
        const SizedBox(height: 8),
        const Text(
          'We will move you to checkout the moment they say yes.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 28),
        _textAction('CANCEL REQUEST', () => _cancel()),
      ],
    );
  }

  Widget _rejectedPanel() {
    final reason = _rejectionReason();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        const Icon(Icons.remove_shopping_cart_outlined,
            size: 46, color: AppTheme.error),
        const SizedBox(height: 12),
        const Text(
          'Not available',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          reason == null
              ? 'This provider does not have this item right now.'
              : 'The provider replied: $reason',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        PrimaryButton(
          label: 'FIND ANOTHER PROVIDER',
          onPressed: () => context.go('/user'),
        ),
        const SizedBox(height: 10),
        _textAction('ASK AGAIN', () {
          _wasWaiting = false;
          _ask();
        }),
      ],
    );
  }

  Widget _acceptedPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(Icons.check_circle_outline, size: 52, color: AppTheme.success),
        SizedBox(height: 12),
        Text(
          'Available — taking you to checkout…',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _messagePanel({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
    required List<Widget> actions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Icon(icon, size: 46, color: iconColor),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            style:
                const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(body,
            textAlign: TextAlign.center,
            style:
                const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary)),
        const SizedBox(height: 24),
        ...actions,
      ],
    );
  }

  Widget _textAction(String label, VoidCallback onTap) {
    return TextButton(
      onPressed: onTap,
      child: Text(label,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: AppTheme.teal)),
    );
  }
}
