import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

/// Movement/permission control — adjust what each staff member (Super Admin,
/// Admin team, Owner team) may see and do. Edits go through the existing
/// `update_staff` RPC, which enforces the hierarchy server-side
/// (can_manage_staff): only the CEO, the Super Admin, and owner-team rows
/// may change a given row. True Admins/CEO are shown read-only.
class AdminRolePermissionsScreen extends ConsumerStatefulWidget {
  const AdminRolePermissionsScreen({super.key});

  @override
  ConsumerState<AdminRolePermissionsScreen> createState() =>
      _AdminRolePermissionsScreenState();
}

class _AdminRolePermissionsScreenState
    extends ConsumerState<AdminRolePermissionsScreen> {
  static const _permissionOptions = <String, String>{
    'sales_transactions': 'Sales & transactions',
    'registrations': 'Registrations',
    'category_management': 'Category management',
    'support_chat': 'Support / chat (incl. Appeals)',
    'payment_verification': 'Payment verification',
    'admin_history': 'View admin history',
    'view_reports': 'View reports',
    'view_expenses': 'View expenses',
    'view_auth_logs': 'View auth logs',
  };

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _staff = [];
  Map<String, dynamic>? _selected;
  Set<String> _perms = {};
  List<Map<String, dynamic>> _categories = [];
  Set<String> _cats = {};
  bool _saving = false;

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
      final rows = await client
          .from('staff')
          .select()
          .eq('is_active', true)
          .order('created_at');
      final staff = List<Map<String, dynamic>>.from(rows as List);

      List<Map<String, dynamic>> cats = [];
      try {
        final catRows = await client
            .from('categories')
            .select('id,name,sector')
            .eq('is_active', true)
            .order('sort_order');
        cats = List<Map<String, dynamic>>.from(catRows as List);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _staff = staff;
        _categories = cats;
        if (_selected != null) {
          _selected = staff
              .where((s) => s['id'] == _selected!['id'])
              .cast<Map<String, dynamic>>()
              .firstOrNull;
          _syncSelection();
        } else if (staff.isNotEmpty) {
          _selected = staff.first;
          _syncSelection();
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _syncSelection() {
    final s = _selected;
    if (s == null) return;
    _perms = ((s['permissions'] as List?) ?? []).map((e) => e.toString()).toSet();
    _cats = ((s['assigned_categories'] as List?) ?? [])
        .map((e) => e.toString())
        .toSet();
  }

  bool get _selectedLocked {
    final s = _selected;
    if (s == null) return true;
    // The CEO row and true-admin self rows are inherent; everything else is
    // editable per can_manage_staff (server enforces regardless).
    return s['is_ceo'] == true;
  }

  String _label(Map<String, dynamic> s) {
    if (s['is_ceo'] == true) return 'CEO';
    if (s['is_super_admin'] == true) return 'Super Admin';
    return ((s['branch'] as String?) ?? 'ADMIN') == 'ME'
        ? 'Owner team'
        : 'Admin team';
  }

  Future<void> _save({Set<String>? perms, Set<String>? cats}) async {
    final s = _selected;
    if (s == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_staff', params: {
        'p_staff_id': s['id'],
        if (perms != null) 'p_permissions': perms.toList(),
        if (cats != null) 'p_assigned_categories': cats.toList(),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update roles'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Role Permissions',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: AppTheme.error)),
                  ),
                )
              : _staff.isEmpty
                  ? const Center(
                      child: Text('No staff members yet.',
                          style: TextStyle(color: AppTheme.textSecondary)),
                    )
                  : Column(
                      children: [
                        // Person selector.
                        SizedBox(
                          height: 56,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            itemCount: _staff.length,
                            itemBuilder: (_, i) {
                              final s = _staff[i];
                              final selected =
                                  _selected?['id'] == s['id'];
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(
                                    '${s['name']} · ${_label(s)}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  selected: selected,
                                  onSelected: (_) {
                                    setState(() {
                                      _selected = s;
                                      _syncSelection();
                                    });
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(child: _buildMatrix()),
                      ],
                    ),
    );
  }

  Widget _buildMatrix() {
    final s = _selected;
    if (s == null) return const SizedBox.shrink();
    final locked = _selectedLocked;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${s['name']} — ${_label(s)}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              if (locked)
                const Tooltip(
                  message: 'The CEO\'s access is inherent and cannot be edited',
                  child: Icon(Icons.lock_outline,
                      size: 18, color: AppTheme.textSecondary),
                ),
            ],
          ),
          if (s['is_super_admin'] == true) ...[
            const SizedBox(height: 4),
            Text(
              'Super Admin: monitors every category, but sees and does only '
              'what is explicitly granted below — exactly like any other '
              'staff row.',
              style: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
            ),
          ],
          const SizedBox(height: 16),

          const Text('Section access',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ..._permissionOptions.entries.map((e) {
            final on = _perms.contains(e.key);
            return SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.value),
              value: on,
              activeColor: AppTheme.primaryGreen,
              onChanged: locked || _saving
                  ? null
                  : (v) {
                      final next = _perms.toSet();
                      if (v) {
                        next.add(e.key);
                      } else {
                        next.remove(e.key);
                      }
                      setState(() => _perms = next);
                      _save(perms: next);
                    },
            );
          }),
          const Divider(height: 28),

          const Text('Category scope',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            _cats.isEmpty
                ? 'No categories assigned — permitted sections apply app-wide.'
                : 'Permitted sections apply only within these categories.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _categories
                .map((c) => FilterChip(
                      label: Text((c['name'] as String?) ?? ''),
                      selected: _cats.contains(c['id'] as String),
                      onSelected: locked || _saving
                          ? null
                          : (v) {
                              final next = _cats.toSet();
                              if (v) {
                                next.add(c['id'] as String);
                              } else {
                                next.remove(c['id']);
                              }
                              setState(() => _cats = next);
                              _save(cats: next);
                            },
                    ))
                .toList(),
          ),
          const SizedBox(height: 24),
          Text(
            'Changes apply immediately: RLS policies and staff_has_permission '
            'read these values on every request.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
