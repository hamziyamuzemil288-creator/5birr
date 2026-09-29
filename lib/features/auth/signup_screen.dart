import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/captcha_service.dart';
import '../../core/services/otp_service.dart';
import '../../core/services/city_service.dart';
import '../../core/utils/phone_formatter.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/google_sign_in_button.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/utils/friendly_error.dart';
import 'terms_policy_screen.dart';
import 'otp_verification_screen.dart';

enum SignupRole { user, vehicleProvider, serviceProvider }

class SignupScreen extends ConsumerStatefulWidget {
  final SignupRole role;
  const SignupScreen({super.key, required this.role});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // Phase 1: required city — persisted on the profile and used to scope
  // home/browse queries. Defaults to the service fallback city.
  String? _selectedCity;

  // Task 7: Kebele + Street/Road (after City) — GPS accuracy + identity
  // verification; stored on profiles via the signup metadata.
  final _kebeleController = TextEditingController();
  final _streetRoadController = TextEditingController();

  // Task 8: optional referral code (providers only) — identifies the
  // sales/staff person who registered this provider. Never required; the
  // server resolves it against referral_codes at account creation.
  final _referralController = TextEditingController();
  String? _referralHint; // live lookup result: "Referred by: <name>"

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  bool _captchaRequired = false;
  String? _captchaId;
  String? _error;

  // Whether a new account must prove an email OTP before it can be created.
  // Defaults to true: if the lookup never completes, the screen asks for a
  // code rather than skipping a gate the server may still enforce. The
  // captcha rides along with it — the challenge exists to throttle OTP
  // requests, so asking a visitor to solve one when no email is ever sent
  // is friction for nothing.
  bool _otpRequired = true;

  // Terms & Privacy agreement (Behavior 5): required before the submit
  // button enables. Acceptance is stored on the profile (0039) right after
  // the account exists, with the version the user actually saw.
  bool _agreedToTerms = false;

  // Task 9: the document-type choice was removed from signup (it was a
  // leftover from before the Task 3 correction). Providers now choose the
  // document type AND upload the document in the same step, at the first
  // protected action after wallet recharge (see ProviderDocGate).

  bool get _isProvider =>
      widget.role == SignupRole.vehicleProvider ||
      widget.role == SignupRole.serviceProvider;

  String get _roleName {
    switch (widget.role) {
      case SignupRole.user:
        return 'User';
      case SignupRole.vehicleProvider:
        return 'Vehicle Provider';
      case SignupRole.serviceProvider:
        return 'Service Provider';
    }
  }

