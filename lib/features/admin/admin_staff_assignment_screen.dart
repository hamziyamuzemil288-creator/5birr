import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/services/city_service.dart';
import '../../core/theme/app_theme.dart';

/// Staff Assignment — true Admin only (the Supabase-registered owner
/// account). Lists every assignable role, lets the admin pick any user,
/// set their city, toggle each role independently (Super Admin, Admin-team
/// /Owner-team staff, and each of the 9 staff permissions), scope them to
/// categories, warn them, or delete their account entirely.
///
/// Every server path re-checks authorization (is_admin()/can_manage_staff/
/// RLS); this page's gate is convenience UX, not the security boundary.
class AdminStaffAssignmentScreen extends ConsumerStatefulWidget {
  const AdminStaffAssignmentScreen({super.key});

  @override
  ConsumerState<AdminStaffAssignmentScreen> createState() =>
      _AdminStaffAssignmentScreenState();
}

class _AdminStaffAssignmentScreenState
    extends ConsumerState<AdminStaffAssignmentScreen> {
  // Role toggles shown on the page. Keys are the staff.permissions vocabulary
  // (same 9 entries the RLS layer checks); Super Admin / branch are separate.
  static const _roleOptions = <String, String>{
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

  final _searchCtrl = TextEditingController();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _selected;
  Map<String, dynamic>? _selectedStaffRow;
  List<Map<String, dynamic>> _categories = [];
  final Set<String> _selectedCats = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _isAdmin => ref.read(authProvider).isAdmin;

  Future<void> _load() async {
    if (!_isAdmin) {
      setState(() {
        _loading = false;
        _error = 'Only the admin can use this page.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;

      // Users (profiles join auth email via the embedded FK auth.users).
      final rows = await client
          .from('profiles')
          .select('id, full_name, phone, email, city, status')
          .order('created_at', ascending: false)
          .limit(300);
      final users = List<Map<String, dynamic>>.from(rows as List);

      // Existing staff rows keyed by user_id.
      final staffRows = await client.from('staff').select('*');
      final staffByUser = <String, Map<String, dynamic>>{};
      for (final s in (staffRows as List)) {
        final sm = Map<String, dynamic>.from(s as Map);
        final uid = sm['user_id'] as String?;
        if (uid != null) staffByUser[uid] = sm;
      }
      // Enrich users with their staff row + role flags.
      for (final u in users) {
        final s = staffByUser[u['id'] as String];
        u['_staff'] = s;
        u['_isSuper'] = s?['is_super_admin'] == true;
        u['_isCeo'] = s?['is_ceo'] == true;
        u['_branch'] = (s?['branch'] as String?) ?? '';
        final perms = ((s?['permissions'] as List?) ?? [])
            .map((e) => e.toString())
            .toSet();
        u['_perms'] = perms;
      }

      // Categories for scope assignment (best-effort).
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
        _users = users;
        _categories = cats;
        if (_selected != null) {
          _selected = users
              .where((u) => u['id'] == _selected!['id'])
              .cast<Map<String, dynamic>>()
              .firstOrNull;
          _syncSelectionState();
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

  void _syncSelectionState() {
    final u = _selected;
    if (u == null) return;
    _selectedStaffRow = u['_staff'] as Map<String, dynamic>?;
    _selectedCats
      ..clear()
      ..addAll(((u['_staff']?['assigned_categories'] as List?) ?? [])
          .map((e) => e.toString()));
  }

  List<Map<String, dynamic>> get _filteredUsers {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _users;
    return _users
        .where((u) =>
            (u['full_name'] as String? ?? '').toLowerCase().contains(q) ||
            (u['email'] as String? ?? '').toLowerCase().contains(q) ||
            (u['phone'] as String? ?? '').contains(q))
        .toList();
  }

  Future<void> _togglePermission(String perm, bool on) async {
    final u = _selected;
    if (u == null || _saving) return;
    final staffId = (u['_staff']?['id'] as String?);
    final current = (u['_perms'] as Set<String>).toSet();
    if (staffId == null && !on) return; // nothing to remove
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      Map<String, dynamic> updated;
      if (staffId == null) {
        // First role for this user → create their staff row. A staff_code
        // is required by the schema; derive one from the name.
        final code = 'ST${DateTime.now().millisecondsSinceEpoch
            .toString().substring(7)}';
        final res = await client.rpc('create_staff', params: {
          'p_name': (u['full_name'] as String?) ?? 'Staff',
          'p_staff_code': code,
          'p_permissions': [perm],
          'p_branch': 'ADMIN',
          'p_assigned_categories': _selectedCats.toList(),
        });
        updated = Map<String, dynamic>.from(res as Map);
      } else {
        final next = current..add(perm);
        final res = await client.rpc('update_staff', params: {
          'p_staff_id': staffId,
          'p_permissions': next.toList(),
        });
        updated = Map<String, dynamic>.from(res as Map);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Role ${on ? 'granted' : 'revoked'}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _revokeAllStaff() async {
    final u = _selected;
    final staffId = (u?['_staff']?['id'] as String?);
    if (u == null || staffId == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_staff', params: {
        'p_staff_id': staffId,
        'p_permissions': <String>[],
        'p_is_super_admin': false,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('All roles revoked')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _toggleSuperAdmin(bool on) async {
    final u = _selected;
    final staffId = (u?['_staff']?.['id']) as String?;
    if (u == null || _saving) return;
    if (on && staffId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Grant a staff role first, then promote')));
      return;
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_staff', params: {
        'p_staff_id': staffId,
        'p_is_super_admin': on,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(on ? 'Promoted to Super Admin' : 'Super Admin off')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setBranch(String branch) async {
    final u = _selected;
    final staffId = (u?['_staff']?['id'] as String?);
    if (u == null || staffId == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_staff', params: {
        'p_staff_id': staffId,
        'p_branch': branch,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(branch == 'ME' ? 'Moved to Owner team' : 'Moved to Admin team')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _setCity(String? city) async {
    final u = _selected;
    if (u == null || _saving) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('admin_set_user_city', params: {
        'p_user_id': u['id'],
        'p_city': city,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(city == null ? 'City cleared' : 'City set to $city')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _toggleCategory(String catId, bool on) async {
    final u = _selected;
    final staffId = (u?['_staff']?['id'] as String?);
    if (u == null || staffId == null || _saving) return;
    final next = _selectedCats.toSet();
    if (on) {
      next.add(catId);
    } else {
      next.remove(catId);
    }
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('update_staff', params: {
        'p_staff_id': staffId,
        'p_assigned_categories': next.toList(),
      });
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _warnUser() async {
    final u = _selected;
    if (u == null) return;
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Warn ${u['full_name'] ?? 'user'}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bodyCtrl,
              maxLines: 3,
              decoration:
                  const InputDecoration(labelText: 'Warning message'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send warning')),
        ],
      ),
    );
    if (ok != true) return;
    final title = titleCtrl.text.trim();
    final body = bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('admin_warn_user', params: {
        'p_user_id': u['id'],
        'p_title': title,
        'p_body': body,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Warning sent')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _deleteUser() async {
    final u = _selected;
    if (u == null) return;
    final name = (u['full_name'] as String?) ?? 'this user';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account'),
        content: Text(
            'Permanently delete $name and their auth account? This cannot be '
            'undone. Admin accounts can never be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final res = await Supabase.instance.client.functions
          .invoke('user-admin', body: {
        'action': 'delete_user',
        'user_id': u['id'],
      });
      final data = res.data as Map<String, dynamic>?;
      if (!mounted) return;
      if (res.status == 200 && data?['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$name deleted')));
        setState(() => _selected = null);
        await _load();
      } else {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Delete failed: ${data?['error'] ?? res.status}')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAdmin) {
      return Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
            title: const Text('Staff Assignment'),
            backgroundColor: AppTheme.primaryGreenDark),
        body: const Center(
          child: Text('Only the admin can open this page.',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Staff Assignment',
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
              : Row(
                  children: [
                    // Left: searchable user list.
                    ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: 340),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: TextField(
                              controller: _searchCtrl,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: 'Search name, email, phone',
                                isDense: true,
                              ),
                            ),
                          ),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _filteredUsers.length,
                              itemBuilder: (_, i) {
                                final u = _filteredUsers[i];
                                final selected =
                                    _selected?['id'] == u['id'];
                                return ListTile(
                                  dense: true,
                                  selected: selected,
                                  selectedTileColor:
                                      AppTheme.primaryGreen.withOpacity(0.10),
                                  leading: Icon(
                                    u['_isCeo'] == true
                                        ? Icons.workspace_premium_outlined
                                        : u['_isSuper'] == true
                                            ? Icons.shield_outlined
                                            : Icons.person_outline,
                                    color: u['_isCeo'] == true ||
                                            u['_isSuper'] == true
                                        ? AppTheme.primaryGreenDark
                                        : AppTheme.textSecondary,
                                  ),
                                  title: Text(
                                      (u['full_name'] as String?) ?? '—',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    ((u['email'] as String?) ?? '') +
                                        ((u['_isSuper'] == true)
                                            ? ' · Super Admin'
                                            : u['_isCeo'] == true
                                                ? ' · CEO'
                                                : ''),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  onTap: () {
                                    setState(() {
                                      _selected =
                                          Map<String, dynamic>.from(u);
                                      _syncSelectionState();
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // Right: selected user's role panel.
                    Expanded(
                      child: _selected == null
                          ? const Center(
                              child: Text('Select a user to manage their roles',
                                  style: TextStyle(
                                      color: AppTheme.textSecondary)),
                            )
                          : _buildPanel(),
                    ),
                  ],
                ),
    );
  }

  Widget _buildPanel() {
    final u = _selected!;
    final isCeo = u['_isCeo'] == true;
    final isSuper = u['_isSuper'] == true;
    final staffId = u['_staff']?['id'] as String?;
    final branch = (u['_branch'] as String?) ?? '';
    final city = (u['city'] as String?) ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (u['full_name'] as String?) ?? '—',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              if (isCeo)
                const Chip(
                  avatar: Icon(Icons.workspace_premium_outlined,
                      size: 18, color: AppTheme.primaryGreenDark),
                  label: Text('CEO — locked'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${u['email'] ?? '—'} · ${u['phone'] ?? 'no phone'}',
              style: const TextStyle(color: AppTheme.textSecondary)),
          const SizedBox(height: 16),

          // ── City (B) ──
          const Text('City', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: city.isEmpty ? null : city,
            hint: const Text('Select city'),
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: '__none__', child: Text('— no city —')),
              // Include the saved value first so a custom city (set via
              // search autocomplete) never trips the dropdown assert.
              if (city.isNotEmpty && !CityService.knownCities.contains(city))
                DropdownMenuItem(value: city, child: Text(city)),
              ...CityService.knownCities.map((c) =>
                  DropdownMenuItem(value: c, child: Text(c))),
            ],
            onChanged: isCeo
                ? null
                : (v) {
                    if (v == null) return;
                    _setCity(v == '__none__' ? null : v);
                  },
          ),
          const SizedBox(height: 20),

          // ── Special roles (C) ──
          const Text('Special roles',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Super Admin',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text(
                'Controls every category per their explicit permission list',
                style: TextStyle(fontSize: 12)),
            value: isSuper,
            onChanged: isCeo ? null : (v) => _toggleSuperAdmin(v),
          ),
          if (staffId != null && !isCeo) ...[
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Admin team'),
                  selected: branch == 'ADMIN',
                  onSelected: (_) => _setBranch('ADMIN'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Owner team'),
                  selected: branch == 'ME',
                  onSelected: (_) => _setBranch('ME'),
                ),
              ],
            ),
          ],
          const Divider(height: 28),

          // ── Staff role toggles (C) ──
          const Text('Staff roles',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          ..._roleOptions.entries.map((e) {
            final on = (u['_perms'] as Set<String>).contains(e.key);
            return SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(e.value),
              value: on,
              activeColor: AppTheme.primaryGreen,
              onChanged: isCeo ? null : (v) => _togglePermission(e.key, v),
            );
          }),
          if (staffId != null && !isCeo) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _saving ? null : _revokeAllStaff,
              icon: const Icon(Icons.block, size: 18),
              label: const Text('Revoke all roles'),
            ),
          ],
          const Divider(height: 28),

          // ── Category scope ──
          const Text('Category scope',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            _selectedCats.isEmpty
                ? 'No categories assigned (staff roles apply app-wide).'
                : 'Scoped to the selected categories only.',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: _categories
                .map((c) => FilterChip(
                      label: Text((c['name'] as String?) ?? ''),
                      selected: _selectedCats.contains(c['id'] as String),
                      onSelected: isCeo || staffId == null
                          ? null
                          : (v) => _toggleCategory(c['id'] as String, v),
                    ))
                .toList(),
          ),
          const SizedBox(height: 28),

          // ── Actions (D) ──
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: isCeo ? null : _warnUser,
                icon: const Icon(Icons.warning_amber_outlined, size: 18),
                label: const Text('Warn user'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error),
                onPressed: isCeo ? null : _deleteUser,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('Delete user'),
              ),
            ],
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }
}
