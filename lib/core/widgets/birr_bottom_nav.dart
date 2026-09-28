import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/cart_service.dart';
import '../theme/app_theme.dart';

/// The user bottom bar: Home | Order | Favourite | Account.
///
/// ## Why it changed
///
/// The previous bar was Home | Search | Orders | Alerts | Profile. The
/// founder's sketch replaces it with four tabs, and two of the five were
/// reachable elsewhere in the new header, so dropping them was not a loss:
///
/// * **Search** moved to the header icon (per the sketch). It was a
///   destination, not a mode — the search screen is still reachable at
///   `/user/search` and from the header on every home tab.
/// * **Alerts** moved to a bell in the header. A full-width nav slot is a
///   poor place for something most people open rarely and urgently.
///
/// ## Index stability
///
/// The `?tab=N` deep link is used by checkout success, the help chatbot and
/// the home menu. The indices below are the contract; changing the order
/// silently re-points all of them. The mapping is:
///
/// | index | tab        | notes                                        |
/// |-------|------------|----------------------------------------------|
/// | 0     | Home       |                                              |
/// | 1     | Order      | was index 2                                 |
/// | 2     | Favourite  | new; the screen already existed, unwired     |
/// | 3     | Account    | was index 4 (Profile)                       |
class BirrBottomNav extends ConsumerWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const BirrBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cartCount = ref.watch(cartCountProvider).valueOrNull ?? 0;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _item(context, 0, Icons.home_outlined, Icons.home_rounded, 'Home'),
              _item(context, 1, Icons.receipt_long_outlined,
                  Icons.receipt_long_rounded, 'Order',
                  cartBadge: cartCount),
              _item(context, 2, Icons.favorite_outline, Icons.favorite_rounded,
                  'Favourite'),
              _item(context, 3, Icons.person_outline, Icons.person_rounded,
                  'Account'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(
    BuildContext context,
    int index,
    IconData outline,
    IconData filled,
    String label, {
    int cartBadge = 0,
  }) {
    final selected = currentIndex == index;
    return GestureDetector(
      onTap: () => onTap(index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 72,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Active indicator pill with glow
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  width: selected ? 48 : 0,
                  height: 3,
                  margin: const EdgeInsets.only(bottom: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: selected
                        ? [
                            BoxShadow(
                              color: AppTheme.primaryGreen.withOpacity(0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : null,
                  ),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: selected
                      ? BoxDecoration(
                          color: AppTheme.primaryGreen.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(14),
                        )
                      : null,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          selected ? filled : outline,
                          key: ValueKey<bool>(selected),
                          color: selected ? AppTheme.primaryGreen : AppTheme.textMuted,
                          size: selected ? 24 : 22,
                        ),
                      ),
                      const SizedBox(height: 3),
                      AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        style: TextStyle(
                          fontSize: selected ? 11 : 10,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                          color: selected ? AppTheme.primaryGreen : AppTheme.textMuted,
                        ),
                        child: Text(label),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
              ],
            ),
            // Cart entry point badge on the Order tab. It is a shortcut, not
            // the tab itself: tapping the badge goes to the cart, tapping the
            // tab goes to the order list.
            if (index == 1)
              Positioned(
                top: -4,
                right: 6,
                child: GestureDetector(
                  onTap: () => context.push('/user/cart'),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutBack,
                    padding: EdgeInsets.symmetric(
                        horizontal: cartBadge > 0 ? 6 : 4,
                        vertical: cartBadge > 0 ? 2 : 3),
                    decoration: BoxDecoration(
                      color: cartBadge > 0
                          ? AppTheme.error
                          : AppTheme.textMuted.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: cartBadge > 0
                          ? [
                              BoxShadow(
                                color: AppTheme.error.withOpacity(0.4),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: cartBadge > 0
                        ? Text('$cartBadge',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700))
                        : const Icon(Icons.shopping_cart_outlined,
                            size: 11, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
