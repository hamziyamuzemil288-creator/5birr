import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/cart_service.dart';
import '../theme/app_theme.dart';
import '../utils/friendly_error.dart';

/// The BUY / BOOK action every listing tile carries.
///
/// This is the missing way INTO a flow the app already implements end to end.
/// It is deliberately the same entry point on the home rail, a category list
/// and a provider page, because there is only one flow behind it:
///
///   Buy  ->  this listing joins the cart and checkout opens for its provider
///        ->  checkout asks the provider to confirm availability when the
///            listing is flagged `requires_availability_confirmation`
///            ("REQUEST ORDER"), and shows the payment step when it is not
///        ->  the provider answers from their order screen
///            ("Confirm Availability" / "Not Available")
///        ->  on YES the order detail unlocks the provider's payment accounts
///            AND the screenshot upload together (the "where to pay" card)
///        ->  once payment is verified the provider's contact and GPS are
///            released on the same order screen.
///
/// Nothing new is invented here: no new status, no new RPC, no second checkout.
/// The button adds the listing and navigates; every rule after that already
/// lives in `create_order_secure`, `order-transition` and `release_order_contact`.
class ProductBuyButton extends ConsumerStatefulWidget {
  /// The listing to buy. Empty means "this tile is a provider, not a listing":
  /// the tap opens the provider's page so a buyer can choose from it, which is
  /// the only useful "Book" a provider photo can offer.
  final String productId;
  final String providerId;

  /// What the buyer sees: "Buy" for a product, "Book" for a service.
  final String label;

  /// Shrinks the button for a dense grid tile.
  final bool compact;

  const ProductBuyButton({
    super.key,
    required this.providerId,
    this.productId = '',
    this.label = 'Buy',
    this.compact = false,
  });

  @override
  ConsumerState<ProductBuyButton> createState() => _ProductBuyButtonState();
}

class _ProductBuyButtonState extends ConsumerState<ProductBuyButton> {
  bool _busy = false;

  Future<void> _buy() async {
    if (_busy) return;
    // A provider tile has no listing to add; send the buyer to the provider so
    // the tap is never dead.
    if (widget.productId.isEmpty) {
      context.push('/user/provider/${widget.providerId}');
      return;
    }
    setState(() => _busy = true);
    try {
      await CartService.instance.addToCart(
        productId: widget.productId,
        quantity: 1,
      );
      ref.invalidate(cartCountProvider);
      if (!mounted) return;
      // The provider id is the checkout's argument, so the cart's line for
      // this listing is already what the checkout reads.
      context.push('/user/checkout', extra: widget.providerId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(friendlyError(e, context: 'Could not start this order')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.compact ? 30 : 34,
      child: ElevatedButton(
        onPressed: _busy ? null : _buy,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryGreen,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppTheme.primaryGreen.withOpacity(0.6),
          disabledForegroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 12 : 16),
          minimumSize: const Size(0, 0),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(9),
          ),
          textStyle: TextStyle(
            fontSize: widget.compact ? 11.5 : 12.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        child: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(widget.label.toUpperCase()),
      ),
    );
  }
}
