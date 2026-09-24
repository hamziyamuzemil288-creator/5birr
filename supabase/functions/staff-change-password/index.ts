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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData.user) return json({ error: "unauthorized" }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: staff, error: staffError } = await admin
    .from("staff")
    .select("id, is_active")
    .eq("user_id", userData.user.id)
    .maybeSingle();
  if (staffError || !staff?.is_active) return json({ error: "staff_inactive" }, 403);

  let body: { current_password?: unknown; new_password?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const currentPassword = String(body.current_password ?? "");
  const newPassword = String(body.new_password ?? "");
  if (currentPassword.length < 1 || currentPassword.length > 200 ||
      newPassword.length < 10 || newPassword.length > 200) {
    return json({ error: "invalid_password_requirements" }, 400);
  }

  const email = userData.user.email ?? "";
  const { error: currentError } = await userClient.auth.signInWithPassword({
    email,
    password: currentPassword,
  });
  if (currentError) return json({ error: "current_password_incorrect" }, 401);

  const { error: updateError } = await userClient.auth.updateUser({
    password: newPassword,
  });
  if (updateError) return json({ error: "password_change_failed" }, 400);
  return json({ ok: true });
});
