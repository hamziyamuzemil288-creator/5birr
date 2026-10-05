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

    // Pick the RPC by the request's recorded source so the same admin
    // approve/reject endpoint works for the existing admin-cash path and for
    // the new provider-funded path (20261005000001).
    //
    // Legacy rows have source NULL (no recorded source) and must still go
    // through the original approve_wallet_recharge / reject_wallet_recharge,
    // which are the only RPCs that know about the registration-fee/activation
    // branch (0038). Providers-funded rows go through the new pair, which
    // credits in full and does not touch registration_fee_paid.
    if (action === "approve") {
      const row = await admin
        .from("wallet_recharge_requests")
        .select("source")
        .eq("id", recharge_id)
        .maybeSingle();

      if (row?.source === "PROVIDER_PAYMENT_METHOD") {
        ({ data, error } = await admin.rpc("approve_provider_wallet_funding", {
          p_recharge_id: recharge_id,
          p_admin_id: user.id,
        }));
      } else {
        ({ data, error } = await admin.rpc("approve_wallet_recharge", {
          p_recharge_id: recharge_id,
          p_admin_id: user.id,
        }));
      }
    } else if (action === "reject") {
      if (!reason) return json({ error: "reason required for rejection" }, 400);

      const row = await admin
        .from("wallet_recharge_requests")
        .select("source")
        .eq("id", recharge_id)
        .maybeSingle();

      if (row?.source === "PROVIDER_PAYMENT_METHOD") {
        ({ data, error } = await admin.rpc("reject_provider_wallet_funding", {
          p_recharge_id: recharge_id,
          p_admin_id: user.id,
          p_reason: reason,
        }));
      } else {
        ({ data, error } = await admin.rpc("reject_wallet_recharge", {
          p_recharge_id: recharge_id,
          p_admin_id: user.id,
          p_reason: reason,
        }));
      }
    } else {
      return json({ error: "Unsupported action" }, 400);
    }

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ recharge: data });
  } catch (e) {
    return handleCatch(e, "admin-wallet-recharge:recharge");
  }
});
