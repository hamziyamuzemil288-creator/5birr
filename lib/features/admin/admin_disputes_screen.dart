import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// Admin queue for orders in the `DISPUTED` state.
///
/// This screen exists because the order state machine is a one-way door
/// without it. `transition_order_status` lets a customer raise a dispute from
/// STARTED or COMPLETED, but the only exits from DISPUTED are REFUNDED and
/// COMPLETED, and BOTH require an admin actor:
///
/// ```
/// when 'DISPUTED' then p_new_status in ('REFUNDED','COMPLETED') and v_actor_is_admin
/// ```
///
/// So a customer could open a dispute that no one in the app could see, let
/// alone close. `/admin/appeals` does not cover this: `appeal_cases` models
/// spam reports with a photo and phone number and has no `order_id`.
///
/// Resolution goes through the same `order-transition` Edge Function the
/// customer and provider flows already use, so the whitelist, the
/// admin-actor check and the `order_status_history` audit trail all apply
/// unchanged.
class AdminDisputesScreen extends StatefulWidget {
  const AdminDisputesScreen({super.key});

  @override
  State<AdminDisputesScreen> createState() => _AdminDisputesScreenState();
}

class _AdminDisputesScreenState extends State<AdminDisputesScreen> {
  List<Map<String, dynamic>> _disputes = [];
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
            'id, status, total_amount, currency, created_at, updated_at, '
            'user_id, provider_id, '
            'provider_profiles!inner(business_name, user_id, profiles(full_name, phone))'
          )
          .eq('status', 'DISPUTED')
          .order('updated_at', ascending: true) // oldest dispute first
          .limit(200);

      if (!mounted) return;
      setState(() {
        _disputes = List<Map<String, dynamic>>.from(data as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A failed read here must never look like "no disputes": an admin
        // would conclude every open case had been dealt with.
        _error = friendlyError(e, context: 'Could not load disputes');
      });
    }
  }

  Future<void> _resolve(Map<String, dynamic> order, String newStatus) async {
    final id = order['id'] as String;
    final amount = _money(order);
    final isRefund = newStatus == 'REFUNDED';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isRefund ? 'Refund this order?' : 'Uphold the order?'),
        content: Text(
          isRefund
              ? 'Order $id for $amount will be marked REFUNDED. This is the '
                  'resolution the customer asked for and it cannot be undone '
                  'from this screen.'
              : 'Order $id for $amount will be marked COMPLETED. The dispute '
                  'is closed in the provider\'s favour.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          PrimaryButton(
            label: isRefund ? 'Refund' : 'Mark completed',
            isOutlined: !isRefund,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _acting.add(id));
    try {
      await Supabase.instance.client.functions.invoke(
        'order-transition',
        body: {
          'order_id': id,
          'new_status': newStatus,
          'note': isRefund
              ? 'Dispute resolved: refunded by admin'
              : 'Dispute resolved: order upheld by admin',
        },
      );
      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isRefund ? 'Order refunded' : 'Dispute closed — order completed',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _acting.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(friendlyError(e, context: 'Could not resolve this dispute')),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  String _money(Map<String, dynamic> o) {
    final amount = (o['total_amount'] as num?)?.toDouble() ?? 0;
    return '${amount.toStringAsFixed(2)} ${o['currency'] ?? 'ETB'}';
  }

  String _providerName(Map<String, dynamic> o) {
    // The join is `!inner`, so provider_profiles is always present, but the
    // relation can arrive under a different key depending on how PostgREST
    // flattens it, so check both shapes rather than trusting one.
    final p = o['provider_profiles'];
    if (p is Map<String, dynamic>) {
      return (p['business_name'] as String?)?.trim().isNotEmpty == true
          ? p['business_name'] as String
          : 'Unnamed provider';
    }
    return (o['business_name'] as String?) ?? 'Unnamed provider';
  }

  String _customerName(Map<String, dynamic> o) {
    final p = o['provider_profiles'];
    if (p is Map<String, dynamic>) {
      final prof = p['profiles'];
      if (prof is Map<String, dynamic>) {
        return (prof['full_name'] as String?)?.trim().isNotEmpty == true
            ? prof['full_name'] as String
            : 'Customer ${(o['user_id'] as String? ?? '').substring(0, 8)}';
      }
    }
    return 'Customer ${(o['user_id'] as String? ?? '').substring(0, 8)}';
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM yyyy, HH:mm');

    return Scaffold(
      appBar: AppBar(title: const Text('Disputes')),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _disputes.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified_user_outlined,
                              size: 64, color: AppTheme.textMuted),
                          SizedBox(height: 16),
                          Text('No open disputes',
                              style: TextStyle(color: AppTheme.textMuted)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: AppTheme.primaryGreen,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _disputes.length,
                        itemBuilder: (_, i) {
                          final o = _disputes[i];
                          final id = o['id'] as String;
                          final busy = _acting.contains(id);
                          final updated = DateTime.tryParse(
                                  '${o['updated_at']}')?.toLocal();
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.gavel,
                                          size: 18, color: AppTheme.error),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _money(o),
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        id.substring(0, 8),
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_customerName(o)}  ·  ${_providerName(o)}',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  if (updated != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Disputed ${fmt.format(updated)}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: PrimaryButton(
                                          label: 'Refund',
                                          icon: Icons.undo,
                                          isLoading: busy,
                                          onPressed: busy
                                              ? null
                                              : () => _resolve(o, 'REFUNDED'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: PrimaryButton(
                                          label: 'Uphold',
                                          isOutlined: true,
                                          isLoading: busy,
                                          onPressed: busy
                                              ? null
                                              : () => _resolve(o, 'COMPLETED'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
