// Regression test for the Task 13 signup OTP bug.
//
// The signup flow pushes /otp-verify BEFORE the account exists, so the
// router's unauthenticated allowlist must contain /otp-verify. When it was
// missing, GoRouter's redirect bounced every signup straight to /login: the
// code-entry screen never mounted and the OTP email was never requested
// (the reported "no OTP at registration, no code screen" bug).
//
// The redirect closure reads authProvider (requires Supabase to be
// initialized), so a full GoRouter unit test is not practical here. Instead
// this test parses the router source directly: it fails if /otp-verify is
// ever dropped from the unauthenticated allowlist again, or if the
// unauthenticated branch stops consulting isAuthRoute.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final routerSource = File('lib/routing/app_router.dart').readAsStringSync();

  test('router: /otp-verify is in the unauthenticated allowlist', () {
    // The allowlist is the isAuthRoute ||-chain inside the redirect.
    // Match the literal route entry to guard against renames/tlosses.
    expect(
      routerSource.contains("loc == '/otp-verify'"),
      isTrue,
      reason:
          "lib/routing/app_router.dart no longer allowlists /otp-verify for "
          "unauthenticated users. Signup pushes /otp-verify BEFORE the "
          "account exists; without the allowlist entry the redirect bounces "
          "the user to /login and the OTP email is never sent.",
    );
  });

  test('router: unauthenticated branch still honors the allowlist', () {
    // The `if (!isAuthenticated)` branch must keep consulting isAuthRoute —
    // an entry in the list alone does nothing if the branch hard-returns.
    final branch = RegExp(
      r'if \(!isAuthenticated\) \{[\s\S]*?if \(isAuthRoute \|\| isSignupRoute\) return null;',
    ).firstMatch(routerSource);
    expect(
      branch,
      isNotNull,
      reason:
          'The unauthenticated redirect branch no longer returns null for '
          'allowlisted routes (isAuthRoute || isSignupRoute). Every '
          'pre-auth screen — including /otp-verify — would bounce to /login.',
    );
  });
}
