import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class AdminIncomeSummaryScreen extends StatefulWidget {
  const AdminIncomeSummaryScreen({super.key});
  @override
  State<AdminIncomeSummaryScreen> createState() => _IncomeSummaryScreenState();
}

class _IncomeSummaryScreenState extends State<AdminIncomeSummaryScreen> {
  bool _loading = true;
  DateTime? _startDate;
  DateTime? _endDate;
  String _typeFilter = 'ALL'; // ALL, TRANSACTION_FEE, SUBSCRIPTION_FEE

  // Both fee types come from wallet_transactions — the authoritative ledger
  // the fee functions write. (The previous sources were permanently empty:
  // orders.admin_fee is never written by any migration, and subscriptions
  // rows are schedules with status ACTIVE/DUE/GRACE/SUSPENDED — never PAID —
  // and have no amount column, so that query errored silently.)
  List<Map<String, dynamic>> _txFees = [];
  List<Map<String, dynamic>> _monthlyFees = [];
  // A snackbar was the only signal here, and it disappears after a few
  // seconds — leaving a Total Income of 0.00 on screen with no indication
  // that the ledger was never actually read. Money totals must not look
  // authoritative when the read failed.
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final String startIso =
          _startDate?.toIso8601String() ?? '2000-01-01T00:00:00.000Z';
      final String endIso = (_endDate ?? DateTime.now())
          .add(const Duration(days: 1))
          .toIso8601String();

      // 1% transaction fees — wallet_transactions rows written by
      // deduct_transaction_fee() (fee = max(1%, 5 birr), idempotent).
      if (_typeFilter == 'ALL' || _typeFilter == 'TRANSACTION_FEE') {
        final data = await client
            .from('wallet_transactions')
            .select(
                'id, provider_id, order_id, ride_request_id, gross_amount, platform_fee, created_at')
            .gte('created_at', startIso)
            .lt('created_at', endIso)
            .eq('transaction_type', 'TRANSACTION_FEE')
            .order('created_at', ascending: false)
            .limit(500);
        _txFees = List<Map<String, dynamic>>.from(data as List);
      } else {
        _txFees = [];
      }

