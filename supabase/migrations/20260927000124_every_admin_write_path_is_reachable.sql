-- 20260927000124 — every admin write path the app calls is actually callable
--
-- WHY THIS FILE EXISTS
-- -------------------
-- Admin screens refused to work, and neither failure was a compile error, a
-- migration error, or anything the static harness could see:
--
--   * changing an administrator's own password ALWAYS failed. The Edge
--     Function tested `email.isNotEmpty` -- a Dart extension method. Deno has
--     no such thing, so it threw a TypeError on the way to the change and the
--     request died as a 500, which the client rendered as "We could not
--     change the password. Try again." A refusal shaped exactly like a policy
--     decision, caused by a crash. Sign-in is email + password, so `email` is
--     populated for effectively every account and the branch always ran.
--
--   * saving a category fee was refused with "That item could not be found. It
--     may have been removed."
--
-- The first was fixed in the function (2026-10-01). The second is what this
-- file exists to ANSWER rather than guess at: the client, the migration text
-- and the live catalog are three things that can disagree, and only one of
-- them is what the server will actually accept.
--
-- WHY A DATABASE ASSERTION AND NOT A STATIC CHECK
-- ----------------------------------------------
-- `check_category_fees_are_wired()` reads the Dart screen and the migration
-- file and confirms they agree with each other. Both can be perfectly
-- consistent and both be wrong about the deployed database: a GRANT added in
-- a migration that was never applied, an overload with the same name and a
-- different arity, a signature PostgREST cannot resolve. Only the live
-- catalog settles it.
--
-- WHAT IS COMPARED
-- ----------------
-- For every admin RPC the app calls:
--
--   1. it EXISTS -- resolved by `to_regprocedure`, which is exact about
--      arity and types, so a same-named function with different arguments
--      counts as missing rather than passing;
--   2. `authenticated` may EXECUTE it -- the role the app actually calls as.
--      A function that exists but is not granted fails at runtime with
--      PGRST202 or 42501 and reads to a user as "not found";
--   3. its declared parameter NAMES are exactly the keys the client sends.
--      PostgREST matches named arguments by name. A client that sends
--      `p_city` against a function declaring `p_city_name` gets
--      "Could not find the function ... with the parameter types you
--      specified" -- PGRST202 -- which `friendlyError` maps to "That item
--      could not be found. It may have been removed." That sentence is the
--      reported symptom, and this is the check that can produce it on
--      purpose.
--   4. it is NOT AMBIGUOUS. Two functions of the same name in `public` make
--      PostgREST answer PGRST203 -- "could not choose the best candidate
--      function" -- for the call, no matter that the expected signature is
--      present, executable and correctly named. `to_regprocedure` still finds
--      it, so every other test here passes and the report says "ok". This was
--      a real blind spot: proven by adding a second `admin_save_category_fee`
--      and reading "ok" back. Overloads are easy to create by accident here,
--      because these migrations restate functions with `CREATE OR REPLACE`,
--      and an arity change silently ADDS an overload rather than replacing
--      one.
--
-- The expected names below are transcribed from the Dart call sites and each
-- one names the file it came from. `check_admin_rpc_argv_is_transcribed()`
-- in the static harness keeps that transcription honest.

