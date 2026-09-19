# Help chat agent

An in-app help assistant for end users. It answers questions using an index of this repo (docs, UI text, code), built on Supabase (pgvector + Edge Functions) and Claude.

## How it fits together
- `lib/features/help_chat/help_chat_screen.dart`: Flutter chat screen. Calls the `repo-chat` Edge Function via `supabase_flutter`.
- `supabase/functions/repo-chat/index.ts`: authenticates the user, rate limits, runs the Claude agent with a `search_app_knowledge` tool.
- `supabase/functions/index-chunks/index.ts`: receives chunks from the indexer, embeds them (gte-small), stores in `repo_chunks`.
- `supabase/migrations/20260919000000_repo_chat.sql`: `repo_chunks`, `match_chunks()`, `chat_usage`, `bump_usage()`.
- `tools/indexer/index.mjs` + `.github/workflows/index-repo.yml`: re-index changed files on every push to `main`.
- `HELP_CHAT_SETUP.md`: deploy steps (secrets, function deploy, GitHub Actions secrets).

## Tasks for a coding agent
1. Wire the screen into the app: add a "Help" entry point (button or menu item) that opens `HelpChatScreen`, following the app's existing routing and theming conventions.
2. Make sure `supabase_flutter` is in `pubspec.yaml` and initialized. Do not add other packages.
3. Adjust `INCLUDE` / `EXCLUDE` in `tools/indexer/index.mjs` to match this repo's real layout (docs folders, l10n files, generated code).
4. Improve retrieval quality by making sure user-facing docs and a `CHANGELOG.md` exist and are current.
5. Run `flutter analyze` and fix issues in the new files.

## Rules
- Never commit secrets (Anthropic key, service role key, `INDEXER_KEY`). They live in Supabase secrets and GitHub Actions secrets only.
- Never deploy functions, run `supabase db push`, or set secrets. The repo owner does that.
- The help agent must never show source code, file paths, or internal details to end users. Keep that rule in the `SYSTEM` prompt in `repo-chat/index.ts`.
- `repo_chunks` must keep RLS enabled with no policies. Only Edge Functions (service role) read it.
- Do not give the agent tools that read or write app user data.
- Keep `index-chunks` protected by the `x-indexer-key` check.
