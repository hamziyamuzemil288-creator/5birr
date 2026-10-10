// Edge Function: the ONE way an administrator's image delete removes the FILE.
//
// WHY THE FILE CANNOT BE REMOVED IN SQL
// -------------------------------------
// `delete_gallery_image`-style SQL is fine for the app's OWN rows, but a
// storage object cannot be removed by a statement. Supabase installs a guard on
// `storage.objects` that refuses a direct DELETE with
//   P0001: Direct deletion from storage tables is not allowed.
//           Use the Storage API instead.
// and it refuses it for EVERY role, including a SECURITY DEFINER function
// running as the owner — the guard is a statement-level trigger, not a
// privilege check. Even where a direct DELETE is forced through, it only
// removes the metadata row and leaves the underlying file orphaned in the
// bucket. The Storage API is the only correct path, and the client cannot use
// it: every image bucket's delete policy is owner-scoped
// (`auth.uid()::text = (string_to_array(name,'/'))[1]`), so an administrator
// removing somebody else's object is refused by RLS.
//
// So the split is:
//   * the FILE — this function, through the Storage API with the service role,
//     which both satisfies the guard and bypasses the owner-only RLS;
//   * the ROW and the audit record — `admin_moderate_image`, called with the
//     CALLER's own JWT so its `is_admin()` gate and its row deletes stay the
//     server-side authority (a client that deleted `vehicle_images` directly
//     would be writing a table the database declares server-only).
//
// ORDER MATTERS. The row is deleted FIRST. If the file removal then fails, the
// image is already gone from the app and the bucket merely holds an orphan —
// invisible to every user. Doing it the other way round would remove the file
// first and, on any RPC failure, leave a row pointing at a file that is gone,
// which renders as a broken image to buyers.
//
// No new secrets: the built-in SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY /
// SUPABASE_ANON_KEY injected by the Edge runtime.
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

// The buckets `admin_moderate_image` will accept. Restated here so a crafted
// request cannot be used to probe a bucket the server would refuse anyway, and
// so the refusal is a clear sentence rather than a raw server code.
const MODERABLE_BUCKETS = [
  "provider-photos",
  "provider-gallery",
  "product-images",
  "vehicle-images",
  "profile-avatars",
];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // 1. Authenticate the CALLER with their own JWT (never the service role).
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } },
  );
  const { data: { user }, error: userErr } = await userClient.auth.getUser();
  if (userErr || !user) return json({ error: "UNAUTHORIZED" }, 401);

  // 2. The caller must be an administrator, checked server-side against the
  //    same definition the RPC uses — the UI gate is convenience, not security.
  const { data: isAdmin, error: adminErr } = await userClient.rpc("is_admin");
  if (adminErr) return json({ error: "ADMIN_CHECK_FAILED" }, 500);
  if (isAdmin !== true) return json({ error: "FORBIDDEN" }, 403);

  // 3. The request.
  let body: { bucket?: string; path?: string; reason?: string; severity?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "INVALID_JSON" }, 400);
  }
  const bucket = (body.bucket ?? "").trim();
  const path = (body.path ?? "").trim();
  const reason = (body.reason ?? "").trim();
  const severity = (body.severity ?? "SERIOUS").trim() || "SERIOUS";

  if (!MODERABLE_BUCKETS.includes(bucket)) {
    return json({ error: "THAT_BUCKET_IS_NOT_MODERABLE" }, 400);
  }
  if (!path) return json({ error: "A_PATH_IS_REQUIRED" }, 400);
  if (reason.length < 3) return json({ error: "A_REASON_IS_REQUIRED" }, 400);

  // 4. The row + the audit record, through the RPC the caller is allowed to
  //    call. It runs as the administrator and writes `moderation_actions`, so
  //    the takedown keeps its record even though the file moves out of SQL.
  const { data: rpcResult, error: rpcErr } = await userClient.rpc(
    "admin_moderate_image",
    {
      p_bucket: bucket,
      p_path: path,
      p_reason: reason,
      p_severity: severity,
    });
  if (rpcErr) {
    // The RPC's own refusals are what the admin can act on, so they are passed
    // through verbatim (friendly_error maps NO_ROW…/THAT_BUCKET…/the rest).
    return json({ error: rpcErr.message }, 400);
  }

  // 5. The file, through the Storage API with the service role. This is the
  //    call the storage guard's own message points at, and the service role is
  //    the only caller allowed to remove another account's object.
  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );
  const { error: storageErr } = await admin.storage.from(bucket).remove([path]);
  if (storageErr) {
    // The visible outcome the admin asked for has already happened (the row is
    // gone); only the bucket still holds the file. Say so rather than claiming
    // a total failure that would invite a retry ending in NO_ROW_REFERENCES…
    console.error("admin-image-delete: storage remove failed", storageErr.message);
    return json({
      ok: true,
      storage_removed: false,
      message:
        "The image was removed, but the stored file could not be cleaned up. It is not visible anywhere.",
      removed_from: rpcResult,
    });
  }

  return json({
    ok: true,
    storage_removed: true,
    message: "Image removed.",
    removed_from: rpcResult,
  });
});
