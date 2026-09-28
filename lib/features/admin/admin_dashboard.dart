import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';

class AdminDashboard extends ConsumerStatefulWidget {
  const AdminDashboard({super.key});
  @override
  ConsumerState<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends ConsumerState<AdminDashboard> {
  int _pendingProviders = 0;
  int _pendingUsers = 0;
  int _pendingRecharges = 0;
  int _totalProviders = 0;
  int _totalUsers = 0;
  int _totalProducts = 0;
  int _totalOrders = 0;
  int _openAppeals = 0;
  int _openDisputes = 0;
  int _pendingOrderPayments = 0;
  double _totalIncome = 0;
  // my_admin_permissions() returns ['*'] for the true Admin/CEO — i.e. every
  // card visible — and the explicit list for staff, who then see only their
  // permitted sections. Server-side RLS remains the real boundary.
  Set<String> _myPerms = const {'*'};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final client = Supabase.instance.client;

    // Each metric is loaded independently: one failing query must never
    // abort the whole load (previously a single bad query zeroed every
    // counter and silently hid pending approvals from the admin).
    Future<int> count(Future<dynamic> Function() query) async {
      try {
        final res = await query();
        return (res as dynamic).count as int? ?? 0;
      } catch (_) {
        return 0;
      }
    }

    final results = await Future.wait<int>([
      count(() => client.from('provider_profiles').select('id').eq('status', 'PENDING_APPROVAL').count(CountOption.exact)),
      count(() => client.from('profiles').select('id').eq('status', 'PENDING_APPROVAL').count(CountOption.exact)),
      count(() => client.from('wallet_recharge_requests').select('id').eq('status', 'PENDING').count(CountOption.exact)),
      count(() => client.from('provider_profiles').select('id').count(CountOption.exact)),
      count(() => client.from('profiles').select('id').count(CountOption.exact)),
      count(() => client.from('products').select('id').count(CountOption.exact)),
      count(() => client.from('orders').select('id').inFilter('status', ['APPROVED', 'STARTED', 'COMPLETED']).count(CountOption.exact)),
      count(() => client.from('appeal_cases').select('id').eq('status', 'OPEN').count(CountOption.exact)),
      // Open order disputes. These are NOT appeal_cases: only an admin can
      // move an order out of DISPUTED, so without a count here an open
      // dispute is invisible from the dashboard entirely.
      count(() => client.from('orders').select('id').eq('status', 'DISPUTED').count(CountOption.exact)),
      // Orders whose payment the buyer submitted and is waiting on an admin.
      // Only an admin can move an order out of PAYMENT_VERIFICATION, so
      // without this count a customer who has already paid is invisible and
      // the provider never gets the release.
      count(() => client
          .from('orders')
          .select('id')
          .eq('status', 'PAYMENT_VERIFICATION')
          .count(CountOption.exact)),
    ]);

    // Section visibility for the signed-in principal (fail-open to '*' is
    // impossible: my_admin_permissions returns [] for no perms — a genuine
    // restriction — so a thrown call simply leaves the default).

    // Platform income = fees actually charged: per-transaction fees plus
    // subscription fees from the wallet ledger (orders table has no fee
    // column, and subscriptions hold schedule rows, not charges).
    double income = 0;
    try {
      final feeRows = await client
          .from('wallet_transactions')
          .select('platform_fee')
          .inFilter('transaction_type', ['TRANSACTION_FEE', 'SUBSCRIPTION_FEE'])
          .limit(1000);
      for (final t in feeRows as List) {
        income += (t['platform_fee'] as num?)?.toDouble() ?? 0;
      }
    } catch (_) {}

    // Permission fetch is independent of the counts (a failure must never
    // blank the dashboard; worst case the full list shows while RLS still
    // guards every screen).
    try {
      final perms = await client.rpc('my_admin_permissions');
      final list = ((perms as List?) ?? const [])
          .map((e) => e.toString())
          .toList();
      if (mounted) setState(() => _myPerms = list.toSet());
    } catch (_) {}

    if (mounted) {
      setState(() {
        _pendingProviders = results[0];
        _pendingUsers = results[1];
        _pendingRecharges = results[2];
        _totalProviders = results[3];
        _totalUsers = results[4];
        _totalProducts = results[5];
        _totalOrders = results[6];
        _openAppeals = results[7];
        _openDisputes = results[8];
        _pendingOrderPayments = results[9];
        _totalIncome = income;
        _loading = false;
      });
    }
  }

