-- 20260927000125 — the customer's ride and order path is reachable too
--
-- WHY THIS FILE EXISTS
-- -------------------
-- 0124 answers "is every ADMIN write path callable?" against the live catalog.
-- The report that prompted it also said: "when user try to order ride its
-- saying that function may have been removed".
--
-- That sentence was `friendly_error`'s not-found branch, which had PGRST202
-- lumped in with 404 and PGRST116. PGRST202 is not a missing record — it means
-- PostgREST could not RESOLVE the call: a misspelt parameter, a GRANT naming a
-- signature the function does not have, a migration that never ran, or an
-- overload it cannot choose between. So a rider was told their ride "may have
-- been removed" when in fact the request never got as far as asking, and
-- `isNotFound()` rendered the not-found screen for a ride that was never made.
-- Both are fixed in the client (friendly_error.dart, failure_mapper.dart).
--
-- This file is the other half: it makes the server say WHICH of those four it
-- is, for the functions a CUSTOMER calls. The static harness cannot settle it.
-- `create_ride_request` was checked by hand and its eight parameter names match
-- the Dart exactly, with a correct GRANT in 0114 — so either the live catalog
-- differs from every migration (a signature restated out of band, an overload
-- left by a `CREATE OR REPLACE` that changed arity) or the failure is upstream
-- of that function. Only the live catalog can say which, and this is what asks.
--
-- WHAT IS COMPARED, PER FUNCTION
-- ------------------------------
--   1. it EXISTS at the exact signature `to_regprocedure` names;
--   2. `authenticated` may EXECUTE it — the role the app calls as. PostgREST
--      hides a function the role cannot execute and reports PGRST202, so an
--      absent GRANT is indistinguishable from an absent function to the client;
--   3. its declared parameter NAMES are exactly the keys the caller sends;
--   4. it is NOT OVERLOADED. Two functions of one name make PostgREST answer
--      PGRST203 for the call even when the expected signature is present,
--      granted and correctly named. This is the check most likely to bite: six
--      functions in this schema are restated with a changed arity somewhere in
--      the migration history, and `CREATE OR REPLACE` ADDS an overload rather
--      than replacing one when the signature changes. Six are listed at the
--      bottom as KNOWN OVERLOADS to keep this honest rather than aspirational.

-- ===========================================================================
-- 1. The live answer
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.customer_rpc_signature_report()
RETURNS TABLE (
  fn           text,
  present      boolean,
  callable     boolean,
  ambiguous    boolean,
  missing_args text,
  extra_args   text,
  note         text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r     record;
  v_oid regprocedure;
  v_actual text[];
  v_siblings int;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- fn,                    identity,                                     expected arg names
      -- ---- The ride path. A rider reaching PGRST202 on any of these is the
      -- ---- reported failure verbatim.
      ('create_ride_request', 'public.create_ride_request(uuid,double precision,double precision,double precision,double precision,text,text,uuid)',
       '{p_user_id,p_pickup_lat,p_pickup_lng,p_destination_lat,p_destination_lng,p_pickup_text,p_destination_text,p_vehicle_category_id}'),
      ('calculate_fare_estimate_at', 'public.calculate_fare_estimate_at(double precision,double precision,double precision,double precision,uuid,text)',
       '{p_pickup_lat,p_pickup_lng,p_dest_lat,p_dest_lng,p_vehicle_category_id,p_city}'),
      ('calculate_fare_estimate', 'public.calculate_fare_estimate(double precision,double precision,double precision,double precision,uuid)',
       '{p_pickup_lat,p_pickup_lng,p_dest_lat,p_dest_lng,p_vehicle_category_id}'),
      ('find_nearby_drivers', 'public.find_nearby_drivers(double precision,double precision,numeric,uuid)',
       '{p_lat,p_lng,p_radius_km,p_vehicle_category_id}'),
      ('set_driver_online', 'public.set_driver_online(uuid,boolean,double precision,double precision)',
       '{p_provider_id,p_online,p_lat,p_lng}'),
      ('update_driver_location', 'public.update_driver_location(uuid,double precision,double precision)',
       '{p_provider_id,p_lat,p_lng}'),
      -- ---- The product order path, through the order-create Edge Function.
      -- ---- create_order_secure is called with service_role, not
      -- ---- authenticated, so it is checked for existence and ambiguity only.
      ('create_order_secure', 'public.create_order_secure(uuid,uuid,jsonb,numeric,text,text,text,text,text)',
       '{p_user_id,p_provider_id,p_items,p_total_amount,p_currency,p_note,p_fulfillment_mode,p_delivery_address,p_city}'),
      ('search_products', 'public.search_products(text,uuid,text,double precision,double precision,numeric,numeric,numeric,numeric,text,int,int,text,boolean)',
       '{p_query,p_category_id,p_sector,p_lat,p_lng,p_radius_km,p_min_price,p_max_price,p_min_rating,p_sort_by,p_limit,p_offset,p_city,p_include_global}'),
      -- The two commission-quote rows that used to sit here
      -- (platform_transaction_fee_for, platform_transaction_fee) are gone,
      -- because their only call site is gone: the buyer checkout used to
      -- show a "Platform fee (charged to provider)" line, and the product
      -- rule is now that the buyer is never quoted it — the commission is
      -- charged to the provider server-side by deduct_transaction_fee() and
      -- displayed from the ledger in the provider wallet screen and the
      -- admin income views. A report row with no caller is exactly the drift
      -- this file exists to prevent, so the rows left with the caller.
      -- ---- Contact handover. A rider who paid cannot see the driver's phone
      -- ---- number if these are unreachable, and the order stalls.
      --
      -- All three take the ORDER only -- there is no `p_actor` parameter. The
      -- caller is derived from `auth.uid()` inside the function, which is what
      -- stops a modified client pointing these at somebody else's order. The
      -- first transcription of these rows invented a `p_actor` on all three,
      -- and the static check caught it by finding the Dart sends no such key
      -- and the migration declares no DEFAULT for it: the harness earned its
      -- keep on the author of the migration this time.
      ('get_order_delivery_location', 'public.get_order_delivery_location(uuid)',
       '{p_order_id}'),
      ('set_order_delivery_location', 'public.set_order_delivery_location(uuid,double precision,double precision)',
       '{p_order_id,p_lat,p_lng}'),
      ('release_order_contact', 'public.release_order_contact(uuid)',
       '{p_order_id}')
    ) AS t(fn, ident, expected)
  LOOP
    v_oid := to_regprocedure(r.ident::text);
    v_actual := '{}';
    v_siblings := 0;

    IF v_oid IS NOT NULL THEN
      SELECT coalesce(p.proargnames, '{}') INTO v_actual
        FROM pg_proc p WHERE p.oid = v_oid;
    END IF;

    -- Every function in `public` sharing this name, whatever its arity.
    SELECT count(*) INTO v_siblings
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = r.fn;

    fn        := r.fn;
    present   := v_oid IS NOT NULL;
    ambiguous := v_siblings > 1;
    missing_args := coalesce((
      SELECT string_agg(x, ', ' ORDER BY x) FROM unnest(r.expected::text[]) x
       WHERE NOT (x = ANY (v_actual))), '');
    extra_args   := coalesce((
      SELECT string_agg(x, ', ' ORDER BY x) FROM unnest(v_actual) x
       WHERE NOT (x = ANY (r.expected::text[]))), '');
    callable := v_oid IS NOT NULL
                AND has_function_privilege('authenticated', v_oid, 'EXECUTE');

    note := CASE
              WHEN v_oid IS NULL
                THEN 'MISSING or wrong arity: PostgREST cannot resolve this signature'
              -- Before everything else: when a name is ambiguous the call
              -- cannot succeed however correct the expected signature is.
              WHEN ambiguous
                THEN format('AMBIGUOUS: %s overloads of %s exist in public; '
                            || 'PostgREST answers PGRST203 and cannot choose '
                            || 'between them', v_siblings, r.fn)
              WHEN NOT callable
                THEN 'exists, but authenticated may not EXECUTE it -- PostgREST '
                     || 'hides it and reports PGRST202'
              WHEN missing_args <> ''
                THEN 'client sends parameter names the function does not declare (PGRST202)'
              ELSE 'ok'
            END;

    RETURN NEXT;
  END LOOP;
