import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// Admin queue for orders waiting on payment verification.
///
/// This screen exists because `PAYMENT_VERIFICATION` is a one-way door
/// without it. The order state machine routes an order through it:
///
/// ```
/// ACCEPTED          -> PAYMENT_PENDING        (provider requests payment)
/// PAYMENT_PENDING   -> PAYMENT_VERIFICATION   (buyer submits the proof)
/// PAYMENT_VERIFICATION -> APPROVED | REJECTED (ADMIN ONLY)
/// ```
///
/// and `transition_order_status` guards the last step:
///
/// ```
/// when 'PAYMENT_VERIFICATION' then
///   p_new_status in ('APPROVED','REJECTED') and v_actor_is_admin
/// ```
///
/// So every order a buyer paid for landed in a state only an admin could
/// leave, and the admin app had no screen for it: `/admin/payments` verifies
/// WALLET RECHARGES (`wallet_recharge_requests`), an entirely different
/// flow. The buyer waited forever, the provider could not start the work
/// (STARTED requires APPROVED), and the money was never released.
///
/// It also has to verify the proof, not just flip the order. `APPROVED`
/// requires a proof already marked VERIFIED:
///
/// ```
/// if p_new_status = 'APPROVED' and v_order.requires_payment_proof then
///   ... raise exception 'PAYMENT_PROOF_REQUIRED'
/// ```
///
/// and only an admin may set that flag (`prevent_payment_proof_self_verification`).
/// So approval here is two deliberate steps — mark the proof VERIFIED, then
/// transition the order — in that order, and the screen does them together so
/// an admin cannot half-complete one.
class AdminOrderPaymentsScreen extends StatefulWidget {
  const AdminOrderPaymentsScreen({super.key});

  @override
  State<AdminOrderPaymentsScreen> createState() =>
      _AdminOrderPaymentsScreenState();
}

class _AdminOrderPaymentsScreenState extends State<AdminOrderPaymentsScreen> {
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;
  final Set<String> _acting = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Supabase.instance.client
          .from('orders')
          .select(
            'id, order_number, status, total_amount, currency, created_at, '
            'user_id, provider_id, '
            'payment_proofs(id, storage_path, verification_status, created_at), '
            'provider_profiles!inner(business_name, profiles(full_name, phone))'
          )
          .eq('status', 'PAYMENT_VERIFICATION')
          .order('updated_at', ascending: true) // longest waiting first
          .limit(200);

