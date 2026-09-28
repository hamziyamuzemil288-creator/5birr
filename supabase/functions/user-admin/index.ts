// Edge Function: true-Admin-only user administration.
//
// delete_user: removes an auth account via the GoTrue admin API. The caller
// must carry the true ADMIN app_role — verified server-side on every request
// (the Flutter gate on the Staff Assignment page is convenience, not
// security). Audited into admin_actions.
//
// No new secrets: uses the built-in SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
// / SUPABASE_ANON_KEY injected by the Edge runtime.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 1. Authenticate the CALLER with their own JWT (never the service role).
  const anon = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user }, error: userErr } = await anon.auth.getUser();
  if (userErr || !user) return json({ error: "unauthorized" }, 401);

  // 2. Verify the caller holds the TRUE ADMIN app_role (server-side check —
  //    the Staff Assignment page's UI gate is convenience only).
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: roles, error: rolesErr } = await admin
    .from("user_roles")
    .select("role")
    .eq("user_id", user.id)
    .eq("role", "ADMIN")
    .limit(1);
  if (rolesErr) return json({ error: "role_check_failed" }, 500);
  if (!roles || roles.length === 0) return json({ error: "forbidden" }, 403);

  // 2b. Is the caller the CEO?
  //
  //  A CEO is an ADMIN who can additionally delete another ADMIN. That single
  //  difference is the whole of the elevated authority, so it is resolved here
  //  and used exactly once, at the guard that would otherwise refuse.
  //
  //  Resolved through the database rather than by reading user_roles here, so
  //  there is one definition of "is the CEO" (public.is_ceo()) instead of two
  //  that can drift. is_ceo() also honours staff.is_super_admin, which that
  //  column already claimed before this feature existed.
  //
  //  A failed check is treated as NOT the CEO. If the lookup breaks, the safe
  //  answer is the narrower authority, never the wider one.
  let callerIsCeo = false;
  {
    const { data: ceoFlag, error: ceoErr } = await anon.rpc("is_ceo");
    if (ceoErr) {
      console.error("is_ceo check failed:", ceoErr.message);
    } else {
      callerIsCeo = ceoFlag === true;
    }
  }

  // 3. Action dispatch.
  let body: { action?: string; user_id?: string; reason?: string; confirm?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const targetId = (body.user_id ?? "").trim();
  if (!targetId) return json({ error: "user_id_required" }, 400);

  if (body.action === "delete_user") {
    // Guard rails: never delete yourself, and never delete another true
    // ADMIN — unless the caller is the CEO, which is the one authority that
    // can. The CEO may still not delete themselves: an account that removes
    // itself cannot be held to account for what it did next, and a company
    // with no CEO is worse than one with a CEO who made a mistake.
    if (targetId === user.id) return json({ error: "cannot_delete_self" }, 400);

    // The confirmation is a deliberate second factor of intent, not
    // decoration: the client must send back the exact target id it means to
    // destroy, so a mis-wired button or a stale screen cannot delete the
    // wrong account. A destructive irreversible action should be impossible
    // to trigger by a single misdirected tap.
    if ((body.confirm ?? "").trim() !== targetId) {
      return json(
        { error: "confirmation_required", detail: "confirm must equal user_id" },
        400,
      );
    }

    const { data: targetRoles, error: tErr } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", targetId);
    if (tErr) return json({ error: "role_check_failed" }, 500);

    const targetIsAdmin = (targetRoles ?? []).some((r) => r.role === "ADMIN");
    const targetIsCeo = (targetRoles ?? []).some((r) => r.role === "CEO");

    // A CEO is not deletable by anyone through this path, including another
    // CEO. Removing the top authority is a decision for the database owner,
    // not for an in-app button, and this keeps it that way.
    if (targetIsCeo) return json({ error: "cannot_delete_ceo" }, 403);

    if (targetIsAdmin && !callerIsCeo) {
      return json({ error: "cannot_delete_admin" }, 403);
    }

    // Detach any staff row first (the link references auth.users; deleting
    // the auth user cascades the row, but deactivating first keeps the
    // audit trail readable and avoids UNIQUE(user_id) surprises).
    await admin
      .from("staff")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .eq("user_id", targetId);

    const { error: delErr } = await admin.auth.admin.deleteUser(targetId);
    if (delErr) {
      console.error("deleteUser failed:", delErr.message);
      return json(
        { error: "delete_failed", detail: delErr.message },
        500,
      );
    }

    await admin.from("admin_actions").insert({
      admin_id: user.id,
      action: "DELETE_USER",
      target_type: "auth_users",
      target_id: targetId,
    });

    // The deletion log the CEO interface reads. admin_history is the existing
    // append-only log and already carries actor, action, city and metadata, so
    // the CEO record lives beside every other admin act rather than in a
    // parallel table nobody looks at.
    //
    // Best-effort on purpose: the account is already gone by this point, and
    // failing the request now would tell the operator the deletion did not
    // happen when it did. The failure is logged loudly instead.
    const { error: histErr } = await admin.from("admin_history").insert({
      actor_id: user.id,
      actor_name: user.email ?? "unknown",
      action_type: targetIsAdmin ? "CEO_DELETE_ADMIN" : "DELETE_USER",
      related_record_id: targetId,
      category: "ACCOUNT_DELETION",
      metadata: {
        reason: (body.reason ?? "").trim() || null,
        caller_was_ceo: callerIsCeo,
        target_was_admin: targetIsAdmin,
        target_roles: (targetRoles ?? []).map((r) => r.role),
      },
    });
    if (histErr) console.error("deletion audit write failed:", histErr.message);

    return json({ ok: true, audited: !histErr, deleted_by_ceo: callerIsCeo });
  }

  return json({ error: "unknown_action" }, 400);
});