  String get _providerType {
    switch (widget.role) {
      case SignupRole.vehicleProvider:
        return 'VEHICLE_PROVIDER';
      case SignupRole.serviceProvider:
        return 'SERVICE_PROVIDER';
      default:
        return '';
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSignupRequirements();
  }

  Future<void> _loadSignupRequirements() async {
    // Both lookups run concurrently; neither blocks the other, and neither
    // can fail the screen.
    final results = await Future.wait([
      CaptchaService.instance.isRequired(),
      OtpService.isRequiredAtSignup(),
    ]);
    if (!mounted) return;
    final otpRequired = results[1];
    setState(() {
      _otpRequired = otpRequired;
      _captchaRequired = results[0] && otpRequired;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _kebeleController.dispose();
    _streetRoadController.dispose();
    _referralController.dispose();
    super.dispose();
  }

  Timer? _referralDebounce;

  /// Live lookup: shows "Referred by: <name>" while the code matches an
  /// active staff code. Failures are silent — the server re-checks at
  /// signup and an unknown code must never block registration (Task 8).
  void _lookupReferral() {
    _referralDebounce?.cancel();
    final code = _referralController.text.trim();
    if (code.isEmpty) {
      if (mounted && _referralHint != null)
        setState(() => _referralHint = null);
      return;
    }
    _referralDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final name = await Supabase.instance.client
            .rpc('validate_referral_code', params: {'p_code': code});
        if (!mounted) return;
        setState(() {
          _referralHint = (name is String && name.isNotEmpty)
              ? 'Referred by: $name ✓'
              : 'Code not recognized — you can still continue without it.';
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _referralHint = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              // Gradient header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
                    stops: [0.0, 1.0],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Back button
                      GestureDetector(
                        onTap: () => context.go('/role-select'),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '$_roleName Registration',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.25,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isProvider
                            ? 'Register now — verify your ID when you start selling'
                            : 'Create your account to get started',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                          color: Colors.white.withOpacity(0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Form content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildFormFields(),
                        const SizedBox(height: 12),
                        if (_error != null)
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
                        const SizedBox(height: 24),
                        // Terms & Privacy agreement (final step, every flow).
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: _agreedToTerms,
                                activeColor: AppTheme.primaryGreen,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: (v) =>
                                    setState(() => _agreedToTerms = v ?? false),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  const Text('I agree to the ',
                                      style: AppTheme.bodyMedium),
                                  GestureDetector(
                                    onTap: () =>
                                        context.push('/terms', extra: true),
                                    child: const Text('Terms & Privacy Policy',
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.teal,
                                            decoration:
                                                TextDecoration.underline,
                                            decorationColor: AppTheme.teal)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (_captchaRequired) ...[
                          const SizedBox(height: 16),
                          CaptchaChallengeField(
                            onVerified: (id) => setState(() => _captchaId = id),
                          ),
                        ],
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            label: 'CONTINUE',
                            isLoading: _isLoading,
                            onPressed: _agreedToTerms &&
                                    (!_captchaRequired || _captchaId != null)
                                ? _handleSubmit
                                : null,
                          ),
                        ),
                        // Task 15: Google OAuth signup — the provider-
                        // verified email replaces the OTP step for these
                        // accounts; admin approval still gates the account,
                        // so this button intentionally ignores the CAPTCHA
                        // and terms flow (Google users confirm terms via
                        // the standard approval pipeline).
                        const SizedBox(height: 12),
                        GoogleSignInButton(
                          isLoading: _isLoading,
                          onPressed: _handleGoogleSignUp,
                        ),
                        const SizedBox(height: 16),
                        // Sign in link
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text('Already have an account? ',
                                style: TextStyle(
                                    fontSize: 14,
                                    color: AppTheme.textSecondary)),
                            GestureDetector(
                              onTap: () => context.go('/login'),
                              child: const Text('Sign In',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: AppTheme.teal)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.black26,
              child: Center(
                child: Container(
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
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppTheme.primaryGreen),
                      SizedBox(height: 16),
                      Text(
                        'Creating account...',
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Validate the form, then hand the user to email verification. The
  /// account is only created AFTER the 6-digit code is verified — the
  /// server (handle_new_user trigger) refuses signups without one.
  /// Task 15: Google OAuth signup. The consent screen runs in the browser;
  /// the deep link returns the session and the OAuth-aware signup trigger
  /// (20260925000000) creates the account PENDING_APPROVAL, same pipeline
  /// as email signups minus the OTP email step.
  Future<void> _handleGoogleSignUp() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWithGoogle();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not start Google sign-in. Please try again.';
        });
      }
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_agreedToTerms) {
      setState(() => _error =
          'Please read and accept the Terms & Privacy Policy to continue.');
      return;
    }
    if (_captchaRequired && _captchaId == null) {
      setState(() =>
          _error = 'Please complete the security check before continuing.');
      return;
    }

    // Park everything the account-creation step will need; the OTP screen
    // hands it back when the code is verified (and is never opened when the
    // OTP is switched off).
    final draft = SignupDraft(
      rolePath: switch (widget.role) {
        SignupRole.user => 'user',
        SignupRole.vehicleProvider => 'vehicle-provider',
        SignupRole.serviceProvider => 'service-provider',
      },
      name: _nameController.text.trim(),
      email: _emailController.text.trim().toLowerCase(),
      phone: _phoneController.text.trim(),
      password: _passwordController.text,
      city: _selectedCity,
      kebele: _kebeleController.text.trim(),
      streetRoad: _streetRoadController.text.trim(),
      nationalIdNumber: null,
      referralCode: _isProvider ? _referralController.text.trim() : null,
      captchaId: _captchaId,
    );

    // Ask for a code only while the server is asking for one. When the OTP
    // is switched off (the email provider is unconfigured) the account is
    // created immediately and waits for admin approval instead — which is
    // the gate that has always protected a new account.
    if (_otpRequired) {
      final verified = await context.push<bool>(
        '/otp-verify',
        extra: OtpArgs(draft: draft),
      );
      if (verified != true || !mounted) return;
    }
    // Code verified — create the account now.
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (_isProvider) {
        await ref.read(authProvider.notifier).signUpAsProvider(
              email: draft.email,
              phone: draft.phone,
              password: draft.password,
              businessName: draft.name,
              providerType: _providerType,
              city: draft.city,
              kebele: draft.kebele,
              streetRoad: draft.streetRoad,
              referralCode: draft.referralCode,
            );
      } else {
        await ref.read(authProvider.notifier).signUp(
              email: draft.email,
              phone: draft.phone,
              password: draft.password,
              fullName: draft.name,
              role: AppUserRole.user,
              city: draft.city,
              kebele: draft.kebele,
              streetRoad: draft.streetRoad,
            );
      }

      // Admin approval is the account gate (email confirmation is disabled
      // in Supabase Auth), so signUp() returns a session immediately and the
      // handle_new_user() trigger has already created the profile in
      // PENDING_APPROVAL status. Go straight to the waiting screen.
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      if (!mounted) return;

      if (!hasSession) {
        // Defensive: only possible if email confirmation gets re-enabled
        // in Supabase Auth. The account was still created — send the user
        // to sign in instead of pretending registration failed.
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Account created. Please sign in to continue.')),
        );
        context.go('/login');
        return;
      }

      // Record the user's terms acceptance (version + timestamp) on the
      // profile now that a session exists. Best-effort, never blocks.
      try {
        await Supabase.instance.client
            .rpc('accept_terms', params: {'p_version': kTermsVersion});
      } catch (_) {
        // Non-fatal: the account itself was already created successfully.
      }

      context.go('/pending-approval');
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = _friendlyError(e.toString());
        });
      }
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('already registered') ||
        raw.contains('already exists') ||
        raw.contains('duplicate')) {
      return 'An account with this email already exists.';
    }
    if (raw.contains('Password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Please check your connection.';
    }
    if (raw.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (raw.contains('EMAIL_OTP_REQUIRED')) {
      return 'Email verification expired. Please verify your email again.';
    }
    // See login_screen: the old fallthrough returned 'Registration failed:
    // $raw' and leaked the raw exception to anyone who could not register.
    return friendlyError(raw, context: 'Could not create your account');
  }

  Widget _buildFormFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Personal Information', style: AppTheme.sectionHeader),
        const SizedBox(height: 4),
        const Text(
          'Fill in your details to create your account',
          style: AppTheme.caption,
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: _isProvider ? 'Business / Owner Name' : 'Full Name',
          controller: _nameController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Name is required';
            if (v.trim().length < 2) return 'Name is too short';
            return null;
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          value: _selectedCity,
          decoration: const InputDecoration(
            labelText: 'City *',
            hintText: 'Select your city',
            prefixIcon: Icon(Icons.location_city_outlined),
          ),
          items: CityService.knownCities
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          validator: (v) =>
              (v == null || v.isEmpty) ? 'City is required' : null,
          onChanged: (v) => setState(() => _selectedCity = v),
        ),
        const SizedBox(height: 16),
        // Task 7: Kebele + Street/Road right after City — used for GPS
        // tracking accuracy and identity verification.
        BirrTextField(
          label: 'Kebele',
          hint: 'e.g. Kebele 08',
          controller: _kebeleController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Kebele is required';
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Street / Road',
          hint: 'e.g. Bole Road, near Edna Mall',
          controller: _streetRoadController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Street / Road is required';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Email',
          hint: 'you@example.com',
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Email is required';
            }
            if (!v.contains('@') || !v.contains('.')) {
              return 'Enter a valid email address';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Phone Number',
          hint: '0912345678',
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Phone number is required';
            }
            return PhoneFormatter.validateEthiopianPhone(v);
          },
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 4),
          child: Text(
            'Ethiopian numbers only — enter as 0912345678, +251912345678, or 251912345678',
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ),
        const SizedBox(height: 16),
        // No National ID is collected at registration, for ANY role. ID
        // verification happens later and inside the app: the document is
        // uploaded in the verification step (user_documents) before a
        // provider may upload a product or a vehicle provider may claim a
        // ride, which is the same gate a user hits before booking. Asking for
        // it here collected a number nobody could check against the document.
        if (_isProvider) ...[
          // Task 8: optional referral code — identifies the sales/staff
          // person who registered this provider. Empty = self-registered;
          // an unknown code never blocks registration (kept as "Other").
          BirrTextField(
            label: 'Referral Code (optional)',
            hint: 'From the sales person who signed you up',
            controller: _referralController,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _lookupReferral(),
          ),
          if (_referralHint != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(_referralHint!, style: AppTheme.caption),
            ),
          ],
          const SizedBox(height: 16),
        ],
        BirrTextField(
          label: 'Password',
          controller: _passwordController,
          obscure: _obscurePassword,
          textInputAction: TextInputAction.next,
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: AppTheme.textMuted,
              size: 20,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Password is required';
            if (v.length < 6) return 'Password must be at least 6 characters';
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Confirm Password',
          controller: _confirmPasswordController,
          obscure: _obscureConfirm,
          textInputAction: TextInputAction.done,
          onEditingComplete: _handleSubmit,
          suffixIcon: IconButton(
            icon: Icon(
              _obscureConfirm
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: AppTheme.textMuted,
              size: 20,
            ),
            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Please confirm your password';
            if (v != _passwordController.text) return 'Passwords do not match';
            return null;
          },
        ),
      ],
    );
  }
}
