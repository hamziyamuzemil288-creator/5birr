-- 20260927000103_money_policy_assertion_rewritten.sql
--
-- The assertion shipped in 0102 raised MONEY_TABLE_MISSING: public.<NULL>.
--
-- WHAT IT DID
-- -----------
-- assert_owner_can_read_and_write_their_money() walked a 2-D array
-- (`v_needed text[][]`, one row per requirement) with a subscripted FOR and
-- read `v_needed[v_i][1]` through a `text[]` row variable. On the live
-- database that produced a NULL table name on the first iteration, so the
-- `SELECT ... FROM pg_class WHERE c.relname = v_table` matched nothing and the
-- function reported a table that has never been missing as the subject:
--
--   MONEY_TABLE_MISSING: public.<NULL> does not exist
--
-- Three things are wrong with that, and only the first is the cause:
--
--   1. the loop did not produce what the code plainly reads as if it did.
--      That could not be reproduced here -- there is no Postgres in the audit
--      environment and no database credentials -- so the cause is not
--      diagnosed. What IS diagnosed is that a 2-D array walked by subscript is
--      a construct this file already has form for: migration 95 records that
--      the 2-D needle table cost two deploy cycles, first a refused FOREACH and
--      then an empty loop.
--   2. a malformed CHECK reported itself as a finding about the schema. A
--      diagnostic that cannot tell "the thing is wrong" from "I am broken"
--      sends the reader to the wrong file. The rewrite below refuses a NULL
--      requirement explicitly instead of searching for a table named NULL.
--   3. and the one that would have mattered most: `v_checked <> array_length(...)`
--      is NULL, not true, when the loop never runs. So the vacuity guard that
--      was supposed to prevent a no-op reading as a pass evaluated to NULL and
--      fell through -- the guard could not fail. That is the same class of
--      failure this whole investigation is about: a check that reports success
--      without having looked.
--
-- WHAT CHANGES
-- ------------
-- The requirement list becomes two flat text[] arrays walked with
-- `FOR v_table, v_cmd IN SELECT * FROM unnest(v_tables, v_cmds)` -- byte for
-- byte the shape migration 0101 uses for its bucket loop, and 0101 is live and
-- passing. No array-typed loop variable, no subscripting, no row variable.
--
-- Two guards are added:
--
--   * a NULL table or command raises MONEY_CHECK_MALFORMED naming itself,
--     before any catalog lookup, so a future failure of this loop reports as
--     its own bug rather than as a missing table; and
--   * the vacuity guard compares with coalesce, so "the loop never ran" is a
--     failure rather than a NULL that falls through.
--
-- The policies this assertion inspects are untouched. Migration 0102 already
-- created them and the live bucket assertion now reports user-documents with
-- a write policy and four read policies, which it did not before.

CREATE OR REPLACE FUNCTION public.assert_owner_can_read_and_write_their_money()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Two flat arrays, zipped by unnest. Flat on purpose: a 2-D array walked by
  -- subscript is the construct that broke the first version of this function.
  v_tables text[] := ARRAY[
    'wallets', 'wallet_recharge_requests', 'wallet_recharge_requests'
  ];
  v_cmds text[] := ARRAY[
    'SELECT', 'INSERT', 'SELECT'
  ];
  -- loop variables, declared here because FOR-over-a-query binds them
  v_table text;
  v_cmd text;
  v_found int;
  v_rls boolean;
  v_report text := '';
  v_checked int := 0;
  v_expected int;
BEGIN
  -- Every command is the one a signed-in, NON-staff provider must be able to
  -- perform on their own row. A policy only counts if it names the caller:
  -- `wallets_staff_read` exists on wallets and satisfies nobody but staff,
  -- which is precisely why the recharge screen found no wallet.
  FOR v_table, v_cmd IN
    SELECT * FROM unnest(v_tables, v_cmds)
  LOOP
    -- Refuse our own breakage before reading the catalog. Without this, a loop
    -- that yields nothing finds no table and reports a table that has always
    -- existed as missing.
    IF v_table IS NULL OR v_cmd IS NULL THEN
      RAISE EXCEPTION
        'MONEY_CHECK_MALFORMED: the requirement list yielded a NULL table or command, so this assertion is broken rather than the schema. Do not act on it as a finding.';
    END IF;

    v_checked := v_checked + 1;

    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_table;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'MONEY_TABLE_MISSING: public.% does not exist, so the client path that queries it fails', v_table;
    END IF;

    -- Names the caller: auth.uid() or the SECURITY DEFINER ownership helper.
    -- Deliberately NOT is_admin() and NOT a staff permission check -- a
    -- provider is neither, and that is the entire bug this migration's
    -- policies fix.
    SELECT count(*) INTO v_found
      FROM pg_policies p
     WHERE p.schemaname = 'public'
       AND p.tablename = v_table
       AND p.cmd IN (v_cmd, 'ALL')
       AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
           ~ '(auth\.uid|owns_provider_profile)';

    IF v_found = 0 THEN
      RAISE EXCEPTION
        'MONEY_ROUTE_CLOSED: public.% has no % policy that names the caller, so a signed-in provider gets zero rows / a refused write. The wallet and recharge screens read and write exactly this, and the failure reaches the user as "That item could not be found" because the client throws its own not-found on an empty result.',
        v_table, v_cmd;
    END IF;

    IF NOT v_rls THEN
      RAISE EXCEPTION
        'MONEY_TABLE_RLS_OFF: row level security is DISABLED on public.%, so any role holding the grant reads every provider''s balance and every provider''s recharge requests. A policy on such a table is decorative.',
        v_table;
    END IF;

    v_report := v_report || v_table || ':' || v_cmd || ' ok; ';
  END LOOP;

  -- coalesce, and the whole point of this rewrite: `0 <> NULL` is NULL, which
  -- IF treats as false, so the previous guard could not fail.
  v_expected := coalesce(array_length(v_tables, 1), 0);
  IF v_checked <> v_expected OR v_expected = 0 THEN
    RAISE EXCEPTION
      'MONEY_POLICY_CHECK_VACUOUS: checked % of % requirements, so a table with no caller-named policy was never examined',
      v_checked, v_expected;
  END IF;

  RETURN 'ok: a provider can ' || rtrim(v_report)
         || '-- every one is owner-scoped and RLS is on';
END;
$$;

COMMENT ON FUNCTION public.assert_owner_can_read_and_write_their_money() IS
  'Requires a caller-named policy -- one mentioning auth.uid() or '
  'owns_provider_profile() -- for SELECT on wallets and for INSERT and SELECT '
  'on wallet_recharge_requests, and requires RLS to be enabled on both. A '
  'staff-scoped policy does not count: wallets_staff_read and '
  'wallet_recharge_requests_staff_read are the only policies any executed '
  'migration created on these tables, and neither is reachable by a provider, '
  'which is why submitting a recharge reported "That item could not be '
  'found". The requirement list is two flat arrays walked with unnest, the '
  'shape migration 0101 uses, and the function refuses a NULL requirement and '
  'fails vacuously-checked runs rather than reporting its own breakage as a '
  'finding about the schema.';

REVOKE ALL ON FUNCTION public.assert_owner_can_read_and_write_their_money() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_owner_can_read_and_write_their_money() TO anon, authenticated, service_role;

notify pgrst, 'reload schema';
