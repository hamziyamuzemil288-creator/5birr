import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The single prominent shortcut a dashboard offers above its tabbed content.
///
/// Extracted from the "Book a ride" pill on the user home screen, which was
/// the only instance of this pattern and therefore the only definition of it.
/// Every role now uses this widget rather than a hand-copied button, because
/// the alternative is the thing this repo keeps paying for: three separately
/// hand-written pills that drift into three different button styles, and a
/// redesign that has to be applied three times.
///
/// The style is fixed rather than parameterised on purpose. It is a single
/// brand-green pill, not a button kit:
///
/// * `AppTheme.primaryGreen` fill, white icon and label
/// * fully rounded (20), sized to its content rather than stretched
/// * 13px / w700 label beside a 17px icon, 7px apart
/// * 16px horizontal, 9px vertical padding
///
/// Content is left-aligned within the padded gutter, matching where the user
/// home screen puts it, so the pill sits in the same optical position on every
/// dashboard.
class QuickActionPill extends StatelessWidget {
  const QuickActionPill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: AppTheme.primaryGreen,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: Colors.white, size: 17),
                  const SizedBox(width: 7),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
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
