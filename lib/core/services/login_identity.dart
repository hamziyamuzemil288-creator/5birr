/// Which credential path a typed login identifier belongs to.
///
/// WHY THIS EXISTS
/// ---------------
/// Admin-created staff sign in with a short username (or an email address)
/// given to them by the CEO — they do NOT have an ordinary Supabase account.
/// `staff-create-gateway` creates their `auth.users` row with a
/// SERVER-DERIVED synthetic address (`<name>@staff-gateway.invalid`, or a
/// hashed form for email-shaped usernames), and their password only ever
/// works through the `staff-login` Edge Function.
///
/// So funneling a staff username into the normal email sign-in can never
/// succeed: the form rejected it as "not an email", and even when it did not
/// the credential check ran against an address that does not exist. That is
/// the reported "the login interface does not recognise the staff member the
/// admin created" bug.
///
/// The classification is deliberately shape-based and has no lookup table:
/// an identifier containing both "@" and "." is an email (the normal
/// account path); anything else is a staff username.
///
/// KNOWN ASYMMETRY: a staff username MAY itself be an email address (see
/// migration 20260925160000), which by shape is indistinguishable from a
/// normal account. `login_screen.dart` therefore falls back to the staff
/// gateway when the ordinary sign-in rejects the credentials, and offers an
/// explicit "Staff / employee sign in" door for that case.
library;

enum LoginIdentityKind {
  /// Normal Supabase account — authenticate with email + password.
  email,

  /// Admin-created staff credential — authenticate via the staff gateway.
  staffUsername,
}

/// Classify a typed login identifier. Case-insensitive; surrounding
/// whitespace is ignored.
LoginIdentityKind classifyLoginIdentifier(String raw) {
  final value = raw.trim();
  if (value.contains('@') && value.contains('.')) {
    return LoginIdentityKind.email;
  }
  return LoginIdentityKind.staffUsername;
}

/// The `login-gate` lockout/CAPTCHA key for a typed staff identifier.
///
/// The gate function rejects any key without "@" (400 `invalid_email`), but
/// a bare staff username has none. Normalizing it to the SAME synthetic
/// address the staff gateway derives for the account
/// (`<name>@staff-gateway.invalid`) keeps the key valid, per-account, and
/// consistent with `staff_gateway_email()` server-side — so CAPTCHA
/// consumption and the failure lockout apply to staff logins exactly as
/// they do to email logins.
///
/// Email-shaped staff usernames are already valid keys and pass through
/// (lowercased, matching the gateway).
String staffLoginGateKey(String raw) {
  final value = raw.trim().toLowerCase();
  if (value.contains('@')) return value;
  return '$value@staff-gateway.invalid';
}
