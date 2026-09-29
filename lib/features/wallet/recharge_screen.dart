import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/resilience/safe_call.dart' show InFlightGuard;
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/wallet_service.dart';
import '../../core/services/payment_methods_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class RechargeScreen extends StatefulWidget {
  const RechargeScreen({super.key});
  @override
  State<RechargeScreen> createState() => _RechargeScreenState();
}

class _RechargeScreenState extends State<RechargeScreen> {
  List<Map<String, dynamic>> _methods = [];
  Map<String, dynamic>? _selectedMethod;
  final _amountCtrl = TextEditingController();
  final _refCtrl = TextEditingController();

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    super.dispose();
  }
  File? _screenshot;
  bool _loading = true;
  bool _submitting = false;
  /// Held for the whole submit, not just while the button shows a spinner.
  final InFlightGuard _guard = InFlightGuard();
  String? _error;
  // Distinct from _error, which is form-validation copy ("Enter a valid
  // amount"). This one is a failed fetch: the payment-method list could not
  // be loaded, and without it the user just sees an empty selector.
  String? _loadError;
  String? _success;
  final _picker = ImagePicker();
  // One-time activation: until the first recharge is approved (which withholds
  // the registration fee), providers see what the fee is before paying.
  bool _registrationFeePaid = true;
  double _registrationFee = 100;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final methods = await PaymentMethodsService.instance.getActiveMethods();
      // Load activation status + fee amount (non-fatal if unavailable).
      try {
        final client = Supabase.instance.client;
        final uid = client.auth.currentUser?.id;
        if (uid != null) {
          final prov = await client
              .from('provider_profiles')
              .select('registration_fee_paid')
              .eq('user_id', uid)
              .maybeSingle();
          if (prov != null) {
            _registrationFeePaid =
                (prov['registration_fee_paid'] as bool?) ?? false;
          }
        }
        final feeSetting = await client
            .from('system_settings')
            .select('value')
            .eq('key', 'provider_registration_fee')
            .maybeSingle();
        final v = (feeSetting?['value'] as num?)?.toDouble();
        if (v != null && v > 0) _registrationFee = v;
      } catch (_) {}
      if (mounted) {
        setState(() {
          _methods = methods;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = friendlyError(e, context: 'Could not load payment methods');
        });
      }
    }
  }

  Future<void> _pickScreenshot() async {
    final picked = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 85);
    if (picked != null) {
      setState(() => _screenshot = File(picked.path));
    }
  }

  Future<void> _submit() async {
    // In-flight guard, not just `_submitting`.
    //
    // `PrimaryButton` disables itself with `onPressed: isLoading ? null : ...`,
    // but that is evaluated at BUILD time. Two taps landing in the same frame
    // — which is exactly what a fast double-tap on a Recharge button does —
    // both call _submit before the rebuild, and both create a recharge
    // request. A guard taken at the top of the method closes that window; a
    // flag read from build state does not.
    if (_guard.isBusy) return;
    await _guard.run(_doSubmit);
  }

  Future<void> _doSubmit() async {
    if (_selectedMethod == null) {
      setState(() => _error = 'Select a payment method');
      return;
    }
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (!_registrationFeePaid && amount < _registrationFee) {
      setState(() => _error =
          'Your first recharge must be at least ${_registrationFee.toStringAsFixed(0)} birr: it includes the one-time $_registrationFee birr registration fee (the rest is credited to your wallet).');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) throw Exception('Not authenticated');
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      if (prov == null) throw Exception('Provider profile not found');
      final wallet = await client
          .from('wallets')
          .select('id')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      if (wallet == null) throw Exception('Wallet not found');

      String? screenshotPath;
      if (_screenshot != null) {
        screenshotPath = await WalletService.instance
            .uploadScreenshot(_screenshot!.path, prov['id']);
      }

      await WalletService.instance.submitRecharge(
        providerId: prov['id'],
        walletId: wallet['id'],
        paymentMethodId: _selectedMethod!['id'],
        amount: amount,
        paymentReference:
            _refCtrl.text.isNotEmpty ? _refCtrl.text.trim() : null,
        screenshotPath: screenshotPath,
      );

      if (mounted) {
        setState(() {
          _submitting = false;
          _success =
              'Payment submitted successfully. Your wallet will be credited after admin verification.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = friendlyError(e, context: 'Could not submit your recharge');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recharge Wallet')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _loadError != null
              ? LoadErrorView(message: _loadError!, onRetry: _load)
              : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_success != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.success.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.success.withOpacity(0.3)),
                      ),
                      child: Text(_success!,
                          style: const TextStyle(
                              fontSize: 13, color: AppTheme.success)),
                    ),
                    const SizedBox(height: 20),
                  ],
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(
                              fontSize: 13, color: AppTheme.error)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (!_registrationFeePaid) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.gold.withOpacity(0.10),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppTheme.gold.withOpacity(0.45)),
                      ),
                      child: Text(
                        'One-time registration fee: your first recharge '
                        'includes the $_registrationFee birr account '
                        'activation fee. Enter $_registrationFee or more — '
                        'the amount above the fee is credited to your '
                        'wallet. Later recharges are credited in full.',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('Select Payment Method',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  if (_methods.isEmpty)
                    const Text('No payment methods available',
                        style: TextStyle(color: AppTheme.textMuted))
                  else
                    ..._methods.map((m) => GestureDetector(
                          onTap: () =>
                              setState(() => _selectedMethod = m),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _selectedMethod?['id'] == m['id']
                                  ? AppTheme.primaryGreen.withOpacity(0.06)
                                  : AppTheme.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _selectedMethod?['id'] == m['id']
                                    ? AppTheme.primaryGreen
                                    : AppTheme.cardBorder,
                                width: _selectedMethod?['id'] == m['id']
                                    ? 1.5
                                    : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m['name'] ?? '',
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                                if (m['account_name'] != null)
                                  Text(m['account_name'],
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textSecondary)),
                                if (m['account_number'] != null)
                                  Text(m['account_number'],
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.teal,
                                          fontWeight: FontWeight.w500)),
                                if (m['instructions'] != null) ...[
                                  const SizedBox(height: 6),
                                  Text(m['instructions'],
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textMuted)),
                                ],
                              ],
                            ),
                          ),
                        )),
                  const SizedBox(height: 20),
                  BirrTextField(
                    label: 'Amount (ETB)',
                    controller: _amountCtrl,
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  BirrTextField(
                    label: 'Payment Reference (optional)',
                    controller: _refCtrl,
                    hint: 'Transaction ID or reference number',
                  ),
                  const SizedBox(height: 16),
                  // Screenshot
                  const Text('Payment Screenshot',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _pickScreenshot,
                    child: Container(
                      width: double.infinity,
                      height: _screenshot != null ? 200 : 120,
                      decoration: BoxDecoration(
                        color: AppTheme.creamDark,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: _screenshot != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child:
                                  Image.file(_screenshot!, fit: BoxFit.cover),
                            )
                          : const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_a_photo_outlined,
                                    size: 32, color: AppTheme.textMuted),
                                SizedBox(height: 8),
                                Text('Tap to upload screenshot',
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textMuted)),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'SUBMIT PAYMENT',
                      isLoading: _submitting,
                      onPressed: _submit,
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
