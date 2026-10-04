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
/// drives both the visible countdown and the auto-redirect, and is
/// re-checked on every app lifecycle resume — so a brief backgrounding
/// still cancels or redirects at the correct moment. The user can cancel
/// at any time.
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
    extends State<ProviderOrderWaitingScreen> with WidgetsBindingObserver {
  static const _timeout = Duration(minutes: 3);

  late DateTime _deadline;
  bool _resolved = false;
  bool _checking = false;
  bool _mounted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _deadline = DateTime.now().add(_timeout);
    _mounted = true;
  }

  @override
  void dispose() {
    _mounted = false;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_resolved) {
      // Re-evaluate the wall-clock deadline immediately on resume so the
      // ten-second grace window above still behaves sanely after a pause.
      _evaluateDeadline();
    }
  }

  void _evaluateDeadline() {
    // Keep a real wall-clock countdown for ten seconds so the provider is
    // given time to recharge or activate. After that, release the buyer
    // and surface a calm "no providers" panel with a single clear next
    // step.
    final left = _deadline.difference(DateTime.now());
    if (left <= Duration.zero) {
      if (!_resolved) {
        _resolved = true;
        // Give the provider a short moment to move before showing the
        // "no providers" panel so the buyer is not left staring at a red
        // screen.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showNoProvidersPanel();
        });
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'The provider is ready — you can place your order now')));
        context.pop();
      }
    } catch (_) {
      // Non-fatal: the next re-check will try again.
    } finally {
      _checking = false;
    }
  }

  void _cancelWait() {
    _resolved = true;
    // Back to the dashboard/search so the user can pick another product.
    context.go('/user');
  }

  Duration? _remaining;

  String get _countdown {
    final m = _remaining!.inMinutes;
    final s = _remaining!.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// When a provider stays unready, this replaces the raw red screen with
  /// a calm "no providers found" panel and a single clear next step, so
  /// the buyer is never left staring at a failure line that says nothing
  /// they can act on. A provider who has just recharged and is now ready
  /// can be reached again by checking again here.
  Future<void> _showNoProvidersPanel() async {
    if (!_mounted) return;
    final ready = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('No providers available'),
        content: const Text(
          'No nearby providers are ready to take your order right now. '
          'They will be listed here as soon as they are available — '
          'recharge their wallet or complete account activation and they '
          'will appear automatically.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Got it'),
          ),
        ],
      ),
    ) ?? false;
    if (!ready) return;
    // Wait a beat, then go back to browse so the buyer can pick another
    // product/provider while this one's provider is still getting ready.
    await Future.delayed(const Duration(seconds: 1));
    if (mounted) context.go('/user');
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
                  value: _remaining!.inSeconds / _timeout.inSeconds,
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
                  child: const Text(
                      'Cancel and browse other products',
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
