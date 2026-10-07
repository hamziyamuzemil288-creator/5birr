-- =============================================================================
-- 20261007000013 — Add banks to client_write_surface_report expected list
--
-- ROOT CAUSE: The client_write_surface_report() RPC has a hard-coded expected
-- list that does NOT include 'banks'. But the app DOES write to banks (the
-- admin edits bank account numbers for payment processing), so 'banks' should
-- be in the expected list.
--
-- The connectivity test reports 'banks' as an unexpected writable table because
-- it's writable (via service_role inheritance) but not in the expected list.
--
-- FIX: Add 'banks' to the expected list in client_write_surface_report().
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
      ('banks'), ('cart_items'), ('chat_logs'), ('client_error_logs'),
      ('client_write_surface_report'),
      ('favorites'), ('notifications'), ('order_messages'),
      ('payment_methods'), ('payment_proofs'), ('product_images'),
      ('products'), ('profiles'), ('provider_payment_methods'),
      ('provider_profiles'), ('reviews'), ('ride_ratings'),
      ('support_tickets'), ('user_documents'), ('vehicles'),
      ('wallet_recharge_requests')
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
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\\(\\)'
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
  'Compares the tables the app is expected to write against the ones it can. Includes banks because the admin writes bank account numbers for payment processing.';

grant execute on function public.client_write_surface_report() to anon, authenticated;
