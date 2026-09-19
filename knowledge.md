# Help chat agent

An in-app help assistant for end users. It answers questions using an index of this repo (docs and UI text), built on Supabase free-plan features only (pgvector + Edge Functions + the built-in gte-small embedding model). No LLM, no API keys.

## How it fits together
- `lib/features/help_chat/help_chat_screen.dart`: Flutter chat screen. Calls the `repo-chat` Edge Function via `supabase_flutter`.
- `supabase/functions/repo-chat/index.ts`: authenticates the user, rate limits, embeds the question and answers in plain language from the best matches. Env `LLM_PROVIDER` (default `none`); `none` (free retrieval) is the only supported mode.
- `supabase/functions/index-chunks/index.ts`: receives chunks from the indexer, embeds them (gte-small), stores in `repo_chunks`.
- `supabase/migrations/20260919000000_repo_chat.sql`: `repo_chunks`, `match_chunks()`, `chat_usage`, `bump_usage()`.
- `supabase/migrations/20260919000001_match_chunks_kinds.sql`: `match_chunks()` with a `kinds text[]` filter; free mode restricts retrieval to `('doc','ui_text')` so end users never see source code, file paths, or table names.
- `tools/indexer/index.mjs` + `.github/workflows/index-repo.yml`: re-index changed files on every push to `main`.
- `docs/help/`: user-facing help content (the primary source for answers).
- `HELP_CHAT_SETUP.md`: deploy steps (secrets, function deploy, GitHub Actions secrets).

## Tasks for a coding agent
1. Keep the screen wired via the app's go_router conventions (`/help`), following existing theming.
2. Do not add packages beyond what is already in `pubspec.yaml`.
3. Adjust `INCLUDE` / `EXCLUDE` in `tools/indexer/index.mjs` to match this repo's real layout (docs folders, l10n files, generated code).
4. Improve retrieval quality by keeping `docs/help/` and user-facing docs current.
5. Run `flutter analyze` and fix issues in the new files.

## Rules
- Never commit secrets (`INDEXER_KEY`, service role key, database password). They live in Supabase secrets and GitHub Actions secrets only.
- Never deploy functions, run migrations against the live database, or set secrets without explicit owner approval.
- The help agent must never show source code, file paths, or internal details to end users. Retrieval is restricted to `kind IN ('doc','ui_text')` and `File:` headers are stripped; keep those guarantees intact.
- `repo_chunks` must keep RLS enabled with no policies. Only Edge Functions (service role) read it.
- `match_chunks` stays revoked from `public/anon/authenticated`.
- Do not give the agent tools that read or write app user data.
- Keep `index-chunks` protected by the `x-indexer-key` check.
