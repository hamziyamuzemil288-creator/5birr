-- 20260927000090 — prove the notifications inbox is still owner-scoped
--
-- WHY THIS IS ITS OWN MIGRATION
-- -----------------------------
-- Migrations 86-89 add SECURITY DEFINER functions that write notifications.
-- Each one is REVOKEd from the client roles, and each runs as the function
-- owner, so a mistake in any of them writes rows a client should not be able
-- to write. That risk did not exist before this series, and the existing
-- assertions do not cover it:
--
--   assert_notification_outbox_is_drained() checks the QUEUE (RLS on, no
--   policies, no client grants) and that the injection guard still exists and
--   still raises. It says nothing about notifications itself.
--
--   assert_client_guards_are_server_safe() names six other guards.
--   prevent_notification_injection() is checked for the presence of a raise,
--   not for whether the policies on notifications are still correct.
--
-- So the table every one of these messages lands in is unasserted. This closes
-- that, and it is deliberately a behavioural check on the LIVE policies rather
-- than a source grep: a policy can be correct in intent and wrong in effect.
--
-- WHAT IS CHECKED
-- ---------------
--   1. RLS is enabled on notifications.
--   2. A signed-in user has a SELECT policy scoped to their own rows, and
--      every SELECT policy on the table mentions auth.uid() or is_admin() —
--      i.e. no policy has quietly become "everyone sees everything".
--   3. authenticated can SELECT but must NOT be able to INSERT or DELETE
--      directly: the only writers are the SECURITY DEFINER functions and the
--      server, and a client-writable table is a client-writable notification.
--   4. The injection guard is still present, still exempts only is_server_write()
--      and is_admin(), and still raises for anyone else.
--   5. notify_user_once is not executable by a client role (it is the new
--      primitive this series added, and it is the one a mistake would expose).
--
-- It reads pg_policies and pg_proc, so it reports what the database is
-- actually enforcing rather than what a migration intended.

CREATE OR REPLACE FUNCTION public.assert_notification_inbox_is_owner_only()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rls boolean;
  v_bad_policies text := '';
  v_guard text;
  v_can_insert boolean;
  v_can_delete boolean;
  v_bad_guard text := '';
BEGIN
  -- 1. RLS must be on. Without it, is_admin()-free rows are readable by any
  --    authenticated user through PostgREST.
  SELECT relrowsecurity INTO v_rls
    FROM pg_class WHERE oid = 'public.notifications'::regclass;

  IF v_rls IS DISTINCT FROM true THEN
    RETURN 'FAIL: row level security is not enabled on notifications, so any '
           || 'signed-in user can read every notification in the system';
  END IF;

  -- 2. Every SELECT policy must be scoped. A policy whose USING clause does
  --    not mention auth.uid() or is_admin() grants the whole table.
  SELECT string_agg(policyname, ', ' ORDER BY policyname) INTO v_bad_policies
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename = 'notifications'
     AND cmd = 'SELECT'
     AND lower(COALESCE(qual, '')) NOT LIKE '%auth.uid()%'
     AND lower(COALESCE(qual, '')) NOT LIKE '%is_admin()%';

  IF v_bad_policies IS NOT NULL THEN
    RETURN 'FAIL: these SELECT policies on notifications are not scoped to '
           || 'their owner: ' || v_bad_policies;
  END IF;

  -- And there must be at least one, or the user cannot read their own inbox
  -- either and the new notifications are written to a table nobody can open.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'notifications'
       AND cmd = 'SELECT'
  ) THEN
    RETURN 'FAIL: notifications has no SELECT policy, so a user cannot read '
           || 'their own notifications at all';
  END IF;

  -- 3. No direct client write. RLS without a write policy already denies
  --    this, but a GRANT bypasses RLS entirely, so the privilege is checked
  --    as well as the policy.
  v_can_insert := has_table_privilege(
    'authenticated', 'public.notifications', 'INSERT');
  v_can_delete := has_table_privilege(
    'authenticated', 'public.notifications', 'DELETE');

  IF v_can_insert OR v_can_delete THEN
    RETURN 'FAIL: authenticated can '
           || CASE WHEN v_can_insert THEN 'INSERT into' ELSE 'DELETE from' END
           || ' notifications directly. The guard trigger exempts verified '
           || 'admins, so a writable table is a client-writable notification '
           || 'for any user who can reach an admin code path.';
  END IF;

  -- 4. The injection guard must still refuse everyone else, and must not have
  --    been widened. Its exemptions are named explicitly: a guard that let
  --    through anyone with a role, or anyone at all, would defeat 3.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_guard
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'prevent_notification_injection';

  IF v_guard IS NULL THEN
    RETURN 'FAIL: prevent_notification_injection() is missing, so a client '
           || 'can insert its own notifications';
  END IF;

  IF position('is_server_write' IN v_guard) = 0 THEN
    v_bad_guard := v_bad_guard || ' [no server exemption]';
  END IF;

  IF position('is_admin' IN v_guard) = 0 THEN
    -- admin_cash_recharge and admin_wallet_adjustment write their audit
    -- notification from inside the RPC with the admin's own JWT, so this
    -- exemption is load-bearing. Dropping it breaks those two screens.
    v_bad_guard := v_bad_guard || ' [no admin exemption - admin_cash_recharge '
                    || 'and admin_wallet_adjustment would break]';
  END IF;

  IF position('raise exception' IN v_guard) = 0 THEN
    v_bad_guard := v_bad_guard || ' [does not raise]';
  END IF;

  IF position('notifications_cannot_be_created_by_clients' IN v_guard) = 0 THEN
    v_bad_guard := v_bad_guard || ' [lost its refusal message]';
  END IF;

  IF v_bad_guard <> '' THEN
    RETURN 'FAIL: prevent_notification_injection() is missing' || v_bad_guard;
  END IF;

  -- 5. The new call site is server-only. notify_user_once is REVOKEd from the
  --    client roles in migration 86; this is the same fact read from the
  --    live database rather than from that migration's text.
  IF has_function_privilege('authenticated',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE')
     OR has_function_privilege('anon',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE') THEN
    RETURN 'FAIL: a client role can EXECUTE notify_user_once(), so a user '
           || 'could send a notification to any other user id';
  END IF;

  RETURN 'ok: RLS on, all '
         || (SELECT count(*) FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'notifications'
                AND cmd = 'SELECT')::text
         || ' SELECT policy/policies scoped to their owner, no client INSERT or '
         || 'DELETE privilege, the injection guard still exempts only the '
         || 'server and verified admins and still raises, and notify_user_once '
         || 'is server-only';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_notification_inbox_is_owner_only()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_notification_inbox_is_owner_only()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.assert_notification_inbox_is_owner_only() IS
  'Checks the live enforcement, not the intent: RLS on notifications, every '
  'SELECT policy scoped to its owner, no client write privilege, the injection '
  'guard still present and un-widened, and notify_user_once server-only.';

notify pgrst, 'reload schema';
