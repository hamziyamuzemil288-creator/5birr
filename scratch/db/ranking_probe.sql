-- LOCAL PROBE -- not a migration, never deployed.
--
-- Executes 0128's paths against scratch/db/ranking_pre.sql. Every case either
-- prints `-> ok` or raises, so a silent wrong answer is impossible: the probe
-- is run with ON_ERROR_STOP=1 and the replay exits non-zero on the first raise.
DO $$
DECLARE
  v_rows integer;
  v_first text;
  v_second text;
  v_third text;
  v_count integer;
  v_price numeric;
  v_text text;
  v_pending_in_list integer;
  v_top_category text;
  v_effective integer;
  v_inactive_present integer;
  v_outcome text;
  v_raised text;
  v_claim uuid;
BEGIN
  -- ---------------------------------------------------------------- seed --
  SELECT count(*) INTO v_rows
  FROM public.category_profile_fields f
  JOIN public.categories c ON c.id = f.category_id
  WHERE c.slug = 'hotels-lodging' AND f.is_active;
  IF v_rows = 4 THEN
    RAISE NOTICE 'RANK 1 accommodation seeded  -> ok (4 fields: %)',
      (SELECT string_agg(f.field_key, ',' ORDER BY f.sort_order)
         FROM public.category_profile_fields f
         JOIN public.categories c ON c.id = f.category_id
        WHERE c.slug = 'hotels-lodging');
  ELSE
    RAISE EXCEPTION 'RANK 1 accommodation seeded -> FAILED, got % field(s)', v_rows;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.category_profile_fields f
    JOIN public.categories c ON c.id = f.category_id
    WHERE c.slug = 'hotels-lodging'
      AND f.field_key = 'price_per_night'
      AND f.is_price AND f.is_required AND f.input_type = 'PRICE')
  THEN
    RAISE NOTICE 'RANK 2 nightly price is a required PRICE -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 2 nightly price is a required PRICE -> FAILED: the seed lost its '
      'type, its price flag or its requiredness';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.category_profile_fields f
    JOIN public.categories c ON c.id = f.category_id
    WHERE c.slug = 'health' AND f.field_key = 'price_per_hour')
  THEN
    RAISE NOTICE 'RANK 3 health has a price-per-hour field -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 3 health has a price-per-hour field -> FAILED: the doctor case in '
      'the report has no hourly price to fill in';
  END IF;

  -- The subcategory inherits. `hostels` is a child of `hotels-lodging` and is
  -- deliberately NOT seeded; without the parent walk it would ask nothing.
  SELECT count(*) INTO v_effective
  FROM public.provider_effective_profile_fields(
      '00000000-0000-4000-8000-00000000c002');
  IF v_effective = 4 THEN
    RAISE NOTICE 'RANK 4 subcategory inherits its parent -> ok (4 fields)';
  ELSE
    RAISE EXCEPTION
      'RANK 4 subcategory inherits its parent -> FAILED, got % field(s). A '
      'provider who picked Hostels is asked nothing', v_effective;
  END IF;

  -- ------------------------------------------------------------ ordering --
  SELECT count(*) INTO v_count FROM public.ranked_providers(NULL, NULL, 50, 0);
  IF v_count = 3 THEN
    RAISE NOTICE 'RANK 5 only approved providers are ranked -> ok (3 of 4)';
  ELSE
    RAISE EXCEPTION
      'RANK 5 only approved providers are ranked -> FAILED, got % rows',
      v_count;
  END IF;

  SELECT id::text INTO v_first  FROM public.ranked_providers(NULL, NULL, 1, 0);
  SELECT id::text INTO v_second FROM public.ranked_providers(NULL, NULL, 1, 1);
  SELECT id::text INTO v_third  FROM public.ranked_providers(NULL, NULL, 1, 2);

  IF v_first = '00000000-0000-4000-8000-0000000000a1' THEN
    RAISE NOTICE 'RANK 6 most transacted is first -> ok (Busy Diner, 3 orders)';
  ELSE
    RAISE EXCEPTION
      'RANK 6 most transacted is first -> FAILED, first is %', v_first;
  END IF;

  IF v_second = '00000000-0000-4000-8000-0000000000a2' THEN
    RAISE NOTICE 'RANK 7 a completed RIDE counts too -> ok (Steady Fleet, '
      '2 orders + 1 ride)';
  ELSE
    RAISE EXCEPTION
      'RANK 7 a completed RIDE counts too -> FAILED, second is %', v_second;
  END IF;

  -- The inversion this migration exists for: the newest signup is LAST.
  IF v_third = '00000000-0000-4000-8000-0000000000a3' THEN
    RAISE NOTICE 'RANK 8 the newest signup is last -> ok (Brand New Inn)';
  ELSE
    RAISE EXCEPTION
      'RANK 8 the newest signup is last -> FAILED, third is %', v_third;
  END IF;

  -- The count itself, read off the row rather than inferred from the order.
  SELECT completed_transactions INTO v_count
  FROM public.ranked_providers(NULL, NULL, 1, 0);
  IF v_count = 3 THEN
    RAISE NOTICE 'RANK 9 the published count is the real count -> ok (3)';
  ELSE
    RAISE EXCEPTION
      'RANK 9 the published count is the real count -> FAILED, got %', v_count;
  END IF;

  -- A pending provider must be absent, not merely last.
  SELECT count(*) INTO v_pending_in_list
  FROM public.ranked_providers(NULL, NULL, 500, 0)
  WHERE id = '00000000-0000-4000-8000-0000000000a4';
  IF v_pending_in_list = 0 THEN
    RAISE NOTICE 'RANK 10 a pending provider is not listed -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 10 a pending provider is not listed -> FAILED: an unapproved '
      'business is on the public board';
  END IF;

  -- A cancelled order and a cancelled ride are not transactions.
  SELECT completed_transactions INTO v_count
  FROM public.provider_transaction_stats()
  WHERE provider_id = '00000000-0000-4000-8000-0000000000a2';
  IF v_count = 3 THEN
    RAISE NOTICE 'RANK 11 cancelled work does not count -> ok (3 of 5 rows)';
  ELSE
    RAISE EXCEPTION
      'RANK 11 cancelled work does not count -> FAILED, got %', v_count;
  END IF;

  -- Category filter is honoured, not ignored.
  SELECT count(*) INTO v_count
  FROM public.ranked_providers('00000000-0000-4000-8000-00000000c004', NULL, 50, 0);
  IF v_count = 1 THEN
    RAISE NOTICE 'RANK 12 the category filter narrows -> ok (1 in Transport)';
  ELSE
    RAISE EXCEPTION
      'RANK 12 the category filter narrows -> FAILED, got %', v_count;
  END IF;

  -- ------------------------------------------------------------ categories --
  SELECT name INTO v_top_category FROM public.ranked_categories(50, 0);
  IF v_top_category = 'Health' THEN
    RAISE NOTICE
      'RANK 13 categories rank by work -> ok (Health: 3 orders + 25 sales)';
  ELSE
    RAISE EXCEPTION
      'RANK 13 categories rank by work -> FAILED, top is %', v_top_category;
  END IF;

  SELECT count(*) INTO v_inactive_present
  FROM public.ranked_categories(500, 0)
  WHERE name = 'Retired Trade';
  IF v_inactive_present = 0 THEN
    RAISE NOTICE 'RANK 14 an inactive category is not ranked -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 14 an inactive category is not ranked -> FAILED: a retired '
      'category is still on the board';
  END IF;

  -- ---------------------------------------------------------- the save path --
  PERFORM set_config('test.uid', '00000000-0000-4000-8000-0000000000e1', false);

  SELECT count(*) INTO v_count FROM public.provider_profile_fields();
  IF v_count = 4 THEN
    RAISE NOTICE 'RANK 15 the provider sees their own trade''s form -> ok '
      '(Busy Diner is in Health, 4 SERVICES fields)';
  ELSE
    RAISE EXCEPTION
      'RANK 15 the provider sees their own trade''s form -> FAILED, got %',
      v_count;
  END IF;

  -- A number that arrives as text is stored as a NUMBER, in value_number.
  PERFORM public.save_provider_profile_field('price_per_hour', '500');
  SELECT value_number INTO v_price
  FROM public.provider_profile_field_values
  WHERE provider_id = '00000000-0000-4000-8000-0000000000a1'
    AND field_key = 'price_per_hour';
  IF v_price = 500 THEN
    RAISE NOTICE 'RANK 16 a PRICE saves into value_number -> ok (500)';
  ELSE
    RAISE EXCEPTION
      'RANK 16 a PRICE saves into value_number -> FAILED, got %', v_price;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.provider_profile_field_values
    WHERE provider_id = '00000000-0000-4000-8000-0000000000a1'
      AND field_key = 'price_per_hour'
      AND value_text IS NULL)
  THEN
    RAISE NOTICE 'RANK 17 the text column is left empty -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 17 the text column is left empty -> FAILED: a price is in both '
      'columns, so two renderers can read it two ways';
  END IF;

  -- Overwriting is an update, not a second row.
  PERFORM public.save_provider_profile_field('price_per_hour', '750');
  SELECT count(*) INTO v_count
  FROM public.provider_profile_field_values
  WHERE provider_id = '00000000-0000-4000-8000-0000000000a1'
    AND field_key = 'price_per_hour';
  IF v_count = 1 THEN
    RAISE NOTICE 'RANK 18 a second save updates in place -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 18 a second save updates in place -> FAILED, % rows', v_count;
  END IF;

  v_raised := '';
  BEGIN
    PERFORM public.save_provider_profile_field('price_per_hour', 'about 500');
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM;
  END;
  IF v_raised LIKE '%THAT_FIELD_EXPECTS_A_NUMBER%' THEN
    RAISE NOTICE 'RANK 19 "about 500" is refused -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 19 "about 500" is refused -> FAILED (raised %)', v_raised;
  END IF;

  -- The required SERVICES field, left empty.
  v_raised := '';
  BEGIN
    PERFORM public.save_provider_profile_field('services_offered');
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM;
  END;
  IF v_raised LIKE '%THIS_FIELD_IS_REQUIRED%' THEN
    RAISE NOTICE 'RANK 20 a required field cannot be blank -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 20 a required field cannot be blank -> FAILED (raised %)', v_raised;
  END IF;

  -- A field that belongs to a DIFFERENT trade. This is the guard that stops a
  -- value nothing renders from being stored.
  v_raised := '';
  BEGIN
    PERFORM public.save_provider_profile_field('room_types', 'Single');
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM;
  END;
  IF v_raised LIKE '%THAT_FIELD_IS_NOT_PART_OF_YOUR_CATEGORY%' THEN
    RAISE NOTICE 'RANK 21 another trade''s field is refused -> ok '
      '(a doctor cannot set "room types")';
  ELSE
    RAISE EXCEPTION
      'RANK 21 another trade''s field is refused -> FAILED (raised %)', v_raised;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profile_field_values
    WHERE field_key = 'room_types')
  THEN
    RAISE NOTICE 'RANK 22 the refused value left no row behind -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 22 the refused value left no row behind -> FAILED';
  END IF;

  -- The public reader shows what the provider declared, and nothing else.
  SELECT count(*) INTO v_count
  FROM public.provider_public_profile_fields(
      '00000000-0000-4000-8000-0000000000a1');
  IF v_count = 1 THEN
    RAISE NOTICE 'RANK 23 the customer sees the declared value -> ok '
      '(1 answered field)';
  ELSE
    RAISE EXCEPTION
      'RANK 23 the customer sees the declared value -> FAILED, got %', v_count;
  END IF;

  -- ... and shows an UNAPPROVED provider's nothing.
  SELECT count(*) INTO v_count
  FROM public.provider_public_profile_fields(
      '00000000-0000-4000-8000-0000000000a4');
  IF v_count = 0 THEN
    RAISE NOTICE 'RANK 24 an unapproved provider declares nothing -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 24 an unapproved provider declares nothing -> FAILED, got %',
      v_count;
  END IF;

  -- ------------------------------------------------------ the signup claim --
  v_raised := '';
  BEGIN
    PERFORM public.provider_claim_category('00000000-0000-4000-8000-00000000c004');
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM;
  END;
  IF v_raised LIKE '%THAT_IS_NOT_A_SERVICE_CATEGORY%' THEN
    RAISE NOTICE 'RANK 25 a service provider cannot claim a vehicle trade -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 25 a service provider cannot claim a vehicle trade -> FAILED '
      '(raised %)', v_raised;
  END IF;

  v_claim := public.provider_claim_category('00000000-0000-4000-8000-00000000c002');
  IF v_claim = '00000000-0000-4000-8000-00000000c002' THEN
    RAISE NOTICE 'RANK 26 their own sector''s category is claimed -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 26 their own sector''s category is claimed -> FAILED';
  END IF;

  -- The claim is what selects the form: they moved to Hostels, so they are now
  -- asked the ACCOMMODATION fields, inherited from the parent.
  SELECT count(*) INTO v_count FROM public.provider_profile_fields();
  IF v_count = 4 THEN
    RAISE NOTICE 'RANK 27 the claimed category selects the form -> ok '
      '(Hostels now asks 4 fields, inherited)';
  ELSE
    RAISE EXCEPTION
      'RANK 27 the claimed category selects the form -> FAILED, got %', v_count;
  END IF;

  -- ------------------------------------------------------------ the admin --
  v_raised := '';
  BEGIN
    PERFORM public.admin_save_category_profile_field(
      '00000000-0000-4000-8000-00000000c003', 'consultation_fee',
      'Consultation fee', 'PRICE', 'ETB', 'Per visit', false, true, 50, true);
  EXCEPTION WHEN OTHERS THEN
    v_raised := SQLERRM;
  END;
  IF v_raised LIKE '%ADMIN_ONLY%' THEN
    RAISE NOTICE 'RANK 28 a non-admin cannot edit the catalogue -> ok';
  ELSE
    RAISE EXCEPTION
      'RANK 28 a non-admin cannot edit the catalogue -> FAILED (raised %)',
      v_raised;
  END IF;

  PERFORM set_config('test.admin', 'true', false);

  PERFORM public.admin_save_category_profile_field(
    '00000000-0000-4000-8000-00000000c003', 'consultation_fee',
    'Consultation fee', 'PRICE', 'ETB', 'Per visit', false, true, 50, true);

  IF EXISTS (
    SELECT 1 FROM public.category_profile_fields
    WHERE field_key = 'consultation_fee' AND is_price AND input_type = 'PRICE')
  THEN
    RAISE NOTICE 'RANK 29 an admin can add a field -> ok';
  ELSE
    RAISE EXCEPTION 'RANK 29 an admin can add a field -> FAILED';
  END IF;

  SELECT count(*) INTO v_count FROM public.admin_category_profile_fields();
  IF v_count = (SELECT count(*) FROM public.category_profile_fields) THEN
    RAISE NOTICE 'RANK 30 the admin list does not multiply rows -> ok (%
      row(s))', v_count;
  ELSE
    RAISE EXCEPTION
      'RANK 30 the admin list does not multiply rows -> FAILED: % rows for % '
      'definitions', v_count, (SELECT count(*) FROM public.category_profile_fields);
  END IF;

  -- A duplicate key is an UPDATE of the same field, not a second definition.
  PERFORM public.admin_save_category_profile_field(
    '00000000-0000-4000-8000-00000000c003', 'consultation_fee',
    'Consultation fee (edited)', 'PRICE', 'ETB', NULL, true, true, 5, true);
  SELECT count(*) INTO v_count FROM public.category_profile_fields
   WHERE field_key = 'consultation_fee';
  IF v_count = 1 THEN
    RAISE NOTICE 'RANK 31 re-saving a field updates it -> ok';
  ELSE
    RAISE EXCEPTION 'RANK 31 re-saving a field updates it -> FAILED, % rows',
      v_count;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.category_profile_fields
    WHERE field_key = 'consultation_fee'
      AND label = 'Consultation fee (edited)' AND is_required AND sort_order = 5)
  THEN
    RAISE NOTICE 'RANK 32 the edit actually landed -> ok';
  ELSE
    RAISE EXCEPTION 'RANK 32 the edit actually landed -> FAILED';
  END IF;

  PERFORM public.admin_delete_category_profile_field(
    (SELECT id FROM public.category_profile_fields WHERE field_key = 'consultation_fee'));
  IF NOT EXISTS (
    SELECT 1 FROM public.category_profile_fields WHERE field_key = 'consultation_fee')
  THEN
    RAISE NOTICE 'RANK 33 an admin can delete a field -> ok';
  ELSE
    RAISE EXCEPTION 'RANK 33 an admin can delete a field -> FAILED';
  END IF;

  -- ------------------------------------------------- the anonymous refusal --
  PERFORM set_config('test.uid', '', false);
  v_outcome := public.save_provider_value_outcome();
  IF v_outcome <> 'ACCEPTED' THEN
    RAISE NOTICE 'RANK 34 a caller with no provider profile cannot write -> ok (%)
      ', v_outcome;
  ELSE
    RAISE EXCEPTION
      'RANK 34 a caller with no provider profile cannot write -> FAILED: the '
      'value was stored';
  END IF;

  -- ------------------------------------------------------------- reports --
  v_text := public.ranking_wiring_report();
  IF v_text LIKE 'ok:%' THEN
    RAISE NOTICE 'RANK RPT %', v_text;
  ELSE
    RAISE EXCEPTION 'RANK RPT ranking wiring -> %', v_text;
  END IF;

  v_text := public.category_field_wiring_report();
  IF v_text LIKE 'ok:%' THEN
    RAISE NOTICE 'RANK RPT %', v_text;
  ELSE
    RAISE EXCEPTION 'RANK RPT category fields -> %', v_text;
  END IF;

  IF (public.assert_ranking_and_category_fields() ->> 'ok') = 'true' THEN
    RAISE NOTICE 'RANK RPT assert_ranking_and_category_fields -> %',
      public.assert_ranking_and_category_fields();
  ELSE
    RAISE EXCEPTION 'RANK RPT assert_ranking_and_category_fields -> %',
      public.assert_ranking_and_category_fields();
  END IF;
END;
$$;
