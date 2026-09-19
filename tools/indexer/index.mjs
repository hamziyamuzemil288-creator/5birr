// Incremental repo indexer. Run by GitHub Actions on every push to main.
// No dependencies (Node 20+). Set FULL=1 to rebuild the whole index.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const { INDEXER_URL, INDEXER_KEY, BEFORE, AFTER, FULL } = process.env;
if (!INDEXER_URL || !INDEXER_KEY) throw new Error("INDEXER_URL and INDEXER_KEY are required");

const sh = (cmd) => execSync(cmd, { encoding: "utf8", maxBuffer: 1 << 28 }).trim();
const commit = AFTER || sh("git rev-parse HEAD");

// Code/config the agent may index (kind 'code'/'database'; never served to
// end users — repo-chat free mode only returns kind 'doc'/'ui_text').
const INCLUDE = [
  /^lib\/.*\.dart$/,
  /^lib\/l10n\/.*\.arb$/,
  /^supabase\/migrations\/.*\.sql$/,
  /^supabase\/functions\/.*\.ts$/,
  /^pubspec\.yaml$/,
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
  const res = await fetch(INDEXER_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-indexer-key": INDEXER_KEY },
    body: JSON.stringify({ commit, ...body }),
  });
  if (!res.ok) throw new Error(`index-chunks ${res.status}: ${await res.text()}`);
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

// 3. Send fresh chunks.
const chunks = changed.flatMap((p) => chunk(p, redact(readFileSync(p, "utf8"))));
for (const b of batches(chunks, 15)) await post({ chunks: b });
console.log(`Indexed ${chunks.length} chunks at ${commit.slice(0, 7)}`);
