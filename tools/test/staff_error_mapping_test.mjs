// Runs the REAL error mapping the Edge Function ships, not a copy of it.
//
// WHY THIS EXISTS
// ---------------
// staff-create-gateway returned one opaque `staff_gateway_setup_failed` 500
// for every failure its error switch did not recognise, and the real cause
// only ever reached the server console. That made STAFF_AUTH_IDENTITY_MISMATCH
// — the most likely cause — undiagnosable without the Supabase Dashboard. The
// mapping now lives in _shared/staff_errors.ts so every raise is nameable.
//
// This test imports that module directly: a copy would drift from the
// function and keep passing while the real thing stayed broken, which is the
// entire bug class this file exists to prevent.
//
// Run: node --experimental-strip-types tools/test/staff_error_mapping_test.mjs
import {
  mapStaffGatewayRpcError,
  mapStaffTrustError,
  truncateDetail,
} from "../../supabase/functions/_shared/staff_errors.ts";

let failures = 0;
let checks = 0;

function check(label, actual, expected) {
  checks += 1;
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    console.log(`  ok  ${label}`);
  } else {
    failures += 1;
    console.log(`FAIL  ${label}\n        expected ${e}\n        actual   ${a}`);
  }
}

console.log("--- create_staff_gateway raises map to distinct codes ---");
// Each of these is a raise the RPC can actually perform
// (supabase/migrations/20260925170000_staff_email_identity.sql).
check("STAFF_USERNAME_TAKEN", mapStaffGatewayRpcError("STAFF_USERNAME_TAKEN"),
  { code: "staff_username_taken", status: 409 });
check("SUPER_ADMIN_ALREADY_EXISTS", mapStaffGatewayRpcError("SUPER_ADMIN_ALREADY_EXISTS"),
  { code: "super_admin_already_exists", status: 409 });
check("ONLY_CEO", mapStaffGatewayRpcError("ONLY_CEO_CAN_CREATE_STAFF_GATEWAY"),
  { code: "only_ceo_can_create_staff_gateway", status: 403 });

console.log("--- the three that used to hide behind the generic 500 ---");
check("STAFF_AUTH_IDENTITY_MISMATCH", mapStaffGatewayRpcError("STAFF_AUTH_IDENTITY_MISMATCH"),
  { code: "staff_auth_identity_mismatch", status: 500 });
check("INVALID_STAFF_BRANCH", mapStaffGatewayRpcError("INVALID_STAFF_BRANCH"),
  { code: "invalid_staff_branch", status: 400 });
check("INVALID_STAFF_USERNAME", mapStaffGatewayRpcError("INVALID_STAFF_USERNAME"),
  { code: "invalid_username", status: 400 });

console.log("--- Postgres prefixes raises with context, so match by substring ---");
check("prefixed ERROR: line", mapStaffGatewayRpcError("ERROR:  STAFF_AUTH_IDENTITY_MISMATCH"),
  { code: "staff_auth_identity_mismatch", status: 500 });
check("CONTEXT: line", mapStaffGatewayRpcError("CONTEXT:  PL/pgSQL function create_staff_gateway() line 99 at RAISE"),
  { code: "staff_gateway_setup_failed", status: 500 });

console.log("--- unknown failures keep the historical generic code ---");
check("unrecognised message", mapStaffGatewayRpcError("something else entirely"),
  { code: "staff_gateway_setup_failed", status: 500 });
check("null message", mapStaffGatewayRpcError(null),
  { code: "staff_gateway_setup_failed", status: 500 });
check("undefined message", mapStaffGatewayRpcError(undefined),
  { code: "staff_gateway_setup_failed", status: 500 });

console.log("--- trust site maps separately, never as a create problem ---");
check("domain not allowed", mapStaffTrustError("STAFF_TRUST_DOMAIN_NOT_ALLOWED: x@y.com"),
  { code: "staff_gateway_domain_not_allowed", status: 500 });
check("unknown trust failure", mapStaffTrustError("connection reset"),
  { code: "staff_gateway_setup_failed", status: 500 });

console.log("--- detail is bounded and single-line ---");
check("short detail passes through", truncateDetail("STAFF_USERNAME_TAKEN"), "STAFF_USERNAME_TAKEN");
check("newlines collapse", truncateDetail("line one\n   line two"), "line one line two");
check("whitespace-only is dropped", truncateDetail("   \n  "), undefined);
check("null is dropped", truncateDetail(null), undefined);
const long = "x".repeat(500);
check("long detail is truncated", truncateDetail(long).length, 301);
check("truncation is marked", truncateDetail(long).endsWith("…"), true);

console.log(
  failures === 0
    ? `\nALL ${checks} CHECKS PASSED`
    : `\n${failures}/${checks} CHECKS FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
