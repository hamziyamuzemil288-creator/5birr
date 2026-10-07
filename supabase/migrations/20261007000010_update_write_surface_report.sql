-- =============================================================================
-- 20261007000010 — Update client_write_surface_report expected list
--
-- ROOT CAUSE: The RPC client_write_surface_report() has a hard-coded expected
-- list of 21 tables. It does NOT include the three tables that were missing
-- and just created by migration 20261007000009:
--   * client_error_logs
--   * product_likes
--   * provider_payment_methods
--
-- The connectivity test (connectivity_test.dart) expects 23 tables in the
-- expected list: 20 core tables + client_error_logs + product_likes +
-- provider_payment_methods. But the RPC returns only 21, so after creating
-- the 3 tables the actual writable list is 24 (21 expected + 3 newly writable),
-- which the test reports as "unexpected" entries.
--
-- FIX: Re-create the RPC with an updated expected list that includes the 3
-- newly created tables, bringing the expected count from 21 to 24. Wait —
-- the test expects 23, not 24. Let me re-check.
--
-- Actually, looking more carefully:
--   - The original expected list has 21 tables (no client_error_logs,
--     product_likes, provider_payment_methods).
--   - The test expects 23 tables (21 + client_error_logs + product_likes +
--     provider_payment_methods).
--   - After creating the 3 tables, the RPC still returns 21 expected tables.
--   - The actual writable list is now 24 (21 + 3 new tables).
--   - The test sees: expected=21, actual=24, unexpected=3 -> FAIL
--
-- The fix is to add the 3 tables to the RPC's expected list, making it 24.
-- But the test expects 23. So either:
--   (a) The test is wrong (should expect 24), or
--   (b) One of the 3 tables should NOT be in the expected list.
--
-- Looking at the test comment: "20 plus client_error_logs, product_likes and
-- provider_payment_methods" = 23. So the test expects all 3.
--
-- But wait — the original expected list has 21 tables. Let me count them:
--   admin_expenses, admin_notification_broadcasts, appeal_cases,
--   cart_items, chat_logs, favorites, notifications, order_messages,
--   payment_methods, payment_proofs, product_images, products, profiles,
--   provider_profiles, reviews, ride_ratings, support_tickets,
--   user_documents, vehicles, wallet_recharge_requests
-- That's 20 tables, not 21. So the original expected list has 20 tables.
--
-- With the 3 new tables: 20 + 3 = 23. That matches the test!
--
-- So the fix is to add the 3 tables to the expected list, making it 23.
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
      ('cart_items'), ('chat_logs'), ('client_error_logs'), ('product_likes'), ('favorites'),
      ('notifications'), ('order_messages'), ('payment_methods'),
      ('payment_proofs'), ('product_images'), ('products'), ('profiles'),
      ('provider_payment_methods'), ('provider_profiles'), ('reviews'),
      ('ride_ratings'), ('support_tickets'), ('user_documents'),
      ('vehicles'), ('wallet_recharge_requests')
  ),
  public_tables AS (
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
  'Compares the tables the app is expected to write against the ones it can. client_error_logs, product_likes and provider_payment_methods are expected: an app that is failing must be able to record why, a like is written directly under RLS by design, and a provider manages their own payment methods from their dashboard.';

grant execute on function public.client_write_surface_report() to anon, authenticated;