-- ===========================================================================
-- 1. The live answer
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.admin_rpc_signature_report()
RETURNS TABLE (
  fn           text,
  present      boolean,
  callable     boolean,
  missing_args text,
  extra_args   text,
  note         text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r     record;
  v_oid regprocedure;
  v_actual text[];
  v_siblings int;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- fn,                      identity,                                      expected arg names
      ('admin_category_fee_catalogue', 'public.admin_category_fee_catalogue()', '{}'),
      ('admin_save_category_fee', 'public.admin_save_category_fee(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric)',
       '{p_category_id,p_city,p_commission_percent,p_commission_min,p_subscription_fee,p_activation_fee,p_ride_base_fare,p_ride_per_km,p_ride_minimum_fare,p_booking_base_fee,p_booking_per_km,p_booking_minimum_fee,p_product_commission_percent,p_product_commission_min,p_product_listing_fee}'),
      ('admin_clear_category_fee', 'public.admin_clear_category_fee(uuid,text)',
       '{p_category_id,p_city}'),
      ('admin_content_reports', 'public.admin_content_reports(text,int)',
       '{p_status,p_limit}'),
      ('admin_moderation_actions', 'public.admin_moderation_actions(int)',
       '{p_limit}'),
      ('admin_moderate_image', 'public.admin_moderate_image(text,text,text,text)',
       '{p_bucket,p_path,p_reason,p_severity}'),
      ('admin_suspend_account', 'public.admin_suspend_account(uuid,text,text)',
       '{p_user_id,p_reason,p_severity}'),
      ('admin_reinstate_account', 'public.admin_reinstate_account(uuid,text)',
       '{p_user_id,p_reason}'),
      ('admin_resolve_content_report', 'public.admin_resolve_content_report(uuid,text,text)',
       '{p_report_id,p_outcome,p_note}'),
      ('file_content_report',
       'public.file_content_report(uuid,uuid,text,text,text,text)',
       '{p_reported_user_id,p_reported_provider_id,p_object_bucket,p_object_path,p_category,p_description}'),
      ('my_transaction_documents', 'public.my_transaction_documents(text,uuid,int)',
       '{p_subject_type,p_subject_id,p_limit}'),
      ('attach_transaction_slip', 'public.attach_transaction_slip(text,text)',
       '{p_document_number,p_path}'),
      ('admin_update_setting', 'public.admin_update_setting(text,jsonb,text)',
       '{p_key,p_value,p_description}'),
      ('admin_fee_catalogue', 'public.admin_fee_catalogue()', '{}'),
      ('is_fee_editor', 'public.is_fee_editor()', '{}')
    ) AS t(fn, ident, expected)
  LOOP
    v_oid := to_regprocedure(r.ident::text);
    v_actual := '{}';
    v_siblings := 0;

    IF v_oid IS NOT NULL THEN
      SELECT coalesce(p.proargnames, '{}') INTO v_actual
        FROM pg_proc p WHERE p.oid = v_oid;
    END IF;

    -- Every function in `public` sharing this name, whatever its arity.
    SELECT count(*) INTO v_siblings
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    fn        := r.fn;
    -- NOT named `exists`: that is a SQL keyword, and `exists := ...` inside
    -- plpgsql is a syntax error rather than a shadow.
    present   := v_oid IS NOT NULL;
    missing_args := coalesce((
      SELECT string_agg(x, ', ' ORDER BY x) FROM unnest(r.expected::text[]) x
       WHERE NOT (x = ANY (v_actual))), '');
    extra_args   := coalesce((
      SELECT string_agg(x, ', ' ORDER BY x) FROM unnest(v_actual) x
       WHERE NOT (x = ANY (r.expected::text[]))), '');
    callable := v_oid IS NOT NULL AND has_function_privilege('authenticated', v_oid, 'EXECUTE');
    note     := CASE
                  WHEN v_oid IS NULL
                    THEN 'MISSING or wrong arity: PostgREST cannot resolve this signature'
                  -- Checked BEFORE the other reasons: when a name is
                  -- ambiguous the call cannot succeed however correct the
                  -- expected signature is, so reporting anything else would
                  -- send an administrator to fix the wrong thing.
                  WHEN v_siblings > 1
                    THEN format('AMBIGUOUS: %s overloads of %s exist in public; '
                                || 'PostgREST cannot choose between them (PGRST203)',
                                v_siblings, r.fn)
                  WHEN NOT callable
                    THEN 'exists, but authenticated may not EXECUTE it -- the call fails at runtime'
                  WHEN missing_args <> ''
                    THEN 'client sends parameter names the function does not declare (PGRST202)'
                  ELSE 'ok'
                END;

    RETURN NEXT;
  END LOOP;
END;
$$;

-- ===========================================================================
-- 2. The assertion the connectivity suite calls
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_admin_write_paths_are_reachable()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text;
  v_ambiguous text;
BEGIN
  SELECT string_agg(format('%s -- %s', r.fn, r.note), '; ' ORDER BY r.fn)
    INTO v_bad
    FROM public.admin_rpc_signature_report() r
   WHERE NOT (r.present AND r.callable AND r.missing_args = '');

  IF v_bad IS NOT NULL THEN
    RETURN 'BROKEN: ' || v_bad;
  END IF;

  -- `present AND callable AND missing_args = ''` cannot see an overload:
  -- to_regprocedure finds the expected signature and the expected signature
  -- is granted. Counted separately so PGRST203 is reported rather than passed.
  SELECT string_agg(fn || ' has more than one overload in public', '; ' ORDER BY fn)
    INTO v_ambiguous
    FROM (
      SELECT DISTINCT s.proname::text AS fn
        FROM pg_proc s
        JOIN pg_namespace n ON n.oid = s.pronamespace
       WHERE n.nspname = 'public'
         AND s.proname IN (
           'admin_category_fee_catalogue', 'admin_save_category_fee',
           'admin_clear_category_fee', 'admin_content_reports',
           'admin_moderation_actions', 'admin_moderate_image',
           'admin_suspend_account', 'admin_reinstate_account',
           'admin_resolve_content_report', 'file_content_report',
           'my_transaction_documents', 'attach_transaction_slip',
           'admin_update_setting', 'admin_fee_catalogue', 'is_fee_editor')
       GROUP BY s.proname
      HAVING count(*) > 1
    ) d;

  IF v_ambiguous IS NOT NULL THEN
    RETURN 'BROKEN: ' || v_ambiguous
           || ' -- PostgREST answers PGRST203 for an ambiguous call, so the '
           || 'expected signature being present and granted is not enough';
  END IF;

  RETURN 'ok: all 15 admin RPCs exist with the arity the client sends, their '
         || 'parameter names match exactly, authenticated may execute each, '
         || 'and none of the names is overloaded';
END;
$$;

REVOKE ALL ON FUNCTION public.admin_rpc_signature_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_rpc_signature_report()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_admin_write_paths_are_reachable() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_admin_write_paths_are_reachable()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_admin_write_paths_are_reachable() IS
  'Reads the LIVE catalog for every admin RPC the app calls and compares the '
  'declared parameter names against the keys the Dart call sites send. '
  'PostgREST matches named arguments by name, so a mismatch is PGRST202, which '
  'friendlyError renders to a user as "That item could not be found. It may '
  'have been removed" -- a sentence about a missing record that is really '
  'about a missing function signature.';

NOTIFY pgrst, 'reload schema';