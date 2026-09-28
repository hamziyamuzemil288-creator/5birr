// POST /admin-wallet-recharge
// Body: { action: 'approve'|'reject', recharge_id, reason? }
// Admin-only endpoint for approving/rejecting wallet recharge requests.
import { corsHeaders, requireRole, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { user } = await requireRole(req, "ADMIN");
    const { action, recharge_id, reason } = await req.json();

    if (!action || !recharge_id) {
      return json({ error: "action and recharge_id required" }, 400);
    }

    const admin = getAdminClient();
    let data, error;

    if (action === "approve") {
      ({ data, error } = await admin.rpc("approve_wallet_recharge", {
        p_recharge_id: recharge_id,
        p_admin_id: user.id,
      }));
    } else if (action === "reject") {
      if (!reason) return json({ error: "reason required for rejection" }, 400);
      ({ data, error } = await admin.rpc("reject_wallet_recharge", {
        p_recharge_id: recharge_id,
        p_admin_id: user.id,
        p_reason: reason,
      }));
    } else {
      return json({ error: "Unsupported action" }, 400);
    }

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ recharge: data });
  } catch (e) {
    return handleCatch(e, "admin-wallet-recharge:recharge");
  }
});
