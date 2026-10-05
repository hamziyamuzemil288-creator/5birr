-- =============================================================================
-- 20260930000001 — the provider the buyer paid can verify that payment
-- =============================================================================
-- THE ASK
-- -------
-- A deposit into a PROVIDER's own wallet (the platform account) is confirmed by
-- an admin only — that stays exactly as it is. But a payment from a buyer or
-- booker INTO a provider's account is money that has already landed in that
-- provider's account, so the provider — who can see their own account balance
-- and the buyer's screenshot at the same time — may confirm it too.
--
-- THE GAP
-- -------
-- The order chain routes a buyer payment through one state only an admin can
-- leave:
--
--   PAYMENT_PENDING      -> PAYMENT_VERIFICATION   (buyer attaches the proof)
--   PAYMENT_VERIFICATION -> APPROVED | REJECTED    (ADMIN ONLY)
--
-- and the proof guard refuses a non-admin the single write that makes APPROVED
-- legal:
--
--   prevent_payment_proof_self_verification(): a non-admin may not change
--   payment_proofs.verification_status, and transition_order_status() refuses
--   APPROVED without a VERIFIED proof (PAYMENT_PROOF_REQUIRED).
--
-- That restriction exists for a real reason — a CUSTOMER must never approve
-- their own payment — but it overshot: it also stops the PROVIDER, the person
-- the money was actually transferred TO.
--
-- THE RULE, AFTER THIS MIGRATION
-- ------------------------------
-- PAYMENT_VERIFICATION may be left by an admin OR by the order's own provider,
-- and by nobody else. The BUYER is still excluded — that is the property the
-- existing assertion was written to protect, and it is restated below to keep
-- protecting exactly that while allowing the provider.
--
-- Three coordinated changes, all narrow, plus the assertion they invalidate:
--
--   1. transition_order_status(): the PAYMENT_VERIFICATION branch admits
--      v_actor_is_provider as well as v_actor_is_admin. Every other branch is
--      byte-for-byte the 20260927000113 body.
--   2. prevent_payment_proof_self_verification(): a non-admin may change a
--      proof's status when they own THIS order's provider profile. The buyer,
--      and every other provider, is still refused.
--   3. payment_proofs_admin_verify RLS policy: widen UPDATE to admin or the
--      order's provider, so the provider screen can make the same write the
--      admin screen already makes.
--   4. assert_order_chain_has_no_dead_ends(): restated, because it had the old
--      admin-only guard as a literal needle and would otherwise fail
--      Connectivity CI the moment this migration shipped.
--
-- Nothing here touches the wallet-recharge path: approve_wallet_recharge()
-- remains admin-only, so a provider still cannot credit their own platform
-- wallet. Only a buyer payment on a real order can be provider-verified.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. transition_order_status(): the provider may release their own order
-- -----------------------------------------------------------------------------
-- Body copied verbatim from 20260927000113_provider_fulfilment_gate.sql,
-- including the fulfilment gate for a provider actor and the buyer-opens-
-- payment clause from 20260927000085. The ONLY change is the
-- PAYMENT_VERIFICATION branch, which now also admits v_actor_is_provider.
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

  -- Unchanged (20260927000113): accepting an order is taking the work, so a
  -- provider actor must be fulfilment-ready. An admin/CEO acting on the same
  -- order is doing the job this gate exists to make possible, so they are not
  -- gated on the provider's paperwork.
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

    -- THE CHANGED LINE. The buyer is deliberately absent: the money reached
    -- the provider, so the provider decides, and the platform's admin may
    -- always override. `v_order.user_id = p_actor` is NOT consulted here.
    when 'PAYMENT_VERIFICATION' then
      p_new_status in ('APPROVED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin)

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

COMMENT ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text) IS
  'The order lifecycle whitelist. PAYMENT_VERIFICATION may be left by an admin '
  'OR by the order''s own provider — the party the buyer paid — and by nobody '
  'else; the BUYER is deliberately excluded. APPROVED still requires a VERIFIED '
  'payment proof.';

