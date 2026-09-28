// POST /order-transition
// Body: { order_id, new_status, note? }
// Validates caller is either the order's user, the owning provider, or admin,
// then delegates to transition_order_status() which enforces the whitelist
// of legal transitions and the payment-proof requirement server-side.
import { corsHeaders, requireUser, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { user } = await requireUser(req);
    const { order_id, new_status, note } = await req.json();
    if (!order_id || !new_status) return json({ error: "order_id and new_status required" }, 400);

    const admin = getAdminClient();

    const { data: order } = await admin
      .from("orders")
      .select("id, user_id, provider_id, provider_profiles!inner(user_id)")
      .eq("id", order_id)
      .single();

    if (!order) return json({ error: "ORDER_NOT_FOUND" }, 404);

    const isOwnerUser = order.user_id === user.id;
    // @ts-ignore joined shape
    const isOwnerProvider = order.provider_profiles?.user_id === user.id;

    const { data: roles } = await admin.from("user_roles").select("role").eq("user_id", user.id);
    const isAdmin = (roles ?? []).some((r: { role: string }) => r.role === "ADMIN");

    if (!isOwnerUser && !isOwnerProvider && !isAdmin) {
      return json({ error: "FORBIDDEN" }, 403);
    }

    const { data, error } = await admin.rpc("transition_order_status", {
      p_order_id: order_id,
      p_new_status: new_status,
      p_actor: user.id,
      p_note: note ?? null,
    });

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ order: data });
  } catch (e) {
    return handleCatch(e, "order-transition:transition");
  }
});
