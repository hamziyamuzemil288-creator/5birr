import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';

class AdminRegistrationHistoryScreen extends StatefulWidget {
  const AdminRegistrationHistoryScreen({super.key});
  @override
  State<AdminRegistrationHistoryScreen> createState() => _State();
}

class _State extends State<AdminRegistrationHistoryScreen> {
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  DateTime? _startDate;
  DateTime? _endDate;
  String _roleFilter = 'ALL'; // ALL, USER, SERVICE_PROVIDER, VEHICLE_PROVIDER

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Load user registrations
      var userQuery = Supabase.instance.client
          .from('profiles')
          .select('id, full_name, phone, email, national_id, status, created_at');
      
      if (_startDate != null) {
        userQuery = userQuery.gte('created_at', _startDate!.toIso8601String());
      }
      if (_endDate != null) {
        final endExclusive = _endDate!.add(const Duration(days: 1));
        userQuery = userQuery.lt('created_at', endExclusive.toIso8601String());
      }
      
      final userData = await userQuery.order('created_at', ascending: false).limit(500);
      
      // Load provider registrations with profiles joined
      var provQuery = Supabase.instance.client
          .from('provider_profiles')
          .select('id, user_id, provider_type, business_name, status, created_at, profiles(full_name, phone, email)');
      
      if (_startDate != null) {
        provQuery = provQuery.gte('created_at', _startDate!.toIso8601String());
      }
      if (_endDate != null) {
        final endExclusive = _endDate!.add(const Duration(days: 1));
        provQuery = provQuery.lt('created_at', endExclusive.toIso8601String());
      }
      
      final provData = await provQuery.order('created_at', ascending: false).limit(500);

      if (mounted) {
        setState(() {
          _users = List<Map<String, dynamic>>.from(userData as List);
          _providers = List<Map<String, dynamic>>.from(provData as List);
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
        if (isStart) _startDate = picked;
        else _endDate = picked;
      });
      _load();
    }
  }

  void _clearFilters() {
    setState(() {
      _startDate = null;
      _endDate = null;
      _roleFilter = 'ALL';
    });
    _load();
  }

  List<Map<String, dynamic>> get _filteredItems {
    List<Map<String, dynamic>> items = [];
    
    if (_roleFilter == 'ALL' || _roleFilter == 'USER') {
      for (final u in _users) {
        items.add({
          ...u,
          '_type': 'USER',
          '_displayName': u['full_name'] ?? '',
          '_detail': u['email'] ?? u['phone'] ?? '',
        });
      }
    }
    
    if (_roleFilter == 'ALL' || _roleFilter == 'SERVICE_PROVIDER' || _roleFilter == 'VEHICLE_PROVIDER') {
      for (final p in _providers) {
        if (_roleFilter != 'ALL' && p['provider_type'] != _roleFilter) continue;
        final profile = p['profiles'] as Map<String, dynamic>?;
        items.add({
          ...p,
          '_type': p['provider_type'] ?? 'PROVIDER',
          '_displayName': p['business_name'] ?? profile?['full_name'] ?? '',
          '_detail': '${profile?['full_name'] ?? ''} · ${profile?['phone'] ?? ''}',
          '_status': p['status'],
        });
      }
    }
    
    // Sort by created_at descending
    items.sort((a, b) {
      final da = DateTime.parse(a['created_at'] as String);
      final db = DateTime.parse(b['created_at'] as String);
      return db.compareTo(da);
    });
    
    return items;
  }

  Future<void> _exportCsv() async {
    final items = _filteredItems;
    final columns = ['Name', 'Type', 'Status', 'Contact', 'Registration Date'];
    final rows = items.map((item) {
      final dt = DateTime.parse(item['created_at'] as String);
      return {
        'Name': item['_displayName'],
        'Type': item['_type']?.toString().replaceAll('_', ' ') ?? '',
        'Status': item['status'] ?? item['_status'] ?? '',
        'Contact': item['_detail'] ?? '',
        'Registration Date': CsvExport.formatDate(dt),
      };
    }).toList();

    await CsvExport.exportAndShare(
      columns: columns,
      rows: rows,
      fileName: 'registration_history_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Registration History',
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    
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
                    _roleChip('ALL'),
                    _roleChip('USER'),
                    _roleChip('SERVICE_PROVIDER'),
                    _roleChip('VEHICLE_PROVIDER'),
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
                _statBadge('Users', _users.length, AppTheme.info),
                const SizedBox(width: 8),
                _statBadge('Providers', _providers.length, AppTheme.primaryGreen),
                const SizedBox(width: 8),
                _statBadge('Total', items.length, AppTheme.teal),
              ],
            ),
          ),
          // List
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primaryGreen))
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

  Widget _roleChip(String role) {
    final selected = _roleFilter == role;
    final label = role == 'ALL'
        ? 'All'
        : role == 'USER'
            ? 'Users'
            : role == 'SERVICE_PROVIDER'
                ? 'Services'
                : 'Vehicles';
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: FilterChip(
        label: Text(label,
            style: TextStyle(
                fontSize: 11,
                color: selected ? Colors.white : AppTheme.textPrimary)),
        selected: selected,
        onSelected: (_) {
          setState(() => _roleFilter = role);
          _load();
        },
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
    final type = item['_type'] ?? '';
    final status = item['status'] ?? '';
    
    Color statusColor;
    switch (status) {
      case 'APPROVED':
        statusColor = AppTheme.success;
        break;
      case 'PENDING_APPROVAL':
        statusColor = AppTheme.warning;
        break;
      case 'REJECTED':
        statusColor = AppTheme.error;
        break;
      default:
        statusColor = AppTheme.textMuted;
    }

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
                color: type == 'USER'
                    ? AppTheme.info.withOpacity(0.1)
                    : AppTheme.primaryGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                type == 'USER' ? Icons.person : Icons.storefront,
                color: type == 'USER' ? AppTheme.info : AppTheme.primaryGreen,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item['_displayName'] ?? '',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${type.toString().replaceAll('_', ' ')} · ${item['_detail'] ?? ''}',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
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
