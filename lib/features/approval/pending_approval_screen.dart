import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/document_upload_service.dart';
import '../../core/widgets/primary_button.dart';

class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key, this.resumeDocUpload = false, this.docError});

  final bool resumeDocUpload;
  final String? docError;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return _PendingApprovalView(
      auth: auth,
      resumeDocUpload: resumeDocUpload,
      initialDocError: docError,
    );
  }
}

class _PendingApprovalView extends ConsumerStatefulWidget {
  const _PendingApprovalView({
    required this.auth,
    this.resumeDocUpload = false,
    this.initialDocError,
  });

  final AuthState auth;
  final bool resumeDocUpload;
  final String? initialDocError;

  @override
  ConsumerState<_PendingApprovalView> createState() => _PendingApprovalViewState();
}

class _PendingApprovalViewState extends ConsumerState<_PendingApprovalView> {
  bool _checkingDocs = true;
  bool _hasDocuments = true;
  bool _uploading = false;
  String? _docMessage;
  final _picker = ImagePicker();

  static const _licenseTypeByRole = {
    'vehicleProvider': 'DRIVING_LICENSE',
    'serviceProvider': 'TRADE_LICENSE',
  };

  @override
  void initState() {
    super.initState();
    _checkDocuments();
  }

  Future<void> _checkDocuments() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      if (mounted) setState(() => _checkingDocs = false);
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('user_documents')
          .select('id')
          .eq('user_id', userId)
          .limit(1);
      if (mounted) {
        setState(() {
          _hasDocuments = (rows as List).isNotEmpty;
          _checkingDocs = false;
        });
      }
    } catch (_) {
      // If the check itself fails, do not block the screen's main purpose.
      if (mounted) setState(() => _checkingDocs = false);
    }
  }

  Future<void> _uploadDocuments() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final role = widget.auth.primaryRole;
    final isProvider = role == AppUserRole.vehicleProvider ||
        role == AppUserRole.serviceProvider;

    try {
      final pickedId = await _picker.pickImage(
          source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
      if (pickedId == null) return;
      final files = <(File, String)>[(File(pickedId.path), 'NATIONAL_ID')];

      if (isProvider) {
        final licenseType = _licenseTypeByRole[role!.name] ?? 'TRADE_LICENSE';
        final pickedLicense = await _picker.pickImage(
            source: ImageSource.gallery, maxWidth: 1920, maxHeight: 1920, imageQuality: 85);
        if (pickedLicense != null) files.add((File(pickedLicense.path), licenseType));
      }

      if (!mounted) return;
      setState(() {
        _uploading = true;
        _docMessage = null;
      });

      final result = await DocumentUploadService.instance
          .uploadAllAndRecord(files: files, userId: userId);

      if (!mounted) return;
      setState(() {
        _uploading = false;
        _docMessage = result.success
            ? 'Documents uploaded. Our team will review them.'
            : 'Upload incomplete (${result.recordedCount}/${result.uploadedCount} files). '
                'Please try again or contact support.';
        if (result.success) _hasDocuments = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _docMessage = 'Upload failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppTheme.primaryGreen, AppTheme.cream],
              stops: [0.0, 0.4],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 32),
                  // Clock icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.hourglass_top_rounded,
                        color: Colors.white, size: 40),
                  ),
                  const SizedBox(height: 20),
                  const Text('Application Under Review',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 8),
                  Text(
                    'Thank you for applying to join 5BIRR',
                    style: TextStyle(
                        fontSize: 14, color: Colors.white.withOpacity(0.8)),
                  ),
                  const SizedBox(height: 32),
                  // Info card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _infoRow(Icons.check_circle_outline, 'Submitted',
                            'Your information and documents have been received'),
                        const SizedBox(height: 16),
                        _infoRow(Icons.search, 'Review in Progress',
                            'Our team is verifying your documents and information'),
                        const SizedBox(height: 16),
                        _infoRow(Icons.notifications_none, 'Notification',
                            'You will be notified when your application is reviewed'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Status info
                  if (auth.profile != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: AppTheme.warning.withOpacity(0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline,
                              color: AppTheme.warning, size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Status: ${auth.profile!.status.replaceAll('_', ' ')}',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  // Document recovery: a failed signup upload can be finished
                  // here without creating a new account.
                  if (_checkingDocs)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else if (!_hasDocuments) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: AppTheme.warning, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Your documents were not received. '
                              'Upload them now so verification can start.',
                              style: TextStyle(
                                  fontSize: 13, color: AppTheme.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    PrimaryButton(
                      label: _uploading ? 'UPLOADING…' : 'UPLOAD YOUR DOCUMENTS',
                      onPressed: _uploading ? null : _uploadDocuments,
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (_docMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _docMessage!,
                        style: TextStyle(
                            fontSize: 12,
                            color: _docMessage!.startsWith('Upload failed') ||
                                    _docMessage!.startsWith('Upload incomplete')
                                ? AppTheme.error
                                : AppTheme.success),
                      ),
                    ),
                  if (widget.resumeDocUpload && widget.initialDocError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Previous attempt failed: ${widget.initialDocError}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.error),
                      ),
                    ),
                  const SizedBox(height: 32),
                  PrimaryButton(
                    label: 'REFRESH STATUS',
                    isOutlined: true,
                    icon: Icons.refresh,
                    onPressed: () =>
                        ref.read(authProvider.notifier).refreshProfile(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'LOGOUT',
                      onPressed: () =>
                          ref.read(authProvider.notifier).signOut(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.primaryGreen.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppTheme.primaryGreen, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(desc,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}
