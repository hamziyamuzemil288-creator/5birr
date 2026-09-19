# Help chat agent — handoff

Status: free mode (no LLM, no API key) implemented on branch
`chore/help-chat-integration` (PR #1 into `main`).
Everything below is names only — no secret values are needed from or by this
document.

## a) What is done

- **Free mode**: `supabase/functions/repo-chat/index.ts` has no Anthropic
  dependency. Env `LLM_PROVIDER` (default `"none"`) is the provider knob;
  `"none"` is the only supported value. The function embeds the question
  (built-in gte-small), calls `match_chunks(..., kinds => ['doc','ui_text'])`,
  and answers in plain language from the best 1–3 matches. `File:` header
  lines are stripped, a defensive regex double-checks no file paths leak, and
  a friendly "contact support" fallback is returned when nothing relevant is
  found or the function errors. Response shape stays `{ reply: string }`, so
  `lib/features/help_chat/help_chat_screen.dart` needs no change. Auth +
  50/day rate limit are unchanged.
- **Migration** `supabase/migrations/20260919000001_match_chunks_kinds.sql`:
  re-creates `match_chunks(query_embedding, query_text, match_count, kinds
  text[] default null)` filtering on `kind = any(kinds)`; same
  revoke-from-public/anon/authenticated posture as the original.
- **User help content**: `docs/help/faq.md` — starter FAQ built from real app
  features (signup + admin approval, documents, cart/checkout, escrow reveal
  rules, rides/live driver location, provider wallets/subscription, points,
  trust ratings). Items needing owner confirmation are marked inside the file.
- **Indexer** (`tools/indexer/index.mjs`): `.md` and `lib/l10n/*.arb` were
  already included; added EXCLUDEs for the agent/ops docs (ALL-IN-ONE bundle,
  HELP_CHAT_SETUP, HELP_CHAT_HANDOFF, knowledge.md) so internal details can
  never be served to end users.
- **Docs**: `HELP_CHAT_SETUP.md` and this file describe free mode only;
  `ANTHROPIC_API_KEY` is gone everywhere. Secrets in play: `INDEXER_KEY`,
  `INDEXER_URL`.
- Route wiring unchanged from the original PR: `/help` route →
  `HelpChatScreen`; entry point is the "Help & Support" tile in
  `lib/features/user/user_profile_screen.dart`.

## b) What was NOT verified

- `flutter analyze` on this branch — CI is the gate (release-AAB workflow).
- The live end-to-end chat (requires the migration + deploys below).
- Supabase function deploys and secrets — done by the owner/agent after SQL
  approval.

## c) Names that must match (names only, never values)

- Edge Functions: `repo-chat`, `index-chunks`
- Table: `repo_chunks`
- RPCs: `match_chunks` (now with 4th arg `kinds`), `bump_usage`
- Env on `repo-chat`: `LLM_PROVIDER` (default `none`)
- Secrets: `INDEXER_KEY`, `INDEXER_URL` (GitHub Actions + Supabase)

## d) Remaining steps — IN THIS ORDER

The agent never touches the live Supabase project. All live-project
operations run through the **"Deploy Supabase"** GitHub Actions workflow
(`.github/workflows/deploy-supabase.yml`, PR #3): manual dispatch only,
`dry_run` input defaulting to **true**, CLI pinned to 2.117.0, `contents:
read` only, and a `deploy-supabase` concurrency group so runs never
overlap. It needs three GitHub secrets — `SUPABASE_ACCESS_TOKEN`,
`SUPABASE_DB_PASSWORD`, `INDEXER_KEY` — and none of them are ever echoed
in the run log. Project ref `xnwieehlrhrffoikpglj` is a plain env var
(not a secret).

1. Owner stores the three GitHub secrets (Settings → Secrets and variables
   → Actions → New repository secret). Generate `INDEXER_KEY` with e.g.
   `openssl rand -hex 32` — keep the value; the same string goes into
   `INDEXER_URL`'s sibling GitHub secret in step 5.
2. Run **Deploy Supabase** with `dry_run = true` (the default). Read the
   schema diff in the run log; nothing is changed. If the CLI reports
   out-of-order migrations, re-run after merging PR #1 so
   `20260919000001_match_chunks_kinds.sql` is present on main (the
   dry-run only sees migrations in the checked-out tree).
3. Owner applies the Task B data repair in the Supabase SQL editor (the
   single transactional UPDATE for approved-but-PENDING profiles) — this
   is data, not schema, so the workflow does not do it.
4. Run **Deploy Supabase** with `dry_run = false`: applies migrations in
   timestamp order (`20260919000001`, then `20260919000002`), deploys
   `repo-chat` and `index-chunks` (`--no-verify-jwt`), and sets Supabase
   function secrets `INDEXER_KEY` + `LLM_PROVIDER=none` (values from the
   GitHub secrets, never printed).
5. Owner adds `INDEXER_URL` (=
   `https://xnwieehlrhrffoikpglj.supabase.co/functions/v1/index-chunks`)
   and `INDEXER_KEY` as GitHub Actions secrets — the workflow env can read
   them but cannot create them.
6. Merge the PRs (Task B `fix/provider-signup-image-admin` #2 first, then
   `chore/help-chat-integration` #1) and confirm main CI is green after
   each.
7. Run the **"Index repo for help chat"** workflow once
   (workflow_dispatch) for a full index.
8. Smoke test: ask 3 real questions in the app; confirm replies never
   contain code, file paths, or table names.
9. Rotate `SUPABASE_DB_PASSWORD` afterwards — it transitied GitHub
   Actions logs/secrets infrastructure and good hygiene after any
   credential exposure window.

## e) Warning

The index workflow triggers on every **push to `main`**. If it runs before
steps 1–3 are done, it fails (missing table / secrets / function). It is not
auto-retried — re-run it manually (workflow_dispatch) after setup is
complete.
