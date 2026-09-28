// POST /provider-approval
// Body: { provider_id, action: 'APPROVE'|'REJECT'|'REQUEST_CORRECTION'|'SUSPEND'|'UNSUSPEND', reason? }
import { corsHeaders, requireRole, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { user } = await requireRole(req, "ADMIN");
    const { provider_id, action, reason } = await req.json();
    if (!provider_id || !action) return json({ error: "provider_id and action required" }, 400);

    const admin = getAdminClient();
    let data, error;

    if (action === "APPROVE") {
      ({ data, error } = await admin.rpc("approve_provider", {
        p_provider_id: provider_id,
        p_admin_id: user.id,
      }));
    } else if (action === "REJECT") {
      if (!reason) return json({ error: "reason is required for rejection" }, 400);
      ({ data, error } = await admin.rpc("reject_provider", {
        p_provider_id: provider_id,
        p_admin_id: user.id,
        p_reason: reason,
      }));
    } else if (action === "REQUEST_CORRECTION") {
      if (!reason) return json({ error: "reason is required for correction request" }, 400);
      ({ data, error } = await admin.rpc("request_correction_provider", {
        p_provider_id: provider_id,
        p_admin_id: user.id,
        p_reason: reason,
      }));
    } else if (action === "SUSPEND") {
      ({ data, error } = await admin.rpc("suspend_provider", {
        p_provider_id: provider_id,
        p_admin_id: user.id,
        p_reason: reason ?? null,
      }));
    } else if (action === "UNSUSPEND") {
      ({ data, error } = await admin.rpc("unsuspend_provider", {
        p_provider_id: provider_id,
        p_admin_id: user.id,
      }));
    } else {
      return json({ error: "Unsupported action" }, 400);
    }

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ provider: data });
  } catch (e) {
    return handleCatch(e, "provider-approval:approve");
  }
});
