import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/wallet_service.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _transactions = [];
  bool _loading = true;
  double _lowThreshold = 15;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final wallet = await WalletService.instance.getMyWallet();
      final txns = await WalletService.instance.getMyTransactions(limit: 30);
      final threshold = await WalletService.instance.getLowBalanceThreshold();
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _transactions = txns;
          _lowThreshold = threshold;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = (_wallet?['balance'] as num?)?.toDouble() ?? 0;
    final isLow = balance <= _lowThreshold;

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  // Balance card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [AppTheme.primaryGreen, AppTheme.primaryGreenDark]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Current Balance',
                            style: TextStyle(
                                fontSize: 14, color: Colors.white70)),
                        const SizedBox(height: 8),
                        Text('${balance.toStringAsFixed(2)} ETB',
                            style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                        if (isLow) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                                '⚠ Your balance is low. Please recharge.',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.white)),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Recharge button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => context.push('/wallet/recharge'),
                      icon: const Icon(Icons.add),
                      label: const Text('RECHARGE WALLET'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.teal,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Recent transactions
                  const Text('Recent Transactions',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  if (_transactions.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(30),
                      child: Center(
                          child: Text('No transactions yet',
                              style: TextStyle(color: AppTheme.textMuted))),
                    )
                  else
                    ..._transactions.map((t) => _txnTile(t)),
                ],
              ),
            ),
    );
  }

  Widget _txnTile(Map<String, dynamic> t) {
    final type = t['transaction_type'] ?? '';
    final gross = (t['gross_amount'] as num?)?.toDouble() ?? 0;
    final net = (t['net_amount'] as num?)?.toDouble() ?? 0;
    final fee = (t['platform_fee'] as num?)?.toDouble() ?? 0;
    final isCredit = type == 'RECHARGE' || type == 'ADMIN_CASH' ||
        type == 'ADJUSTMENT' || type == 'REFUND' || type == 'DEPOSIT';
    final color = isCredit ? AppTheme.success : AppTheme.error;
    final sign = isCredit ? '+' : '-';
    final date = t['created_at'] != null
        ? DateTime.parse(t['created_at'])
        : DateTime.now();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isCredit ? Icons.arrow_downward : Icons.arrow_upward,
              color: color,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_txnLabel(type),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                    '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$sign${gross.toStringAsFixed(2)} ETB',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: color)),
              if (fee > 0)
                Text('Fee: ${fee.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textMuted)),
            ],
          ),
        ],
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
      case 'REFUND': return 'Refund';
      case 'DEPOSIT': return 'Deposit';
      case 'WITHDRAWAL': return 'Withdrawal';
      default: return type;
    }
  }
}
