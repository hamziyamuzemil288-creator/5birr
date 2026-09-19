// Incremental repo indexer. Run by GitHub Actions on every push to main.
// No dependencies (Node 20+). Set FULL=1 to rebuild the whole index.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const { INDEXER_URL, INDEXER_KEY, BEFORE, AFTER, FULL } = process.env;
if (!INDEXER_URL || !INDEXER_KEY) throw new Error("INDEXER_URL and INDEXER_KEY are required");

const sh = (cmd) => execSync(cmd, { encoding: "utf8", maxBuffer: 1 << 28 }).trim();
const commit = AFTER || sh("git rev-parse HEAD");

// Chunk POST batch size (index-chunks embeds each chunk sequentially with
// gte-small; 2 per request sits safely inside free-plan worker limits).
const BATCH = Math.max(1, parseInt(process.env.BATCH || "2", 10) || 2);

// Docs-only allowlist: index ONLY user-facing content. repo-chat free mode
// (LLM_PROVIDER=none) serves kind 'doc' and 'ui_text' exclusively, so code,
// migrations and function sources are never returned to users — embedding them
// wasted the edge worker's compute budget (HTTP 546 WORKER_RESOURCE_LIMIT,
// full-index runs #13/#16).
const INCLUDE = [
  /^lib\/l10n\/.*\.arb$/,
];
// Markdown is an ALLOWLIST: only user-facing docs are ever indexed. Markdown
// under n8n/, scripts/, test/, supabase/, tools/ and .github/ is excluded by
// construction (nothing in the allowlist lives there).
const MARKDOWN_ALLOWLIST = [
  /^docs\/help\//,
  /^privacy-policy\.md$/,
  /^delete-account\.md$/,
];
const EXCLUDE = [
  /\.g\.dart$/,
  /\.freezed\.dart$/,
  /(^|\/)\.env/,
  // Help-chat's own machinery is never indexed (as before this change).
  /^supabase\/functions\/(repo-chat|index-chunks)\//,
  // Explicit never-index list (belt-and-braces vs allowlist drift), plus the
  // generated combined-migration dump produced by scripts/apply_migrations_sql.sh.
  /(^|\/)help-chat-agent-ALL-IN-ONE\.md$/,
  /(^|\/)knowledge\.md$/,
  /(^|\/)HELP_CHAT_SETUP\.md$/,
  /(^|\/)HELP_CHAT_HANDOFF\.md$/,
];
// Markdown-scoped directory excludes: explicit per the security policy. Scoped
// to .md files only so the supabase/ and tools/ entries above keep working.
const MARKDOWN_EXCLUDE_DIRS = [
  /^n8n\//,
  /^scripts\//,
  /^test\//,
  /^supabase\//,
  /^tools\//,
  /^\.github\//,
];
const wanted = (p) => {
  if (p.endsWith(".md")) {
    return (
      MARKDOWN_ALLOWLIST.some((r) => r.test(p)) &&
      !MARKDOWN_EXCLUDE_DIRS.some((r) => r.test(p)) &&
      !EXCLUDE.some((r) => r.test(p))
    );
  }
  return INCLUDE.some((r) => r.test(p)) && !EXCLUDE.some((r) => r.test(p));
};

// Remove anything that looks like a secret before it leaves the repo.
const redact = (s) =>
  s
    .replace(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, "[REDACTED_JWT]")
    .replace(/sk-[A-Za-z0-9_-]{20,}/g, "[REDACTED_KEY]")
    .replace(/((?:api[_-]?key|secret|token|password)\s*[:=]\s*)(['"]).+?\2/gi, "$1$2[REDACTED]$2");

const kindOf = (p) =>
  p.endsWith(".md") ? "doc" : p.endsWith(".arb") ? "ui_text" : p.endsWith(".sql") ? "database" : "code";

// Split into ~1200-2000 char chunks, preferring blank-line boundaries.
function chunk(path, text) {
  const lines = text.split("\n");
  const out = [];
  let start = 0;
  let size = 0;
  for (let i = 0; i < lines.length; i++) {
    size += lines[i].length + 1;
    const atBreak = lines[i].trim() === "";
    if ((size > 1200 && atBreak) || size > 2000 || i === lines.length - 1) {
      const content = lines.slice(start, i + 1).join("\n").trim();
      if (content) {
        out.push({
          path,
          start_line: start + 1,
          end_line: i + 1,
          kind: kindOf(path),
          content: `File: ${path}\n${content}`,
        });
      }
      start = i + 1;
      size = 0;
    }
  }
  return out;
}

async function post(body) {
  // Retry up to 3 times with backoff on 5xx / 546 (free-plan worker limits
  // are transient under load). Never logs body content or secrets.
  const delays = [2000, 6000, 15000];
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(INDEXER_URL, {
      method: "POST",
      headers: { "content-type": "application/json", "x-indexer-key": INDEXER_KEY },
      body: JSON.stringify({ commit, ...body }),
    });
    if (res.ok) return res.json();
    const retryable = res.status >= 500 || res.status === 546 || res.status === 429;
    if (!retryable || attempt >= 3) {
      throw new Error(`index-chunks ${res.status}: ${await res.text()}`);
    }
    const wait = delays[attempt];
    console.log(`index-chunks ${res.status}, retrying in ${wait / 1000}s (attempt ${attempt + 1}/3)`);
    await new Promise((r) => setTimeout(r, wait));
  }
}

const batches = (arr, n) => Array.from({ length: Math.ceil(arr.length / n) }, (_, i) => arr.slice(i * n, i * n + n));

// 1. Work out what changed.
let changed = [];
let deleted = [];
const full = FULL || !BEFORE || /^0+$/.test(BEFORE);
if (full) {
  changed = sh("git ls-files").split("\n").filter(wanted);
} else {
  for (const line of sh(`git diff --name-status --no-renames ${BEFORE} ${AFTER}`).split("\n")) {
    if (!line) continue;
    const [status, path] = line.split("\t");
    if (!wanted(path)) continue;
    (status === "D" ? deleted : changed).push(path);
  }
}
console.log(`${full ? "Full" : "Incremental"} index: ${changed.length} changed, ${deleted.length} deleted`);

// 2. Remove stale chunks.
if (full) await post({ delete_all: true });
else for (const b of batches([...changed, ...deleted], 100)) await post({ delete_paths: b });

// 3. Send fresh chunks.const chunks = changed.flatMap((p) => chunk(p, redact(readFileSync(p, "utf8"))));
const list = batches(chunks, BATCH);
let totals = { inserted: 0, embedded: 0, failed: 0 };
for (let i = 0; i < list.length; i++) {
  const out = await post({ chunks: list[i] });
  totals.inserted += out.inserted || 0;
  totals.embedded += out.embedded || 0;
  totals.failed += out.failed || 0;
  console.log(`batch ${i + 1}/${list.length} ok`);
}
console.log(
  `Indexed ${totals.inserted} chunks at ${commit.slice(0, 7)}` +
    ` (embedded: ${totals.embedded}, failed-embed: ${totals.failed})`,
);
if (totals.failed > 0 && totals.embedded === 0) {
  throw new Error(`every embedding failed (${totals.failed} rows inserted with NULL embedding)`);
}
