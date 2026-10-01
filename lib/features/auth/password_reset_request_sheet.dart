import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';

/// File a password reset as a trackable case, for somebody who cannot sign in.
///
/// Deliberately NOT requiring a session: the person cannot sign in, which is
/// the entire reason they are here. Identity is possession of the registered
/// email and/or phone, checked server-side by
/// `request_password_reset_appeal` (migration 20260927000120), and the answer is
/// the same whether or not it matched -- so this cannot be used to discover
/// which addresses have accounts.
///
/// It lands in `appeal_cases` with `case_type = 'PASSWORD_RESET'`, which the
/// admin appeals screen filters on. A parallel inbox would be a queue staff
/// forget to check, and a request nobody sees is the same as no request.
Future<void> showPasswordResetRequestSheet(
  BuildContext context, {
  String initialEmail = '',
}) {
  final emailCtrl = TextEditingController(text: initialEmail);
  final phoneCtrl = TextEditingController();
  final notesCtrl = TextEditingController();

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetCtx) => _PasswordResetRequestBody(
      emailCtrl: emailCtrl,
      phoneCtrl: phoneCtrl,
      notesCtrl: notesCtrl,
    ),
  ).whenComplete(() {
    emailCtrl.dispose();
    phoneCtrl.dispose();
    notesCtrl.dispose();
  });
}

class _PasswordResetRequestBody extends StatefulWidget {
  const _PasswordResetRequestBody({
    required this.emailCtrl,
    required this.phoneCtrl,
    required this.notesCtrl,
  });

  final TextEditingController emailCtrl;
  final TextEditingController phoneCtrl;
  final TextEditingController notesCtrl;

  @override
  State<_PasswordResetRequestBody> createState() =>
      _PasswordResetRequestBodyState();
}

class _PasswordResetRequestBodyState extends State<_PasswordResetRequestBody> {
  bool _sending = false;
  String? _error;
  String? _done;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Ask for a password reset', style: AppTheme.heading),
            const SizedBox(height: 8),
            const Text(
              'Tell us the email and phone number on your account. Our team '
              'will check who you are and set a new password for you.',
              style: AppTheme.bodyMedium,
            ),
            const SizedBox(height: 20),
            BirrTextField(
              label: 'Email on the account',
              controller: widget.emailCtrl,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 12),
            BirrTextField(
              label: 'Phone number on the account',
              controller: widget.phoneCtrl,
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            BirrTextField(
              label: 'Anything else? (optional)',
              controller: widget.notesCtrl,
              maxLines: 2,
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style:
                      const TextStyle(fontSize: 13, color: AppTheme.error)),
            ],
            if (_done != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      color: AppTheme.success, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_done!,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.success)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'SEND REQUEST',
                isLoading: _sending,
                onPressed: _done != null ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final email = widget.emailCtrl.text.trim();
    final phone = widget.phoneCtrl.text.trim();
    if (email.isEmpty && phone.isEmpty) {
      setState(() => _error =
          'Give us the email or the phone number on the account.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final message = await Supabase.instance.client
          .rpc('request_password_reset_appeal', params: {
        'p_email': email.isEmpty ? null : email,
        'p_phone': phone.isEmpty ? null : phone,
        'p_notes':
            widget.notesCtrl.text.trim().isEmpty ? null : widget.notesCtrl.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _sending = false;
        _done = (message as String?) ??
            'Request sent. Our team will be in touch.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error =
            'Could not send the request. Check your connection and try again.';
      });
    }
  }
}
