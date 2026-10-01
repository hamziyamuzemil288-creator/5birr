-- =============================================================================
-- 20260927000129 — the fee-save assertion ran as its CALLER, and the new field
-- tables were never meant to be written directly
-- =============================================================================
-- Two findings from the first Connectivity run after 0126-0128 reached the live
-- database. Both were invisible while those migrations were pending, because
-- neither the assertion nor the tables existed yet.
--
-- =============================================================================
-- 1. THE ASSERTION PLANNED AS ANON AND GOT PERMISSION DENIED
-- =============================================================================
-- assert_category_fee_save_plans() PLANS an upsert into category_fee_settings
-- under EXPLAIN, which requires INSERT privilege on the table. It was declared
-- without SECURITY DEFINER, so the connectivity suite -- which calls it as the
-- anon client -- got
--
--     42501 permission denied for table category_fee_settings
--
-- and reported it as "The category fee save does not plan", which reads as a
-- defect in the fee save rather than in the assertion. The comment above the
-- function already claimed the plan "runs inside an EXCEPTION block as the
-- function owner"; the attribute was simply missing.
--
-- ALTER FUNCTION rather than a restatement: the body is correct, and restating
-- it would put the whole function on the diff for one attribute.
--
-- Why the local replay was green and the live database red: the probe ran as
-- the database superuser, who has the privilege, so the caller the assertion
-- actually faces in production was never exercised.
ALTER FUNCTION public.assert_category_fee_save_plans() SECURITY DEFINER;
ALTER FUNCTION public.assert_category_fee_save_plans()
  SET search_path = public, pg_temp;

REVOKE ALL ON FUNCTION public.assert_category_fee_save_plans()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_category_fee_save_plans()
  TO anon, authenticated, service_role;

-- =============================================================================
-- 2. THE FIELD TABLES ARE WRITTEN THROUGH DEFINER RPCs, NOT BY THE CLIENT
-- =============================================================================
-- category_profile_fields and provider_profile_field_values are written ONLY
-- through SECURITY DEFINER functions: admin_save_category_profile_field,
-- admin_delete_category_profile_field and save_provider_profile_field (with
-- provider_claim_category writing provider_profiles). The Dart calls those
-- RPCs; it never inserts into either table.
--
-- Supabase grants INSERT/UPDATE/DELETE to the client roles by DEFAULT on every
-- new public table, and both tables carry a FOR ALL policy, so
-- client_write_surface_report() classified them as client-writable and
-- assert_client_write_surface_is_closed() refused them as tables outside the
-- expected list. That refusal is correct: the expected list means "the app
-- writes this client-side", and the app does not.
--
-- The default grant is revoked rather than the tables added to the list,
-- because adding them would silently widen the client write surface to tables
-- no client writes. Nothing needs the grant -- a SECURITY DEFINER function runs
-- with the OWNER's privileges, so the RPCs are unaffected, and SELECT is left
-- in place for the catalogue read policy.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.category_profile_fields FROM PUBLIC, anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.provider_profile_field_values FROM PUBLIC, anon, authenticated;

-- The property, as something a deploy can assert rather than something the
-- write-surface report happens to imply. A later migration that re-grants the
-- default (or an ALTER DEFAULT PRIVILEGES that catches the next table) fails
-- here instead of re-opening the surface silently.
CREATE OR REPLACE FUNCTION public.assert_field_tables_are_not_client_writable()
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
    'category_profile_fields', 'provider_profile_field_values'
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
    RAISE WARNING 'FIELD_TABLE_IS_CLIENT_WRITABLE: %', array_to_string(v_open, ', ');
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_field_tables_are_not_client_writable() IS
  'Fails while a client role holds INSERT/UPDATE/DELETE/TRUNCATE on '
  'category_profile_fields or provider_profile_field_values. Both are written '
  'only through SECURITY DEFINER RPCs, and Supabase grants the client roles '
  'write by default on every new public table -- so this has to be revoked and '
  'has to STAY revoked.';

REVOKE ALL ON FUNCTION public.assert_field_tables_are_not_client_writable()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_field_tables_are_not_client_writable()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
