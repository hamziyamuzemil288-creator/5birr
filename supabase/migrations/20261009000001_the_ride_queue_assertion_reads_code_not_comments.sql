-- =============================================================================
-- 20261009000001 — the ride-queue assertion was reading its own explanation
--
-- THE FAILURE (Connectivity CI, Release 1.7.5+112, run #213)
-- ---------------------------------------------------------
--   GPS rides: creation -> claim -> timeout the ride request notifies through
--   the queue, not the guard (failed)
--
--   PostgrestException(message: the ride path bypasses the notification queue:
--     create_ride_request calls insert_notification() directly; on a rider's
--     own call the notification guard raises
--     NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS and rolls the whole ride
--     back, code: P0001)
--
-- THE CAUSE, and it is not the ride path
-- --------------------------------------
-- 20261008000001 routed both call sites through the queue-aware helpers --
-- `PERFORM public.notify_user_safe(...)` for the rider's own notice and
-- `PERFORM public.notify_nearby_drivers(...)` for the fan-out -- and it says so
-- in its own body comment, which names the helper it no longer calls:
--
--     -- NOT insert_notification(): this function is called by a signed-in
--     -- rider, so the notification guard would raise ...
--
-- `pg_proc.prosrc` is the body as the server stored it, COMMENTS INCLUDED. The
-- assertion that same migration added scanned that text with
--
--     IF v_ride ILIKE '%insert_notification%' THEN ...
--
-- so it matched the sentence explaining that the direct call was removed, and
-- raised. The fix shipped correctly and was reported as broken by the check
-- written to protect it. Nothing about create_ride_request, notify_user_safe,
-- notify_best_effort or the notification guard is wrong here, and none of them
-- is touched.
--
-- This is the lesson the Python harness already records for its own body
-- checks (`function_body` strips comments, because a naive count "also counts
-- the header comment that explains the invariant -- which is how a correct file
-- would look like a broken one"). The SQL assertions that read `prosrc` never
-- had that step. Note the converse: leaving comments in makes a body that only
-- *mentions* a legitimate pattern in prose pass a check meant to find the
-- pattern in code.
--
-- WHAT CHANGES
-- ------------
-- Both bodies this assertion inspects are read with their comments REMOVED
-- before anything is matched: line comments (`--` to end of line) and block
-- comments (`/* ... */`) become a space, then whitespace is collapsed. Only
-- then are the patterns looked for, so prose can neither satisfy the check nor
-- fail it.
--
-- One further tightening while the function is restated: a hand-written
-- `INSERT INTO notifications` is the same bypass as the helper call and was
-- not checked at all. 20260927000058's own note names both spellings as the
-- drift its assertion exists to catch. Both bodies are now checked for both.
--
-- WHAT IS NOT CHANGED
-- -------------------
--   * create_ride_request, notify_user_safe, notify_best_effort,
--     notify_nearby_drivers — no body, signature or grant is touched. The ride
--     path itself is already correct.
--   * prevent_notification_injection(), is_server_write(), is_admin().
--   * Every message this function already carried, and its name, its
--     zero-argument signature, its `returns boolean` and its grants.
--
-- Deploy: needs a Supabase deploy (one function body). Connectivity CI stays
-- red until it is applied, because the broken check lives on the live database
-- and this file is what replaces it.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.assert_ride_create_notifies_through_the_queue()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ride text;
  v_fan  text;
  v_bad  text[] := '{}'::text[];
BEGIN
  -- COMMENTS ARE REMOVED BEFORE ANYTHING IS MATCHED, and that is the whole
  -- fix. `prosrc` is the body as stored, comments included, so a body that
  -- says in prose that the direct call was deleted reads exactly like one that
  -- makes it. Line comments go first, then block comments, then whitespace is
  -- collapsed so a line break cannot decide the outcome either.
  SELECT regexp_replace(
           regexp_replace(
             regexp_replace(p.prosrc, E'--[^\n]*', ' ', 'g'),
             '/\*.*?\*/', ' ', 'g'),
           '[[:space:]]+', ' ', 'g')
    INTO v_ride
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';

  IF v_ride IS NULL THEN
    RETURN false;
  END IF;

  -- A direct write on this path is the defect: the caller is a signed-in
  -- rider, so is_server_write() and is_admin() are both false, the guard
  -- raises, and the ride row written one line earlier is rolled back. Both
  -- spellings are checked, because the helper and the hand-written INSERT
  -- bypass the queue identically.
  IF v_ride ILIKE '%insert_notification%'
     OR v_ride ILIKE '%insert into notifications%'
     OR v_ride ILIKE '%insert into public.notifications%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request calls insert_notification() directly; on a rider''s '
      'own call the notification guard raises NOTIFICATIONS_CANNOT_BE_CREATED_'
      'BY_CLIENTS and rolls the whole ride back'];
  END IF;

  IF v_ride NOT ILIKE '%notify_user%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request no longer routes its rider notice through '
      'notify_user(), so the client path writes into notifications directly'];
  END IF;

  -- Same rule and the same comment stripping for the fan-out. It reaches the
  -- guard through its own EXCEPTION WHEN OTHERS swallow, so a direct write
  -- there loses every driver's notice silently instead of rolling anything
  -- back -- quieter than the rider's failure, and just as final.
  SELECT regexp_replace(
           regexp_replace(
             regexp_replace(p.prosrc, E'--[^\n]*', ' ', 'g'),
             '/\*.*?\*/', ' ', 'g'),
           '[[:space:]]+', ' ', 'g')
    INTO v_fan
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'notify_best_effort';

  IF v_fan ILIKE '%insert_notification%'
     OR v_fan ILIKE '%insert into notifications%'
     OR v_fan ILIKE '%insert into public.notifications%' THEN
    v_bad := v_bad || ARRAY[
      'notify_best_effort writes notifications directly; its own swallow '
      'catches the guard''s exception, so every driver near the pickup is '
      'left untold and nothing reports it'];
  END IF;

  IF v_fan IS NULL OR v_fan NOT ILIKE '%notify_user%' THEN
    v_bad := v_bad || ARRAY[
      'notify_best_effort no longer routes through notify_user(), so the '
      'driver fan-out raises into its own swallow and no driver is told'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the ride path bypasses the notification queue: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_ride_create_notifies_through_the_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_ride_create_notifies_through_the_queue()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_ride_create_notifies_through_the_queue() IS
  'Fails when create_ride_request or notify_best_effort writes notifications '
  'directly again: the rider''s own call is a client path, and a direct INSERT '
  'there is rolled back by prevent_notification_injection, which is why no ride '
  'request ever reached the database. Both bodies are read with their comments '
  'removed, because the first version of this check matched the sentence in '
  'create_ride_request explaining why the direct call had been deleted.';

notify pgrst, 'reload schema';
