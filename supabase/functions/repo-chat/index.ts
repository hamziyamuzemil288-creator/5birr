// Supabase Edge Function: in-app help agent for end users.
// Free mode only — no LLM, no API keys. Fast paths handle greetings and the
// app's core flows; anything else is answered from the indexed repo, and
// anything the agent can't answer gets a friendly handoff to human support.
// Env: LLM_PROVIDER (default "none").
import { createClient } from "npm:@supabase/supabase-js@2";

declare const Supabase: any; // provided by the Supabase Edge runtime

const DAILY_LIMIT = 50; // messages per user per day
// Only the free retrieval mode exists today. Reserve the knob for the future.
const LLM_PROVIDER = (Deno.env.get("LLM_PROVIDER") ?? "none").toLowerCase();
if (LLM_PROVIDER !== "none") {
  console.warn(`LLM_PROVIDER "${LLM_PROVIDER}" is not supported in this build; using "none".`);
}

// ── Human support contact (shown whenever the agent can't help) ──────────
const SUPPORT_WHATSAPP_DISPLAY = "0917686990";
const SUPPORT_WHATSAPP_URL = "https://wa.me/251917686990"; // +251 91 768 6990
const SUPPORT_EMAIL = "muktarbiya329@gmail.com";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const embedder = new Supabase.ai.Session("gte-small");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// ── Fast-path helpers ─────────────────────────────────────────────────────
const GREETING_RE =
  /^(hi|hii+|hello+|hay|hey+|hy|hallo|hiya|yo|selam|selamta|ሰላም|salam|hola|howdy|greetings|good\s+(morning|afternoon|evening|day)|whats\s*up|what's\s*up|sup|how\s+are\s+you|how\s+are\s+you\s+doing|how\s+is\s+it\s+going|hows\s+it\s+going|nice\s+to\s+meet\s+you|good\s+to\s+see\s+you)[\s!.,?]*$/i;

function isGreeting(text: string): boolean {
  return GREETING_RE.test(text.trim());
}

const GREETING_REPLY =
  "Hi! 👋 I'm the Aliob assistant. I can help with registering, buying and orders, " +
  "escrow and payments, wallet recharges, fees, points, and rides.\n\n" +
  "What can I help you with today?";

// ── Canned answers for the app's core flows ──────────────────────────────
// Deliberately short, conversational, and honest — the FAQ doc holds the
// long-form versions and remains the retrieval source of truth.
const CANNED_TOPICS: { patterns: RegExp; reply: string }[] = [
  {
    patterns:
      /\b(sign\s*up|register|registration|create\s+(an?\s+)?(account|acct)|open\s+(an?\s+)?account|join\s+the\s+app|become\s+(a\s+)?(seller|provider|driver|user)|how\s+(do|can)\s+i\s+(sell|provide\s+rides)|get\s+started)\b/i,
    reply:
      "Creating an account is easy:\n\n" +
      "1. Tap Get Started on the home screen and pick your account type — personal, vehicle provider, or service provider.\n" +
      "2. Fill in your details and upload a photo of your national ID (vehicle providers also need a driving license; service providers a trading license).\n" +
      "3. Our team reviews every application — usually quickly — and you'll get a notification once you're approved.\n\n" +
      "Anything else you'd like to know?",
  },
  {
    patterns: /\b(buy|buying|purchase|order|orders|shop|shopping|add\s+to\s+cart|cart|checkout|check\s+out|place\s+an?\s+order)\b/i,
    reply:
      "To buy something:\n\n" +
      "1. Browse or search for a product and open it.\n" +
      "2. Add it to your cart — you can mix items from different sellers; each seller's items check out as a separate order.\n" +
      "3. Check out and upload your payment screenshot. Once our team verifies the payment, the order moves forward and the seller is notified.\n\n" +
      "Want help with anything specific?",
  },
  {
    patterns: /\b(escrow|payment\s+(verification|proof|confirm)|is\s+(it|my\s+(payment|money))\s+safe|hold\s+(my\s+)?(money|payment)|protected|scam|fraud|trust)\b/i,
    reply:
      "Your payment is held safely (escrow) until the order is confirmed:\n\n" +
      "• You upload your payment screenshot at checkout.\n" +
      "• Our team verifies it — only then does the order move forward.\n" +
      "• The seller's contact and location are shared with you only after your payment is confirmed, so details stay private on purpose.\n\n" +
      "This protects both sides of every deal.",
  },
  {
    patterns: /\b(recharge|top\s*up|topup|wallet|telebirr|deposit\s+money|add\s+(money|funds|balance)|credit\s+my\s+wallet|pay\s+(the\s+)?(monthly|subscription|fee))\b/i,
    reply:
      "Wallet recharge (providers):\n\n" +
      "1. Open Wallet from your provider dashboard and tap RECHARGE WALLET.\n" +
      "2. Send the amount to our Telebirr account: 0917686990 (Aliob Business).\n" +
      "3. Enter the amount, the transaction reference, and upload your payment screenshot.\n" +
      "4. Once an admin verifies it, your wallet is credited.\n\n" +
      "Your wallet then automatically covers the 1% transaction fee on sales and the monthly subscription when it's due.",
  },
  {
    patterns: /\b(points?|rewards?|loyalty|earn\s+points)\b/i,
    reply:
      "Points:\n\n" +
      "• Every successfully completed sale earns the provider points automatically.\n" +
      "• Buyers earn points for completed orders too.\n" +
      "• Your points total is shown on your dashboard and profile.\n\n" +
      "No setup needed — points just accumulate as you use the app.",
  },
  {
    patterns: /\b(fees?|charges?|commission|costs?|1\s*%|five\s*birr|5\s*birr|how\s+much\s+(does\s+it\s+cost|do\s+you\s+charge|is\s+the\s+fee))\b/i,
    reply:
      "Fees:\n\n" +
      "• Orders include a small transaction fee (about 1%), shown clearly at checkout before you pay.\n" +
      "• Providers pay a fixed 5 Birr monthly subscription after their account is approved.\n" +
      "• Both are deducted automatically from your provider wallet — no hidden charges.\n\n" +
      "If your wallet runs low, recharge it from your dashboard.",
  },
  {
    patterns: /\b(rides?|taxi|driver|trip|trips|vehicle)\b/i,
    reply:
      "Rides:\n\n" +
      "• Pick your pickup point on the ride screen — the app fills it in automatically if you allow location access.\n" +
      "• A nearby driver accepts your request, and once they claim it you can watch their vehicle move on the map in real time.\n" +
      "• You can share your live location with your driver for that ride only, and tap Get directions to navigate to them.\n\n" +
      "Location sharing between you and the driver ends when the ride ends.",
  },
  {
    patterns: /\b(browse\s+&\s+shop|browse\s+and\s+shop|browse\s*&\s*shop|provider\s+(mode|dashboard|account)|shop\s+as\s+(a\s+)?provider|buy\s+as\s+(a\s+)?provider|switch\s+(to\s+)?(buyer|shopping)|sell\s+and\s+buy)\b/i,
    reply:
      "Provider accounts can do both:\n\n" +
      "• Your provider dashboard is where you manage your business — listings, orders, wallet, and vehicles.\n" +
      "• Tap Browse & Shop on your dashboard to switch into the buyer experience and order from other providers exactly like a regular user.\n\n" +
      "Your business view stays exactly as it is — shopping is added on top.",
  },
  {
    patterns: /\b(ratings?|reviews?|stars?|feedback|rate\s+(a\s+)?(seller|provider|driver))\b/i,
    reply:
      "Ratings and reviews:\n\n" +
      "• After an order is completed you can rate the seller.\n" +
      "• Ratings feed the average stars, completed sales, and completion rate shown on the seller's profile — all from real orders.\n\n" +
      "Honest ratings keep the marketplace trustworthy for everyone.",
  },
];

function cannedReply(text: string): string | null {
  for (const t of CANNED_TOPICS) {
    if (t.patterns.test(text)) return t.reply;
  }
  return null;
}

// ── Human handoff (returned whenever the agent can't help) ───────────────
function handoffReply(): string {
  return (
    "I'm not able to help with that directly, but our support team is happy to help!\n\n" +
    `• WhatsApp: ${SUPPORT_WHATSAPP_DISPLAY} (${SUPPORT_WHATSAPP_URL})\n` +
    `• Email: ${SUPPORT_EMAIL}\n\n` +
    "You can tap either option below to reach them."
  );
}

// Search ONLY docs and UI text so end users never see code, file paths or table names.
async function search(query: string, matchCount: number) {
  const emb = await embedder.run(query, { mean_pool: true, normalize: true });
  const { data, error } = await admin.rpc("match_chunks", {
    query_embedding: JSON.stringify(Array.from(emb)),
    query_text: query,
    match_count: matchCount,
    kinds: ["doc", "ui_text"],
  });
  if (error) {
    console.error("match_chunks failed:", error.message);
    return [] as { content: string; score: number }[];
  }
  return (data ?? []) as { content: string; score: number }[];
}

// Indexer chunks carry a "File: <path>" header; strip it so paths never reach users.
function stripFileHeader(content: string): string {
  return content.replace(/^File:\s*.*$/m, "").trim();
}

function looksLikeInternalPath(s: string): boolean {
  return /(^|[\s(])[\w./-]+\.(dart|ts|sql|mjs|arb)\b/i.test(s) || /\b(lib|supabase|tools)\//.test(s);
}

// Minimum retrieval score before we trust a retrieved answer. The hybrid
// score is rank-based, so a single top-20 semantic hit alone scores ~0.0164;
// a keyword match alone ~0.0164; both together ~0.0328. Anything weaker than
// one meaningful match is treated as "not found" → human handoff.
const MIN_HIT_SCORE = 0.012;

function buildAnswer(
  query: string,
  hits: { content: string; score: number }[],
): { reply: string; handoff: boolean } {
  const good = hits.filter((h) => h.score >= MIN_HIT_SCORE);
  const top = good.slice(0, 3).map((h) => stripFileHeader(h.content)).filter(Boolean);
  if (!top.length) return { reply: handoffReply(), handoff: true };
  if (top.some((t) => looksLikeInternalPath(t))) return { reply: handoffReply(), handoff: true };
  return { reply: top.join("\n\n"), handoff: false };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // 1. Auth: only signed-in app users.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  // 2. Rate limit.
  const { data: used } = await admin.rpc("bump_usage", { p_user: user.id });
  if ((used ?? 0) > DAILY_LIMIT) return json({ error: "daily_limit" }, 429);

  // 3. Parse the latest user message (keep the request shape compatible).
  const body = await req.json().catch(() => ({}));
  const msgs = (Array.isArray(body.messages) ? body.messages : [])
    .filter((m: any) => (m?.role === "user" || m?.role === "assistant") && typeof m.content === "string")
    .slice(-10)
    .map((m: any) => ({ role: m.role, content: String(m.content).slice(0, 2000) }));
  while (msgs.length && msgs[0].role !== "user") msgs.shift();
  if (!msgs.length) return json({ error: "no_message" }, 400);
  const question = msgs[msgs.length - 1].content.trim();
  if (!question) return json({ error: "no_message" }, 400);

  try {
    if (LLM_PROVIDER !== "none") return json({ error: "unsupported_provider" }, 400);

    // 4a. Fast path: greetings and small talk.
    if (isGreeting(question)) {
      return json({ reply: GREETING_REPLY });
    }

    // 4b. Fast path: canned answers for the app's core flows.
    const canned = cannedReply(question);
    if (canned) return json({ reply: canned });

    // 4c. Retrieval over indexed docs/UI text.
    const hints = msgs.filter((m: { role: string }) => m.role === "user").map((m: { content: string }) => m.content);
    let hits = await search(question, 6);
    if (!hits.length && hints.length > 1) {
      hits = await search(hints.slice(-3).join(" "), 6);
    }
    const answer = buildAnswer(question, hits);
    return json(answer);
  } catch (e) {
    console.error("repo-chat failed:", e);
    return json({ reply: handoffReply(), handoff: true });
  }
});
