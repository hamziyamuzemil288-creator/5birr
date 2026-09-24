import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/staff_admin_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';

/// Staff / role-hierarchy management.
///
/// Hierarchy (enforced server-side by the staff RPCs — hiding UI here is
/// convenience, not the security boundary):
///   CEO            top of both branches; only the CEO creates super admins
///   Super Admin    ADMIN branch; monitors sub-admins, sees reports/expenses
///   Me (owner)     ME branch; jointly controls sub-admins with Super Admin
///   Sub-Admin      categorized; explicit permission list ∩ categories
class AdminStaffScreen extends ConsumerStatefulWidget {
  const AdminStaffScreen({super.key});

  @override
  ConsumerState<AdminStaffScreen> createState() => _AdminStaffScreenState();
}

class _AdminStaffScreenState extends ConsumerState<AdminStaffScreen> {
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _categories = [];
  bool _loading = true;
  String? _error;
  bool _isSuperAdmin = false;
  bool _isCeo = false;

  /// Permission vocabulary. The three `view_*` entries are the
  /// reports / expenses / auth-log visibility the hierarchy spec adds;
  /// action permissions stay as before.
  static const _permissionOptions = {
    'sales_transactions': 'Sales & transactions',
    'registrations': 'Registrations',
    'category_management': 'Category management',
    'support_chat': 'Support / chat',
    'payment_verification': 'Payment verification',
    'admin_history': 'View admin history',
    'view_reports': 'View reports',
    'view_expenses': 'View expenses',
    'view_auth_logs': 'View auth logs',
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
      // Identity via the server helpers: is_ceo() covers the true Admin
      // (the Supabase-registered owner account, which never has a staff
      // row) and is_super_admin() the active Super Admin staff row.
      if (client.auth.currentUser != null) {
        try {
          _isCeo = await client.rpc('is_ceo') == true;
        } catch (_) {
          _isCeo = false;
        }
        try {
          _isSuperAdmin = await client.rpc('is_super_admin') == true;
        } catch (_) {
          _isSuperAdmin = false;
        }
      }
      final rows = await client.from('staff').select().order('created_at');
      final staff = List<Map<String, dynamic>>.from(rows as List);
      // Vehicle categories for sub-admin scope assignment.
      List<Map<String, dynamic>> cats = [];
      try {
        final catRows = await client
            .from('categories')
            .select('id,name,sector')
            .eq('is_active', true)
            .order('sort_order');
        cats = List<Map<String, dynamic>>.from(catRows as List);
      } catch (_) {
        // Category listing is optional for the editor; staff ops continue.
      }
      if (!mounted) return;
      setState(() {
        _staff = staff;
        _categories = cats;
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

  String _branchLabel(Map<String, dynamic> s) {
    if (s['is_ceo'] == true) return 'CEO';
    final branch = (s['branch'] as String?) ?? 'ADMIN';
    if (s['is_super_admin'] == true) return 'Super Admin';
    return branch == 'ME' ? 'Owner team' : 'Admin team';
  }

  IconData _branchIcon(Map<String, dynamic> s) {
    if (s['is_ceo'] == true) return Icons.workspace_premium_outlined;
    if (s['is_super_admin'] == true) return Icons.shield_outlined;
    return ((s['branch'] as String?) ?? 'ADMIN') == 'ME'
        ? Icons.badge_outlined
        : Icons.support_agent_outlined;
  }

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    final nameController =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final codeController =
        TextEditingController(text: existing?['staff_code'] as String? ?? '');
    final targetController = TextEditingController(
        text: existing?['sales_target']?.toString() ?? '0');
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final selected = ((existing?['permissions'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    final selectedCats = ((existing?['assigned_categories'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    bool isSuper = (existing?['is_super_admin'] as bool?) ?? false;
    // Super Admin rows always live in the ADMIN branch; new entries default
    // to the ADMIN branch, matching the pre-hierarchy behavior.
    String branch = (existing?['branch'] as String?) ??
        (isSuper ? 'ADMIN' : 'ADMIN');
    final canSetSuper = _isCeo && existing == null;

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
          child: SingleChildScrollView(
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
                if (existing == null && _isCeo) ...[
                  const SizedBox(height: 4),
                  const Text('Gateway credentials (CEO only)',
                      style: AppTheme.sectionHeader),
                  const SizedBox(height: 8),
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username *',
                      helperText: '3–32 characters; handed to staff offline',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Initial password *',
                      helperText: 'At least 10 characters; never shown again',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm password *'),
                  ),
                  const SizedBox(height: 12),
                ],
                const Text('Branch', style: AppTheme.sectionHeader),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'ADMIN',
                        label: Text('Admin'),
                        icon: Icon(Icons.admin_panel_settings_outlined, size: 16)),
                    ButtonSegment(
                        value: 'ME',
                        label: Text('Me'),
                        icon: Icon(Icons.badge_outlined, size: 16)),
                  ],
                  selected: {branch},
                  onSelectionChanged: canSetSuper || existing == null
                      ? (sel) => setSheetState(() => branch = sel.first)
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sub-admins in "Me" are jointly managed by you and the '
                  'super admin. Sub-admins in "Admin" report to the super '
                  'admin.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
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
                const SizedBox(height: 8),
                const Text('Assigned categories', style: AppTheme.sectionHeader),
                const SizedBox(height: 4),
                Text(
                  'Empty = unrestricted. Sub-admins only act inside their '
                  'categories.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                ..._categories.map(
                  (c) => CheckboxListTile(
                    dense: true,
                    title: Text('${c['name']}',
                        style: const TextStyle(fontSize: 13)),
                    subtitle: Text('${c['sector']}',
                        style: const TextStyle(fontSize: 10)),
                    value: selectedCats.contains(c['id']),
                    onChanged: (on) => setSheetState(() {
                      on == true
                          ? selectedCats.add(c['id'] as String)
                          : selectedCats.remove(c['id']);
                    }),
                  ),
                ),
                if (canSetSuper)
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Super admin (runs the staff program)',
                        style: TextStyle(fontSize: 13)),
                    subtitle: const Text('ADMIN branch only; created by the CEO',
                        style: TextStyle(fontSize: 11)),
                    value: isSuper,
                    onChanged: (on) => setSheetState(() {
                      isSuper = on ?? false;
                      if (isSuper) branch = 'ADMIN';
                    }),
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
                      if (existing == null && _isCeo) {
                        const service = StaffAdminService();
                        await service.createGateway(
                          name: nameController.text.trim(),
                          staffCode: codeController.text.trim(),
                          username: usernameController.text,
                          password: passwordController.text,
                          confirmPassword: confirmPasswordController.text,
                          permissions: selected,
                          salesTarget: double.tryParse(targetController.text) ?? 0,
                          isSuperAdmin: isSuper,
                          branch: isSuper ? 'ADMIN' : branch,
                          assignedCategories: selectedCats,
                        );
                      } else if (existing == null) {
                        await client.rpc('create_staff',
                            params: {
                              'p_name': nameController.text.trim(),
                              'p_staff_code': codeController.text.trim(),
                              'p_permissions': selected,
                              'p_sales_target':
                                  double.tryParse(targetController.text) ?? 0,
                              'p_is_super_admin': isSuper,
                              'p_branch': isSuper ? 'ADMIN' : branch,
                              'p_assigned_categories': selectedCats,
                            }) as Map<String, dynamic>;
                      } else {
                        await client.rpc('update_staff', params: {
                          'p_staff_id': existing['id'],
                          'p_name': nameController.text.trim(),
                          'p_permissions': selected,
                          'p_sales_target':
                              double.tryParse(targetController.text) ?? 0,
                          'p_assigned_categories': selectedCats,
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
      ),
    );
    if (result == true) _load();
  }

  /// Attach a staff record to a real account by email — the linked user
  /// then signs in and reaches the admin panel with the row's permissions.
  Future<void> _linkAccount(Map<String, dynamic> staff) async {
    final emailController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Link ${staff['name']} to an account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Enter the email of the account this staff member will sign '
                'in with. They must already be registered.'),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email *'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Link')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final email = emailController.text.trim();
    if (email.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('link_staff_user', params: {
        'p_staff_id': staff['id'],
        'p_email': email,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$email can now sign in as staff')));
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
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
      final client = Supabase.instance.client;
      final rows = await client
          .rpc('staff_performance', params: {'p_staff_id': staff['id']});
      final r = (rows as List).isNotEmpty
          ? rows.first as Map<String, dynamic>
          : <String, dynamic>{};
      final progressRows = await client.rpc(
        'staff_progress',
        params: {'p_staff_id': staff['id']},
      );
      final progress = (progressRows as List).isNotEmpty
          ? Map<String, dynamic>.from(progressRows.first as Map)
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
              Text('Completed tasks: ${progress['completed_tasks'] ?? 0}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('Remaining tasks: ${progress['remaining_tasks'] ?? 0}'),
              Text('Task progress: ${progress['progress_percent'] ?? 0}%'),
              Text('30-day completed: ${progress['completed_last_30_days'] ?? 0}'),
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

  /// Only the CEO / Super Admin / owner may edit or revoke; the server
  /// enforces the same matrix via can_manage_staff.
  bool _canManage(Map<String, dynamic> s) {
    if (!_isCeo && !_isSuperAdmin) return false;
    if (s['is_ceo'] == true) return _isCeo; // only the CEO manages the CEO row
    return s['is_active'] == true;
  }

  // ── Task 8: referral-code manager ────────────────────────────────────────
  // Codes are issued per staff person (this screen); a person may hold
  // several. Each provider signup that uses a code records the person's
  // id + name on the provider row (see referral_tracking migration).
  Future<void> _showReferralCodes(Map<String, dynamic> staff) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ReferralCodesSheet(staff: staff),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Roles & Staff')),
      floatingActionButton: (_isCeo || _isSuperAdmin)
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
                            const SizedBox(height: 8),
                            const Text(
                              'Ask the CEO or super admin to add staff members.',
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textMuted),
                            ),
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
                          final cats = ((s['assigned_categories'] as List?) ?? [])
                              .map((e) => e.toString())
                              .toList();
                          final catNames = cats
                              .map((id) => _categories
                                  .where((c) => c['id'] == id)
                                  .map((c) => c['name'])
                                  .join(', '))
                              .where((n) => n.isNotEmpty)
                              .join(', ');
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              leading: Icon(
                                s['is_active'] == true
                                    ? _branchIcon(s)
                                    : Icons.block_outlined,
                                color: s['is_active'] == true
                                    ? AppTheme.primaryGreen
                                    : AppTheme.error,
                              ),
                              title: Text('${s['name']}'
                                  '  ·  ${s['staff_code']}'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_branchLabel(s),
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.teal)),
                                  Text(
                                    perms.isEmpty
                                        ? 'No permissions'
                                        : perms
                                            .map((p) =>
                                                _permissionOptions[p] ?? p)
                                            .join(', '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (catNames.isNotEmpty)
                                    Text('Categories: $catNames',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11)),
                                ],
                              ),
                              isThreeLine: true,
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'edit') _openEditor(s);
                                  if (v == 'perf') _showPerformance(s);
                                  if (v == 'referrals') _showReferralCodes(s);
                                  if (v == 'revoke') _revoke(s);
                                  if (v == 'link') _linkAccount(s);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'perf',
                                      child: Text('Performance')),
                                  const PopupMenuItem(
                                      value: 'referrals',
                                      child: Text('Referral codes')),
                                  if (_canManage(s) && s['user_id'] == null)
                                    const PopupMenuItem(
                                        value: 'link',
                                        child: Text('Link account')),
                                  if (_canManage(s))
                                    const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Edit')),
                                  if (_canManage(s))
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

/// Task 8: per-staff referral-code sheet — lists the person's codes with
/// usage counts, issues new ones, and toggles active state. Deletion is
/// omitted from the sheet (registrations keep the denormalized name, but an
/// accidental delete would orphan future lookups); use deactivate instead.
class _ReferralCodesSheet extends StatefulWidget {
  final Map<String, dynamic> staff;
  const _ReferralCodesSheet({required this.staff});
  @override
  State<_ReferralCodesSheet> createState() => _ReferralCodesSheetState();
}

class _ReferralCodesSheetState extends State<_ReferralCodesSheet> {
  List<Map<String, dynamic>> _codes = [];
  bool _loading = true;
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
      final rows = await Supabase.instance.client.rpc('admin_referral_codes');
      _codes = (rows as List)
          .whereType<Map<String, dynamic>>()
          .where((r) => r['staff_id'] == widget.staff['id'])
          .toList();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _issue() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('New code for ${widget.staff['name']}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Code',
            hintText: 'letters, digits, . _ - only',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Issue')),
        ],
      ),
    );
    if (ok != true) return;
    final code = controller.text.trim();
    if (code.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('admin_issue_referral_code', params: {
        'p_staff_id': widget.staff['id'],
        'p_code': code,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  Future<void> _toggle(Map<String, dynamic> code) async {
    try {
      await Supabase.instance.client.rpc('admin_set_referral_code_active',
          params: {
            'p_code_id': code['id'],
            'p_active': !(code['is_active'] == true),
          });
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Referral codes — ${widget.staff['name']} '
                    '(${widget.staff['staff_code']})',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Providers who sign up with a code are attributed to '
              '${widget.staff['name']} in Registration History.',
              style: AppTheme.caption,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(
                      color: AppTheme.error, fontSize: 12))
            else if (_codes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No codes issued yet.',
                    style: TextStyle(color: AppTheme.textMuted)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _codes.length,
                  itemBuilder: (_, i) {
                    final c = _codes[i];
                    final active = c['is_active'] == true;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text('${c['code']}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          'used ${c['uses'] ?? 0} · ${active ? 'active' : 'inactive'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Switch(
                          value: active,
                          onChanged: (_) => _toggle(c),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _issue,
                icon: const Icon(Icons.add),
                label: const Text('Issue new code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
