import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:storage_client/storage_client.dart' show FileOptions;
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/cart_service.dart';
import '../../core/services/document_upload_service.dart';
import '../../core/utils/order_number_format.dart' as onf;
import '../../core/utils/friendly_error.dart';

class UserCheckoutScreen extends ConsumerStatefulWidget {
  final String providerId;
  const UserCheckoutScreen({super.key, required this.providerId});
  @override
  ConsumerState<UserCheckoutScreen> createState() => _UserCheckoutScreenState();
}

class _UserCheckoutScreenState extends ConsumerState<UserCheckoutScreen> {
  List<CartItem> _items = [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  DateTime? _lastOrderTime;
  final _addressCtrl = TextEditingController();
  final _refCtrl = TextEditingController();

  // Phase 4: shared selection flow — Delivery or Self-pickup. Self-pickup
  // pays the product price only (no delivery), delivery shows the address
  // step. Both paths share the same payment step below.
  String _fulfillmentMode = 'DELIVERY';
  File? _screenshot;
  File? _nationalId;
  final _picker = ImagePicker();

  /// Whether this buyer still needs to provide a National ID. Users sign up
  /// with only email/phone/password, so the ID is verified at booking time —
  /// attached alongside the payment proof on their first order. Once a
  /// NATIONAL_ID document exists in user_documents, no upload is needed.
  bool _needsNationalId = true;

  /// True when at least one item in this cart is a listing whose provider
  /// must confirm it is available before the buyer is shown payment details
  /// or the screenshot upload.
  ///
  /// Snapshotted onto the order by `create_order_secure` at the moment the
  /// order is created, so the gate cannot move under a buyer after they have
  /// paid. Read here from the products themselves, best-effort: a database
  /// that has not run migration 20260927000074 has no such column, the read
  /// raises, and the flag stays false — the order is then placed exactly as
  /// it was before this feature existed.
  bool _needsAvailabilityConfirmation = false;

  /// Provider readiness (Fix: orders are blocked when the provider's wallet is
  /// 0 — they cannot cover the transaction fee — or when the provider has not
  /// yet paid the one-time registration fee).
  bool _providerActivated = true;
  bool _providerHasBalance = true;
  String _providerName = 'The provider';

  /// The provider's category and city, which is what the commission is
  /// resolved AGAINST.
  ///
  /// These exist because 0107 made the commission per-category and per-city.
  /// The quote below used to call the one-argument
  /// `platform_transaction_fee()`, which resolves the GLOBAL rate, while
  /// `deduct_transaction_fee()` charges `platform_transaction_fee_for()` with
  /// the provider's real category and city. The moment an admin set a
  /// category or city override, the figure on this screen stopped being the
  /// figure the provider is charged — and the old comment here claimed the
  /// opposite, which is how it survived review. Null until loaded, and null
  /// is a valid input that means "fall back to the global rate", so a failed
  /// provider read degrades to exactly the old behaviour.
  String? _feeCity;
  String? _feeCategoryId;

  /// Re-fetches the provider's activation/wallet state. Called on load and
  /// again after returning from the waiting screen, so a provider who has just
  /// recharged does not bounce the buyer straight back to waiting.
  Future<void> _refreshProviderReadiness() async {
    try {
      final prov = await Supabase.instance.client
          .from('public_provider_profiles')
          .select(
              'business_name, registration_fee_paid, status, category_id, city')
          .eq('id', widget.providerId)
          .maybeSingle();
      if (prov != null) {
        _providerName = (prov['business_name'] as String?)?.isNotEmpty == true
            ? prov['business_name'] as String
            : _providerName;
        // Raw city, NOT pre-normalised: `category_fee()` does
        // `lower(btrim(coalesce(p_city,'')))` itself, so normalising here
        // would be a second place for the rule to live and a second place for
        // it to be wrong.
        final rawCity = (prov['city'] as String?)?.trim();
        _feeCity = (rawCity == null || rawCity.isEmpty) ? null : rawCity;
        final rawCat = prov['category_id']?.toString();
        _feeCategoryId =
            (rawCat == null || rawCat.isEmpty) ? null : rawCat;
        _providerActivated = (prov['registration_fee_paid'] as bool?) == true &&
            prov['status'] == 'APPROVED';
        final wallet = await Supabase.instance.client
            .from('wallets')
            .select('balance')
            .eq('provider_id', widget.providerId)
            .maybeSingle();
        _providerHasBalance =
            ((wallet?['balance'] as num?)?.toDouble() ?? 0) > 0;
      }
    } catch (_) {
      // Non-fatal: if it fails, the server-side gate in create_order_secure
      // still blocks and the error is surfaced after submission.
    }
  }

  /// The platform commission for this order, quoted live by
  /// platform_transaction_fee_for() using the SAME category, city and
  /// is_product flag that deduct_transaction_fee() will use, so this figure
  /// cannot drift from what the provider is actually charged.
  ///
  /// The last argument is `true` because the charge passes
  /// `p_order_id IS NOT NULL` — this quote is for an order. Getting that
  /// backwards would quote the product rate for an order, or the order rate
  /// for a booking.
  double? _platformFee;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await CartService.instance.getCart();
      final items =
          all.where((i) => i.providerId == widget.providerId).toList();
      // BEFORE the fee quote. This read is what populates _feeCategoryId and
      // _feeCity; quoting first would resolve them as null, fall back to the
      // global rate, and silently reintroduce exactly the drift this quote
      // exists to remove. Ordering, not correctness, is the whole fix here.
      await _refreshProviderReadiness();
      // The commission is resolved per category and per city, and it is the
      // CEO's to change at any time, so it is quoted from the server rather
      // than recomputed here. The category, city and is_product flag are the
      // provider's own, so the quote and the charge resolve identically.
      // Informational: hide the row entirely if it cannot be loaded.
      double? platformFee;
      try {
        final subtotal = items.fold<double>(0.0, (sum, i) => sum + i.lineTotal);
        final quoted = await Supabase.instance.client.rpc(
          'platform_transaction_fee_for',
          params: {
            'p_amount': subtotal,
            'p_category_id': _feeCategoryId,
            'p_city': _feeCity,
            // This quote is for an order, matching deduct_transaction_fee()'s
            // `p_order_id IS NOT NULL`.
            'p_is_product': true,
          },
        );
        final v = (quoted as num?)?.toDouble();
        if (v != null && v > 0) platformFee = v;
      } catch (_) {
        // Any argument the server does not recognise (an older deployment
        // that has not run 0107 yet) raises rather than returning null, so
        // fall back to the global rate. A hidden row is better than a wrong
        // one, and the server still charges the truth either way.
        try {
          final subtotal =
              items.fold<double>(0.0, (sum, i) => sum + i.lineTotal);
          final quoted = await Supabase.instance.client
              .rpc('platform_transaction_fee', params: {'p_amount': subtotal});
          final v = (quoted as num?)?.toDouble();
          if (v != null && v > 0) platformFee = v;
        } catch (_) {}
      }
      // Skip the ID upload for buyers who already verified one at signup
      // (older accounts / re-installed app). Best-effort: on failure the
      // checkout keeps asking for the ID, which is always safe.
      try {
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid != null) {
          final existing = await Supabase.instance.client
              .from('user_documents')
              .select('id')
              .eq('user_id', uid)
              .eq('document_type', 'NATIONAL_ID')
              .limit(1)
              .maybeSingle();
          if (existing != null) _needsNationalId = false;
        }
      } catch (_) {}

