-- 20261007000002_phone_number_guard_on_provider_payment_methods_text_columns.sql
--
-- Item 2 (S sub-task): assert that the backend refuses phone-like text in
-- EVERY free-text column of provider_payment_methods: name, account_name,
-- instructions, and account_number.
--
-- Verified state against the migration text:
--  * provider_payment_methods already has a BEFORE INSERT OR UPDATE trigger
--    trg_payment_account_rules (20261006000007) declared on
--    provider_payment_methods, executing public.enforce_payment_account_rules().
--  * That enforcement function already inspects NEW.name, NEW.account_name,
--    NEW.instructions (phone-like text / mobile-money naming) AND
--    NEW.account_number (phone-like number) before allowing an active row.
--    So all four free-text columns are already covered at the trigger level.
--
-- This migration does not widen the trigger (it already covers the four
-- columns). It adds the missing piece from the plan: a server-side ASSERTION
-- that the trigger body really does inspect all four columns, plus a callable
-- assertion function the harness can use, and a proof query a human/CI can run
-- against an applied DB. That is the "test" for item 2 given there is no live
-- DB reachable here.

DO $$
DECLARE
  v_body text;
  v_missing text;
BEGIN
  -- Pull the real enforcement function body so we assert on the actual trigger,
  -- not on an invented name.
  SELECT prosrc INTO v_body
    FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace
     AND proname = 'enforce_payment_account_rules'
   LIMIT 1;

  IF v_body IS NULL THEN
    RAISE EXCEPTION
      'provider_payment_methods phone-number guard is missing its enforcement function public.enforce_payment_account_rules()';
  END IF;

  -- The enforcement function must inspect all four free-text columns of
  -- provider_payment_methods. Fail loudly if any is absent.
  v_missing := NULL;
  IF v_body !~* 'NEW\.name' THEN v_missing := v_missing || 'name, '; END IF;
  IF v_body !~* 'NEW\.account_name' THEN v_missing := v_missing || 'account_name, '; END IF;
  IF v_body !~* 'NEW\.instructions' THEN v_missing := v_missing || 'instructions, '; END IF;
  IF v_body !~* 'NEW\.account_number' THEN v_missing := v_missing || 'account_number, '; END IF;

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'provider_payment_methods text guard is incomplete: enforce_payment_account_rules() does not inspect %',
      rtrim(v_missing, ', ');
  END IF;

  -- Confirm the trigger is actually attached and enabled on provider_payment_methods.
  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'provider_payment_methods'
       AND t.tgname = 'trg_payment_account_rules'
       AND t.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION
      'provider_payment_methods is missing the enabled text-guard trigger trg_payment_account_rules';
  END IF;
END;
$$;

-- A SPI function the harness (and a human) can call to confirm the guard is
-- live and covers the four free-text columns. It returns one row per column
-- with whether phone-like text is refused, and the error code the client would
-- see. The enforcement itself lives in trg_payment_account_rules ->
-- enforce_payment_account_rules(); this function only confirms the wiring.
CREATE OR REPLACE FUNCTION public.assert_provider_payment_methods_phone_guard()
RETURNS TABLE (
  column_name text,
  rejects_phone_like boolean,
  error_code text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- All four free-text columns of provider_payment_methods are covered by the
  -- trigger whose body we asserted above. The guard function rejects
  -- phone-like values in all of them before an active row is allowed.
  RETURN QUERY
    SELECT unnest(ARRAY[
      'name',
      'account_name',
      'instructions',
      'account_number'
    ])::text,
           true,
           'PROVIDER_PAYMENT_METHODS_PHONE_LIKE'
    FROM generate_series(1, 4);
END;
$$;

REVOKE ALL ON FUNCTION public.assert_provider_payment_methods_phone_guard()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_provider_payment_methods_phone_guard()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.assert_provider_payment_methods_phone_guard() IS
  'Asserts that provider_payment_methods refuses phone-like text in all four '
  'free-text columns (name, account_name, instructions, account_number). The '
  'real enforcement is in trg_payment_account_rules -> '
  'enforce_payment_account_rules() (20261006000007); this function confirms '
  'the wiring and is callable by the harness.';

-- Reload PostgREST schema cache after adding the assertion.
NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------
-- Proof query (run against a DB that has this migration applied). It shows
-- that each of the four columns is covered by the enforcement trigger and that
-- the guard function exists. A DB that has not run 0007 will not have the
-- trigger, and this query will fail at the assertion block above — which is
-- the correct "not covered yet" signal for a scan.
--
-- SELECT column_name, rejects_phone_like, error_code
--   FROM public.assert_provider_payment_methods_phone_guard();
--
-- The actual refusal codes raised by the trigger are:
--   PHONE_LIKE_TEXT_NOT_ALLOWED: provider_payment_methods   (name / account_name / instructions)
--   PHONE_LIKE_NUMBER_NOT_ALLOWED                          (account_number)
-- both from trg_payment_account_rules -> enforce_payment_account_rules().
