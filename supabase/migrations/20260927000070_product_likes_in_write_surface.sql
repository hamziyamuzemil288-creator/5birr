-- =============================================================================
-- 20260927000070 — product_likes joins the client write surface
-- =============================================================================
-- Migration 68 added product_likes as a table the app writes DIRECTLY: the
-- like toggle inserts and deletes rows under RLS with no SECURITY DEFINER
-- wrapper, which is deliberate -- the ownership check is the policy.
--
-- Adding a genuine client write means updating BOTH halves of the contract,
-- the SQL expected list and test/client_write_surface_test.dart, and this is
-- the SQL half. Connectivity CI caught the omission on the next run: the
-- closed-surface assertion refuses any writable table that is not on the
-- expected list, so leaving product_likes out would have read as a new hole
-- rather than a missing entry.
--
-- Body is migration 65's, unchanged, with one name added.
-- =============================================================================

create or replace function public.client_write_surface_report()
returns table (
  kind text,
  tables text[]
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  WITH expected(t) AS (
    VALUES
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('cart_items'), ('chat_logs'), ('client_error_logs'), ('favorites'),
      ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('product_images'), ('product_likes'), ('products'), ('profiles'), ('provider_profiles'),
      ('reviews'), ('ride_ratings'), ('support_tickets'), ('user_documents'),
      ('vehicles'), ('wallet_recharge_requests')
  ),
  public_tables AS (
    -- The existence guard, restored. has_table_privilege() resolves a text
    -- argument as a relation name and raises 42P01 when it does not resolve,
    -- so every name handed to it below must come from a relation that is
    -- known to exist. Enumerating pg_policies instead does not guarantee
    -- that, which is how this function ended up throwing on a relation named
    -- "job" that no migration creates.
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
  ),
  writable AS (
    SELECT pt.table_name
    FROM public_tables pt
    WHERE has_table_privilege('authenticated', pt.table_name, 'INSERT')
      AND EXISTS (
        SELECT 1 FROM pg_policies p
        WHERE p.schemaname = 'public'
          AND p.tablename = pt.table_name
          AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      )
  ),
  unguarded AS (
    SELECT w.table_name
    FROM writable w
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = w.table_name
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  SELECT 'expected', COALESCE(array_agg(t ORDER BY t), '{}') FROM expected
  UNION ALL
  SELECT 'unexpected', COALESCE(array_agg(w.table_name ORDER BY w.table_name), '{}')
    FROM writable w
    WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.t = w.table_name)
  UNION ALL
  SELECT 'unguarded', COALESCE(array_agg(table_name ORDER BY table_name), '{}')
    FROM unguarded;
$$;

comment on function public.client_write_surface_report() is
  'Compares the tables the app is expected to write against the ones it can. client_error_logs and product_likes are expected: an app that is failing must be able to record why, and a like is written directly under RLS by design.';

grant execute on function public.client_write_surface_report() to anon, authenticated;
