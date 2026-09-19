-- Help chat: kind-filtered hybrid search (TASK A, free mode)
-- 20260919000001_match_chunks_kinds.sql
--
-- Adds `kinds text[]` to match_chunks() so the repo-chat Edge Function can
-- restrict retrieval to kind IN ('doc','ui_text') — end users must never see
-- source code, file paths, or table names. Signature stays backward
-- compatible: callers that omit `kinds` (none currently) keep old behavior
-- via the default NULL. Same revocation posture as the original function:
-- executable only by the service role (Edge Functions), revoked from
-- public/anon/authenticated.
--
-- Idempotent; safe to re-run.

create or replace function match_chunks(
  query_embedding vector(384),
  query_text text,
  match_count int default 6,
  kinds text[] default null
)
returns table (path text, start_line int, end_line int, content text, score float)
language sql stable as $$
  with sem as (
    select id, row_number() over (order by embedding <=> query_embedding) as r
    from repo_chunks
    where kinds is null or kind = any(kinds)
    order by embedding <=> query_embedding
    limit 20
  ),
  kw as (
    select id, row_number() over (
      order by ts_rank(fts, websearch_to_tsquery('english', query_text)) desc
    ) as r
    from repo_chunks
    where fts @@ websearch_to_tsquery('english', query_text)
      and (kinds is null or kind = any(kinds))
    limit 20
  )
  select c.path, c.start_line, c.end_line, c.content,
         (coalesce(1.0 / (60 + sem.r), 0) + coalesce(1.0 / (60 + kw.r), 0))::numeric::float as score
  from repo_chunks c
  left join sem on sem.id = c.id
  left join kw on kw.id = c.id
  where sem.id is not null or kw.id is not null
  order by score desc
  limit match_count;
$$;

revoke all on function match_chunks(vector, text, int, text[]) from public, anon, authenticated;
