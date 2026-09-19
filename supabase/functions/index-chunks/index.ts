// Supabase Edge Function: called by the GitHub Action indexer (not by app users).
// Deploy with --no-verify-jwt; it is protected by the x-indexer-key secret instead.
import { createClient } from "npm:@supabase/supabase-js@2";

declare const Supabase: any; // provided by the Supabase Edge runtime

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const embedder = new Supabase.ai.Session("gte-small");

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.headers.get("x-indexer-key") !== Deno.env.get("INDEXER_KEY")) {
    return reply({ error: "forbidden" }, 403);
  }

  const { commit, delete_all = false, delete_paths = [], chunks = [] } = await req.json();

  if (delete_all) {
    const { error } = await admin.from("repo_chunks").delete().gt("id", 0);
    if (error) return reply({ error: error.message }, 500);
  }

  if (delete_paths.length) {
    const { error } = await admin.from("repo_chunks").delete().in("path", delete_paths);
    if (error) return reply({ error: error.message }, 500);
  }

  // Embed each chunk defensively: a per-chunk embedder failure (worker CPU
  // pressure, odd content) must not lose the chunk — the row is still inserted
  // with a NULL embedding so keyword (fts) search keeps working; only semantic
  // search skips NULL rows.
  let embedded = 0;
  let failed = 0;
  const rows = [];
  for (const c of chunks) {
    let embedding: string | null = null;
    try {
      const emb = await embedder.run(String(c.content).slice(0, 2000), {
        mean_pool: true,
        normalize: true,
      });
      embedding = JSON.stringify(Array.from(emb));
      embedded++;
    } catch (_e) {
      failed++;
    }
    rows.push({
      path: c.path,
      start_line: c.start_line,
      end_line: c.end_line,
      kind: c.kind,
      content: c.content,
      commit_sha: commit,
      embedding,
    });
  }

  if (rows.length) {
    const { error } = await admin.from("repo_chunks").insert(rows);
    if (error) return reply({ error: error.message }, 500);
  }

  return reply({ ok: true, inserted: rows.length, embedded, failed });
});
