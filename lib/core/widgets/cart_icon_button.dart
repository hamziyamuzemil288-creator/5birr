import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../services/cart_service.dart';

/// Cart icon with a live item-count badge for app bars / headers.
/// Watches [cartCountProvider]; invalidate it after cart mutations
/// (already done by CartService callers).
class CartIconButton extends ConsumerWidget {
  /// Icon color (defaults to theme icon color; use Colors.white on
  /// green/gradient headers).
  final Color? iconColor;

  const CartIconButton({super.key, this.iconColor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider).valueOrNull ?? 0;
    return IconButton(
      tooltip: 'Cart',
      onPressed: () => context.push('/user/cart'),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(Icons.shopping_cart_outlined, color: iconColor),
          if (count > 0)
            Positioned(
              top: -5,
              right: -7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppTheme.error,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: AppTheme.surface, width: 1.5),
                ),
                constraints: const BoxConstraints(minWidth: 17, minHeight: 17),
                child: Text(
                  count > 99 ? '99+' : '$count',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
