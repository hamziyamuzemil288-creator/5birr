-- Close the client write surface: no table outside the app's twenty is writable.
--
-- WHAT THE REPORT HAS BEEN SAYING
-- -------------------------------
-- client_write_surface_report() has printed the same shape for three runs:
--
--   expected   (20)  the tables the app writes directly
--   unexpected (21)  public tables a client can INSERT into, that the app
--                    never writes
--   unguarded   (8)  ...of which these have no admin-gated policy visible
--
-- The numbers were measured rather than guessed, and the guess was never used
-- to justify a revoke. It was read first, and then the three tables with a
-- real finding were closed in 20260927000046: user_roles (a WITH CHECK (true)
-- policy on PUBLIC made any signed-in user an ADMIN), email_otp_codes (a
-- client could seed its own verification row and pass the signup gate with no
-- email), and order_items (a write path the app does not have).
--
-- That left twenty-one. Every one of them is behind RLS with an admin or owner
-- policy, so none is an escalation -- and every one of them is a grant that
-- nothing in the app uses. The history of this codebase says exactly why that
-- is worth removing anyway: 0033 widened a storage policy to
-- `bucket_id = 'product-images'` with no path check, and any signed-in account
-- could overwrite any provider's listing photo until 20260927000048; 0021
-- shipped a PUBLIC policy with WITH CHECK (true) on user_roles. Both were
-- POLICY mistakes that only became exploitable because a GRANT was already
-- there. A grant nobody needs is the half of the pair that can be removed
-- today, and RLS mistakes are the half that keeps happening.
--
-- WHAT MAKES THIS SAFE TO DO NOW
-- ------------------------------
-- The reason this was deferred twice is that the effective state cannot be read
-- from the migration files -- a policy created in 0002 and dropped in
-- 20260927000014 appears in both. So the question was not "which policies
-- exist" but "does anything write these tables by a path that a revoke would
-- break", and that is answerable: every way a table can be written.
--
--   * the app, directly -- excluded by test/client_write_surface_test.dart,
--     which scans lib/ and fails on a direct write to any table outside the
--     twenty. It passes, and it is the reason the twenty are trusted;
--   * a SECURITY DEFINER function -- unaffected, because the owner is not
--     subject to the revoked role's grants. Every writer of every one of these
--     twenty-one tables was checked: 550 function bodies parsed, and NOT ONE
--     invoker writer exists for any of them;
--   * service_role (the Edge Functions) -- unaffected, it is not one of the two
--     roles being revoked from;
--   * a trigger -- checked with the functions that contain them, which is where
--     a trigger's SQL lives;
--   * another client outside this repository -- the one thing that cannot be
--     verified from here. Nothing in this repo suggests one exists, and if it
--     does, it is using the anon key that ships inside the app bundle, which
--     means it is already as reachable as the app itself.
--
-- THE REVOKE IS COMPUTED, NOT LISTED
-- ----------------------------------
-- The twenty-one names could be pasted in. They are deliberately not: the list
-- is the OUTPUT of a query, and the invariant is "a client may write the twenty
-- tables the app writes, and nothing else". So the migration walks the public
-- base tables that a client role can write and revokes on every one that is not
-- in the expected list -- which also catches a table that has an INSERT grant
-- and no policy at all. Those are invisible to the report on purpose (it
-- requires a policy to be interesting) and they are exactly as stale.
--
-- The expected list is the same twenty that appear in
-- client_write_surface_report(), test/client_write_surface_test.dart and
-- expectedClientWrites. Three copies is already two too many, which is why
-- assert_client_write_surface_is_closed() below now fails if the report's
-- `unexpected` bucket is not empty: the copies cannot drift without the build
-- saying so.

-- ===========================================================================
-- 1. Revoke write privileges on everything the app does not write
-- ===========================================================================
DO $$
DECLARE
  -- The contract, spelled the same way as client_write_surface_report().
  c_expected constant text[] := ARRAY[
    'admin_expenses', 'admin_notification_broadcasts', 'appeal_cases',
    'cart_items', 'chat_logs', 'favorites', 'notifications',
    'order_messages', 'payment_methods', 'payment_proofs',
    'product_images', 'products', 'profiles', 'provider_profiles',
    'reviews', 'ride_ratings', 'support_tickets', 'user_documents',
    'vehicles', 'wallet_recharge_requests'
  ];
  c_privs constant text[] := ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'];
  c_roles constant text[] := ARRAY['anon', 'authenticated'];
  t text;
  p text;
  r text;
  v_touched int := 0;
  -- Distinct table names, for the NOTICE only. A text[] and not a
  -- comma-joined string: the count of a string has to be re-derived with
  -- string_to_array, which returns {''} for an empty input and would report
  -- one table when nothing was touched.
  v_names text[] := ARRAY[]::text[];
