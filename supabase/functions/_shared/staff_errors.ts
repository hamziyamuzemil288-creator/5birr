// Maps create_staff_gateway / trust_staff_gateway_email failures to stable
// client-facing codes.
//
// WHY THIS FILE EXISTS
// --------------------
// staff-create-gateway had a catch-all: any RPC error the switch did not
// recognise collapsed into one opaque `staff_gateway_setup_failed` 500, and
// the real message was only ever written to the server console. Three of the
// raises that RPC actually performs — STAFF_AUTH_IDENTITY_MISMATCH,
// INVALID_STAFF_BRANCH and INVALID_STAFF_USERNAME — were unrecognised, so the
// most likely underlying failure presented to the operator as a generic
// message that named no cause. Diagnosing it required pulling Edge Function
// logs out of the Supabase Dashboard by hand.
//
// Every code the RPC can raise is mapped here instead, so the app names the
// actual cause on its own. Kept free of Deno globals and side effects so it
// can be unit-tested directly (see tools/test/staff_error_mapping_test.mjs).
//
// The console.error() calls stay in the caller: this module only decides what
// the client is told.

/** A client-facing failure: a stable code plus the HTTP status to send. */
export interface StaffGatewayFailure {
  code: string;
  status: number;
}

/** Longest detail string echoed back to the client. */
const MAX_DETAIL_LENGTH = 300;

/**
 * Bounds the server detail echoed to the client.
 *
 * The endpoint is CEO-gated, so the operator is trusted, but an unbounded
 * error string is still not something to render in a UI: a very long Postgres
 * message would wreck the dialog layout. Newlines are collapsed too — the
 * message is shown inline, not in a multiline field.
 */
export function truncateDetail(detail: string | null | undefined): string | undefined {
  const text = (detail ?? "").replace(/\s+/g, " ").trim();
  if (!text) return undefined;
  return text.length > MAX_DETAIL_LENGTH
    ? `${text.slice(0, MAX_DETAIL_LENGTH)}…`
    : text;
}

/**
 * Maps a create_staff_gateway RPC error message to a client-facing failure.
 *
 * Matched by substring because the RPC raises with a bare code and Postgres
 * prefixes it with context (e.g. `ERROR: STAFF_USERNAME_TAKEN`), so an
 * equality check would never fire.
 *
 * The fallthrough keeps the historical generic code, so a client that has not
 * yet been updated still renders something sensible.
 */
export function mapStaffGatewayRpcError(
  message: string | null | undefined,
): StaffGatewayFailure {
  const text = message ?? "";
  if (text.includes("STAFF_USERNAME_TAKEN")) {
    return { code: "staff_username_taken", status: 409 };
  }
  if (text.includes("SUPER_ADMIN_ALREADY_EXISTS")) {
    return { code: "super_admin_already_exists", status: 409 };
  }
  if (text.includes("ONLY_CEO")) {
    return { code: "only_ceo_can_create_staff_gateway", status: 403 };
  }
  // The auth row exists but its email does not match the address the SQL twin
  // derived, so the staff/staff_credentials rows were not written. A backend
  // linkage defect, not user error — hence a 5xx with its own code so it is
  // never mistaken for the generic catch-all.
  if (text.includes("STAFF_AUTH_IDENTITY_MISMATCH")) {
    return { code: "staff_auth_identity_mismatch", status: 500 };
  }
  if (text.includes("INVALID_STAFF_USERNAME")) {
    return { code: "invalid_username", status: 400 };
  }
  if (text.includes("INVALID_STAFF_BRANCH")) {
    return { code: "invalid_staff_branch", status: 400 };
  }
  return { code: "staff_gateway_setup_failed", status: 500 };
}

/**
 * Maps a trust_staff_gateway_email failure.
 *
 * Kept separate from the RPC map because it has a single raise of its own
 * (STAFF_TRUST_DOMAIN_NOT_ALLOWED) and no shared codes — conflating the two
 * would report a trust problem as a create problem.
 */
export function mapStaffTrustError(
  message: string | null | undefined,
): StaffGatewayFailure {
  const text = message ?? "";
  if (text.includes("STAFF_TRUST_DOMAIN_NOT_ALLOWED")) {
    return { code: "staff_gateway_domain_not_allowed", status: 500 };
  }
  return { code: "staff_gateway_setup_failed", status: 500 };
}
