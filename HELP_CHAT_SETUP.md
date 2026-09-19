# Help chat agent: setup

## 0. Add it to your repo
```bash
unzip help-chat-agent.zip && cd help-chat-agent
bash install.sh /path/to/your/repo --push   # copies files, commits only them, pushes branch feat/help-chat-agent
```
Drop `--push` to just copy files and print the git commands. Existing files are never overwritten, and `knowledge.md` (read by Codebuff) is appended to, not replaced.
Then open a pull request on GitHub. If the push is rejected for `.github/workflows`, your token needs the `workflow` scope.

## 1. Database
```bash
supabase db push        # applies supabase/migrations/20260919000000_repo_chat.sql
```

## 2. Secrets and functions
```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase secrets set INDEXER_KEY=$(openssl rand -hex 32)   # save this value for step 3

supabase functions deploy repo-chat
supabase functions deploy index-chunks --no-verify-jwt
```

## 3. GitHub Actions secrets (repo → Settings → Secrets → Actions)
- `INDEXER_URL`: `https://<project-ref>.supabase.co/functions/v1/index-chunks`
- `INDEXER_KEY`: the value from step 2

Run the "Index repo for help chat" workflow once manually (full index). After that, every push to `main` re-indexes only the changed files.

## 4. Flutter
Add the screen and route to it (e.g. from a Help button):
```dart
Navigator.push(context, MaterialPageRoute(builder: (_) => const HelpChatScreen()));
```
Users must be signed in with Supabase Auth (the function rejects anonymous calls).

## Tuning
- `INCLUDE` / `EXCLUDE` in `tools/indexer/index.mjs`: what the agent may learn from.
- `SYSTEM` prompt and `DAILY_LIMIT` in `repo-chat/index.ts`.
- Keep a `CHANGELOG.md` and user-facing docs in the repo: they give the best answers.

## Security notes
- The index table has RLS on with no policies, so app users cannot read it directly.
- The agent only searches the index; it has no access to your app's user data.
- Secrets patterns are redacted before upload, but never commit real secrets.
- Add any private/internal paths to `EXCLUDE`.

## Not done yet (next steps)
- Streaming replies (currently one response per message)
- An eval set of real user questions to run after each re-index
- Feedback thumbs and a "contact support" hand-off
