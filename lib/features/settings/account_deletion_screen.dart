import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/utils/friendly_error.dart';

/// Request deletion of an account, and follow the request afterwards.
///
/// Two halves on one screen, because a person who has just asked to leave
/// needs to know what happened next without hunting for it:
///
///   * the history — every request this account has made, with its status and
///     the note a staff member left back;
///   * the form — a required reason, and optional supporting detail.
///
/// Nothing here deletes anything. Submitting opens a request that a staff
/// member with the `account_deletion` job decides, which is the whole point:
/// the decision has a person attached to it and the person can see who.
class AccountDeletionScreen extends StatefulWidget {
  const AccountDeletionScreen({super.key});

  @override
  State<AccountDeletionScreen> createState() => _AccountDeletionScreenState();
}

class _AccountDeletionScreenState extends State<AccountDeletionScreen> {
  final _reasonCtrl = TextEditingController();
  final _infoCtrl = TextEditingController();

  List<Map<String, dynamic>> _requests = const [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    _infoCtrl.dispose();
    super.dispose();
  }

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> _load() async {
    try {
      final data = await _client.rpc('my_account_deletion_requests');
      if (!mounted) return;
      setState(() {
        _requests = List<Map<String, dynamic>>.from(data as List);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your requests');
      });
    }
  }

  bool get _hasPending =>
      _requests.any((r) => r['status'] == 'PENDING');

  Future<void> _submit() async {
    final reason = _reasonCtrl.text.trim();
    if (reason.length < 10) {
      _toast('Please tell us why in at least a few words.');
      return;
    }
    setState(() => _submitting = true);
    try {
      await _client.rpc('request_account_deletion', params: {
        'p_reason': reason,
        'p_supporting_info':
            _infoCtrl.text.trim().isEmpty ? null : _infoCtrl.text.trim(),
      });
      _reasonCtrl.clear();
      _infoCtrl.clear();
      await _load();
      if (!mounted) return;
      _toast('Request sent. Our team will review it and get back to you.');
    } catch (e) {
      if (!mounted) return;
      _toast(_messageFor(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The three refusals the server can send, in the words the founder would
  /// use. Anything else falls back to the shared error mapper.
  String _messageFor(Object e) {
    final raw = e.toString();
    if (raw.contains('ALREADY_HAS_PENDING_REQUEST')) {
      return 'You already have a request being reviewed.';
    }
    if (raw.contains('REASON_TOO_SHORT')) {
      return 'Please give us a little more detail.';
    }
    return friendlyError(e, context: 'Could not send your request');
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete Account')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _Explainer(),
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(_error!,
                        style: const TextStyle(
                            color: AppTheme.error, fontSize: 13)),
                  ),
                if (_requests.isNotEmpty) ...[
                  const Text('Your requests',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 10),
                  for (final r in _requests) _RequestCard(request: r),
                  const SizedBox(height: 20),
                ],
                if (_hasPending)
                  _PendingNotice()
                else ...[
                  const Text('Request deletion',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 12),
                  BirrTextField(
                    label: 'Why are you leaving? (required)',
                    controller: _reasonCtrl,
                    maxLines: 3,
                  ),
                  const SizedBox(height: 12),
                  BirrTextField(
                    label: 'Anything else we should know? (optional)',
                    controller: _infoCtrl,
                    maxLines: 2,
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'SUBMIT REQUEST',
                      isLoading: _submitting,
                      onPressed: _submit,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Your account keeps working normally until a staff member '
                  'approves the request.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ),
    );
  }
}

class _Explainer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: AppTheme.textSecondary),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Deletion is reviewed by a person, not instant. We keep your '
              'order and wallet records for accounting, but your profile, '
              'documents and personal data are removed.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.hourglass_top, color: AppTheme.warning),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Your request is with our team. We will let you know the outcome '
              'here and by notification.',
              style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request});
  final Map<String, dynamic> request;

  @override
  Widget build(BuildContext context) {
    final status = (request['status'] as String?) ?? 'PENDING';
    final (color, label) = switch (status) {
      'APPROVED' => (AppTheme.success, 'Approved'),
      'REJECTED' => (AppTheme.error, 'Declined'),
      _ => (AppTheme.warning, 'Under review'),
    };
    final note = (request['decision_note'] as String?)?.trim();
    final at = DateTime.tryParse('${request['reviewed_at'] ?? request['created_at']}');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
              const Spacer(),
              if (at != null)
                Text(
                  '${at.day}/${at.month}/${at.year}',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text('${request['reason'] ?? ''}',
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textPrimary, height: 1.4)),
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('From our team: $note',
                  style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                      height: 1.4)),
            ),
          ],
        ],
      ),
    );
  }
}