  /// Card visibility per the signed-in principal's permissions.
  bool _can(String perm) =>
      _myPerms.contains('*') || _myPerms.contains(perm);

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final hasPending = _pendingProviders > 0 || _pendingUsers > 0 || _pendingRecharges > 0;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Aliob Admin',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        elevation: 0,
        actions: [
          // The way into the CEO workspace. Rendered only for a CEO account,
          // because for anyone else the destination explains it is CEO-only
          // and offering it would be a dead end. The real check is server-side
          // in is_ceo(); this only decides whether to show the door.
          if (ref.watch(authProvider).isCeo)
            IconButton(
              tooltip: 'CEO workspace',
              icon: const Icon(Icons.workspace_premium),
              onPressed: () => context.push('/ceo'),
            ),
          if (hasPending)
            Badge(
              label: Text('${_pendingProviders + _pendingUsers + _pendingRecharges}',
                  style: const TextStyle(fontSize: 10, color: Colors.white)),
              backgroundColor: AppTheme.error,
              child: IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () {},
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              child: CustomScrollView(
                slivers: [
                  // Header with gradient
                  SliverToBoxAdapter(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [AppTheme.primaryGreenDark, Color(0xFF071F0A)],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.admin_panel_settings, color: Colors.white, size: 24),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Welcome back!',
                                        style: TextStyle(fontSize: 13, color: Colors.white70)),
                                    Text('Aliob Dashboard',
                                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          // Income highlight
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white.withOpacity(0.1)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.account_balance_wallet, color: AppTheme.gold, size: 22),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Total Income', style: TextStyle(fontSize: 11, color: Colors.white60)),
                                    Text('ETB ${_totalIncome.toStringAsFixed(2)}',
                                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white)),
                                  ],
                                ),
                                const Spacer(),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text('$_totalOrders orders',
                                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                    Text('$_totalProducts products',
                                        style: const TextStyle(fontSize: 11, color: Colors.white54)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Quick stats
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                      child: Row(
                        children: [
                          _quickStat(Icons.pending_actions, 'Pending', '$_pendingProviders', AppTheme.warning),
                          const SizedBox(width: 8),
                          _quickStat(Icons.people, 'Users', '$_totalUsers', AppTheme.info),
                          const SizedBox(width: 8),
                          _quickStat(Icons.storefront, 'Providers', '$_totalProviders', AppTheme.primaryGreen),
                          const SizedBox(width: 8),
                          _quickStat(Icons.receipt, 'Orders', '$_totalOrders', AppTheme.teal),
                        ],
                      ),
                    ),
                  ),

