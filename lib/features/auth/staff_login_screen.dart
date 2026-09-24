import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/staff_gateway_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
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

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _service.signIn(
        username: _username.text,
        password: _password.text,
      );
      if (mounted) context.go('/staff/dashboard');
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _friendlyError(e.toString());
        });
      }
    }
  }

  String _friendlyError(String raw) {
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
                      'Use the username and password provided by the CEO.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    BirrTextField(
                      label: 'Username',
                      controller: _username,
                      textInputAction: TextInputAction.next,
                      textCapitalization: TextCapitalization.none,
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Username is required';
                        }
                        if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]{2,31}$')
                            .hasMatch(value.trim())) {
                          return 'Use 3–32 letters, numbers, dots, underscores, or hyphens';
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
