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

  // 3. Action dispatch.
  let body: { action?: string; user_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const targetId = (body.user_id ?? "").trim();
  if (!targetId) return json({ error: "user_id_required" }, 400);

  if (body.action === "delete_user") {
    // Guard rails: never delete yourself, and never delete another true
    // ADMIN (the admin tier is fixed and external — admins are never
    // removed through this system).
    if (targetId === user.id) return json({ error: "cannot_delete_self" }, 400);
    const { data: targetRoles, error: tErr } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", targetId)
      .eq("role", "ADMIN")
      .limit(1);
    if (tErr) return json({ error: "role_check_failed" }, 500);
    if (targetRoles && targetRoles.length > 0) {
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
    return json({ ok: true });
  }

  return json({ error: "unknown_action" }, 400);
});
