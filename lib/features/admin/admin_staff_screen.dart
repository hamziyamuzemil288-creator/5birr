import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';

/// Phase 2: staff / sub-admin management.
///
/// Visible only to super admins (the super-admin flag lives on the staff
/// row, enforced server-side by the create/update/revoke RPCs — hiding the
/// UI is convenience, not the security boundary).
class AdminStaffScreen extends ConsumerStatefulWidget {
  const AdminStaffScreen({super.key});

  @override
  ConsumerState<AdminStaffScreen> createState() => _AdminStaffScreenState();
}

class _AdminStaffScreenState extends ConsumerState<AdminStaffScreen> {
  List<Map<String, dynamic>> _staff = [];
  bool _loading = true;
  String? _error;
  bool _isSuperAdmin = false;
  /// One-time bootstrap: an ADMIN with no super admin yet may initialize
  /// the staff program (create_staff self-links the first super admin).
  bool _canBootstrap = false;

  static const _permissionOptions = {
    'sales_transactions': 'Sales & transactions',
    'registrations': 'Registrations',
    'category_management': 'Category management',
    'support_chat': 'Support / chat',
    'payment_verification': 'Payment verification',
    'admin_history': 'View admin history',
  };

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
      final uid = client.auth.currentUser?.id;
      if (uid != null) {
        final me = await client
            .from('staff')
            .select('is_super_admin')
            .eq('user_id', uid)
            .eq('is_active', true)
            .maybeSingle();
        _isSuperAdmin = (me?['is_super_admin'] as bool?) ?? false;
      }
      final rows = await client
          .from('staff')
          .select()
          .order('created_at', ascending: false);
      final staff = List<Map<String, dynamic>>.from(rows as List);
      if (!mounted) return;
      final hasActiveSuper =
          staff.any((s) => s['is_super_admin'] == true && s['is_active'] == true);
      setState(() {
        _staff = staff;
        _canBootstrap =
            ref.read(authProvider).isAdmin && !_isSuperAdmin && !hasActiveSuper;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// One-time initialization of the staff program: the acting ADMIN creates
  /// themselves as the first super admin (create_staff self-links their auth
  /// user). Only offered when no active super admin exists.
  Future<void> _bootstrapStaffProgram() async {
    final nameController = TextEditingController(
        text: Supabase.instance.client.auth.currentUser?.userMetadata?['full_name'] as String? ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Initialize staff program'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'You are the first admin. This creates your super-admin '
                'staff record so you can add sub-admins with limited '
                'permissions. This can only be done once.'),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Your name *'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Initialize')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final name = nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your name is required')));
      return;
    }
    try {
      final code =
          'SA-' + DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase();
      await Supabase.instance.client.rpc('create_staff', params: {
        'p_name': name,
        'p_staff_code': code,
        'p_permissions': <String>[
          'sales_transactions',
          'registrations',
          'category_management',
          'support_chat',
          'payment_verification',
          'admin_history'
        ],
        'p_sales_target': 0,
        'p_is_super_admin': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Staff program initialized — you are the super admin')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    final nameController =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final codeController =
        TextEditingController(text: existing?['staff_code'] as String? ?? '');
    final targetController = TextEditingController(
        text: existing?['sales_target']?.toString() ?? '0');
    final selected = ((existing?['permissions'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    bool isSuper = (existing?['is_super_admin'] as bool?) ?? false;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(existing == null ? 'Add staff' : 'Edit staff',
                  style: AppTheme.sectionHeader),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Full name *'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: codeController,
                enabled: existing == null,
                decoration: const InputDecoration(
                    labelText: 'Staff ID *', helperText: 'Unique, immutable'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: targetController,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Sales target (ETB)'),
              ),
              const SizedBox(height: 12),
              const Text('Permissions', style: AppTheme.sectionHeader),
              ..._permissionOptions.entries.map(
                (e) => CheckboxListTile(
                  dense: true,
                  title: Text(e.value, style: const TextStyle(fontSize: 13)),
                  value: selected.contains(e.key),
                  onChanged: (on) => setSheetState(() {
                    on == true
                        ? selected.add(e.key)
                        : selected.remove(e.key);
                  }),
                ),
              ),
              CheckboxListTile(
                dense: true,
                title: const Text('Super admin (runs the staff program)',
                    style: TextStyle(fontSize: 13)),
                value: isSuper,
                onChanged: (on) => setSheetState(() => isSuper = on ?? false),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: existing == null ? 'Create staff' : 'Save changes',
                onPressed: () async {
                  if (nameController.text.trim().isEmpty ||
                      codeController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      const SnackBar(
                          content: Text('Name and staff ID are required')),
                    );
                    return;
                  }
                  try {
                    final client = Supabase.instance.client;
                    if (existing == null) {
                      await client.rpc('create_staff', params: {
                        'p_name': nameController.text.trim(),
                        'p_staff_code': codeController.text.trim(),
                        'p_permissions': selected,
                        'p_sales_target':
                            double.tryParse(targetController.text) ?? 0,
                        'p_is_super_admin': isSuper,
                      });
                    } else {
                      await client.rpc('update_staff', params: {
                        'p_staff_id': existing['id'],
                        'p_name': nameController.text.trim(),
                        'p_permissions': selected,
                        'p_sales_target':
                            double.tryParse(targetController.text) ?? 0,
                      });
                    }
                    if (sheetContext.mounted) Navigator.pop(sheetContext, true);
                  } catch (e) {
                    if (sheetContext.mounted) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(
                            content: Text(e
                                .toString()
                                .replaceFirst('PostgrestException(', ''))),
                      );
                    }
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (result == true) _load();
  }

  Future<void> _revoke(Map<String, dynamic> staff) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Revoke ${staff['name']}?'),
        content: const Text(
            'The staff member loses admin access and their staff entry is '
            'deactivated. History is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .rpc('revoke_staff', params: {'p_staff_id': staff['id']});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _showPerformance(Map<String, dynamic> staff) async {
    try {
      final rows = await Supabase.instance.client
          .rpc('staff_performance', params: {'p_staff_id': staff['id']});
      final r = (rows as List).isNotEmpty
          ? rows.first as Map<String, dynamic>
          : <String, dynamic>{};
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${staff['name']} — performance'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Registrations approved: ${r['registrations'] ?? 0}'),
              Text('Sales total: ETB ${r['sales_total'] ?? 0}'),
              Text('Orders: ${r['orders_count'] ?? 0}'),
              Text('Rides: ${r['rides_count'] ?? 0}'),
              const SizedBox(height: 8),
              Text(
                'Target: ETB ${staff['sales_target'] ?? 0}',
                style: const TextStyle(fontWeight: FontWeight.w700),
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff / Sub-admins')),
      floatingActionButton: _isSuperAdmin
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add staff'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ))
              : _staff.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.group_outlined,
                                size: 48, color: AppTheme.textMuted),
                            const SizedBox(height: 12),
                            const Text('No staff yet',
                                style: TextStyle(color: AppTheme.textMuted)),
                            if (_canBootstrap) ...[
                              const SizedBox(height: 16),
                              PrimaryButton(
                                label: 'INITIALIZE STAFF PROGRAM',
                                onPressed: _bootstrapStaffProgram,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'One-time: makes you the super admin so you '
                                'can add sub-admins with limited permissions.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.textMuted),
                              ),
                            ] else ...[
                              const SizedBox(height: 8),
                              const Text(
                                'Ask the super admin to add staff members.',
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.textMuted),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _staff.length,
                        itemBuilder: (_, i) {
                          final s = _staff[i];
                          final perms = ((s['permissions'] as List?) ?? [])
                              .map((e) => e.toString())
                              .toList();
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              leading: Icon(
                                s['is_active'] == true
                                    ? Icons.badge_outlined
                                    : Icons.block_outlined,
                                color: s['is_active'] == true
                                    ? AppTheme.primaryGreen
                                    : AppTheme.error,
                              ),
                              title: Text('${s['name']}'
                                  '  ·  ${s['staff_code']}'),
                              subtitle: Text(
                                perms.isEmpty
                                    ? 'No permissions'
                                    : perms
                                        .map((p) =>
                                            _permissionOptions[p] ?? p)
                                        .join(', '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              isThreeLine: perms.length > 2,
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'edit') _openEditor(s);
                                  if (v == 'perf') _showPerformance(s);
                                  if (v == 'revoke') _revoke(s);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'perf',
                                      child: Text('Performance')),
                                  if (_isSuperAdmin && s['is_active'] == true)
                                    const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Edit')),
                                  if (_isSuperAdmin && s['is_active'] == true)
                                    const PopupMenuItem(
                                        value: 'revoke',
                                        child: Text('Revoke')),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