      if (!mounted) return;
      setState(() {
        _orders = List<Map<String, dynamic>>.from(data as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A failed read must never look like "nothing is waiting": an admin
        // would conclude every customer had been paid out.
        _error = friendlyError(e, context: 'Could not load payments');
      });
    }
  }

  /// Approve: mark every proof on the order VERIFIED, then move the order to
  /// APPROVED.
  ///
  /// The proof is marked first because the order transition is what enforces
  /// it — approving first would fail with PAYMENT_PROOF_REQUIRED and leave a
  /// verified proof on an order still awaiting approval, which reads as a
  /// half-finished job on the next load.
  Future<void> _approve(Map<String, dynamic> order) async {
    final id = order['id'] as String;
    final amount = _money(order);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Release payment?'),
        content: Text(
          'Confirm you have checked the transfer for $amount against the '
          'attached proof. Approving releases the order to the provider and '
          'cannot be undone from this screen.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          PrimaryButton(
            label: 'Approve payment',
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _acting.add(id));
    try {
      final client = Supabase.instance.client;
      final proofs = _proofs(order);

      for (final p in proofs) {
        if (p['verification_status'] == 'VERIFIED') continue;
        await client
            .from('payment_proofs')
            .update({
              'verification_status': 'VERIFIED',
              'verified_by': client.auth.currentUser!.id,
              'verified_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', p['id']);
      }

      await client.functions.invoke('order-transition', body: {
        'order_id': id,
        'new_status': 'APPROVED',
        'note': 'Payment proof verified by admin',
      });

      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment approved — order released')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyError(e, context: 'Could not approve this payment')),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _reject(Map<String, dynamic> order) async {
    final id = order['id'] as String;
    final reasonCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject payment'),
        content: TextField(
          controller: reasonCtrl,
          maxLines: 2,
          decoration: const InputDecoration(hintText: 'Reason *'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject',
                style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
    if (result != true || reasonCtrl.text.trim().isEmpty) return;
    final reason = reasonCtrl.text.trim();

    setState(() => _acting.add(id));
    try {
      final client = Supabase.instance.client;
      for (final p in _proofs(order)) {
        await client
            .from('payment_proofs')
            .update({
              'verification_status': 'REJECTED',
              'verified_by': client.auth.currentUser!.id,
              'verified_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('id', p['id']);
      }

      await client.functions.invoke('order-transition', body: {
        'order_id': id,
        'new_status': 'REJECTED',
        'note': 'Payment rejected by admin: $reason',
      });

      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Payment rejected')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyError(e, context: 'Could not reject this payment')),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  /// The proof rows embedded on the order, as a list of maps.
  ///
  /// PostgREST returns a to-one embed as a map and a to-many embed as a
  /// list; `payment_proofs` is to-many from `orders`, but a failed or
  /// partially-applied embed can still arrive as a single map, so both
  /// shapes are accepted rather than assumed.
  List<Map<String, dynamic>> _proofs(Map<String, dynamic> order) {
    final raw = order['payment_proofs'];
    if (raw is List) return raw.whereType<Map<String, dynamic>>().toList();
    if (raw is Map<String, dynamic>) return [raw];
    return const [];
  }

  String _money(Map<String, dynamic> order) {
    final amount = (order['total_amount'] as num?)?.toDouble() ?? 0;
    final currency = order['currency'] as String? ?? 'ETB';
    return '$amount $currency';
  }

  Future<void> _viewProof(Map<String, dynamic> proof) async {
    final path = proof['storage_path'] as String?;
    if (path == null || path.isEmpty) return;
    try {
      // Private bucket: the admin sees it via a short-lived signed URL.
      final url = await Supabase.instance.client.storage
          .from('payment-proofs')
          .createSignedUrl(path, 600);
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: InteractiveViewer(
            child: Image.network(
              url,
              errorBuilder: (_, __, ___) => const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Could not load this image'),
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, context: 'Could not open the proof'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Payments'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _orders.isEmpty
                  ? const Center(
                      child: Text('No payments waiting for review',
                          style: TextStyle(color: AppTheme.textMuted)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _orders.length,
                        itemBuilder: (_, i) => _card(_orders[i]),
                      ),
                    ),
    );
  }

  Widget _card(Map<String, dynamic> order) {
    final id = order['id'] as String;
    final acting = _acting.contains(id);
    final provider = order['provider_profiles'] as Map<String, dynamic>?;
    final profile =
        provider != null ? provider['profiles'] as Map<String, dynamic>? : null;
    final proofs = _proofs(order);
    final waiting = proofs
        .where((p) => p['verification_status'] != 'VERIFIED')
        .toList();
    final f = DateFormat('d MMM, HH:mm');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    provider?['business_name'] as String? ?? 'Provider',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  _money(order),
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryGreen),
                ),
              ],
            ),
            if (profile?['full_name'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(profile!['full_name'] as String,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.textSecondary)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'Order ${order['order_number'] ?? id.substring(0, 8)}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 10),
            if (proofs.isEmpty)
              const Text(
                'No payment proof attached. Reject this order or ask the '
                'customer to resubmit from their order page.',
                style: TextStyle(fontSize: 13, color: AppTheme.error),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in waiting)
                    ActionChip(
                      avatar: const Icon(Icons.receipt_long, size: 16),
                      label: Text(
                        p['verification_status'] == 'REJECTED'
                            ? 'Rejected proof'
                            : 'Proof pending',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () => _viewProof(p),
                    ),
                  if (waiting.isEmpty)
                    const Chip(
                      avatar: Icon(Icons.check, size: 16),
                      label: Text('Proof verified',
                          style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: acting ? null : () => _reject(order),
                    icon: const Icon(Icons.close, size: 18,
                        color: AppTheme.error),
                    label: const Text('Reject',
                        style: TextStyle(color: AppTheme.error)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.error,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'Approve',
                    isLoading: acting,
                    onPressed: acting ? null : () => _approve(order),
                  ),
                ),
              ],
            ),
            if (order['created_at'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Placed ${f.format(DateTime.parse(order['created_at'] as String).toLocal())}',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
