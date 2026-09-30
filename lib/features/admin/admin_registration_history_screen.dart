import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';
import '../../core/utils/friendly_error.dart';

/// Task 8: Registration History with two combined categorizations:
///   Channel:       Self-registered / Sales-registered / Other (unknown code)
///   Confirmation:  System (QR agent) / Pending / Staff (by staff ID) / Rejected
/// All filtering happens server-side in admin_registration_history() (gated
/// by admin_can('registrations')); this screen only renders + sends filters.
class AdminRegistrationHistoryScreen extends StatefulWidget {
  const AdminRegistrationHistoryScreen({super.key});
  @override
  State<AdminRegistrationHistoryScreen> createState() => _State();
}

class _State extends State<AdminRegistrationHistoryScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  DateTime? _startDate;
  DateTime? _endDate;

  // Channel filter: null = all.
  String? _channelFilter; // 'SELF' | 'SALES' | 'OTHER'
  // Confirmation filter: null = all.
  String? _confirmFilter; // 'SYSTEM' | 'STAFF' | 'PENDING' | 'REJECTED'

  // Which KIND of person to show: null = everyone.
  //
  // This is the "registered persons in their category" control. Before it,
  // the only two axes were Channel (how they signed up) and Confirmation
  // (who approved them), so a buyer, a bajaj driver, a hotel and a staff
  // account were all one undifferentiated list -- and because the SQL did
  // not exclude staff from the USER branch, a staff account appeared in it
  // as an ordinary self-registered buyer. Migration
  // 20260927000108_registration_history_separates_staff.sql fixes the data;
  // this is the control that lets an admin actually ask for one group.
  String? _categoryFilter; // 'BUYER' | 'VEHICLE_PROVIDER' | 'SERVICE_PROVIDER' | 'STAFF'
  // Sales-person filter (the person whose code was used at signup).
  String? _referrerStaffId;
  // Free-text search across name / contact / referrer / confirming staff ID.
  String _search = '';

  List<Map<String, dynamic>> _staff = [];

  @override
  void initState() {
    super.initState();
    _loadStaff();
    _load();
  }

  Future<void> _loadStaff() async {
    try {
      final rows = await Supabase.instance.client.rpc('admin_referral_codes');
      final codes = List<Map<String, dynamic>>.from(rows as List);
      final byStaff = <String, String>{}; // staff_id -> name
      for (final c in codes) {
        byStaff[c['staff_id'] as String] = c['staff_name'] as String? ?? '';
      }
      if (mounted) {
        setState(() {
          _staff = byStaff.entries
              .map((e) => {'id': e.key, 'name': e.value})
              .toList()
            ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
        });
      }
    } catch (_) {
      // Staff list is a filter convenience only — never block the page.
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await Supabase.instance.client.rpc(
        'admin_registration_history',
        params: {
          // The category filter is sent as p_channel because that is the
          // parameter the server accepts category values on; sending both
          // would be ambiguous and the server would have to guess.
          'p_channel': _categoryFilter ?? _channelFilter,
          'p_confirmation': _confirmFilter,
          'p_staff_id': _referrerStaffId,
          if (_startDate != null) 'p_start': _startDate!.toIso8601String(),
          if (_endDate != null)
            'p_end': _endDate!.add(const Duration(days: 1)).toIso8601String(),
        },
      );
      if (mounted) {
        setState(() {
          _rows = List<Map<String, dynamic>>.from(rows as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyError(e, context: 'Could not load registrations');
          _loading = false;
        });
      }
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
        if (isStart) _startDate = picked; else _endDate = picked;
      });
      _load();
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _channelFilter = null;
      _confirmFilter = null;
      _categoryFilter = null;
      _referrerStaffId = null;
      _search = '';
    });
    _load();
  }

  /// Picking a category clears the channel filter and vice versa: both travel
  /// on the same server parameter, so leaving both set would send one and
  /// silently drop the other.
  void _setCategory(String? value) {
    setState(() {
      _categoryFilter = value;
      if (value != null) _channelFilter = null;
    });
    _load();
  }

  void _setChannel(String? value) {
    setState(() {
      _channelFilter = value;
      if (value != null) _categoryFilter = null;
    });
    _load();
  }

  List<Map<String, dynamic>> get _filtered {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    return _rows.where((r) {
      final haystack = [
        r['display_name'],
        r['contact'],
        r['referral_code'],
        r['referrer_name'],
        r['confirmed_by_staff_code'],
        r['confirmed_by_name'],
        // Searching "staff" must find the staff rows. The category is part of
        // what a person is searching for, not just what they are looking at.
        _typeLabel((r['record_type'] ?? '').toString()),
      ].whereType<String>().join(' ').toLowerCase();
      return haystack.contains(q);
    }).toList();
  }

  Future<void> _exportCsv() async {
    final items = _filtered;
    final columns = [
      'Name', 'Type', 'Status', 'Contact', 'Registration Date',
      'Channel', 'Referrer', 'Referral Code', 'Confirmation',
      'Confirmed By (Staff ID)', 'Confirmed At',
    ];
    final rows = items.map((item) {
      final created = DateTime.parse(item['created_at'] as String);
      final confirmedAt = item['confirmed_at'] != null
          ? DateTime.tryParse(item['confirmed_at'] as String)
          : null;
      return {
        'Name': item['display_name'] ?? '',
        'Type': (item['record_type'] ?? '').toString().replaceAll('_', ' '),
        'Status': item['status'] ?? '',
        'Contact': item['contact'] ?? '',
        'Registration Date': CsvExport.formatDate(created),
        'Channel': _channelLabel(item['channel'] as String?),
        'Referrer': item['referrer_name'] ?? '',
        'Referral Code': item['referral_code'] ?? '',
        'Confirmation': _confirmLabel(item['confirmation'] as String?),
        'Confirmed By (Staff ID)': item['confirmed_by_staff_code'] ?? '',
        'Confirmed At': confirmedAt != null ? CsvExport.formatDate(confirmedAt) : '',
      };
    }).toList();

    await CsvExport.exportAndShare(
      columns: columns,
      rows: rows,
      fileName: 'registration_history_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Registration History',
    );
  }

  /// Human label for `record_type`. 'USER' reads as "Buyer" on purpose: the
  /// raw enum name is the thing that made staff accounts indistinguishable
  /// from customers in the first place.
  static String _typeLabel(String type) => switch (type) {
        'USER' => 'Buyer',
        'VEHICLE_PROVIDER' => 'Vehicle provider',
        'SERVICE_PROVIDER' => 'Service provider',
        'STAFF' => 'Staff / admin',
        _ => type.replaceAll('_', ' '),
      };

  static Color _typeColor(String type) => switch (type) {
        'USER' => AppTheme.info,
        'STAFF' => AppTheme.gold,
        _ => AppTheme.primaryGreen,
      };

  static IconData _typeIcon(String type) => switch (type) {
        'USER' => Icons.person,
        'STAFF' => Icons.badge_outlined,
        'VEHICLE_PROVIDER' => Icons.directions_car,
        'SERVICE_PROVIDER' => Icons.storefront,
        _ => Icons.person,
      };

  static String _channelLabel(String? c) {
    switch (c) {
      case 'SELF': return 'Self-registered';
      case 'SALES': return 'Sales-registered';
      case 'OTHER': return 'Other (unknown code)';
      default: return c ?? '';
    }
  }

  static String _confirmLabel(String? c) {
    switch (c) {
      case 'SYSTEM': return 'Confirmed by system';
      case 'STAFF': return 'Confirmed by staff';
      case 'PENDING': return 'Pending';
      case 'REJECTED': return 'Rejected';
      default: return c ?? '';
    }
  }

  Color _confirmColor(String? c) {
    switch (c) {
      case 'SYSTEM': return AppTheme.success;
      case 'STAFF': return AppTheme.teal;
      case 'PENDING': return AppTheme.warning;
      case 'REJECTED': return AppTheme.error;
      default: return AppTheme.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registration History'),
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
                // WHO they are -- the category axis. First, because it is the
                // question an admin actually asks ("show me the providers",
                // "show me the staff"), and because before migration 0108 a
                // staff account was filed under the buyer branch.
                //
                // Row inside a horizontal SingleChildScrollView rather than a
                // fixed-height box: the chip row sizes itself to the chips,
                // so it cannot overflow at any system text scale. The old
                // SizedBox(height: 34) form did, on the same pattern that
                // produced the admin "bottom overflow" stripes elsewhere.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _chip('Everyone', _categoryFilter == null && _channelFilter == null,
                          () => _setCategory(null)),
                      _chip('Buyers', _categoryFilter == 'BUYER',
                          () => _setCategory('BUYER')),
                      _chip('Vehicle providers', _categoryFilter == 'VEHICLE_PROVIDER',
                          () => _setCategory('VEHICLE_PROVIDER')),
                      _chip('Service providers', _categoryFilter == 'SERVICE_PROVIDER',
                          () => _setCategory('SERVICE_PROVIDER')),
                      _chip('Staff & admins', _categoryFilter == 'STAFF',
                          () => _setCategory('STAFF')),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // HOW they signed up -- the original channel axis.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _chip('All channels',
                          _channelFilter == null && _categoryFilter == null,
                          () => _setChannel(null)),
                      _chip('Self-registered', _channelFilter == 'SELF',
                          () => _setChannel('SELF')),
                      _chip('Sales-registered', _channelFilter == 'SALES',
                          () => _setChannel('SALES')),
                      _chip('Other', _channelFilter == 'OTHER',
                          () => _setChannel('OTHER')),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // Confirmation categorization. "By staff" here means
                // "approved by a staff member", which is a DIFFERENT thing
                // from the "Staff & admins" category chip above -- hence the
                // wording on both sides.
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _chip('Any status', _confirmFilter == null, () {
                        setState(() => _confirmFilter = null);
                        _load();
                      }),
                      _chip('By system', _confirmFilter == 'SYSTEM', () {
                        setState(() => _confirmFilter = 'SYSTEM');
                        _load();
                      }),
                      _chip('By staff', _confirmFilter == 'STAFF', () {
                        setState(() => _confirmFilter = 'STAFF');
                        _load();
                      }),
                      _chip('Pending', _confirmFilter == 'PENDING', () {
                        setState(() => _confirmFilter = 'PENDING');
                        _load();
                      }),
                      _chip('Rejected', _confirmFilter == 'REJECTED', () {
                        setState(() => _confirmFilter = 'REJECTED');
                        _load();
                      }),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    // Sales-person filter (from issued referral codes).
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _referrerStaffId,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: 'Sales person',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem(value: null, child: Text('Anyone')),
                          ..._staff.map((s) => DropdownMenuItem(
                                value: s['id'] as String,
                                child: Text(s['name'] as String,
                                    overflow: TextOverflow.ellipsis),
                              )),
                        ],
                        onChanged: (v) {
                          setState(() => _referrerStaffId = v);
                          _load();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        decoration: const InputDecoration(
                          labelText: 'Search name / staff ID',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (v) => setState(() => _search = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Stats
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _statBadge('Total', items.length, AppTheme.teal),
                const SizedBox(width: 8),
                _statBadge('Buyers',
                    items.where((r) => r['record_type'] == 'USER').length,
                    AppTheme.info),
                const SizedBox(width: 8),
                _statBadge(
                    'Providers',
                    items
                        .where((r) =>
                            r['record_type'] == 'VEHICLE_PROVIDER' ||
                            r['record_type'] == 'SERVICE_PROVIDER')
                        .length,
                    AppTheme.primaryGreen),
                const SizedBox(width: 8),
                _statBadge('Staff',
                    items.where((r) => r['record_type'] == 'STAFF').length,
                    AppTheme.gold),
                const SizedBox(width: 8),
                _statBadge('Pending',
                    items.where((r) => r['confirmation'] == 'PENDING').length,
                    AppTheme.warning),
              ],
            ),
          ),
          // List
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primaryGreen))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12)),
                              TextButton(onPressed: _load, child: const Text('Retry')),
                            ],
                          ),
                        ),
                      )
                    : items.isEmpty
                        ? const Center(
                            child: Text('No registrations found',
                                style: TextStyle(color: AppTheme.textMuted)))
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: items.length,
                            itemBuilder: (_, i) => _registrationCard(items[i]),
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

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: selected ? Colors.white : AppTheme.textPrimary)),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppTheme.primaryGreen,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _statBadge(String label, int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('$label: $count',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _registrationCard(Map<String, dynamic> item) {
    final dt = DateTime.parse(item['created_at'] as String);
    final type = (item['record_type'] ?? '') as String;
    final status = (item['status'] ?? '') as String;
    final channel = item['channel'] as String?;
    final confirmation = item['confirmation'] as String?;
    final referrerName = item['referrer_name'] as String?;
    final referralCode = item['referral_code'] as String?;
    final confirmedByCode = item['confirmed_by_staff_code'] as String?;

    final Color statusColor = switch (status) {
      'APPROVED' => AppTheme.success,
      'PENDING_APPROVAL' => AppTheme.warning,
      'REJECTED' => AppTheme.error,
      _ => AppTheme.textMuted,
    };

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
                color: _typeColor(type).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _typeIcon(type),
                color: _typeColor(type),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['display_name'] ?? '',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_typeLabel(type)} · ${item['contact'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 4),
                  // Channel line.
                  Text(
                    switch (channel) {
                      'SELF' => 'Self-registered',
                      'SALES' => 'Sales-registered by ${referrerName ?? ''}',
                      'OTHER' => 'Other — code "${referralCode ?? ''}" not matched',
                      _ => '',
                    },
                    style: TextStyle(
                      fontSize: 11,
                      color: channel == 'SALES' ? AppTheme.primaryGreen : AppTheme.textMuted,
                      fontWeight: channel == 'SALES' ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    status.replaceAll('_', ' '),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: statusColor),
                  ),
                ),
                const SizedBox(height: 4),
                // Confirmation chip with confirming staff ID.
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _confirmColor(confirmation).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    confirmation == 'STAFF'
                        ? 'By staff ${confirmedByCode ?? '?'}'
                        : confirmation == 'SYSTEM'
                            ? 'By system'
                            : _confirmLabel(confirmation),
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: _confirmColor(confirmation)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  DateFormat('dd/MM/yyyy').format(dt),
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
