-- 20260927000087 — a warm welcome on every path that approves an account
--
-- WHAT THIS CHANGES
-- -----------------
-- Both approval functions already sent a notification. Neither was a welcome,
-- and only one of them could be:
--
--   approve_user    "Account approved / Your account has been approved. You
--                   can now use the app."
--   approve_provider "Application approved / Your provider account is now
--                   active."
--
-- Both are factual and both fire, so the honest summary of the prior state is
-- "the event was covered, the tone was not". What is added here is the
-- personalized welcome the brief asks for, sent from the same place the status
-- is flipped.
--
-- EVERY APPROVAL PATH IS COVERED — AND THE LIST IS SHORTER THAN IT LOOKS
-- ----------------------------------------------------------------------
-- The brief warns that a user approval, a provider approval and a
-- "Become a Partner" upgrade might be three different functions. They are not:
--
--   * submit_partner_application() (migration 57) does NOT approve anything.
--     It INSERTs a provider_profiles row with status PENDING_APPROVAL and
--     writes the approval_requests row. An admin then approves it through the
--     ordinary provider path, so a partner upgrade is approved by
--     approve_provider() and inherits this welcome. There is no third
--     approval function to cover.
--
--   * charge_due_subscriptions() and the subscription-process Edge Function
--     also write provider_profiles.status = 'APPROVED', but only to RESTORE
--     an account that was suspended for an unpaid fee. That is a reinstatement,
--     not a first approval, and both already send their own "Account
--     reactivated" notice. A welcome here would be wrong: the account was
--     never new. Deliberately not touched.
--
-- So the two functions below are the complete set. assert_approval_welcome_
-- covers_all_paths() enforces that, so a future fourth path cannot be added
-- without this assertion noticing.
--
-- WHY THE WELCOME IS SENT ALONGSIDE THE EXISTING NOTICE, NOT INSTEAD OF IT
-- -----------------------------------------------------------------------
-- approve_provider's existing "Application approved" is a status transition
-- notice; the welcome is a different message about a different thing (you can
-- trade now). Reusing the key 'provider-approved:'||id means a retried admin
-- approval cannot produce a second welcome, and the existing unkeyed notice
-- keeps its current behaviour rather than being silently reshaped.
--
-- TONE
-- ----
-- Factual, short, no promotion. "ready to go" is the whole claim; there is no
-- mention of earnings, growth, or anything the account cannot do yet.
--
-- EVERY OTHER STATEMENT IS PRESERVED EXACTLY. approve_provider's four-part
-- staff-scope authorization and its self-approval refusal are reproduced byte
-- for byte from 20260927000026 — the body that fixed the widening regression
-- documented at the top of that file. This is the exact mistake the brief
-- warns about, so the guard is asserted rather than trusted.

-- ===========================================================================
-- 1. approve_provider
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.approve_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider public.provider_profiles;
  v_name text;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  IF p_admin_id = (SELECT user_id FROM public.provider_profiles WHERE id = p_provider_id) THEN
    RAISE EXCEPTION 'CANNOT_APPROVE_OWN_ACCOUNT';
  END IF;

  UPDATE public.provider_profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;

  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  -- Completion gate: the profile is what the login router checks.
  UPDATE public.profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = v_provider.user_id;

  -- Close the approval request so the admin list stops showing it.
  UPDATE public.approval_requests
    SET status = 'APPROVED'
    WHERE subject_type = 'PROVIDER'
      AND subject_id = p_provider_id
      AND status = 'PENDING_APPROVAL';

  -- Wallet (created on approval; idempotent)
  INSERT INTO public.wallets (provider_id, balance)
  VALUES (p_provider_id, 0)
  ON CONFLICT (provider_id) DO NOTHING;

  -- Initial subscription: ACTIVE from approval, first payment due in one
  -- month (deduct_subscription_fee() advances next_due_date from here).
  INSERT INTO public.subscriptions (provider_id, status, next_due_date)
  VALUES (p_provider_id, 'ACTIVE', now() + interval '1 month')
  ON CONFLICT (provider_id) DO NOTHING;

  INSERT INTO public.approval_history (subject_type, subject_id, action, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    v_provider.user_id,
    'APPROVAL',
    'Application approved',
    'Your provider account is now active.'
  );

  -- The welcome. business_name is the provider's own trading name, so this
  -- addresses them the way their customers will see them; full_name is the
  -- fallback when the profile was created without one. COALESCE rather than a
  -- NULL-guarded string, because '<name>' in a welcome is worse than no name.
  v_name := COALESCE(
    NULLIF(btrim(v_provider.business_name), ''),
    (SELECT NULLIF(btrim(full_name), '') FROM public.profiles WHERE id = v_provider.user_id)
  );

  PERFORM public.notify_user_once(
    'provider-approved:' || p_provider_id::text,
    v_provider.user_id,
    'APPROVAL',
    'Welcome to Aliob',
    CASE
      WHEN v_name IS NULL THEN
        'Your account is approved and ready to go.'
      ELSE
        'Welcome to Aliob, ' || v_name || '. Your account is approved and ready to go.'
    END,
    jsonb_build_object('provider_id', p_provider_id, 'event', 'provider_approved')
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('provider_user', v_provider.user_id));

  RETURN v_provider;
