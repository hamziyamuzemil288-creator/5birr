import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

/// Shown when the signed-in user's profile.status is REJECTED.
///
/// Complete flow (was TODO-only before):
///  - Shows the reviewer's latest reason from approval_history
///    (owner-readable RLS; hidden gracefully when absent).
///  - "Correct & Resubmit" calls the reopen_rejected_application() RPC
///    (status flip is trigger-protected, so it must go through the
///    sanctioned server path), then refreshes the profile — the router
///    moves the user to /pending-approval on the next redirect.
///  - "Contact Support" files a support_tickets row the admin panel
///    already displays (trg_support_tickets_security requires status
///    OPEN on user inserts, which is the column default).
class RejectedScreen extends ConsumerStatefulWidget {
  const RejectedScreen({super.key});

  @override
  ConsumerState<RejectedScreen> createState() => _RejectedScreenState();
}

class _RejectedScreenState extends ConsumerState<RejectedScreen> {
  bool _resubmitting = false;
  bool _sendingTicket = false;
  String? _rejectionReason;
  bool _reasonLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadRejectionReason();
  }

  /// Latest reviewer note for this account. approval_history_owner_read
  /// allows subjects of type USER for the owner and PROVIDER via
  /// owns_provider_profile(); a failure here is silent — the generic
  /// guidance below is still correct.
  Future<void> _loadRejectionReason() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final rows = await Supabase.instance.client
          .from('approval_history')
          .select('action, reason, created_at')
          .eq('subject_type', 'USER')
          .eq('subject_id', uid)
          .eq('action', 'REJECT')
          .order('created_at', ascending: false)
          .limit(1);
      if (!mounted) return;
      final data = rows as List;
      setState(() {
        _rejectionReason =
            data.isNotEmpty ? (data.first['reason'] as String?) : null;
        _reasonLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _reasonLoaded = true);
    }
  }

  Future<void> _resubmit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _ResubmitDialog(),
    );
    if (confirmed != true) return;

    setState(() => _resubmitting = true);
    try {
      await Supabase.instance.client.rpc(
        'reopen_rejected_application',
        params: {
          'p_note': _ResubmitDialog.lastNote?.trim().isEmpty ?? true
              ? null
              : _ResubmitDialog.lastNote!.trim(),
        },
      );
      if (!mounted) return;
      // Profile is back to PENDING_APPROVAL — refresh, then let the
      // router redirect to /pending-approval.
      await ref.read(authProvider.notifier).refreshProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Application resubmitted for review.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _resubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, context: 'Could not resubmit'))),
      );
    }
  }

  Future<void> _contactSupport() async {
    setState(() => _sendingTicket = true);
    try {
      final auth = ref.read(authProvider);
      final email = auth.user?.email ?? 'unknown';
      await Supabase.instance.client.from('support_tickets').insert({
        'subject': 'Rejected application — help resubmitting',
        'description':
            'My application was rejected${_rejectionReason == null ? '' : ' (reason: ${_rejectionReason!})'}. '
                'Account email: $email. Please help me correct and resubmit.',
        'source': 'OTHER',
        // status defaults to OPEN (required by the insert security trigger).
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Support request sent — our team will reach out to you.')),
      );
      await ref.read(authProvider.notifier).refreshProfile();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, context: 'Could not send your request'))),
      );
    } finally {
      if (mounted) setState(() => _sendingTicket = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppTheme.error, Color(0xFF8B1A1A)],
              stops: [0.0, 0.4],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 32),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.cancel_outlined,
                        color: Colors.white, size: 40),
                  ),
                  const SizedBox(height: 20),
                  const Text('Application Update',
                      style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 8),
                  Text(
                    'Your application requires attention',
                    style: TextStyle(
                        fontSize: 14, color: Colors.white.withOpacity(0.8)),
                  ),
                  const SizedBox(height: 32),
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.info_outline,
                                color: AppTheme.error, size: 20),
                            const SizedBox(width: 8),
                            const Text('Status',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            (auth.profile?.status ?? 'REJECTED')
                                .replaceAll('_', ' '),
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.error),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_reasonLoaded &&
                            _rejectionReason != null &&
                            _rejectionReason!.trim().isNotEmpty) ...[
                          const Text("Reviewer's note",
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                  color: AppTheme.warning.withOpacity(0.3)),
                            ),
                            child: Text(
                              _rejectionReason!,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textPrimary,
                                  height: 1.45),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        const Text(
                          'Our review found that your application needs '
                          'corrections or additional information. Update '
                          'your details and resubmit — or contact support '
                          'if something looks wrong.',
                          style: TextStyle(
                              fontSize: 13,
                              color: AppTheme.textSecondary,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'CORRECT & RESUBMIT',
                      icon: Icons.edit_outlined,
                      isLoading: _resubmitting,
                      onPressed: _resubmit,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'CONTACT SUPPORT',
                      isOutlined: true,
                      icon: Icons.support_agent,
                      isLoading: _sendingTicket,
                      onPressed: _contactSupport,
                    ),
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
}

/// Confirmation dialog with an optional note to reviewers. The note is
/// stashed in a static for the one-call lifetime between dialog dismiss
/// and RPC invocation (the dialog itself is unmounted by then).
class _ResubmitDialog extends StatefulWidget {
  static String? lastNote;

  const _ResubmitDialog();

  @override
  State<_ResubmitDialog> createState() => _ResubmitDialogState();
}

class _ResubmitDialogState extends State<_ResubmitDialog> {
  final _noteController = TextEditingController(text: _ResubmitDialog.lastNote);

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Resubmit application?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your application goes back to the review queue with your '
            'current details. You can add a short note for the reviewers '
            'below.',
            style: TextStyle(fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _noteController,
            maxLines: 3,
            maxLength: 500,
            decoration: const InputDecoration(
              hintText: 'Note to reviewers (optional)',
              counterText: '',
            ),
            onChanged: (v) => _ResubmitDialog.lastNote = v,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('CANCEL'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('RESUBMIT'),
        ),
      ],
    );
  }
}
