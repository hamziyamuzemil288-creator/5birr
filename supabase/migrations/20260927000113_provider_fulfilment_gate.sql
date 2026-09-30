-- 0113: the fulfilment gate — documents verified, fee paid, wallet funded.
--
-- WHAT THIS FIXES
--
-- The product rule is: a provider posts a product or claims an order only
-- once their documents are VERIFIED and their wallet has been charged. Before
-- this migration, three of the four surfaces did not enforce it:
--
--   surface                          status  reg_fee  documents
--   -------------------------------  ------  -------  ----------
--   create_provider_product          yes     yes      "satisfied"
--   create_provider_vehicle          yes     yes      "satisfied"
--   claim_ride                       yes     NO       NO
--   transition_order_status ACCEPT   NO      NO       NO
--
-- Two separate defects sit behind that table.
--
-- 1. "satisfied" did not mean verified. provider_docs_satisfied() accepts
--    MANUAL_REVIEW, and user_documents.verification_status DEFAULTS to
--    MANUAL_REVIEW and is forced to it by a BEFORE INSERT trigger
--    (20260924000004). So the document half of the gate was satisfied by the
--    act of UPLOADING a document, before any human had looked at it. The
--    function is left exactly as it is — two assertions depend on it — and
--    the stricter rule lives beside it as provider_documents_verified().
--
--    20260927000030's header says provider_docs_satisfied() "is the
--    server-side re-check on protected writes (listing upload, claim_ride)".
--    claim_ride never called it. That comment is the second time in this
--    codebase a comment has asserted a protection that was not there.
--
-- 2. claim_ride and transition_order_status never consulted the gate at all.
--    A vehicle provider whose registration fee was unpaid, or whose ID was
--    still sitting unreviewed, could take a rider's trip. The buyer-side
--    checkout DID block an unfunded provider — so the rule existed, was
--    enforced in one place, and was simply absent from the other three.
--
-- THE SUBSCRIPTION, WHICH IS ALREADY WIRED
--
-- No subscription check is added here, because there does not need to be one.
-- charge_due_subscriptions() sets provider_profiles.status = 'SUSPENDED' when
-- the wallet cannot cover the fee, and trg_sync_profile_status carries that to
-- profiles.status, which the router gates on. Every surface below already
-- requires status = 'APPROVED', so an unpaid subscription already stops all
-- four. Adding a second subscription predicate here would be a third place
-- for the rule to live and a third place for it to disagree.
--
-- BLAST RADIUS — READ provider_fulfilment_gate_report() AFTER deploying
--
-- Turning "uploaded" into "verified" is a real change: every provider whose
-- document is still MANUAL_REVIEW stops being able to work until the team
-- reviews it. That is the rule that was asked for, and the report is the
-- honest way to see its size. If it turns out to be too large to absorb at
-- once, the CEO can turn it off from Settings without a deploy:
--
--   UPDATE system_settings SET value = 'false'::jsonb
--    WHERE key = 'enforce_verified_documents';
--
-- It seeds TRUE, so the requested behaviour is the default rather than
-- something that has to be switched on later. The other three blockers
-- (approval, activation fee, empty wallet) are not behind that switch: they
-- were the intended rule all along.

SET search_path = public, pg_temp;

