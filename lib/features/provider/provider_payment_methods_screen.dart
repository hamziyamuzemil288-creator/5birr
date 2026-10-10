import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/payment_methods_service.dart';
import '../../core/services/wallet_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/bank_account_rules.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

class ProviderPaymentMethodsScreen extends ConsumerStatefulWidget {
  const ProviderPaymentMethodsScreen({super.key});

  @override
  ConsumerState<ProviderPaymentMethodsScreen> createState() =>
      _ProviderPaymentMethodsScreenState();
}

class _ProviderPaymentMethodsScreenState
    extends ConsumerState<ProviderPaymentMethodsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _accountNameController = TextEditingController();
  final _accountNumberController = TextEditingController();
  final _instructionsController = TextEditingController();

  List<Map<String, dynamic>> _methods = [];
  List<Map<String, dynamic>> _walletFundingRequests = [];
  /// The admin-editable banks — the only source of the length/prefix rules
  /// this form validates against, so the client and the trigger can never
  /// disagree about what a valid account is.
  List<Map<String, dynamic>> _banks = [];
  String? _selectedBankId;
  Map<String, dynamic>? _wallet;
  String? _businessName;
  bool _loading = true;
  String? _error;
  String? _loadError;
  bool _refreshing = false;

  /// `provider_profiles.id` — NOT the auth user id. Resolved by [_load].
  String? _providerId;

  @override
  void initState() {
    super.initState();
    // Nothing used to start this screen. `_loading` begins true, only
    // `_load()` ever clears it, and no path called `_load()` until a save had
    // already happened — so the screen sat on its spinner forever. A provider
    // could reach "Payment account number" from the dashboard, from the
    // posting checklist and from the readiness banner, and never once see the
    // form or the Add button behind it.
    _load();
  }

  @override
  void dispose() {
    _accountNameController.dispose();
    _accountNumberController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadError = null;
    });
    try {
      // WHICH provider this screen belongs to, resolved before anything is
      // read or written. `provider_payment_methods.provider_id` is a foreign
      // key onto `provider_profiles(id)` (20260927000142) and every policy on
      // the table is `owns_provider_profile(provider_id)`, which matches on
      // `user_id = auth.uid()` — so the auth uid is not a provider id. Sending
      // it selected no rows (the screen read as empty however many accounts the
      // business had) and inserted a `provider_id` naming no profile at all, so
      // Add failed on the foreign key.
      final providerId = await _resolveProviderId();
      if (!mounted) return;
      if (providerId == null) {
        setState(() {
          _loading = false;
          _loadError = 'No business profile is linked to this account yet. '
              'Finish your provider registration, then come back to add your '
              'account number.';
        });
        return;
      }
      _providerId = providerId;

      // Every read is bounded (PaymentMethodsService.kTimeout, and the
      // .timeout below for the wallet reads): the endless spinner this
      // screen used to show was an un-awaited read that never returned —
      // no deadline meant no error state, no code and no retry.
      final methods =
          await PaymentMethodsService.instance.getProviderMethods(providerId);
      final banks = await PaymentMethodsService.instance.getBanks();
      final wallet = await WalletService.instance.getWallet(providerId)
          .timeout(PaymentMethodsService.kTimeout);
      final requests =
          await WalletService.instance.getMyWalletFundingSummary()
              .timeout(PaymentMethodsService.kTimeout);
      final requestsWithUrls = <Map<String, dynamic>>[];
      for (final r in requests) {
        final path = r['screenshot_storage_path'] as String?;
        if (path == null || path.isEmpty) {
          requestsWithUrls.add(r);
          continue;
        }
        try {
          final url = await WalletService.instance.getScreenshotUrl(path)
              .timeout(PaymentMethodsService.kTimeout);
          requestsWithUrls.add(Map<String, dynamic>.from(r)
            ..['_screenshotUrl'] = url);
        } catch (_) {
          requestsWithUrls.add(Map<String, dynamic>.from(r)
            ..['_screenshotUrl'] = null);
        }
      }
      String? name;
      if (wallet != null) {
        try {
          final client = Supabase.instance.client;
          final prov = await client
              .from('provider_profiles')
              .select('business_name')
              .eq('id', providerId)
              .maybeSingle()
              .timeout(PaymentMethodsService.kTimeout);
          name = prov?['business_name'] as String?;
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _methods = methods;
          _banks = banks;
          _wallet = wallet;
          _walletFundingRequests = requestsWithUrls;
          _businessName = name;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError =
              friendlyError(e, context: 'Could not load payment accounts');
        });
      }
    }
  }

  /// `provider_profiles.id` for the signed-in account, or null when the
  /// account has no business profile (a buyer, or a provider whose signup row
  /// has gone).
  ///
  /// Read as a list rather than `.maybeSingle()`: one person can hold more
  /// than one provider profile (a business and a driver), and `maybeSingle()`
  /// throws on two rows. A service business is preferred, because this screen
  /// is opened from the service-provider dashboard; failing that, whichever
  /// profile the account has.
  Future<String?> _resolveProviderId() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return null;
    final rows = await Supabase.instance.client
        .from('provider_profiles')
        .select('id, provider_type')
        .eq('user_id', userId)
        .timeout(PaymentMethodsService.kTimeout);
    final mine = List<Map<String, dynamic>>.from(rows as List);
    if (mine.isEmpty) return null;
    for (final r in mine) {
      if (r['provider_type'] == 'SERVICE_PROVIDER') return r['id'] as String;
    }
    return mine.first['id'] as String;
  }

  Future<void> _save() async {
    if (!context.mounted) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _error = null;
    });

    try {
      await _createMethod();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not save account')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (context.mounted) {
        _load();
      }
    }
  }

  Map<String, dynamic>? _selectedBank() {
    final id = _selectedBankId;
    if (id == null) return null;
    for (final b in _banks) {
      if (b['id'] == id) return b;
    }
    return null;
  }

  int get _activeCount =>
      _methods.where((m) => (m['is_active'] as bool?) == true).length;

  /// The bank picker: the ONLY source of a name now — a free-text name is
  /// how Telebirr / CBE Birr rows used to get in.
  Widget _bankField() => DropdownButtonFormField<String>(
        initialValue: _selectedBankId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Bank'),
        items: [
          for (final b in _banks)
            if ((b['is_active'] as bool?) != false)
              DropdownMenuItem<String>(
                value: b['id'] as String,
                child: Text(b['name'] as String? ?? ''),
              ),
        ],
        onChanged: (v) => setState(() => _selectedBankId = v),
        validator: (v) => v == null ? 'Choose your bank' : null,
      );

  /// Mirrors text_looks_like_phone for the fields buyers can read.
  String? _phoneTextValidator(String? v) =>
      looksLikePhone(v) ? 'Phone numbers are not allowed here' : null;

  /// Mirrors the trigger's bank length/prefix check against the very rows
  /// the trigger will check it against (the banks table).
  String? _numberValidator(String? v) {
    final bank = _selectedBank();
    if (bank == null) return 'Choose your bank first';
    return bankAccountError(
      v ?? '',
      digitMin: (bank['digit_min'] as num?)?.toInt() ?? 8,
      digitMax: (bank['digit_max'] as num?)?.toInt() ?? 16,
      prefix: bank['prefix'] as String?,
    );
  }

  Future<void> _createMethod() async {
    final providerId = _providerId;
    if (providerId == null) {
      // No resolved business profile: refusing with a sentence beats inserting
      // a row whose provider_id names nobody.
      throw Exception('NO_PROVIDER_PROFILE');
    }
    final bank = _selectedBank();
    final data = await PaymentMethodsService.instance.createProviderMethod(
      name: bank?['name'] as String? ?? 'Bank account',
      bankId: _selectedBankId,
      accountName: _accountNameController.text.trim().isEmpty
          ? null
          : _accountNameController.text.trim(),
      accountNumber: _accountNumberController.text.trim().isEmpty
          ? null
          : _accountNumberController.text.trim(),
      instructions: _instructionsController.text.trim().isEmpty
          ? null
          : _instructionsController.text.trim(),
      providerId: providerId,
    );

    if (context.mounted) {
      setState(() {
        _methods = [..._methods, data];
        _selectedBankId = null;
        _accountNameController.clear();
        _accountNumberController.clear();
        _instructionsController.clear();
      });
    }
  }

  Future<void> _updateMethod(String id) async {
    final index = _methods.indexWhere((m) => m['id'] == id);
    if (index < 0) return;

    final method = _methods[index];

    try {
      final bank = _selectedBank();
      final updated = await PaymentMethodsService.instance.updateProviderMethod(
        id: id,
        name: bank?['name'] as String?,
        bankId: _selectedBankId,
        accountName:
            _accountNameController.text.trim().isEmpty
                ? null
                : _accountNameController.text.trim(),
        accountNumber: _accountNumberController.text.trim().isEmpty
            ? null
            : _accountNumberController.text.trim(),
        instructions: _instructionsController.text.trim().isEmpty
            ? null
            : _instructionsController.text.trim(),
        isActive: method['is_active'] as bool?,
      );

      if (context.mounted) {
        _methods[index] = updated;
        _selectedBankId = null;
        _accountNameController.clear();
        _accountNumberController.clear();
        _instructionsController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment account updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not update account')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (context.mounted) {
        _load();
      }
    }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _load();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _deleteMethod(String id) async {
    setState(() {
      _error = null;
    });

    try {
      await PaymentMethodsService.instance.deleteProviderMethod(id);
      if (context.mounted) {
        _load();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment account removed')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        setState(() {
          _error =
              friendlyError(e, context: 'Could not remove account');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_error!),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (context.mounted) {
        _load();
      }
    }
  }

  Future<void> _showAddFundsSheet() async {
    final amountCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    File? screenshot;
    String? selectedMethodId;
    final picker = ImagePicker();

    void pickScreenshot() async {
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked != null) {
        setState(() => screenshot = File(picked.path));
      }
    }

    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add funds from a payment account',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'This request will be reviewed by an admin before it is '
                  'credited to your wallet. It cannot be approved by you.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedMethodId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'From (your payment account)',
                    isDense: true,
                  ),
                  items: _methods
                      .where((m) => (m['is_active'] as bool?) == true)
                      .map((m) => DropdownMenuItem<String>(
                            value: m['id'] as String,
                            child: Text(m['name'] ?? ''),
                          ))
                      .toList(),
                  onChanged: (v) => setSheet(() => selectedMethodId = v),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount (ETB)',
                    prefixText: 'ETB ',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: refCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Reference (optional)',
                    hintText: 'Transaction ID or note',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: pickScreenshot,
                  child: Container(
                    width: double.infinity,
                    height: screenshot != null ? 160 : 100,
                    decoration: BoxDecoration(
                      color: AppTheme.creamDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.cardBorder),
                    ),
                    child: screenshot != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              screenshot!,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 28,
                                  color: AppTheme.textMuted),
                              SizedBox(height: 8),
                              Text(
                                'Add a payment screenshot (optional)',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    label: 'Submit for review',
                    onPressed: () async {
                      Navigator.of(sheet).pop(true);
                      await _submitProviderWalletFunding(
                        selectedMethodId: selectedMethodId,
                        amountCtrl: amountCtrl,
                        refCtrl: refCtrl,
                        screenshot: screenshot,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(sheet).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitProviderWalletFunding({
    required String? selectedMethodId,
    required TextEditingController amountCtrl,
    required TextEditingController refCtrl,
    required File? screenshot,
  }) async {
    final providerId = _providerId;
    if (providerId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No business profile is linked to this account yet, '
                'so there is no wallet to fund.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final amount = double.tryParse(amountCtrl.text);
    if (selectedMethodId == null || selectedMethodId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a payment account'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    if (amount == null || amount <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a valid amount'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _error = null;
    });

    String? screenshotPath;
    if (screenshot != null) {
      try {
        screenshotPath = await WalletService.instance.uploadScreenshot(
          screenshot.path,
          providerId,
        );
      } on Exception catch (e) {
        if (mounted) {
          setState(() {
            _error = friendlyError(
                e, context: 'Could not upload your payment screenshot');
          });
        }
        return;
      }
    }

    try {
      await WalletService.instance.submitProviderWalletFundingRequest(
        providerId: providerId,
        walletId: (_wallet?['id'] as String?) ?? '',
        paymentMethodId: selectedMethodId,
        amount: amount,
        paymentReference: refCtrl.text.trim().isEmpty
            ? null
            : refCtrl.text.trim(),
        screenshotStoragePath: screenshotPath,
      );
      if (mounted) {
        _load();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Funding request submitted. An admin will credit it when approved.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error =
              friendlyError(e, context: 'Could not submit your funding request');
        });
      }
    }
  }

  Widget _walletBalanceCard() {
    final wallet = _wallet;
    final hasWallet = wallet != null && (wallet['id'] as String?)?.isNotEmpty == true;
    final balance = hasWallet ? (wallet['balance'] as num?)?.toDouble() ?? 0 : 0.0;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primaryGreen, AppTheme.primaryGreenDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _businessName ?? '',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      balance.toStringAsFixed(2),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Text(
                      'ETB available in your wallet',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.account_balance_wallet,
                color: Colors.white,
                size: 36,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (hasWallet)
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'Add funds from a payment account',
                icon: Icons.add,
                onPressed: _showAddFundsSheet,
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'No wallet yet. Contact support to set one up so you can fund it from your payment accounts.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white,
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Your wallet is funded by you through this screen. The amount you '
            'enter is reviewed by an admin before it is credited.',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingRequestsCard() {
    if (_walletFundingRequests.isEmpty && !_refreshing) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hourglass_empty,
                    size: 18, color: AppTheme.warning),
                const SizedBox(width: 8),
                const Text(
                  'Awaiting admin review',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_walletFundingRequests.length} request'
                  '${_walletFundingRequests.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'These funding requests are reviewed by an admin. You will be '
              'notified when one is approved or rejected.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            if (_refreshing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                      color: AppTheme.primaryGreen),
                ),
              )
            else
              ...(_walletFundingRequests.map((r) {
                final amount =
                    (r['amount'] as num?)?.toStringAsFixed(2) ?? '0.00';
                final status = (r['status'] as String?) ?? 'PENDING';
                final when = r['created_at'] != null
                    ? DateTime.tryParse(r['created_at'] as String)
                    : null;
                final screenshotUrl =
                    r['_screenshotUrl'] as String?;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppTheme.cardBorder,
                      width: 0.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$amount ETB',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              status,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.warning,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (r['payment_methods'] as Map<String, dynamic>?)
                                      ?['name'] as String?
                                  ?? 'Payment account',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                          if (when != null)
                            Text(
                              '${when.day}/${when.month}/${when.year}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            ),
                        ],
                      ),
                      if (screenshotUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              screenshotUrl,
                              height: 90,
                              width: 120,
                              fit: BoxFit.cover,
                              loadingBuilder: (
                                BuildContext context,
                                Widget? child,
                                ImageChunkEvent? progress,
                              ) {
                                return child ?? const SizedBox.shrink();
                              },
                              errorBuilder: (
                                BuildContext context,
                                Object exception,
                                StackTrace? stackTrace,
                              ) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              })),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment account number'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: AppTheme.primaryGreen))
          : _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: AppTheme.textMuted),
                      const SizedBox(height: 16),
                      Text(
                        _loadError!,
                        style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _methods.isEmpty
                  ? _emptyState(context)
                  : _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _walletBalanceCard(),
          if (_walletFundingRequests.isNotEmpty) _pendingRequestsCard(),
          _listBody(context),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
              Icons.credit_card_outlined,
              size: 64,
              color: AppTheme.textMuted),
          const SizedBox(height: 16),
          Text(
            'No payment accounts yet',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add up to 3 bank accounts so buyers know where to send money '
            'and can upload proof on the order. Telebirr, CBE Birr and '
            'other mobile money are not accepted.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startAdding,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Add bank account'),
          ),
        ],
      ),
    );
  }

  Widget _listBody(BuildContext context) {
    return ListView.builder(
      // shrinkWrap + no inner scrolling: this list is rendered INSIDE the
      // screen's own ListView (the wallet card and the pending-requests card
      // sit above it). A plain nested ListView has no bounded height to lay
      // out against and threw "Vertical viewport was given unbounded height"
      // the moment a provider had one account — which is exactly when this
      // list first rendered, so the empty state looked fine and the first
      // saved account broke the screen.
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      // One extra row: the "add account" action, always reachable and
      // always honest about the 3-account cap.
      itemCount: _methods.length + 1,
      itemBuilder: (_, i) {
        if (i == _methods.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: _activeCount >= 3 ? null : _startAdding,
                  icon: const Icon(Icons.add_circle_outline),
                  label: Text(_activeCount >= 3
                      ? 'Maximum of 3 accounts reached'
                      : 'Add bank account'),
                ),
                const SizedBox(height: 4),
                Text(
                  '$_activeCount of 3 accounts in use',
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              ],
            ),
          );
        }
        final method = _methods[i];
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        method['name'] ?? 'Untitled account',
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if ((method['is_active'] as bool?) == false)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          'Inactive',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.orange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
                if ((method['is_active'] as bool?) == false)
                  const SizedBox(height: 4),
                if ((method['is_active'] as bool?) == false)
                  Text(
                    'This account will not be shown to buyers until it is turned on.',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMuted),
                  ),
                const SizedBox(height: 8),
                if (method['is_default'] == true)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Default',
                      style: TextStyle(
                          fontSize: 11,
                          color: AppTheme.primaryGreen,
                          fontWeight: FontWeight.w700),
                    ),
                  )
                else if ((method['is_active'] as bool?) == true)
                  TextButton(
                    onPressed: () => _makeDefault(method['id'] as String),
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32)),
                    child: const Text('Make default',
                        style: TextStyle(fontSize: 12)),
                  ),
                const SizedBox(height: 12),
                ListTile(
                  title: const Text('Payee name'),
                  subtitle: Text(
                    method['account_name'] as String? ?? '—',
                    style: TextStyle(
                        fontSize: 13,
                        color: (method['account_name'] as String?)
                                ?.isNotEmpty ==
                            true
                        ? null
                        : AppTheme.textMuted),
                  ),
                ),
                ListTile(
                  title: const Text('Account number'),
                  subtitle: Text(
                    method['account_number'] as String? ?? '—',
                    style: TextStyle(
                        fontSize: 13,
                        color: (method['account_number'] as String?)
                                ?.isNotEmpty ==
                            true
                        ? null
                        : AppTheme.textMuted),
                  ),
                ),
                if ((method['instructions'] as String?)?.isNotEmpty == true)
                  ListTile(
                    title: const Text('Buyer note'),
                    subtitle: Text(
                      method['instructions'] as String,
                      style: const TextStyle(
                          fontSize: 13,
                          color: AppTheme.textMuted,
                          fontStyle: FontStyle.italic),
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _startEditing(method['id']!),
                        icon: const Icon(Icons.edit),
                        label: const Text('Edit'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _startDeleting(method['id']!),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.red,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }  void _startAdding() {
    // Up to 3 ACTIVE accounts, enforced here for a fast "why" and by the
    // trigger for everyone else (ACCOUNT_LIMIT_REACHED).
    if (_activeCount >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You can have up to 3 payment accounts. Remove or '
              'deactivate one first.'),
        ),
      );
      return;
    }
    _selectedBankId = null;
    _accountNameController.clear();
    _accountNumberController.clear();
    _instructionsController.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add bank account'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _bankField(),
                TextFormField(
                  controller: _accountNameController,
                  decoration: const InputDecoration(labelText: 'Account / payee name'),
                  textCapitalization: TextCapitalization.words,
                  validator: _phoneTextValidator,
                ),
                TextFormField(
                  controller: _accountNumberController,
                  decoration: const InputDecoration(labelText: 'Account number'),
                  keyboardType: TextInputType.number,
                  validator: _numberValidator,
                ),
                TextFormField(
                  controller: _instructionsController,
                  decoration: const InputDecoration(
                      labelText: 'Buyer note (optional)'),
                  maxLines: 3,
                  keyboardType: TextInputType.multiline,
                  validator: _phoneTextValidator,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _save,
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }  VoidCallback _startEditing(String id) => () {
        final method = _methods.firstWhere((m) => m['id'] == id);
        _selectedBankId = method['bank_id'] as String?;
        _accountNameController.text =
            method['account_name'] as String? ?? '';
        _accountNumberController.text =
            method['account_number'] as String? ?? '';
        _instructionsController.text =
            method['instructions'] as String? ?? '';
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Edit bank account'),
            content: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _bankField(),
                    TextFormField(
                      controller: _accountNameController,
                      decoration: const InputDecoration(labelText: 'Account / payee name'),
                      textCapitalization: TextCapitalization.words,
                      validator: _phoneTextValidator,
                    ),
                    TextFormField(
                      controller: _accountNumberController,
                      decoration: const InputDecoration(labelText: 'Account number'),
                      keyboardType: TextInputType.number,
                      validator: _numberValidator,
                    ),
                    TextFormField(
                      controller: _instructionsController,
                      decoration: const InputDecoration(
                          labelText: 'Buyer note (optional)'),
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
                      validator: _phoneTextValidator,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  _updateMethod(id);
                  Navigator.of(context).pop();
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      };

  Future<void> _makeDefault(String id) async {
    try {
      await PaymentMethodsService.instance
          .updateProviderMethod(id: id, isDefault: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Default account updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(friendlyError(e, context: 'Could not set default')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (context.mounted) _load();
    }
  }

  VoidCallback _startDeleting(String id) => () {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('Remove payment account'),
            content: const Text(
                'This will remove this account. Buyers will no longer see '
                'it.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  Navigator.of(dialogCtx).pop();
                  _deleteMethod(id);
                },
                child: const Text('Remove'),
              ),
            ],
          ),
        );
      };
}
