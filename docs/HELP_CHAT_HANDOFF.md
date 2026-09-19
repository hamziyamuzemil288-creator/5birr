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

1. Apply both SQL files with psql (owner approves the SQL first).
2. Generate `INDEXER_KEY` silently, set it as a Supabase secret, deploy both
   functions (`index-chunks` with `--no-verify-jwt`).
3. Add `INDEXER_URL` and `INDEXER_KEY` to GitHub Actions secrets (the agent's
   token cannot write repo secrets — owner adds them in Settings → Secrets →
   Actions if `gh secret set` fails).
4. Merge the PR (`chore/help-chat-integration` → `main`).
5. Run the **"Index repo for help chat"** workflow once (workflow_dispatch)
   for a full index.
6. Smoke test: ask 3 real questions in the app; confirm replies never contain
   code, file paths, or table names.

## e) Warning

The index workflow triggers on every **push to `main`**. If it runs before
steps 1–3 are done, it fails (missing table / secrets / function). It is not
auto-retried — re-run it manually (workflow_dispatch) after setup is
complete.
