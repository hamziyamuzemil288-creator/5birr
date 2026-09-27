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

  if (newPassword === currentPassword) {
    // Changing a password to itself is the one "new" password that is a
    // guaranteed wrong answer, and the only situation where the user believes
    // they have secured the account and has not.
    return json({ error: "new_password_must_differ" }, 400);
  }

  const { error: updateError } = await userClient.auth.updateUser({
    password: newPassword,
  });
  if (updateError) return json({ error: "password_change_failed" }, 400);

  // The whole reason to change a password is that the old one may be known to
  // somebody else — usually because the CEO typed it into a handover chat. The
  // password is now different, but every OTHER session already signed in with
  // the leaked one keeps working on its refresh token until it expires, which
  // for a default Supabase project is a week. The account would look secured
  // and would not be.
  //
  // Best-effort on purpose, and the reason is the ORDER of the statements
  // above: the password is already changed by this point. Failing the request
  // now would tell the user "password change failed" for a change that
  // succeeded, which is worse than a stale session they can sign out. So this
  // is logged loudly rather than surfaced as a failure.
  const callerJwt = userData.session?.access_token;
  if (callerJwt) {
    const { error: signOutError } = await admin.auth.admin.signOut(
      callerJwt,
      "others",
    );
    if (signOutError) {
      console.error(
        "password changed but other sessions were NOT revoked:",
        signOutError.message,
        { staff_id: staff.id },
      );
    }
  } else {
    console.error(
      "password changed but there was no session token to revoke others with",
      { staff_id: staff.id },
    );
  }

  // An audit row with a NULL actor is the failure mode this exists to prevent,
  // so the actor is passed explicitly: this function authenticates as
  // service_role, which carries no JWT and therefore has no auth.uid().
  const { error: logError } = await admin.rpc("log_staff_password_change", {
    p_staff_id: staff.id,
    p_actor_id: userData.user.id,
  });
  if (logError) {
    // The password changed whether or not this lands. Say so in the log rather
    // than failing the response — a user must never believe a change failed
    // when it succeeded and only the paperwork is missing.
    console.error(
      "password changed but the audit row was NOT written:",
      logError.message,
      { staff_id: staff.id },
    );
  }

  return json({ ok: true });
});
