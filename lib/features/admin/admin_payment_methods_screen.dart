import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/payment_methods_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class AdminPaymentMethodsScreen extends StatefulWidget {
  const AdminPaymentMethodsScreen({super.key});
  @override
  State<AdminPaymentMethodsScreen> createState() => _State();
}

class _State extends State<AdminPaymentMethodsScreen> {
  List<Map<String, dynamic>> _methods = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await PaymentMethodsService.instance.getAllMethods();
      if (mounted) {
        setState(() {
          _methods = data;
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

  Future<void> _addOrEdit({Map<String, dynamic>? existing}) async {
    final nameCtrl = TextEditingController(text: existing?['name'] ?? '');
    final acctNameCtrl =
        TextEditingController(text: existing?['account_name'] ?? '');
    final acctNumCtrl =
        TextEditingController(text: existing?['account_number'] ?? '');
    final instrCtrl =
        TextEditingController(text: existing?['instructions'] ?? '');
    final isEdit = existing != null;

    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(isEdit ? 'Edit Payment Method' : 'Add Payment Method'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name *')),
              const SizedBox(height: 12),
              TextField(
                  controller: acctNameCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Account Name')),
              const SizedBox(height: 12),
              TextField(
                  controller: acctNumCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Account Number / Phone')),
              const SizedBox(height: 12),
              TextField(
                  controller: instrCtrl,
                  maxLines: 3,
                  decoration:
                      const InputDecoration(labelText: 'Instructions')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save')),
        ],
      ),
    );

    if (result == true && nameCtrl.text.isNotEmpty) {
      try {
        if (isEdit) {
          await PaymentMethodsService.instance.updateMethod(
            id: existing!['id'],
            name: nameCtrl.text.trim(),
            accountName: acctNameCtrl.text.trim(),
            accountNumber: acctNumCtrl.text.trim(),
            instructions: instrCtrl.text.trim(),
          );
        } else {
          await PaymentMethodsService.instance.createMethod(
            name: nameCtrl.text.trim(),
            accountName: acctNameCtrl.text.trim(),
            accountNumber: acctNumCtrl.text.trim(),
            instructions: instrCtrl.text.trim(),
          );
        }
        _load();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update payment methods'))));
        }
      }
    }
  }

  Future<void> _toggleActive(String id, bool current) async {
    try {
      await PaymentMethodsService.instance
          .updateMethod(id: id, isActive: !current);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update payment methods'))));
      }
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Payment Method'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await PaymentMethodsService.instance.deleteMethod(id);
        _load();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update payment methods'))));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Methods')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primaryGreen,
        onPressed: () => _addOrEdit(),
        child: const Icon(Icons.add, color: Colors.white),
      ),      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _methods.isEmpty
              ? const Center(
                  child: Text('No payment methods configured',
                      style: TextStyle(color: AppTheme.textMuted)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _methods.length,
                  itemBuilder: (_, i) {
                    final m = _methods[i];
                    return Card(
                      child: ListTile(
                        title: Text(m['name'] ?? '',
                            style: const TextStyle(
                                fontWeight: FontWeight.w600)),
                        subtitle: Text(m['account_number'] ?? ''),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Switch(
                              value: m['is_active'] ?? true,
                              onChanged: (_) =>
                                  _toggleActive(m['id'], m['is_active']),
                              activeColor: AppTheme.primaryGreen,
                            ),
                            PopupMenuButton(
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                    value: 'edit', child: Text('Edit')),
                                const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Delete',
                                        style: TextStyle(
                                            color: AppTheme.error))),
                              ],
                              onSelected: (v) {
                                if (v == 'edit') _addOrEdit(existing: m);
                                if (v == 'delete') _delete(m['id']);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
