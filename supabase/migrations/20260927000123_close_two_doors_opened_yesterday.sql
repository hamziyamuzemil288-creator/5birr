-- 20260927000123 — close two doors that 0122 opened
--
-- 0122 deployed, and the connectivity suite immediately went red on two
-- counts. Both are about what 0122 did, and both are this file's job.
--
-- 0121 and 0122 are APPLIED. Nothing here edits them. This is a new migration
-- that changes the live schema from where it actually is, which is the only
-- honest way to fix a deployed file -- restating history is how a database and
-- its repository stop telling the same story.
--
-- ---------------------------------------------------------------------------
-- 1. A twenty-first client-writable table
-- ---------------------------------------------------------------------------
-- The failure:
--
--   One of three: a client role can write user_roles, email_otp_codes or
--   order_items again; a table outside the twenty the app writes became
--   client-writable; or a write policy a client can reach never names a
--   caller.
--
-- It is the middle one, and 0122 caused it. 0122 granted
--
--   GRANT SELECT, INSERT, UPDATE ON public.content_reports TO authenticated
--
-- and added an INSERT policy so a reporter could file one directly. That put
-- `content_reports` outside the twenty `client_write_policy_detail()` names,
-- and that function is a CONTRACT, not a suggestion: it exists so the set of
-- tables a signed-in customer can write is small enough to read in one sitting.
--
-- The tempting fix is to add `content_reports` to the array and move on. That
-- is the wrong fix: it grows the surface to accommodate the mistake.
--
-- `file_content_report()` already exists, is SECURITY DEFINER, and does
-- everything the direct write was for -- it validates that a description was
-- given and is long enough, that the report names something at all, it folds a
-- duplicate into the existing open case instead of double-queuing it, and it
-- cannot be used to write somebody else's report because the reporter id comes
-- from `auth.uid()` and not from a parameter. The direct INSERT policy was a
-- second, weaker door to the same table, and it bypassed every one of those.
--
-- So the door closes. Reports are written by the function and read by SELECT.

-- ===========================================================================
-- 1. Only the function writes a report
-- ===========================================================================
DROP POLICY IF EXISTS content_reports_insert ON public.content_reports;
DROP POLICY IF EXISTS content_reports_update_own ON public.content_reports;

-- REVOKE, not just DROP POLICY: a grant without a policy is inert under RLS,
-- but the grant is what `client_write_policy_detail()` reports on, and leaving
-- it would leave the surface looking closed and the privilege still present.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.content_reports FROM anon, authenticated;
GRANT SELECT ON public.content_reports TO authenticated, service_role;

COMMENT ON TABLE public.content_reports IS
  'The moderation queue. Rows are written ONLY by file_content_report(), which '
  'is SECURITY DEFINER and validates the report before it is accepted; a client '
  'holds SELECT and nothing else. Never grant a direct INSERT here: the function '
  'is the only write path that folds a duplicate into the open case instead of '
  'queueing it twice, and it takes the reporter from auth.uid() so a report '
  'cannot be filed against somebody else.';

-- The reporter reading their own reports still works: that is the SELECT
-- policy from 0122, untouched.
DROP POLICY IF EXISTS content_reports_read ON public.content_reports;
CREATE POLICY content_reports_read ON public.content_reports
  FOR SELECT TO authenticated
  USING (
    reporter_user_id = (SELECT auth.uid())
    OR reported_user_id = (SELECT auth.uid())
    OR public.is_admin()
  );

