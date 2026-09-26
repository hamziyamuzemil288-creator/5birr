import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/captcha_service.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/google_sign_in_button.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/services/login_identity.dart';
import '../../core/services/staff_admin_service.dart';
import '../../core/services/staff_gateway_service.dart';
import '../auth/admin_gate.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;
  // Task 13 item 2: the login page is an attack surface too — enforce the
  // same server-side CAPTCHA as signup/OTP/appeals, plus the failure lockout.
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
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// One staff-gateway attempt. Never throws — failures come back as false so
  /// the caller can decide what to say.
  ///
  /// Admin-created staff have no ordinary Supabase identity: their auth
  /// account's email is a server-derived synthetic address, so the normal
  /// email sign-in can never match them. The gateway is the only door.
  Future<bool> _staffSignIn(String username) async {
    try {
      await const StaffGatewayService()
          .signIn(username: username, password: _passwordController.text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    final identifier = _emailController.text.trim();
    final isStaff = classifyLoginIdentifier(identifier) ==
        LoginIdentityKind.staffUsername;
    // The gate keys CAPTCHA + lockout per account identity. Bare staff
    // usernames are normalized to the same synthetic address the gateway
    // derives for them so the gate (which requires an "@") can enforce
    // staff logins too — NO login path skips CAPTCHA/lockout.
    final gateKey = isStaff ? staffLoginGateKey(identifier) : identifier;

    if (_captchaRequired && _captchaId == null) {
      setState(() => _error = 'Complete the security check before signing in.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });

    // 1. Server gate BEFORE the credential check — staff included: consumes
    //    the CAPTCHA and enforces the failure lockout. Fail closed on any
    //    gate problem.
    try {
      await CaptchaService.instance
          .gateLogin(email: gateKey, captchaId: _captchaId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          // login-gate consumes the challenge before checking credentials.
          // Never leave a green, already-consumed challenge on screen.
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
      return;
    }

    // ── Staff gateway credentials ──
    // A bare username (no "@") is unambiguously staff: send it to the
    // gateway instead of the email path, which would both reject the shape
    // and (even if it did not) fail against the synthetic identity. This is
    // the path that makes an admin-created staff account usable the moment
    // it exists — and it now runs behind the same gate as everything else.
    if (isStaff) {
      final ok = await _staffSignIn(identifier);
      await CaptchaService.instance.recordLoginAttempt(
        email: gateKey,
        success: ok,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _isLoading = false;
          // The gate consumed the challenge; never leave it on screen.
          _captchaId = null;
          _captchaResetVersion++;
          _error = 'Invalid username or password.';
        });
      }
      // On success the auth listener loads the profile and the router
      // forwards the staff member to /staff/dashboard; leaving the button in
      // its loading state until then avoids a flash of an idle form.
      return;
    }

    final email = identifier;
    try {
      try {
        // 2. The credential check itself (the gate already ran above).
        await ref.read(authProvider.notifier).signIn(
              email: email,
              password: _passwordController.text,
            );
        // signedIn is picked up by the auth listener; still clear the
        // failure window server-side so one typo never bites later.
        await CaptchaService.instance.recordLoginAttempt(
          email: email,
          success: true,
        );
      } catch (signInError) {
        // A staff username MAY itself be an email address, and those accounts
        // have no ordinary Supabase identity either — so give the gateway one
        // chance with the same input before reporting a failure. Only count a
        // failure once BOTH doors have rejected the credentials: recording it
        // before the fallback would log a false failure on every successful
        // email-shaped staff login and push the account toward lockout.
        if (await _staffSignIn(identifier)) {
          // Clear the failed-attempt window for this identity — the ordinary
          // rejection above was not a real credential failure.
          await CaptchaService.instance.recordLoginAttempt(
            email: email,
            success: true,
          );
          return;
        }
        await CaptchaService.instance.recordLoginAttempt(
          email: email,
          success: false,
        );
        rethrow;
      }
      if (mounted) {
        // Router redirect will handle navigation
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          // login-gate consumes the challenge before checking credentials.
          // Never leave a green, already-consumed challenge on screen after
          // a failed password attempt or any other completed gate attempt.
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
    }
  }

  /// Task 15: open the Google consent screen. The session comes back via
  /// the auth listener (deep link) — failures surface as readable errors.
  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWithGoogle();
      // The OAuth round-trip continues in the browser; the router navigates
      // once the deep link delivers the session.
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not start Google sign-in. Please try again.';
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
    if (raw.contains('temporarily_locked')) {
      return 'Too many failed attempts. Try again in 15 minutes.';
    }
    if (raw.contains('Invalid login credentials')) {
      return 'Invalid email or password.';
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Please check your connection.';
    }
    if (raw.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    return 'Login failed: $raw';
  }

  /// Password reset: ask for the email, send the recovery link. The link
  /// opens the app (deep link in AndroidManifest) and lands the user on
  /// /update-password via the passwordRecovery auth event.
  void _showForgotPasswordSheet() {
    final emailController =
        TextEditingController(text: _emailController.text.trim());
    var sending = false;
    var sent = false;
    String? sheetError;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, 24 + MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Reset Password', style: AppTheme.heading),
              const SizedBox(height: 8),
              const Text(
                'Enter your account email and we will send you a link to '
                'set a new password.',
                style: AppTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              BirrTextField(
                label: 'Email',
                hint: 'you@example.com',
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
              ),
              if (sheetError != null) ...[
                const SizedBox(height: 12),
                Text(sheetError!,
                    style:
                        const TextStyle(fontSize: 13, color: AppTheme.error)),
              ],
              if (sent) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: AppTheme.success, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Reset link sent — check your email (and the spam '
                        'folder). The link opens this app.',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.success),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: sent ? 'RESEND LINK' : 'SEND RESET LINK',
                  isLoading: sending,
                  onPressed: () async {
                    final email = emailController.text.trim();
                    if (email.isEmpty ||
                        !email.contains('@') ||
                        !email.contains('.')) {
                      setSheetState(
                          () => sheetError = 'Enter a valid email address');
                      return;
                    }
                    setSheetState(() {
                      sending = true;
                      sheetError = null;
                    });
                    try {
                      await ref
                          .read(authProvider.notifier)
                          .resetPassword(email: email);
                      setSheetState(() {
                        sending = false;
                        sent = true;
                      });
                    } catch (_) {
                      setSheetState(() {
                        sending = false;
                        sheetError = 'Could not send the email. Check your '
                            'connection and try again.';
                      });
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
            stops: [0.0, 0.35],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 56),
                // Logo
                AdminGate(
                  onUnlocked: () => context.go('/admin-login'),
                  child: Image.asset(
                    'assets/images/aliob_logo_mark.png',
                    width: 84,
                    height: 84,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Aliob',
                    style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 4,
                        height: 1.1)),
                const SizedBox(height: 8),
                Text('All in one',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withOpacity(0.75),
                        letterSpacing: 2)),
                const SizedBox(height: 36),
                // Login card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Welcome Back',
                            style: AppTheme.headingLarge),
                        const SizedBox(height: 6),
                        const Text('Sign in to your account',
                            style: AppTheme.bodyMedium),
                        const SizedBox(height: 24),
                        // Accepts an account email OR a staff username — an
                        // admin-created staff member types the username they
                        // were given, which is not an email.
                        BirrTextField(
                          label: 'Email or staff username',
                          hint: 'you@example.com or staff username',
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            final value = v?.trim() ?? '';
                            if (value.isEmpty) {
                              return 'Email or username is required';
                            }
                            if (classifyLoginIdentifier(value) ==
                                    LoginIdentityKind.email ||
                                isValidStaffUsername(value)) {
                              return null;
                            }
                            return 'Enter a valid email or staff username';
                          },
                        ),
                        const SizedBox(height: 16),
                        BirrTextField(
                          label: 'Password',
                          controller: _passwordController,
                          obscure: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          onEditingComplete: _handleLogin,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: AppTheme.textMuted,
                              size: 20,
                            ),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Password is required';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _showForgotPasswordSheet,
                            child: const Text('Forgot Password?'),
                          ),
                        ),
                        // Task 13 item 2: same tick+math CAPTCHA as signup,
                        // enforced server-side by the login-gate function.
                        if (_captchaRequired) ...[
                          CaptchaChallengeField(
                            key: ValueKey(_captchaResetVersion),
                            onVerified: (id) => setState(() => _captchaId = id),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppTheme.error.withOpacity(0.2)),
                            ),
                            child: Text(_error!,
                                style: const TextStyle(
                                    fontSize: 13, color: AppTheme.error)),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            label: 'LOGIN',
                            isLoading: _isLoading,
                            onPressed: _handleLogin,
                          ),
                        ),
                        // Task 15: Google OAuth — same account pipeline as
                        // email signups (PENDING_APPROVAL until an admin
                        // approves); the provider-verified email replaces
                        // the OTP step for these accounts only.
                        const SizedBox(height: 12),
                        GoogleSignInButton(
                          isLoading: _isLoading,
                          onPressed: _handleGoogleSignIn,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Sign up link
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("Don't have an account? ",
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary)),
                    GestureDetector(
                      onTap: () => context.go('/role-select'),
                      child: const Text('Create Account',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.teal)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Explicit door for staff whose username IS an email address
                // (they cannot be told apart from a normal account by shape).
                // The gateway screen is otherwise reachable only after
                // signing in, which left staff created by the admin with no
                // way in at all.
                TextButton.icon(
                  onPressed: () => context.go('/staff/login'),
                  icon: const Icon(Icons.support_agent,
                      size: 16, color: AppTheme.textSecondary),
                  label: const Text('Staff / employee sign in',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 36),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
