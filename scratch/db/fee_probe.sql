-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Calls admin_save_category_fee() with EXACTLY the argument names and values
-- CategoryFeeSettingsScreen._save() sends, as a signed-in fee editor, and then
-- READS THE ROW BACK FROM THE TABLE.
--
-- Reading the function could not answer this; running it did, immediately and
-- with the exact SQLSTATE. Reading the row back rather than trusting the return
-- value is the point: the report is "it doesn't create the price", so what has
-- to be proven is that a row exists afterwards, not that a call returned.

\set QUIET on
\set ON_ERROR_STOP off

-- The signed-in administrator. auth.uid() reads this setting, which is how the
-- harness impersonates a role without a real session.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS 'SELECT NULLIF(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';

\set QUIET off

DO $$
DECLARE
  v_admin  constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_bajaj  uuid;
  v_rows   integer;
  v_val    numeric;
BEGIN
  -- The account owner: a staff row with is_ceo. This is what makes
  -- is_fee_editor() true, which is the screen's whole edit gate.
  INSERT INTO auth.users (id, email) VALUES (v_admin, 'owner@test');
  INSERT INTO public.staff (user_id, is_ceo, is_active)
  VALUES (v_admin, true, true);

  SELECT id INTO v_bajaj FROM public.categories WHERE name = 'Bajaj';

  -- ── CASE 1: exactly what the app sends on a first save ────────────────
  -- One price typed, the other twelve left blank, which _save() sends as JSON
  -- null ("inherit"). p_category_id and p_city first, then every fee field in
  -- the order the Dart lists them.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    PERFORM public.admin_save_category_fee(
      p_category_id                => v_bajaj,
      p_city                       => '',
      p_commission_percent         => NULL,
      p_commission_min             => NULL,
      p_subscription_fee           => NULL,
      p_activation_fee             => NULL,
      p_ride_base_fare             => NULL,
      p_ride_per_km                => 12.50,
      p_ride_minimum_fare          => NULL,
      p_booking_base_fee           => NULL,
      p_booking_per_km             => NULL,
      p_booking_minimum_fee        => NULL,
      p_product_commission_percent => NULL,
      p_product_commission_min     => NULL,
      p_product_listing_fee        => NULL
    );
    SELECT count(*) INTO v_rows FROM public.category_fee_settings;
    SELECT ride_per_km INTO v_val FROM public.category_fee_settings
     WHERE category_id = v_bajaj AND city = '';
    RAISE NOTICE 'CASE 1 first save          -> ok: % row(s) written, ride_per_km=%',
      v_rows, v_val;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'CASE 1 first save          -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── CASE 2: the same save with a city, and a SECOND save of the same ────
  -- (category, city) so the ON CONFLICT branch -- the branch that was broken --
  -- actually runs rather than being skipped because the pair is new.
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    PERFORM public.admin_save_category_fee(
      p_category_id                => v_bajaj,
      p_city                       => 'hawassa',
      p_commission_percent         => 10,
      p_commission_min             => 5,
      p_subscription_fee           => 300,
      p_activation_fee             => 500,
      p_ride_base_fare             => 40,
      p_ride_per_km                => 15,
      p_ride_minimum_fare          => 60,
      p_booking_base_fee           => NULL,
      p_booking_per_km             => NULL,
      p_booking_minimum_fee        => NULL,
      p_product_commission_percent => NULL,
      p_product_commission_min     => NULL,
      p_product_listing_fee        => NULL
    );
    SELECT count(*) INTO v_rows FROM public.category_fee_settings;
    RAISE NOTICE 'CASE 2 city save (hawassa) -> ok: % row(s) total', v_rows;

    PERFORM public.admin_save_category_fee(
      p_category_id                => v_bajaj,
      p_city                       => 'hawassa',
      p_commission_percent         => 12,   -- the value an admin EDITS next
      p_commission_min             => NULL,
      p_subscription_fee           => NULL,
      p_activation_fee             => NULL,
      p_ride_base_fare             => NULL,
      p_ride_per_km                => NULL,
      p_ride_minimum_fare          => NULL,
      p_booking_base_fee           => NULL,
      p_booking_per_km             => NULL,
      p_booking_minimum_fee        => NULL,
      p_product_commission_percent => NULL,
      p_product_commission_min     => NULL,
      p_product_listing_fee        => NULL
    );
    SELECT count(*) INTO v_rows FROM public.category_fee_settings;
    SELECT commission_percent INTO v_val FROM public.category_fee_settings
     WHERE category_id = v_bajaj AND city = 'hawassa';
    RAISE NOTICE 'CASE 2b EDIT the same pair   -> ok: % row(s) total, commission now %',
      v_rows, v_val;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'CASE 2b EDIT the same pair   -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── CASE 3: a category id that is not in `categories` ─────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    PERFORM public.admin_save_category_fee(
      p_category_id                => '00000000-0000-4000-8000-00000000dead',
      p_city                       => '',
      p_commission_percent         => NULL, p_commission_min => NULL,
      p_subscription_fee => NULL, p_activation_fee => NULL,
      p_ride_base_fare => NULL, p_ride_per_km => 10, p_ride_minimum_fare => NULL,
      p_booking_base_fee => NULL, p_booking_per_km => NULL, p_booking_minimum_fee => NULL,
      p_product_commission_percent => NULL, p_product_commission_min => NULL,
      p_product_listing_fee => NULL
    );
    RAISE NOTICE 'CASE 3 unknown category    -> ok (unexpected)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'CASE 3 unknown category    -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── CASE 4: a capitalised city, which must be NORMALISED not refused ──
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    PERFORM public.admin_save_category_fee(
      p_category_id                => v_bajaj,
      p_city                       => 'Addis Ababa',   -- capitalised, not lowercased
      p_commission_percent         => NULL, p_commission_min => NULL,
      p_subscription_fee => NULL, p_activation_fee => NULL,
      p_ride_base_fare => NULL, p_ride_per_km => 20, p_ride_minimum_fare => NULL,
      p_booking_base_fee => NULL, p_booking_per_km => NULL, p_booking_minimum_fee => NULL,
      p_product_commission_percent => NULL, p_product_commission_min => NULL,
      p_product_listing_fee => NULL
    );
    -- v_city is lower(btrim(p_city)) BEFORE the shape test, so this is
    -- accepted and stored lowercase. The Dart picker lowercases too, so the
    -- two agree; this case exists to pin that they must keep agreeing.
    SELECT count(*) INTO v_rows FROM public.category_fee_settings WHERE city = 'addis ababa';
    RAISE NOTICE 'CASE 4 capitalised city    -> ok, % row normalised to lowercase', v_rows;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'CASE 4 capitalised city    -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── CASE 5: a staff member who is not the owner ───────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000b2', false);
    PERFORM public.admin_save_category_fee(
      p_category_id                => v_bajaj,
      p_city                       => '',
      p_commission_percent         => NULL, p_commission_min => NULL,
      p_subscription_fee => NULL, p_activation_fee => NULL,
      p_ride_base_fare => NULL, p_ride_per_km => 99, p_ride_minimum_fare => NULL,
      p_booking_base_fee => NULL, p_booking_per_km => NULL, p_booking_minimum_fee => NULL,
      p_product_commission_percent => NULL, p_product_commission_min => NULL,
      p_product_listing_fee => NULL
    );
    RAISE NOTICE 'CASE 5 non-owner save      -> ok (unexpected!)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'CASE 5 non-owner save      -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── CASE 6: is_fee_editor() as each role sees it ──────────────────────
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
  RAISE NOTICE 'CASE 6 is_fee_editor(ceo)   -> %', public.is_fee_editor();
  PERFORM set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000b2', false);
  RAISE NOTICE 'CASE 6 is_fee_editor(staff) -> %', public.is_fee_editor();
END;
$$;