-- ===========================================================================
-- 2. Reinstatement says something
-- ===========================================================================
-- The failure:
--
--   FAIL: these functions set provider_profiles.status to APPROVED but send no
--   welcome: admin_reinstate_account. Either they are a first approval and need
--   a welcome, or they belong in the reinstatement allowlist with a stated
--   reason.
--
-- `admin_reinstate_account` is NOT a first approval. The account was approved
-- once already; it was suspended afterwards, and reinstating it returns
-- somebody who already knows the platform to a working account. Sending
-- "Welcome to Aliob, <name>" to them would be wrong -- they were never
-- leaving, and a welcome implies they were.
--
-- So it does the second thing the assertion offers: it is allowlisted, with
-- the reason stated, AND it sends its own notice, which is what a person who
-- has been suspended and then reinstated actually needs to hear. Both halves,
-- because the assertion only requires the allowlist entry and the USER only
-- benefits from the notification.
--
-- Restated in FULL, because this repository's rule is that a function which
-- writes a status must not be edited piecemeal -- the guards are named and
-- checked by tools/harness/restatement_diff.py, and every clause below is the
-- one 0122 wrote.
CREATE OR REPLACE FUNCTION public.admin_reinstate_account(
  p_user_id uuid,
  p_reason  text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor      uuid;
  v_actor_name text := '';
  v_name       text := '';
  v_provider   uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_name
    FROM public.profiles WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_SUCH_ACCOUNT';
  END IF;

  SELECT (SELECT full_name) INTO v_actor_name FROM public.profiles WHERE id = v_actor;
  v_actor_name := coalesce(v_actor_name, '');

  -- BOTH tables, profiles first. The router gates on `profiles.status`, the
  -- admin panel reads `provider_profiles.status`, and a half-written
  -- reinstatement is exactly what assert_profile_status_synced exists to
  -- catch.
  UPDATE public.profiles SET status = 'APPROVED', updated_at = now()
   WHERE id = p_user_id;

  SELECT pp.id INTO v_provider FROM public.provider_profiles pp
   WHERE pp.user_id = p_user_id;

  IF v_provider IS NOT NULL THEN
    UPDATE public.provider_profiles SET status = 'APPROVED', updated_at = now()
     WHERE id = v_provider;
  END IF;

  -- The notice. Keyed on the user id and this event, so a second reinstatement
  -- of the same account does not pile up duplicates in the inbox, and so it
  -- cannot be used as a way to message an arbitrary person.
  PERFORM public.notify_user_once(
    'account-reinstated:' || p_user_id::text,
    p_user_id,
    'APPROVAL',
    'Your account is active again',
    coalesce(
      'Your account has been reinstated'
      || CASE WHEN btrim(coalesce(p_reason, '')) <> ''
              THEN '. ' || btrim(p_reason) ELSE '.' END
      || ' Sorry for the inconvenience.',
      'Your account has been reinstated. Sorry for the inconvenience.'),
    jsonb_build_object('event', 'account_reinstated',
                       'actor', v_actor,
                       'provider_id', v_provider));

  INSERT INTO public.moderation_actions (
    action_type, severity, reason, target_user_id, target_provider_id,
    detail, actioned_by, actioned_by_name)
  VALUES (
    'ACCOUNT_REINSTATED', 'MODERATE', coalesce(nullif(btrim(p_reason), ''), 'No reason given'),
    p_user_id, v_provider,
    jsonb_build_object('account_name', v_name), v_actor, coalesce(v_actor_name, ''));

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'ACCOUNT_REINSTATED_BY_ADMIN', 'profiles', p_user_id,
          jsonb_build_object('reason', coalesce(p_reason, 'No reason given')));

  RETURN 'ok: reinstated ' || coalesce(nullif(v_name, ''), p_user_id::text);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reinstate_account(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reinstate_account(uuid, text)
  TO authenticated, service_role;

-- ===========================================================================
-- 3. The allowlist, with the reason written down
-- ===========================================================================
-- `assert_approval_welcome_covers_all_paths()` lists every function that runs
-- `UPDATE public.provider_profiles SET status = 'APPROVED'` and requires each
-- to either send a welcome or be on its reinstatement allowlist with a stated
-- reason.
--
-- It is restated VERBATIM below, with exactly one change: one more name in that
-- array. Not retyped from a description of what it does.
--
-- The first attempt at this file restated it from memory and dropped the
-- self-approval refusal check, the wallet-creation check, the subscription-
-- creation check, the `notify_user_once` check on `approve_provider`, all three
-- of `approve_user`'s checks, and the `update public.provider_profiles set
-- status = 'APPROVED'` regex that gives the coverage clause its precision --
-- replacing it with a loose `prosrc ILIKE '%status%APPROVED%'` and a hardcoded
-- `proname NOT IN (...)`. That would have SHIPPED a weaker assertion than the
-- one already protecting this platform, in a migration whose stated purpose is
-- to close a hole. The body below is copied character-for-character out of
-- 20260927000087; `git diff` between the two is the allowlist and its comment.
CREATE OR REPLACE FUNCTION public.assert_approval_welcome_covers_all_paths()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_missing text := '';
  v_covered text;
  v_uncovered text;
  v_clause text;
  v_names text[];
  v_fn text;
  -- approve_provider's authorization conditions, each named so a restatement
  -- that drops one is reported by name rather than as a generic failure.
  v_required_clauses text[] := ARRAY[
    'admin_can(''registrations'')',
    'p_admin_id is distinct from auth.uid()',
    'staff_is_action_manager()',
    'staff_scope_allows_category('
  ];
  -- Functions that write APPROVED but are NOT a first approval. Each is
  -- excluded for a stated reason; a new name may not be added here without one.
  v_reinstatement_allowlist text[] := ARRAY[
    'charge_due_subscriptions',   -- restores a fee-suspended account
    -- 20260927000123. Returns an account that was approved once already, after
    -- a suspension. Not a first approval, so it does not send a welcome -- it
    -- sends "Your account is active again", keyed on the account. Listed here
    -- because this assertion scans every function whose body runs
    -- `UPDATE public.provider_profiles SET status = 'APPROVED'`, and a new
    -- approval-shaped path has to make a deliberate statement about which it
    -- is rather than being discovered by a red test later.
    'admin_reinstate_account'
  ];
BEGIN
  -- (a) approve_provider is still fully guarded.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'approve_provider';

  IF v_src IS NULL THEN
    RETURN 'FAIL: approve_provider() does not exist';
  END IF;

  FOREACH v_clause IN ARRAY v_required_clauses LOOP
    IF position(v_clause IN v_src) = 0 THEN
      v_missing := v_missing || ' [' || v_clause || ']';
    END IF;
  END LOOP;

  -- The self-approval refusal is load-bearing: without it an admin can
  -- approve the account they are signed in to.
  IF position('cannot_approve_own_account' IN v_src) = 0 THEN
    v_missing := v_missing || ' [self-approval refusal]';
  END IF;

  -- The wallet and subscription rows are what make an approved provider
  -- usable; dropping them produces an account that is approved and cannot
  -- trade.
  IF position('insert into public.wallets' IN v_src) = 0 THEN
    v_missing := v_missing || ' [wallet creation]';
  END IF;

  IF position('insert into public.subscriptions' IN v_src) = 0 THEN
    v_missing := v_missing || ' [subscription creation]';
  END IF;

  IF v_missing <> '' THEN
    RETURN 'FAIL: approve_provider() is missing' || v_missing
           || '. A restatement dropped a condition; restore it from '
           || '20260927000026 before deploying.';
  END IF;

  -- Both functions must actually send the welcome.
  IF position('notify_user_once' IN v_src) = 0 THEN
    RETURN 'FAIL: approve_provider() no longer sends the welcome';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'approve_user';

  IF v_src IS NULL THEN
    RETURN 'FAIL: approve_user() does not exist';
  END IF;

  IF position('notify_user_once' IN v_src) = 0 THEN
    RETURN 'FAIL: approve_user() no longer sends the welcome';
  END IF;

  IF position('admin_can(''registrations'')' IN v_src) = 0
     OR position('p_admin_id is distinct from auth.uid()' IN v_src) = 0 THEN
    RETURN 'FAIL: approve_user() lost its authorization check';
  END IF;

  -- (b) No un-welcomed approval path. Enumerated rather than pattern-matched:
  --     this is the check that would have caught a third path.
  v_covered := 'approve_provider,approve_user';
  v_uncovered := '';

  FOR v_fn IN
    SELECT p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname <> 'assert_approval_welcome_covers_all_paths'
       AND lower(p.prosrc) ~ 'update\s+public\.provider_profiles\s+set\s+status\s*=\s*''approved'''
  LOOP
    IF v_fn = ANY(v_reinstatement_allowlist) THEN
      CONTINUE;
    END IF;

    IF position(',' || v_fn || ',' IN ',' || v_covered || ',') = 0
       AND v_fn NOT IN ('approve_provider', 'approve_user') THEN
      v_uncovered := v_uncovered || v_fn || ',';
    END IF;
  END LOOP;

  IF v_uncovered <> '' THEN
    RETURN 'FAIL: these functions set provider_profiles.status to APPROVED but '
           || 'send no welcome: ' || v_uncovered
           || '. Either they are a first approval and need a welcome, or they '
           || 'belong in the reinstatement allowlist with a stated reason.';
  END IF;

  RETURN 'ok: approve_provider keeps all 4 authorization clauses, the '
         || 'self-approval refusal, wallet and subscription creation; both '
         || 'approval functions send a keyed welcome; no other function sets '
         || 'provider_profiles.status to APPROVED without one (allowlisted '
         || 'reinstatement: ' || array_to_string(v_reinstatement_allowlist, ', ') || ')';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_approval_welcome_covers_all_paths() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_approval_welcome_covers_all_paths()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';