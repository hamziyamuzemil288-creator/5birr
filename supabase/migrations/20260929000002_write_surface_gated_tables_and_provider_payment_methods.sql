-- =============================================================================
-- 20260929000002 — the close the two gated tables needed, and the provider's
-- own payment methods joining the expected list
-- =============================================================================
-- The first Connectivity run after 20260927000142 and 20260929000001 reached
-- the live database reported three tables a client could write that are not on
-- the expected list:
--
--   unexpected (3): approved_location_for_buyers, payment_approval_screenshots,
--                   provider_payment_methods
--
-- Three flagged, two different findings. They are split below because the fix
-- is opposite for each: one pair is server-written and must lose the grant,
-- the other is genuinely a client write and must join the contract.
--
-- =============================================================================
-- 1. THE GATED TABLES ARE SERVER-WRITTEN, SO THE GRANT GOES, NOT THE LIST
-- =============================================================================
-- Both 20260929000001 tables were created with the Supabase DEFAULT grant
-- (INSERT/UPDATE/DELETE to anon and authenticated) plus a FOR ALL policy, so
-- client_write_surface_report() classified them as client-writable and
-- assert_client_write_surface_is_closed() refused them as tables outside the
-- expected list. That refusal is correct: the expected list means "the app
-- writes this client-side", and neither table has a single write in lib/.
--
--   * approved_location_for_buyers — the approved buyer-visible point is set by
--     the server path; 20260929000001's own header says "the server-side RPC
--     owns the write and re-checks ownership". The read is the
--     get_approved_location_for_buyer() RPC.
--   * payment_approval_screenshots — the buyer's upload writes payment_proofs
--     first, and the decision is made by approve_payment_screenshot() /
--     approve_payment_screenshot_provider(); the screen never writes this
--     table.
--
-- This is the same class as 20260927000129, which revoked the default grant on
-- category_profile_fields and provider_profile_field_values for the same
-- reason, and it uses the same remedy: the default grant is revoked rather than
-- the tables added to the list, because adding them would silently widen the
-- client write surface to tables no client writes. Nothing needs the grant —
-- both RPCs are SECURITY DEFINER and run with the OWNER's privileges, so they
-- are unaffected. SELECT is left in place for the read policies.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.approved_location_for_buyers FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.payment_approval_screenshots FROM PUBLIC, anon, authenticated;

-- PostgREST caches table privileges for its schema cache; without this a
-- revoked grant can still be served from the cache.
NOTIFY pgrst, 'reload schema';

-- The property, as something a deploy can assert rather than something the
-- write-surface report happens to imply. A later migration that re-grants the
-- default (or an ALTER DEFAULT PRIVILEGES that catches the next table) fails
-- here instead of re-opening the surface silently. Mirrors
-- assert_field_tables_are_not_client_writable() from 20260927000129.
CREATE OR REPLACE FUNCTION public.assert_gated_tables_are_not_client_writable()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_table text;
  v_priv  text;
  v_open  text[] := ARRAY[]::text[];
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'approved_location_for_buyers', 'payment_approval_screenshots'
  ] LOOP
    -- Unqualified names on purpose: has_table_privilege looks in pg_catalog
    -- first, and a `public.%I` name does not resolve there.
    FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'] LOOP
      IF has_table_privilege('anon', v_table, v_priv)
         OR has_table_privilege('authenticated', v_table, v_priv) THEN
        v_open := v_open || format('%s (%s)', v_table, v_priv);
      END IF;
    END LOOP;
  END LOOP;

  IF array_length(v_open, 1) > 0 THEN
    RAISE WARNING 'GATED_TABLE_IS_CLIENT_WRITABLE: %', array_to_string(v_open, ', ');
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_gated_tables_are_not_client_writable() IS
  'Fails while a client role holds INSERT/UPDATE/DELETE/TRUNCATE on '
  'approved_location_for_buyers or payment_approval_screenshots. Both are '
  'written only through the server path, and Supabase grants the client roles '
  'write by default on every new public table -- so this has to be revoked and '
  'has to STAY revoked.';

REVOKE ALL ON FUNCTION public.assert_gated_tables_are_not_client_writable()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_gated_tables_are_not_client_writable()
  TO anon, authenticated, service_role;

-- =============================================================================
-- 2. THE PROVIDER'S OWN PAYMENT METHODS ARE A GENUINE CLIENT WRITE
-- =============================================================================
-- provider_payment_methods is the opposite finding. PaymentMethodsService
-- (lib/core/services/payment_methods_service.dart) inserts, updates and deletes
-- rows directly, owner-scoped by the provider_payment_methods_owner policy
-- USING owns_provider_profile(provider_id) -- the same shape as products or
-- vehicles, where the ownership policy IS the check. The app really does write
-- it, so the fix is to add it to the expected list on BOTH halves of the
-- contract: the SQL list below and test/client_write_surface_test.dart.
--
-- Body is migration 20260927000070's, unchanged, with one name added. Both
-- copies are hand-maintained (a migration cannot read a Dart file), which is
-- exactly why the closed-surface assertion fails when they drift.
CREATE OR REPLACE FUNCTION public.client_write_surface_report()
RETURNS TABLE (
  kind text,
  tables text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH expected(t) AS (
    VALUES
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('cart_items'), ('chat_logs'), ('client_error_logs'), ('favorites'),
      ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('provider_payment_methods'),
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

COMMENT ON FUNCTION public.client_write_surface_report() IS
  'Compares the tables the app is expected to write against the ones it can. client_error_logs, product_likes and provider_payment_methods are expected: an app that is failing must be able to record why, a like is written directly under RLS by design, and a provider manages their own payment methods from their dashboard.';

GRANT EXECUTE ON FUNCTION public.client_write_surface_report()
  TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
