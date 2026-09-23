// Email OTP sender — signup verification (Task 7 item 1).
//
// Flow (server-authoritative, nothing trusted from the client):
//   1. POST /functions/v1/send-otp { "email": "..." }
//        - this function generates a random 6-digit code,
//        - request_email_otp(email, code) rate-limits (60 s/email) and
//          stores only the SHA-256 hash (10-min expiry, 5 attempts),
//        - the plaintext code exists only in this function's memory.
//   2. rpc verify_email_otp(email, code)  — client submits the code.
//   3. signUp() — handle_new_user() refuses to create the account unless a
//      verified OTP for the email exists (migration 20260923000005).
//
// ── EMAIL PROVIDER STATUS: STUBBED (no provider configured) ─────────────
// A transactional provider was evaluated (Elastic Email) but its free trial
// requires payment/card details, which the owner declined. Per owner
// instruction the delivery step is a clearly marked stub: the code is
// generated, stored, verifiable and enforced — only the actual email send
// is missing. Stub mode returns the code to the caller as dev_code so the
// full flow is testable end-to-end; a real provider never returns it.
//
// TODO(EMAIL_PROVIDER): wire a real provider here. Card-free options with
// usable free tiers: Brevo (300 emails/day), Mailjet (200/day), Resend
// (100/day). The generated code is in `code`; replace the STUBBED block
// with e.g.:
//
//   const apiKey = Deno.env.get("BREVO_API_KEY");
//   const res = await fetch("https://api.brevo.com/v3/smtp/email", {
//     method: "POST",
//     headers: { "api-key": apiKey, "content-type": "application/json" },
//     body: JSON.stringify({
//       sender: { name: "Aliob", email: "noreply@yourdomain.com" },
//       to: [{ email }],
//       subject: `Your Aliob verification code: ${code}`,
//       textContent:
//         `Your Aliob verification code is ${code}. It expires in 10 minutes.`,
//     }),
//   });
//   if (!res.ok) throw new Error(`email send failed: ${await res.text()}`);
//
// then `supabase secrets set BREVO_API_KEY=...`, deploy this function, and
// set STUBBED = false. Everything else (hashing, expiry, attempts, signup
// gate) is already live and unchanged by that switch.
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

const STUBBED = true; // TODO(EMAIL_PROVIDER): false once a provider is wired

const randomCode = (): string => {
  // 6 digits, uniformly from crypto randomness; leading zeros allowed
  // because verification compares zero-padded strings.
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return String(buf[0] % 1000000).padStart(6, "0");
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const { email } = await req.json();
    if (typeof email !== "string" || !email.includes("@")) {
      return json({ error: "invalid_email" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

    const code = randomCode();
    const { data, error } = await admin.rpc("request_email_otp", {
      p_email: email,
      p_code: code,
    });
    if (error) {
      console.error("request_email_otp failed:", error.message);
      return json({ error: "otp_request_failed" }, 500);
    }
    if (data && data.ok === false) {
      // 60 s resend window still open — tell the client to wait.
      return json({
        delivered: false,
        retry_after_seconds: data.retry_after_seconds,
      });
    }

    if (STUBBED) {
      return json({
        delivered: false,
        provider: "stub",
        // Stub-mode only: lets the app complete the flow while no provider
        // is connected. Removed when STUBBED becomes false.
        dev_code: code,
        expires_in_seconds: data?.expires_in_seconds ?? 600,
      });
    }

    // TODO(EMAIL_PROVIDER): real send path goes here (see header comment).
    return json({ delivered: false, error: "provider_not_configured" }, 500);
  } catch (e) {
    console.error(e);
    return json({ error: "internal_error" }, 500);
  }
});
