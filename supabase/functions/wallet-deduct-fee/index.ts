// POST /wallet-deduct-fee
// Body: { provider_id, order_id?, ride_id?, gross_amount, idempotency_key }
// Manual/administrative trigger for the platform transaction fee. In normal
// flow the fee is deducted automatically inside transition_order_status()
// and transition_ride_status() — this endpoint exists for admin corrections,
// n8n-triggered retries, and out-of-band charges. Idempotent by design.
import { corsHeaders, requireRole, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    await requireRole(req, "ADMIN");
    const { provider_id, order_id, ride_id, gross_amount, idempotency_key } = await req.json();

    if (!provider_id || !idempotency_key) {
      return json({ error: "provider_id and idempotency_key are required" }, 400);
    }

    const admin = getAdminClient();
    const { data, error } = await admin.rpc("deduct_transaction_fee", {
      p_provider_id: provider_id,
      p_order_id: order_id ?? null,
      p_ride_id: ride_id ?? null,
      p_gross_amount: gross_amount ?? 0,
      p_idempotency_key: idempotency_key,
    });

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ transaction: data });
  } catch (e) {
    return handleCatch(e, "wallet-deduct-fee:deduct");
  }
});
