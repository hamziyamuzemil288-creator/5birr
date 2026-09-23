import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/auth_provider.dart';
import '../features/splash/splash_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart' show SignupScreen, SignupRole;
import '../features/auth/otp_verification_screen.dart';
import '../features/auth/role_selection_screen.dart';
import '../features/auth/admin_login_screen.dart';
import '../features/auth/terms_policy_screen.dart';
import '../features/auth/update_password_screen.dart';
import '../features/user/user_dashboard.dart';
import '../features/user/user_notifications_screen.dart';
import '../features/user/user_product_detail_screen.dart';
import '../features/user/user_provider_detail_screen.dart';
import '../features/user/user_category_screen.dart';
import '../features/user/user_favorites_screen.dart';
import '../features/user/user_cart_screen.dart';
import '../features/user/user_checkout_screen.dart';
import '../features/user/user_order_detail_screen.dart';
import '../features/user/provider_order_waiting_screen.dart';
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
import '../features/admin/admin_history_screen.dart';
import '../features/admin/admin_staff_screen.dart';
import '../features/admin/admin_user_management_screen.dart';
import '../features/admin/admin_payment_methods_screen.dart';
import '../features/admin/admin_payment_verification_screen.dart';
import '../features/admin/admin_cash_recharge_screen.dart';
import '../features/admin/admin_provider_wallet_screen.dart';
import '../features/admin/admin_transaction_history_screen.dart';
import '../features/admin/admin_registration_history_screen.dart';
import '../features/admin/admin_income_summary_screen.dart';
import '../features/admin/admin_expense_screen.dart';
import '../features/admin/admin_reports_screen.dart';
import '../features/admin/admin_support_tickets_screen.dart';
import '../features/admin/admin_appeals_screen.dart';
import '../features/admin/admin_staff_assignment_screen.dart';
import '../features/admin/admin_role_permissions_screen.dart';
import '../features/appeal/appeal_screen.dart';
import '../features/admin/admin_notification_send_screen.dart';
import '../features/approval/pending_approval_screen.dart';
import '../features/approval/rejected_screen.dart';
import '../features/vehicle/driver_ride_requests_screen.dart';
import '../features/vehicle/driver_trip_screen.dart';
import '../features/user/user_ride_request_screen.dart';
import '../features/user/user_active_ride_screen.dart';
import '../features/shared/ride_history_screen.dart';
import '../features/help_chat/help_chat_screen.dart';

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
          loc == '/admin-login' ||
          loc == '/terms' ||
          loc == '/update-password';
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

      // ── Password recovery — checked BEFORE every other gate ──
      // A recovery session is a real session but must only be used to set
      // a new password. Send them to /update-password from anywhere else;
      // clear the flag the moment the new password is saved.
      if (authState.isRecoverySession && loc != '/update-password') {
        return '/update-password';
      }

      // ── Pending / rejected status (checked BEFORE dashboard redirect) ──
      // Admins bypass the approval gate — they authenticate directly via
      // Supabase Auth + has_role('ADMIN') and never need admin approval.
      if (!authState.isAdmin) {
        if (authState.isPendingApproval && !isApprovalRoute) {
          return '/pending-approval';
        }
        if (authState.isRejected && !isApprovalRoute) {
          return '/rejected';
        }
      }

      // Approval resolved (e.g. admin approved while the user sat on the
      // pending screen and tapped REFRESH STATUS) — move to the dashboard
      // instead of dead-ending on the approval screen.
      if (isApprovalRoute &&
          !authState.isPendingApproval &&
          !authState.isRejected) {
        return _getDashboardPath(authState);
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

      // Task 7 item 1: email OTP verification between the signup form and
      // account creation. Returns `true` when the code was verified.
      GoRoute(
        path: '/otp-verify',
        builder: (_, s) => OtpVerificationScreen(args: s.extra as OtpArgs),
      ),
      GoRoute(
        path: '/update-password',
        builder: (_, __) => const UpdatePasswordScreen(),
      ),
      GoRoute(
        path: '/terms',
        builder: (_, s) => TermsPolicyScreen(returnToSignup: s.extra == true),
      ),
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
      GoRoute(
        path: '/user/order-waiting',
        builder: (_, s) {
          final args = (s.extra as Map?) ?? const {};
          return ProviderOrderWaitingScreen(
            providerId: args['providerId'] as String? ?? '',
            providerName: args['providerName'] as String? ?? 'The provider',
            providerNotActivated: (args['providerNotActivated'] as bool?) ?? false,
          );
        },
      ),
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
      // Standalone search route: the screen is a bare Column (tab content),
      // so it must get a Material/Scaffold ancestor here — otherwise the
      // TextField crashes with "No Material widget found" and the in-build
      // error box overflows the unscrollable column.
      GoRoute(
        path: '/user/search',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Search')),
          body: const SafeArea(child: UserSearchScreen()),
        ),
      ),
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
      GoRoute(path: '/admin/users', builder: (_, __) => const AdminUserManagementScreen()),
      GoRoute(path: '/admin/payment-methods', builder: (_, __) => const AdminPaymentMethodsScreen()),
      GoRoute(path: '/admin/payments', builder: (_, __) => const AdminPaymentVerificationScreen()),
      GoRoute(path: '/admin/providers/:id/wallet', builder: (_, s) => AdminProviderWalletScreen(providerId: s.pathParameters['id']!)),
      GoRoute(path: '/admin/providers/:id/wallet/recharge', builder: (_, s) => AdminCashRechargeScreen(providerId: s.pathParameters['id']!)),
      // ── Admin — New sections ──
      GoRoute(path: '/admin/transactions', builder: (_, __) => const AdminTransactionHistoryScreen()),
      GoRoute(path: '/admin/registrations', builder: (_, __) => const AdminRegistrationHistoryScreen()),
      GoRoute(path: '/admin/income', builder: (_, __) => const AdminIncomeSummaryScreen()),
      GoRoute(path: '/admin/expenses', builder: (_, __) => const AdminExpenseScreen()),
      GoRoute(path: '/admin/reports', builder: (_, __) => const AdminReportsScreen()),
      GoRoute(path: '/admin/support-tickets', builder: (_, __) => const AdminSupportTicketsScreen()),
      GoRoute(path: '/admin/appeals', builder: (_, __) => const AdminAppealsScreen()),
      GoRoute(path: '/admin/history', builder: (_, __) => const AdminHistoryScreen()),
      GoRoute(path: '/admin/staff', builder: (_, __) => const AdminStaffScreen()),
      // Task 3: role management console (true-Admin-only page + per-staff
      // permission control; server paths re-check authorization).
      GoRoute(path: '/admin/staff-assignment', builder: (_, __) => const AdminStaffAssignmentScreen()),
      GoRoute(path: '/admin/roles/permissions', builder: (_, __) => const AdminRolePermissionsScreen()),
      GoRoute(path: '/admin/send-notifications', builder: (_, __) => const AdminNotificationSendScreen()),

      // ── Help (signed-in users) ──
      GoRoute(path: '/help', builder: (_, __) => const HelpChatScreen()),
      // User-submitted appeal / spam-report form (linked from the help chat).
      GoRoute(path: '/appeal', builder: (_, __) => const AppealScreen()),

      // Task 7 item 2: standalone notification inbox for providers/vehicle
      // owners (their dashboards' bell). Users get the same screen as a
      // dashboard tab; staff in the admin panel have /admin/send-notifications.
      GoRoute(
          path: '/admin-notifications',
          builder: (_, __) => const Scaffold(body: UserNotificationsScreen())),
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
