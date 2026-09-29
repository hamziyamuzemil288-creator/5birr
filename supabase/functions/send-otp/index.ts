// Email OTP sender — server-authoritative signup verification.
// The plaintext OTP is sent only to the requested mailbox. It is never returned
// to the client, logged, or exposed in a development response.
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

const randomCode = (): string => {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return String(buf[0] % 1000000).padStart(6, "0");
};

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------
// Two providers, chosen by which secrets are present. This is not
// abstraction for its own sake: Resend's free tier and Brevo's are both fine
// for OTP volume, but only one of them is available on a given day, and the
// failure mode of having neither is that EVERY registration fails with an
// opaque "Database error saving new user". Resend is tried first because it
// was the original choice; setting BREVO_* switches the sender without a code
// change, and deleting RESEND_* is what switches back.
//
//   Resend  RESEND_API_KEY   + OTP_FROM_EMAIL
//   Brevo   BREVO_API_KEY    + BREVO_FROM_EMAIL   (falls back to OTP_FROM_EMAIL)
//
// Neither is a client-visible concern: the code is generated and stored
// before either call, and a delivery failure returns 502 with the provider's
// own message in the function log, never to the caller.
type Provider = "resend" | "brevo";

const resolveProvider = (): { provider: Provider; apiKey: string; from: string } | null => {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const resendFrom = Deno.env.get("OTP_FROM_EMAIL");
  if (resendKey && resendFrom) {
    return { provider: "resend", apiKey: resendKey, from: resendFrom };
  }
  const brevoKey = Deno.env.get("BREVO_API_KEY");
  const brevoFrom = Deno.env.get("BREVO_FROM_EMAIL") ?? resendFrom;
  if (brevoKey && brevoFrom) {
    return { provider: "brevo", apiKey: brevoKey, from: brevoFrom };
  }
  return null;
};

const deliver = async (
  provider: Provider,
  apiKey: string,
  from: string,
  to: string,
  code: string,
): Promise<{ ok: boolean; detail: string }> => {
  const subject = "Your Aliob verification code";
  const text = `Your Aliob verification code is ${code}. It expires in 10 minutes.`;

  const call =
    provider === "resend"
      ? fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ from, to: [to], subject, text }),
        })
      : fetch("https://api.brevo.com/v3/smtp/email", {
          method: "POST",
          headers: {
            "api-key": apiKey,
            "Content-Type": "application/json",
          },
          // Brevo takes a named sender object and a single recipient, not the
          // Resend array shape.
          body: JSON.stringify({
            sender: { email: from },
            to: [{ email: to }],
            subject,
            textContent: text,
          }),
        });

  const response = await call;
  if (response.ok) return { ok: true, detail: "" };

  // The body is the only place the real cause appears — an unverified sender,
  // an expired key, or a free-tier daily cap all come back as a bare 4xx with
  // nothing useful in the status line. Truncated because it can echo the
  // recipient address, and this goes to logs.
  const detail = (await response.text().catch(() => "")).slice(0, 300);
  return { ok: false, detail: `${provider} HTTP ${response.status}: ${detail}` };
};


Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const { email, captcha_id } = await req.json();
    const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
    if (!normalizedEmail || !normalizedEmail.includes("@")) {
      return json({ error: "invalid_email" }, 400);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

    // Email verification is switched off (migration 82), so there is nothing
    // to send and nothing to verify. Skipping here rather than failing gives
    // the app a clean pass: the client treats any response without an `error`
    // key as success, so the code screen moves on instead of showing a
    // "could not send" message the user can do nothing about.
    //
    // `delivered: false` is the truth — nothing was sent. It is not an
    // error, because the user did nothing wrong and there is no retry that
    // would help.
    const { data: otpRequired, error: otpCheckError } = await admin.rpc(
      "signup_otp_required",
    );
    if (otpCheckError) {
      console.error("signup_otp_required failed:", otpCheckError.message);
      return json({ error: "security_check_unavailable" }, 503);
    }
    if (otpRequired !== true) {
      return json({
        delivered: false,
        skipped: "email_verification_disabled",
      });
    }

    // Past this point a real code WILL be sent and verified, so a provider
    // is genuinely required. Fail closed rather than generating a code no
    // user can ever receive — a silently undeliverable code looks identical
    // to a user who mistyped theirs.
    const mailer = resolveProvider();
    if (!mailer) {
      return json({ error: "email_provider_not_configured" }, 503);
    }

    const required = await admin.rpc("captcha_required");
    if (required.error) {
      console.error("captcha_required failed:", required.error.message);
      return json({ error: "security_check_unavailable" }, 503);
    }
    if (required.data !== false) {
      if (typeof captcha_id !== "string") {
        return json({ error: "captcha_required" }, 400);
      }
      const consumed = await admin.rpc("consume_captcha", {
        p_captcha_id: captcha_id,
        p_target: `otp:${normalizedEmail}`,
      });
      if (consumed.error || consumed.data !== true) {
        return json({ error: "captcha_failed" }, 400);
      }
    }

    const code = randomCode();
    const { data, error } = await admin.rpc("request_email_otp", {
      p_email: normalizedEmail,
      p_code: code,
    });
    if (error) {
      console.error("request_email_otp failed:", error.message);
      return json({ error: "otp_request_failed" }, 500);
    }
    if (data && data.ok === false) {
      return json({
        delivered: false,
        retry_after_seconds: data.retry_after_seconds,
      });
    }

    const sent = await deliver(
      mailer.provider,
      mailer.apiKey,
      mailer.from,
      normalizedEmail,
      code,
    );
    if (!sent.ok) {
      // The provider's own words, not just its status code.
      console.error("email provider rejected request:", sent.detail);
      return json({ error: "email_delivery_failed" }, 502);
    }

    return json({ delivered: true, expires_in_seconds: 600 });
  } catch (e) {
    console.error(e);
    return json({ error: "internal_error" }, 500);
  }
});