END;
$$;

-- ===========================================================================
-- 2. approve_user
--
-- Body from 20260922000010, unchanged except for the added welcome. Note this
-- function has no is_server_write() branch: it is called with the approving
-- admin's own JWT, so admin_can + identity is the whole check. That asymmetry
-- with approve_provider is pre-existing and is NOT changed here — adding a
-- server-write bypass would be an authorization change, which is outside this
-- task's scope.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.approve_user(
  p_user_id uuid,
  p_admin_id uuid
) RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  v_profile public.profiles;
  v_name text;
BEGIN
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE public.profiles
  SET    status = 'APPROVED', updated_at = now()
  WHERE  id = p_user_id
  RETURNING * INTO v_profile;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  UPDATE public.approval_requests
  SET    status = 'APPROVED'
  WHERE  subject_type = 'USER'
  AND    subject_id = p_user_id
  AND    status = 'PENDING_APPROVAL';

  INSERT INTO public.approval_history
    (subject_type, subject_id, action, performed_by)
  VALUES
    ('USER', p_user_id, 'APPROVE', p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_user_id,
    'APPROVAL',
    'Account approved',
    'Your account has been approved. You can now use the app.'
  );

  v_name := NULLIF(btrim(v_profile.full_name), '');

  PERFORM public.notify_user_once(
    'user-approved:' || p_user_id::text,
    p_user_id,
    'APPROVAL',
    'Welcome to Aliob',
    CASE
      WHEN v_name IS NULL THEN
        'Your account is approved and ready to go.'
      ELSE
        'Welcome to Aliob, ' || v_name || '. Your account is approved and ready to go.'
    END,
    jsonb_build_object('user_id', p_user_id, 'event', 'user_approved')
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_USER', 'profiles', p_user_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_USER', p_user_id,
    'registration', v_profile.city);

  RETURN v_profile;
END;
$$;

-- ===========================================================================
-- 3. The assertion
--
-- Two things are checked, and the first is the one that has bitten this repo
-- twice.
--
-- (a) COMPLETENESS. The four authorization/refusal clauses of approve_provider
--     are still present. assert_meaningful_events_are_notified() in migration
--     58 checks that these functions notify, and it PASSED on the body that
--     had lost two of four conditions — it was written to catch the bug the
--     author expected and was blind to the one they caused. So this assertion
--     names each clause individually. A restatement that drops
--     staff_scope_allows_category turns this red.
--
-- (b) COVERAGE. No other function sets an account to APPROVED for a first
--     time. It lists every function whose body writes status = 'APPROVED' and
--     requires that each one either is one of the two above or is on the
--     reinstatement allowlist — so a new approval path added later is caught
--     rather than silently going un-welcomed.
-- ===========================================================================
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
    'charge_due_subscriptions'  -- restores a fee-suspended account
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

REVOKE ALL ON FUNCTION public.assert_approval_welcome_covers_all_paths()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_approval_welcome_covers_all_paths()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.assert_approval_welcome_covers_all_paths() IS
  'Checks that both approval functions still carry their full authorization '
  'guards and wallet/subscription side effects after being restated, and that '
  'no other function sets an account to APPROVED for the first time without '
  'sending the welcome.';

notify pgrst, 'reload schema';
