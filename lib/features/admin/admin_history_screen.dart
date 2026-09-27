import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

/// Phase 3: filterable admin history / audit trail.
///
/// Reads the append-only admin_history table (RLS: admins only). Filters:
/// free-text search (actor name / action), action type, category, city and
/// date range. Image paths (Supabase Storage) are shown via a 5-minute
/// signed URL when present.
class AdminHistoryScreen extends StatefulWidget {
  const AdminHistoryScreen({super.key});

  @override
  State<AdminHistoryScreen> createState() => _AdminHistoryScreenState();
}

class _AdminHistoryScreenState extends State<AdminHistoryScreen> {
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  String? _actionFilter;
  String? _categoryFilter;
  String? _cityFilter;
  DateTime? _from;
  DateTime? _to;

  static const _categories = [
    'registration',
    'transaction',
    'staff',
    'support',
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      var q = client.from('admin_history').select();

      final search = _searchController.text.trim();
      if (search.isNotEmpty) {
        q = q.or('actor_name.ilike.%$search%,action_type.ilike.%$search%');
      }
      if (_actionFilter != null) q = q.eq('action_type', _actionFilter!);
      if (_categoryFilter != null) q = q.eq('category', _categoryFilter!);
      if (_cityFilter != null) q = q.eq('city', _cityFilter!);
      if (_from != null) {
        q = q.gte('created_at', _from!.toUtc().toIso8601String());
      }
      if (_to != null) {
        final toEnd = _to!.add(const Duration(days: 1));
        q = q.lt('created_at', toEnd.toUtc().toIso8601String());
      }

      final rows = await q
          .order('created_at', ascending: false)
          .limit(200);
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, context: 'Could not load the audit log');
        _loading = false;
      });
    }
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() => isFrom ? _from = picked : _to = picked);
    _load();
  }

  Future<void> _showImages(List<String> paths) async {
    final client = Supabase.instance.client;
    final urls = <String>[];
    for (final p in paths) {
      try {
        final parts = p.split('/');
        final bucket = parts.removeAt(0);
        urls.add(await client.storage.from(bucket).createSignedUrl(
              parts.join('/'),
              300,
            ));
      } catch (_) {
        urls.add('');
      }
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Attachments'),
        content: urls.isEmpty
            ? const Text('No images')
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final u in urls)
                    u.isEmpty
                        ? const Text('Image unavailable')
                        : Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Image.network(u),
                          ),
                ],
              ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin History')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _searchController,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search actor or action…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.filter_list),
                  onPressed: _openFilters,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!, textAlign: TextAlign.center))
                    : _rows.isEmpty
                        ? const Center(child: Text('No history entries'))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: _rows.length,
                              itemBuilder: (_, i) {
                                final r = _rows[i];
                                final images =
                                    ((r['image_paths'] as List?) ?? [])
                                        .map((e) => e.toString())
                                        .toList();
                                final created =
                                    DateTime.tryParse(r['created_at'] ?? '');
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  child: ListTile(
                                    title: Text(
                                      '${r['action_type'] ?? ''}'
                                      '${r['category'] != null ? '  ·  ${r['category']}' : ''}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      '${r['actor_name'] ?? 'unknown'}'
                                      '${r['city'] != null ? '  ·  ${r['city']}' : ''}'
                                      '${created != null ? '  ·  ${created.toLocal().toString().substring(0, 16)}' : ''}',
                                    ),
                                    trailing: images.isNotEmpty
                                        ? IconButton(
                                            icon: const Icon(
                                                Icons.image_outlined),
                                            onPressed: () =>
                                                _showImages(images),
                                          )
                                        : null,
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  void _openFilters() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Filters', style: AppTheme.sectionHeader),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _actionFilter,
                decoration:
                    const InputDecoration(labelText: 'Action type'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Any action')),
                  DropdownMenuItem(
                      value: 'APPROVE_PROVIDER', child: Text('Approve provider')),
                  DropdownMenuItem(
                      value: 'REJECT_PROVIDER', child: Text('Reject provider')),
                  DropdownMenuItem(
                      value: 'SUSPEND_PROVIDER', child: Text('Suspend provider')),
                  DropdownMenuItem(
                      value: 'APPROVE_USER', child: Text('Approve user')),
                  DropdownMenuItem(
                      value: 'REJECT_USER', child: Text('Reject user')),
                  DropdownMenuItem(
                      value: 'PAYMENT_PROOF_VERIFIED',
                      child: Text('Payment verified')),
                  DropdownMenuItem(
                      value: 'PAYMENT_PROOF_REJECTED',
                      child: Text('Payment rejected')),
                  DropdownMenuItem(
                      value: 'STAFF_CREATED', child: Text('Staff created')),
                  DropdownMenuItem(
                      value: 'STAFF_UPDATED', child: Text('Staff updated')),
                  DropdownMenuItem(
                      value: 'STAFF_REVOKED', child: Text('Staff revoked')),
                  DropdownMenuItem(
                      value: 'CONTACT_RELEASED',
                      child: Text('Contact released')),
                ],
                onChanged: (v) => setSheetState(() => _actionFilter = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: _categoryFilter,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any category')),
                  for (final c in _categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setSheetState(() => _categoryFilter = v),
              ),
              const SizedBox(height: 10),
              TextField(
                decoration: const InputDecoration(labelText: 'City'),
                onChanged: (v) => setSheetState(() {
                  _cityFilter = v.trim().isEmpty ? null : v.trim();
                }),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDateFromSheet(
                          sheetContext, setSheetState, true),
                      child: Text(_from == null
                          ? 'From date'
                          : _from!.toLocal().toString().substring(0, 10)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _pickDateFromSheet(
                          sheetContext, setSheetState, false),
                      child: Text(_to == null
                          ? 'To date'
                          : _to!.toLocal().toString().substring(0, 10)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () {
                      setSheetState(() {
                        _actionFilter = null;
                        _categoryFilter = null;
                        _cityFilter = null;
                        _from = null;
                        _to = null;
                      });
                    },
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _load();
                    },
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _pickDateFromSheet(BuildContext sheetContext, StateSetter setSheetState,
      bool isFrom) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: sheetContext,
      initialDate: now,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    setSheetState(() => isFrom ? _from = picked : _to = picked);
  }
}
