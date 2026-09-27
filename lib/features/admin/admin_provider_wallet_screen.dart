import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class AdminProviderWalletScreen extends StatefulWidget {
  final String providerId;
  const AdminProviderWalletScreen({super.key, required this.providerId});
  @override
  State<AdminProviderWalletScreen> createState() => _State();
}

class _State extends State<AdminProviderWalletScreen> {
  Map<String, dynamic>? _wallet;
  Map<String, dynamic>? _provider;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _rechargeRequests = [];
  bool _loading = true;
  // A failed load used to leave _wallet null, and the screen then rendered
  // that as a balance of 0.00 ETB — an admin reconciling a provider's money
  // would be told the wallet was empty when the request had merely failed.
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final wallet = await client
          .from('wallets')
          .select()
          .eq('provider_id', widget.providerId)
          .maybeSingle();
      final prov = await client
          .from('provider_profiles')
          .select('*, profiles(full_name, phone)')
          .eq('id', widget.providerId)
          .maybeSingle();
      final txns = await client
          .from('wallet_transactions')
          .select()
          .eq('provider_id', widget.providerId)
          .order('created_at', ascending: false)
          .limit(50);
      final recharges = await client
          .from('wallet_recharge_requests')
          .select('*, payment_methods(name)')
          .eq('provider_id', widget.providerId)
          .order('created_at', ascending: false)
          .limit(20);
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _provider = prov;
          _transactions = List<Map<String, dynamic>>.from(txns as List);
          _rechargeRequests =
              List<Map<String, dynamic>>.from(recharges as List);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load this wallet');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
          body: const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen)));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Provider Wallet')),
        body: LoadErrorView(message: _error!, onRetry: _load),
      );
    }
    final balance = (_wallet?['balance'] as num?)?.toDouble() ?? 0;
    final profile =
        _provider != null ? _provider!['profiles'] as Map<String, dynamic>? : null;

    return Scaffold(
      appBar: AppBar(
        title: Text('${_provider?['business_name'] ?? 'Provider'} Wallet'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              await context.push('/admin/providers/${widget.providerId}/wallet/recharge');
              _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Balance
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [AppTheme.primaryGreen, AppTheme.primaryGreenDark]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(profile?['full_name'] ?? '',
                      style: const TextStyle(
                          fontSize: 14, color: Colors.white70)),
                  const SizedBox(height: 4),
                  Text('${balance.toStringAsFixed(2)} ETB',
                      style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Quick actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await context.push(
                          '/admin/providers/${widget.providerId}/wallet/recharge');
                      _load();
                    },
                    icon: const Icon(Icons.money, size: 18),
                    label: const Text('Cash Recharge'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Recharge requests
            if (_rechargeRequests.isNotEmpty) ...[
              const Text('Recharge Requests',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ..._rechargeRequests.map((r) => ListTile(
                    title: Text(
                        '${(r['amount'] as num).toStringAsFixed(2)} ETB'),
                    subtitle: Text(r['status'] ?? ''),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: r['status'] == 'APPROVED'
                            ? AppTheme.success.withOpacity(0.1)
                            : r['status'] == 'REJECTED'
                                ? AppTheme.error.withOpacity(0.1)
                                : AppTheme.warning.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(r['status'],
                          style: TextStyle(
                              fontSize: 11,
                              color: r['status'] == 'APPROVED'
                                  ? AppTheme.success
                                  : r['status'] == 'REJECTED'
                                      ? AppTheme.error
                                      : AppTheme.warning)),
                    ),
                  )),
              const SizedBox(height: 16),
            ],
            // Transactions
            const Text('Transaction History',
                style:
                    TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (_transactions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                    child: Text('No transactions',
                        style: TextStyle(color: AppTheme.textMuted))),
              )
            else
              ..._transactions.map((t) {
                final type = t['transaction_type'] ?? '';
                final gross =
                    (t['gross_amount'] as num?)?.toDouble() ?? 0;
                final isCredit = type == 'RECHARGE' ||
                    type == 'ADMIN_CASH' ||
                    type == 'ADJUSTMENT';
                return ListTile(
                  title: Text(
                      '${isCredit ? '+' : '-'}${gross.toStringAsFixed(2)} ETB',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isCredit
                              ? AppTheme.success
                              : AppTheme.error)),
                  subtitle: Text(_txnLabel(type)),
                );
              }),
          ],
        ),
      ),
    );
  }

  String _txnLabel(String type) {
    switch (type) {
      case 'RECHARGE': return 'Recharge';
      case 'ADMIN_CASH': return 'Cash Recharge';
      case 'TRANSACTION_FEE': return 'Transaction Fee';
      case 'SUBSCRIPTION_FEE': return 'Subscription Fee';
      case 'ADJUSTMENT': return 'Adjustment';
      default: return type;
    }
  }
}
