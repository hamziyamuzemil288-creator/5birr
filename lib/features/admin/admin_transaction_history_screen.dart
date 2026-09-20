import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';
import '../../core/utils/order_number_format.dart';

class AdminTransactionHistoryScreen extends StatefulWidget {
  const AdminTransactionHistoryScreen({super.key});
  @override
  State<AdminTransactionHistoryScreen> createState() => _State();
}

class _State extends State<AdminTransactionHistoryScreen> {
  List<Map<String, dynamic>> _transactions = [];
  bool _loading = true;
  DateTime? _startDate;
  DateTime? _endDate;
  String? _typeFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      var query = Supabase.instance.client
          .from('wallet_transactions')
          .select(
              '*, provider_profiles(business_name, user_id, profiles(full_name, phone)), orders(order_number)');
      
      if (_startDate != null) {
        query = query.gte('created_at', _startDate!.toIso8601String());
      }
      if (_endDate != null) {
        // Add one day to include the end date fully
        final endExclusive = _endDate!.add(const Duration(days: 1));
        query = query.lt('created_at', endExclusive.toIso8601String());
      }
      if (_typeFilter != null && _typeFilter!.isNotEmpty) {
        query = query.eq('transaction_type', _typeFilter!);
      }

      final data = await query.order('created_at', ascending: false).limit(500);
      if (mounted) {
        setState(() {
          _transactions = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? (_startDate ?? DateTime.now()) : (_endDate ?? DateTime.now()),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
      _load();
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _typeFilter = null;
    });
    _load();
  }

  Future<void> _exportCsv() async {
    final columns = [
      'Date', 'Provider', 'Type', 'Gross Amount', 'Fee', 'Net Amount', 'Status', 'Reference'
    ];
    final rows = _transactions.map((t) {
      final provider = t['provider_profiles'] as Map<String, dynamic>?;
      final profile = provider?['profiles'] as Map<String, dynamic>?;
      final order = t['orders'] as Map<String, dynamic>?;
      final dt = DateTime.parse(t['created_at']);
      return {
        'Date': CsvExport.formatDate(dt),
        'Provider': provider?['business_name'] ?? profile?['full_name'] ?? '',
        'Type': t['transaction_type'] ?? '',
        'Order Number': order?['order_number'] ?? '',
        'Gross Amount': t['gross_amount'] ?? 0,
        'Fee': t['platform_fee'] ?? 0,
        'Net Amount': t['net_amount'] ?? 0,
        'Status': t['status'] ?? '',
        'Reference': t['idempotency_key'] ?? '',
      };
    }).toList();

    await CsvExport.exportAndShare(
      columns: columns,
      rows: rows,
      fileName: 'transactions_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Transaction History',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transaction History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _exportCsv,
            tooltip: 'Export CSV',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filters
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _dateButton(
                        label: _startDate != null
                            ? DateFormat('dd/MM/yyyy').format(_startDate!)
                            : 'Start Date',
                        onTap: () => _pickDate(isStart: true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _dateButton(
                        label: _endDate != null
                            ? DateFormat('dd/MM/yyyy').format(_endDate!)
                            : 'End Date',
                        onTap: () => _pickDate(isStart: false),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: _clearFilters,
                      tooltip: 'Clear filters',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _typeChip(''),
                    _typeChip('TRANSACTION_FEE'),
                    _typeChip('SUBSCRIPTION_FEE'),
                    _typeChip('RECHARGE'),
                    _typeChip('ADMIN_CASH'),
                  ],
                ),
              ],
            ),
          ),
          // Results count
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text(
                  '${_transactions.length} transactions',
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
                const Spacer(),
                Text(
                  'Total: ${_transactions.fold<double>(0, (sum, t) => sum + ((t['gross_amount'] as num?)?.toDouble() ?? 0)).toStringAsFixed(2)} ETB',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryGreen),
                ),
              ],
            ),
          ),
          // List
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primaryGreen))
                : _transactions.isEmpty
                    ? const Center(
                        child: Text('No transactions found',
                            style: TextStyle(color: AppTheme.textMuted)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _transactions.length,
                        itemBuilder: (_, i) => _transactionCard(_transactions[i]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _dateButton({required String label, required VoidCallback onTap}) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _typeChip(String type) {
    final selected = _typeFilter == type || (_typeFilter == null && type.isEmpty);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(
          type.isEmpty ? 'All' : type.replaceAll('_', ' '),
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
        selected: selected,
        onSelected: (_) {
          setState(() => _typeFilter = type.isEmpty ? null : type);
          _load();
        },
        selectedColor: AppTheme.primaryGreen,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _transactionCard(Map<String, dynamic> t) {
    final provider = t['provider_profiles'] as Map<String, dynamic>?;
    final profile = provider?['profiles'] as Map<String, dynamic>?;
    final order = t['orders'] as Map<String, dynamic>?;
    final gross = (t['gross_amount'] as num?)?.toDouble() ?? 0;
    final fee = (t['platform_fee'] as num?)?.toDouble() ?? 0;
    final type = t['transaction_type'] ?? '';
    final dt = DateTime.parse(t['created_at']);
    final isCredit = type == 'RECHARGE' || type == 'ADMIN_CASH';
    final orderNumber = formatOrderNumber(order?['order_number']);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isCredit
                    ? AppTheme.success.withOpacity(0.1)
                    : AppTheme.primaryGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isCredit ? Icons.add : Icons.remove,
                color: isCredit ? AppTheme.success : AppTheme.primaryGreen,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    provider?['business_name'] ?? profile?['full_name'] ?? 'Unknown',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${type.replaceAll('_', ' ')} · ${DateFormat('dd/MM/yyyy').format(dt)}'
                    '${orderNumber != null ? ' · $orderNumber' : ''}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isCredit ? '+' : '-'}${gross.toStringAsFixed(2)} ETB',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: isCredit ? AppTheme.success : AppTheme.textPrimary,
                  ),
                ),
                if (fee > 0)
                  Text(
                    'Fee: ${fee.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 10, color: AppTheme.textMuted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
