import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/provider_doc_gate.dart';
import '../../core/services/provider_readiness.dart';
import '../../core/theme/app_theme.dart';

/// "You cannot publish yet, and here is why" — on the provider dashboard,
/// above the actions, before any form is opened.
///
/// ## Why this is not a snackbar
///
/// The failure this replaces was invisible until the last possible moment: a
/// provider filled in the whole listing form and pressed Save, and the server
/// refused. Every field they had typed was a dead end. This banner answers the
/// same question at the top of the dashboard instead, where it costs nothing
/// to read and where the answer can carry a button.
///
/// ## Why it shows the SERVER's reasons
///
/// Not `ProviderDocGate`. That gate is client-side and deliberately counts a
/// document awaiting review as good enough; the server does not (migration
/// 0113). Displaying the client's answer here is what produced the original
/// bug in the first place — see `ProviderReadiness`.
class PublishReadinessBanner extends StatelessWidget {
  const PublishReadinessBanner({
    super.key,
    required this.readiness,
    this.onChanged,
  });

  final ProviderReadiness readiness;

  /// Called after the provider acts on a remedy, so the dashboard can re-read
  /// the server instead of assuming the fix worked.
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    // Unknown is not "ready". Say so plainly and do not pretend.
    if (!readiness.checked) return const SizedBox.shrink();
    if (readiness.reasons.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline,
                  color: AppTheme.warning, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Finish these before you can publish',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final code in readiness.reasons) ...[
            _ReasonRow(code: code, onChanged: onChanged),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _ReasonRow extends StatelessWidget {
  const _ReasonRow({required this.code, this.onChanged});

  final String code;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final remedy = ProviderReadiness.remedyFor(code);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Icon(Icons.circle, size: 6, color: AppTheme.textMuted),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                remedy.phrase,
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              // The button is the point. A banner that only explains leaves
              // the provider exactly where they were.
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _act(context, remedy.route),
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: Text(remedy.action),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: const BorderSide(color: AppTheme.primaryGreen),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _act(BuildContext context, String? route) async {
    // A null route is the document sheet, which is a dialog rather than a
    // screen. Uploading is what moves DOCUMENTS_UNVERIFIED along, so this is
    // the one reason the banner can actually resolve itself from here.
    if (route == null) {
      await ProviderDocGate.instance.ensureDocuments(context);
      onChanged?.call();
      return;
    }
    if (!context.mounted) return;
    await context.push(route);
    // Coming back from a fix, the answer may have changed — a recharge, a
    // renewal. Re-read rather than assume.
    onChanged?.call();
  }
}
