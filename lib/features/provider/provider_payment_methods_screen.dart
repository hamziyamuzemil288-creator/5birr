import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/payment_methods_service.dart';
import '../../core/services/wallet_service.dart';
import '../../core/theme/app_theme.dart';
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
  final _nameController = TextEditingController();
  final _accountNameController = TextEditingController();
  final _accountNumberController = TextEditingController();
  final _instructionsController = TextEditingController();

  List<Map<String, dynamic>> _methods = [];
  List<Map<String, dynamic>> _walletFundingRequests = [];
  Map<String, dynamic>? _wallet;
  String? _businessName;
  bool _loading = true;
  String? _error;
  String? _loadError;
  bool _refreshing = false;

  @override
  void dispose() {
    _nameController.dispose();
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
      final methods =
          await PaymentMethodsService.instance.getProviderMethods(_providerId);
      final wallet = await WalletService.instance.getWallet(_providerId);
      final requests =
          await WalletService.instance.getMyWalletFundingSummary();
      final requestsWithUrls = <Map<String, dynamic>>[];
      for (final r in requests) {
        final path = r['screenshot_storage_path'] as String?;
        if (path == null || path.isEmpty) {
          requestsWithUrls.add(r);
          continue;
        }
        try {
          final url = await WalletService.instance.getScreenshotUrl(path);
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
              .eq('id', _providerId)
              .maybeSingle();
          name = prov?['business_name'] as String?;
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _methods = methods;
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
              friendlyError(e, context: 'Could not load payment methods');
        });
      }
    }
  }

  String get _providerId =>
      Supabase.instance.client.auth.currentUser?.id ?? '';

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
                friendlyError(e, context: 'Could not save method')),
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

  Future<void> _createMethod() async {
    final data = await PaymentMethodsService.instance.createProviderMethod(
      name: _nameController.text.trim(),
      accountName: _accountNameController.text.trim().isEmpty
          ? null
          : _accountNameController.text.trim(),
      accountNumber: _accountNumberController.text.trim().isEmpty
          ? null
          : _accountNumberController.text.trim(),
      instructions: _instructionsController.text.trim().isEmpty
          ? null
          : _instructionsController.text.trim(),
      providerId: _providerId,
    );

    if (context.mounted) {
      setState(() {
        _methods = [..._methods, data];
        _nameController.clear();
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
      final updated = await PaymentMethodsService.instance.updateProviderMethod(
        id: id,
        name: _nameController.text.trim(),
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
        _nameController.clear();
        _accountNameController.clear();
        _accountNumberController.clear();
        _instructionsController.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Payment method updated')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not update method')),
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
          const SnackBar(content: Text('Payment method removed')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        setState(() {
          _error =
              friendlyError(e, context: 'Could not remove method');
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
                  'Add funds from a payment method',
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
                    labelText: 'From (your payment method)',
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
    final amount = double.tryParse(amountCtrl.text);
    if (selectedMethodId == null || selectedMethodId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a payment method'),
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
          _providerId,
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
        providerId: _providerId,
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
                label: 'Add funds from a payment method',
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
                'No wallet yet. Contact support to set one up so you can fund it from your payment methods.',
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
                                  ?? 'Payment method',
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
        title: const Text('Payment Methods'),
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
            'No payment methods yet',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Add the methods your buyers can pay with so they can confirm '
            'payment and send proof on the order.',
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: AppTheme.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _startAdding,
            icon: const Icon(Icons.add_circle_outline),
            label: const Text('Add payment method'),
          ),
        ],
      ),
    );
  }

  Widget _listBody(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _methods.length,
      itemBuilder: (_, i) {
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
                        method['name'] ?? 'Untitled method',
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
                    'This method will not be shown to buyers until it is turned on.',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMuted),
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
                  title: const Text('Account / card number'),
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
  }

  void _startAdding() {
    _nameController.clear();
    _accountNameController.clear();
    _accountNumberController.clear();
    _instructionsController.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Add payment method'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration:
                      const InputDecoration(labelText: 'Name (shown to buyers)'),
                  textCapitalization: TextCapitalization.words,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Required' : null,
                ),
                TextFormField(
                  controller: _accountNameController,
                  decoration:
                      const InputDecoration(labelText: 'Account / payee name'),
                  textCapitalization: TextCapitalization.words,
                ),
                TextFormField(
                  controller: _accountNumberController,
                  decoration:
                      const InputDecoration(labelText: 'Account / card number'),
                  keyboardType: TextInputType.number,
                ),
                TextFormField(
                  controller: _instructionsController,
                  decoration: const InputDecoration(
                      labelText: 'Buyer note (optional)'),
                  maxLines: 3,
                  keyboardType: TextInputType.multiline,
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
  }

  VoidCallback _startEditing(String id) => () {
        final method = _methods.firstWhere((m) => m['id'] == id);
        _nameController.text = method['name'] ?? '';
        _accountNameController.text =
            method['account_name'] as String? ?? '';
        _accountNumberController.text =
            method['account_number'] as String? ?? '';
        _instructionsController.text =
            method['instructions'] as String? ?? '';
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Edit payment method'),
            content: SingleChildScrollView(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                          labelText: 'Name (shown to buyers)'),
                      textCapitalization: TextCapitalization.words,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    TextFormField(
                      controller: _accountNameController,
                      decoration: const InputDecoration(
                          labelText: 'Account / payee name'),
                      textCapitalization: TextCapitalization.words,
                    ),
                    TextFormField(
                      controller: _accountNumberController,
                      decoration: const InputDecoration(
                          labelText: 'Account / card number'),
                      keyboardType: TextInputType.number,
                    ),
                    TextFormField(
                      controller: _instructionsController,
                      decoration: const InputDecoration(
                          labelText: 'Buyer note (optional)'),
                      maxLines: 3,
                      keyboardType: TextInputType.multiline,
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

  VoidCallback _startDeleting(String id) => () {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (dialogCtx) => AlertDialog(
            title: const Text('Remove payment method'),
            content: const Text(
                'This will remove the method for this account. Buyers will '
                'no longer see it.'),
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
