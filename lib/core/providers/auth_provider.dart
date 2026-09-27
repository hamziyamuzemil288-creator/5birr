import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/city_service.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../services/provider_presence_service.dart';
import '../utils/friendly_error.dart';
import '../utils/phone_formatter.dart';

/// Application roles matching the Supabase `app_role` enum.
enum AppUserRole { user, vehicleProvider, serviceProvider, admin }

/// Complete auth state for the application.
class AuthState {
  final User? user;
  final UserProfile? profile;
  final List<AppUserRole> roles;
  final AppUserRole? primaryRole;
  final bool isStaffGateway;
  final bool isLoading;
  final String? error;

  /// True while the session came from a password-recovery link — the
  /// router must send the user to /update-password before anything else.
  final bool isRecoverySession;

  /// True when this account already runs a business of either kind.
  ///
  /// Used to hide "Become a Partner": a customer turning their existing
  /// account into a business is the case that button is for, and somebody who
  /// is already a provider pressing it would only be told they have one
  /// already. An account can hold USER *and* a provider role at once, so this
  /// checks the provider roles rather than primaryRole.
  bool get isProvider =>
      roles.contains(AppUserRole.serviceProvider) ||
      roles.contains(AppUserRole.vehicleProvider);

  const AuthState({
    this.user,
    this.profile,
    this.roles = const [],
    this.primaryRole,
    this.isStaffGateway = false,
    this.isLoading = true,
    this.error,
    this.isRecoverySession = false,
  });

  AuthState copyWith({
    User? user,
    UserProfile? profile,
    List<AppUserRole>? roles,
    AppUserRole? primaryRole,
    bool? isStaffGateway,
    bool? isLoading,
    String? error,
    bool? isRecoverySession,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      profile: profile ?? this.profile,
      roles: roles ?? this.roles,
      primaryRole: primaryRole ?? this.primaryRole,
      isStaffGateway: isStaffGateway ?? this.isStaffGateway,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isRecoverySession: isRecoverySession ?? this.isRecoverySession,
    );
  }

  bool get isAuthenticated => user != null;
  bool get isAdmin => roles.contains(AppUserRole.admin);
  bool get isStaffMember => isStaffGateway && isAdmin;
  bool get isVehicleProvider => roles.contains(AppUserRole.vehicleProvider);
  bool get isServiceProvider => roles.contains(AppUserRole.serviceProvider);
  bool get isUser => roles.contains(AppUserRole.user);
  bool get isPendingApproval =>
      profile != null && profile!.status == 'PENDING_APPROVAL';
  bool get isApproved => profile != null && profile!.status == 'APPROVED';
  bool get isRejected => profile != null && profile!.status == 'REJECTED';

  /// SUSPENDED and INACTIVE are terminal account states that the router must
  /// gate. They used to match none of the checks above, so a suspended user
  /// landed on a normal dashboard with no indication anything was wrong —
  /// even though `suspend_provider` had emailed them "Account suspended" and
  /// the revenue scheduler sets SUSPENDED on its own when a subscription fee
  /// cannot be paid.
  ///
  /// INACTIVE is grouped here deliberately: it is the same user-facing
  /// outcome (no access, needs a human) and nothing in the app transitions
  /// between the two.
  bool get isSuspendedOrInactive {
    if (profile == null) return false;
    const blocked = {'SUSPENDED', 'INACTIVE'};
    return blocked.contains(profile!.status);
  }
}

/// Auth state notifier managing Supabase auth + profile + roles.
class AuthNotifier extends StateNotifier<AuthState> {
  final SupabaseService _svc;
  StreamSubscription<dynamic>? _authSub;

  /// Monotonically increasing counter so that an older _loadUserProfile
  /// call cannot overwrite state produced by a newer one.
  int _profileLoadSeq = 0;

  AuthNotifier(this._svc) : super(const AuthState(isLoading: true)) {
    _init();
  }

  void _init() {
    // Listen for auth state changes
    _authSub = _svc.authStateChanges.listen((authState) async {
      final event = authState.event;
      final session = authState.session;

      if (event == AuthChangeEvent.signedIn && session != null) {
        await _loadUserProfile(session.user);
      } else if (event == AuthChangeEvent.signedOut) {
        state = const AuthState(isLoading: false);
      } else if (event == AuthChangeEvent.tokenRefreshed && session != null) {
        await _loadUserProfile(session.user);
      } else if (event == AuthChangeEvent.passwordRecovery && session != null) {
        // The password-reset email was opened on this device. The session
        // is real but must only be used to set a new password — flag the
        // state so the router lands on /update-password.
        await _loadUserProfile(session.user, isRecovery: true);
      }
    });

    // Check existing session
    final currentSession = _svc.client.auth.currentSession;
    if (currentSession != null) {
      _loadUserProfile(currentSession.user);
    } else {
      state = const AuthState(isLoading: false);
    }
  }

