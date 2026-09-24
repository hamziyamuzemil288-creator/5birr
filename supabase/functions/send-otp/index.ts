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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const { email, captcha_id } = await req.json();
    const normalizedEmail = typeof email === "string" ? email.trim().toLowerCase() : "";
    if (!normalizedEmail || !normalizedEmail.includes("@")) {
      return json({ error: "invalid_email" }, 400);
    }

    // Fail closed until a real provider is configured. Never fall back to a
    // response body, log, or other client-visible development channel.
    const apiKey = Deno.env.get("RESEND_API_KEY");
    const fromEmail = Deno.env.get("OTP_FROM_EMAIL");
    if (!apiKey || !fromEmail) {
      return json({ error: "email_provider_not_configured" }, 503);
    }

    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

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

    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: fromEmail,
        to: [normalizedEmail],
        subject: "Your Aliob verification code",
        text: `Your Aliob verification code is ${code}. It expires in 10 minutes.`,
      }),
    });
    if (!emailResponse.ok) {
      console.error("email provider rejected request:", emailResponse.status);
      return json({ error: "email_delivery_failed" }, 502);
    }

    return json({ delivered: true, expires_in_seconds: 600 });
  } catch (e) {
    console.error(e);
    return json({ error: "internal_error" }, 500);
  }
});
