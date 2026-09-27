-- Account deletion as a REQUEST, decided by staff — never instant self-service.
--
-- WHAT EXISTED
-- ------------
-- Nothing. delete-account.md tells users to email an address and wait seven
-- business days. There is no record of who asked, why, who decided, or what
-- was said — and the founder's own audit asked for deletion to become a
-- self-service flow that still requires approval.
--
-- The shape deliberately copies wallet_recharge_requests rather than
-- inventing one: a request row, a PENDING -> APPROVED/REJECTED status, the
-- decider and the timestamp, an optional note back, and the same
-- notifications + audit_logs + admin_actions trail that reject_wallet_recharge
-- already writes. A deletion request is a payment-shaped decision (one person
-- asks, another authorises, both sides need a record) and reusing the proven
-- shape means the staff screens that already read "requests with a reason and
-- a decision" can read this one too.
--
-- WHY THE ACTUAL DELETE IS AN EDGE FUNCTION
-- -----------------------------------------
-- Deleting the auth.users row needs the service role, which must never reach a
-- client. That is the same reason staff-delete-gateway exists, and the same
-- cascade: RPC marks APPROVED and records the decision, then the gateway
-- removes the auth row. The RPC on its own is the whole flow EXCEPT the last
-- step, so an approved request whose gateway call failed is visible and
-- retryable rather than silently lost.
--
-- WHY THE FOREIGN KEYS HAVE TO CHANGE
-- -----------------------------------
-- Deleting auth.users today fails for almost any real account. Of the columns
-- that reference it, ten CASCADE (profiles, user_roles, provider_profiles,
-- user_documents, favorites, notifications, ...) and those go cleanly. The
-- other nine are NOT NULL with no action:
--
--   orders.user_id            reviews.user_id          ride_requests.user_id
--   support_tickets.user_id   payment_agreements.user_id
--   ride_ratings.rater_id     appeals.user_id
--   admin_actions.admin_id    admin_wallet_actions.admin_id
--
-- Every one of those is a RECORD, not personal data: an order is money that
-- has already moved, a rating is a statement about a transaction, an admin
-- action is the audit trail. Deleting them to delete a login would destroy
-- financial and audit history, which is the opposite of what a data-deletion
-- request is for.
--
-- So they are made ON DELETE SET NULL instead. The row survives, the link to
-- the person does not, and the profile row that gave the row its display name
-- is deleted by the existing CASCADE — so an orphaned order renders with no
-- name rather than with a name the person asked to be forgotten. NOT NULL is
-- dropped on exactly those nine columns and nowhere else. Nothing that reads
-- them is a client: the app resolves names through profiles, and every RLS
-- predicate of the form `user_id = auth.uid()` simply stops matching a NULL,
-- which is the correct outcome for an account that no longer exists.

-- ===========================================================================
-- 1. The request table
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.account_deletion_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- The reason is the whole point of the queue: a decider who cannot see why
  -- is being asked to delete a stranger's account.
  reason text NOT NULL CHECK (length(btrim(reason)) >= 10),
  supporting_info text,
  status text NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  reviewed_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  decision_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.account_deletion_requests IS
  'Self-service account deletion requests. A user asks and a staff member '
  'decides; nothing is deleted on submit. Mirrors wallet_recharge_requests: '
  'status, decider, timestamp and an optional note back.';

