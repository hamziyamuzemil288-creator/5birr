import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/captcha_service.dart';
import '../../core/services/login_identity.dart';
import '../../core/services/staff_admin_service.dart';
import '../../core/services/staff_gateway_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/primary_button.dart';

class StaffLoginScreen extends ConsumerStatefulWidget {
  const StaffLoginScreen({super.key});

  @override
  ConsumerState<StaffLoginScreen> createState() => _StaffLoginScreenState();
}

class _StaffLoginScreenState extends ConsumerState<StaffLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _service = const StaffGatewayService();
  bool _loading = false;
  bool _obscure = true;
  String? _error;
  // This screen is a login path too: it runs behind the SAME server-side
  // CAPTCHA + failure lockout as the main login (no staff bypass).
  bool _captchaRequired = true; // conservative default until the server says
  String? _captchaId;
  int _captchaResetVersion = 0;

  @override
  void initState() {
    super.initState();
    // A lookup failure defaults to true (fail closed), matching the service.
    CaptchaService.instance.isRequired().then((required) {
      if (mounted) setState(() => _captchaRequired = required);
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final identifier = _username.text.trim();
    // Same key scheme as the main login: bare usernames are normalized to
    // the synthetic staff address the gate accepts, email-shaped ones pass
    // through — so CAPTCHA consumption and the lockout track this account.
    final gateKey = staffLoginGateKey(identifier);

    if (_captchaRequired && _captchaId == null) {
      setState(() => _error = 'Complete the security check before signing in.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    // Server gate BEFORE the credential check: consumes the CAPTCHA and
    // enforces the shared failure lockout. Fails CLOSED on any gate problem.
    try {
      await CaptchaService.instance
          .gateLogin(email: gateKey, captchaId: _captchaId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          // login-gate consumes the challenge before checking credentials;
          // never leave a green, already-consumed challenge on screen.
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
      return;
    }

    try {
      await _service.signIn(
        username: identifier,
        password: _password.text,
      );
      // Clear the failure window server-side so one typo never bites later.
      await CaptchaService.instance
          .recordLoginAttempt(email: gateKey, success: true);
      if (mounted) context.go('/staff/dashboard');
    } catch (e) {
      await CaptchaService.instance
          .recordLoginAttempt(email: gateKey, success: false);
      if (mounted) {
        setState(() {
          _loading = false;
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
    }
  }

  String _friendlyError(String raw) {
    // Gate/lockout messages are already written for the user.
    if (raw.contains('Too many failed attempts') ||
        raw.contains('security check')) {
      return raw;
    }
    if (raw.contains('invalid_credentials')) {
      return 'Invalid username or password.';
    }
    if (raw.contains('login_unavailable')) {
      return 'Staff sign-in is temporarily unavailable. Try again shortly.';
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Check your connection and try again.';
    }
    return 'Could not sign in. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff Gateway')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.support_agent,
                        size: 64, color: AppTheme.primaryGreen),
                    const SizedBox(height: 18),
                    const Text(
                      'Staff sign in',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Use the username or email and password provided by '
                      'the CEO.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    BirrTextField(
                      label: 'Username or email',
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.none,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Username is required';
                        }
                        if (!isValidStaffUsername(value)) {
                          return kStaffUsernameHint;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    BirrTextField(
                      label: 'Password',
                      controller: _password,
                      obscure: _obscure,
                      textInputAction: TextInputAction.done,
                      onEditingComplete: _login,
                      suffixIcon: IconButton(
                        icon: Icon(_obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                      validator: (value) => value == null || value.isEmpty
                          ? 'Password is required'
                          : null,
                    ),
                    if (_captchaRequired) ...[
                      const SizedBox(height: 14),
                      // Same tick+math CAPTCHA as the main login, enforced
                      // server-side by the login-gate function.
                      CaptchaChallengeField(
                        key: ValueKey(_captchaResetVersion),
                        onVerified: (id) => setState(() => _captchaId = id),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppTheme.error),
                      ),
                    ],
                    const SizedBox(height: 22),
                    PrimaryButton(
                      label: 'SIGN IN',
                      isLoading: _loading,
                      onPressed: _login,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => context.go('/login'),
                      child: const Text('Back to user login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
