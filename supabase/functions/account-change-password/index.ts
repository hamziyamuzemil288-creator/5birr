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

// Change your own password, as a user or a provider.
//
// This is staff-change-password with the staff check removed, and it is a
// separate function rather than a flag on that one on purpose: the staff
// endpoint refuses anyone without an active `staff` row, and loosening it to
// "anyone signed in" would widen a function whose callers are the most
// privileged accounts in the product. A new endpoint can carry its own rules.
//
// The security shape is identical to the staff flow, because it is the same
// question asked of a different person: prove you know the CURRENT password
// before being allowed to set a new one. Supabase's updateUser({password})
// alone would let anyone who walked up to an unlocked, still-signed-in device
// take the account over permanently, and the session is exactly what a
// shoulder-surfer or a shared tablet has.
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

  let body: { current_password?: unknown; new_password?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const currentPassword = String(body.current_password ?? "");
  const newPassword = String(body.new_password ?? "");
  // Same floor as the staff flow: a 10-character minimum is the bar the rest
  // of the product already sets, and the upper bound keeps a multi-megabyte
  // string out of the auth request.
  if (
    currentPassword.length < 1 ||
    currentPassword.length > 200 ||
    newPassword.length < 10 ||
    newPassword.length > 200
  ) {
    return json({ error: "invalid_password_requirements" }, 400);
  }

  if (newPassword === currentPassword) {
    // The one "new" password that is a guaranteed wrong answer, and the only
    // case where someone believes they have secured the account and has not.
    return json({ error: "new_password_must_differ" }, 400);
  }

  // Phone-only accounts (Google/OAuth signups) have no password to verify, so
  // there is no "current password" to ask for. updateUser on the live session
  // is the only available path, and Supabase sends the user a confirmation.
  const email = userData.user.email ?? "";
  if (email.isNotEmpty) {
    const { error: currentError } = await userClient.auth.signInWithPassword({
      email,
      password: currentPassword,
    });
    if (currentError) {
      return json({ error: "current_password_incorrect" }, 401);
    }
  } else if (currentPassword.length < 1) {
    return json({ error: "current_password_incorrect" }, 401);
  }

  const { error: updateError } = await userClient.auth.updateUser({
    password: newPassword,
  });
  if (updateError) return json({ error: "password_change_failed" }, 400);

  // The reason to change a password is that the old one may be known to
  // somebody else. It is now different, but every OTHER session signed in with
  // the old one keeps working on its refresh token, so the account would look
  // secured and would not be.
  //
  // Best-effort, and best-effort AFTER the change on purpose: failing the
  // request now would report "password change failed" for a change that
  // succeeded, which is worse than a stale session the person can sign out.
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
      );
    }
  }

  return json({ ok: true });
});
