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
//
// WHY THE SYNTHETIC EMAIL IS NO LONGER THE SOURCE OF TRUTH HERE
// -------------------------------------------------------------
// This function used to rebuild the auth address from the username with
// syntheticStaffEmail() and sign in against that. That made login correct only
// for as long as the derivation stayed in lockstep with whatever actually
// created the auth.users row — and it does not, for two reasons that are both
// live in this repository:
//
//   * link_staff_user() attaches an EXISTING auth.users row to a staff row. Its
//     real email is the person's own address, not a @staff-gateway.invalid
//     synthetic one, so re-deriving one always produced an account that does
//     not exist. The admin screen even tells the operator "$email can now sign
//     in as staff" — a promise the code could not keep. Every linked staff
//     member was permanently locked out with the same opaque
//     "Invalid username or password."
//   * The SQL twin (staff_gateway_email) is a third copy of the rule. Any
//     disagreement between the TypeScript, the SQL, and auth.users produced
//     exactly the reported symptom, with nothing on screen to distinguish
//     "no such username" from "wrong password" from "wrong identity".
//
// So the auth row itself is now the source of truth: read the real email from
// auth.users by the id already stored on staff_credentials. That is immune to
// every derivation above, including ones written after this comment.
// syntheticStaffEmail is kept as a fallback for a row that somehow has no
// email, and stays exported for the create path and its tests.

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
  if (lookupError) {
    console.error("staff-login credential lookup failed:", lookupError.message);
    return json({ error: "login_unavailable" }, 503);
  }

  // The four refusal reasons below are deliberately indistinguishable on the
  // wire — this endpoint is unauthenticated, so distinguishing them would turn
  // it into a username oracle. They were also indistinguishable in the LOGS,
  // which is why a real, total lockout ("this account can never log in") was
  // reported as a mistyped password. The reason is now recorded server-side.
  const staff = credential?.staff as { is_active?: boolean } | null;
  if (!credential) {
    console.error("staff-login refused: no staff_credentials row for username");
    return json({ error: "invalid_credentials" }, 401);
  }
  if (!staff?.is_active) {
    console.error("staff-login refused: staff row is not active", {
      staff_id: credential.staff_id,
    });
    return json({ error: "invalid_credentials" }, 401);
  }
  if (credential.locked_until && new Date(credential.locked_until).getTime() > Date.now()) {
    console.error("staff-login refused: account locked until", credential.locked_until, {
      staff_id: credential.staff_id,
    });
    return json({ error: "invalid_credentials" }, 401);
  }

  // Ground truth: the address the auth row actually has. This is what makes a
  // linked staff member (whose auth email is their own) reachable at all.
  let authEmail: string | undefined;
  const { data: authRow, error: authError } = await admin.auth.admin.getUserById(
    credential.user_id,
  );
  if (authError) {
    console.error("staff-login could not read the auth user:", authError.message, {
      staff_id: credential.staff_id,
    });
    return json({ error: "login_unavailable" }, 503);
  }
  authEmail = authRow?.user?.email ?? undefined;
  if (!authEmail) {
    authEmail = await syntheticStaffEmail(username);
    console.error("staff-login: auth row has no email, fell back to the derived one", {
      staff_id: credential.staff_id,
    });
  }

  const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: signIn, error: signInError } = await userClient.auth.signInWithPassword({
    email: authEmail,
    password,
  });
  if (signInError || !signIn.session || signIn.user?.id !== credential.user_id) {
    console.error("staff-login refused: password rejected", {
      staff_id: credential.staff_id,
      // message only, never the address or the password
      gotrue: signInError?.message ?? "no session",
    });
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
