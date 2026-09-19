-- Knowledge index of the repo (docs, UI strings, Dart, SQL) for the in-app help agent.
create extension if not exists vector;

create table if not exists repo_chunks (
  id          bigint generated always as identity primary key,
  path        text not null,
  start_line  int,
  end_line    int,
  kind        text,
  content     text not null,
  commit_sha  text,
  embedding   vector(384),  -- Supabase built-in gte-small
  fts         tsvector generated always as (to_tsvector('english', content)) stored
);

create index if not exists repo_chunks_embedding_idx on repo_chunks using hnsw (embedding vector_cosine_ops);
create index if not exists repo_chunks_fts_idx on repo_chunks using gin (fts);
create index if not exists repo_chunks_path_idx on repo_chunks (path);

-- RLS on with NO policies: app users can never read the index directly.
-- Only Edge Functions (service role) touch it.
alter table repo_chunks enable row level security;

-- Hybrid search: semantic + keyword, merged with reciprocal rank fusion.
create or replace function match_chunks(
  query_embedding vector(384),
  query_text text,
  match_count int default 6
)
returns table (path text, start_line int, end_line int, content text, score float)
language sql stable as $$
  with sem as (
    select id, row_number() over (order by embedding <=> query_embedding) as r
    from repo_chunks
    order by embedding <=> query_embedding
    limit 20
  ),
  kw as (
    select id, row_number() over (
      order by ts_rank(fts, websearch_to_tsquery('english', query_text)) desc
    ) as r
    from repo_chunks
    where fts @@ websearch_to_tsquery('english', query_text)
    limit 20
  )
  select c.path, c.start_line, c.end_line, c.content,
         (coalesce(1.0 / (60 + sem.r), 0) + coalesce(1.0 / (60 + kw.r), 0))::float as score
  from repo_chunks c
  left join sem on sem.id = c.id
  left join kw on kw.id = c.id
  where sem.id is not null or kw.id is not null
  order by score desc
  limit match_count;
$$;

-- Per-user daily usage counter (rate limit).
create table if not exists chat_usage (
  user_id uuid not null,
  day     date not null default current_date,
  count   int  not null default 1,
  primary key (user_id, day)
);
alter table chat_usage enable row level security;

create or replace function bump_usage(p_user uuid)
returns int
language sql
security definer
set search_path = public
as $$
  insert into chat_usage (user_id) values (p_user)
  on conflict (user_id, day) do update set count = chat_usage.count + 1
  returning count;
$$;

revoke all on function bump_usage(uuid) from public, anon, authenticated;
revoke all on function match_chunks(vector, text, int) from public, anon, authenticated;
