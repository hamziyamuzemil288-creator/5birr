import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/captcha_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/captcha_challenge_field.dart';

/// User-facing appeal / spam-report form.
///
/// Collects an evidence photo, a written report and contact details and stores
/// the case in `appeal_cases` (photo in the private `user-documents` bucket).
/// Admins review and resolve cases from Admin → Appeals.
class AppealScreen extends StatefulWidget {
  const AppealScreen({super.key});

  @override
  State<AppealScreen> createState() => _AppealScreenState();
}

class _AppealScreenState extends State<AppealScreen> {
  static const _bucket = 'user-documents';

  final _formKey = GlobalKey<FormState>();
  final _descriptionCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  XFile? _photo;
  bool _submitting = false;
  bool _captchaRequired = false;
  String? _captchaId;
  int _captchaVersion = 0;
  String? _error;
  String? _caseId;

  @override
  void initState() {
    super.initState();
    _loadCaptchaRequirement();
  }

  Future<void> _loadCaptchaRequirement() async {
    final required = await CaptchaService.instance.isRequired();
    if (mounted) setState(() => _captchaRequired = required);
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    // Camera first, gallery as fallback, mirroring the signup document flow.
    try {
      final fromCamera = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (fromCamera != null) {
        setState(() => _photo = fromCamera);
        return;
      }
      final fromGallery = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (fromGallery != null) setState(() => _photo = fromGallery);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the camera: $e')),
      );
    }
  }

  String? _validateEmail(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional field
    final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return emailRe.hasMatch(value) ? null : 'Enter a valid email address';
  }

  String? _validatePhone(String? v) {
    final value = v?.trim() ?? '';
    final phoneRe = RegExp(r'^(?:\+?251|0)?9\d{8}$');
    return phoneRe.hasMatch(value.replaceAll(RegExp(r'[\s-]'), ''))
        ? null
        : 'Enter a valid Ethiopian phone number (e.g. 0912345678)';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_photo == null) {
      setState(() => _error = 'Please attach a photo to support your appeal.');
      return;
    }
    if (_captchaRequired && _captchaId == null) {
      setState(() => _error = 'Please complete the security check first.');
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() => _error = 'You need to be signed in to submit an appeal.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final client = Supabase.instance.client;

      // 1. Upload the evidence photo (private bucket, same one signup uses).
      final path =
          '${user.id}/appeal_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await client.storage.from(_bucket).upload(
            path,
            File(_photo!.path),
            fileOptions: const FileOptions(upsert: true),
          );

      // 2. Store the case.
      final inserted = await client
          .from('appeal_cases')
          .insert({
            'user_id': user.id,
            'photo_path': path,
            'description': _descriptionCtrl.text.trim(),
            'phone': _phoneCtrl.text.trim(),
            'email': _emailCtrl.text.trim().isEmpty
                ? null
                : _emailCtrl.text.trim(),
            'captcha_id': _captchaId,
          })
          .select('id')
          .single();

      if (!mounted) return;
      setState(() {
        _caseId = inserted['id'] as String;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      final captchaFailed = raw.contains('CAPTCHA_REQUIRED');
      setState(() {
        _submitting = false;
        if (captchaFailed) {
          _captchaId = null;
          _captchaVersion++;
        }
        _error = captchaFailed
            ? 'The security check expired. Please solve a new one and submit again.'
            : 'Could not submit your appeal. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Submit an Appeal',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _caseId != null ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline,
                color: AppTheme.primaryGreen, size: 72),
            const SizedBox(height: 16),
            const Text(
              'Appeal submitted',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Our team will review your case and contact you using the '
              'details you provided. You can follow up any time through '
              'Help & Support.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline,
                      color: AppTheme.primaryGreenDark, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Wrongly flagged, scammed, or want to report someone? '
                      'Tell us what happened and attach a photo as evidence. '
                      'Our team reviews every appeal.',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Photo attachment
            Text('Evidence photo',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _submitting ? null : _pickPhoto,
              child: Container(
                height: 160,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.cardBorder,
                    width: 1.2,
                  ),
                ),
                child: _photo != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child:
                                Image.file(File(_photo!.path), fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.white),
                                onPressed:
                                    _submitting ? null : () => setState(() => _photo = null),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.add_a_photo_outlined,
                              color: AppTheme.textSecondary, size: 32),
                          SizedBox(height: 8),
                          Text('Tap to take or choose a photo',
                              style: TextStyle(color: AppTheme.textSecondary)),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),

            BirrTextField(
              label: 'Report / description',
              hint: 'Describe what happened in as much detail as you can',
              controller: _descriptionCtrl,
              maxLines: 5,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Please describe your case' : null,
            ),
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Phone number',
              hint: '09xxxxxxxx',
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              validator: _validatePhone,
            ),
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Email (optional)',
              hint: 'you@example.com',
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              validator: _validateEmail,
            ),

            if (_captchaRequired) ...[
              const SizedBox(height: 16),
              CaptchaChallengeField(
                key: ValueKey('appeal-captcha-$_captchaVersion'),
                onVerified: (id) => setState(() => _captchaId = id),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.error, fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting || (_captchaRequired && _captchaId == null)
                  ? null
                  : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryGreenDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Submit appeal',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