CREATE INDEX IF NOT EXISTS idx_account_deletion_requests_user
  ON public.account_deletion_requests(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_account_deletion_requests_pending
  ON public.account_deletion_requests(created_at ASC) WHERE status = 'PENDING';

-- One open request per person. A rejected account that wants to try again can,
-- because the partial predicate only holds while a request is PENDING.
CREATE UNIQUE INDEX IF NOT EXISTS uq_account_deletion_requests_one_pending
  ON public.account_deletion_requests(user_id) WHERE status = 'PENDING';

CREATE TRIGGER trg_account_deletion_requests_updated_at
  BEFORE UPDATE ON public.account_deletion_requests
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- RLS with a self-only read. The reason a person gave for leaving is their own
-- business, and a staff member reading the queue does it through
-- pending_account_deletion_requests(), which is permission-gated -- so the
-- table policy deliberately does NOT grant staff a blanket read.
ALTER TABLE public.account_deletion_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY account_deletion_requests_read_own
  ON public.account_deletion_requests FOR SELECT
  USING (user_id = auth.uid());

-- The client never writes this table. Both directions go through the
-- SECURITY DEFINER functions below so that "one pending request" and the
-- reason-length rule are enforced on the only paths that exist.
REVOKE ALL ON public.account_deletion_requests FROM anon, authenticated;
GRANT SELECT ON public.account_deletion_requests TO authenticated;

-- ===========================================================================
-- 2. The staff job
-- ===========================================================================
-- Same catalogue the other nine jobs live in, so the CEO assigns it from the
-- existing list and staff_activity_log records the grant like any other.
INSERT INTO public.staff_jobs (key, label, description, group_name, sort_order)
VALUES
  ('account_deletion', 'Account deletions',
   'Approve or reject a user''s request to delete their account.',
   'Support', 35)
ON CONFLICT (key) DO NOTHING;

-- ===========================================================================
-- 3. Who may decide
-- ===========================================================================
-- Mirrors the payment_verification gate: the permission, or an administrator
-- (which includes the CEO). Written once here and called by both decision
-- functions so the two cannot drift.
CREATE OR REPLACE FUNCTION public.may_decide_account_deletion()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_admin()
      OR public.staff_has_permission(auth.uid(), 'account_deletion');
$$;

-- The actor-parameter twin of the above: same rule, but resolved from an
-- explicit id for the service-role gateway path, where auth.uid() is NULL.
--
-- The last clause is not redundant with is_ceo(). is_ceo() means "CEO staff
-- row, OR an ADMIN role holder with NO staff row" -- an administrator who is
-- also a staff member is deliberately not the CEO. is_admin() (which takes no
-- argument and reads auth.uid()) therefore has no explicit-id twin in the
-- schema, so the ADMIN-role check is written out to keep this function's reach
-- identical to the auth.uid() version above.
CREATE OR REPLACE FUNCTION public.may_decide_account_deletion_for(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_ceo(p_user_id)
      OR public.is_super_admin(p_user_id)
      OR public.staff_has_permission(p_user_id, 'account_deletion')
      OR EXISTS (
           SELECT 1 FROM public.user_roles ur
            WHERE ur.user_id = p_user_id AND ur.role = 'ADMIN'
         );
$$;

-- ===========================================================================
-- 4. Submit
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.request_account_deletion(
  p_reason text,
  p_supporting_info text DEFAULT NULL
)
RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request public.account_deletion_requests;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'REASON_TOO_SHORT';
  END IF;

  -- The partial unique index would reject the second request anyway; raising
  -- the real reason beats surfacing a constraint name to the user.
  IF EXISTS (
    SELECT 1 FROM public.account_deletion_requests r
     WHERE r.user_id = auth.uid() AND r.status = 'PENDING'
  ) THEN
    RAISE EXCEPTION 'ALREADY_HAS_PENDING_REQUEST';
  END IF;

  INSERT INTO public.account_deletion_requests (user_id, reason, supporting_info)
  VALUES (auth.uid(), btrim(p_reason), NULLIF(btrim(coalesce(p_supporting_info, '')), ''))
  RETURNING * INTO v_request;

  RETURN v_request;
END;
$$;

COMMENT ON FUNCTION public.request_account_deletion(text, text) IS
  'Self-service submission. Creates a PENDING request and nothing else: no '
  'row is deleted here, and the account keeps working until staff approve.';

-- ===========================================================================
-- 5. The requester's own view
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.my_account_deletion_requests()
RETURNS SETOF public.account_deletion_requests
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT r.*
    FROM public.account_deletion_requests r
   WHERE r.user_id = auth.uid()
   ORDER BY r.created_at DESC;
$$;

-- ===========================================================================
-- 6. The staff queue
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.pending_account_deletion_requests()
RETURNS TABLE (
  id uuid,
  user_id uuid,
  full_name text,
  phone text,
  email text,
  provider_count bigint,
  order_count bigint,
  reason text,
  supporting_info text,
  status text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.may_decide_account_deletion() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_DELETION_REQUESTS';
  END IF;

  RETURN QUERY
  SELECT r.id,
         r.user_id,
         p.full_name,
         p.phone,
         p.email,
         (SELECT count(*) FROM public.provider_profiles pp WHERE pp.user_id = r.user_id),
         (SELECT count(*) FROM public.orders o WHERE o.user_id = r.user_id),
         r.reason,
         r.supporting_info,
         r.status,
         r.created_at
    FROM public.account_deletion_requests r
    LEFT JOIN public.profiles p ON p.id = r.user_id
   WHERE r.status = 'PENDING'
   ORDER BY r.created_at ASC;
END;
$$;

-- ===========================================================================
-- 7. Decide
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.approve_account_deletion(
  p_request_id uuid,
  p_actor_id uuid,
  p_note text DEFAULT NULL
)
RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request public.account_deletion_requests;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
BEGIN
  -- The actor is auth.uid() whenever there IS a caller, and the explicit
  -- parameter only when there is not (the service-role gateway). Resolving it
  -- this way means a client can never write somebody else's id into the audit
  -- trail by passing a forged p_actor_id, while the gateway -- which carries no
  -- end-user JWT and would otherwise have a NULL here -- still works.
  IF v_actor IS NULL OR NOT public.may_decide_account_deletion_for(v_actor) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE_DELETION';
  END IF;

  SELECT * INTO v_request
    FROM public.account_deletion_requests r
   WHERE r.id = p_request_id
   FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;
  IF v_request.status <> 'PENDING' THEN
    RAISE EXCEPTION 'ALREADY_DECIDED';
  END IF;

  UPDATE public.account_deletion_requests
     SET status = 'APPROVED',
         reviewed_by = v_actor,
         reviewed_at = now(),
         decision_note = NULLIF(btrim(coalesce(p_note, '')), ''),
         updated_at = now()
   WHERE id = p_request_id
   RETURNING * INTO v_request;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'ACCOUNT_DELETION_APPROVED', 'account_deletion_requests', p_request_id,
          jsonb_build_object('user_id', v_request.user_id));

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor, 'APPROVE_ACCOUNT_DELETION', 'account_deletion_requests', p_request_id,
          jsonb_build_object('user_id', v_request.user_id));

  -- Told the person their request was accepted. The deletion itself is
  -- performed by account-deletion-gateway immediately after this returns.
  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (v_request.user_id, 'ACCOUNT_DELETION', 'Account deletion approved',
          coalesce(p_note, 'Your account deletion request was approved.'));

  RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION public.reject_account_deletion(
  p_request_id uuid,
  p_actor_id uuid,
  p_note text
)
RETURNS public.account_deletion_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_request public.account_deletion_requests;
  -- Same actor resolution as approve: the caller wins, so the recorded decider
  -- is the person who actually signed in. Reject is client-only, so this is
  -- always auth.uid() in practice.
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
BEGIN
  IF v_actor IS NULL OR NOT public.may_decide_account_deletion_for(v_actor) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT_DELETION';
  END IF;

  SELECT * INTO v_request
    FROM public.account_deletion_requests r
   WHERE r.id = p_request_id
   FOR UPDATE;

  IF v_request.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;
  IF v_request.status <> 'PENDING' THEN
    RAISE EXCEPTION 'ALREADY_DECIDED';
  END IF;

  UPDATE public.account_deletion_requests
     SET status = 'REJECTED',
         reviewed_by = v_actor,
         reviewed_at = now(),
         decision_note = NULLIF(btrim(coalesce(p_note, '')), ''),
         updated_at = now()
   WHERE id = p_request_id
   RETURNING * INTO v_request;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'ACCOUNT_DELETION_REJECTED', 'account_deletion_requests', p_request_id,
          jsonb_build_object('user_id', v_request.user_id, 'note', coalesce(p_note, '')));

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor, 'REJECT_ACCOUNT_DELETION', 'account_deletion_requests', p_request_id,
          jsonb_build_object('user_id', v_request.user_id, 'note', coalesce(p_note, '')));

  -- A rejection with no explanation is not a decision the person can act on,
  -- so the note is the payload rather than a courtesy.
  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (v_request.user_id, 'ACCOUNT_DELETION', 'Account deletion declined',
          coalesce(p_note, 'Your account deletion request was declined.'));

  RETURN v_request;
