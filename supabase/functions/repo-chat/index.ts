// Supabase Edge Function: in-app help agent for end users.
// Free mode only — no LLM, no API keys. Retrieval over the indexed repo,
// answered in plain, product-level language. Env: LLM_PROVIDER (default "none").
import { createClient } from "npm:@supabase/supabase-js@2";

declare const Supabase: any; // provided by the Supabase Edge runtime

const DAILY_LIMIT = 50; // messages per user per day
// Only the free retrieval mode exists today. Reserve the knob for the future.
const LLM_PROVIDER = (Deno.env.get("LLM_PROVIDER") ?? "none").toLowerCase();
if (LLM_PROVIDER !== "none") {
  console.warn(`LLM_PROVIDER "${LLM_PROVIDER}" is not supported in this build; using "none".`);
}

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
    return [] as { content: string }[];
  }
  return (data ?? []) as { content: string }[];
}

// Indexer chunks carry a "File: <path>" header; strip it so paths never reach users.
function stripFileHeader(content: string): string {
  return content.replace(/^File:\s*.*$/m, "").trim();
}

function looksLikeInternalPath(s: string): boolean {
  return /(^|[\s(])[\w./-]+\.(dart|ts|sql|mjs|arb)\b/i.test(s) || /\b(lib|supabase|tools)\//.test(s);
}

function fallbackReply(): string {
  return "I couldn't find that in the help topics. Please contact support and they'll be happy to help.";
}

function buildAnswer(query: string, hits: { content: string }[]): string {
  const top = hits.slice(0, 3).map((h) => stripFileHeader(h.content)).filter(Boolean);
  if (!top.length) return fallbackReply();
  if (top.some((t) => looksLikeInternalPath(t))) return fallbackReply();
  return `Here's what I found about "${query}":\n\n${top.join("\n\n")}`;
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

  // 3. Parse the latest user question (keep the request shape compatible).
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

    // 4. Free mode: one search, answer assembled from the best 1-3 matches.
    //    Broaden with the history's user turns when the last question is short.
    const hints = msgs.filter((m: { role: string }) => m.role === "user").map((m: { content: string }) => m.content);
    const hits = await search(question, 6);
    if (!hits.length && hints.length > 1) {
      hits.push(...(await search(hints.slice(-3).join(" "), 6)));
    }
    return json({ reply: buildAnswer(question, hits) });
  } catch (e) {
    console.error("repo-chat failed:", e);
    return json({ reply: fallbackReply() });
  }
});
