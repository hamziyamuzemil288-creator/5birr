import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';

/// Waiting screen shown when an order could not be placed because the
/// provider's wallet balance is 0 (they cannot cover the transaction fee)
/// or their account is not yet activated.
///
/// Real backing timer: a wall-clock deadline (DateTime.now() + 3 minutes)
/// drives both the visible countdown and the auto-redirect, and is re-checked
/// on every app lifecycle resume — so a brief backgrounding still cancels or
/// redirects at the correct moment. The user can cancel at any time.
class ProviderOrderWaitingScreen extends StatefulWidget {
  final String providerId;
  final String providerName;
  final bool providerNotActivated;

  const ProviderOrderWaitingScreen({
    super.key,
    required this.providerId,
    required this.providerName,
    this.providerNotActivated = false,
  });

  @override
  State<ProviderOrderWaitingScreen> createState() =>
      _ProviderOrderWaitingScreenState();
}

class _ProviderOrderWaitingScreenState
    extends State<ProviderOrderWaitingScreen>
    with WidgetsBindingObserver {
  static const _timeout = Duration(minutes: 3);

  late DateTime _deadline;
  Timer? _ticker;
  Duration _remaining = _timeout;
  bool _resolved = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deadline = DateTime.now().add(_timeout);
    _startTicker();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_resolved) {
      // The ticker may have been suspended while backgrounded — re-evaluate
      // the wall-clock deadline immediately on resume.
      _evaluateDeadline();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_resolved || !mounted) return;
      _evaluateDeadline();
    });
  }

  void _evaluateDeadline() {
    final left = _deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      if (_resolved) return;
      _resolved = true;
      _ticker?.cancel();
      // No resolution within 3 minutes — send the user back to find another
      // product/provider.
      if (mounted) {
        context.go('/user');
      }
      return;
    }
    if (mounted) setState(() => _remaining = left);
  }

  /// Re-check the provider's wallet: once they recharge (balance > 0 and
  /// activated), the user can proceed back to checkout immediately.
  Future<void> _recheck() async {
    if (_checking || _resolved) return;
    _checking = true;
    try {
      final client = Supabase.instance.client;
      final prov = await client
          .from('public_provider_profiles')
          .select('id, registration_fee_paid, status')
          .eq('id', widget.providerId)
          .maybeSingle();
      if (prov == null) return;
      final activated =
          (prov['registration_fee_paid'] as bool?) == true &&
              prov['status'] == 'APPROVED';
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'] as String)
          .maybeSingle();
      final balance = (wallet?['balance'] as num?)?.toDouble() ?? 0;
      if (activated && balance > 0 && mounted) {
        _resolved = true;
        _ticker?.cancel();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('The provider is ready — you can place your order now')));
        context.pop();
      }
    } catch (_) {
      // Non-fatal: the periodic re-check will try again.
    } finally {
      _checking = false;
    }
  }

  void _cancelWait() {
    _resolved = true;
    _ticker?.cancel();
    // Back to the dashboard/search so the user can pick another product.
    context.go('/user');
  }

  String get _countdown {
    final m = _remaining.inMinutes;
    final s = _remaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Waiting for provider')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppTheme.gold.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.hourglass_top_rounded,
                    size: 40, color: AppTheme.gold),
              ),
              const SizedBox(height: 24),
              Text(
                widget.providerNotActivated
                    ? '${widget.providerName} has not completed account activation yet'
                    : '${widget.providerName} needs to recharge their wallet',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                widget.providerNotActivated
                    ? 'This provider has not paid the one-time registration fee, so they cannot accept your order right now. We let them know — your order will be ready once they activate.'
                    : 'This provider\'s wallet balance is 0, so they cannot accept new orders right now. We notified them to recharge. Your order will go through once they top up.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary, height: 1.5),
              ),
              const SizedBox(height: 28),
              Text(
                'Redirecting to browse other products in $_countdown',
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textMuted),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _remaining.inSeconds / _timeout.inSeconds,
                  minHeight: 6,
                  backgroundColor: AppTheme.creamDark,
                  valueColor:
                      const AlwaysStoppedAnimation(AppTheme.primaryGreen),
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'CHECK AGAIN',
                  isLoading: _checking,
                  onPressed: _recheck,
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _cancelWait,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: AppTheme.cardBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Cancel and browse other products',
                      style: TextStyle(
                          fontSize: 14, color: AppTheme.textSecondary)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
