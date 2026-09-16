import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/auth_provider.dart';
import '../features/splash/splash_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart' show SignupScreen, SignupRole;
import '../features/auth/role_selection_screen.dart';
import '../features/auth/admin_login_screen.dart';
import '../features/user/user_dashboard.dart';
import '../features/user/user_product_detail_screen.dart';
import '../features/user/user_provider_detail_screen.dart';
import '../features/user/user_category_screen.dart';
import '../features/user/user_favorites_screen.dart';
import '../features/user/user_cart_screen.dart';
import '../features/user/user_checkout_screen.dart';
import '../features/user/user_order_detail_screen.dart';
import '../features/user/user_search_screen.dart';
import '../features/user/review_form_screen.dart';
import '../features/provider/service_provider_dashboard.dart';
import '../features/provider/provider_orders_screen.dart';
import '../features/provider/provider_business_profile_screen.dart';
import '../features/provider/provider_product_list_screen.dart';
import '../features/provider/provider_product_form_screen.dart';
import '../features/vehicle/vehicle_provider_dashboard.dart';
import '../features/vehicle/vehicle_management_screen.dart';
import '../features/vehicle/vehicle_form_screen.dart';
import '../features/wallet/wallet_screen.dart';
import '../features/wallet/recharge_screen.dart';
import '../features/admin/admin_dashboard.dart';
import '../features/admin/admin_provider_management_screen.dart';
import '../features/admin/admin_payment_methods_screen.dart';
import '../features/admin/admin_payment_verification_screen.dart';
import '../features/admin/admin_cash_recharge_screen.dart';
import '../features/admin/admin_provider_wallet_screen.dart';
import '../features/approval/pending_approval_screen.dart';
import '../features/approval/rejected_screen.dart';
import '../features/vehicle/driver_ride_requests_screen.dart';
import '../features/vehicle/driver_trip_screen.dart';
import '../features/user/user_ride_request_screen.dart';
import '../features/user/user_active_ride_screen.dart';
import '../features/shared/ride_history_screen.dart';

