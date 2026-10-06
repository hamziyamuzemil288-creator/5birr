-- 20261006000006 — the availability gate: no order without a provider's YES
--
-- THE REPORT (twice)
-- ------------------
-- "Availability check before every Buy / Book." Buyers could go straight to
-- payment without the provider ever being asked whether the item exists.
-- Reproduced from code (harness check
-- check_availability_gate_covers_every_checkout fails against the tree as it
-- stood): there was NO gate. The pieces that existed were all one layer too
-- late or one flag too narrow:
--
--   * `products.requires_availability_confirmation` (0074) is an optional
--     PER-LISTING flag; unflagged listings went to payment directly, and
--     even flagged ones asked only AFTER an order row existed
--     (PENDING_PROVIDER), so the buyer had already committed to checkout;
--   * nothing asked before checkout, nothing had a 15-minute window, no
--     request row existed to show an admin, and
--   * create_order_secure demanded no request of any kind.
--
-- WHAT THIS MIGRATION BUILDS
-- --------------------------
--   table    availability_requests — buyer, product, provider, quantity,
--            status PENDING/ACCEPTED/REJECTED/EXPIRED/CANCELLED, reason,
--            created_at, expires_at = +15 min, responded_at, used_at.
--            One ACTIVE request per buyer+product (partial unique index on
--            status = 'PENDING'), so a double-tap cannot stack duplicates.
--   rpc      create_availability_requests(provider, products[]) — idempotent
--            (returns an existing PENDING/ACCEPTED row instead of a second),
--            stamps quantity from the cart, notifies the provider through
--            notify_best_effort so an offline provider or one with no push
--            token can never fail the buyer's ask.
--   rpc      respond_availability_request(id, accept, reason) — provider
--            only, row-locked, refuses a second answer
--            (REQUEST_ALREADY_ANSWERED) and a late one
--            (REQUEST_EXPIRED), notifies the buyer instantly.
--   rpc      cancel_availability_request(id) — the buyer stands it down.
--   cron     expire_availability_requests() every minute flips unanswered
--            PENDING rows past expires_at to EXPIRED.
--   order    create_order_secure is restated (argv untouched — 0125
--            transcribes it) to REQUIRE an ACCEPTED, unexpired, UNUSED
--            request for every product in p_items and to claim it via
--            used_at. That is the enforcement half: the client gate is UX,
--            this is the rule.
--   realtime availability_requests joins supabase_realtime so the buyer's
--            waiting screen and the provider's popup learn of the answer
--            without polling (the screens poll anyway — fallback).
--
-- Coexistence: the per-listing requires_availability_confirmation /
-- PENDING_PROVIDER flow (0074/0133) is untouched. This gate runs BEFORE
-- checkout for every purchase; that one still runs at order level for the
-- listings that opt in. A flagged listing therefore asks twice — pre-order
-- (this gate) and at order level (existing behaviour, whose assertions are
-- many). Removing the second ask would rewrite the order status chain this
-- repository has already had to repair twice; keeping both costs a tap and
-- risks nothing.
--
-- Deploy: needs a Supabase deploy (table, RPCs, cron job, enum values).

-- ---------------------------------------------------------------------------
-- 0. The two notification types, BEFORE anything writes them
-- ---------------------------------------------------------------------------
-- Same reasoning as 0133: a plpgsql body is syntax-checked at CREATE and
-- its enum literals resolve at first CALL, so the member has to exist first.
ALTER TYPE public.notification_type
  ADD VALUE IF NOT EXISTS 'AVAILABILITY_REQUEST';
ALTER TYPE public.notification_type
  ADD VALUE IF NOT EXISTS 'AVAILABILITY_RESPONSE';

-- ---------------------------------------------------------------------------
-- 1. The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.availability_requests (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id  uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  buyer_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id)
                ON DELETE CASCADE,
  quantity    numeric NOT NULL DEFAULT 1,
  status      text NOT NULL DEFAULT 'PENDING'
                CHECK (status IN
                       ('PENDING','ACCEPTED','REJECTED','EXPIRED','CANCELLED')),
  reason      text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  responded_at timestamptz,
  used_at     timestamptz,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- One ACTIVE ask per buyer+product. This is the double-tap guard made
