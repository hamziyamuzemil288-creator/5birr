import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/points_service.dart';

class ServiceProviderDashboard extends ConsumerStatefulWidget {
  const ServiceProviderDashboard({super.key});
  @override
  ConsumerState<ServiceProviderDashboard> createState() =>
      _ServiceProviderDashboardState();
}

class _ServiceProviderDashboardState
    extends ConsumerState<ServiceProviderDashboard> {
  Map<String, dynamic>? _providerProfile;
  int _productCount = 0;
  int _orderCount = 0;
  int _points = 0;
  double? _walletBalance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select()
          .eq('user_id', userId)
          .eq('provider_type', 'SERVICE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final prods = await client
          .from('products')
          .select('id')
          .eq('provider_id', prov['id'])
          .eq('is_active', true)
          .count(CountOption.exact);
      final orders = await client
          .from('orders')
          .select('id')
          .eq('provider_id', prov['id'])
          .count(CountOption.exact);
      final points = await PointsService.instance.getProviderPoints(prov['id'] as String);
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      if (mounted) {
        setState(() {
          _providerProfile = prov;
          _productCount = prods.count ?? 0;
          _orderCount = orders.count ?? 0;
          _points = points;
          _walletBalance = (wallet?['balance'] as num?)?.toDouble();
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
        title: const Text('Aliob Business'),
        actions: [
          // Task 7 item 2: real notification inbox (admin broadcasts land
          // here), not a placeholder snackbar.
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push('/admin-notifications')),
          IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () =>
                  ref.read(authProvider.notifier).signOut()),
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
                    // Header
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [
                              AppTheme.primaryGreen,
                              Color(0xFF2E7D32)
                            ]),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              _providerProfile?['business_name'] ??
                                  auth.profile?.fullName ??
                                  'Business',
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white)),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                    (_providerProfile?['status'] ?? 'UNKNOWN')
                                        .replaceAll('_', ' '),
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.white)),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Wallet balance strip
                    _walletCard(),
                    const SizedBox(height: 20),
                    // Stats
                    Row(
                      children: [
                        _statCard(Icons.inventory_2_outlined, 'Products',
                            '$_productCount'),
                        const SizedBox(width: 12),
                        _statCard(
                            Icons.receipt_long, 'Orders', '$_orderCount'),
                        const SizedBox(width: 12),
                        _statCard(
                            Icons.stars_rounded, 'Points', '$_points'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Text('Management',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    // Buyer mode: providers can shop from other providers
                    // using the regular user experience (browse, cart,
                    // checkout, escrow) while keeping this business view.
                    _action(Icons.shopping_bag_outlined, 'Browse & Shop',
                        () => context.push('/user')),
                    _action(Icons.storefront_outlined, 'Business Profile',
                        () => context.push('/provider/business')),
                    _action(Icons.inventory_2_outlined, 'My Products',
                        () => context.push('/provider/products')),
                    _action(Icons.add_circle_outline, 'Add Product',
                        () => context.push('/provider/products/new')),
                    _action(Icons.photo_library_outlined, 'Gallery',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                    _action(Icons.receipt_long_outlined, 'Orders',
                        () => context.push('/provider/orders')),                    _action(Icons.account_balance_wallet_outlined, 'Wallet',
                        () => context.push('/wallet')),
                    _action(Icons.card_membership, 'Subscription',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                    _action(Icons.person_outline, 'Profile',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                  ],
                ),
              ),
            ),
    );
  }

  /// Compact wallet balance strip: balance at a glance + one-tap recharge.
  Widget _walletCard() {
    final balance = _walletBalance ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.account_balance_wallet_outlined,
                color: AppTheme.primaryGreen, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Wallet Balance',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text('${balance.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => context.push('/wallet/recharge'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Recharge',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(foregroundColor: AppTheme.teal),
          ),
        ],
      ),
    );
  }

  Widget _statCard(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppTheme.primaryGreen, size: 22),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.primaryGreen),
        title: Text(label,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right,
            color: AppTheme.textMuted, size: 20),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
        tileColor: AppTheme.surface,
      ),
    );
  }
}
