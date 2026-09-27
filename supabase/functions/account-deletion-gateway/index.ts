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

// Approve a pending account-deletion request and actually remove the account.
//
// It has to be an Edge Function rather than a direct client call for the same
// reason staff-delete-gateway is one: public.delete_user_account is granted to
// service_role only, and deleting an auth.users row needs the service role key,
// which must never reach a client.
//
// Order of operations is deliberate and is the same order the SQL documents:
//
//   1. identify the CALLER as themselves (anon client + the user's JWT), so the
//      decision is made by a real signed-in staff member;
//   2. re-check the permission server-side -- the UI gate is not security;
//   3. mark the request APPROVED and record who decided, BEFORE anything is
//      deleted, so a failure below leaves a visible, retryable audit trail
//      rather than a silently-lost request;
//   4. run the cascade, which drops the CASCADE tables (profiles, roles,
//      provider profile and its dependants, documents, favourites,
//      notifications) and detaches the record tables (orders, rides, reviews,
//      the audit trail) via the ON DELETE SET NULL FKs added in 20260927000054;
//   5. remove the GoTrue auth row.
//
// If step 5 fails after step 4, the person can no longer sign in and the
// request reads APPROVED, so the response says exactly that rather than
// pretending the whole thing failed.
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

  // The UI hides this action from anyone without the job. Re-check the real
  // rule here, and again inside public.approve_account_deletion.
  const { data: mayDecide, error: decideError } = await admin.rpc(
    "may_decide_account_deletion_for",
    { p_user_id: actor.id },
  );
  if (decideError || mayDecide !== true) {
    return json({ error: "only_staff_with_permission_can_approve" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const requestId = String(body.request_id ?? "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(requestId)) {
    return json({ error: "invalid_request_id" }, 400);
  }
  const note =
    typeof body.note === "string" && body.note.trim() !== ""
      ? body.note.trim()
      : null;

  // Read the request first so a bad id, an already-decided request, or a
  // missing account is reported precisely and nothing is touched.
  const { data: request, error: requestError } = await admin
    .from("account_deletion_requests")
    .select("id, user_id, status, reason")
    .eq("id", requestId)
    .maybeSingle();
  if (requestError) return json({ error: "lookup_failed" }, 500);
  if (!request) return json({ error: "request_not_found" }, 404);
  if (request.status !== "PENDING") {
    return json({ error: "already_decided", status: request.status }, 409);
  }

  const { data: target, error: targetError } = await admin
    .from("profiles")
    .select("id, full_name")
    .eq("id", request.user_id as string)
    .maybeSingle();
  if (targetError) return json({ error: "lookup_failed" }, 500);
  if (!target) return json({ error: "user_not_found" }, 404);

  // Record the decision first. If the cascade below fails, the audit trail and
  // the APPROVED status still stand, so a staff member can retry.
  const { error: approveError } = await admin.rpc("approve_account_deletion", {
    p_request_id: requestId,
    p_actor_id: actor.id,
    p_note: note,
  });
  if (approveError) {
    const msg = approveError.message ?? "";
    if (msg.includes("ALREADY_DECIDED")) {
      return json({ error: "already_decided" }, 409);
    }
    if (msg.includes("NOT_FOUND")) {
      return json({ error: "request_not_found" }, 404);
    }
    if (msg.includes("ONLY_ADMINISTRATORS")) {
      return json({ error: "only_staff_with_permission_can_approve" }, 403);
    }
    console.error("approve_account_deletion failed:", msg);
    return json({ error: "approval_failed" }, 500);
  }

  // The cascade. p_actor_id is passed EXPLICITLY: this is a service-role call
  // with no end-user JWT, so auth.uid() would be NULL inside the function and
  // the permission check could never pass. Mirrors delete_staff.
  const { data: result, error: deleteError } = await admin.rpc("delete_user_account", {
    p_actor_id: actor.id,
    p_target_user_id: request.user_id as string,
  });
  if (deleteError) {
    const msg = deleteError.message ?? "";
    if (msg.includes("CANNOT_DELETE_CEO")) {
      return json({ error: "cannot_delete_ceo" }, 403);
    }
    if (msg.includes("USER_NOT_FOUND")) {
      return json({ error: "user_not_found" }, 404);
    }
    if (msg.includes("ONLY_ADMINISTRATORS_CAN_DELETE_ACCOUNTS")) {
      return json({ error: "only_staff_with_permission_can_approve" }, 403);
    }
    console.error("delete_user_account failed:", msg);
    return json({ error: "delete_failed", approved: true }, 500);
  }

  const deleted = (result ?? {}) as {
    deleted_user_id?: string;
    full_name?: string;
    orders_retained?: number;
    provider_profiles_retained?: number;
  };

  // The data is already gone by this point (profiles cascaded), so a failure
  // here only leaves an orphaned login that can no longer reach anything.
  // Report it plainly so it can be cleaned from the dashboard.
  const { error: authError } = await admin.auth.admin.deleteUser(
    request.user_id as string,
  );
  if (authError) {
    console.error("auth user deletion failed:", authError.message);
    return json(
      {
        error: "auth_user_delete_failed",
        approved: true,
        data_deleted: true,
        user_id: deleted.deleted_user_id ?? request.user_id,
      },
      500,
    );
  }

  return json({
    ok: true,
    deleted: {
      user_id: deleted.deleted_user_id ?? request.user_id,
      full_name: deleted.full_name ?? target.full_name,
      // Surfaced so the staff member can see what was kept, not destroyed.
      orders_retained: deleted.orders_retained ?? 0,
      provider_profiles_retained: deleted.provider_profiles_retained ?? 0,
    },
  });
});
