import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/birr_text_field.dart';
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

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signIn(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      if (mounted) {
        // Router redirect will handle navigation
      }
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
    if (raw.contains('Invalid login credentials')) {
      return 'Invalid email or password.';
    }
    if (raw.contains('Email not confirmed')) {
      return 'Please verify your email first. Check your inbox for a confirmation link.';
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Please check your connection.';
    }
    if (raw.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    return 'Login failed: $raw';
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
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Colors.white.withOpacity(0.3), width: 2),
                    ),
                    child: const Center(
                      child: Text('₅',
                          style: TextStyle(
                              fontSize: 42,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text('5BIRR',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 3)),
                const SizedBox(height: 6),
                Text('Marketplace • Services • Transport',
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(0.7),
                        letterSpacing: 0.5)),
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
                        const SizedBox(height: 4),
                        const Text('Sign in to your account',
                            style: AppTheme.caption),
                        const SizedBox(height: 24),
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
                            onPressed: () {
                              // TODO: Password reset flow
                            },
                            child: const Text('Forgot Password?'),
                          ),
                        ),
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
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
