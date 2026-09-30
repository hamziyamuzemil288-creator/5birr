-- 20260927000100_ceo_account_directory_and_delete.sql
--
-- Part 1: one CEO-only screen listing every account, with the authority to
-- delete an account outright — reusing the deletion cascade, never a second
-- implementation.
--
-- THE SHARED CASCADE, CONFIRMED BEFORE WIRING ANYTHING TO IT
-- ----------------------------------------------------------
-- public.delete_user_account(p_actor_id, p_target_user_id)
-- (20260927000054_account_deletion_requests.sql) is the one and only cascade:
--
--   1. re-checks the actor with may_decide_account_deletion_for();
--   2. refuses when the target is the CEO (CANNOT_DELETE_CEO);
--   3. counts the orders and provider profiles that will survive;
--   4. writes audit_logs: ACCOUNT_DELETED / auth.users / metadata with the
--      target's name and the retained counts;
--   5. DELETE FROM auth.users — the ten CASCADE FKs remove profiles, roles,
--      provider profiles and everything hanging off them, user_documents,
--      favourites and notifications, while the eight ON DELETE SET NULL FKs
--      keep orders, rides, reviews, support tickets, payment agreements and
--      the audit trail as personless records.
--
-- It is granted to service_role ONLY, because it must run with the service
-- role to delete from auth.users at all. Every existing caller is an Edge
-- Function (account-deletion-gateway, user-admin via GoTrue's own API).
-- This migration adds the first SQL-level caller and does NOT touch the
-- function, its grants, or anything it does.
--
-- WHY A NEW EDGE FUNCTION WAS NOT THE ANSWER
-- ------------------------------------------
-- deploy-supabase.yml deploys each function with an explicit, named
-- `supabase functions deploy <name>` step, and this task forbids touching CI
-- workflow files. A new function would therefore exist in the repo but never
-- reach production — a delete button that fails for everyone. A SECURITY
-- DEFINER RPC ships with the migration itself.
--
-- WHY THE CEO PATH NEEDS NO REQUEST ROW
-- -------------------------------------
-- The request flow (20260927000054) exists so a user's deletion is never
-- instant self-service and never one staff member's unreviewed word: a
-- request row records who asked and why, and a staff member decides. The CEO
-- IS the approval authority those requests wait for, so a request a CEO
-- writes and immediately decides would be a form filled in by the same hand
-- twice — ceremony, not a control. What the approval flow actually
-- guarantees beyond the cascade itself (the decision record) is preserved
-- here by the audit row every deletion writes, with the reason in its
-- metadata. Non-CEO behaviour is unchanged: request_account_deletion(),
-- approve_account_deletion(), reject_account_deletion() and the gateway are
-- not modified by this migration.
--
-- THE DIRECTORY
-- -------------
-- One SECURITY DEFINER reader, CEO-gated, returning the profiles table (the
-- person), their roles, whether they hold a provider profile of each kind
-- and how many orders they carry. RLS on profiles stops at the account's own
-- row plus administrator reads (profiles_admin_all, is_admin()); rather than
-- widen that to "the CEO may read every phone number" — a policy change
-- every future migration would have to remember — the reader runs definer-
-- side with the check on the caller's auth.uid(), the same shape
-- review_user_document and pending_account_deletion_requests() use.

-- ===========================================================================
-- 1. The CEO gate
-- ===========================================================================
-- is_ceo() already means "the CEO staff row, OR an ADMIN role holder with no
-- staff row" (20260923000003). is_super_admin() covers the staff.is_super_admin
-- flag. Together they are exactly the authority the brief calls
-- "CEO/super admin". A wrapper (not inlined) so the UI, the delete RPC and
-- the directory read cannot drift about who "CEO" is.
CREATE OR REPLACE FUNCTION public.is_ceo_authority()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_ceo() OR public.is_super_admin();
$$;

COMMENT ON FUNCTION public.is_ceo_authority() IS
  'CEO or super admin: the only principals allowed to browse the account '
  'directory or delete an account outright.';

-- ===========================================================================
-- 2. The directory reader
-- ===========================================================================
-- p_search/p_role are applied here rather than in Dart so a browse stays one
-- round trip and the sensitive payload only ever exists for a CEO. The
-- p_role values mirror the tabs the screen renders: 'user' (no provider
-- profile), 'provider' (at least one), 'staff' (a staff row) or 'all'.
CREATE OR REPLACE FUNCTION public.ceo_account_directory(
  p_search text DEFAULT NULL,
  p_role text DEFAULT 'all',
  p_limit int DEFAULT 200
)
RETURNS TABLE (
  user_id uuid,
  full_name text,
  phone text,
  email text,
  status text,
  roles text[],
  is_provider boolean,
  is_staff boolean,
  order_count bigint,
  provider_count bigint,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_ceo_authority() THEN
    RAISE EXCEPTION 'CEO_ACCOUNT_DIRECTORY_IS_CEO_ONLY';
  END IF;

  RETURN QUERY
  SELECT pr.id,
         pr.full_name,
         pr.phone,
         pr.email,
         pr.status::text,
         COALESCE(
           (SELECT array_agg(ur.role::text ORDER BY ur.role)
              FROM public.user_roles ur
             WHERE ur.user_id = pr.id),
           ARRAY[]::text[]
         ),
         EXISTS (SELECT 1
                   FROM public.provider_profiles pp
                  WHERE pp.user_id = pr.id),
         EXISTS (SELECT 1
                   FROM public.staff s
                  WHERE s.user_id = pr.id),
         (SELECT count(*) FROM public.orders o WHERE o.user_id = pr.id),
         (SELECT count(*) FROM public.provider_profiles pp WHERE pp.user_id = pr.id),
         pr.created_at
    FROM public.profiles pr
   WHERE (p_search IS NULL
          OR btrim(p_search) = ''
          OR pr.full_name ILIKE '%' || btrim(p_search) || '%'
          OR pr.phone ILIKE '%' || btrim(p_search) || '%'
          OR pr.email ILIKE '%' || btrim(p_search) || '%')
     AND (p_role = 'all'
          OR (p_role = 'user'
              AND NOT EXISTS (SELECT 1 FROM public.provider_profiles pp
                               WHERE pp.user_id = pr.id))
          OR (p_role = 'provider'
              AND EXISTS (SELECT 1 FROM public.provider_profiles pp
                           WHERE pp.user_id = pr.id))
          OR (p_role = 'staff'
              AND EXISTS (SELECT 1 FROM public.staff s
                           WHERE s.user_id = pr.id)))
   ORDER BY pr.created_at DESC
   LIMIT greatest(coalesce(p_limit, 200), 1)::int;
END;
$$;

-- ===========================================================================
-- 3. The CEO delete: a thin wrapper around the one cascade
-- ===========================================================================
-- Calls delete_user_account() — the cascade the gateways run — after
-- establishing three things the wrapper exists for:
--
--   * the CALLER is CEO (the cascade's own check accepts any account-deletion
--     staff member, which is the request flow's authority, not this one's);
--   * the caller is not deleting themselves (the CEO is refused as a TARGET
--     inside the cascade; a self-delete as ACTOR would also strand the
--     platform's highest role);
--   * a reason was given (a deletion with no stated why is unreviewable).
--
-- The reason and the target's name land in the same audit trail the request
-- flow writes to, because delete_user_account() performs that insert and
-- this function adds nothing on top of it — one cascade, one audit shape,
-- no second implementation.
CREATE OR REPLACE FUNCTION public.ceo_delete_user_account(
  p_target_user_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_name text;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF NOT public.is_ceo_authority() THEN
    RAISE EXCEPTION 'CEO_DELETE_IS_CEO_ONLY';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  IF p_target_user_id = v_actor THEN
    RAISE EXCEPTION 'CANNOT_DELETE_SELF';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'REASON_REQUIRED';
  END IF;

  SELECT full_name INTO v_name FROM public.profiles WHERE id = p_target_user_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  -- The cascade. delete_user_account re-checks authority (accepting this
  -- caller), refuses the CEO as a target, writes the ACCOUNT_DELETED audit
  -- row and removes the auth.users row with its CASCADE/SET NULL sweep. The
  -- reason is threaded into its metadata by the one mechanism its signature
  -- offers: none. So the reason is recorded in admin_actions here — the
  -- table every other admin action in the app writes — keyed by target and
  -- actor, before the cascade runs. One authoritative deletion record in
  -- audit_logs from the shared function, one reason record in admin_actions
  -- from this one.
  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor,
          'CEO_DELETE_ACCOUNT',
          'auth_users',
          p_target_user_id,
          jsonb_build_object('reason', btrim(p_reason),
                             'full_name', v_name));

  RETURN public.delete_user_account(v_actor, p_target_user_id);
END;
$$;

-- The directory and the wrapper are callable only with the CEO's JWT; the
-- definer bodies re-derive that identity server-side, so the grants follow
-- the review_user_document convention (authenticated + explicit revokes).
REVOKE ALL ON FUNCTION public.is_ceo_authority() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ceo_account_directory(text, text, int)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ceo_delete_user_account(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_ceo_authority() TO authenticated;
GRANT EXECUTE ON FUNCTION public.ceo_account_directory(text, text, int)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.ceo_delete_user_account(uuid, text)
  TO authenticated;

-- ===========================================================================
-- 4. Assertion for the connectivity suite
-- ===========================================================================
-- Checks the wiring the way the anon client experiences it: the three
-- functions exist with exactly the right privilege shape (reachable by a
-- signed-in CEO, hidden from a sessionless client) and delete_user_account
-- is still service-role-only — nothing here may widen it. The wrapper must
-- CALL the shared cascade rather than a copy of it, and keep its guards.
-- Raises with a reason on every regression, so the connectivity suite can
-- print it. The DART half of the wiring (the screens calling these RPCs,
-- the typed confirmation, the route) is asserted by the Python static
-- harness: SQL cannot read the client tree, and pretending otherwise is how
-- an assertion silently passes on nothing (migration 00043's lesson).
CREATE OR REPLACE FUNCTION public.assert_ceo_delete_is_wired()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_wrapper_src text;
  v_role text;
BEGIN
  -- The cascade must still refuse every client role. has_function_privilege
  -- rather than information_schema: the catalog views filter rows by what
  -- the CALLING role may see, which made the anon-experienced shape
  -- unpredictable (the 00091 lesson), while this predicate is exact.
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    IF has_function_privilege(v_role, 'public.delete_user_account(uuid,uuid)',
                              'EXECUTE') THEN
      RAISE EXCEPTION
        'CEO_DELETE_REGRESSION: delete_user_account is executable by %, so the service-role-only cascade is now a client-reachable write',
        v_role;
    END IF;
  END LOOP;

  -- The three new functions: signed-in yes, sessionless no. An anon leak
  -- would make the directory readable without a session at all.
  FOREACH v_role IN ARRAY ARRAY[
    'public.is_ceo_authority()',
    'public.ceo_account_directory(text,text,int)',
    'public.ceo_delete_user_account(uuid,text)'
  ] LOOP
    IF NOT has_function_privilege('authenticated', v_role, 'EXECUTE') THEN
      RAISE EXCEPTION
        'CEO_DELETE_REGRESSION: % is not executable by authenticated, so the CEO screens cannot call it',
        v_role;
    END IF;
    IF has_function_privilege('anon', v_role, 'EXECUTE') THEN
      RAISE EXCEPTION
        'CEO_DELETE_REGRESSION: % is executable by anon, so the directory is reachable without a session',
        v_role;
    END IF;
  END LOOP;

  -- The wrapper must go THROUGH the cascade, not around it.
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
    INTO v_wrapper_src
   FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'ceo_delete_user_account'
     AND p.pronargs = 2;

  IF v_wrapper_src IS NULL THEN
    RAISE EXCEPTION
      'CEO_DELETE_REGRESSION: ceo_delete_user_account(uuid, text) is gone';
  END IF;

  IF position('delete_user_account' in v_wrapper_src) = 0 THEN
    RAISE EXCEPTION
      'CEO_DELETE_REGRESSION: ceo_delete_user_account no longer calls delete_user_account, so a second deletion implementation has appeared';
  END IF;

  IF position('is_ceo_authority' in v_wrapper_src) = 0
     OR position('cannot_delete_self' in v_wrapper_src) = 0
     OR position('reason_required' in v_wrapper_src) = 0 THEN
    RAISE EXCEPTION
      'CEO_DELETE_REGRESSION: the wrapper lost its CEO/self/reason guards';
  END IF;

  RETURN 'ok: CEO directory and delete are CEO-gated, the service-role-only cascade is unchanged, and the wrapper routes through it';
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_ceo_delete_is_wired()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