      // Does anything in this cart need the provider to confirm it is
      // available? One gated item gates the order: the buyer pays for the
      // whole basket in one transfer, so there is no way to split the
      // payment screen either. Same best-effort rule as the fee quote
      // above — a failure here means "not gated", which is the behaviour
      // that was already working.
      var needsConfirmation = false;
      try {
        final ids = items.map((i) => i.productId).toList();
        if (ids.isNotEmpty) {
          final rows = await Supabase.instance.client
              .from('products')
              .select('id, requires_availability_confirmation')
              .inFilter('id', ids);
          needsConfirmation = (rows as List)
              .any((r) => r['requires_availability_confirmation'] == true);
        }
      } catch (_) {
        needsConfirmation = false;
      }

      if (mounted) {
        setState(() {
          _items = items;
          _platformFee = platformFee;
          _needsAvailabilityConfirmation = needsConfirmation;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your cart';
        });
      }
    }
  }

  double get _total => _items.fold(0.0, (sum, i) => sum + i.lineTotal);

  Future<void> _pickScreenshot() async {
    // Downscaled like every other bucket upload in the app. payment-proofs
    // allows 10MB, which hides the problem on most phones but not on a
    // 48MP camera image — the same defect the provider recharge screen had,
    // fixed there first.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _screenshot = File(picked.path));
    }
  }

  Future<void> _pickNationalId() async {
    // user-documents allows 10MB and takes jpeg/png/webp/pdf, so this one
    // has the same latent refusal as the screenshot above.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null) {
      setState(() => _nationalId = File(picked.path));
    }
  }

  Future<void> _placeOrder() async {
    // Duplicate-tap guard: prevent double-submission within 3 seconds.
    final now = DateTime.now();
    if (_lastOrderTime != null &&
        now.difference(_lastOrderTime!) < const Duration(seconds: 3)) {
      return; // silently ignore rapid re-tap
    }
    _lastOrderTime = now;

    if (_items.isEmpty) {
      setState(() => _error = 'Your cart is empty for this provider');
      return;
    }
    if (_needsNationalId && _nationalId == null) {
      setState(() => _error =
          'Please upload a photo of your National ID to place an order');
      return;
    }

    // Provider readiness: a not-yet-activated provider (one-time registration
    // fee unpaid) or a 0-balance wallet cannot accept the order — the
    // server-side gate in create_order_secure would reject it. Re-check at
    // submission time (a provider may have just recharged), then show the
    // waiting screen instead of submitting an order that would fail; it
    // re-checks the provider and sends the buyer back to browse on timeout.
    await _refreshProviderReadiness();
    if (mounted) setState(() {});
    if (!_providerActivated || !_providerHasBalance) {
      await context.push('/user/order-waiting', extra: {
        'providerId': widget.providerId,
        'providerName': _providerName,
        'providerNotActivated': !_providerActivated,
      });
      if (!mounted) return;
      // Back from waiting: re-check — if the provider is ready now, fall
      // through and place the order; otherwise the user can retry or cancel.
      await _refreshProviderReadiness();
      if (!mounted) return;
      if (!_providerActivated || !_providerHasBalance) return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Once order-create returns, the order EXISTS. Everything after that
    // point is bookkeeping, and none of it is allowed to report failure —
    // the outer catch used to set "Could not place your order" for a thrown
    // clearCart()/invalidate/showDialog, which would tell the user their
    // order failed when it had in fact been created, inviting them to submit
    // again and place a duplicate.
    String? createdOrderId;
    var orderCreated = false;
    try {
      final client = Supabase.instance.client;

      // Send ONLY product_id + quantity — the server computes prices/total.
      // Quantity stays a double: unit-priced lines (kg/liter) are fractional
      // (order_items.quantity is numeric(10,3)); fixed-price lines are whole.
      final noteParts = <String>[
        if (_fulfillmentMode == 'SELF_PICKUP') 'Fulfillment: self-pickup',
        if (_fulfillmentMode == 'DELIVERY' &&
            _addressCtrl.text.trim().isNotEmpty)
          'Delivery: ${_addressCtrl.text.trim()}',
        if (_refCtrl.text.trim().isNotEmpty)
          'Payment ref: ${_refCtrl.text.trim()}',
      ];
      final result = await client.functions.invoke('order-create', body: {
        'provider_id': widget.providerId,
        'items': _items
            .map((i) => {'product_id': i.productId, 'quantity': i.quantity})
            .toList(),
        if (noteParts.isNotEmpty) 'note': noteParts.join(' | '),
        'fulfillment_mode': _fulfillmentMode,
        if (_fulfillmentMode == 'DELIVERY')
          'delivery_address': _addressCtrl.text.trim(),
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final order = data['order'] as Map<String, dynamic>?;
      final orderId = order?['id'] as String?;
      createdOrderId = orderId;
      orderCreated = true;
      final orderNumber =
          onf.formatOrderNumber(order?['order_number'] as String?);

      // ID on file → upload it with the same retry as signup (user_documents).
      // Follows the screenshot pattern: the order is already placed, so a
      // failed upload surfaces a message instead of blocking or duplicating
      // the order. The user can retry from their profile / support.
      String? idIssue;
      if (_needsNationalId && _nationalId != null) {
        try {
          await DocumentUploadService.instance.uploadAndRecord(
            file: _nationalId!,
            userId: client.auth.currentUser!.id,
            documentType: 'NATIONAL_ID',
          );
        } catch (_) {
          idIssue =
              'Your order was placed, but the National ID photo could not be '
              'uploaded. Open Profile → Verify Document (or Help & Support) '
              'to retry so your identity can be verified.';
        }
      }

      // Optional payment screenshot → existing 'payment-proofs' bucket,
      // linked to the order in payment_proofs (user-insert RLS allows this).
      String? screenshotIssue;
      if (_screenshot != null && orderId != null) {
        try {
          final userId = client.auth.currentUser!.id;
          final fileName = '${DateTime.now().millisecondsSinceEpoch}.jpg';
          final path = '$userId/$orderId/$fileName';
          await client.storage.from('payment-proofs').upload(path, _screenshot!,
              fileOptions: const FileOptions(upsert: true));
          await client.from('payment_proofs').insert({
            'order_id': orderId,
            'storage_path': path,
          });
        } catch (_) {
          screenshotIssue =
              'Your order was placed, but the payment screenshot could not be attached.';
        }
      }

      // Cart clearing is best-effort for the same reason the uploads above
      // are: it runs after the order exists, so a failure must be reported as
      // a leftover cart, not as a failed order. The user can empty the cart
      // from the cart screen.
      var cartIssue = false;
      try {
        await CartService.instance.clearCart();
        ref.invalidate(cartCountProvider);
      } catch (_) {
        cartIssue = true;
      }

      if (!mounted) return;
      setState(() => _submitting = false);
      final dialogMessage = idIssue ??
          screenshotIssue ??
          (cartIssue
              ? 'Your order has been placed successfully, but your cart could '
                  'not be cleared automatically. Please empty it from the cart.'
              : (orderNumber != null
                  ? 'Order $orderNumber has been placed successfully. '
                      'You can track it in My Orders.'
                  : 'Your order has been placed successfully. You can track it in My Orders.'));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => AlertDialog(
          icon: Icon(
              (idIssue != null || screenshotIssue != null)
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle,
              color: (idIssue != null || screenshotIssue != null)
                  ? AppTheme.warning
                  : AppTheme.success,
              size: 44),
          title: const Text('Order placed'),
          content: Text(dialogMessage),
          actions: [
            TextButton(
              onPressed: () {
                dialogCtx.pop();
                if (orderId != null) {
                  context.go('/user/orders/$orderId');
                } else {
                  context.go('/user?tab=1');
                }
              },
              child: const Text('VIEW ORDER'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      if (orderCreated) {
        // The order is real. Say so plainly and send them to it rather than
        // implying it failed — otherwise the obvious next move is to submit
        // again, and that creates a duplicate order.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e,
                context: 'Your order was placed, but we could not finish the last step')),
            backgroundColor: AppTheme.warning,
          ),
        );
        context.go(createdOrderId != null
            ? '/user/orders/$createdOrderId'
            : '/user?tab=1');
        return;
      }
      setState(() {
        _error = friendlyError(e, context: 'Could not place your order');
      });
    }
  }

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _items.isEmpty
              ? const Center(
                  child: Text('Your cart is empty for this provider',
                      style: TextStyle(color: AppTheme.textMuted)))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_error != null)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 16),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(_error!,
                              style: const TextStyle(
                                  fontSize: 13, color: AppTheme.error)),
                        ),
                      const Text('Order Summary',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppTheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Column(
                          children: [
                            for (final item in _items)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(item.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w500)),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                        '${_fmtQty(item.quantity)} ${item.unit != null ? item.unitLabel : '×'} '
                                        '${item.price.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.textSecondary)),
                                    const SizedBox(width: 12),
                                    Text(item.lineTotal.toStringAsFixed(2),
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            const Divider(height: 20),
                            if (_platformFee != null) ...[
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                      'Platform fee '
                                      '(charged to provider)',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textMuted)),
                                  Text(
                                    '-${_platformFee!.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textMuted),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Total',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700)),
                                Text(
                                  '${_total.toStringAsFixed(2)} '
                                  '${_items.first.currency}',
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.primaryGreen),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      // Phase 4: fulfillment selection (shared flow).
                      const Text('How do you want to get it?',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _FulfillmentCard(
                              icon: Icons.local_shipping_outlined,
                              title: 'Delivery',
                              subtitle: 'Brought to your address',
                              selected: _fulfillmentMode == 'DELIVERY',
                              onTap: () =>
                                  setState(() => _fulfillmentMode = 'DELIVERY'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _FulfillmentCard(
                              icon: Icons.store_outlined,
                              title: 'Self-pickup',
                              subtitle: 'Pay product price only',
                              selected: _fulfillmentMode == 'SELF_PICKUP',
                              onTap: () => setState(
                                  () => _fulfillmentMode = 'SELF_PICKUP'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_fulfillmentMode == 'DELIVERY') ...[
                        const Text('Delivery Details',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 12),
                        BirrTextField(
                          label: 'Delivery Address',
                          controller: _addressCtrl,
                          maxLines: 2,
                          hint: 'Street, area, city',
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_fulfillmentMode == 'SELF_PICKUP') ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryGreen.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color:
                                    AppTheme.primaryGreen.withOpacity(0.25)),
                          ),
                          child: const Text(
                            'Self-pickup: pay the product price only and collect '
                            'it from the provider. Their contact details become '
                            'available after payment approval.',
                            style: TextStyle(fontSize: 12.5, height: 1.4),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      // ── Payment ──
                      //
                      // Gated behind the provider's availability
                      // confirmation. A listing flagged
                      // requires_availability_confirmation is one where
                      // "in stock" is a claim rather than a fact — a
                      // hotel room, a vehicle for a date, a service slot
                      // — so the buyer is not shown where to pay, or a
                      // way to pay, until the provider has confirmed it
                      // exists for this order. The order is still placed
                      // now; it opens in PENDING_PROVIDER, the provider
                      // confirms from their order screen, and the buyer's
                      // order detail then shows the payment card with the
                      // accounts AND the upload button together.
                      //
                      // That last part used to be false. The card appeared at
                      // ACCEPTED but the upload button did not, because the
                      // button lived on PAYMENT_PENDING and only the
                      // provider could move an order there — so this notice
                      // promised an upload option that the order screen did
                      // not actually have. Migration 85 lets the buyer open
                      // that step themselves on a gated order, which is what
                      // makes the sentence below true.
                      //
                      // Nothing here is a second checkout: the same
                      // order-create call, the same order, the same
                      // payment-proof upload and the same admin
                      // verification — only the moment the payment
                      // section appears is conditional. Listings with
                      // the flag off (every listing today) see exactly
                      // the screen they saw before.
                      if (_needsAvailabilityConfirmation) ...[
                        _AvailabilityNotice(),
                        const SizedBox(height: 20),
                      ] else ...[
                        BirrTextField(
                          label: 'Payment Reference (optional)',
                          controller: _refCtrl,
                          hint: 'Transaction ID or reference number',
                        ),
                        const SizedBox(height: 16),
                        const Text('Payment Screenshot (optional)',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: _pickScreenshot,
                          child: Container(
                            width: double.infinity,
                            height: _screenshot != null ? 160 : 110,
                            decoration: BoxDecoration(
                              color: AppTheme.creamDark,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: AppTheme.cardBorder),
                            ),
                            child: _screenshot != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(_screenshot!,
                                        fit: BoxFit.cover),
                                  )
                                : const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_a_photo_outlined,
                                          size: 32, color: AppTheme.textMuted),
                                      SizedBox(height: 8),
                                      Text('Tap to upload proof of payment',
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (_needsNationalId) ...[
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            const Expanded(
                              child: Text('National ID (required)',
                                  style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppTheme.gold.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('VERIFICATION',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.gold)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                            'First-time verification: we need a photo of your '
                            'National ID to confirm your identity. It is stored '
                            'securely and only visible to our admin team.',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textMuted)),
                        const SizedBox(height: 8),
                        GestureDetector(
                          onTap: _pickNationalId,
                          child: Container(
                            width: double.infinity,
                            height: _nationalId != null ? 160 : 110,
                            decoration: BoxDecoration(
                              color: AppTheme.creamDark,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: _nationalId != null
                                      ? AppTheme.primaryGreen
                                      : AppTheme.cardBorder),
                            ),
                            child: _nationalId != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Image.file(_nationalId!,
                                        fit: BoxFit.cover),
                                  )
                                : const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.badge_outlined,
                                          size: 32, color: AppTheme.textMuted),
                                      SizedBox(height: 8),
                                      Text('Tap to upload your National ID',
                                          style: TextStyle(
                                              fontSize: 13,
                                              color: AppTheme.textMuted)),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        // On a gated listing the press does not pay and does
                        // not claim the booking: it ASKS the provider. So the
                        // button says what it does — "check availability" —
                        // rather than "request order", which reads as a
                        // purchase the buyer has not made yet.
                        child: PrimaryButton(
                          label: _needsAvailabilityConfirmation
                              ? 'CHECK AVAILABILITY'
                              : 'PLACE ORDER',
                          isLoading: _submitting,
                          onPressed: _placeOrder,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// Stands in for the payment section when the cart needs a provider
/// confirmation first.
///
/// Says what is happening and what happens next, because the alternative --
/// silently omitting the payment fields -- reads as a broken screen. The
/// wording deliberately promises nothing about timing: the provider sets it.
class _AvailabilityNotice extends StatelessWidget {
  const _AvailabilityNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.gold.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.gold.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hourglass_top_rounded,
                  size: 18, color: AppTheme.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Waiting for provider to confirm availability',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'This booking is made for a specific date, room or slot, so the '
            'provider has to confirm it is available before you pay. Send the '
            'request now — as soon as they confirm, the payment details and '
            'your upload option appear on the order, and you will be notified.',
            style: TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }
}

/// Phase 4: delivery vs self-pickup selection card (shared across the
/// product/service flow).
class _FulfillmentCard extends StatelessWidget {
  const _FulfillmentCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTheme.primaryGreen.withOpacity(0.08)
          : AppTheme.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.primaryGreen : AppTheme.cardBorder,
              width: selected ? 1.4 : 0.5,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon,
                  size: 20,
                  color:
                      selected ? AppTheme.primaryGreen : AppTheme.textMuted),
              const SizedBox(height: 6),
              Text(title,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? AppTheme.primaryGreen
                          : AppTheme.textPrimary)),
              Text(subtitle,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
