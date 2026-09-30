-- Correct the profile-completion signature assertion's own expected value.
--
-- WHAT WENT WRONG
-- ---------------
-- 0104's `assert_profile_completion_is_wired()` compared
--
--     p.proargnames::text = 'full_name,phone,city,kebele,street_road'
--
-- but `pg_proc.proargnames` renders as `{p_full_name,p_phone,p_city,p_kebele,
-- p_street_road}` -- braces, and the `p_` prefix the parameters are actually
-- declared with. The comparison could therefore never be true, so the
-- assertion failed on a perfectly correct `complete_profile()`:
--
--     PROFILE_COMPLETION_SIGNATURE: public.complete_profile takes
--     ({p_full_name,p_phone,p_city,p_kebele,p_street_road}), not
--     (full_name,phone,city,kebele,street_road).
--
-- Worth recording what this is: the assertion caught itself being wrong. The
-- RPC it was guarding is fine, the OAuth sign-in it protects works, and the
-- build went red rather than green. Every other fake pass in this repo's
-- history went the other way -- a needle satisfied by a doc comment, a check
-- that matched zero things, an assertion that passed on a table it never
-- opened. A check that is too strict is a nuisance; a check that is too
-- lenient is the thing that costs days.
--
-- THE FIX
-- -------
-- Compare against the array the catalog actually produces, rather than
-- re-spelling it as text. The declared names ARE `p_*` -- that is what the
-- client sends and what PostgREST matches on -- so the assertion should
-- assert that, and print what it found when it differs.

CREATE OR REPLACE FUNCTION public.assert_profile_completion_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_args text[];
  v_dollar text;
  v_expected constant text[] :=
    ARRAY['p_full_name', 'p_phone', 'p_city', 'p_kebele', 'p_street_road'];
BEGIN
  SELECT p.proargnames INTO v_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'complete_profile';

  IF v_args IS NULL THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_MISSING: public.complete_profile does not exist, so an OAuth account can never fill in the phone and address the verification step needs.';
  END IF;

  -- IS DISTINCT FROM, not <>: a NULL element must not make this pass.
  -- The 0104 version compared a text rendering, which also meant a
  -- one-parameter overload would have satisfied nothing at all.
  IF v_args IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_SIGNATURE: public.complete_profile takes (%), not (%). The client calls it with the five p_* names; a rename here is a runtime failure for every OAuth sign-in.',
      v_args, v_expected;
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.complete_profile(text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_NOT_GRANTED: the authenticated role cannot EXECUTE complete_profile, so the "Complete your profile" screen is unreachable.';
  END IF;

  -- The trap this function must not walk into: it may only ever write the
  -- caller's own row. Its target is auth.uid() and it has no id parameter.
  SELECT p.prosrc INTO v_dollar
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'complete_profile'
     AND p.pronargs = 5;

  IF v_dollar IS NULL THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_MALFORMED: the 5-argument complete_profile is not defined.';
  END IF;

  IF v_dollar !~ '(?i)UPDATE\s+public\.profiles' THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_MALFORMED: complete_profile no longer updates public.profiles.';
  END IF;

  -- Self-scoped, stated as a fact rather than inferred from a needle: no
  -- statement in the body may target a table other than profiles, auth.users
  -- (read-only, for the email) and the catalog. A body that grew a second
  -- UPDATE is how one account would end up editing another's identity.
  IF v_dollar ~* '(?i)(INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+public\.[a-z_]+' THEN
    DECLARE v_written text;
    BEGIN
      SELECT string_agg(DISTINCT m[1], ', ') INTO v_written
        FROM regexp_matches(
               v_dollar,
               '(?i)(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+public\.([a-z_]+)',
               'g') AS m;
      IF v_written <> 'profiles' THEN
        RAISE EXCEPTION
          'PROFILE_COMPLETION_TOUCHES_OTHERS: complete_profile writes (%), not only public.profiles. It must only ever write the caller''s own row.',
          v_written;
      END IF;
    END;
  END IF;

  RETURN 'ok: complete_profile(text,text,text,text,text) exists with the five '
         || 'p_* parameters the client sends, is executable by authenticated, '
         || 'and writes only the caller''s own public.profiles row';
END;
$$;

COMMENT ON FUNCTION public.assert_profile_completion_is_wired() IS
  'The SQL half of the OAuth profile-completion gap: the RPC exists, with the '
  'signature the client calls, is executable by authenticated, and writes only '
  'its caller''s own profile row. Corrects 0104, which compared proargnames '
  'against an unprefixed text rendering and so failed on a correct function.';

GRANT EXECUTE ON FUNCTION public.assert_profile_completion_is_wired() TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.assert_profile_completion_is_wired() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
