import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/staff_admin_service.dart';
import '../../core/services/staff_gateway_service.dart';
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

  /// Editor submit state — rendered INSIDE the sheet. Errors must surface
  /// here: ScaffoldMessenger snackbars fire on the Scaffold BEHIND the modal
  /// bottom sheet, where the sheet hides them (the silent "nothing happens"
  /// staff-creation bug).
  String? _sheetError;
  bool _submitting = false;

  /// UX: which collapsible category groups are expanded in the editor.
  /// Kept across sheet re-openings so the CEO's choices persist.
  final Set<String> _expandedCategoryGroups = {};

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

  /// UX: permissions grouped into three purpose labels so the checklist
  /// reads as three short rows inside one collapsible section instead of a
  /// nine-item wall. Keys must all exist in _permissionOptions.
  static const _permissionGroups = <String, List<String>>{
    'Daily operations': [
      'sales_transactions',
      'registrations',
      'category_management',
    ],
    'Support & payments': [
      'support_chat',
      'payment_verification',
    ],
    'Oversight & reports': [
      'admin_history',
      'view_reports',
      'view_expenses',
      'view_auth_logs',
    ],
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
            .select('id,name,sector,parent_id')
            .eq('is_active', true)
            .order('sort_order');
        cats = List<Map<String, dynamic>>.from(catRows as List);
        // Nest subcategories visually under their parent: top-levels first
        // (by sort_order), then each parent's children right after it. The
        // editor indents child rows so the CEO sees the hierarchy at a
        // glance instead of a mixed flat list.
        int rank(Map<String, dynamic> c) {
          final parentId = c['parent_id'] as String?;
          final so = (c['sort_order'] as num?)?.toInt() ?? 0;
          if (parentId == null) return so * 1000;
          final parent =
              cats.where((p) => p['id'] == parentId).toList(growable: false);
          final parentSo = parent.isNotEmpty
              ? ((parent.first['sort_order'] as num?)?.toInt() ?? 999)
              : 999;
          return parentSo * 1000 + 500 + so;
        }

        cats.sort((a, b) => rank(a).compareTo(rank(b)));
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
    String branch =
        (existing?['branch'] as String?) ?? (isSuper ? 'ADMIN' : 'ADMIN');
    final canSetSuper = _isCeo && existing == null;
    // Fresh sheet: never show a stale error/spinner from a previous attempt.
    _sheetError = null;
    _submitting = false;

    // UX: category checklist grouped by the category's own sector so the
    // CEO expands only the vehicle or service groups that are relevant.
    final vehicleCats =
        _categories.where((c) => c['sector'] == 'VEHICLE').toList();
    final serviceCats =
        _categories.where((c) => c['sector'] == 'SERVICE').toList();
    final otherCats = _categories
        .where((c) => c['sector'] != 'VEHICLE' && c['sector'] != 'SERVICE')
        .toList();

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
                      labelText: 'Username or email *',
                      helperText: '3–32 characters; handed to staff offline',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Initial password *',
                      helperText: '10–200 characters; never shown again',
                    ),
                  ),
                  // Requirement + live counter so a too-short password is
                  // caught on the form, not as a server error after submit.
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      'Minimum 10 characters'
                      '${passwordController.text.isEmpty ? '' : ' — ${passwordController.text.length}/200'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: passwordController.text.isEmpty ||
                                passwordController.text.length >=
                                    kStaffPasswordMinLength
                            ? AppTheme.textMuted
                            : AppTheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Confirm password *',
                      errorText: confirmPasswordController.text.isEmpty ||
                              confirmPasswordController.text ==
                                  passwordController.text
                          ? null
                          : 'Passwords do not match',
                    ),
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
                        icon: Icon(Icons.admin_panel_settings_outlined,
                            size: 16)),
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
                // UX: grouped collapsible sections replace the long flat
                // checklists — the CEO expands only what is relevant, and
                // each header shows how many options are selected.
                _CollapsibleSection(
                  icon: Icons.verified_user_outlined,
                  title: 'Permissions',
                  subtitle: 'What this staff member can do across the app.',
                  countLabel: '${selected.length}/${_permissionOptions.length}',
                  initiallyExpanded: true,
                  trailing: [_AllNoneButtons(
                    onAll: () => setSheetState(() {
                      for (final key in _permissionOptions.keys) {
                        if (!selected.contains(key)) selected.add(key);
                      }
                    }),
                    onNone: () => setSheetState(() {
                      selected.removeWhere(_permissionOptions.containsKey);
                    }),
                  )],
                  children: [
                    for (final group in _permissionGroups.entries) ...[
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 16, top: 6, bottom: 2),
                        child: Text(
                          group.key.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: AppTheme.teal,
                          ),
                        ),
                      ),
                      ...group.value.map(
                        (key) => CheckboxListTile(
                          dense: true,
                          title: Text(_permissionOptions[key]!,
                              style: const TextStyle(fontSize: 13)),
                          value: selected.contains(key),
                          onChanged: (on) => setSheetState(() {
                            on == true
                                ? selected.add(key)
                                : selected.remove(key);
                          }),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Assigned categories',
                    style: AppTheme.sectionHeader),
                const SizedBox(height: 4),
                Text(
                  'Empty = unrestricted. Sub-admins only act inside their '
                  'categories. Expand a group to choose.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 4),
                _categorySection(
                  sheetSet: setSheetState,
                  selectedCats: selectedCats,
                  title: 'Vehicle categories',
                  icon: Icons.directions_car_outlined,
                  cats: vehicleCats,
                ),
                _categorySection(
                  sheetSet: setSheetState,
                  selectedCats: selectedCats,
                  title: 'Service categories',
                  icon: Icons.room_service_outlined,
                  cats: serviceCats,
                ),
                if (otherCats.isNotEmpty)
                  _categorySection(
                    sheetSet: setSheetState,
                    selectedCats: selectedCats,
                    title: 'Other categories',
                    icon: Icons.category_outlined,
                    cats: otherCats,
                  ),
                if (canSetSuper) ...[
                  const SizedBox(height: 8),
                  _CollapsibleSection(
                    icon: Icons.shield_outlined,
                    title: 'Admin roles',
                    subtitle: 'Special roles above the permission system.',
                    countLabel: isSuper ? 'Super admin' : 'None',
                    initiallyExpanded: isSuper,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        title: const Text('Super admin (runs the staff program)',
                            style: TextStyle(fontSize: 13)),
                        subtitle: const Text(
                            'ADMIN branch only; created by the CEO',
                            style: TextStyle(fontSize: 11)),
                        value: isSuper,
                        onChanged: (on) => setSheetState(() {
                          isSuper = on ?? false;
                          if (isSuper) branch = 'ADMIN';
                        }),
                      ),
                    ],
                  ),
                ],
                // In-sheet error banner — see _showSheetError. Without this
                // the operator sees nothing at all when submit fails.
                if (_sheetError != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.08),
                      border:
                          Border.all(color: AppTheme.error.withValues(alpha: 0.4)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            color: AppTheme.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sheetError!,
                            style: const TextStyle(
                                fontSize: 12.5, color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 16),
                PrimaryButton(
                  label: existing == null ? 'Create staff' : 'Save changes',
                  isLoading: _submitting,
                  onPressed: () async {
                    setSheetState(() => _sheetError = null);
                    if (nameController.text.trim().isEmpty ||
                        codeController.text.trim().isEmpty) {
                      _showSheetError(
                          setSheetState, 'Name and staff ID are required');
                      return;
                    }
                    // Pre-submit validation mirrors staff-create-gateway so
                    // the operator never sees a raw server exception.
                    if (existing == null && _isCeo) {
                      final password = passwordController.text;
                      if (password.length < kStaffPasswordMinLength ||
                          password.length > kStaffPasswordMaxLength) {
                        _showSheetError(setSheetState,
                            'Password must be 10–200 characters.');
                        return;
                      }
                      if (password != confirmPasswordController.text) {
                        _showSheetError(
                            setSheetState, 'The passwords do not match.');
                        return;
                      }
                      final username =
                          usernameController.text.trim().toLowerCase();
                      if (!isValidStaffUsername(username)) {
                        _showSheetError(setSheetState, kStaffUsernameHint);
                        return;
                      }
                      final staffCodeValue = codeController.text.trim();
                      if (staffCodeValue.length < 2 ||
                          staffCodeValue.length > 60 ||
                          nameController.text.trim().length < 2 ||
                          nameController.text.trim().length > 100) {
                        _showSheetError(
                            setSheetState,
                            'Name must be 2–100 characters and staff ID '
                            '2–60 characters.');
                        return;
                      }
                      final salesTargetValue =
                          double.tryParse(targetController.text) ?? 0;
                      if (salesTargetValue < 0) {
                        _showSheetError(setSheetState,
                            'Sales target must be zero or a positive number.');
                        return;
                      }
                    }
                    setSheetState(() => _submitting = true);
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
                          salesTarget:
                              double.tryParse(targetController.text) ?? 0,
                          isSuperAdmin: isSuper,
                          branch: isSuper ? 'ADMIN' : branch,
                          assignedCategories: selectedCats,
                        ).timeout(
                          const Duration(seconds: 25),
                          onTimeout: () => throw Exception(
                              'The request timed out. Check your connection '
                              'and try again.'),
                        );
                      } else if (existing == null) {
                        await client.rpc('create_staff', params: {
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
                      if (sheetContext.mounted)
                        Navigator.pop(sheetContext, true);
                    } catch (e) {
                      if (sheetContext.mounted) {
                        _showSheetError(
                          setSheetState,
                          e
                              .toString()
                              .replaceFirst('PostgrestException(', '')
                              .replaceFirst('Exception: ', ''),
                        );
                      }
                    } finally {
                      if (sheetContext.mounted) {
                        setSheetState(() => _submitting = false);
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

  /// Surface a failure INSIDE the editor sheet. A snackbar via
  /// ScaffoldMessenger renders on the Scaffold behind the modal bottom sheet
  /// and is invisible to the operator — which is exactly the silent "Create
  /// staff does nothing" bug. All editor feedback goes through this.
  void _showSheetError(
      void Function(void Function()) setSheetState, String message) {
    setSheetState(() {
      _sheetError = message;
      _submitting = false;
    });
  }

  /// One collapsible category group inside the editor (vehicle / service /
  /// other). The header always shows the selected count so the CEO can see
  /// state without expanding; the section reuses _CollapsibleSection.
  Widget _categorySection({
    required void Function(void Function()) sheetSet,
    required List<String> selectedCats,
    required String title,
    required IconData icon,
    required List<Map<String, dynamic>> cats,
  }) {
    final selectedInGroup =
        cats.where((c) => selectedCats.contains(c['id'])).length;
    return _CollapsibleSection(
      icon: icon,
      title: title,
      subtitle: cats.isEmpty
          ? 'No categories available in this group.'
          : '${cats.length} categories · subcategories indented.',
      countLabel: '$selectedInGroup/${cats.length}',
      initiallyExpanded: _expandedCategoryGroups.contains(title),
      onExpansionChanged: (expanded) =>
          expanded ? _expandedCategoryGroups.add(title) : _expandedCategoryGroups.remove(title),
      children: [
        for (final c in cats)
          CheckboxListTile(
            dense: true,
            contentPadding: c['parent_id'] != null
                ? const EdgeInsets.only(left: 28, right: 4)
                : const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              '${c['name']}',
              style: TextStyle(
                fontSize: c['parent_id'] != null ? 12 : 13,
                fontWeight: c['parent_id'] != null
                    ? FontWeight.w400
                    : FontWeight.w600,
              ),
            ),
            value: selectedCats.contains(c['id']),
            onChanged: (on) => sheetSet(() {
              on == true
                  ? selectedCats.add(c['id'] as String)
                  : selectedCats.remove(c['id']);
            }),
          ),
      ],
    );
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

  /// Permanently remove a staff member.
  ///
  /// Behind a TYPED confirmation, not just a yes/no dialog: this destroys the
  /// auth account, so the username is freed for reuse and the history cannot
  /// be restored. Revoking (the menu item above) remains the default, safer
  /// action for "this person should not have access any more".
  Future<void> _deletePermanently(Map<String, dynamic> staff) async {
    final name = '${staff['name']}';
    final staffId = '${staff['id']}';

    final typed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => TypedConfirmDialog(
        title: 'Delete $name permanently?',
        body: 'This removes their staff entry AND their login account. '
            'It cannot be undone, and their username becomes available again.\n\n'
            'To remove access without deleting, use Revoke instead.',
        confirmWord: 'DELETE',
        actionLabel: 'Delete forever',
      ),
    );
    if (typed != 'DELETE' || !mounted) return;

    try {
      await const StaffGatewayService().deletePermanently(staffId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name deleted')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
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
              Text(
                  '30-day completed: ${progress['completed_last_30_days'] ?? 0}'),
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
                          final cats =
                              ((s['assigned_categories'] as List?) ?? [])
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
                              // Tapping the row opens the editor. The ⋮ menu
                              // already had an Edit item, but burying the only
                              // way to change someone's roles behind a
                              // three-dot menu is why "I can create staff but
                              // not manage them" reads as a missing feature.
                              onTap: _canManage(s) ? () => _openEditor(s) : null,
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
                                  if (v == 'delete') _deletePermanently(s);
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
                                        value: 'edit', child: Text('Edit')),
                                  if (_canManage(s))
                                    const PopupMenuItem(
                                        value: 'revoke', child: Text('Revoke')),
                                  // Never offered for the CEO row: the server
                                  // refuses it too, but hiding an action that
                                  // would always fail is better UX.
                                  if (_canManage(s) && s['is_ceo'] != true)
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete permanently',
                                          style: TextStyle(
                                              color: AppTheme.error)),
                                    ),
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

/// A confirmation the user has to finish by typing [confirmWord].
///
/// Public (rather than private to this file) so the overflow regression test
/// can drive the real widget. A test against a copy of the layout would not
/// catch the layout regressing.

///
/// Used for irreversible actions where a stray tap must not be enough. The
/// dialog pops with the typed word, so the caller can compare it against what
/// it expects — a cancelled dialog returns null.
class TypedConfirmDialog extends StatefulWidget {
  const TypedConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmWord,
    required this.actionLabel,
  });

  final String title;
  final String body;
  final String confirmWord;
  final String actionLabel;

  @override
  State<TypedConfirmDialog> createState() => TypedConfirmDialogState();
}

class TypedConfirmDialogState extends State<TypedConfirmDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _controller.text.trim().toUpperCase() == widget.confirmWord;
    return AlertDialog(
      // `scrollable: true` makes the DIALOG ITSELF scroll its content.
      // `isScrollControlled: true` at the showDialog call site is not enough
      // on its own: it only relaxes the height cap, and the title plus a
      // paragraph plus a TextField still exceeded it at a 1.8–2.0 text scale
      // ("BOTTOM OVERFLOWED BY 31 PIXELS", then by 101 and 216). Making it a
      // property of the widget rather than of the call site means no caller
      // can forget it.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body,
              style: const TextStyle(
                  fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Type ${widget.confirmWord} to confirm',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled until the word matches, so the destructive action is
          // never one stray tap away.
          onPressed: ready ? () => Navigator.pop(context, _controller.text.trim().toUpperCase()) : null,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// UX: a single collapsible card used by the staff editor. The header row
/// (icon + title + selected-count chip + chevron) toggles the body, so long
/// checklists stay collapsed until the CEO expands the group they need.
class _CollapsibleSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Selection summary shown in a small chip on the header (e.g. "2/9").
  final String? countLabel;

  /// Header-right action buttons (e.g. All / None). Rendered before the
  /// chevron; keep them compact.
  final List<Widget> trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    this.subtitle,
    this.countLabel,
    this.trailing = const [],
    required this.children,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Remove the default divider so stacked sections read as one group.
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(
            expansionTileTheme: Theme.of(context).expansionTileTheme.copyWith(
                  backgroundColor: Theme.of(context).cardColor,
                  collapsedBackgroundColor: Theme.of(context).cardColor,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  collapsedShape:
                      const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                ),
          ),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            onExpansionChanged: onExpansionChanged,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            childrenPadding:
                const EdgeInsets.only(left: 8, right: 8, bottom: 8),
            leading: Icon(icon, color: AppTheme.teal, size: 22),
            title: Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle!,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...trailing,
                if (countLabel != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      countLabel!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryGreen,
                      ),
                    ),
                  ),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Header-right All / None shortcuts for the permissions section.
class _AllNoneButtons extends StatelessWidget {
  final VoidCallback onAll;
  final VoidCallback onNone;
  const _AllNoneButtons({required this.onAll, required this.onNone});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      TextButton(
        onPressed: onAll,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        child: const Text('All'),
      ),
      TextButton(
        onPressed: onNone,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        child: const Text('None'),
      ),
    ]);
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
      await Supabase.instance.client
          .rpc('admin_set_referral_code_active', params: {
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
                  style: const TextStyle(color: AppTheme.error, fontSize: 12))
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
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
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
