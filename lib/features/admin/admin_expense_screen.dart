import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';

class AdminExpenseScreen extends StatefulWidget {
  const AdminExpenseScreen({super.key});
  @override
  State<AdminExpenseScreen> createState() => _AdminExpenseScreenState();
}

class _AdminExpenseScreenState extends State<AdminExpenseScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _expenses = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client
          .from('admin_expenses')
          .select()
          .order('created_at', ascending: false)
          .limit(500);
      _expenses = List<Map<String, dynamic>>.from(data as List);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _showAddDialog() async {
    final descCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    String category = 'MARKETING';

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Log Expense'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(labelText: 'Description', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountCtrl,
                decoration: const InputDecoration(
                  labelText: 'Amount (ETB)',
                  border: OutlineInputBorder(),
                  prefixText: 'ETB ',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: category,
                decoration: const InputDecoration(labelText: 'Category', border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: 'MARKETING', child: Text('Marketing')),
                  DropdownMenuItem(value: 'OPERATIONS', child: Text('Operations')),
                  DropdownMenuItem(value: 'SALARIES', child: Text('Salaries')),
                  DropdownMenuItem(value: 'INFRASTRUCTURE', child: Text('Infrastructure')),
                  DropdownMenuItem(value: 'OTHER', child: Text('Other')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => category = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final amount = double.tryParse(amountCtrl.text);
                if (descCtrl.text.isEmpty || amount == null || amount <= 0) return;
                Navigator.pop(ctx, {
                  'description': descCtrl.text,
                  'amount': amount,
                  'category': category,
                });
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryGreen, foregroundColor: Colors.white),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result != null) {
      try {
        await Supabase.instance.client.from('admin_expenses').insert({
          'description': result['description'],
          'amount': result['amount'],
          'category': result['category'],
          'admin_id': Supabase.instance.client.auth.currentUser?.id,
        });
        _load();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
          );
        }
      }
    }
  }

  double get _totalExpenses =>
      _expenses.fold(0.0, (s, e) => s + ((e['amount'] as num?)?.toDouble() ?? 0));

  Future<void> _exportCsv() async {
    final rows = <Map<String, String>>[];
    for (final e in _expenses) {
      rows.add({
        'Description': e['description'] ?? '',
        'Amount (ETB)': (e['amount'] ?? 0).toString(),
        'Category': e['category'] ?? '',
        'Date': DateFormat('dd/MM/yyyy HH:mm').format(DateTime.parse(e['created_at'])),
      });
    }

    await CsvExport.exportAndShare(
      columns: ['Description', 'Amount (ETB)', 'Category', 'Date'],
      rows: rows,
      fileName: 'expenses_${DateFormat('yyyyMMdd').format(DateTime.now())}',
      title: 'Admin Expenses',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expense Registration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download, color: Colors.white),
            onPressed: _exportCsv,
            tooltip: 'Export CSV',
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        backgroundColor: AppTheme.primaryGreen,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Log Expense', style: TextStyle(color: Colors.white)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              child: Column(
                children: [
                  // Total card
                  Card(
                    margin: const EdgeInsets.all(16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.receipt_long, size: 24, color: AppTheme.error),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Total Expenses', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                              Text('ETB ${_totalExpenses.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: AppTheme.error)),
                            ],
                          ),
                          const Spacer(),
                          Text('${_expenses.length} entries',
                              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                        ],
                      ),
                    ),
                  ),
                  // List
                  Expanded(
                    child: _expenses.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.receipt_long, size: 48, color: AppTheme.textMuted.withOpacity(0.3)),
                                const SizedBox(height: 12),
                                const Text('No expenses logged yet', style: TextStyle(color: AppTheme.textMuted)),
                                const SizedBox(height: 8),
                                const Text('Tap "Log Expense" to add your first entry',
                                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _expenses.length,
                            itemBuilder: (_, i) {
                              final exp = _expenses[i];
                              return Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: AppTheme.error.withOpacity(0.1),
                                    child: const Icon(Icons.remove_circle_outline, size: 18, color: AppTheme.error),
                                  ),
                                  title: Text(exp['description'] ?? '',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  subtitle: Text(
                                    '${exp['category'] ?? ''} · ${DateFormat('dd/MM/yyyy').format(DateTime.parse(exp['created_at']))}',
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                  ),
                                  trailing: Text('ETB ${(exp['amount'] ?? 0).toStringAsFixed(2)}',
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.error)),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }
}
