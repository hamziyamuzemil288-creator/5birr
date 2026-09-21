# Bot knowledge base — release process

The assistant's knowledge lives in three layers:

1. **`docs/help/`** — user-facing articles. Indexed on every push to `main`
   by the *Index repo for help chat* workflow. This is the primary source
   the assistant retrieves from.
2. **Canned answers in `supabase/functions/repo-chat/index.ts`** — the
   `CANNED_TOPICS` array (fast, always-available answers for the core
   flows) plus `INTENT_ROUTES` (deep-link chips under answers) and
   `DATA_QUERY_RES` / `dataReply()` (live account-data answers).
3. **`docs/bot-knowledge.md`** (this file) — the maintenance contract that
   keeps all layers in sync as the app evolves.

## When the app changes, update the bot in the same PR

| App change | Bot update required |
| --- | --- |
| New user-facing feature / screen | New or updated article in `docs/help/`; consider a canned topic for common questions |
| New route | Add to `kKnownRoutes` in `lib/features/help_chat/chat_deep_links.dart`; add matching `INTENT_ROUTES` entries in `repo-chat/index.ts` if reachable from chat |
| New table/column users would ask about | Extend `user_chat_context()` in a new migration and `dataReply()` in `repo-chat/index.ts` |
| Changed flow wording (buttons, screens) | Update the matching `docs/help/` article and `CANNED_TOPICS` text |
| New fee, limit, or policy | Update `docs/help/faq.md` and the relevant canned topic in the same PR |
| Removed feature | Remove or rewrite its article; drop its canned topic and deep links |

## Feedback loop

- The chat screen shows **Helpful?** thumbs on each answer; ratings are
  stored in `chat_logs.helpful`.
- Admins can pull the worst-rated topics with:
  `SELECT * FROM chat_low_rated_summary(30);`
  (intent, thumbs up/down, one sample question — sorted by thumbs down).
- Triage rhythm (weekly or after each release): fix or rewrite the top
  intents, re-index (`FULL=1` via the Index workflow after doc edits), and
  watch the numbers next cycle.
- Unresolved conversations also surface through the existing support-ticket
  flow — `support_tickets` rows with `source = 'HELP_CHAT'` are the
  escalated subset of chat problems.

## Rules that must not regress

- `user_chat_context()` reads only the caller's own data (`auth.uid()`),
  is read-only, and is revoked from `anon`/`public`.
- `chat_logs` is RLS-locked to the owner; only the owner (and the service
  role for logging) touch it.
- Deep links are validated client-side against `kKnownRoutes` — the
  function can never navigate the user anywhere else.
- The assistant must never reveal source paths, table names, or internal
  details (existing retrieval guards keep this guarantee).
