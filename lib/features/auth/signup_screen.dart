import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/document_upload_service.dart';
import '../../core/utils/phone_formatter.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/document_upload_card.dart';
import 'terms_policy_screen.dart';

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
  final _nationalIdController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  String? _error;

  // Terms & Privacy agreement (Behavior 5): required before the submit
  // button enables. Acceptance is stored on the profile (0039) right after
  // the account exists, with the version the user actually saw.
  bool _agreedToTerms = false;

  File? _nationalIdImage;
  File? _licenseImage;
  bool _uploadingDocs = false;
  String? _uploadError;

  final _picker = ImagePicker();
  final _supabase = Supabase.instance.client;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _nationalIdController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

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

  Future<void> _pickImage(ImageSource source, bool isNationalId) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked != null) {
        final file = File(picked.path);
        final size = await file.length();
        if (size > 10 * 1024 * 1024) {
          setState(() => _uploadError = 'Image must be under 10 MB');
          return;
        }
        setState(() {
          if (isNationalId) {
            _nationalIdImage = file;
          } else {
            _licenseImage = file;
          }
          _uploadError = null;
        });
      }
    } catch (e) {
      setState(() => _uploadError = 'Failed to pick image');
    }
  }

  void _showImagePicker(bool isNationalId) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Camera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera, isNationalId);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery, isNationalId);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when the account itself was created but document storage failed.
  /// The error must reach the user (and support), never disappear silently.
  /// [router]/[messenger] are captured at method entry so this still works
  /// when navigation has disposed the signup screen mid-flight.
  Future<void> _showDocumentUploadError(
    Object error,
    GoRouter router,
    ScaffoldMessengerState messenger,
  ) async {
    // Report even if navigation has disposed this screen: the pending-
    // approval screen offers a recovery action for exactly this case.
    final message = _documentErrorText(error);
    if (!mounted) {
      router.push(
          '/pending-approval?resumeDocUpload=true&docError=${Uri.encodeComponent(message)}');
      return;
    }
    setState(() => _uploadingDocs = false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Documents not uploaded'),
        content: Text(
          'Your account was created, but your documents could not be '
          'uploaded, so verification cannot start yet.\n\n'
          'Reason: $message\n\n'
          'Please contact support — they will help you finish verification. '
          'You can also retry from the pending-approval screen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  /// Human-readable, secret-free text for a document pipeline failure.
  String _documentErrorText(Object error) {
    if (error is PostgrestException) {
      final details = error.details?.toString();
      return 'database error ${error.code}: ${error.message}'
          '${details == null || details.isEmpty ? '' : ' — $details'}';
    }
    if (error is StorageException) {
      return 'storage error: ${error.message}';
    }
    return error.toString();
  }

  /// Records the user's terms acceptance on their profile. Best-effort:
  /// a failure here never blocks the account that was just created, but it
  /// is surfaced so consent can be re-confirmed on next launch.
  Future<void> _recordTermsAcceptance() async {
    try {
      await _supabase.rpc('accept_terms', params: {'p_version': kTermsVersion});
    } catch (_) {
      // Non-fatal: the account itself was already created successfully.
    }
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_agreedToTerms) {
      setState(() => _error =
          'Please read and accept the Terms & Privacy Policy to continue.');
      return;
    }

    // Captured before any await: used to report failures even if navigation
    // has disposed this screen by the time an upload/insert fails.
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Regular users sign up with contact details only — no ID is collected
    // here. Browsing, cart, and checkout never require one; a National ID
    // is only requested at booking time for booking-type orders.
    if (_isProvider) {
      if (_nationalIdImage == null) {
        setState(() => _uploadError = 'National ID image is required');
        return;
      }
      if (_licenseImage == null) {
        setState(() => _uploadError = _roleName == 'Vehicle Provider'
            ? 'Driving license image is required'
            : 'Trading license image is required');
        return;
      }
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _uploadError = null;
    });

    try {
      if (_isProvider) {
        await ref.read(authProvider.notifier).signUpAsProvider(
              email: _emailController.text.trim(),
              phone: _phoneController.text.trim(),
              password: _passwordController.text,
              businessName: _nameController.text.trim(),
              ownerNationalId: _nationalIdController.text.trim(),
              providerType: _providerType,
            );

        // Upload documents after account is created. Failures are surfaced:
        // without the documents the admin cannot verify the account, so the
        // user must know (and contact support) instead of the signup silently
        // "succeeding" without them. The router only navigates away after
        // this completes (success, partial success, or reported failure).
        final userId = _supabase.auth.currentUser?.id;
        if (userId == null) {
          // No session (e.g. email confirmation enabled): GoTrue issued no
          // JWT, so nothing can be uploaded or recorded now. Tell the user
          // instead of silently skipping — documents are requested again
          // after they log in.
          final msg = 'Account created. Your verification documents will be '
              'requested after you sign in.';
          messenger.showSnackBar(SnackBar(content: Text(msg)));
          setState(() => _uploadError = msg);
        } else {
          setState(() => _uploadingDocs = true);

          // Same shared per-file unit (upload + user_documents insert + one
          // retry) the pending-approval recovery screen uses. The real
          // exception is kept so the dialog/deep-link below shows the same
          // detail as before.
          Object? licenseError;
          try {
            await DocumentUploadService.instance.uploadAndRecord(
              file: _nationalIdImage!,
              userId: userId,
              documentType: 'NATIONAL_ID',
            );
            try {
              await DocumentUploadService.instance.uploadAndRecord(
                file: _licenseImage!,
                userId: userId,
                documentType: _roleName == 'Vehicle Provider'
                    ? 'DRIVING_LICENSE'
                    : 'TRADE_LICENSE',
              );
            } catch (e) {
              // First file is already stored and recorded; keep going.
              licenseError = e;
            }
          } catch (docError) {
            await _showDocumentUploadError(docError, router, messenger);
          } finally {
            if (mounted) setState(() => _uploadingDocs = false);
          }
          // Report a second-file failure only after the first file's row
          // was recorded (never instead of it).
          if (licenseError != null) {
            await _showDocumentUploadError(licenseError, router, messenger);
          }
        }
      } else {
        await ref.read(authProvider.notifier).signUp(
              email: _emailController.text.trim(),
              phone: _phoneController.text.trim(),
              password: _passwordController.text,
              fullName: _nameController.text.trim(),
              role: AppUserRole.user,
            );

        // No documents are collected for regular users at signup — the
        // admin approves the account from the submitted details alone.
      }

      // Admin approval is the account gate (email confirmation is
      // disabled in Supabase Auth), so signUp() returns a session
      // immediately and the handle_new_user() trigger has already created
      // the profile in PENDING_APPROVAL status. Go straight to the
      // waiting-for-admin-approval screen.
      final hasSession = _supabase.auth.currentSession != null;
      if (!mounted) return;

      if (!hasSession) {
        // Defensive: only possible if email confirmation gets re-enabled
        // in Supabase Auth. The account was still created — send the user
        // to sign in instead of pretending registration failed.
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Account created. Please sign in to continue.')),
        );
        context.go('/login');
        return;
      }

      // Record the user's terms acceptance (version + timestamp) on the
      // profile now that a session exists. Best-effort, never blocks.
      await _recordTermsAcceptance();

      context.go('/pending-approval');
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _uploadingDocs = false;
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
    return 'Registration failed: $raw';
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
                            ? 'Your application will be reviewed before activation'
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
                        // Document uploads are provider-only; regular users
                        // sign up with contact details alone.
                        if (_isProvider) ...[
                          _buildDocumentSection(),
                          const SizedBox(height: 24),
                        ],
                        _buildFormFields(),
                        const SizedBox(height: 12),
                        if (_uploadError != null)
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppTheme.error.withOpacity(0.2)),
                            ),
                            child: Text(_uploadError!,
                                style: const TextStyle(
                                    fontSize: 13, color: AppTheme.error)),
                          ),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
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
                                onChanged: (v) => setState(
                                    () => _agreedToTerms = v ?? false),
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
                                    onTap: () => context.push('/terms', extra: true),
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
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            label: _isProvider
                                ? 'SUBMIT APPLICATION'
                                : 'CREATE ACCOUNT',
                            isLoading: _isLoading,
                            onPressed:
                                _agreedToTerms ? _handleSignup : null,
                          ),
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
          if (_isLoading || _uploadingDocs)
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                          color: AppTheme.primaryGreen),
                      const SizedBox(height: 16),
                      Text(
                        _uploadingDocs
                            ? 'Uploading documents...'
                            : 'Creating account...',
                        style: const TextStyle(
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

  Widget _buildDocumentSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.description_outlined,
                  color: AppTheme.primaryGreen, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Required Documents',
                      style: AppTheme.sectionHeader),
                  SizedBox(height: 2),
                  Text('Upload clear photos of your documents',
                      style: AppTheme.caption),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // National ID image: providers only (verified upfront). Regular
        // users browse and buy without ever providing an ID here.
        if (_isProvider)
          DocumentUploadCard(
            title: 'National ID',
            subtitle: 'Clear photo of front side',
            file: _nationalIdImage,
            onPick: () => _showImagePicker(true),
            onRemove: () => setState(() => _nationalIdImage = null),
          ),
        // License is only required for providers
        if (_isProvider) ...[
          const SizedBox(height: 12),
          DocumentUploadCard(
            title: _roleName == 'Vehicle Provider'
                ? 'Driving License'
                : 'Trading License',
            subtitle: _roleName == 'Vehicle Provider'
                ? 'Updated driving license'
                : 'Valid trading license',
            file: _licenseImage,
            onPick: () => _showImagePicker(false),
            onRemove: () => setState(() => _licenseImage = null),
          ),
        ],
      ],
    );
  }

  Widget _buildFormFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Personal Information',
            style: AppTheme.sectionHeader),
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
        // National ID is only collected from providers (verified upfront).
        // Regular users sign up without it and provide ID later at booking
        // time if the order type requires one.
        if (_isProvider) ...[
          BirrTextField(
            label: 'National ID Number',
            controller: _nationalIdController,
            textInputAction: TextInputAction.next,
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'National ID is required';
              }
              if (v.trim().length < 4) return 'Invalid national ID';
              return null;
            },
          ),
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
          onEditingComplete: _handleSignup,
          suffixIcon: IconButton(
            icon: Icon(
              _obscureConfirm
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: AppTheme.textMuted,
              size: 20,
            ),
            onPressed: () =>
                setState(() => _obscureConfirm = !_obscureConfirm),
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
