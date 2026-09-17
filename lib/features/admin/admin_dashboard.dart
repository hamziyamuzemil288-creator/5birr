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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final pending = await client
          .from('provider_profiles')
          .select('id')
          .eq('status', 'PENDING_APPROVAL')
          .count(CountOption.exact);
      final pendingUsers = await client
          .from('profiles')
          .select('id')
          .eq('status', 'PENDING_APPROVAL')
          .count(CountOption.exact);
      final recharges = await client
          .from('wallet_recharge_requests')
          .select('id')
          .eq('status', 'PENDING')
          .count(CountOption.exact);
      final total = await client
          .from('provider_profiles')
          .select('id')
          .count(CountOption.exact);
      final users = await client
          .from('profiles')
          .select('id')
          .count(CountOption.exact);
      final prods = await client
          .from('products')
          .select('id')
          .count(CountOption.exact);
      if (mounted) {
        setState(() {
          _pendingProviders = pending.count ?? 0;
          _pendingUsers = pendingUsers.count ?? 0;
          _pendingRecharges = recharges.count ?? 0;
          _totalProviders = total.count ?? 0;
          _totalUsers = users.count ?? 0;
          _totalProducts = prods.count ?? 0;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('5BIRR Admin'),
        backgroundColor: AppTheme.primaryGreenDark,
        actions: [
          IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => ref.read(authProvider.notifier).signOut()),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [AppTheme.primaryGreenDark, Color(0xFF071F0A)]),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Admin Panel',
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          const SizedBox(height: 4),
                          Text('Manage the 5BIRR platform',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white.withOpacity(0.7))),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    GridView.count(
                      crossAxisCount: 2,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.6,
                      children: [
                        _statCard(Icons.pending_actions, 'Pending Providers',
                            '$_pendingProviders', AppTheme.warning),
                        _statCard(Icons.person_add, 'Pending Users',
                            '$_pendingUsers', AppTheme.teal),
                        _statCard(Icons.payment, 'Pending Recharges',
                            '$_pendingRecharges', AppTheme.teal),
                        _statCard(Icons.storefront, 'Providers',
                            '$_totalProviders', AppTheme.primaryGreen),
                        _statCard(Icons.people, 'Users', '$_totalUsers', AppTheme.info),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Provider Management
                    const Text('Approvals',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    _action(Icons.person_add, 'Pending User Approvals',
                        () => context.go('/admin/users')),
                    _action(Icons.approval, 'Pending Provider Approvals',
                        () => context.go('/admin/approvals')),
                    const SizedBox(height: 20),
                    // Provider Management
                    const Text('Provider Management',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    _action(Icons.storefront_outlined, 'All Providers',
                        () => context.go('/admin/providers')),
                    _action(Icons.directions_car_outlined, 'Vehicle Providers',
                        () => context.go('/admin/providers')),
                    const SizedBox(height: 20),
                    // Financial
                    const Text('Financial',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    _action(Icons.payment, 'Payment Verification',
                        () => context.go('/admin/payments')),
                    _action(Icons.money, 'Cash Recharge',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                    _action(Icons.account_balance_wallet_outlined, 'Payment Methods',
                        () => context.go('/admin/payment-methods')),
                    const SizedBox(height: 20),
                    // System
                    const Text('System',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    _action(Icons.people_outline, 'All Users',
                        () => context.go('/admin/users')),
                    _action(Icons.category_outlined, 'Categories',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                    _action(Icons.analytics_outlined, 'Analytics',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _statCard(IconData icon, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const Spacer(),
          Text(value,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.primaryGreenDark),
        title: Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: AppTheme.surface,
      ),
    );
  }
}
