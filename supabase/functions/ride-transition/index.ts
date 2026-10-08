// POST /ride-transition
// Body: { ride_id, new_status, actor_id }
// Validates caller authorization for ride status transitions.
import { corsHeaders, requireUser, getAdminClient, json, sanitizeError } from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { user } = await requireUser(req);
    const { ride_id, new_status, actor_id } = await req.json();

    if (!ride_id || !new_status) {
      return json({ error: "ride_id and new_status required" }, 400);
    }

    const admin = getAdminClient();

    // Fetch the ride
    const { data: ride } = await admin
      .from("ride_requests")
      .select("id, user_id, claimed_by_provider_id, status")
      .eq("id", ride_id)
      .single();

    if (!ride) return json({ error: "RIDE_NOT_FOUND" }, 404);

    // Authorization check
    const isOwner = ride.user_id === user.id;
    const isClaimedDriver = ride.claimed_by_provider_id != null;

    // Verify driver ownership if driver action
    if (isClaimedDriver) {
      const { data: provider } = await admin
        .from("provider_profiles")
        .select("id")
        .eq("id", ride.claimed_by_provider_id)
        .eq("user_id", user.id)
        .single();
      if (!provider && !isOwner) {
        return json({ error: "FORBIDDEN" }, 403);
      }
    }

    // Role-based transition validation
    const { data: roles } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id);
    const isAdmin = (roles ?? []).some((r: { role: string }) => r.role === "ADMIN");

    // Validate transition authorization
    let allowed = false;
    if (isAdmin) {
      allowed = true;
    } else if (isOwner) {
      // The rider may cancel any time before the trip starts. This list is
      // deliberately the same one the rider's screen offers its CANCEL button
      // from (REQUESTED / CLAIMED / DRIVER_ARRIVING): it used to stop at
      // CLAIMED, so a rider who cancelled while the driver was on the way got
      // 403 FORBIDDEN — "You do not have permission to do that" — for the one
      // action the screen had just told them was available.
      if (
        new_status === "CANCELLED" &&
        ["REQUESTED", "CLAIMED", "DRIVER_ARRIVING"].includes(ride.status)
      ) {
        allowed = true;
      }
    } else if (isClaimedDriver) {
      // Driver can progress through states
      const driverTransitions: Record<string, string[]> = {
        "CLAIMED": ["DRIVER_ARRIVING", "CANCELLED"],
        "DRIVER_ARRIVING": ["ARRIVED", "CANCELLED"],
        "ARRIVED": ["TRIP_STARTED"],
        "TRIP_STARTED": ["COMPLETED"],
      };
      allowed = driverTransitions[ride.status]?.includes(new_status) ?? false;
    }

    if (!allowed) {
      return json({ error: "FORBIDDEN" }, 403);
    }

    // Call the SQL transition function
    const { data, error } = await admin.rpc("transition_ride_status", {
      p_ride_id: ride_id,
      p_new_status: new_status,
      p_actor: user.id,
    });

    if (error) return json({ error: sanitizeError(error.message) }, 400);
    return json({ ride: data });
  } catch (e) {
    return handleCatch(e, "ride-transition:transition");
  }
});
