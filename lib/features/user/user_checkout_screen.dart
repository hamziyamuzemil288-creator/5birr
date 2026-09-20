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
  File? _screenshot;
  File? _nationalId;
  final _picker = ImagePicker();

  /// Whether this buyer still needs to provide a National ID. Users sign up
  /// with only email/phone/password, so the ID is verified at booking time —
  /// attached alongside the payment proof on their first order. Once a
  /// NATIONAL_ID document exists in user_documents, no upload is needed.
  bool _needsNationalId = true;

  /// Provider readiness (Fix: orders are blocked when the provider's wallet is
  /// 0 — they cannot cover the transaction fee — or when the provider has not
  /// yet paid the one-time registration fee).
  bool _providerActivated = true;
  bool _providerHasBalance = true;
  String _providerName = 'The provider';

  /// Re-fetches the provider's activation/wallet state. Called on load and
  /// again after returning from the waiting screen, so a provider who has just
  /// recharged does not bounce the buyer straight back to waiting.
  Future<void> _refreshProviderReadiness() async {
    try {
      final prov = await Supabase.instance.client
          .from('provider_profiles')
          .select('business_name, registration_fee_paid, status')
          .eq('id', widget.providerId)
          .maybeSingle();
      if (prov != null) {
        _providerName = (prov['business_name'] as String?)?.isNotEmpty == true
            ? prov['business_name'] as String
            : _providerName;
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

  /// Transaction fee percentage, read live from system_settings so the
  /// summary always reflects the current configuration. The fee itself is
  /// still charged server-side by deduct_transaction_fee() — this display
  /// never alters how it's calculated.
  double? _feePercent;

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
      // Fee % is informational; hide the row entirely if it can't load.
      double? feePercent;
      try {
        final setting = await Supabase.instance.client
            .from('system_settings')
            .select('value')
            .eq('key', 'transaction_fee')
            .maybeSingle();
        final v = (setting?['value'] as num?)?.toDouble();
        if (v != null && v > 0) feePercent = v;
      } catch (_) {}
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
      // Provider readiness check.
      await _refreshProviderReadiness();

      if (mounted) {
        setState(() {
          _items = items;
          _feePercent = feePercent;
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
    final picked =
        await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) {
      setState(() => _screenshot = File(picked.path));
    }
  }

  Future<void> _pickNationalId() async {
    final picked =
        await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
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
    try {
      final client = Supabase.instance.client;

      // Send ONLY product_id + quantity — the server computes prices/total.
      // Quantity stays a double: unit-priced lines (kg/liter) are fractional
      // (order_items.quantity is numeric(10,3)); fixed-price lines are whole.
      final noteParts = <String>[
        if (_addressCtrl.text.trim().isNotEmpty)
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
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final order = data['order'] as Map<String, dynamic>?;
      final orderId = order?['id'] as String?;
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
              'uploaded. Please contact support so your identity can be '
              'verified (WhatsApp 0917686990).';
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

      await CartService.instance.clearCart();
      ref.invalidate(cartCountProvider);

      if (!mounted) return;
      setState(() => _submitting = false);
      final dialogMessage = idIssue ??
          screenshotIssue ??
          (orderNumber != null
              ? 'Order $orderNumber has been placed successfully. '
                  'You can track it in My Orders.'
              : 'Your order has been placed successfully. You can track it in My Orders.');
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
                  context.go('/user?tab=2');
                }
              },
              child: const Text('VIEW ORDER'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Order failed: ${_errorMessage(e)}';
      });
    }
  }

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  String _errorMessage(Object e) {
    // Strip any exception-type prefix so the server's message shows cleanly.
    final s = e.toString();
    return s.replaceFirst(RegExp(r'^FunctionException:\s*'), '');
  }

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
                            if (_feePercent != null) ...[
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                      'Transaction fee '
                                      '(${_feePercent!.toStringAsFixed(0)}% '
                                      'charged to provider)',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textMuted)),
                                  Text(
                                    '-${(_total * _feePercent! / 100).toStringAsFixed(2)}',
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
                        child: PrimaryButton(
                          label: 'PLACE ORDER',
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
