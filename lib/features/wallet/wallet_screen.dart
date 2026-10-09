import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/wallet_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/shimmer_effect.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});
  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  Map<String, dynamic>? _wallet;
  List<Map<String, dynamic>> _transactions = [];
  List<Map<String, dynamic>> _rechargeRequests = [];
  bool _loading = true;
  double _lowThreshold = 15;
  // Set when _load() fails. Without it the screen cleared the spinner and
  // rendered a confident "Current Balance 0.00 ETB", which reads as "your
  // wallet is empty" rather than "we could not reach your wallet" — the worst
  // possible reading for the screen that holds someone's money.
  String? _error;

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
      final requests = await WalletService.instance.getMyRechargeRequests();
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _transactions = txns;
          _lowThreshold = threshold;
          _rechargeRequests = requests;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your wallet');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = (_wallet?['balance'] as num?)?.toDouble() ?? 0;
    final isLow = balance <= _lowThreshold;

    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: _loading
          ? _walletSkeleton()
          : _error != null
              ? _walletError(_error!, onRetry: _load)
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
                          gradient: const LinearGradient(colors: [
                            AppTheme.primaryGreen,
                            AppTheme.primaryGreenDark
                          ]),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Current Balance',
                                style:
                                    TextStyle(fontSize: 14, color: Colors.white70)),
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
                                  color: AppTheme.warning.withValues(alpha: 0.3),
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
                      const SizedBox(height: 12),
                      // Points live next to the wallet because that is what they
                      // convert into. The conversion rate is a server setting and
                      // the screen reads it live.
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => context.push('/points'),
                          icon: const Icon(Icons.stars_rounded),
                          label: const Text('POINTS & RANK'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppTheme.primaryGreen,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // My recharge requests
                      const Text('My Recharge Requests',
                          style:
                              TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      if (_rechargeRequests.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8),
                          child: Text('No recharge requests yet',
                              style: TextStyle(color: AppTheme.textMuted)),
                        )
                      else
                        ..._rechargeRequests.map(_rechargeTile),
                      const SizedBox(height: 24),
                      // Recent transactions
                      const Text('Recent Transactions',
                          style:
                              TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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
                      gradient: const LinearGradient(colors: [
                        AppTheme.primaryGreen,
                        AppTheme.primaryGreenDark
                      ]),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Current Balance',
                            style:
                                TextStyle(fontSize: 14, color: Colors.white70)),
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
                              color: AppTheme.warning.withValues(alpha: 0.3),
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
                  const SizedBox(height: 12),
                  // Points live next to the wallet because that is what they
                  // convert into. The conversion rate is a server setting and
                  // the screen reads it live.
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/points'),
                      icon: const Icon(Icons.stars_rounded),
                      label: const Text('POINTS & RANK'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primaryGreen,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // My recharge requests
                  const Text('My Recharge Requests',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  if (_rechargeRequests.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('No recharge requests yet',
                          style: TextStyle(color: AppTheme.textMuted)),
                    )
                  else
                    ..._rechargeRequests.map(_rechargeTile),
                  const SizedBox(height: 24),
                  // Recent transactions
                  const Text('Recent Transactions',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
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

  /// Status chip colors for recharge requests.
  Color _requestColor(String status) {
    switch (status) {
      case 'APPROVED':
        return AppTheme.success;
      case 'REJECTED':
        return AppTheme.error;
      default:
        return AppTheme.warning; // PENDING
    }
  }

  Widget _walletSkeleton() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        children: [
          // Balance card skeleton
          ShimmerEffect(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.creamDark,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(
                      width: 120, height: 14, borderRadius: 6),
                  SizedBox(height: 16),
                  SkeletonBox(
                      width: 200, height: 34, borderRadius: 8),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          ShimmerEffect(
            child: SkeletonBox(
                width: double.infinity, height: 52, borderRadius: 12),
          ),
          const SizedBox(height: 12),
          ShimmerEffect(
            child: SkeletonBox(
                width: double.infinity, height: 52, borderRadius: 12),
          ),
          const SizedBox(height: 24),
          // Recharge requests label + skeleton row
          const SkeletonBox(
              width: 160, height: 18, borderRadius: 6),
          const SizedBox(height: 12),
          ShimmerEffect(
            child: SkeletonBox(
                width: double.infinity, height: 68, borderRadius: 10),
          ),
          const SizedBox(height: 24),
          // Transactions label + skeleton row
          const SkeletonBox(
              width: 160, height: 18, borderRadius: 6),
          const SizedBox(height: 12),
          ShimmerEffect(
            child: SkeletonBox(
                width: double.infinity, height: 68, borderRadius: 10),
          ),
          const SizedBox(height: 68),
        ],
      ),
    );
  }

  Widget _walletError(String message, {required VoidCallback onRetry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }

  Widget _rechargeTile(Map<String, dynamic> r) {
    final status = (r['status'] as String?) ?? 'PENDING';
    final amount = (r['amount'] as num?)?.toDouble() ?? 0;
    final method =
        (r['payment_methods'] as Map<String, dynamic>?)?['name'] as String?;
    final date = r['created_at'] != null
        ? DateTime.parse(r['created_at'])
        : DateTime.now();
    final color = _requestColor(status);

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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(status,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: color)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${amount.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  '${method ?? 'Payment'} · ${date.day}/${date.month}/${date.year}',
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                if (status == 'REJECTED' && r['rejection_reason'] != null) ...[
                  const SizedBox(height: 4),
                  Text('Reason: ${r['rejection_reason']}',
                      style:
                          const TextStyle(fontSize: 11, color: AppTheme.error)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _txnTile(Map<String, dynamic> t) {
    final type = t['transaction_type'] ?? '';
    final gross = (t['gross_amount'] as num?)?.toDouble() ?? 0;
    final net = (t['net_amount'] as num?)?.toDouble() ?? 0;
    final fee = (t['platform_fee'] as num?)?.toDouble() ?? 0;
    final isCredit = type == 'RECHARGE' ||
        type == 'ADMIN_CASH' ||
        type == 'ADJUSTMENT' ||
        type == 'REFUND' ||
        type == 'DEPOSIT';
    final color = isCredit ? AppTheme.success : AppTheme.error;
    final sign = isCredit ? '+' : '-';
    final date = t['created_at'] != null
        ? DateTime.parse(t['created_at'])
        : DateTime.now();
    // One-time activation: the registration fee consumed this entire first
    // recharge (fee == amount, nothing credited). Without this special case
    // the row reads "Recharge +100.00 / Fee: 100.00" with no explanation and
    // looks like a crediting bug.
    // (net == 0 exactly: the activation branch writes credit = amount - fee,
    // which is 0 only when the fee consumed the entire recharge.)
    final isActivation = type == 'RECHARGE' && fee > 0 && net == 0;

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
              color: color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              isActivation
                  ? Icons.verified_outlined
                  : (isCredit ? Icons.arrow_downward : Icons.arrow_upward),
              color: color,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    isActivation
                        ? 'Registration Fee Activation'
                        : _txnLabel(type),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                    '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
                if (isActivation) ...[
                  const SizedBox(height: 2),
                  const Text(
                      'One-time registration fee — 0.00 credited. Your next recharge credits in full.',
                      style:
                          TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                ],
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('$sign${gross.toStringAsFixed(2)} ETB',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: color)),
              if (isActivation)
                Text('0.00 credited',
                    style: const TextStyle(
                        fontSize: 10, color: AppTheme.textMuted))
              else if (fee > 0)
                Text(
                    'Fee: ${fee.toStringAsFixed(2)} · Credited: ${net.toStringAsFixed(2)}',
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
      case 'RECHARGE':
        return 'Recharge';
      case 'ADMIN_CASH':
        return 'Cash Recharge';
      case 'TRANSACTION_FEE':
        return 'Transaction Fee';
      case 'SUBSCRIPTION_FEE':
        return 'Subscription Fee';
      case 'ADJUSTMENT':
        return 'Adjustment';
      case 'REFUND':
        return 'Refund';
      case 'DEPOSIT':
        return 'Deposit';
      case 'WITHDRAWAL':
        return 'Withdrawal';
      default:
        return type;
    }
  }
}
