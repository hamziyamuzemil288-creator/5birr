-- 20261006000009 — no contact with a seller before payment
--
-- THE REPORT (item 7)
-- -------------------
-- Buyers could reach providers before an order existed: a "Contact seller"
-- button on the product page and in the checkout card, account numbers
-- readable by ANYONE (the reveal RPC was granted to `anon` for the public
-- product page), provider names on the payment copy, and no filter on the
-- order chat for phone numbers typed into messages.
--
-- WHAT THIS MIGRATION ENFORCES (the server half; the buttons are removed
-- in the client, this is the rule):
--   provider_payment_accounts  restated: `anon` grant REVOKED (a signed-out
--     caller can no longer read bank details at all), and a BUYER only
--     receives rows while they hold an ACCEPTED, unexpired, UNUSED
--     availability request for that provider — i.e. exactly the window
--     between the provider's YES and the order that consumes the request.
--     Owners and admins are unaffected. Empty set instead of an exception:
--     an empty list already renders "can't accept orders yet".
--   order_messages             a BEFORE INSERT/UPDATE trigger masks any
--     phone-shaped token in a TEXT message so the order thread cannot be
--     used to hand over a number instead of paying.
--
-- THE BUG THIS FILE HAD (found by running the pattern against a real
-- PostgreSQL 14, not by reading it): the first draft pattern
--   (?<![0-9])(?:\+|00)?(?:251)?[97][0-9]{8}(?![0-9])
-- masked 2519…/002519…/bare 911… numbers but let the MOST COMMON Ethiopian
-- mobile format — 09…/07… local numbers (0 + 9/7 + 8 digits) — through
-- untouched, and every space/dash/dot separated form with it. The buyer
-- typing “0911 2345 67” walked the number straight past the filter. The
-- pattern now lives in order_chat_phone_mask_pattern() (immutable, tested
-- by assert_no_contact_before_payment on both masked and must-NOT-be-masked
-- samples) and accepts the local 0-prefix and single separators between
-- digits while still refusing 13-digit bank accounts and longer runs.
--
-- Deploy: needs a Supabase deploy (function restatement + trigger).

-- ---------------------------------------------------------------------------
-- 1. provider_payment_accounts — availability YES required, anon revoked
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.provider_payment_accounts(
  p_provider_id uuid
)
RETURNS SETOF public.provider_payment_methods
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.*
    FROM public.provider_payment_methods m
    JOIN public.provider_profiles pp
      ON pp.id = m.provider_id
   WHERE m.provider_id = p_provider_id
     AND m.is_active = true
     AND (
       -- The owner and the administrator always see the rows.
       public.owns_provider_profile(m.provider_id)
       OR public.is_admin()
       OR (
         -- Item 7: a BUYER sees the numbers only after the provider said
         -- YES — an ACCEPTED request inside its 15-minute window that no
         -- order has consumed yet. Checkout is reached through the gate, so
         -- a legitimate buyer holds one; a caller who skipped the gate gets
         -- an empty set and the "can't accept orders yet" card.
         auth.uid() IS NOT NULL
         AND pp.status = 'APPROVED'::account_status
         AND EXISTS (
           SELECT 1 FROM public.availability_requests a
            WHERE a.buyer_id = auth.uid()
              AND a.provider_id = p_provider_id
              AND a.status = 'ACCEPTED'
              AND a.expires_at > now()
              AND a.used_at IS NULL
         )
       )
     )
   ORDER BY m.sort_order, m.created_at;
$$;