REVOKE ALL ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. The proof guard: the order's provider may record a decision
-- -----------------------------------------------------------------------------
-- Same shape as the live 0022c body (SECURITY DEFINER, admin passes, any other
-- status change raises), with one addition: a non-admin who owns THIS order's
-- provider profile is allowed. The buyer is still refused, because
-- owns_provider_profile(order.provider_id) is false for the buyer.
CREATE OR REPLACE FUNCTION public.prevent_payment_proof_self_verification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider_owns boolean := false;
BEGIN
  IF new.verification_status IS DISTINCT FROM old.verification_status THEN
    IF public.is_admin() THEN
      RETURN new;
    END IF;

    -- The provider the buyer paid may decide their own order's proof. Scoped
    -- to ownership of this order's provider profile, so this grants no reach
    -- over another provider's order and never over the buyer's own.
    SELECT EXISTS (
      SELECT 1
        FROM public.orders o
       WHERE o.id = new.order_id
         AND o.provider_id IS NOT NULL
         AND public.owns_provider_profile(o.provider_id)
    ) INTO v_provider_owns;

    IF NOT v_provider_owns THEN
      RAISE EXCEPTION 'VERIFICATION_IS_ADMIN_ONLY';
    END IF;
  END IF;

  RETURN new;
END;
$$;

-- The trigger already points at this function name (0022d); restating the
-- CREATE TRIGGER is only to be explicit and is idempotent.
DROP TRIGGER IF EXISTS trg_payment_proofs_security ON public.payment_proofs;
CREATE TRIGGER trg_payment_proofs_security
  BEFORE UPDATE ON public.payment_proofs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_payment_proof_self_verification();

-- -----------------------------------------------------------------------------
-- 3. RLS: the provider may update their own order's proof
-- -----------------------------------------------------------------------------
-- Widened from admin-only to admin OR the order's provider. Read and insert
-- policies are untouched: the buyer still inserts the proof, and the buyer and
-- provider still read it through the existing payment_proofs_read policy.
DROP POLICY IF EXISTS payment_proofs_admin_verify ON public.payment_proofs;
CREATE POLICY payment_proofs_admin_verify ON public.payment_proofs
  FOR UPDATE
  TO authenticated
  USING (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = payment_proofs.order_id
         AND public.owns_provider_profile(o.provider_id)
    )
  )
  WITH CHECK (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.orders o
       WHERE o.id = payment_proofs.order_id
         AND public.owns_provider_profile(o.provider_id)
    )
  );

