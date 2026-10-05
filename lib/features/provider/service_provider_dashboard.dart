import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/points_service.dart';
import '../../core/services/provider_readiness.dart';
import '../../core/services/rank_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/publish_readiness_banner.dart';
import '../../core/widgets/rank_badge.dart';
import '../../core/widgets/dashboard_top_tabs.dart';
import '../../core/widgets/quick_action_pill.dart';
import 'provider_payment_methods_screen.dart';

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

  /// Orders sitting at PENDING_PROVIDER — the provider is the only actor who
  /// can move them, so this is work that is blocked on THEM and nobody else.
  ///
  /// `_orderCount` above is every order ever, which is a vanity number: it
  /// cannot change when new work arrives, so a provider watching it has no way
  /// to tell a quiet week from a queue of three bookings they have not
  /// answered. This is the number that moves.
  int _awaitingMe = 0;

  /// Of those, the ones whose listing asked for an availability confirmation.
  ///
  /// Counted separately because they are the ones with a deadline attached: a
  /// buyer is sitting on "Waiting for the provider to confirm availability" and
  /// cannot pay until this is answered.
  int _awaitingAvailability = 0;
  int _points = 0;
  RankProgress? _rankProgress;
  double? _walletBalance;
  bool _loading = true;
  String? _error;

  /// What the SERVER says is outstanding before this provider may publish.
  ///
  /// Loaded alongside the rest of the dashboard, and re-read whenever the
  /// provider returns from fixing something. It is deliberately not derived
  /// from `ProviderDocGate`: the client's rule and the server's rule differ
  /// (see `ProviderReadiness`), and it was the client's more permissive answer
  /// that let a provider fill in a form the server would refuse.
  ProviderReadiness _readiness = ProviderReadiness.unknown;

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
      // The queue. `.eq('status', 'PENDING_PROVIDER')` rather than a client
      // filter over the 200 rows the orders screen loads: this has to be right
      // the moment the dashboard opens, not only after a list has paged in.
      final waiting = await client
          .from('orders')
          .select('id, requires_availability_confirmation')
          .eq('provider_id', prov['id'])
          .eq('status', 'PENDING_PROVIDER');
      final waitingRows = List<Map<String, dynamic>>.from(waiting as List);
      final points = await PointsService.instance.getProviderPoints(prov['id'] as String);
      // Ladder from the server; best-effort so a rank hiccup never blocks the
      // dashboard itself.
      RankProgress? progress;
      try {
        progress = await RankService.instance.progressForPoints(points);
      } catch (_) {
        progress = null;
      }
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      // Asked of the server, alongside the rest, and never allowed to fail the
      // dashboard: a provider who cannot publish still needs to see their
      // orders. An unreadable answer leaves the banner hidden rather than
      // showing a wrong "you are ready".
      final readiness =
          await ProviderReadiness.load(prov['id'] as String);
      if (mounted) {
        setState(() {
          _providerProfile = prov;
          _productCount = prods.count ?? 0;
          _orderCount = orders.count ?? 0;
          _awaitingMe = waitingRows.length;
          _awaitingAvailability = waitingRows
              .where((o) => o['requires_availability_confirmation'] == true)
              .length;
          _points = points;
          _rankProgress = progress;
          _walletBalance = (wallet?['balance'] as num?)?.toDouble();
          _readiness = readiness;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your dashboard');
        });
      }
    }
  }

  /// Re-asks the server whether the provider may publish now.
  ///
  /// Called when the provider returns from a remedy in the banner. It does not
  /// assume the fix worked: the provider may have opened the wrong screen, or
  /// the activation fee may still be processing, and a banner that clears
  /// itself optimistically is the same lie the server's refusal used to tell.
  Future<void> _reloadReadiness() async {
    final id = _providerProfile?['id'];
    if (id is! String || !mounted) return;
    final readiness = await ProviderReadiness.load(id);
    if (!mounted) return;
    setState(() => _readiness = readiness);
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
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
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
                    // Before anything else: can this provider publish at all?
                    //
                    // "Add Product" and "Add Vehicle" are both refused by the
                    // server until this list is empty, and until this banner
                    // existed the ONLY place that surfaced was a failed save at
                    // the end of a fully filled form. A provider who could not
                    // publish had no way to find out why short of trying.
                    PublishReadinessBanner(
                      readiness: _readiness,
                      onChanged: _reloadReadiness,
                    ),
                    // The one shortcut this role opens most: a provider's
                    // photos are what a customer reads before they book, and
                    // the Business tab buried them one tab and one list row
                    // deep. This is the same pill the user home screen uses
                    // for "Book a ride" — QuickActionPill, not a second
                    // button style.
                    //
                    // Additive, not a move: the Business tab entry stays,
                    // because a provider who already knows where it is should
                    // find it there too.
                    //
                    // Gated on the same condition as that entry, for the same
                    // reason: the route is /provider/gallery/:id, so without a
                    // provider id this would push a path matching no route.
                    if (_providerProfile?['id'] != null)
                      QuickActionPill(
                        icon: Icons.photo_library_outlined,
                        label: 'My Gallery',
                        onTap: () => context.push(
                            '/provider/gallery/${_providerProfile!['id']}'),
                      ),
                    const SizedBox(height: 20),
                    // Rank: the business's standing on the loyalty ladder, with
                    // the distance to the next rung. Status only — no feature
                    // is gated on it.
                    RankProgressCard(
                      points: _points,
                      progress: _rankProgress,
                      subjectLabel: 'Business',
                      onTap: () => context.push('/points'),
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
                    // Grouped per the founder's top-tab sketch. The same
                    // entries, in the same order, in the same screens —
                    // only the navigation shape changed.
                    DashboardTopTabs(
                      tabs: [
                        DashboardTab(
                          label: 'Business',
                          icon: Icons.storefront_outlined,
                          builder: (_) => _actionList([
                            // Buyer mode: providers can shop from other
                            // providers using the regular user experience
                            // (browse, cart, checkout, escrow) while keeping
                            // this business view.
                            _action(Icons.shopping_bag_outlined,
                                'Browse & Shop', () => context.push('/user')),
                            _action(Icons.storefront_outlined,
                                'Business Profile',
                                () => context.push('/provider/business')),
                            // The trade-specific form: the fields and prices
                            // this provider's own category defines, set by an
                            // administrator. Sits beside Business Profile
                            // rather than replacing it -- that one is who they
                            // are, this one is what they sell.
                            _action(Icons.tune, 'Settings & Pricing',
                                () => context.push('/provider/category-settings')),
                            // Only rendered once a profile row exists. The
                            // route is /provider/gallery/:id, so a null id
                            // here would push a path matching no route at all.
                            if (_providerProfile?['id'] != null)
                              _action(Icons.photo_library_outlined, 'My Gallery',
                                  () => context.push(
                                      '/provider/gallery/${_providerProfile!['id']}')),
                            _action(Icons.card_membership, 'Subscription',
                                () => context.push('/provider/subscription')),
                            _action(Icons.payment_outlined, 'Payment Methods',
                                () => context.push('/provider/payment-methods')),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Catalogue',
                          icon: Icons.inventory_2_outlined,
                          builder: (_) => _actionList([
                            _action(Icons.inventory_2_outlined,
                                'My Products',
                                () => context.push('/provider/products')),
                            _action(Icons.add_circle_outline, 'Add Product',
                                () => context.push('/provider/products/new')),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Orders',
                          icon: Icons.receipt_long_outlined,
                          builder: (_) => _actionList([
                            _action(Icons.receipt_long_outlined, 'Orders',
                                () => context.push('/provider/orders')),
                            // The money a buyer paid into this account. The
                            // provider can confirm it here as well as an admin
                            // can; the platform wallet top-up stays
                            // admin-only and is not on this screen.
                            _action(Icons.verified_outlined,
                                'Verify Buyer Payments',
                                () => context.push('/provider/payment-verification')),
                          ]),
                        ),
                        DashboardTab(
                          label: 'Account',
                          icon: Icons.person_outline,
                          builder: (_) => _actionList([
                            _action(
                                Icons.account_balance_wallet_outlined, 'Wallet',
                                () => context.push('/wallet')),
                            _action(Icons.person_outline, 'Profile',
                                () => context.push('/profile')),
                          ]),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// The entries of one dashboard tab, as a single widget.
  ///
  /// Returns a Column rather than a List<Widget> because a DashboardTab's
  /// builder is a WidgetBuilder: handing it a list is a type error, and
  /// returning the raw list is what made this compile-fail.
  Widget _actionList(List<Widget> actions) =>
      Column(children: actions);

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
