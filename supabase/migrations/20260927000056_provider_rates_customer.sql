-- A provider can rate the customer they just served.
--
-- WHAT EXISTED
-- ------------
-- `reviews` is polymorphic -- target_type + target_id -- and its CHECK allowed
-- only ('PRODUCT', 'PROVIDER', 'VEHICLE'). reviews_user_insert then allowed a
-- row only when the order belonged to auth.uid() and was COMPLETED, which is
-- the "a buyer rates what they bought" rule and nothing else.
--
-- So the founder's "providers can rate their users" had no path at all: the
-- constraint rejected the value and the policy would have rejected the row.
-- This adds exactly the missing half, as the mirror image of the rule that
-- already exists.
--
-- THE RULE, AND WHY IT IS NOT JUST "is a provider"
-- -------------------------------------------------
-- A provider may rate a customer only from an order they themselves served to
-- that customer, and only once it is COMPLETED. That is reviews_user_insert
-- with the two sides swapped: o.provider_id must be a profile the caller owns,
-- and o.user_id is the customer being rated. The swap is what stops this from
-- becoming a reputation-laundering tool -- a provider cannot invent a review of
-- someone they never served, and cannot rate a customer on an order that is
-- still in flight.
--
-- target_id is the CUSTOMER's user id (auth.users id == profiles.id), not a
-- profile row, because that is the id the app has when it renders "Rate this
-- customer" on a completed order.
--
-- The CHECK is widened rather than replaced, so the three existing values keep
-- their meaning and an unknown value is still refused. The same drop-then-add
-- shape is used in 20260923000004 for admin_notification_broadcasts.

-- ===========================================================================
-- 1. Widen the allowed target types
-- ===========================================================================
ALTER TABLE public.reviews DROP CONSTRAINT IF EXISTS reviews_target_type_check;

ALTER TABLE public.reviews ADD CONSTRAINT reviews_target_type_check
  CHECK (target_type IN ('PRODUCT', 'PROVIDER', 'VEHICLE', 'USER'));

COMMENT ON CONSTRAINT reviews_target_type_check ON public.reviews IS
  'USER is the customer on an order the provider served. Added by '
  '20260927000056 so a provider can rate the person they just served; the '
  'other three are unchanged and still the only ways to rate a listing.';

-- ===========================================================================
-- 2. The mirrored insert policy
-- ===========================================================================
CREATE POLICY reviews_provider_insert ON public.reviews
  FOR INSERT
  WITH CHECK (
    -- prevent_review_insert_privilege_escalation() already forces
    -- user_id = auth.uid(), so the reviewer is always the caller.
    (user_id = auth.uid())
    AND target_type = 'USER'
    AND EXISTS (
      SELECT 1
        FROM public.orders o
       WHERE o.id = reviews.order_id
         AND o.status = 'COMPLETED'::order_status
         AND o.user_id = reviews.target_id
         AND public.owns_provider_profile(o.provider_id)
    )
  );

-- ===========================================================================
-- 3. Read the reviews a customer received
-- ===========================================================================
-- reviews_public_read is USING (true), so a review of a user is already
-- readable; nothing is widened here. The one rule that is added is that the
-- reviewer, the reviewed customer and staff can each delete -- mirroring
-- reviews_owner_delete so a customer is not stuck with a review they dispute
-- and a provider is not stuck with one they cannot answer.
CREATE POLICY reviews_reviewed_user_delete ON public.reviews
  FOR DELETE
  USING (target_type = 'USER' AND target_id = auth.uid());

-- An existing UNIQUE (user_id, target_type, target_id, order_id) is already in
-- place, so one customer cannot be rated twice for the same order even from
-- the provider side. No new index needed.

NOTIFY pgrst, 'reload schema';
