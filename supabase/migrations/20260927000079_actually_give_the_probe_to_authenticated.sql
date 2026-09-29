-- =============================================================================
-- 20260927000079 — actually give the like probe to authenticated
-- =============================================================================
--
-- 78's mechanism was right and its bookkeeping was wrong. It transferred
-- like_probe_as_client() to "the owner of assert_likes_persist_and_are_exclusive()",
-- on the reasonable-sounding assumption that the caller and the callee were
-- different roles. They are not: both functions are created by the same deploy
-- runner, so that owner is postgres for both, and
--
--   alter function public.like_probe_as_client() owner to <postgres>
--
-- was a no-op. The live database said so in the plainest possible way:
--
--   the like probe is running as postgres, not as authenticated, so every RLS
--   step below would pass without a policy being evaluated
--
-- That message is the probe's own entry check, and it is the reason this was a
-- one-line diagnosis instead of another guessing round: the function refuses to
-- proceed unless current_user really is authenticated, rather than running the
-- whole body and reporting a pass it never earned.
--
-- The target is authenticated, unconditionally. The caller is then granted
-- EXECUTE separately, because the two roles genuinely are different here:
-- postgres calls it, authenticated owns it.
--
-- Grant before the transfer, still: only the owner may GRANT, and immediately
-- after the ALTER this session is no longer the owner. REVOKE from PUBLIC in the
-- same breath, because a SECURITY DEFINER function that any client can call is
-- not something to leave lying around — and the owner needs the grant, not
-- PUBLIC, to reach it.
--
-- No application behaviour changes. This migration only changes who owns a
-- test function and who may call it.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_owner  name;
  v_caller name;
BEGIN
  -- The role that may call this: whoever owns the assertion that builds the
  -- fixtures, captured rather than assumed.
  SELECT pg_get_userbyid(p.proowner) INTO v_caller
    FROM pg_proc p
   WHERE p.oid = 'public.assert_likes_persist_and_are_exclusive()'::regprocedure;

  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'cannot find the owner of assert_likes_persist_and_are_exclusive(), '
                    'so like_probe_as_client() cannot be made callable by it';
  END IF;

  IF NOT EXISTS (select 1 from pg_roles where rolname = 'authenticated') THEN
    RAISE EXCEPTION 'the authenticated role does not exist, so no function can be owned '
                    'by it and the like probe cannot run as a real client';
  END IF;

  -- The current owner, before the transfer, so the GRANT below is legal.
  SELECT pg_get_userbyid(p.proowner) INTO v_owner
    FROM pg_proc p
   WHERE p.oid = 'public.like_probe_as_client()'::regprocedure;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'like_probe_as_client() does not exist; migration 78 must be applied '
                    'before this one';
  END IF;

  EXECUTE 'REVOKE ALL ON FUNCTION public.like_probe_as_client() FROM PUBLIC';
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.like_probe_as_client() TO %I', v_caller);
  EXECUTE 'ALTER FUNCTION public.like_probe_as_client() OWNER TO authenticated';
END;
$$;

-- ---------------------------------------------------------------------------
-- And prove the transfer took, at deploy time, rather than leaving it to be
-- discovered by a failing test run twenty minutes later.
--
-- current_user is checked by CALLING the function, not by reading
-- pg_class/pg_proc: what matters is who Postgres resolves as the effective user
-- inside the body, and only a call answers that. A SECURITY DEFINER function
-- owned by postgres will return true here, which is exactly the bug 78 shipped,
-- so this check cannot pass by inspecting the catalog alone.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_reported text;
BEGIN
  BEGIN
    -- Runs to its first assertion and stops there: the fixtures do not exist in
    -- this transaction, so it fails on the identity check, which is the one
    -- check that does not need fixtures. Anything else is a real problem worth
    -- surfacing here.
    PERFORM public.like_probe_as_client();
  EXCEPTION WHEN OTHERS THEN
    v_reported := SQLERRM;
  END;

  IF v_reported IS NULL THEN
    RAISE EXCEPTION 'like_probe_as_client() ran to completion as authenticated on an empty '
                    'database. Its fixtures are missing, so this is not evidence the owner '
                    'transfer worked -- it means the probe is not checking what it claims to.';
  END IF;

  IF v_reported NOT LIKE '%running as %not as authenticated%' THEN
    RAISE EXCEPTION 'like_probe_as_client() failed on something other than the identity '
                    'check: %', v_reported;
  END IF;

  RAISE NOTICE 'like_probe_as_client() is owned by authenticated and reports the identity '
               'before it does anything else -- the owner transfer took';
END;
$$;

COMMENT ON FUNCTION public.like_probe_as_client() IS
  'WRITE test helper: SECURITY DEFINER and OWNED BY authenticated, so current_user is a real client inside it and row-level security is genuinely evaluated. Never call this directly -- it assumes the fixtures exist. Asserts its own identity on entry and refuses to run otherwise, which is how migration 78''s no-op owner transfer was caught immediately: 77 tried set_config(''role'', ...), which PostgreSQL forbids inside a SECURITY DEFINER function, and 78 transferred the function to the caller''s own role instead of to authenticated.';
