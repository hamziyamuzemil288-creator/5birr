// POST /ride-claim
// Body: { ride_id, provider_id, vehicle_id }
// Wraps claim_ride() SECURITY DEFINER SQL function. Only ONE concurrent
// caller can succeed for a given ride_id — enforced at the DB layer via
// a conditional UPDATE ... WHERE status = 'REQUESTED', not here.
import { corsHeaders, requireRole, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { user } = await requireRole(req, "VEHICLE_PROVIDER");
    const { ride_id, provider_id, vehicle_id } = await req.json();

    if (!ride_id || !provider_id || !vehicle_id) {
      return json({ error: "ride_id, provider_id, vehicle_id are required" }, 400);
    }

    const admin = getAdminClient();

    // Confirm the provider_id actually belongs to the calling user —
    // never trust the client-supplied provider_id blindly.
    const { data: provider } = await admin
      .from("provider_profiles")
      .select("id")
      .eq("id", provider_id)
      .eq("user_id", user.id)
      .single();
    if (!provider) return json({ error: "PROVIDER_MISMATCH" }, 403);

    const { data, error } = await admin.rpc("claim_ride", {
      p_ride_id: ride_id,
      p_provider_id: provider_id,
      p_vehicle_id: vehicle_id,
    });

    if (error) {
      const msg = sanitizeError(error.message);
      const code = msg.includes("RIDE_ALREADY_TAKEN") ? 409 : 400;
      return json({ error: msg }, code);
    }

    return json({ ride: data });
  } catch (e) {
    return handleCatch(e, "ride-claim:claim");
  }
});