REVOKE ALL ON FUNCTION public.provider_payment_accounts(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_payment_accounts(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.provider_payment_accounts(uuid) IS
  'The ACTIVE payment accounts of one provider. Since 20261006000009 a '
  'buyer must hold an ACCEPTED, unexpired, unused availability request for '
  'that provider (the gate said YES) — and anon can no longer call it at '
  'all, so bank details are not readable from the public product page. '
  'Owners and admins always see their rows.';

-- ---------------------------------------------------------------------------
-- 2. The order thread masks phone numbers
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.order_chat_phone_mask_pattern()
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public, pg_temp
AS $$
  -- One phone-shaped token, bounded on both sides so it cannot bite a
  -- chunk out of a longer digit run (a 13-digit bank account, an order
  -- reference):
  --   (?<![0-9])         not in the middle of other digits
  --   (?:\+|00)?         optional international prefix
  --   (?:251|0)?         optional country code or the local trunk 0
  --   [97]               Ethiopian mobiles start 9 or 7
  --   [ .-]? … {7} …     8 more digits, single space/dash/dot separators
  --                       allowed between them (0911 2345 67, 09.11.…)
  --   (?![0-9])          ends at the end of the number, not halfway in
  SELECT '(?<![0-9])(?:(?:\+|00)[ .-]?)?(?:(?:251|0)[ .-]?)?[97]'
         '[ .-]?(?:[0-9][ .-]?){7}[0-9](?![0-9])';
$$;

COMMENT ON FUNCTION public.order_chat_phone_mask_pattern() IS
  'The regex mask_phone_in_order_messages applies, as a testable value: '
  'assert_no_contact_before_payment runs it against numbers that must be '
  'masked (09…, 07…, 2519…, +/00, spaced) and numbers that must not be '
  '(bank accounts, longer runs).';

CREATE OR REPLACE FUNCTION public.mask_phone_in_order_messages()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.kind IS DISTINCT FROM 'TEXT' OR NEW.body IS NULL THEN
    RETURN NEW;
  END IF;
  -- Masked, not rejected: the message survives (a refusal would let one
  -- party block the thread), the number does not.
  NEW.body := regexp_replace(
    NEW.body,
    public.order_chat_phone_mask_pattern(),
    '••••••',
    'g');
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.mask_phone_in_order_messages() IS
  'Masks phone-shaped tokens in order chat messages: after an order, '
  'communication happens only in the thread, and the thread does not hand '
  'over the number that takes the payment outside the platform.';

DROP TRIGGER IF EXISTS trg_order_messages_mask_phone ON public.order_messages;
CREATE TRIGGER trg_order_messages_mask_phone
  BEFORE INSERT OR UPDATE OF body ON public.order_messages
  FOR EACH ROW
  EXECUTE FUNCTION public.mask_phone_in_order_messages();

-- ---------------------------------------------------------------------------
-- 3. The assertion Connectivity CI runs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_no_contact_before_payment()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_reveal text;
  v_mask text;
  v_anon boolean;
  v_trigger int;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_reveal
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_payment_accounts';
  IF v_reveal IS NULL THEN
    v_bad := v_bad || ARRAY['provider_payment_accounts is missing'];
  ELSE
    IF v_reveal NOT ILIKE '%availability_requests%' THEN
      v_bad := v_bad || ARRAY[
        'provider_payment_accounts no longer demands an availability YES — '
        'a buyer can read bank details without the provider answering'];
    END IF;
    IF v_reveal NOT ILIKE '%used_at%' THEN
      v_bad := v_bad || ARRAY[
        'provider_payment_accounts no longer checks used_at — a consumed '
        'request still reveals the numbers'];
    END IF;
  END IF;

  -- The anon grant is the exact hole the report describes: bank details
  -- readable from an unauthenticated call aimed at the product page.
  SELECT (p.proacl::text LIKE '%anon%') INTO v_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_payment_accounts';
  IF COALESCE(v_anon, false) THEN
    v_bad := v_bad || ARRAY[
      'provider_payment_accounts is still executable by anon'];
  END IF;

  SELECT prosrc INTO v_mask
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'mask_phone_in_order_messages';
  IF v_mask IS NULL OR v_mask NOT ILIKE '%regexp_replace%' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat phone mask is missing — numbers can be handed over '
      'in the thread'];
  END IF;

  -- The pattern itself, exercised live: this is the check that would have
  -- caught the 09…/07… blind spot before deploy. It runs the exact regex
  -- the trigger uses against numbers that MUST be masked and digit runs
  -- that MUST NOT be (masking a bank account in the thread is a bug too).
  IF regexp_replace('0911234567',
       public.order_chat_phone_mask_pattern(), '•', 'g') <> '•' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat mask misses local 09/07 numbers — the commonest '
      'Ethiopian format walks straight through the filter'];
  END IF;
  IF regexp_replace('0911 2345 67',
       public.order_chat_phone_mask_pattern(), '•', 'g') <> '•' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat mask misses space-separated numbers (0911 2345 67)'];
  END IF;
  IF regexp_replace('+251911234567',
       public.order_chat_phone_mask_pattern(), '•', 'g') <> '•' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat mask misses international +251 numbers'];
  END IF;
  IF regexp_replace('1000123456789',
       public.order_chat_phone_mask_pattern(), '•', 'g')
       = '•' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat mask eats digit runs that are not phone numbers '
      '(a 13-digit bank account got masked)'];
  END IF;
  IF regexp_replace('2519112345678',
       public.order_chat_phone_mask_pattern(), '•', 'g') = '•' THEN
    v_bad := v_bad || ARRAY[
      'the order-chat mask matches inside longer digit runs'];
  END IF;

  SELECT count(*) INTO v_trigger
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'order_messages'
     AND NOT t.tgisinternal
     AND t.tgname = 'trg_order_messages_mask_phone';
  IF v_trigger = 0 THEN
    v_bad := v_bad || ARRAY[
      'trg_order_messages_mask_phone is not installed on order_messages'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the pre-payment contact rules are not wired: %',
      array_to_string(v_bad, '; ');
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_no_contact_before_payment()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_no_contact_before_payment() IS
  'True when account numbers need an availability YES (and anon cannot '
  'call the reveal at all) and the order thread masks phone numbers.';
