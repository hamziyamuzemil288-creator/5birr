import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/subscription.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

/// Read-only view of a service provider's subscription.
///
/// The billing itself is not something the app performs. `subscription-process`
/// runs daily from n8n, reads the provider's own `subscriptions` row, charges
/// the wallet through `deduct_subscription_fee` (idempotent per
/// provider+period), and moves the row through ACTIVE -> DUE -> GRACE ->
/// SUSPENDED. This screen exists so the provider can see that state before
/// the deduction lands rather than discovering it as an unexplained balance
/// drop.
///
/// Deliberately read-only. The `subscriptions` table is protected by
/// `prevent_subscription_self_modification`, which refuses any status or
/// date change from a non-admin, so offering an edit control here would only
/// ever produce a server error. The one action a provider legitimately has
/// — topping the wallet up so the charge clears — is a link to /wallet.
class ProviderSubscriptionScreen extends StatefulWidget {
  const ProviderSubscriptionScreen({super.key});

  @override
  State<ProviderSubscriptionScreen> createState() => _State();
}

class _State extends State<ProviderSubscriptionScreen> {
  Subscription? _subscription;
  List<Map<String, dynamic>> _charges = [];
  num _monthlyFee = 0;
  num _graceDays = 3;
  num _walletBalance = 0;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Same resolution the other provider screens use: provider_profiles.id
      // is keyed on the auth user, and `subscriptions.provider_id` points at
      // that row, not at auth.users.
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();

      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final providerId = prov['id'] as String;

      final sub = await client
          .from('subscriptions')
          .select('*')
          .eq('provider_id', providerId)
          .maybeSingle();

      final charges = await client
          .from('wallet_transactions')
          .select('id, gross_amount, balance_after, created_at')
          .eq('provider_id', providerId)
          .eq('transaction_type', 'SUBSCRIPTION_FEE')
          .order('created_at', ascending: false)
          .limit(12);

      // Fee and grace period are business rules in system_settings. Providers
      // can read them (they need to know what they will be charged), and RLS
      // blocks any write, so this is a read-only lookup.
      num fee = 0;
      num grace = 3;
      try {
        final settings = await client
            .from('system_settings')
            .select('key, value')
            .inFilter('key', ['monthly_subscription_fee', 'subscription_grace_period_days']);
        for (final row in (settings as List).whereType<Map<String, dynamic>>()) {
          final raw = row['value'];
          // value is jsonb: seeded as a bare string ('5') but jsonb scalars
          // come back as num when the column holds a number.
          final parsed = raw is num
              ? raw
              : num.tryParse(raw?.toString() ?? '') ?? 0;
          if (row['key'] == 'monthly_subscription_fee') {
            fee = parsed;
          } else if (row['key'] == 'subscription_grace_period_days') {
            grace = parsed;
          }
        }
      } catch (_) {
        // Pricing is advisory here. If the lookup fails the screen still
        // works; it just cannot state the amount.
      }

      num balance = 0;
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', providerId)
          .maybeSingle();
      if (wallet != null) {
        final raw = wallet['balance'];
        balance = raw is num ? raw : num.tryParse('$raw') ?? 0;
      }

      if (!mounted) return;
      setState(() {
        _subscription =
            sub == null ? null : Subscription.fromJson(Map<String, dynamic>.from(sub as Map));
        _charges = List<Map<String, dynamic>>.from(charges as List);
        _monthlyFee = fee;
        _graceDays = grace;
        _walletBalance = balance;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your subscription');
      });
    }
  }

  /// Status colour, following the same status-driven approach the profile
  /// badge uses rather than a fixed colour.
  ({Color color, String label, String blurb}) get _status {
    final sub = _subscription;
    if (sub == null) {
      return (
        color: AppTheme.textSecondary,
        label: 'Not set up',
        blurb: 'No subscription is linked to this account yet.',
      );
    }
    if (sub.isSuspended) {
      return (
        color: AppTheme.error,
        label: 'Suspended',
        blurb:
            'Your account is suspended because a subscription payment was missed. Recharge your wallet and contact support to reactivate.',
      );
    }
    if (sub.isGrace) {
      return (
        color: AppTheme.warning,
        label: 'Payment overdue',
        blurb:
            'Your wallet did not have enough for the subscription fee. Recharge within ${_graceDays.toInt()} day(s) to avoid suspension.',
      );
    }
    if (sub.isOverdue || sub.isDue) {
      return (
        color: AppTheme.warning,
        label: 'Due',
        blurb: 'Your subscription fee will be charged from your wallet shortly.',
      );
    }
    return (
      color: AppTheme.success,
      label: 'Active',
      blurb: 'Your subscription is up to date.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      _statusCard(),
                      const SizedBox(height: 16),
                      if (_subscription != null) ...[
                        _detailsCard(),
                        const SizedBox(height: 16),
                      ],
                      _chargesCard(),
                    ],
                  ),
                ),
    );
  }

  Widget _statusCard() {
    final s = _status;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: s.color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: s.color, size: 22),
              const SizedBox(width: 8),
              Text(
                s.label,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: s.color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            s.blurb,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsCard() {
    final sub = _subscription!;
    final dateFmt = DateFormat('d MMM yyyy');
    final rows = <(String, String)>[
      ('Monthly fee', _monthlyFee > 0 ? '${_monthlyFee.toStringAsFixed(2)} ETB' : '—'),
      ('Next charge', dateFmt.format(sub.nextDueDate.toLocal())),
      (
        'Last charged',
        sub.lastChargedAt == null
            ? 'Not yet charged'
            : dateFmt.format(sub.lastChargedAt!.toLocal()),
      ),
      ('Wallet balance', '${_walletBalance.toStringAsFixed(2)} ETB'),
    ];

    // Nudge before the charge lands rather than letting it surprise them.
    final needsTopUp = _walletBalance < _monthlyFee && _monthlyFee > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Billing',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            if (needsTopUp) ...[
              const SizedBox(height: 12),
              Text(
                'Your wallet balance is below this month\'s fee. Top up to keep your account active.',
                style: TextStyle(fontSize: 13, color: AppTheme.warning, height: 1.4),
              ),
            ],
            if (needsTopUp) ...[
              const SizedBox(height: 16),
              PrimaryButton(
                label: 'Recharge wallet',
                icon: Icons.account_balance_wallet_outlined,
                onPressed: () => context.push('/wallet/recharge'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chargesCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Charge history',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            const Text(
              'Subscription fees already deducted from your wallet.',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),
            if (_charges.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'No subscription charges yet.',
                    style: TextStyle(fontSize: 14, color: AppTheme.textMuted),
                  ),
                ),
              )
            else
              for (final c in _charges)
                Builder(builder: (context) {
                  final amount = (c['gross_amount'] as num?)?.toStringAsFixed(2) ?? '0.00';
                  final when = DateTime.tryParse('${c['created_at']}')?.toLocal();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              when == null
                                  ? '—'
                                  : DateFormat('d MMM yyyy').format(when),
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Subscription fee',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '-$amount ETB',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
          ],
        ),
      ),
    );
  }
}

/// Full-screen error with a retry, matching the pattern the other provider
/// screens use. The user is never left staring at a dead page.
class _ErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    // PrimaryButton takes a VoidCallback; this wraps the async retry so the
    // button's own isLoading state cannot be driven from a Future.
    void retry() {
      onRetry();
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: 'Retry',
              icon: Icons.refresh,
              onPressed: retry,
            ),
          ],
        ),
      ),
    );
  }
}
