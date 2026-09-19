# Help chat agent: setup

The help chat runs in **free mode** — no LLM, no API key, no paid services.
Replies are built from the indexed help docs and UI strings using the built-in
embedding model (gte-small). There is no Anthropic dependency.

Secrets in play: `INDEXER_KEY` and `INDEXER_URL` only. Nothing else.

The optional env `LLM_PROVIDER` on the `repo-chat` function defaults to `none`
(the only supported value today).

## 1. Database

The project's migrations are applied with psql (the live database has no
Supabase CLI migration history, so `supabase db push` would replay old
migrations and fail). Apply the help-chat migrations in order:

- `supabase/migrations/20260919000000_repo_chat.sql` — creates `repo_chunks`,
  `match_chunks()`, `chat_usage`, `bump_usage()`
- `supabase/migrations/20260919000001_match_chunks_kinds.sql` — re-creates
  `match_chunks()` with the `kinds` filter used by free mode

Both are idempotent and safe to re-run.

## 2. Secrets and functions

```bash
supabase functions deploy repo-chat
supabase functions deploy index-chunks --no-verify-jwt

supabase secrets set INDEXER_KEY=$(openssl rand -hex 32)   # save this value for step 3
```

There is no `ANTHROPIC_API_KEY` and none should ever be added.

## 3. GitHub Actions secrets (repo → Settings → Secrets → Actions)
- `INDEXER_URL`: `https://<project-ref>.supabase.co/functions/v1/index-chunks`
- `INDEXER_KEY`: the value from step 2

Run the "Index repo for help chat" workflow once manually (full index).
After that, every push to `main` re-indexes only the changed files.

## 4. Flutter
The screen is already wired: Profile → **Help & Support** opens `/help`.
Users must be signed in with Supabase Auth (the function rejects anonymous
calls).

## Tuning
- What the agent learns from: `INCLUDE` / `EXCLUDE` in `tools/indexer/index.mjs`
  (user help content lives in `docs/help/`).
- Answer style and daily limit: `DAILY_LIMIT` in `repo-chat/index.ts`.
- Keep `docs/help/` current: it is the primary source for answers.

## Security notes
- The index table has RLS on with no policies, so app users cannot read it
  directly.
- `match_chunks` is revoked from `public/anon/authenticated`; only Edge
  Functions (service role) can call it.
- The agent only searches the index; it has no access to app user data.
- Secrets patterns are redacted before upload, but never commit real secrets.
- Agent-facing docs (ALL-IN-ONE bundle, setup/handoff/knowledge files) are
  excluded from the index so internal details never reach end users.

## Not done yet (next steps)
- Feedback thumbs and a "contact support" hand-off from inside the chat
- An eval set of real user questions to run after each re-index