BEGIN
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'          -- ordinary tables; views and matviews are
                                    -- governed by their own rules
      AND NOT (c.relname = ANY (c_expected))
    ORDER BY c.relname
  LOOP
    FOREACH r IN ARRAY c_roles LOOP
      FOREACH p IN ARRAY c_privs LOOP
        IF has_table_privilege(r, t, p) THEN
          -- Unqualified table name, unqualified privilege, role as text.
          -- has_table_privilege looks in pg_catalog first and a
          -- format('public.%I', ...) name does not resolve there -- the mistake
          -- that made the first write-surface report print
          -- `relation "public.objects" does not exist` while staying green.
          EXECUTE format('REVOKE %s ON public.%I FROM %I', p, t, r);
          v_touched := v_touched + 1;
          IF NOT (t = ANY (v_names)) THEN
            v_names := v_names || t;
          END IF;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  -- A silent privilege change on production tables is not something to
  -- discover later from a log. RAISE takes a bare % as its placeholder (it is
  -- format() that wants %s and raises on a bare one), so these are deliberately
  -- not the same shape as the format() calls above.
  RAISE NOTICE 'revoked % write privileges across % tables: %',
    v_touched, cardinality(v_names), array_to_string(v_names, ', ');
END $$;

-- PostgREST caches table privileges for its schema cache; without this a
-- revoked grant can still be served from the cache.
NOTIFY pgrst, 'reload schema';

-- ===========================================================================
-- 2. The assertion grows the half that makes the contract checkable
-- ===========================================================================
-- Two things are asserted that were not before:
--
--   * the report's `unexpected` bucket must be EMPTY. Before this migration it
--     held twenty-one tables, which is a number nobody could act on; now it is
--     a number that means "something new became client-writable", and that is
--     worth failing a build over. This is the check that makes the three
--     hand-maintained copies of the twenty-table list fail loudly instead of
--     drifting;
--   * an admin-scoped policy that a client can technically reach is not a
--     finding. user_roles_admin_write is TO public with WITH CHECK
--     (is_admin()) and always was -- the escalation 20260927000046 closed was
--     `Service role can insert roles`, WITH CHECK (true), ORing past it. The
--     rule is "no client-reachable policy that never names a caller".
CREATE OR REPLACE FUNCTION public.assert_client_write_surface_is_closed()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tables constant text[] := ARRAY['user_roles', 'email_otp_codes', 'order_items'];
  v_privs  constant text[] := ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'];
  v_table  text;
  v_priv   text;
  v_policy text;
  v_wide   text;
  v_extra  text;
  v_problems text[] := ARRAY[]::text[];
BEGIN
  -- Half 1: the three tables whose escalation was live get a direct grant
  -- check, because they are the ones where a re-grant would be immediately
  -- exploitable rather than merely stale.
  FOREACH v_table IN ARRAY v_tables LOOP
    FOREACH v_priv IN ARRAY v_privs LOOP
      IF has_table_privilege('anon', v_table, v_priv)
         OR has_table_privilege('authenticated', v_table, v_priv) THEN
        v_problems := v_problems || format(
          '%s: %s is still granted to a client role', v_table, v_priv);
      END IF;
    END LOOP;

    FOR v_policy IN
      SELECT format('%s (%s)', p.policyname, p.cmd)
      FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = v_table
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND p.roles::text[] && ARRAY['public', 'anon', 'authenticated']
        -- Both expression columns, because an INSERT policy keeps its whole
        -- rule in WITH CHECK and has no USING clause to read.
        AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
              !~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
    LOOP
      v_problems := v_problems || format(
        '%s: policy %s applies to a client role and never names a caller', v_table, v_policy);
    END LOOP;
  END LOOP;

  -- Half 2: nothing outside the app's own list is client-writable at all.
  SELECT string_agg(x.t, ', ' ORDER BY x.t) INTO v_extra
  FROM public.client_write_surface_report() r,
       unnest(r.tables) AS x(t)
  WHERE r.kind = 'unexpected';
  IF v_extra IS NOT NULL THEN
    v_problems := v_problems || format(
      'tables a client can write that the app never writes: %s', v_extra);
  END IF;

  -- Half 3: no client-reachable write policy anywhere is unconditional.
  SELECT string_agg(format('%s (%s)', d.table_name, d.cmd), ', ' ORDER BY d.table_name)
    INTO v_wide
    FROM public.client_write_policy_detail() d
   WHERE d.verdict = 'WIDE';
  IF v_wide IS NOT NULL THEN
    v_problems := v_problems || format('client-reachable WIDE write policies: %s', v_wide);
  END IF;

  IF array_length(v_problems, 1) > 0 THEN
    RAISE WARNING 'CLIENT_WRITE_SURFACE_IS_OPEN: %', array_to_string(v_problems, ' | ');
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_client_write_surface_is_closed() IS
  'Three halves of one contract. (1) No client role holds '
  'INSERT/UPDATE/DELETE/TRUNCATE on user_roles, email_otp_codes or order_items, '
  'and no client-reachable policy on those three is unconditional -- the '
  'escalation 20260927000046 closed was a WITH CHECK (true) beside a correct '
  'admin policy. (2) client_write_surface_report()''s unexpected bucket is '
  'empty: nothing outside the twenty tables the app writes is client-writable. '
  '(3) No client-reachable write policy in the schema is WIDE. An admin-scoped '
  'policy a client can technically reach is not a finding; the grant is what '
  'closes a table.';
