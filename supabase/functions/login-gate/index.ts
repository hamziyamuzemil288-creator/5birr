// Server-side login gate (Task 13 item 2): CAPTCHA enforcement + per-account
// failure lockout for the client sign-in flow.
//
// Password sign-in runs in the browser/app against Supabase Auth, so the
// gate must run BEFORE the credential check is even attempted:
//   1. captcha_required() / consume_captcha()  — the same tick+math CAPTCHA
//      the signup/appeal flows use (one solved challenge per sign-in attempt).
//   2. recent_login_failures()                 — lock the account out for 15
//      minutes after 8 failed attempts; the cooldown seconds are returned so
//      the client can show a readable message instead of a raw error.
//   3. The client then calls Supabase Auth signInWithPassword() itself and
//      reports the outcome via record_login_attempt (anonymized: lowercased
//      email key + sha256(IP) — never the raw address, never the password).
//
// Both helpers are SECURITY DEFINER and revoked from anon/authenticated
// (20260924000009_login_lockout.sql), so this function — the only caller,
// holding the service-role key — is the only path that can read or write the
// counter. Clients cannot reset it, forge successes, or enumerate accounts
// (a locked login is indistinguishable in body from any other failure).
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

const MAX_FAILURES = 8;
const LOCK_WINDOW_MINUTES = 15;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const action = typeof body?.action === "string" ? body.action : "";
    const email =
      typeof body?.email === "string" ? body.email.trim().toLowerCase() : "";
    if (!email || !email.includes("@")) {
      return json({ error: "invalid_email" }, 400);
    }
    // Never persist more than the account identity + a one-way IP hash.
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "";
    const ipHash = ip
      ? Array.from(
          new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip))),
        )
          .map((b) => b.toString(16).padStart(2, "0"))
          .join("")
      : null;

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

    if (action === "record") {
      // Failure bookkeeping only; a success clears the window server-side.
      const success = body?.success === true;
      await admin.rpc("record_login_attempt", {
        p_email_key: email,
        p_success: success,
        p_ip_hash: ipHash,
      });
      return json({ ok: true });
    }

    // action === "gate" (default): CAPTCHA + lockout check before sign-in.
    const required = await admin.rpc("captcha_required");
    if (required.error) {
      console.error("captcha_required failed:", required.error.message);
      return json({ error: "security_check_unavailable" }, 503);
    }
    if (required.data !== false) {
      if (typeof body?.captcha_id !== "string") {
        return json({ error: "captcha_required" }, 400);
      }
      const consumed = await admin.rpc("consume_captcha", {
        p_captcha_id: body.captcha_id,
        p_target: `login:${email}`,
      });
      if (consumed.error || consumed.data !== true) {
        return json({ error: "captcha_failed" }, 400);
      }
    }

    const failures = await admin.rpc("recent_login_failures", {
      p_key: email,
      p_window: `00:${LOCK_WINDOW_MINUTES}:00`,
    });
    if (failures.error) {
      console.error("recent_login_failures failed:", failures.error.message);
      return json({ error: "login_unavailable" }, 503);
    }
    const count = typeof failures.data === "number" ? failures.data : 0;
    if (count >= MAX_FAILURES) {
      // 429: this is a rate-limit refusal, not a success. The client already
      // matches the error string in the body, but a refusal must never carry
      // a 2xx status.
      return json(
        {
          error: "temporarily_locked",
          retry_after_seconds: LOCK_WINDOW_MINUTES * 60,
        },
        429,
      );
    }

    return json({
      ok: true,
      captcha_required: required.data !== false,
      failures_remaining: Math.max(0, MAX_FAILURES - count),
    });
  } catch (e) {
    console.error(e);
    return json({ error: "internal_error" }, 500);
  }
});
