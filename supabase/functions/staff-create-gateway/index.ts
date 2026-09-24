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

const usernamePattern = /^[a-z0-9][a-z0-9._-]{2,31}$/;

function cleanUsername(value: unknown): string {
  return String(value ?? "").trim().toLowerCase();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: userData, error: userError } = await anon.auth.getUser();
  const actor = userData.user;
  if (userError || !actor) return json({ error: "unauthorized" }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  // The UI gate is not security. Re-check the true CEO on the server.
  const { data: isCeo, error: ceoError } = await admin.rpc("is_ceo", {
    p_user_id: actor.id,
  });
  if (ceoError || isCeo !== true) {
    return json({ error: "only_ceo_can_create_staff_gateway" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const username = cleanUsername(body.username);
  const name = String(body.name ?? "").trim();
  const staffCode = String(body.staff_code ?? "").trim();
  const password = String(body.password ?? "");
  const confirmPassword = String(body.confirm_password ?? password);
  const permissions = Array.isArray(body.permissions)
    ? body.permissions.map((p) => String(p))
    : [];
  const categories = Array.isArray(body.assigned_categories)
    ? body.assigned_categories.map((c) => String(c))
    : [];
  const salesTarget = Number(body.sales_target ?? 0);
  const isSuperAdmin = body.is_super_admin === true;
  const branch = String(body.branch ?? "ADMIN");

  if (!usernamePattern.test(username)) {
    return json({ error: "invalid_username" }, 400);
  }
  if (name.length < 2 || name.length > 100 || staffCode.length < 2 || staffCode.length > 60) {
    return json({ error: "invalid_staff_details" }, 400);
  }
  if (password.length < 10 || password.length > 200) {
    return json({ error: "password_must_be_10_to_200_characters" }, 400);
  }
  if (password !== confirmPassword) {
    return json({ error: "passwords_do_not_match" }, 400);
  }
  if (!Number.isFinite(salesTarget) || salesTarget < 0) {
    return json({ error: "invalid_sales_target" }, 400);
  }

  const syntheticEmail = `${username}@staff-gateway.invalid`;
  const { data: createdAuth, error: createAuthError } = await admin.auth.admin.createUser({
    email: syntheticEmail,
    password,
    email_confirm: true,
    // app_metadata is server-controlled; the public signup metadata flag is
    // deliberately not used to bypass the OTP trigger.
    app_metadata: { staff_gateway: true },
    user_metadata: { full_name: name },
  });
  if (createAuthError || !createdAuth.user) {
    return json({ error: "staff_account_creation_failed" }, 500);
  }

  const { data: staff, error: staffError } = await admin.rpc("create_staff_gateway", {
    p_actor_id: actor.id,
    p_auth_user_id: createdAuth.user.id,
    p_username: username,
    p_name: name,
    p_staff_code: staffCode,
    p_permissions: permissions,
    p_sales_target: salesTarget,
    p_is_super_admin: isSuperAdmin,
    p_branch: branch,
    p_assigned_categories: categories,
  });

  if (staffError || !staff) {
    await admin.auth.admin.deleteUser(createdAuth.user.id);
    return json({ error: "staff_gateway_setup_failed" }, 500);
  }

  return json({
    ok: true,
    staff_id: staff.id,
    username,
    // Never return or log the password.
  }, 201);
});
