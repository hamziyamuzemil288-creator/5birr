import 'dart:async';

import 'package:flutter/material.dart';

import '../services/provider_doc_gate.dart';
import '../theme/app_theme.dart';

/// Task 13 item 3: brief, non-blocking "Verify your account" notice shown
/// after registration. Auto-dismisses after a few seconds; tapping it (or
/// the action) opens the same document upload sheet the protected-action
/// gate uses (ProviderDocGate — Task 9), so this adds zero new gating
/// logic and never blocks the UI.
///
/// Renders nothing when the signed-in user already has an accepted
/// document (or when the check fails — a notice must never nag on error).
class VerificationNotice extends StatefulWidget {
  const VerificationNotice({super.key});

  @override
  State<VerificationNotice> createState() => _VerificationNoticeState();
}

class _VerificationNoticeState extends State<VerificationNotice> {
  bool _visible = false;
  bool _checking = true;
  String _message = _uploadPrompt;
  Timer? _dismissTimer;

  static const _uploadPrompt =
      'Verify your account — upload an ID document to unlock provider actions.';
  static const _pendingMessage =
      'We received your ID — our team is checking it. Nothing is blocked.';

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    // Deliberately reviewState() and NOT isSatisfied(). isSatisfied() fails
    // OPEN — correct for gating, wrong for prompting — so a failed check
    // returned true and this notice computed `_visible = !true = false`.
    // The one moment the user most needs to be told something was exactly the
    // moment the notice stayed hidden and the gate sat open.
    //
    // So: show unless we positively know they are verified. A failed check is
    // not knowledge, and the notice's own text is safe guidance either way.
    final state = await ProviderDocGate.instance.reviewState();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _visible = state != DocReviewState.verified;
      // Someone who already uploaded and is waiting on us must not be told to
      // upload again — that was the second half of the reported bug.
      _message = state == DocReviewState.pending
          ? _pendingMessage
          : _uploadPrompt;
    });
    if (_visible) {
      _dismissTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    super.dispose();
  }

  Future<void> _openUpload() async {
    _dismissTimer?.cancel();
    await ProviderDocGate.instance.ensureDocuments(context);
    if (!mounted) return;
    setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || !_visible) return const SizedBox.shrink();
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Material(
          color: AppTheme.primaryGreen.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _openUpload,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  const Icon(Icons.verified_user_outlined,
                      size: 20, color: AppTheme.primaryGreen),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _message,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppTheme.textPrimary),
                    ),
                  ),
                  TextButton(
                    onPressed: _openUpload,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Verify',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close,
                        size: 16, color: AppTheme.textMuted),
                    onPressed: () => setState(() => _visible = false),
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