      // 5birr monthly fees — same ledger, SUBSCRIPTION_FEE rows written by
      // deduct_subscription_fee() via the subscription scheduler.
      if (_typeFilter == 'ALL' || _typeFilter == 'SUBSCRIPTION_FEE') {
        final data = await client
            .from('wallet_transactions')
            .select(
                'id, provider_id, order_id, ride_request_id, gross_amount, platform_fee, created_at')
            .gte('created_at', startIso)
            .lt('created_at', endIso)
            .eq('transaction_type', 'SUBSCRIPTION_FEE')
            .order('created_at', ascending: false)
            .limit(500);
        _monthlyFees = List<Map<String, dynamic>>.from(data as List);
      } else {
        _monthlyFees = [];
      }
    } catch (e) {
      // Surface failures instead of silently rendering a fake zero summary.
      if (mounted) {
        setState(() {
          _error = friendlyError(e, context: 'Could not load income data');
        });
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _typeFilter = 'ALL';
    });
    _load();
  }

  double get _totalTxAmount => _txFees.fold(
      0.0, (s, e) => s + ((e['platform_fee'] as num?)?.toDouble() ?? 0));
  double get _totalMonthlyAmount => _monthlyFees.fold(
      0.0, (s, e) => s + ((e['platform_fee'] as num?)?.toDouble() ?? 0));
  double get _totalIncome => _totalTxAmount + _totalMonthlyAmount;

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart
          ? (_startDate ?? DateTime.now())
          : (_endDate ?? DateTime.now()),
      firstDate: DateTime(2023),
      lastDate: DateTime.now().add(const Duration(days: 1)),
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

  Future<void> _exportCsv() async {
    final rows = <Map<String, String>>[];

    for (final tx in _txFees) {
      rows.add({
        'Type': '1% Transaction Fee',
        'Ref': tx['order_id'] ?? tx['ride_request_id'] ?? tx['id'] ?? '',
        'Gross Amount': 'ETB ${tx['gross_amount'] ?? 0}',
        'Fee Charged': 'ETB ${tx['platform_fee'] ?? 0}',
        'Date': DateFormat('dd/MM/yyyy HH:mm')
            .format(DateTime.parse(tx['created_at'])),
      });
    }

    for (final sub in _monthlyFees) {
      rows.add({
        'Type': '5birr Monthly Fee',
        'Ref': sub['provider_id'] ?? sub['id'] ?? '',
        'Gross Amount': 'ETB ${sub['gross_amount'] ?? 0}',
        'Fee Charged': 'ETB ${sub['platform_fee'] ?? 0}',
        'Date': DateFormat('dd/MM/yyyy HH:mm')
            .format(DateTime.parse(sub['created_at'])),
      });
    }

    await CsvExport.exportAndShare(
      columns: ['Type', 'Ref', 'Gross Amount', 'Fee Charged', 'Date'],
      rows: rows,
      fileName:
          'income_summary_${DateFormat('yyyyMMdd').format(DateTime.now())}',
      title: 'Income Summary',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Income Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download, color: Colors.white),
            onPressed: _exportCsv,
            tooltip: 'Export CSV',
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Summary cards
                  Row(
                    children: [
                      Expanded(
                        child: _summaryCard(
                          '1% Transaction Fees',
                          'ETB ${_totalTxAmount.toStringAsFixed(2)}',
                          AppTheme.primaryGreen,
                          Icons.receipt_long,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _summaryCard(
                          '5birr Monthly Fees',
                          'ETB ${_totalMonthlyAmount.toStringAsFixed(2)}',
                          AppTheme.teal,
                          Icons.calendar_month,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _summaryCard(
                    'Total Income',
                    'ETB ${_totalIncome.toStringAsFixed(2)}',
                    AppTheme.gold,
                    Icons.account_balance_wallet,
                  ),
                  const SizedBox(height: 16),

                  // Filters
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Filters',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _dateBtn(
                                  _startDate != null
                                      ? DateFormat('dd/MM/yyyy')
                                          .format(_startDate!)
                                      : 'From',
                                  () => _pickDate(isStart: true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _dateBtn(
                                  _endDate != null
                                      ? DateFormat('dd/MM/yyyy')
                                          .format(_endDate!)
                                      : 'To',
                                  () => _pickDate(isStart: false),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.clear,
                                    size: 20, color: AppTheme.textMuted),
                                onPressed: _clearFilters,
                                tooltip: 'Clear filters',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              _filterChip('ALL'),
                              _filterChip('TRANSACTION_FEE'),
                              _filterChip('SUBSCRIPTION_FEE'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Transaction fee details
                  if (_txFees.isNotEmpty) ...[
                    _sectionHeader(
                        '1% Transaction Fee Details', AppTheme.primaryGreen),
                    const SizedBox(height: 8),
                    ..._txFees.take(50).map((tx) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.receipt_long,
                                        size: 16, color: AppTheme.primaryGreen),
                                    const SizedBox(width: 6),
                                    Text(
                                        'Fee #${(tx['id'] ?? '').toString().substring(0, 8)}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.textPrimary)),
                                    const Spacer(),
                                    Text('ETB ${tx['platform_fee'] ?? 0}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.primaryGreen)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                    'Transaction total: ETB ${tx['gross_amount'] ?? 0}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: AppTheme.textMuted)),
                                Text(
                                    DateFormat('dd/MM/yyyy HH:mm').format(
                                        DateTime.parse(tx['created_at'])),
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.textMuted)),
                              ],
                            ),
                          ),
                        )),
                  ],

                  // Monthly fee details
                  if (_monthlyFees.isNotEmpty) ...[
                    _sectionHeader('5birr Monthly Fee Details', AppTheme.teal),
                    const SizedBox(height: 8),
                    ..._monthlyFees.take(50).map((sub) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.calendar_month,
                                        size: 16, color: AppTheme.teal),
                                    const SizedBox(width: 6),
                                    Text(
                                        'Fee #${(sub['id'] ?? '').toString().substring(0, 8)}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.textPrimary)),
                                    const Spacer(),
                                    Text('ETB ${sub['platform_fee'] ?? 0}',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppTheme.teal)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                    DateFormat('dd/MM/yyyy').format(
                                        DateTime.parse(sub['created_at'])),
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.textMuted)),
                              ],
                            ),
                          ),
                        )),
                  ],

                  if (_txFees.isEmpty && _monthlyFees.isEmpty) ...[
                    const SizedBox(height: 40),
                    Center(
                      child: Column(
                        children: [
                          Icon(Icons.account_balance_wallet,
                              size: 48,
                              color: AppTheme.textMuted.withOpacity(0.3)),
                          const SizedBox(height: 12),
                          const Text('No income records found',
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 13)),
                          const Text('Try adjusting your date filters',
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 11)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _summaryCard(String title, String value, Color color, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textMuted)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _dateBtn(String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    );
  }

  Widget _filterChip(String type) {
    final selected = _typeFilter == type;
    final labels = {
      'ALL': 'All',
      'TRANSACTION_FEE': '1% Fees',
      'SUBSCRIPTION_FEE': '5birr Fees'
    };
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(labels[type] ?? type,
            style: TextStyle(
                fontSize: 11,
                color: selected ? Colors.white : AppTheme.textPrimary)),
        selected: selected,
        onSelected: (_) {
          setState(() => _typeFilter = type);
          _load();
        },
        selectedColor: AppTheme.primaryGreen,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _sectionHeader(String title, Color color) {
    return Row(
      children: [
        Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
                color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 8),
        Text(title,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary)),
      ],
    );
  }
}