  Future<void> _loadUserProfile(User user, {bool isRecovery = false}) async {
    // Bump the sequence so an older in-flight call cannot overwrite our result.
    final seq = ++_profileLoadSeq;

    try {
      // Load profile — timeout so a hanging query can never leave the UI stuck
      final profileData = await _svc.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'profiles query timed out after 10 seconds',
            ),
          );

      // A newer load has started — discard this stale result.
      if (seq != _profileLoadSeq) return;

      UserProfile? profile;
      if (profileData != null) {
        profile = UserProfile.fromJson(profileData);
      }

      // Load roles — also timeout-protected
      final rolesData = await _svc.client
          .from('user_roles')
          .select('role')
          .eq('user_id', user.id)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'user_roles query timed out after 10 seconds',
            ),
          );

      // Another stale check after the second query.
      if (seq != _profileLoadSeq) return;

      final roles = (rolesData as List)
          .map((r) => _parseRole(r['role'] as String))
          .toList();

      // Gateway accounts are ADMIN-role identities, but they use the staff
      // workspace rather than the CEO/admin dashboard. This lookup is
      // deliberately user-scoped and contains no password data.
      bool isStaffGateway = false;
      try {
        final gateway = await _svc.client
            .from('staff_credentials')
            .select('staff_id')
            .eq('user_id', user.id)
            .maybeSingle();
        isStaffGateway = gateway != null;
      } catch (_) {
        // A pre-Task-12 database has no gateway table. Preserve the existing
        // login behavior until the migration is deployed.
      }

      final primaryRole = roles.firstWhere(
        (r) => r != AppUserRole.user,
        orElse: () => AppUserRole.user,
      );

      state = state.copyWith(
        user: user,
        profile: profile,
        roles: roles,
        primaryRole: primaryRole,
        isStaffGateway: isStaffGateway,
        isLoading: false,
        error: null,
        // Keeps the recovery flag across later token refreshes, and only
        // ever turns it on here (copyWith keeps the previous value).
        isRecoverySession: isRecovery ? true : null,
      );

      // Presence heartbeat: while a provider is signed in and the app is
      // running, periodically touch last_active_at for online/last-seen.
      if (primaryRole == AppUserRole.serviceProvider ||
          primaryRole == AppUserRole.vehicleProvider) {
        ProviderPresence.instance.startHeartbeat();
      } else {
        ProviderPresence.instance.stopHeartbeat();
      }
    } catch (e) {
      // Only apply error state if no newer load has taken over.
      if (seq != _profileLoadSeq) return;
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth profile-load failed: $e');
      state = state.copyWith(
        user: user,
        isLoading: false,
        error: friendlyError(e, context: 'Could not load your account'),
      );
    }
  }

  AppUserRole _parseRole(String role) {
    switch (role) {
      case 'ADMIN':
        return AppUserRole.admin;
      case 'VEHICLE_PROVIDER':
        return AppUserRole.vehicleProvider;
      case 'SERVICE_PROVIDER':
        return AppUserRole.serviceProvider;
      default:
        return AppUserRole.user;
    }
  }

  /// Sign up a regular user with email + password.
  /// Phone number is stored in the profile but NOT used for auth.
  /// No national ID is collected at user signup — ID is requested later at
  /// booking time for booking-type orders.
  ///
  /// IMPORTANT: all profile data is passed via signUp(data: ...) metadata —
  /// the SECURITY DEFINER handle_new_user() trigger creates the profile
  /// (and the provider profile when provider_type is present), the USER
  /// role, and the approval request. The app never writes tables client-
  /// side during signup, so this works whether or not Supabase returns a
  /// session (e.g. if email confirmation is ever re-enabled).
  Future<void> signUp({
    required String email,
    required String phone,
    required String password,
    required String fullName,
    required AppUserRole role,
    String? city,
    String? kebele,
    String? streetRoad,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Format phone to E.164 for profile storage (not auth)
      final e164 = PhoneFormatter.formatToE164(phone);

      final response = await _svc.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
          'phone': e164 ?? phone,
          if (city != null && city.isNotEmpty) 'city': city,
          if (kebele != null && kebele.isNotEmpty) 'kebele': kebele,
          if (streetRoad != null && streetRoad.isNotEmpty)
            'street_road': streetRoad,
        },
      );

      if (response.user == null) {
        throw Exception('Sign up failed: no user returned');
      }

      // Email confirmation is disabled in Supabase Auth (admin approval is
      // the account gate), so a session is issued immediately. If a session
      // is somehow still absent, reset to a logged-out state so the router
      // treats the user as unauthenticated and the UI sends them to sign in.
      if (response.session == null) {
        state = const AuthState(isLoading: false);
        return;
      }

      // Session available — load the profile created by the trigger
      // (status PENDING_APPROVAL, so the router lands on
      // /pending-approval).
      await _loadUserProfile(response.user!);
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not create your account'),
      );
      rethrow;
    }
  }

  /// Sign up as a provider (vehicle or service) with email + password.
  /// Phone number is stored in the profile but NOT used for auth.
  ///
  /// All writes happen server-side: handle_new_user() creates the profile
  /// AND the provider_profiles row (from provider_type in the signup
  /// metadata); trg_provider_profiles_auto_setup then assigns the provider
  /// role and opens the approval request. The app never writes tables
  /// client-side during signup, so this works whether or not Supabase
  /// returns a session.
  Future<void> signUpAsProvider({
    required String email,
    required String phone,
    required String password,
    required String businessName,
    required String ownerNationalId,
    required String providerType,
    String? city,
    String? kebele,
    String? streetRoad,
    // Task 8: optional referral code identifying the sales/staff person who
    // registered this provider. Resolved server-side by handle_new_user()
    // against referral_codes; blank/unknown codes never block registration.
    String? referralCode,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Format phone to E.164 for profile storage (not auth)
      final e164 = PhoneFormatter.formatToE164(phone);

      final response = await _svc.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': businessName,
          'phone': e164 ?? phone,
          'national_id': ownerNationalId,
          'provider_type': providerType,
          'business_name': businessName,
          if (city != null && city.isNotEmpty) 'city': city,
          if (kebele != null && kebele.isNotEmpty) 'kebele': kebele,
          if (streetRoad != null && streetRoad.isNotEmpty)
            'street_road': streetRoad,
          if (referralCode != null && referralCode.trim().isNotEmpty)
            'referral_code': referralCode.trim(),
        },
      );

      if (response.user == null) {
        throw Exception('Sign up failed');
      }

      // No-session fallback — see signUp() above.
      if (response.session == null) {
        state = const AuthState(isLoading: false);
        return;
      }

      // Session available — load the profile + provider profile created
      // by the triggers.
      await _loadUserProfile(response.user!);
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not send the reset email'),
      );
      rethrow;
    }
  }

  /// Sends the password-reset email for [email].
  ///
  /// The link opens the app through the Supabase deep-link scheme
  /// (registered in AndroidManifest.xml) and fires AuthChangeEvent
  /// .passwordRecovery, which flags the session and sends the user to
  /// /update-password. Always completes without telling the caller
  /// whether the address exists (account-enumeration safe).
  Future<void> resetPassword({required String email}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'io.supabase.com.amistbirr.myapp://login-callback/',
      );
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not sign in'),
      );
      rethrow;
    }
    state = state.copyWith(isLoading: false);
  }

  /// Sign in with email + password.
  /// Profile loading is handled exclusively by the _authSub listener
  /// when AuthChangeEvent.signedIn fires — no need to call
  /// _loadUserProfile here (it would cause a redundant double-call).
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      // _authSub listener will pick up AuthChangeEvent.signedIn
      // and call _loadUserProfile automatically.
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not sign in with Google'),
      );
      rethrow;
    }
  }

  /// Task 15: continue with Google (Supabase Auth OAuth provider).
  ///
  /// Opens the system browser for the Google consent screen; Supabase
  /// redirects back into the app via the same deep-link scheme the
  /// password-recovery flow already registers. The session then arrives
  /// through _authSub (AuthChangeEvent.signedIn) and the normal profile
  /// load runs — the account the OAuth trigger creates lands
  /// PENDING_APPROVAL exactly like an email signup, so the router sends
  /// the user to /pending-approval. Nothing else changes for OAuth users.
  ///
  /// [isSignup] only picks the button copy's context — the OAuth flow is
  /// identical for signing in and signing up (Supabase upserts the user).
  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'io.supabase.com.amistbirr.myapp://login-callback/',
      );
      // The browser round-trip continues async; _authSub completes the
      // sign-in when the deep link returns. Reset the spinner here so a
      // user who cancels the consent screen is not stuck loading.
      if (state.isLoading) {
        state = state.copyWith(isLoading: false);
      }
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not load your account'),
      );
      rethrow;
    }
  }

  /// Clear the recovery-session flag after the new password was saved,
  /// so the router resumes the normal authenticated flow.
  void clearRecoveryFlag() {
    if (!state.isRecoverySession) return;
    state = state.copyWith(isRecoverySession: false);
  }

  /// Sign out.
  Future<void> signOut() async {
    ProviderPresence.instance.stopHeartbeat();
    await _svc.client.auth.signOut();
    state = const AuthState(isLoading: false);
  }

  /// Refresh profile from database.
  Future<void> refreshProfile() async {
    if (state.user != null) {
      await _loadUserProfile(state.user!);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    ProviderPresence.instance.stopHeartbeat();
    super.dispose();
  }
}

/// Provider instance.
/// Phase 1: multi-city state (saved city + travel-mode browsing).
/// Exposes the shared singleton so every reader sees the same state;
/// recreated provider stays cheap and sign-out-safe via loadSavedCity.
final cityProvider = Provider<CityService>((ref) => CityService.instance);

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(SupabaseService.instance);
});

/// Convenience provider: is the user authenticated?
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authProvider).isAuthenticated;
});

/// Convenience provider: the user's primary non-USER role.
final primaryRoleProvider = Provider<AppUserRole?>((ref) {
  return ref.watch(authProvider).primaryRole;
});
