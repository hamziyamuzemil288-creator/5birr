import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The subcategory chip used on every category screen.
///
/// ## Why this is a widget and not an inline `ActionChip`
///
/// The chips were built inline and picked up the app-wide
/// `ChipThemeData`, which supplies a cream background and a `labelStyle`
/// that carries a font size but **no colour of its own**. That leaves the
/// label colour to whatever `DefaultTextStyle` the chip happens to resolve
/// against, so contrast with the background was decided by the ambient
/// text style rather than by the chip. It looked fine in some places and
/// washed out in others — which is what made the "Interior Design" /
/// "Moving & Packing" labels unreadable on the category screen.
///
/// Every value that affects legibility is stated here — background, label
/// colour, side — so the chip cannot inherit a colour from anywhere. One
/// definition also means "apply this to every subcategory chip on every
/// category screen" is a single edit, not a search.
class SubcategoryChip extends StatelessWidget {
  const SubcategoryChip({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      // Brand green fill with white text: the same pairing the tab row, the
      // header gradient and the primary buttons already use, and a contrast
      // ratio (white on #1B5E20) far above the 4.5:1 minimum.
      backgroundColor: AppTheme.primaryGreen,
      // Deliberately no `selectedColor` / `disabledColor`: this is an
      // ActionChip, whose constructor has neither, and a chip that cannot be
      // selected or disabled has nothing to colour in those states anyway.
      // onPressed is always non-null, so the chip is never drawn disabled.
      // No side: a border on a saturated fill only muddies the edge.
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      // Stated here as well as on the label so it wins over the app-wide
      // chipTheme regardless of how the two are merged.
      labelStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
      ),
      onPressed: onTap,
    );
  }
}