-- structural: the second tap conflicts and the RPC returns the first row.
CREATE UNIQUE INDEX IF NOT EXISTS uq_availability_one_active
  ON public.availability_requests (buyer_id, product_id)
  WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_availability_provider_created
  ON public.availability_requests (provider_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_availability_buyer_created
  ON public.availability_requests (buyer_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_availability_expiry
  ON public.availability_requests (status, expires_at)
  WHERE status = 'PENDING';

DROP TRIGGER IF EXISTS trg_availability_requests_updated
  ON public.availability_requests;
CREATE TRIGGER trg_availability_requests_updated
  BEFORE UPDATE ON public.availability_requests FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

ALTER TABLE public.availability_requests ENABLE ROW LEVEL SECURITY;

-- READ-ONLY for clients, three audiences: the buyer who asked, the provider
-- asked, the admin watching. There is deliberately NO INSERT/UPDATE/DELETE
-- policy — every write goes through the SECURITY DEFINER RPCs, so a client
-- cannot pre-accept its own request or answer for a provider.
DO $$ BEGIN
  CREATE POLICY availability_requests_buyer_read
    ON public.availability_requests FOR SELECT
    USING (buyer_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE POLICY availability_requests_provider_read
    ON public.availability_requests FOR SELECT
    USING (public.owns_provider_profile(provider_id));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
  CREATE POLICY availability_requests_admin_read
    ON public.availability_requests FOR SELECT
    USING (public.is_admin());
EXCEPTION WHEN duplicate_object THEN null; END $$;

REVOKE ALL ON public.availability_requests FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.availability_requests FROM authenticated;
GRANT SELECT ON public.availability_requests TO authenticated;

-- Realtime: without the publication entry every .stream() on this table is
-- dead on arrival (the exact defect 0041 fixed for ride_requests).
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.availability_requests;
  EXCEPTION
    WHEN duplicate_object THEN NULL;
    WHEN undefined_object THEN NULL;
  END;
END $$;

-- ---------------------------------------------------------------------------
-- 2. The buyer asks: create_availability_requests(provider, products[])
-- ---------------------------------------------------------------------------
-- Idempotent by construction:
--   * an ACCEPTED, unexpired, unused row for the product is returned as-is
--     (the buyer already cleared it — no second ask);
--   * an existing PENDING row is returned as-is (the double-tap, or a
--     waiting screen reopened after the app was killed);
--   * otherwise one row is inserted, quantity taken from the buyer's cart,
--     expiring 15 minutes from now.
-- The provider is told through notify_best_effort, which swallows delivery
-- failure: a provider who is offline or has no push token must not fail the
-- buyer's request — the row itself, the pending section and the admin queue
-- all exist for exactly that case.

CREATE OR REPLACE FUNCTION public.create_availability_requests(
  p_provider_id uuid,
  p_product_ids uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_buyer uuid := auth.uid();
  v_pid uuid;
  v_product public.products%ROWTYPE;
  v_row public.availability_requests%ROWTYPE;
  v_new_id uuid;
  v_qty numeric;
  v_name text;
  v_out jsonb := '[]'::jsonb;
BEGIN
  IF v_buyer IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;
  IF p_provider_id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_REQUIRED';
  END IF;
  IF p_product_ids IS NULL OR coalesce(array_length(p_product_ids, 1), 0) = 0 THEN
    RAISE EXCEPTION 'p_product_ids must not be empty';
  END IF;

  FOR v_pid IN SELECT DISTINCT unnest(p_product_ids) LOOP
    -- Already cleared? (Checkout's backstop and a re-tap both land here.)
    SELECT * INTO v_row
      FROM public.availability_requests
     WHERE buyer_id = v_buyer
       AND product_id = v_pid
       AND status = 'ACCEPTED'
       AND expires_at > now()
       AND used_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1;
    IF FOUND THEN
      v_out := v_out || jsonb_build_array(to_jsonb(v_row));
      CONTINUE;
    END IF;

    -- Already waiting? The unique partial index is the hard guarantee; this
    -- read is what turns a racing double-tap into one request instead of an
    -- error the buyer would see as "something went wrong".
    SELECT * INTO v_row
      FROM public.availability_requests
     WHERE buyer_id = v_buyer
       AND product_id = v_pid
       AND status = 'PENDING'
       AND expires_at > now()
     ORDER BY created_at DESC
     LIMIT 1;
    IF FOUND THEN
      v_out := v_out || jsonb_build_array(to_jsonb(v_row));
      CONTINUE;
    END IF;

    -- The product must exist and belong to the provider being asked — the
    -- order-side check compares the same two columns, so a mismatch here is
    -- caught before checkout rather than at submission.
    SELECT * INTO v_product
      FROM public.products WHERE id = v_pid;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
    END IF;
    IF v_product.provider_id <> p_provider_id THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FROM_PROVIDER';
    END IF;

    SELECT coalesce(quantity, 1) INTO v_qty
      FROM public.cart_items
     WHERE user_id = v_buyer AND product_id = v_pid;
    v_qty := coalesce(v_qty, 1);

    BEGIN
      INSERT INTO public.availability_requests
        (product_id, buyer_id, provider_id, quantity, status, expires_at)
      VALUES
        (v_pid, v_buyer, p_provider_id, v_qty, 'PENDING',
         now() + interval '15 minutes')
      ON CONFLICT (buyer_id, product_id) WHERE status = 'PENDING'
      DO NOTHING
      RETURNING id INTO v_new_id;
    EXCEPTION WHEN unique_violation THEN
      -- Lost the race by milliseconds: fall through to the re-select below.
      v_new_id := NULL;
    END;

    IF v_new_id IS NOT NULL THEN
      SELECT name INTO v_name FROM public.products WHERE id = v_pid;
      PERFORM public.notify_best_effort(
        (SELECT pp.user_id FROM public.provider_profiles pp
          WHERE pp.id = p_provider_id),
        'AVAILABILITY_REQUEST',
        'Availability request',
        coalesce(v_name, 'An item') ||
          CASE WHEN v_qty = 1
               THEN ' — a buyer asks if 1 item is available. You have 15 minutes to answer.'
               ELSE ' — a buyer asks if ' || v_qty || ' units are available. You have 15 minutes to answer.'
          END,
        jsonb_build_object(
          'availability_request_id', v_new_id,
          'product_id', v_pid,
          'buyer_id', v_buyer,
          'quantity', v_qty));
    END IF;

    -- Return whichever row now exists (inserted, or the concurrent winner's).
    SELECT * INTO v_row
      FROM public.availability_requests
     WHERE buyer_id = v_buyer
       AND product_id = v_pid
       AND status = 'PENDING'
     ORDER BY created_at DESC
     LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'AVAILABILITY_REQUEST_NOT_CREATED';
    END IF;
    v_out := v_out || jsonb_build_array(to_jsonb(v_row));
  END LOOP;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.create_availability_requests(uuid, uuid[])
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_availability_requests(uuid, uuid[])
  TO authenticated, service_role;

COMMENT ON FUNCTION public.create_availability_requests(uuid, uuid[]) IS
  'Creates (or resumes) one PENDING availability request per product for the '
  'signed-in buyer, 15-minute expiry, quantity from the cart, and notifies '
  'the provider best-effort. Returns the live rows as a jsonb array.';

-- ---------------------------------------------------------------------------
-- 3. The provider answers: respond_availability_request
-- ---------------------------------------------------------------------------
-- Row-locked so two taps serialise; PENDING is re-checked after the lock so
-- a second answer (or an answer racing the expiry sweep) is refused rather
-- than applied. A late answer is refused with REQUEST_EXPIRED — the cron
-- will land the row on EXPIRED within a minute.

CREATE OR REPLACE FUNCTION public.respond_availability_request(
  p_request_id uuid,
  p_accept boolean,
  p_reason text DEFAULT NULL
)
RETURNS public.availability_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_req public.availability_requests%ROWTYPE;
  v_name text;
  v_reason text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT * INTO v_req
    FROM public.availability_requests
   WHERE id = p_request_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REQUEST_NOT_FOUND';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profiles
     WHERE id = v_req.provider_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'NOT_YOUR_REQUEST';
  END IF;

  IF v_req.status <> 'PENDING' THEN
    RAISE EXCEPTION 'REQUEST_ALREADY_ANSWERED';
  END IF;

  IF v_req.expires_at <= now() THEN
    RAISE EXCEPTION 'REQUEST_EXPIRED';
  END IF;

  v_reason := CASE
    WHEN p_accept THEN NULL
    ELSE nullif(coalesce(btrim(p_reason), ''), '')
  END;

  UPDATE public.availability_requests
     SET status = CASE WHEN p_accept THEN 'ACCEPTED' ELSE 'REJECTED' END,
         responded_at = now(),
         reason = v_reason,
         updated_at = now()
   WHERE id = p_request_id
   RETURNING * INTO v_req;

  SELECT name INTO v_name FROM public.products WHERE id = v_req.product_id;

  PERFORM public.notify_best_effort(
    v_req.buyer_id,
    'AVAILABILITY_RESPONSE',
    CASE WHEN p_accept
         THEN 'Available — you can continue to checkout'
         ELSE 'Not available' END,
    CASE WHEN p_accept
         THEN coalesce(v_name, 'Your item') ||
              ' is available. Continue to checkout within 15 minutes to complete your order.'
         ELSE coalesce(v_name, 'Your item') || ' is not available' ||
              coalesce(': ' || v_reason, '.') ||
              ' Find another provider.'
    END,
    jsonb_build_object(
      'availability_request_id', v_req.id,
      'product_id', v_req.product_id,
      'provider_id', v_req.provider_id,
      'accepted', p_accept,
      'reason', v_reason));

  RETURN v_req;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_availability_request(uuid, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.respond_availability_request(uuid, boolean, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.respond_availability_request(uuid, boolean, text) IS
  'The provider accepts or declines a PENDING availability request (row-'
  'locked, refuses a second answer and a late one) and tells the buyer '
  'immediately.';

-- ---------------------------------------------------------------------------
-- 4. The buyer stands it down: cancel_availability_request
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.cancel_availability_request(
  p_request_id uuid
)
RETURNS public.availability_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_req public.availability_requests%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT * INTO v_req
    FROM public.availability_requests
   WHERE id = p_request_id
   FOR UPDATE;

  IF NOT FOUND OR v_req.buyer_id <> auth.uid() THEN
    RAISE EXCEPTION 'NOT_YOUR_REQUEST';
  END IF;

  -- Idempotent for the dead states: a buyer whose countdown just hit zero
  -- must not be shown an error for cancelling a request the cron already
  -- expired. Only a live answer is a refusal.
  IF v_req.status IN ('EXPIRED', 'CANCELLED') THEN
    RETURN v_req;
  END IF;
  IF v_req.status <> 'PENDING' THEN
    RAISE EXCEPTION 'REQUEST_ALREADY_ANSWERED';
  END IF;

  UPDATE public.availability_requests
     SET status = 'CANCELLED',
         updated_at = now()
   WHERE id = p_request_id
   RETURNING * INTO v_req;

  RETURN v_req;
END;
$$;

REVOKE ALL ON FUNCTION public.cancel_availability_request(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_availability_request(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. The timeout: expire_availability_requests() on pg_cron
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.expire_availability_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  UPDATE public.availability_requests
     SET status = 'EXPIRED',
         updated_at = now()
   WHERE status = 'PENDING'
     AND expires_at <= now();
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_availability_requests()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_availability_requests()
  TO service_role;

COMMENT ON FUNCTION public.expire_availability_requests() IS
  'Flips unanswered PENDING availability requests past expires_at to '
  'EXPIRED. Scheduled every minute (5birr-availability-expiry).';

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = '5birr-availability-expiry'
  ) THEN
    PERFORM cron.schedule(
      '5birr-availability-expiry',
      '* * * * *',
      $cron$SELECT public.expire_availability_requests()$cron$
    );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6. The rule: create_order_secure demands the request
-- ---------------------------------------------------------------------------
-- Restated from 20260927000133 — argv identical (0125 transcribes it), the
-- unapproved-provider guard left byte-for-byte where
-- assert_orders_block_unapproved_providers' normalised-substring check
-- expects it, the PENDING_PROVIDER insert, the history row, the short order
-- number and the ORDER_RECEIVED notification all kept. The one addition is
-- the gate, placed AFTER the provider guard so that assertion still sees
-- PROVIDER_NOT_ACCEPTING_ORDERS fire first for an unapproved provider.

CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null,
  p_fulfillment_mode text default 'DELIVERY',
  p_delivery_address text default null,
  p_city text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_needs_availability boolean := false;
  v_order_number text;
  v_item_count int;
  v_av_pid uuid;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;
  if p_fulfillment_mode is null or p_fulfillment_mode not in ('DELIVERY','SELF_PICKUP') then
    p_fulfillment_mode := 'DELIVERY';
  end if;
  if p_fulfillment_mode = 'DELIVERY' and coalesce(trim(p_delivery_address), '') = '' then
    raise exception 'DELIVERY_REQUIRES_ADDRESS';
  end if;

  if not exists (
    select 1 from provider_profiles
     where id = p_provider_id and status = 'APPROVED'
  ) then
    raise exception 'PROVIDER_NOT_ACCEPTING_ORDERS';
  end if;

  -- 20261006000006. Every product in this order must carry an ACCEPTED,
  -- unexpired, unused availability request from THIS buyer to THIS provider.
  -- The app runs the gate before checkout; this is where it becomes a rule
  -- rather than a courtesy, and it is also why a mismatched product (one
  -- that does not belong to p_provider_id) is refused: it can carry no
  -- request from this provider. The matching requests are claimed in the
  -- same transaction, so one acceptance pays for exactly one order.
  for v_av_pid in
    select distinct (e->>'product_id')::uuid
      from jsonb_array_elements(p_items) e
  loop
    if not exists (
      select 1 from availability_requests
       where buyer_id = p_user_id
         and provider_id = p_provider_id
         and product_id = v_av_pid
         and status = 'ACCEPTED'
         and expires_at > now()
         and used_at is null
    ) then
      raise exception 'AVAILABILITY_CONFIRMATION_REQUIRED: %', v_av_pid;
    end if;
  end loop;

  update availability_requests
     set used_at = now(), updated_at = now()
   where buyer_id = p_user_id
     and provider_id = p_provider_id
     and status = 'ACCEPTED'
     and expires_at > now()
     and used_at is null
     and product_id in (
       select distinct (e->>'product_id')::uuid
         from jsonb_array_elements(p_items) e);

  select exists (
    select 1
      from (select distinct on (e->>'product_id') e->>'product_id' as product_id
              from jsonb_array_elements(p_items) e) d
      join products pr on pr.id = d.product_id::uuid
     where pr.requires_availability_confirmation
  ) into v_needs_availability;

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at, fulfillment_mode,
    delivery_address, city, requires_availability_confirmation
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'PENDING_PROVIDER',
    p_total_amount, coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
    nullif(trim(p_delivery_address), ''),
    coalesce(
      nullif(trim(p_city), ''),
      (select pp.city from provider_profiles pp where pp.id = p_provider_id),
      default_city()
    ),
    coalesce(v_needs_availability, false)
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(),
      v_order_id,
      (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::numeric,
      (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'PENDING_PROVIDER', p_user_id, p_note);

  v_order_number := upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
  select count(*) into v_item_count from order_items oi where oi.order_id = v_order_id;

  perform public.notify_best_effort(
    (select pp.user_id from provider_profiles pp where pp.id = p_provider_id),
    'ORDER_RECEIVED',
    case when v_needs_availability
         then 'Availability request ' || coalesce(v_order_number, '')
         else 'New order ' || coalesce(v_order_number, '')
    end,
    case when v_needs_availability then
      case when v_item_count = 1
           then 'A customer is asking whether you have 1 item available. '
                || 'Open it to confirm or decline.'
           else 'A customer is asking whether you have ' || v_item_count
                || ' items available. Open it to confirm or decline.'
      end
      else
        case when v_item_count = 1
             then 'A customer placed an order for 1 item. Open it to confirm.'
             else 'A customer placed an order for ' || v_item_count
                  || ' items. Open it to confirm.'
        end
    end,
    jsonb_build_object(
      'order_id', v_order_id,
      'order_number', v_order_number,
      'requires_availability_confirmation', coalesce(v_needs_availability, false))
  );

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

REVOKE ALL ON FUNCTION public.create_order_secure(
  uuid, uuid, jsonb, numeric, text, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_order_secure(
  uuid, uuid, jsonb, numeric, text, text, text, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. assert_order_creation_writes — restated with the seed the app now makes
-- ---------------------------------------------------------------------------
-- Verbatim from 20260927000024 apart from ONE insertion: the fixture order
-- now needs the ACCEPTED availability request every order needs, or this
-- write test would fail against a CORRECT gate and teach everyone to
-- distrust it. Everything else — the sentinel rollback, the jwt claim, the
-- client-guard probe, the PENDING_PROVIDER assertions, the unapproved-
-- provider refusal — is unchanged.

CREATE OR REPLACE FUNCTION public.assert_order_creation_writes()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000c0de';
  v_prov  uuid := '00000000-0000-4000-8000-0000000000c1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000000c2';
  v_order jsonb;
  v_row   record;
  v_count int;
BEGIN
  BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at)
    VALUES (v_user, 'write-test@example.invalid', now())
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user, 'Write Test', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES (v_prov, v_user, 'SERVICE_PROVIDER', 'Write Test Provider', 'APPROVED')
    ON CONFLICT (id) DO NOTHING;
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    INSERT INTO public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    VALUES (v_prod, v_prov, 'Write Test Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    ON CONFLICT (id) DO NOTHING;

    -- 20261006000006: the gate. Seed exactly what the app's availability
    -- screen produces before checkout — ACCEPTED, unexpired, unused — so
    -- the real create_order_secure sees what every real order now needs.
    INSERT INTO public.availability_requests
      (product_id, buyer_id, provider_id, quantity, status,
       expires_at, responded_at)
    VALUES (v_prod, v_user, v_prov, 2, 'ACCEPTED',
            now() + interval '15 minutes', now())
    ON CONFLICT DO NOTHING;

    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    IF public.is_server_write() THEN
      RAISE EXCEPTION 'is_server_write() is true for an authenticated client, so the client guards would be skipped and this test would prove nothing';
    END IF;

    v_order := public.create_order_secure(
      p_user_id          => v_user,
      p_provider_id      => v_prov,
      p_items            => jsonb_build_array(
                             jsonb_build_object('product_id', v_prod,
                                                'quantity', 2, 'unit_price', 10.00)),
      p_total_amount     => 20.00,
      p_currency         => 'ETB',
      p_note             => 'write-verification',
      p_fulfillment_mode => 'DELIVERY',
      p_delivery_address => 'Write Test Address',
      p_city             => 'Addis Ababa'
    );

    IF v_order IS NULL THEN
      RAISE EXCEPTION 'create_order_secure returned null';
    END IF;

    SELECT o.status, o.total_amount INTO v_row
    FROM public.orders o WHERE o.id = (v_order->>'id')::uuid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'create_order_secure did not persist an order row';
    END IF;

    IF v_row.status <> 'PENDING_PROVIDER' THEN
      RAISE EXCEPTION 'order created in status %, expected PENDING_PROVIDER',
        v_row.status;
    END IF;

    IF v_row.total_amount <> 20.00 THEN
      RAISE EXCEPTION 'order total is %, expected 20.00', v_row.total_amount;
    END IF;

    SELECT count(*) INTO v_count
    FROM public.order_items WHERE order_id = (v_order->>'id')::uuid;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'order has % items, expected 1', v_count;
    END IF;

    -- The acceptance was consumed: a second order from the same request
    -- must be refused (used_at is the one-acceptance-one-order rule).
    IF NOT EXISTS (
      SELECT 1 FROM public.availability_requests
       WHERE product_id = v_prod AND buyer_id = v_user
         AND used_at IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'the availability request was not consumed by the order';
    END IF;

    -- A provider who is not APPROVED must be refused -- proven by attempting
    -- the write, not by reading the function body.
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES ('00000000-0000-4000-8000-0000000000c3', v_user, 'SERVICE_PROVIDER',
            'Write Test Pending', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    BEGIN
      PERFORM public.create_order_secure(
        p_user_id          => v_user,
        p_provider_id      => '00000000-0000-4000-8000-0000000000c3',
        p_items            => jsonb_build_array(
                               jsonb_build_object('product_id', v_prod,
                                                  'quantity', 1, 'unit_price', 10.00)),
        p_total_amount     => 10.00,
        p_currency         => 'ETB',
        p_fulfillment_mode => 'DELIVERY',
        p_delivery_address => 'Write Test Address'
      );
      RAISE EXCEPTION 'a non-approved provider was allowed to take an order';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM = 'a non-approved provider was allowed to take an order' THEN
          RAISE;
        END IF;
        NULL;
    END;

    RAISE EXCEPTION '%', c_sentinel;

  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = c_sentinel THEN
        RETURN true;
      END IF;
      RAISE;
  END;
END;
$$;

COMMENT ON FUNCTION public.assert_order_creation_writes() IS
  'Places a real order as a signed-in customer inside a subtransaction that '
  'is always rolled back, asserting the order persists in PENDING_PROVIDER '
  'with its items, that the seeded ACCEPTED availability request was '
  'consumed, and that a non-approved provider is refused.';

GRANT EXECUTE ON FUNCTION public.assert_order_creation_writes()
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. The assertion Connectivity CI runs
-- ---------------------------------------------------------------------------
-- Reads the LIVE catalog, because every defect this migration answers was
-- invisible to source-level checks until the harness check was written:
-- "does create_order_secure demand the request", "is the expiry scheduled",
-- "does the uniqueness index exist" are questions only the database can
-- answer once deploys and manual edits drift from the files.

CREATE OR REPLACE FUNCTION public.assert_preorder_availability_gate_is_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order text;
  v_create text;
  v_respond text;
  v_jobs int;
  v_idx int;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_order
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_order_secure'
     AND pg_get_function_identity_arguments(p.oid) LIKE '%fulfillment_mode%';
  IF v_order IS NULL THEN
    v_bad := v_bad || ARRAY['create_order_secure (9-arg) is missing'];
  ELSE
    IF v_order NOT ILIKE '%AVAILABILITY_CONFIRMATION_REQUIRED%'
       OR v_order NOT ILIKE '%availability_requests%'
       OR v_order NOT ILIKE '%used_at%' THEN
      v_bad := v_bad || ARRAY[
        'create_order_secure no longer requires an ACCEPTED, unexpired, '
        'unused availability request per product — orders bypass the gate'];
    END IF;
    IF v_order NOT ILIKE '%PROVIDER_NOT_ACCEPTING_ORDERS%' THEN
      v_bad := v_bad || ARRAY[
        'create_order_secure lost the unapproved-provider guard'];
    END IF;
  END IF;

  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_availability_requests';
  IF v_create IS NULL THEN
    v_bad := v_bad || ARRAY['create_availability_requests is missing'];
  ELSIF v_create NOT ILIKE '%15 minutes%'
        OR v_create NOT ILIKE '%AVAILABILITY_REQUEST%' THEN
    v_bad := v_bad || ARRAY[
      'create_availability_requests no longer stamps the 15-minute window '
      'or notifies the provider'];
  END IF;

  SELECT prosrc INTO v_respond
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'respond_availability_request';
  IF v_respond IS NULL THEN
    v_bad := v_bad || ARRAY['respond_availability_request is missing'];
  ELSIF v_respond NOT ILIKE '%REQUEST_EXPIRED%'
        OR v_respond NOT ILIKE '%REQUEST_ALREADY_ANSWERED%' THEN
    v_bad := v_bad || ARRAY[
      'respond_availability_request no longer refuses a late or second '
      'answer'];
  END IF;

  SELECT count(*) INTO v_jobs
    FROM cron.job
   WHERE jobname = '5birr-availability-expiry'
     AND command LIKE '%expire_availability_requests%';
  IF v_jobs = 0 THEN
    v_bad := v_bad || ARRAY[
      'the pg_cron job 5birr-availability-expiry is not scheduled, so '
      'unanswered requests never expire'];
  END IF;

  SELECT count(*) INTO v_idx
    FROM pg_indexes
   WHERE schemaname = 'public'
     AND tablename = 'availability_requests'
     AND indexdef LIKE '%(buyer_id, product_id)%'
     AND indexdef LIKE '%PENDING%';
  IF v_idx = 0 THEN
    v_bad := v_bad || ARRAY[
      'the one-active-request-per-buyer+product index is gone, so a '
      'double-tap can stack duplicate PENDING requests'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the availability gate is not fully wired: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_preorder_availability_gate_is_wired()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_preorder_availability_gate_is_wired() IS
  'True when orders demand an ACCEPTED unexpired unused availability request, '
  'the 15-minute window and its cron job exist, the provider cannot answer '
  'twice or late, and the one-active-per-buyer+product index is in place.';
