// Shared staff identity rules for the Supabase Edge Functions (Deno).
//
// WHY THIS FILE EXISTS — staff accounts are real auth.users rows, so both
// staff-create-gateway and staff-login must independently derive the SAME
// synthetic email from a username. When the two sides disagree, staff
// creation succeeds but login can never find the account, which presents as
// a silent "invalid username or password" with no clue why.
//
// A username may now be an email address (the product's real login identity
// is an email everywhere else). That breaks the original scheme, which built
// the auth email as `${username}@staff-gateway.invalid`: an email username
// would yield `aymen@gmail.com@staff-gateway.invalid`, which is malformed
// and which GoTrue rejects.
//
// The scheme is therefore chosen by the SHAPE of the username, not by a
// lookup table or a migration of existing rows:
//   * bare name  (e.g. "aymen")          -> aymen@staff-gateway.invalid
//     Byte-identical to the original scheme, so every staff account created
//     before this change keeps logging in with no password reset and no
//     re-key. This is what makes the change backward compatible.
//   * email      (e.g. "aymen@gmail.com") -> s_<sha256[0:24]>@staff-gateway.invalid
//     A fixed-shape local part, because a local part may not contain "@".
//
// The mapping is pure and deterministic: given a username, both gateways
// compute the same email with no database round-trip, so login can rebuild
// the identity from the credentials alone.

/** The original format. Kept verbatim so existing accounts are unaffected. */
export const LEGACY_USERNAME_PATTERN = /^[a-z0-9][a-z0-9._-]{2,31}$/;

/**
 * A deliberately permissive email check. The authoritative validation for
 * deliverable addresses is the OTP send/verify path; this only has to reject
 * values that could not be an identity at all (no "@", no domain, spaces).
 */
export const EMAIL_USERNAME_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/** Usernames are matched case-insensitively; the DB's unique index is on lower(username). */
export function cleanUsername(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

export function isValidUsername(username: string): boolean {
  return LEGACY_USERNAME_PATTERN.test(username) || EMAIL_USERNAME_PATTERN.test(username);
}

function toHex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * The auth.users email a staff username maps to. MUST stay in lockstep
 * between staff-create-gateway and staff-login.
 */
export async function syntheticStaffEmail(username: string): Promise<string> {
  const u = cleanUsername(username);
  if (LEGACY_USERNAME_PATTERN.test(u)) {
    // Unchanged from the original implementation.
    return `${u}@staff-gateway.invalid`;
  }
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(u),
  );
  return `s_${toHex(digest).slice(0, 24)}@staff-gateway.invalid`;
}
