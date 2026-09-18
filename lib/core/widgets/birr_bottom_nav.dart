import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../services/cart_service.dart';

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
              _item(context, 1, Icons.search_outlined, Icons.search_rounded, 'Search'),
              _item(context, 2, Icons.receipt_long_outlined, Icons.receipt_long_rounded,
                  'Orders', cartBadge: cartCount),
              _item(context, 3, Icons.notifications_outlined, Icons.notifications_rounded,
                  'Alerts'),
              _item(context, 4, Icons.person_outlined, Icons.person_rounded, 'Profile'),
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
        width: 62,
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
            // Cart entry point badge on the Orders tab.
            if (index == 2)
              Positioned(
                top: -4,
                right: 4,
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
