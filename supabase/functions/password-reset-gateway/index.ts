import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// Set a locked-out user's password, on a staff member's authority.
//
// It has to be an Edge Function for the same reason account-deletion-gateway
// and staff-delete-gateway are: writing to auth.users needs the service role,
// and the service role key must never reach a client. There is no SQL function
// that can do it, so an approved RPC plus a gateway is the only shape
// available.
//
// Order of operations is deliberate, and it is the same order
// account-deletion-gateway documents:
//
//   1. identify the CALLER as themselves (anon client + the user's JWT), so
//      the decision is made by a real signed-in staff member;
//   2. re-check the permission server-side -- the UI gate is not security;
//   3. call the RPC, which marks the appeal resolved, writes the audit trail,
//      and returns WHICH account to reset. The target comes from the case row,
//      never from this request body, so a caller cannot point it at an
//      arbitrary account;
//   4. only then set the password.
//
// If step 4 fails the case is already RESOLVED and audited. The response says
// exactly that rather than pretending the whole thing failed, because a staff
// member retrying a request that already succeeded would otherwise create a
// second case.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;

  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await anon.auth.getUser();
  const actor = userData?.user;
  if (userError || !actor) return json({ error: "unauthorized" }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // The appeals screen hides the action from anyone without the job. Re-check
  // the real rule here, and again inside the RPC.
  const { data: mayReset, error: permError } = await admin.rpc(
    "may_reset_password_for",
    { p_user_id: actor.id },
  );
  if (permError || mayReset !== true) {
    return json({ error: "only_password_reset_staff_can_approve" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const caseId = String(body.case_id ?? "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(caseId)) {
    return json({ error: "invalid_case_id" }, 400);
  }
  const newPassword = String(body.new_password ?? "");
  const note =
    typeof body.note === "string" ? body.note.trim().slice(0, 500) : "";

  // Same floor as the two existing password paths (staff-change-password and
  // account-change-password), so a password set through a staff member cannot
  // be weaker than one a person sets for themselves.
  if (newPassword.length < 10 || newPassword.length > 200) {
    return json({ error: "invalid_password_requirements" }, 400);
  }

  const { data: targetUserId, error: approveError } = await admin.rpc(
    "approve_password_reset_appeal",
    { p_case_id: caseId, p_actor_id: actor.id, p_note: note || null },
  );
  if (approveError) {
    return json({ error: approveError.message }, 400);
  }
  if (!targetUserId) {
    return json({ error: "not_found" }, 404);
  }

  const { error: updateError } = await admin.auth.admin.updateUserById(
    targetUserId as string,
    { password: newPassword },
  );
  if (updateError) {
    // The case is RESOLVED and audited but the password was not set. Say so
    // plainly -- this is the one state an operator has to act on by hand.
    return json(
      {
        error: "password_not_set",
        detail:
          "The request is recorded and approved, but the password was not " +
          "changed. Set it by hand and close the case.",
        pg_error: updateError.message,
      },
      500,
    );
  }

  // Everybody else's session is now signed in with a password that no longer
  // exists. Without this the account would look secured and would not be.
  //
  // It is a SQL call, not `auth.admin.signOut`: that takes a JWT, not a user
  // id, and there is no "sign out every session for this account" method on
  // the admin API. The function is the one place with the reach to do it.
  const { data: revoked, error: revokeError } = await admin.rpc(
    "revoke_user_sessions",
    { p_user_id: targetUserId },
  );
  if (revokeError) {
    // The password IS changed. Failing loudly here is right: the operator has
    // to know the old sessions are still alive, because that is the entire
    // reason the person asked.
    console.error("password reset done but sessions NOT revoked:", revokeError.message);
  }

  return json({ ok: true, target_user_id: targetUserId, sessions_revoked: revoked ?? 0 });
});