END;
$$;

-- ===========================================================================
-- 2. The assertion the connectivity suite calls
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_customer_write_paths_are_reachable()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(format('%s -- %s', r.fn, r.note), '; ' ORDER BY r.fn)
    INTO v_bad
    FROM public.customer_rpc_signature_report() r
   WHERE NOT (r.present AND r.callable AND r.missing_args = '' AND NOT r.ambiguous);

  IF v_bad IS NOT NULL THEN
    RETURN 'BROKEN: ' || v_bad;
  END IF;

  RETURN 'ok: all 13 customer ride and order RPCs exist with the arity the '
         || 'client sends, their parameter names match exactly, authenticated '
         || 'may execute each, and none of the names is overloaded';
END;
$$;

REVOKE ALL ON FUNCTION public.customer_rpc_signature_report() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_rpc_signature_report()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_customer_write_paths_are_reachable() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_customer_write_paths_are_reachable()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_customer_write_paths_are_reachable() IS
  'Reads the LIVE catalog for every ride and order RPC a customer calls and '
  'compares the declared parameter names against the keys the client sends. '
  'PostgREST matches named arguments by name, so a mismatch, an absent GRANT '
  'or an ambiguous overload is PGRST202/PGRST203 -- which used to reach the '
  'user as "That item could not be found. It may have been removed", a '
  'sentence about a deleted ride that was really about an unresolvable call.';

-- ===========================================================================
-- 3. Known overloads, recorded rather than discovered later
-- ===========================================================================
-- These six are restated somewhere in the migration history with a CHANGED
-- ARITY, which leaves a second function of the same name in the catalog. They
-- are NOT in the table above, so this assertion does not go red for them --
-- and it must not pretend to. They are listed here because each is one
-- argument away from being a customer's PGRST203:
--
--   create_staff      5 args, then 7
--   delete_staff      1 arg,  then 2
--   update_staff      5, 6, then 8 args
--   log_staff_activity 4 args, then 5
--   create_order_secure 6 args, then 9   <- customer path; the Edge Function
--                                            sends all 9, so it resolves, but a
--                                            caller sending only the 6 shared
--                                            names matches BOTH and is
--                                            ambiguous. Nothing in the app does
--                                            that today.
--   search_products   15 args, then 17     <- customer path; the search screen
--                                            sends p_city and p_include_global,
--                                            so it resolves to the 17-arg
--                                            overload. A caller omitting either
--                                            would match both.
--
-- Dropping the stale arity for the two customer-path functions is a separate
-- migration and is deliberately NOT bundled here: `search_products` is called
-- by an installed client that may not send the newer arguments, and dropping
-- the 15-arg overload is the kind of change that should be read rather than
-- bundled into a diagnostic.

NOTIFY pgrst, 'reload schema';