/// A [ChangeNotifier] that fires whenever [authProvider] state changes,
/// allowing [GoRouter] to re-evaluate its redirect callback.
///
/// Also handles a one-time retry for missing profiles right after signup:
/// the database trigger may not have completed by the time
/// [GoRouter] first evaluates the redirect, so we wait briefly and
/// refresh the profile once.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(this._ref) {
    _sub = _ref.listen<AuthState>(authProvider, (_, __) => notifyListeners());
  }

  final Ref _ref;
  late final ProviderSubscription<AuthState> _sub;
  bool _profileRetryScheduled = false;

  /// Call when redirect sees an authenticated user with no profile.
  /// Schedules a single retry after 1 second to give the database
  /// trigger time to complete.
  void scheduleProfileRetry() {
    if (_profileRetryScheduled) return;
    _profileRetryScheduled = true;
    Future.delayed(const Duration(seconds: 1), () {
      _profileRetryScheduled = false;
      _ref.read(authProvider.notifier).refreshProfile();
    });
  }

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  // Create a ChangeNotifier that fires on every auth state change.
  // GoRouter listens to this via refreshListenable and re-evaluates
  // the redirect callback each time it fires.
  //
  // IMPORTANT: We do NOT ref.watch(authProvider) here. Watching it would
  // destroy and recreate the GoRouter on every auth state change, losing
  // all navigation state. Instead, the redirect callback reads the
  // current auth state via ref.read() each time it is invoked.
  final refreshNotifier = _AuthRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      // Read the CURRENT auth state each time the redirect is evaluated.
      // This is safe because refreshListenable fires on every auth change,
      // and ref.read() returns the latest state synchronously.
      final authState = ref.read(authProvider);
      final isLoading = authState.isLoading;
      final isAuthenticated = authState.isAuthenticated;
      final loc = state.matchedLocation;
      final isAuthRoute = loc == '/login' ||
          loc == '/role-select' ||
          loc == '/admin-login';
      final isSignupRoute = loc.startsWith('/signup/');
      final isApprovalRoute = _isApprovalRoute(loc);

      // Still loading — don't redirect yet.
      if (isLoading) return null;

      // Not authenticated — redirect to login (unless already on an auth route).
      if (!isAuthenticated) {
        if (isAuthRoute || isSignupRoute) return null;
        return '/login';
      }

      // Authenticated but profile or roles haven't loaded yet — stay put
      // and schedule a retry (the DB trigger may still be in-flight).
      if (authState.profile == null || authState.roles.isEmpty) {
        refreshNotifier.scheduleProfileRetry();
        return null;
      }

      // ── Pending / rejected status (checked BEFORE dashboard redirect) ──
      if (authState.isPendingApproval && !isApprovalRoute) {
        return '/pending-approval';
      }
      if (authState.isRejected && !isApprovalRoute) {
        return '/rejected';
      }

      // ── On an auth route (login, signup, role-select) — redirect away ──
      if (isAuthRoute || isSignupRoute) {
        return _getDashboardPath(authState);
      }

      // ── On the splash screen — redirect to the correct dashboard ──
      if (loc == '/') {
        return _getDashboardPath(authState);
      }

      // Already on a dashboard or approval route — no redirect needed.
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/role-select', builder: (_, __) => const RoleSelectionScreen()),
      GoRoute(
        path: '/signup/:role',
        builder: (_, state) {
          final r = state.pathParameters['role']!;
          return SignupScreen(role: switch (r) {
            'user' => SignupRole.user,
            'vehicle' => SignupRole.vehicleProvider,
            'service' => SignupRole.serviceProvider,
            _ => SignupRole.user,
          });
        },
      ),
      GoRoute(path: '/admin-login', builder: (_, __) => const AdminLoginScreen()),
      GoRoute(path: '/pending-approval', builder: (_, __) => const PendingApprovalScreen()),
      GoRoute(path: '/rejected', builder: (_, __) => const RejectedScreen()),

      // ── User ──
      GoRoute(path: '/user', builder: (_, __) => const UserDashboard()),
      GoRoute(path: '/user/product/:id', builder: (_, s) => UserProductDetailScreen(productId: s.pathParameters['id']!)),
      GoRoute(path: '/user/provider/:id', builder: (_, s) => UserProviderDetailScreen(providerId: s.pathParameters['id']!)),
      GoRoute(path: '/user/category/:id', builder: (_, s) => UserCategoryScreen(categoryId: s.pathParameters['id']!)),
      GoRoute(path: '/user/favorites', builder: (_, __) => const UserFavoritesScreen()),
      GoRoute(path: '/user/cart', builder: (_, __) => const UserCartScreen()),
      GoRoute(path: '/user/checkout', builder: (_, s) => UserCheckoutScreen(providerId: s.extra as String)),
      GoRoute(path: '/user/orders/:id', builder: (_, s) => UserOrderDetailScreen(orderId: s.pathParameters['id']!, viewerRole: s.extra as String? ?? 'user')),
      GoRoute(
        path: '/review/new',
        builder: (_, s) {
          final args = (s.extra as Map?) ?? const {};
          return ReviewFormScreen(
            orderId: args['orderId'] as String?,
            productId: args['productId'] as String?,
            providerId: args['providerId'] as String?,
          );
        },
      ),
      GoRoute(path: '/user/search', builder: (_, __) => const UserSearchScreen()),
      GoRoute(path: '/user/ride-request', builder: (_, __) => const UserRideRequestScreen()),
      GoRoute(path: '/user/ride-active', builder: (_, __) => const UserActiveRideScreen()),
      GoRoute(path: '/user/ride-history', builder: (_, __) => const RideHistoryScreen(isProvider: false)),

      // ── Service Provider ──
      GoRoute(path: '/provider', builder: (_, __) => const ServiceProviderDashboard()),
      GoRoute(path: '/provider/business', builder: (_, __) => const ProviderBusinessProfileScreen()),
      GoRoute(path: '/provider/orders', builder: (_, __) => const ProviderOrdersScreen()),
      GoRoute(path: '/provider/products', builder: (_, __) => const ProviderProductListScreen()),
      GoRoute(path: '/provider/products/new', builder: (_, __) => const ProviderProductFormScreen()),
      GoRoute(path: '/provider/products/:id', builder: (_, s) => ProviderProductFormScreen(productId: s.pathParameters['id'])),

      // ── Wallet (provider) ──
      GoRoute(path: '/wallet', builder: (_, __) => const WalletScreen()),
      GoRoute(path: '/wallet/recharge', builder: (_, __) => const RechargeScreen()),

      // ── Vehicle Provider ──
      GoRoute(path: '/vehicle', builder: (_, __) => const VehicleProviderDashboard()),
      GoRoute(path: '/vehicle/vehicles', builder: (_, __) => const VehicleManagementScreen()),
      GoRoute(path: '/vehicle/vehicles/new', builder: (_, __) => const VehicleFormScreen()),
      GoRoute(path: '/vehicle/vehicles/:id', builder: (_, s) => VehicleFormScreen(vehicleId: s.pathParameters['id'])),
      GoRoute(path: '/vehicle/ride-requests', builder: (_, __) => const DriverRideRequestsScreen()),
      GoRoute(path: '/vehicle/trip/:id', builder: (_, __) => const DriverTripScreen()),
      GoRoute(path: '/vehicle/history', builder: (_, __) => const RideHistoryScreen(isProvider: true)),

      // ── Admin ──
      GoRoute(path: '/admin', builder: (_, __) => const AdminDashboard()),
      GoRoute(path: '/admin/approvals', builder: (_, __) => const AdminProviderManagementScreen()),
      GoRoute(path: '/admin/providers', builder: (_, __) => const AdminProviderManagementScreen()),
      GoRoute(path: '/admin/payment-methods', builder: (_, __) => const AdminPaymentMethodsScreen()),
      GoRoute(path: '/admin/payments', builder: (_, __) => const AdminPaymentVerificationScreen()),
      GoRoute(path: '/admin/providers/:id/wallet', builder: (_, s) => AdminProviderWalletScreen(providerId: s.pathParameters['id']!)),
      GoRoute(path: '/admin/providers/:id/wallet/recharge', builder: (_, s) => AdminCashRechargeScreen(providerId: s.pathParameters['id']!)),
    ],
  );
});

String _getDashboardPath(AuthState auth) {
  if (auth.isAdmin) return '/admin';
  if (auth.primaryRole == AppUserRole.vehicleProvider) return '/vehicle';
  if (auth.primaryRole == AppUserRole.serviceProvider) return '/provider';
  return '/user';
}

bool _isApprovalRoute(String path) {
  return path == '/pending-approval' || path == '/rejected';
}