END;
$$;

-- ===========================================================================
-- 8. The cascade itself (service role only)
-- ===========================================================================
-- Called by account-deletion-gateway, never by a client. p_actor_id is passed
-- explicitly for the same reason delete_staff takes it: a service-role
-- PostgREST call carries no end-user JWT, so auth.uid() is NULL inside the
-- function and an auth.uid()-based check would reject the real staff member.
CREATE OR REPLACE FUNCTION public.delete_user_account(
  p_actor_id uuid,
  p_target_user_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_full_name text;
  v_orders bigint;
  v_providers bigint;
BEGIN
  IF NOT public.may_decide_account_deletion_for(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_DELETE_ACCOUNTS';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  SELECT full_name INTO v_full_name FROM public.profiles WHERE id = p_target_user_id;
  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  -- The CEO is an account too. Deleting it would remove the only role that
  -- can approve the next request, so it is refused here as well as in the UI.
  IF public.is_ceo(p_target_user_id) THEN
    RAISE EXCEPTION 'CANNOT_DELETE_CEO';
  END IF;

  SELECT count(*) INTO v_orders FROM public.orders WHERE user_id = p_target_user_id;
  SELECT count(*) INTO v_providers FROM public.provider_profiles WHERE user_id = p_target_user_id;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (p_actor_id, 'ACCOUNT_DELETED', 'auth.users', p_target_user_id,
          jsonb_build_object('full_name', v_full_name,
                             'orders_retained', v_orders,
                             'provider_profiles_retained', v_providers));

  -- The CASCADE FKs take profiles, user_roles, provider_profiles (and
  -- everything hanging off it), user_documents, favorites, notifications,
  -- fcm_tokens and notification_preferences. The SET NULL FKs added above keep
  -- orders, rides, reviews and the audit trail, detached from the person.
  DELETE FROM auth.users WHERE id = p_target_user_id;

  RETURN jsonb_build_object('deleted_user_id', p_target_user_id,
                            'full_name', v_full_name,
                            'orders_retained', v_orders,
                            'provider_profiles_retained', v_providers);
END;
$$;

-- ===========================================================================
-- 9. Grants
-- ===========================================================================
-- The write functions are the only client-reachable writes, and each one
-- re-checks identity server-side.
REVOKE ALL ON FUNCTION public.request_account_deletion(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.my_account_deletion_requests() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.pending_account_deletion_requests() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_account_deletion(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_account_deletion(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.may_decide_account_deletion() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.may_decide_account_deletion_for(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.request_account_deletion(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.my_account_deletion_requests() TO authenticated;
GRANT EXECUTE ON FUNCTION public.pending_account_deletion_requests() TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_account_deletion(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_account_deletion(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.may_decide_account_deletion() TO authenticated;

-- delete_user_account stays service_role-only, exactly like delete_staff.
REVOKE ALL ON FUNCTION public.delete_user_account(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_user_account(uuid, uuid) TO service_role;

-- ===========================================================================
-- 10. Make the account deletable
-- ===========================================================================
-- Ten CASCADE FKs already clean up the personal tables. These nine are records
-- and are detached rather than destroyed — see the header. Dropping NOT NULL
-- is confined to these nine columns and to nothing else.
DO $$
DECLARE
  t text;
  c text;
  fk text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'orders', 'reviews', 'ride_requests', 'support_tickets',
    'payment_agreements', 'ride_ratings', 'appeals',
    'admin_actions', 'admin_wallet_actions'
  ] LOOP
    c := CASE t
           WHEN 'ride_ratings' THEN 'rater_id'
           WHEN 'admin_actions' THEN 'admin_id'
           WHEN 'admin_wallet_actions' THEN 'admin_id'
           ELSE 'user_id'
         END;

    SELECT conname INTO fk
      FROM pg_constraint
     WHERE conrelid = format('public.%I', t)::regclass
       AND contype = 'f'
       AND conkey = ARRAY[
             (SELECT attnum FROM pg_attribute
               WHERE attrelid = format('public.%I', t)::regclass
                 AND attname = c)];

    IF fk IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', t, fk);
      EXECUTE format(
        'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) '
        'REFERENCES auth.users(id) ON DELETE SET NULL', t, fk, c);
      EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I DROP NOT NULL', t, c);
    END IF;
  END LOOP;
END;
$$;

-- PostgREST caches the relation metadata, and these functions are new.
NOTIFY pgrst, 'reload schema';