                  // Approvals (if any pending)
                  if (hasPending) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: Row(
                          children: [
                            Container(width: 3, height: 16,
                                decoration: BoxDecoration(color: AppTheme.warning, borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            const Text('Requires Attention',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            if (_pendingProviders > 0)
                              _pendingCard(Icons.approval, 'Provider Approvals',
                                  '$_pendingProviders pending', AppTheme.warning, () => context.push('/admin/approvals')),
                            if (_pendingUsers > 0)
                              _pendingCard(Icons.person_add, 'User Approvals',
                                  '$_pendingUsers pending', AppTheme.teal, () => context.push('/admin/users')),
                            if (_pendingRecharges > 0)
                              _pendingCard(Icons.payment, 'Recharge Requests',
                                  '$_pendingRecharges pending', AppTheme.info, () => context.push('/admin/payments')),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // Operations section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.primaryGreen, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Operations',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          if (_can('registrations'))
                            _menuCard(Icons.person_add, 'User Approvals', '$_pendingUsers pending', () => context.push('/admin/users')),
                          if (_can('registrations'))
                            _menuCard(Icons.approval, 'Provider Approvals', '$_pendingProviders pending', () => context.push('/admin/approvals')),
                          if (_can('registrations'))
                            _menuCard(Icons.storefront_outlined, 'All Providers', '$_totalProviders total', () => context.push('/admin/providers')),
                          if (_can('payment_verification'))
                            _menuCard(Icons.payment, 'Payment Verification', null, () => context.push('/admin/payments')),
                          if (_can('payment_verification'))
                            _menuCard(Icons.account_balance_wallet_outlined, 'Payment Methods', null, () => context.push('/admin/payment-methods')),
                        ],
                      ),
                    ),
                  ),

                  // Financial section
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Financial',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        children: [
                          if (_can('sales_transactions'))
                            _menuCard(Icons.receipt_long, 'Transaction History', '1% fees & orders', () => context.push('/admin/transactions')),
                          if (_can('view_reports'))
                            _menuCard(Icons.account_balance_wallet, 'Income Summary', 'ETB ${_totalIncome.toStringAsFixed(0)} total', () => context.push('/admin/income')),
                          if (_can('view_expenses'))
                            _menuCard(Icons.receipt, 'Expenses', 'Log & track', () => context.push('/admin/expenses')),
                          if (_can('view_reports'))
                            _menuCard(Icons.analytics_outlined, 'Sector Reports', 'Per-category data', () => context.push('/admin/reports')),
                        ],
                      ),
                    ),
                  ),

                  // Data & Communications
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                      child: Row(
                        children: [
                          Container(width: 3, height: 16,
                              decoration: BoxDecoration(color: AppTheme.teal, borderRadius: BorderRadius.circular(2))),
                          const SizedBox(width: 8),
                          const Text('Data & Communications',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                      child: Column(
                        children: [
                          if (_can('registrations'))
                            _menuCard(Icons.badge_outlined, 'Registration History', 'Buyers & sellers', () => context.push('/admin/registrations')),
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.notifications_outlined, 'Send Notifications', 'To users or broadcast', () => context.push('/admin/send-notifications')),
                          if (_can('support_chat'))
                            _menuCard(Icons.support_agent, 'Support Tickets', 'From the in-app help chat', () => context.push('/admin/support-tickets')),
                          if (_can('*') || _can('account_deletion'))
                            _menuCard(Icons.person_remove_outlined, 'Account Deletions',
                                'Deletion requests',
                                () => context.push('/admin/deletions')),
                          if (_can('support_chat'))
                            _menuCard(Icons.gavel_outlined, 'Appeals',
                                _openAppeals > 0
                                    ? '$_openAppeals open case${_openAppeals == 1 ? '' : 's'}'
                                    : 'User appeals & reports',
                                () => context.push('/admin/appeals')),
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.report_gmailerrorred_outlined, 'Disputes',
                                _openDisputes > 0
                                    ? '$_openDisputes open dispute${_openDisputes == 1 ? '' : 's'}'
                                    : 'Refund or uphold',
                                () => context.push('/admin/disputes')),
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.receipt_long_outlined, 'Order Payments',
                                _pendingOrderPayments > 0
                                    ? '$_pendingOrderPayments waiting to verify'
                                    : 'Verify customer payments',
                                () => context.push('/admin/order-payments')),
                          if (_can('admin_history'))
                            _menuCard(Icons.history_edu_outlined, 'Admin History', 'Full audit trail', () => context.push('/admin/history')),
                          // Phase 2: staff management (server-side RBAC; the
                          // screen itself also self-hides without permission).
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.group_outlined, 'Staff / Sub-admins', 'Permissions & targets', () => context.push('/admin/staff')),
                          // Task 3: true-Admin-only assignment console.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.admin_panel_settings_outlined, 'Staff Assignment',
                                'Roles, city, warnings, deletion', () => context.push('/admin/staff-assignment')),
                          if (_can('*') || _can('admin_history'))
                            _menuCard(Icons.tune, 'Role Permissions', 'Per-staff section access', () => context.push('/admin/roles/permissions')),
                          // The business rules — fees, thresholds, the points
                          // awards and the points-to-birr rate — editable
                          // without a migration. Writes go through
                          // admin_update_setting(), which is Admin-gated.
                          if (ref.read(authProvider).isAdmin)
                            _menuCard(Icons.settings_outlined, 'System Settings',
                                'Fees, points & rank rules', () => context.push('/admin/settings')),
                            // Every money value the platform charges, editable
                            // live. Separate from System Settings because a fee
                            // change is a money decision with its own history,
                            // not one row among dozens of knobs.
                            _menuCard(Icons.payments_outlined, 'Fees & Pricing',
                                'Commission, activation and ride fares',
                                () => context.push('/admin/fees')),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _quickStat(IconData icon, String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
            Text(label, style: const TextStyle(fontSize: 9, color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _pendingCard(IconData icon, String title, String subtitle, Color color, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      Text(subtitle, style: TextStyle(fontSize: 11, color: color)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: color, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuCard(IconData icon, String title, String? subtitle, VoidCallback onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: AppTheme.primaryGreen, size: 19),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.textPrimary)),
                      if (subtitle != null)
                        Text(subtitle, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