-- -----------------------------------------------------------------------------
-- 4. The order-chain assertion, restated for the new rule
-- -----------------------------------------------------------------------------
-- Restated from 20260927000012 with one change: the needle for the
-- PAYMENT_VERIFICATION guard is the rule this migration ships —
--   ... and (v_actor_is_provider or v_actor_is_admin)
-- instead of the old `... and v_actor_is_admin`. Everything else — the
-- whitespace-flattened, lower-cased comparison and the branch-existence loop —
-- is copied verbatim, because that matching behaviour is what makes the
-- assertion reliable across how the function was last applied.
--
-- The assertion now protects the property that still matters: the BUYER can
-- never leave PAYMENT_VERIFICATION. A future refactor that admits
-- `v_order.user_id = p_actor` fails here.
CREATE OR REPLACE FUNCTION public.assert_order_chain_has_no_dead_ends()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_flat text;
  v_status text;
  v_escapable text[] := ARRAY[
    'CREATED', 'PENDING_PROVIDER', 'ACCEPTED', 'PAYMENT_PENDING',
    'PAYMENT_VERIFICATION', 'APPROVED', 'STARTED', 'COMPLETED', 'DISPUTED'
  ];
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'transition_order_status';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  v_flat := regexp_replace(lower(v_src), E'\\s+', ' ', 'g');

  FOREACH v_status IN ARRAY v_escapable LOOP
    IF position('when ''' || lower(v_status) || ''' then' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  -- PAYMENT_VERIFICATION must be restricted to admin OR the order's provider.
  -- Loosening it to the buyer would let a customer approve their own payment,
  -- so that direction must fail CI.
  IF position(
       'when ''payment_verification'' then p_new_status in (''approved'',''rejected'') and (v_actor_is_provider or v_actor_is_admin)'
       in v_flat
     ) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_order_chain_has_no_dead_ends() IS
  'True when every non-terminal order status has an onward transition in '
  'transition_order_status(), and PAYMENT_VERIFICATION is restricted to an '
  'admin or the order''s own provider (never the buyer).';

GRANT EXECUTE ON FUNCTION public.assert_order_chain_has_no_dead_ends() TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. The assertion for this feature
-- -----------------------------------------------------------------------------
-- Reported, not raised, in the shape the Connectivity suite reads. Checks the
-- three coordinated pieces exist and point the right way, and that the wallet
-- path is NOT what widened: approve_wallet_recharge() must still be admin-gated.
CREATE OR REPLACE FUNCTION public.assert_provider_can_verify_buyer_payment()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_problem text[] := '{}';
  v_flat text;
BEGIN
  -- (a) the transition whitelist admits the provider and not the buyer.
  SELECT regexp_replace(lower(coalesce(pg_get_functiondef(
           'public.transition_order_status(uuid, order_status, uuid, text)'::regprocedure
         ), '')), E'\\s+', ' ', 'g')
    INTO v_flat;

  IF v_flat = '' THEN
    v_problem := array_append(v_problem, 'transition_order_status() is missing');
  ELSE
    IF position(
         'when ''payment_verification'' then p_new_status in (''approved'',''rejected'') and (v_actor_is_provider or v_actor_is_admin)'
         in v_flat
       ) = 0 THEN
      v_problem := array_append(v_problem,
        'transition_order_status() does not allow the order''s provider to leave PAYMENT_VERIFICATION');
    END IF;
    IF position('payment_proof_required' in v_flat) = 0 THEN
      v_problem := array_append(v_problem,
        'transition_order_status() no longer refuses APPROVED without a VERIFIED proof');
    END IF;
  END IF;

  -- (b) the proof guard consults order ownership, so the provider may write it.
  SELECT regexp_replace(lower(coalesce(pg_get_functiondef(
           'public.prevent_payment_proof_self_verification()'::regprocedure
         ), '')), E'\\s+', ' ', 'g')
    INTO v_flat;
  IF position('owns_provider_profile' in v_flat) = 0 THEN
    v_problem := array_append(v_problem,
      'prevent_payment_proof_self_verification() does not consult order ownership, so a provider cannot record a decision');
  END IF;

  -- (c) the platform-wallet path must NOT have widened: a provider still may
  -- not credit their own wallet.
  IF position('insufficient_permission' in lower(coalesce(pg_get_functiondef(
       'public.approve_wallet_recharge(uuid, uuid)'::regprocedure), ''))) = 0 THEN
    v_problem := array_append(v_problem,
      'approve_wallet_recharge() no longer refuses a non-admin, so a provider could credit their own platform wallet');
  END IF;

  IF cardinality(v_problem) > 0 THEN
    RETURN concat('PROVIDER_PAYMENT_VERIFICATION_NOT_WIRED: ', array_to_string(v_problem, '; '));
  END IF;

  RETURN 'provider buyer-payment verification OK: PAYMENT_VERIFICATION may be '
         || 'left by an admin or the order''s provider; wallet recharge stays admin-only';
END;
$$;

COMMENT ON FUNCTION public.assert_provider_can_verify_buyer_payment() IS
  'Proves the provider may verify a buyer''s order payment while the platform '
  'wallet recharge path stays admin-only. Returns a diagnostic string; never raises.';

GRANT EXECUTE ON FUNCTION public.assert_provider_can_verify_buyer_payment()
  TO anon, authenticated, service_role;

-- PostgREST caches the function list; without this the app can still be served
-- the old transition_order_status until the next schema reload.
NOTIFY pgrst, 'reload schema';
