import { createClient } from "npm:@supabase/supabase-js@2";
import {
  cleanUsername,
  isValidUsername,
  syntheticStaffEmail,
} from "../_shared/staff_identity.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// Must mirror staff-create-gateway exactly — see _shared/staff_identity.ts.

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { username?: unknown; password?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const username = cleanUsername(body.username);
  const password = String(body.password ?? "");
  if (!isValidUsername(username) || password.length < 1 || password.length > 200) {
    return json({ error: "invalid_credentials" }, 401);
  }

  const url = Deno.env.get("SUPABASE_URL")!;
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data: credential, error: lookupError } = await admin
    .from("staff_credentials")
    .select("user_id, staff_id, locked_until, staff:staff_id(is_active)")
    .eq("username", username)
    .maybeSingle();
  if (lookupError) return json({ error: "login_unavailable" }, 503);

  const staff = credential?.staff as { is_active?: boolean } | null;
  if (!credential || !staff?.is_active ||
      (credential.locked_until && new Date(credential.locked_until).getTime() > Date.now())) {
    return json({ error: "invalid_credentials" }, 401);
  }

  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: signIn, error: signInError } = await userClient.auth.signInWithPassword({
    email: await syntheticStaffEmail(username),
    password,
  });
  if (signInError || !signIn.session || signIn.user?.id !== credential.user_id) {
    await admin.rpc("staff_gateway_record_login", {
      p_username: username,
      p_success: false,
    });
    return json({ error: "invalid_credentials" }, 401);
  }

  await admin.rpc("staff_gateway_record_login", {
    p_username: username,
    p_success: true,
  });

  return json({
    access_token: signIn.session.accessToken,
    refresh_token: signIn.session.refreshToken,
    expires_in: signIn.session.expiresIn,
    token_type: signIn.session.tokenType,
    staff_id: credential.staff_id,
    username,
  });
});
