import 'package:flutter/material.dart';

import '../services/provider_doc_gate.dart';
import '../theme/app_theme.dart';

/// Status-aware entry point to the document-verification flow.
///
/// WHY THIS EXISTS
/// ---------------
/// The profile menu rendered one static tile — the same icon, the same label
/// "Verify Document", the same chevron — whether or not the account had an
/// accepted document on file. The only surface that reflected verification at
/// all was the dashboard banner, which auto-dismisses after five seconds. So a
/// verified and an unverified account were indistinguishable the moment that
/// banner faded, and after a successful upload the entry still looked exactly
/// as it had before: no way to tell whether the upload had worked.
///
/// This renders all six real states distinctly and re-reads the status after
/// the upload flow closes, so the tile turns green the moment a document is
/// actually VERIFIED rather than only looking right after an app restart.
///
/// It reads [DocReviewState], NOT [DocCheckStatus]. The gating status says
/// "you may work", which is deliberately generous — a document merely queued
/// for review satisfies it — and using it here is what made this tile claim
/// "Identity verified" for an ID no human had ever opened. There was not even
/// an admin decision to display until migration 20260927000030 added the
/// VERIFIED / REJECTED states.
///
/// It uses a hand-built row rather than ListTile on purpose: ListTile's fixed
/// height and single-line subtitle clip at large text scales, and this list has
/// already produced one overflow bug tonight (the staff delete confirmation).
/// An intrinsic-height Row cannot overflow vertically, and the flexible middle
/// column absorbs the width.
class VerificationStatusTile extends StatefulWidget {
  const VerificationStatusTile({
    super.key,
    this.reviewLoader,
    this.onTapAction,
  });

  /// Overridable for tests. The real loader goes through ProviderDocGate, which
  /// needs a live Supabase client a widget test cannot provide.
  final Future<DocReviewState> Function()? reviewLoader;

  /// Overridable for tests, for the same reason.
  final Future<void> Function(BuildContext context)? onTapAction;

  @override
  State<VerificationStatusTile> createState() => _VerificationStatusTileState();
}

class _VerificationStatusTileState extends State<VerificationStatusTile> {
  /// Null until the first check returns. Rendered as "Checking…" rather than
  /// guessing — defaulting to [DocReviewState.none] would flash "Not verified"
  /// at a verified user on every open.
  DocReviewState? _status;

  /// Guards against a slow first check landing after a newer one and
  /// overwriting it with stale state.
  int _request = 0;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final token = ++_request;
    final loader = widget.reviewLoader ?? ProviderDocGate.instance.reviewState;
    DocReviewState result;
    try {
      result = await loader();
    } catch (_) {
      // reviewState already folds its own failures into unknown; this only
      // covers an injected loader that throws.
      result = DocReviewState.unknown;
    }
    if (!mounted || token != _request) return;
    setState(() => _status = result);
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final action = widget.onTapAction ??
          (BuildContext ctx) => ProviderDocGate.instance.ensureDocuments(ctx);
      // Called before any await, so the context is still valid here.
      await action(context);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The flow may have just changed the state. Re-read it, or the tile keeps
    // claiming "Not verified" after a successful upload — the exact staleness
    // this widget exists to remove.
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final v = _visualFor(_status);

    return InkWell(
      onTap: _busy ? null : _open,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: v.color.withOpacity(0.08),
                borderRadius: BorderRadius.circular(9),
              ),
              child: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(9),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: v.color,
                      ),
                    )
                  : Icon(v.icon, color: v.color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The status chip lives INSIDE the flexible column, in a
                  // Wrap, rather than in the Row's trailing slot. As trailing
                  // content it took its natural width first and squeezed this
                  // column to 14px at a 2.0 text scale — caught by the layout
                  // test, and the text then wrapped into a vertical overflow.
                  // In a Wrap the chip drops to its own line instead, so it can
                  // never steal width from the label.
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        v.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      if (v.chip != null) _chip(v.chip!, v.color),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    v.subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                color: AppTheme.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// What the tile shows for a given state. Split out so every state is spelled
/// out in one place and cannot quietly converge on the same visuals — which is
/// precisely the bug this widget exists to prevent.
///
/// SUBTITLES ARE DELIBERATELY SHORT. This is a list row inside a Column, and
/// the regression test pumps it at a 2.0 text scale in a 320x480 viewport,
/// where the flexible column gets 216px. A two-sentence subtitle wraps to five
/// lines there and overflows by 10px — caught in CI the first time these
/// states were written, with a rendering exception and no visible cause. Say
/// one thing; the profile screen and the admin screen carry the detail.
class _TileVisual {
  const _TileVisual({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.chip,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? chip;
}

_TileVisual _visualFor(DocReviewState? status) {
  switch (status) {
    case null:
      return const _TileVisual(
        icon: Icons.badge_outlined,
        color: AppTheme.textMuted,
        title: 'Verification',
        subtitle: 'Checking your documents…',
      );
    case DocReviewState.verified:
      return const _TileVisual(
        icon: Icons.verified_user,
        color: AppTheme.primaryGreen,
        title: 'Identity verified',
        subtitle: 'Your ID was checked and accepted.',
        chip: 'Verified',
      );
    case DocReviewState.pending:
      // The state this bug lived in. A document is on file and NOBODY has
      // looked at it, which used to render the green "Verified" chip above.
      return const _TileVisual(
        icon: Icons.hourglass_top_rounded,
        color: AppTheme.info,
        title: 'ID awaiting review',
        subtitle: 'Received — our team is checking it now.',
        chip: 'In review',
      );
    case DocReviewState.rejected:
      return const _TileVisual(
        icon: Icons.gpp_bad_outlined,
        color: AppTheme.error,
        title: 'ID not accepted',
        subtitle: 'Not accepted. Tap to upload a clearer one.',
        chip: 'Rejected',
      );
    case DocReviewState.flagged:
      return const _TileVisual(
        icon: Icons.report_problem_outlined,
        color: AppTheme.error,
        title: 'ID under investigation',
        subtitle: 'Flagged for a manual check by our team.',
        chip: 'Flagged',
      );
    case DocReviewState.none:
      return const _TileVisual(
        icon: Icons.badge_outlined,
        color: AppTheme.gold,
        title: 'Verify your identity',
        subtitle: 'Not verified — upload an ID to unlock provider actions.',
        chip: 'Not verified',
      );
    case DocReviewState.unknown:
      return const _TileVisual(
        icon: Icons.cloud_off_outlined,
        color: AppTheme.error,
        title: 'Verification status unknown',
        subtitle: "We couldn't check your documents — tap to retry.",
        chip: 'Retry',
      );
  }
}
