# Help chat agent — handoff

Status: code complete on branch `chore/help-chat-integration` (PR #1 into `main`).
Everything below is names only — no secret values are needed from or by this document.

## a) What is done

- Bundle materialized: all 8 files from `help-chat-agent-ALL-IN-ONE.md` now exist at their
  real paths exactly as written (`HELP_CHAT_SETUP.md`, `knowledge.md`,
  `.github/workflows/index-repo.yml`, `supabase/migrations/20260919000000_repo_chat.sql`,
  `tools/indexer/index.mjs`, `lib/features/help_chat/help_chat_screen.dart`,
  `supabase/functions/index-chunks/index.ts`, `supabase/functions/repo-chat/index.ts`).
- Route wiring (go_router convention — the app does not use `Navigator.push`):
  - `/help` route added in `lib/routing/app_router.dart` → `HelpChatScreen`.
  - Signed-in entry point: the "Help & Support" tile in `lib/features/user/user_profile_screen.dart`
    (was a dead tile) now pushes `/help`. The redirect in the router already gates everything
    behind authentication, so anonymous users never reach it.
- Indexer INCLUDE/EXCLUDE decisions (`tools/indexer/index.mjs`): kept as shipped because they
  already match the real repo layout — `lib/**/*.dart`, `**/*.md`, `pubspec.yaml`,
  `supabase/migrations/**`, `supabase/functions/**` are included; the Edge Functions themselves,
  `tools/`, `.github/`, `.env*`, and generated `*.g.dart`/`*.freezed.dart` are excluded. The
  `lib/l10n/**` rule is dormant (no such directory exists in this repo) and harmless.
- Audit cleanups confirmed: names consistent across code/docs/workflow; `vector(384)` matches
  the `gte-small` model; migration sorts after the newest existing one (`0033_*`) and is
  idempotent; `repo_chunks` and `chat_usage` have RLS enabled with **no** policies; the agent's
  only tool searches the knowledge index and cannot touch app user data; `index-chunks` is
  protected by the `x-indexer-key` check; no secrets committed anywhere.
- CI: existing `build.yml` (release AAB) is untouched; `index-repo.yml` is a separate workflow
  file, no trigger conflicts.

## b) What was NOT verified

- `flutter pub get` / `flutter analyze` / `flutter test` — could not run: no Flutter SDK in the
  workspace. CI is the gate (the release-AAB workflow must be green after merge).
- Supabase migration application, Edge Function deploys, and secrets — intentionally not run
  (owner does them; steps below).
- Live end-to-end chat — untested (requires steps 1–7 below to be complete).

## c) Names that must match (names only, never values)

- Edge Functions: `repo-chat`, `index-chunks`
- Table: `repo_chunks`
- RPCs: `match_chunks`, `bump_usage`
- Secrets: `ANTHROPIC_API_KEY`, `INDEXER_KEY`, `INDEXER_URL`

## d) Remaining owner steps — IN THIS ORDER, before merging

1. `supabase db push` (applies `20260919000000_repo_chat.sql`; or run it in the Supabase SQL Editor).
2. `supabase secrets set ANTHROPIC_API_KEY=...` and `supabase secrets set INDEXER_KEY=...` (save the INDEXER_KEY value for step 4).
3. Deploy the functions: `supabase functions deploy repo-chat`, and `supabase functions deploy index-chunks --no-verify-jwt`.
4. Add `INDEXER_URL` (`https://<project-ref>.supabase.co/functions/v1/index-chunks`) and `INDEXER_KEY` (value from step 2) to the repo's **GitHub Actions secrets**.
5. Merge the PR (`chore/help-chat-integration` → `main`).
6. Run the **"Index repo for help chat"** workflow manually once (workflow_dispatch) for a full index.
7. Smoke test in the app: sign in → Profile → Help & Support → ask a question.

## e) Warning

The index workflow triggers on every **push to `main`**. If it runs before steps 1–4 are done,
it fails (missing table / secrets / function). It is not auto-retried — re-run it manually
(workflow_dispatch) after setup is complete.
