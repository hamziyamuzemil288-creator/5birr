-- Help chat: semantic relevance cutoff (free mode)
-- 20260920000000_match_chunks_distance_cutoff.sql
--
-- The previous match_chunks() always returned the top-N nearest chunks with
-- no distance floor, so the repo-chat agent "found" an answer for every
-- input — including greetings and off-topic questions — and its no-match
-- handoff could never trigger. This adds a cosine-distance cutoff to the
-- semantic branch only: chunks farther than 1.05 from the query embedding
-- are dropped. Keyword (FTS) matches keep the old behavior because rare
-- tokens (e.g. a product name) can be legitimately relevant regardless of
-- embedding distance. Greetings and small talk are handled by the agent's
-- fast path, not by retrieval.
--
-- Shape stays identical to 20260919000001: same signature, same columns,
-- service-role-only execution. Idempotent; safe to re-run.

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
    where (kinds is null or kind = any(kinds))
      and embedding <=> query_embedding <= 1.05
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
