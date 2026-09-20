import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../utils/phone_formatter.dart';

/// Application roles matching the Supabase `app_role` enum.
enum AppUserRole { user, vehicleProvider, serviceProvider, admin }

/// Complete auth state for the application.
class AuthState {
  final User? user;
  final UserProfile? profile;
  final List<AppUserRole> roles;
  final AppUserRole? primaryRole;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.user,
    this.profile,
    this.roles = const [],
    this.primaryRole,
    this.isLoading = true,
    this.error,
  });

  AuthState copyWith({
    User? user,
    UserProfile? profile,
    List<AppUserRole>? roles,
    AppUserRole? primaryRole,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      profile: profile ?? this.profile,
      roles: roles ?? this.roles,
      primaryRole: primaryRole ?? this.primaryRole,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  bool get isAuthenticated => user != null;
  bool get isAdmin => roles.contains(AppUserRole.admin);
  bool get isVehicleProvider => roles.contains(AppUserRole.vehicleProvider);
  bool get isServiceProvider => roles.contains(AppUserRole.serviceProvider);
  bool get isUser => roles.contains(AppUserRole.user);
  bool get isPendingApproval =>
      profile != null && profile!.status == 'PENDING_APPROVAL';
  bool get isApproved =>
      profile != null && profile!.status == 'APPROVED';
  bool get isRejected =>
      profile != null && profile!.status == 'REJECTED';
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

  Future<void> _loadUserProfile(User user) async {
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

      final primaryRole = roles.firstWhere(
        (r) => r != AppUserRole.user,
        orElse: () => AppUserRole.user,
      );

      state = state.copyWith(
        user: user,
        profile: profile,
        roles: roles,
        primaryRole: primaryRole,
        isLoading: false,
        error: null,
      );
    } catch (e) {
      // Only apply error state if no newer load has taken over.
      if (seq != _profileLoadSeq) return;
      state = state.copyWith(
        user: user,
        isLoading: false,
        error: e.toString(),
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
      state = state.copyWith(isLoading: false, error: e.toString());
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
      state = state.copyWith(isLoading: false, error: e.toString());
      rethrow;
    }
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
      state = state.copyWith(isLoading: false, error: e.toString());
      rethrow;
    }
  }

  /// Sign out.
  Future<void> signOut() async {
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
    super.dispose();
  }
}

/// Provider instance.
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
