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
-- ── Then the transfer itself failed, for a reason worth writing down ───────
--
--   ERROR: permission denied for schema public (SQLSTATE 42501)
--
-- AlterObjectOwnership checks one thing that is easy not to know about: the NEW
-- owner must hold CREATE on the schema the object lives in. Supabase grants
-- authenticated only USAGE on public, and deliberately never CREATE — a client
-- that can create objects in public is a privilege the platform does not hand
-- out. So the transfer could not be granted into existence, only borrowed.
--
-- Which is what this does: CREATE is granted and revoked inside the one
-- transaction this migration already runs in, so no other session can ever see
-- authenticated holding it. It is not a standing grant, it is a key handed over
-- for exactly one statement and taken back, and the REVOKE is conditional on
-- having granted it, so an environment where authenticated legitimately has
-- CREATE is left alone.
--
-- Grant before the transfer, still, for the older reason: only the owner may
-- GRANT, and immediately after the ALTER this session is no longer the owner.
-- REVOKE from PUBLIC in the same breath, because a SECURITY DEFINER function
-- any client can call is not something to leave lying around — the owner needs
-- the grant, not PUBLIC, to reach it.
--
-- No application behaviour changes. This migration only changes who owns a
-- test function and who may call it.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
  v_caller name;
  v_borrowed_create boolean := false;
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

  IF NOT EXISTS (select 1 from pg_proc
                  where oid = 'public.like_probe_as_client()'::regprocedure) THEN
    RAISE EXCEPTION 'like_probe_as_client() does not exist; migration 78 must be applied '
                    'before this one';
  END IF;

  EXECUTE 'REVOKE ALL ON FUNCTION public.like_probe_as_client() FROM PUBLIC';
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.like_probe_as_client() TO %I', v_caller);

  -- Borrowed, not granted. See the header.
  IF NOT has_schema_privilege('authenticated', 'public', 'CREATE') THEN
    EXECUTE 'GRANT CREATE ON SCHEMA public TO authenticated';
    v_borrowed_create := true;
  END IF;

  EXECUTE 'ALTER FUNCTION public.like_probe_as_client() OWNER TO authenticated';

  -- Handed straight back. Conditional, so an environment that already had it
  -- is not stripped of a privilege it was relying on.
  IF v_borrowed_create THEN
    EXECUTE 'REVOKE CREATE ON SCHEMA public FROM authenticated';
  END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- And prove the transfer took, at deploy time, rather than leaving it to be
-- discovered by a failing test run twenty minutes later.
--
-- current_user is checked by CALLING the function, not by reading pg_proc:
-- what matters is who Postgres resolves as the effective user inside the body,
-- and only a call answers that. A function still owned by postgres reports the
-- identity failure, which is exactly the bug 78 shipped — so an inspection of
-- the catalog could not have caught this one.
--
-- The claims are set first so that the probe gets past the auth.uid() check
-- too. There are no fixtures in this transaction, so the call then stops at
-- the first step that needs one, and that is the expected ending: getting that
-- far is the evidence.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_reported text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',
                     '00000000-0000-4000-8000-00000000e7a1', true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', '00000000-0000-4000-8000-00000000e7a1',
                                       'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.like_probe_as_client();
    v_reported := 'returned normally';
  EXCEPTION WHEN OTHERS THEN
    v_reported := SQLERRM;
  END;

  -- The one failure that means the transfer did not take. Anything else means
  -- it did, including the fixture errors expected here.
  IF v_reported LIKE '%not as authenticated%' THEN
    RAISE EXCEPTION 'the owner transfer still did not take -- %', v_reported;
  END IF;

  RAISE NOTICE 'like_probe_as_client() is owned by authenticated and cleared its identity '
               'check; it then stopped where there are no fixtures to work with: %',
               v_reported;
END;
$$;

COMMENT ON FUNCTION public.like_probe_as_client() IS
  'WRITE test helper: SECURITY DEFINER and OWNED BY authenticated, so current_user is a real client inside it and row-level security is genuinely evaluated. Never call this directly -- it assumes the fixtures exist. Asserts its own identity on entry and refuses to run otherwise, which is how migration 78''s no-op owner transfer was caught immediately: 77 tried set_config(''role'', ...), which PostgreSQL forbids inside a SECURITY DEFINER function, and 78 transferred the function to the caller''s own role instead of to authenticated. Migrating it needs authenticated to hold CREATE on public, which Supabase does not grant, so 79 borrows it for the one statement and revokes it.';
