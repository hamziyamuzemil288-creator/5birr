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

// Permanent removal of a staff member.
//
// This is deliberately NOT the same as revoke_staff. Revoking flips
// is_active=false, which is reversible and which staff-login already refuses
// — the account survives and the username stays reserved. This endpoint is
// the "remove this person entirely" path: the staff row, everything
// cascading off it, and the GoTrue account all go.
//
// It has to be an Edge Function rather than a direct client call for two
// reasons: public.delete_staff is granted to service_role only, and deleting
// an auth.users row needs the service role key, which must never reach a
// client. Both concerns are why the RPC refuses to do the auth deletion
// itself.
//
// Revoke remains the default, safer action in the UI; this is behind a typed
// confirmation.
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;

  // Identify the caller as themselves first.
  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await anon.auth.getUser();
  const actor = userData.user;
  if (userError || !actor) return json({ error: "unauthorized" }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // The UI gate is not security. Re-check the true CEO on the server, and
  // re-check it inside public.delete_staff as well.
  const { data: isCeo, error: ceoError } = await admin.rpc("is_ceo", {
    p_user_id: actor.id,
  });
  if (ceoError || isCeo !== true) {
    return json({ error: "only_ceo_can_delete_staff" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const staffId = String(body.staff_id ?? "").trim();
  if (!/^[0-9a-fA-F-]{36}$/.test(staffId)) {
    return json({ error: "invalid_staff_id" }, 400);
  }

  // Confirm the target exists and is not the CEO BEFORE deleting anything, so
  // a rejected request leaves the database untouched and we can return a
  // precise reason to the UI.
  const { data: target, error: targetError } = await admin
    .from("staff")
    .select("id, name, staff_code, is_ceo")
    .eq("id", staffId)
    .maybeSingle();
  if (targetError) return json({ error: "lookup_failed" }, 500);
  if (!target) return json({ error: "staff_not_found" }, 404);
  if (target.is_ceo === true) {
    return json({ error: "cannot_delete_ceo" }, 403);
  }

  // The RPC deletes the staff row and everything cascading off it, and
  // returns the auth user id for the GoTrue cleanup below.
  const { data: result, error: deleteError } = await admin.rpc("delete_staff", {
    p_staff_id: staffId,
  });
  if (deleteError) {
    const msg = deleteError.message ?? "";
    if (msg.includes("CANNOT_DELETE_CEO")) {
      return json({ error: "cannot_delete_ceo" }, 403);
    }
    if (msg.includes("ONLY_CEO_CAN_DELETE_STAFF")) {
      return json({ error: "only_ceo_can_delete_staff" }, 403);
    }
    if (msg.includes("STAFF_NOT_FOUND")) {
      return json({ error: "staff_not_found" }, 404);
    }
    console.error("delete_staff failed:", msg);
    return json({ error: "delete_failed" }, 500);
  }

  // Order matters: the staff row is already gone, so if the auth deletion
  // fails we leave an orphan login that can no longer act as staff, rather
  // than a live staff row whose account we could not remove.
  const authUserId = (result as { auth_user_id?: string | null })?.auth_user_id;
  if (authUserId) {
    const { error: authError } = await admin.auth.admin.deleteUser(authUserId);
    if (authError) {
      // Not fatal: the staff privileges are already gone, so the person can
      // no longer reach anything. Report it so the CEO knows an orphan login
      // may remain and can be cleaned up from the dashboard.
      console.error("auth user deletion failed:", authError.message);
      return json({
        error: "auth_user_delete_failed",
        staff_deleted: true,
        auth_user_id: authUserId,
      }, 500);
    }
  }

  return json({
    ok: true,
    deleted: { staff_id: staffId, name: target.name },
  });
});
