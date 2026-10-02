-- 20260927000135 — unsuspend is a reinstatement, not an approval
--
-- WHAT THE LIVE DATABASE SAID
-- ----------------------------
-- The first Connectivity CI run after 0130 deployed reported:
--
--   FAIL: these functions set provider_profiles.status to APPROVED but send
--   no welcome: unsuspend_provider.
--
-- and the check was right. `unsuspend_provider` IS an approval path as far as
-- the database is concerned: it writes `provider_profiles.status =
-- 'APPROVED'`. It was invisible to `assert_approval_welcome_covers_all_paths`
-- only by accident of formatting, and this migration is about the accident.
--
-- WHY IT WAS INVISIBLE, AND WHY THAT WAS A LATENT BUG
-- -------------------------------------------------
-- The check finds approval paths with:
--
--     lower(p.prosrc) ~ 'update\s+public\.provider_profiles\s+set\s+status\s*=\s*''approved'''
--
-- `public\.` is REQUIRED by that pattern. Migration 0111 wrote the statement
-- unqualified:
--
--     UPDATE provider_profiles SET status = 'APPROVED', updated_at = now()
--
-- so the regex did not match, and a function that genuinely approves
-- accounts had been sitting outside the check the whole time. 0130 restated
-- `unsuspend_provider` and wrote the schema-qualified form:
--
--     UPDATE public.provider_profiles
--     SET status = 'APPROVED', updated_at = now()
--
-- `\s+` matches the newline, the pattern matches, and a path the check was
-- built to catch became visible for the first time.
--
-- So this is not 0130 breaking something. This is 0130 making a pre-existing
-- hole visible. Qualifying the table is the correct thing to write -- a
-- function running under a SECURITY DEFINER `search_path` should never
-- resolve `provider_profiles` by luck -- and the fix belongs in the allowlist,
-- not in a regression back to the unqualified form.
--
-- WHY UNSUSPEND IS NOT A FIRST APPROVAL
-- -------------------------------------
-- Because the account was already approved. `unsuspend_provider` lifts a
-- suspension from an account that had passed review before: it reinstates
-- someone the platform has already welcomed, verified and equipped with a
-- wallet. Sending the welcome again would tell a driver who was suspended for
-- a day that "your account is approved, welcome to Aliob" -- which is both
-- false (they were never un-approved) and the kind of message that trains
-- people to ignore notifications.
--
-- This is exactly what the allowlist is for. 0087 says it plainly: "Functions
-- that write APPROVED but are NOT a first approval. Each is excluded for a
-- stated reason; a new name may not be added here without one." This is that
-- stated reason.
--
-- The provider is still TOLD, which is the part that matters and the part
-- that used to be missing entirely. 0130 gave `unsuspend_provider` a keyed
-- reactivation notice through `notify_user_safe`, so the reinstatement is
-- announced with its own message instead of borrowing the welcome's. The
-- allowlist entry therefore means "not a welcome", not "not told".
--
-- ONLY THE ALLOWLIST CHANGES
-- --------------------------
-- Every guard, every required clause, the self-approval refusal, the wallet
-- and subscription checks and the final wording are byte-identical to
-- 20260927000123, which is the predecessor on the live database -- NOT to
-- 0087, which 0123 superseded. Restating the function is unavoidable: the
-- allowlist is a local variable, so changing one entry means redefining the
-- body. Which makes it a restatement a reviewer has to check line by line,
-- and the reason the rest is identical is the entire point of writing it
-- this way.

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
    'admin_reinstate_account',
    -- 20260927000135. Lifts a suspension from an account that was already
    -- approved, so there is nothing to welcome them to. 0130 gave it a keyed
    -- reactivation notice of its own; this entry means "not a welcome", not
    -- "not told". Visible to this check only since 0130 wrote the statement
    -- schema-qualified -- see this file's header.
    'unsuspend_provider'
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

-- 0123's grant block, NOT 0087's. This function's predecessor on the live
-- database is 20260927000123, which restated both the body and the grants.
-- 0087's block reads
--
--     REVOKE ALL ... FROM public, anon;
--     GRANT EXECUTE ... TO authenticated, service_role;
--
-- which is the version from BEFORE 0091 granted anon EXECUTE so the
-- connectivity suite could call this report. Copying 0087's block here
-- silently removed that grant, and the harness caught it before it shipped:
--
--     assert_approval_welcome_covers_all_paths() is called by the connectivity
--     suite, which runs as the anon role, but its final privilege state leaves
--     anon with no path
--
-- Taking the restatement from the wrong migration is the whole hazard. The
-- two 0087/0123 bodies are identical apart from the allowlist, so a diff
-- against 0087 shows nothing wrong and a deploy would have taken the grant
-- with it.
REVOKE ALL ON FUNCTION public.assert_approval_welcome_covers_all_paths() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_approval_welcome_covers_all_paths()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_approval_welcome_covers_all_paths() IS
  'Checks that both approval functions still carry their full authorization '
  'guards and wallet/subscription side effects after being restated, and that '
  'no other function sets an account to APPROVED for the first time without '
  'sending the welcome.';

notify pgrst, 'reload schema';