import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'primary_button.dart';

/// Full-screen "we could not load this" state with a retry.
///
/// Many screens previously cleared their spinner in a catch block and fell
/// straight through to their empty state, so a failed request rendered
/// "No rides yet" / "No orders yet" / "No transactions yet" — telling the user
/// they have no history when the truth is that the request failed. On a
/// screen showing someone's balance or active ride that is actively
/// misleading.
///
/// Pass the message from `friendlyError(e, context: ...)` so the copy stays
/// calm and consistent, and the raw exception never reaches the user.
class LoadErrorView extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  final String retryLabel;
  final IconData icon;

  const LoadErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryLabel = 'Retry',
    this.icon = Icons.cloud_off_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: retryLabel,
              icon: Icons.refresh,
              // PrimaryButton takes a VoidCallback, so wrap rather than
              // handing it a Future-returning function.
              onPressed: () {
                onRetry();
              },
            ),
          ],
        ),
      ),
    );
  }
}
