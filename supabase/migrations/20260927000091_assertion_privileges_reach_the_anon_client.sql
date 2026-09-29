-- 20260927000091 — the new assertions were unreachable by the safety net
--
-- THE BUG
-- ------
-- Deploy ran clean and Connectivity CI still failed all five new tests, with
--
--   PGRST202  Could not find the function ... in the schema cache
--
-- on the first run, and then, after the schema reloaded:
--
--   42501  permission denied for function assert_notify_user_once_is_idempotent
--
-- The functions existed. They were simply not executable by the role that
-- calls them.
--
-- ROOT CAUSE
-- ----------
-- tools/integration_test/connectivity_test.dart builds its client as
--
--   SupabaseClient(_url, _anonKey)
--
-- with no session, so every RPC in that suite runs as the **anon** role. The
-- five new assertions granted EXECUTE to `authenticated, service_role` only,
-- and — the part that actually caused it — explicitly revoked from `anon`:
--
--   REVOKE ALL ON FUNCTION public.assert_...() FROM public, anon;
--   GRANT EXECUTE ON FUNCTION public.assert_...() TO authenticated, service_role;
--
-- A function created in public has EXECUTE for PUBLIC by default, and anon
-- inherits it through PUBLIC. The older assertions in this repo rely on that
-- inheritance: none of them revokes, so they run as anon without anyone
-- noticing. Revoking from anon removed the inherited grant, and nothing
-- granted it back.
--
-- This is why the suite failed with PGRST202 first rather than 42501: the
-- revoked function was hidden from the PostgREST schema cache entirely, and
-- only once the cache reloaded did the real error surface.
--
-- THE FIX
-- -------
-- GRANT EXECUTE to anon, authenticated, service_role — matching the convention
-- every other assertion in this repo already follows, including the write
-- tests (assert_wallet_crediting_writes, assert_likes_persist_and_are_exclu
-- sive), which are deliberately runnable by the anon client.
--
-- Is it safe to let anon call these? Yes, and deliberately so. Each one is
-- either read-only introspection or a write test that raises a sentinel to
-- roll itself back; none of them returns privileged data. That is the same
-- posture the existing write assertions have always had. The genuinely
-- sensitive function in this series, notify_user_once(), keeps its revoke and
-- is NOT granted here: a client that could call it could notify any user id.
--
-- THE LESSON, RECORDED SO IT IS NOT REDISCOVERED
-- ---------------------------------------------
-- The harness cannot catch this class of bug: it reads the .sql file, where
-- the GRANT looks correct, while the failure is in how the file meets the
-- client. So this migration ships an assertion that reads the GRANT back off
-- the live database and compares it to the role the suite actually uses. A
-- future assertion that repeats this mistake fails immediately, naming the
-- function.

GRANT EXECUTE ON FUNCTION public.assert_notify_user_once_is_idempotent()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_approval_welcome_covers_all_paths()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_order_and_ride_receipts_are_sent()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_points_conversion_notifies()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_notification_inbox_is_owner_only()
  TO anon, authenticated, service_role;

-- The call site itself stays server-only. Asserted here as well, because this
-- migration is the one place a reader might be tempted to "fix" the grant
-- problem by opening notify_user_once to the client.
-- (Intentionally no GRANT: see the header.)

-- ---------------------------------------------------------------------------
-- The assertion: every assertion function is executable by the role the
-- connectivity suite actually uses, and notify_user_once is not.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_every_assertion_is_reachable()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_names text[];
  v_name text;
  v_missing text := '';
  v_sig text;
BEGIN
  -- Every function in the public schema whose name starts with assert_ is
  -- registered in the connectivity suite by name, so the whole set is checked
  -- rather than the five added today. This is the class of bug, not the
  -- instance: the next assertion written without anon would otherwise fail
  -- CI the same way.
  SELECT array_agg(p.proname ORDER BY p.proname) INTO v_names
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname LIKE 'assert\_%'
     AND p.pronargs = 0;   -- the zero-argument form the suite calls

  IF v_names IS NULL THEN
    RETURN 'FAIL: no assert_* functions found at all, which means the '
           || 'connectivity suite has nothing to run';
  END IF;

  FOREACH v_name IN ARRAY v_names LOOP
    v_sig := format('public.%s()', v_name);
    -- anon is the role the suite runs as. Checking only `authenticated` is
    -- what let this ship: authenticated could execute them, and the suite
    -- still could not.
    IF NOT has_function_privilege('anon', v_sig, 'EXECUTE') THEN
      v_missing := v_missing || v_name || ', ';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RETURN 'FAIL: the connectivity suite runs as the anon role (SupabaseClient '
           || 'is built with the anon key and no session), but these '
           || 'assertion functions are not executable by it: '
           || rtrim(v_missing, ', ')
           || '. GRANT EXECUTE ... TO anon, authenticated, service_role. A '
           || 'function hidden from anon is reported by PostgREST as PGRST202 '
           || '"could not find the function in the schema cache", which reads '
           || 'like a missing migration rather than a missing privilege.';
  END IF;

  -- The opposite direction, on the one function that must stay closed. If a
  -- future fix opens notify_user_once "so the check can reach it", any client
  -- could then send a notification to any user id of its choosing.
  IF has_function_privilege('anon',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE')
     OR has_function_privilege('authenticated',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE') THEN
    RETURN 'FAIL: notify_user_once() is executable by a client role. It is the '
           || 'call site for money notifications, so a client that could call '
           || 'it could notify any user id. Its REVOKE is what the grant fix '
           || 'above must not undo.';
  END IF;

  RETURN 'ok: all ' || cardinality(v_names)::text
         || ' zero-argument assert_* functions are executable by anon (the '
         || 'role the connectivity suite actually uses), and '
         || 'notify_user_once() remains server-only';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_every_assertion_is_reachable()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_every_assertion_is_reachable()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_every_assertion_is_reachable() IS
  'Every assert_* function the connectivity suite calls must be executable by '
  'anon, because the suite runs as the anon role. Added after five new '
  'assertions failed CI with PGRST202 because they were granted to '
  'authenticated only. Also asserts notify_user_once() is still server-only.';

notify pgrst, 'reload schema';
