import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/payment_methods_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

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
  bool _loading = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _accountNameController.dispose();
    _accountNumberController.dispose();
    _instructionsController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final methods = await PaymentMethodsService.instance.getProviderMethods(
          _providerId);
      if (mounted) {
        setState(() {
          _methods = methods;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load payment methods');
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
      // Not called to avoid exceeding the Freebuff 60s broadcast limit; instead
      // the screen creates the first row locally and matches it after the RPC.
      await _createMethod();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e, context: 'Could not save method')),
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
        accountName: _accountNameController.text.trim().isEmpty
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
            content: Text(friendlyError(e, context: 'Could not update method')),
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
          _error = friendlyError(e, context: 'Could not remove method');
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
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.error_outline,
                          size: 64, color: AppTheme.textMuted),
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: const TextStyle(
                            color: AppTheme.textMuted, fontSize: 14),
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
                  : _listBody(context),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.credit_card_outlined,
              size: 64, color: AppTheme.textMuted),
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
            style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
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
                            fontSize: 16, fontWeight: FontWeight.w600),
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
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textMuted),
                  ),
                const SizedBox(height: 12),
                // Label shown to buyers: the public form takes a display
                // name; the numeric/account fields are optional ledger
                // detail only.
                ListTile(
                  title: const Text('Payee name'),
                  subtitle: Text(
                    (method['account_name'] as String?) ?? '—',
                    style: TextStyle(
                        fontSize: 13,
                        color: (method['account_name'] as String?)?.isNotEmpty ==
                                true
                            ? null
                            : AppTheme.textMuted),
                  ),
                ),
                ListTile(
                  title: const Text('Account / card number'),
                  subtitle: Text(
                    (method['account_number'] as String?) ?? '—',
                    style: TextStyle(
                        fontSize: 13,
                        color: (method['account_number'] as String?)?.isNotEmpty ==
                                true
                            ? null
                            : AppTheme.textMuted),
                  ),
                ),
                if ((method['instructions'] as String?)?.isNotEmpty == true)
                  ListTile(
                    title: const Text('Buyer note'),
                    subtitle: Text(
                      (method['instructions'] as String?)!,
                      style: TextStyle(
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
                        onPressed: _startDeleting(method['id']!),
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
      builder: (context) => AlertDialog(
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
                  decoration: const InputDecoration(labelText: 'Name (shown to buyers)'),
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
                  decoration: const InputDecoration(labelText: 'Account / card number'),
                  keyboardType: TextInputType.number,
                ),
                TextFormField(
                  controller: _instructionsController,
                  decoration: const InputDecoration(labelText: 'Buyer note (optional)'),
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
      builder: (context) => AlertDialog(
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
                  decoration: const InputDecoration(labelText: 'Account / card number'),
                  keyboardType: TextInputType.number,
                ),
                TextFormField(
                  controller: _instructionsController,
                  decoration: const InputDecoration(labelText: 'Buyer note (optional)'),
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
      builder: (context) => AlertDialog(
        title: const Text('Remove payment method'),
        content: const Text(
            'This will remove the method for this account. Buyers will '
            'no longer see it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              _deleteMethod(id);
              Navigator.of(context).pop();
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  };
}