-- -----------------------------------------------------------------------------
-- 1. Documents VERIFIED, as distinct from documents uploaded
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.provider_documents_verified(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT p_user_id IS NOT NULL AND EXISTS (
    SELECT 1
      FROM public.user_documents d
     WHERE d.user_id = p_user_id
       AND d.document_type IN (
             'NATIONAL_ID', 'DRIVING_LICENSE', 'DRIVING_LICENSE_ID', 'PASSPORT'
           )
       -- MANUAL_REVIEW is deliberately NOT here. It is the default a row is
       -- born with, so including it is what made "verified" mean "uploaded".
       AND COALESCE(d.verification_status, 'MANUAL_REVIEW')
             IN ('AUTO_APPROVED', 'VERIFIED')
  );
$$;

REVOKE ALL ON FUNCTION public.provider_documents_verified(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_documents_verified(uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. Every reason a provider cannot work, as data
-- -----------------------------------------------------------------------------
--
-- A boolean cannot explain itself, and "you cannot do that" is the single
-- least helpful sentence this product could show a provider who has done
-- everything right. One function returns the reasons; the boolean below is
-- just a question about its length, and every caller that needs a sentence
-- uses the array.

CREATE OR REPLACE FUNCTION public.provider_fulfilment_blockers(p_provider_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id    uuid;
  v_status     text;
  v_fee_paid   boolean;
  v_balance    numeric;
  v_allow_neg  boolean := public.get_setting_bool('allow_negative_wallet');
  v_enforce    boolean := public.get_setting_bool('enforce_verified_documents');
  v_out        text[] := '{}'::text[];
BEGIN
  IF p_provider_id IS NULL THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  SELECT pp.user_id, pp.status, pp.registration_fee_paid
    INTO v_user_id, v_status, v_fee_paid
    FROM public.provider_profiles pp
   WHERE pp.id = p_provider_id;

  IF NOT FOUND THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  -- A suspended profile is already the subscription scheduler's own verdict
  -- (it sets SUSPENDED when the monthly fee cannot be paid), so that is the
  -- only status word worth giving: it names the cause, and it tells the
  -- provider to recharge rather than to contact support.
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    v_out := v_out || ARRAY[
      CASE WHEN v_status = 'SUSPENDED'
           THEN 'SUBSCRIPTION_UNPAID'
           ELSE 'ACCOUNT_NOT_APPROVED' END];
  END IF;

  IF COALESCE(v_fee_paid, false) IS NOT TRUE THEN
    v_out := v_out || ARRAY['ACTIVATION_FEE_UNPAID']::text[];
  END IF;

  IF v_enforce AND NOT public.provider_documents_verified(v_user_id) THEN
    v_out := v_out || ARRAY['DOCUMENTS_UNVERIFIED']::text[];
  END IF;

  -- An unfunded provider cannot cover the platform fee, and the failure would
  -- otherwise surface at the moment a buyer is waiting. The checkout already
  -- refuses an empty wallet; this is the same rule at the point the work is
  -- accepted rather than at the point it is paid for.
  IF NOT v_allow_neg THEN
    SELECT balance INTO v_balance
      FROM public.wallets WHERE provider_id = p_provider_id;
    IF COALESCE(v_balance, 0) <= 0 THEN
      v_out := v_out || ARRAY['WALLET_EMPTY']::text[];
    END IF;
  END IF;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.provider_fulfilment_blockers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_fulfilment_blockers(uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.provider_can_fulfil(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(array_length(public.provider_fulfilment_blockers(p_provider_id), 1), 0) = 0;
$$;

REVOKE ALL ON FUNCTION public.provider_can_fulfil(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_can_fulfil(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.provider_fulfilment_blockers(uuid) IS
  'Every reason this provider may not post a listing, add a vehicle, claim a '
  'ride or accept an order. Empty array = may work. Exists so a refusal can '
  'name itself instead of saying "you cannot do that".';

-- -----------------------------------------------------------------------------
-- 3. provider_can_publish now means the same thing everywhere
-- -----------------------------------------------------------------------------
--
-- Signature unchanged, so create_provider_product, create_provider_vehicle and
-- the products trigger in 20260927000076 all pick the stricter rule up without
-- being touched. Its old error code is kept for those callers; the new
-- surfaces below raise the richer one.

CREATE OR REPLACE FUNCTION public.provider_can_publish(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.provider_can_fulfil(p_provider_id);
$$;

REVOKE ALL ON FUNCTION public.provider_can_publish(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_can_publish(uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. claim_ride — restated
-- -----------------------------------------------------------------------------
--
-- Last defined in 2021_live_schema_snapshot.sql, which is BELOW this repo's
-- deploy baseline and is therefore marked applied WITHOUT executing, so the
-- body below is what has to be restated above the baseline to change it.
--
-- Verbatim from that snapshot apart from the added gate. The two existing
-- refusals keep their order and their codes: an ineligible vehicle is still
-- reported before eligibility is considered, so no existing caller sees a
-- different error for the same input.

CREATE OR REPLACE FUNCTION public.claim_ride(
  p_ride_id uuid,
  p_provider_id uuid,
  p_vehicle_id uuid
)
RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ride ride_requests;
  v_blockers text[];
BEGIN
  IF NOT exists (SELECT 1 FROM vehicles
                  WHERE id = p_vehicle_id
                    AND provider_id = p_provider_id
                    AND is_available = true) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE';
  END IF;

  IF NOT exists (SELECT 1 FROM provider_profiles
                  WHERE id = p_provider_id
                    AND provider_type = 'VEHICLE_PROVIDER'
                    AND status = 'APPROVED') THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ELIGIBLE';
  END IF;

  -- NEW. The same gate the listing path has used all along, applied to the
  -- one surface that had none. A rider's trip is not work a provider with an
  -- unreviewed ID and an empty wallet should be holding.
  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', array_to_string(v_blockers, ',');
  END IF;

  UPDATE ride_requests
     SET status = 'CLAIMED',
         claimed_by_provider_id = p_provider_id,
         claimed_vehicle_id = p_vehicle_id,
         claimed_at = now(),
         updated_at = now()
   WHERE id = p_ride_id
     AND status = 'REQUESTED'
  RETURNING * INTO v_ride;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'RIDE_ALREADY_TAKEN';
  END IF;

  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by)
  VALUES (p_ride_id, 'REQUESTED', 'CLAIMED', auth.uid());

  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'RIDE_CLAIMED', 'ride_requests', p_ride_id,
          jsonb_build_object('provider_id', p_provider_id, 'vehicle_id', p_vehicle_id));

  RETURN v_ride;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_ride(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ride(uuid, uuid, uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. transition_order_status — restated
-- -----------------------------------------------------------------------------
--
-- Verbatim from 20260927000085_gated_buyer_payment_request.sql apart from the
-- added guard. The guard is deliberately placed AFTER the actor checks and
-- BEFORE the whitelist is evaluated, and it only applies when the provider is
-- the actor and is not also an admin: a CEO unblocking a customer's order, or
-- the revenue scheduler settling one, must not be gated on that provider's
-- paperwork.

CREATE OR REPLACE FUNCTION public.transition_order_status(
  p_order_id uuid,
  p_new_status order_status,
  p_actor uuid,
  p_note text DEFAULT null
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders;
  v_old order_status;
  v_valid boolean := false;
  v_actor_is_provider boolean := false;
  v_actor_is_admin boolean := false;
  v_buyer_may_open_payment boolean := false;
  v_blockers text[];
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  v_old := v_order.status;

  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN')
    INTO v_actor_is_admin;
  SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_order.provider_id AND user_id = p_actor)
    INTO v_actor_is_provider;

  -- NEW. Accepting an order is taking the work, exactly as claiming a ride is,
  -- and it had no gate at all: a provider with an unpaid activation fee and an
  -- unreviewed ID could accept, and the buyer was committed to them.
  --
  -- Only when the PROVIDER is the actor. An admin or the CEO acting on the
  -- same order is doing exactly the job this gate is meant to make possible,
  -- and gating them on the provider's paperwork would make the escape hatch
  -- unavailable in the case it exists for.
  IF v_actor_is_provider AND NOT v_actor_is_admin THEN
    v_blockers := public.provider_fulfilment_blockers(v_order.provider_id);
    IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
      RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', array_to_string(v_blockers, ',');
    END IF;
  END IF;

  v_buyer_may_open_payment :=
    v_order.requires_availability_confirmation
    AND v_order.user_id = p_actor
    AND NOT v_actor_is_admin;

  v_valid := case v_old
    when 'CREATED' then
      p_new_status in ('PENDING_PROVIDER','CANCELLED')
      AND (v_order.user_id = p_actor OR v_actor_is_admin)

    when 'PENDING_PROVIDER' then
      (p_new_status in ('ACCEPTED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'ACCEPTED' then
      (p_new_status = 'PAYMENT_PENDING'
        AND (v_actor_is_provider OR v_actor_is_admin OR v_buyer_may_open_payment))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'PAYMENT_PENDING' then
      (p_new_status = 'PAYMENT_VERIFICATION' AND v_order.user_id = p_actor)
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    when 'PAYMENT_VERIFICATION' then
      p_new_status in ('APPROVED','REJECTED') AND v_actor_is_admin


    when 'APPROVED' then
      (p_new_status = 'STARTED' AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'STARTED' then
      (p_new_status = 'COMPLETED' AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status in ('DISPUTED','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'COMPLETED' then
      (p_new_status in ('DISPUTED','REFUNDED') AND (v_order.user_id = p_actor OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    when 'DISPUTED' then
      p_new_status in ('REFUNDED','COMPLETED') AND v_actor_is_admin

    else false
  end;

  IF NOT v_valid THEN
    RAISE EXCEPTION 'INVALID_TRANSITION_%_TO_%_FOR_ACTOR', v_old, p_new_status;
  END IF;

  -- Unchanged: contact and fulfilment stay behind a VERIFIED proof.
  IF p_new_status = 'APPROVED' AND v_order.requires_payment_proof THEN
    IF NOT exists (
      SELECT 1 FROM payment_proofs
       WHERE order_id = p_order_id AND verification_status = 'VERIFIED'
    ) THEN
      RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
    END IF;
  END IF;

  UPDATE orders SET status = p_new_status, updated_at = now()
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, note)
  VALUES (p_order_id, v_old, p_new_status, p_actor, p_note);

  -- Unchanged (migration 73): the transaction fee moves at STARTED.
  IF p_new_status = 'STARTED' THEN
    PERFORM deduct_transaction_fee(
      v_order.provider_id, p_order_id, null, v_order.total_amount,
      'order:' || p_order_id::text
    );
  END IF;

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. The blast radius, readable
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.provider_fulfilment_gate_report()
RETURNS TABLE (
  provider_id uuid,
  business_name text,
  provider_type text,
  status text,
  activation_fee_paid boolean,
  documents_verified boolean,
  wallet_balance numeric,
  blockers text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT pp.id,
         pp.business_name,
         pp.provider_type,
         pp.status,
         COALESCE(pp.registration_fee_paid, false),
         public.provider_documents_verified(pp.user_id),
         (SELECT w.balance FROM public.wallets w WHERE w.provider_id = pp.id),
         public.provider_fulfilment_blockers(pp.id)
    FROM public.provider_profiles pp
   ORDER BY array_length(public.provider_fulfilment_blockers(pp.id), 1) NULLS FIRST,
            pp.business_name;
$$;

REVOKE ALL ON FUNCTION public.provider_fulfilment_gate_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_fulfilment_gate_report()
  TO authenticated, service_role;

-- Re-read the grant: this one deliberately EXCLUDES anon, because unlike an
-- assertion it returns every provider's business name, document state and
-- wallet balance. The CEO reads it from the admin session.

-- -----------------------------------------------------------------------------
-- 7. The switch
-- -----------------------------------------------------------------------------

INSERT INTO public.system_settings (key, value, description)
VALUES (
  'enforce_verified_documents',
  'true'::jsonb,
  'When on, a provider whose identity document is still awaiting review '
  'cannot post a listing, add a vehicle, claim a ride or accept an order. '
  'The other three blockers (approval, activation fee, empty wallet) are not '
  'behind this switch. Set to false to fall back to "has an unrejected '
  'document", which is what the gate meant before 0113.'
)
ON CONFLICT (key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 8. Assertion
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_provider_fulfilment_gate_is_wired()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_gate text;
  v_publish text;
  v_ride text;
  v_order text;
  v_docs text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_gate FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_can_fulfil';
  IF v_gate IS NULL THEN
    RAISE EXCEPTION 'provider_can_fulfil is missing -- nothing enforces the fulfilment gate';
  END IF;
  IF v_gate NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['provider_can_fulfil does not consult provider_fulfilment_blockers'];
  END IF;

  SELECT prosrc INTO v_publish FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_can_publish';
  IF v_publish IS NULL OR v_publish NOT ILIKE '%can_fulfil%' THEN
    v_bad := v_bad || ARRAY['provider_can_publish no longer delegates to provider_can_fulfil, so the listing path has gone back to the weaker rule'];
  END IF;

  SELECT prosrc INTO v_ride FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'claim_ride';
  IF v_ride IS NULL THEN
    v_bad := v_bad || ARRAY['claim_ride is missing'];
  ELSIF v_ride NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['claim_ride no longer calls the fulfilment gate -- a provider with an unreviewed ID can take a rider''s trip again'];
  END IF;

  SELECT prosrc INTO v_order FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'transition_order_status';
  IF v_order IS NULL THEN
    v_bad := v_bad || ARRAY['transition_order_status is missing'];
  ELSIF v_order NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['transition_order_status no longer calls the fulfilment gate -- an unfunded provider can accept an order again'];
  END IF;

  -- The strict predicate must not accept MANUAL_REVIEW. That is the whole
  -- defect: the document half of the gate was satisfied by uploading one.
  SELECT prosrc INTO v_docs FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_documents_verified';
  IF v_docs IS NULL THEN
    v_bad := v_bad || ARRAY['provider_documents_verified is missing'];
  ELSIF v_docs ILIKE '%MANUAL_REVIEW%AUTO_APPROVED%'
     OR v_docs ILIKE '%manual_review%auto_approved%' THEN
    v_bad := v_bad || ARRAY['provider_documents_verified still accepts MANUAL_REVIEW, so "verified" still means "uploaded"'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'The fulfilment gate is not fully wired: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

-- anon IS granted here, unlike the gate functions above. Connectivity CI runs
-- its read-only assertions as the anon role, and a function reachable by
-- neither PUBLIC nor anon is reported by PostgREST as PGRST202 "could not
-- find the function in the schema cache" -- which reads like a migration that
-- never applied rather than a missing privilege. `check_money_notifications`
-- caught exactly that while this was still `authenticated`-only.
--
-- An assertion returns true or raises with the list of broken things. It
-- reads pg_proc's source text and touches no user data, which is why it is
-- safe to expose; the gate functions it reports on are not.
REVOKE ALL ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_provider_fulfilment_gate_is_wired()
  TO anon, authenticated, service_role;
