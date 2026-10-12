-- 20261012000001 — every listing carries its own type, derived from its own
-- category, so BUY vs BOOK has something true to read
-- =============================================================================
--
-- THE REPORT (third time): "Buy vs Book button type logic is STILL not
-- working."
--
-- The button logic was never the bug. `listingActionLabel()` (in
-- lib/core/widgets/product_card.dart) and `Product.actionLabel` read
-- `products.listing_type`, which has existed since 0022a as the enum
-- ('PRODUCT','FOOD','SERVICE','ROOM','OTHER'), and a SERVICE or a ROOM is
-- BOOKED. The bug is that the COLUMN WAS NEVER TRUE for a listing created by
-- this app:
--
--   * `products.listing_type` is `NOT NULL DEFAULT 'PRODUCT'` (0022a line 70);
--   * `create_provider_product()` — the one write path a provider has — inserts
--     `(provider_id, name, description, price, category_id, quantity,
--     price_per_unit, unit, is_available, location)` and does not name
--     `listing_type` at all (20261006000008 line ~106), and the client's edit
--     path (provider_product_form_screen.dart) does not either.
--
-- So every service, room, appointment and food listing this platform has ever
-- created is stored as 'PRODUCT'. The UI then reads 'PRODUCT' and correctly
-- shows BUY. A `select id, name, listing_type from products` is the whole
-- diagnosis: the column says PRODUCT for rows whose provider picked a booking
-- category, because nothing ever wrote the value the provider chose.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
--   1. `listing_type_for_category(uuid)` — the ONE place that turns a category
--      into a listing type. It walks the category and its ancestors and applies
--      the same precedence the app already trusts for the same question in
--      lib/core/models/category_tabs.dart: ACCOMMODATION -> ROOM,
--      SERVICES -> SERVICE, FOOD -> FOOD, RETAIL/OTHER -> PRODUCT, and
--      `service_group = 'BOOKING_BASED'` -> SERVICE as the fallback for a row
--      whose marketplace_sector was never set. NULL ("this category does not
--      say") leaves the row's own value alone rather than guessing.
--   2. A BEFORE INSERT OR UPDATE OF category_id trigger on `products` that
--      stamps that value. This is what fixes the write path GOING FORWARD, and
--      it fixes it for every path at once — the RPC, a direct insert, an edit,
--      and whatever is written next year — because none of them has to remember
--      to set the column.
--   3. A backfill of the rows that are already wrong: every listing whose
--      category classifies and whose stored type disagrees is corrected in
--      place, with the before/after counts reported in the deploy log.
--   4. `assert_listing_types_are_true()` — the live report, for the
--      connectivity suite and for anyone with a SQL prompt: the counts by type,
--      the still-mismatched count (must be zero), and real example rows. That
--      is the "show me the actual data" half of the report, answered by the
--      database rather than by a claim.
--
-- Deploy: needs a Supabase deploy (function, trigger, data backfill). Until it
-- is applied the client is unchanged and degrades exactly as it does today —
-- the button reads the stored type, whatever it says.

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. The one derivation, from the category the provider actually picked
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.listing_type_for_category(p_category_id uuid)
RETURNS public.listing_type
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
  v_id uuid := p_category_id;
  v_depth int := 0;
  v_row public.categories%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Nearest classified row wins, and the walk stops at the first answer: the
  -- category the provider chose is the most specific statement about what they
  -- are selling, and a parent is consulted only when the child does not say.
  -- Five levels is deeper than any tree this schema has, and the depth guard is
  -- what stops a cycle in `parent_id` from looping forever.
  WHILE v_id IS NOT NULL AND v_depth < 5 LOOP
    SELECT * INTO v_row FROM public.categories WHERE id = v_id;
    EXIT WHEN NOT FOUND;

    IF v_row.marketplace_sector = 'ACCOMMODATION' THEN
      RETURN 'ROOM'::public.listing_type;
    END IF;
    IF v_row.marketplace_sector = 'SERVICES' THEN
      RETURN 'SERVICE'::public.listing_type;
    END IF;
    IF v_row.marketplace_sector = 'FOOD' THEN
      RETURN 'FOOD'::public.listing_type;
    END IF;
    IF v_row.marketplace_sector IN ('RETAIL', 'OTHER') THEN
      RETURN 'PRODUCT'::public.listing_type;
    END IF;
    -- The fallback, and the reason it is second rather than first: migration
    -- 20260923000004 set BOOKING_BASED on every VEHICLE row and PRODUCT_BASED
    -- on every SERVICE row, so it cannot be the primary signal (category_tabs
    -- documents the same ordering for the same reason).
    IF v_row.service_group = 'BOOKING_BASED' THEN
      RETURN 'SERVICE'::public.listing_type;
    END IF;
    IF v_row.service_group = 'PRODUCT_BASED' THEN
      RETURN 'PRODUCT'::public.listing_type;
    END IF;

    v_id := v_row.parent_id;
    v_depth := v_depth + 1;
  END LOOP;

  -- Unclassified. Deliberately NULL and not 'PRODUCT': a category that says
  -- nothing must not overwrite a type somebody else stated.
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.listing_type_for_category(uuid) IS
  'The listing_type a category implies: ACCOMMODATION -> ROOM, SERVICES -> '
  'SERVICE, FOOD -> FOOD, RETAIL/OTHER -> PRODUCT, then service_group = '
  'BOOKING_BASED -> SERVICE, walking to the parent when the row says nothing. '
  'NULL means "this category does not say" and callers leave the stored value '
  'alone. The same precedence the app uses to place a category on its home tab '
  '(lib/core/models/category_tabs.dart).';

-- ---------------------------------------------------------------------------
-- 2. The write path: a listing takes its type from its category, always
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.set_listing_type_from_category()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_type public.listing_type;
BEGIN
  IF NEW.category_id IS NULL THEN
    RETURN NEW;
  END IF;

  -- An update that does not move the listing to another category keeps the type
  -- it already has. Re-deriving on every update would also be wrong for the one
  -- case where they legitimately differ: a listing deliberately parked in a
  -- broader category.
  IF TG_OP = 'UPDATE'
     AND NEW.category_id IS NOT DISTINCT FROM OLD.category_id THEN
    RETURN NEW;
  END IF;

  v_type := public.listing_type_for_category(NEW.category_id);
  IF v_type IS NOT NULL THEN
    NEW.listing_type := v_type;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.set_listing_type_from_category() IS
  'Stamps products.listing_type from the row''s category on insert and whenever '
  'the category changes. It exists because create_provider_product() inserts '
  'without naming listing_type, so every listing created by the app took the '
  'column default of PRODUCT — which is why a service read BUY everywhere. A '
  'trigger rather than an extra function argument on purpose: it covers the '
  'edit path and every future writer with no one having to remember.';

DROP TRIGGER IF EXISTS trg_products_listing_type ON public.products;
CREATE TRIGGER trg_products_listing_type
  BEFORE INSERT OR UPDATE OF category_id ON public.products
  FOR EACH ROW EXECUTE FUNCTION public.set_listing_type_from_category();

-- ---------------------------------------------------------------------------
-- 3. The rows that are already wrong, corrected in place
-- ---------------------------------------------------------------------------
-- Only rows whose category actually classifies are touched, so a listing in an
-- unclassified category is left exactly as it is. The counts are printed here
-- because a data repair that does not say what it changed is indistinguishable
-- from one that changed nothing.

DO $$
DECLARE
  v_before text;
  v_after text;
  v_changed int := 0;
  v_remaining int := 0;
BEGIN
  SELECT string_agg(format('%s=%s', listing_type, n), ', '
                    ORDER BY listing_type)
    INTO v_before
    FROM (SELECT listing_type, count(*) AS n
            FROM public.products GROUP BY listing_type) s;

  UPDATE public.products p
     SET listing_type = public.listing_type_for_category(p.category_id)
   WHERE p.category_id IS NOT NULL
     AND public.listing_type_for_category(p.category_id) IS NOT NULL
     AND p.listing_type IS DISTINCT FROM
         public.listing_type_for_category(p.category_id);
  GET DIAGNOSTICS v_changed = ROW_COUNT;

  SELECT string_agg(format('%s=%s', listing_type, n), ', '
                    ORDER BY listing_type)
    INTO v_after
    FROM (SELECT listing_type, count(*) AS n
            FROM public.products GROUP BY listing_type) s;

  RAISE NOTICE 'listing_type backfill: % row(s) corrected; before [%]; after [%]',
    v_changed, coalesce(v_before, 'no listings'), coalesce(v_after, 'no listings');

  -- The correction has to be complete: anything left disagreeing is a row the
  -- derivation should have classified, which means the walk or the precedence
  -- is wrong — a silent miss here is the same class of bug this file fixes.
  SELECT count(*) INTO v_remaining
    FROM public.products p
   WHERE p.category_id IS NOT NULL
     AND public.listing_type_for_category(p.category_id) IS NOT NULL
     AND p.listing_type IS DISTINCT FROM
         public.listing_type_for_category(p.category_id);
  IF v_remaining > 0 THEN
    RAISE EXCEPTION
      'LISTING_TYPE_BACKFILL_INCOMPLETE: % listing(s) still disagree with their category',
      v_remaining;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4. The migration proves its own claims
-- ---------------------------------------------------------------------------
-- A column nobody writes, a trigger that fires on nothing and a backfill that
-- matched no rows all look exactly like a working deploy. So the three are
-- re-read here and the file fails loudly if any of them is not wired.

DO $$
DECLARE
  v_body text;
  v_trigger int;
  v_mismatch text;
BEGIN
  SELECT prosrc INTO v_body
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'set_listing_type_from_category';
  IF v_body IS NULL OR v_body NOT ILIKE '%NEW.listing_type%' THEN
    RAISE EXCEPTION
      'set_listing_type_from_category does not write NEW.listing_type — every '
      'listing would keep taking the PRODUCT default';
  END IF;

  SELECT count(*) INTO v_trigger
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'products'
     AND t.tgname = 'trg_products_listing_type' AND NOT t.tgisinternal;
  IF v_trigger = 0 THEN
    RAISE EXCEPTION
      'trg_products_listing_type is not on public.products — create_provider_product '
      'would go back to storing every service as a PRODUCT';
  END IF;

  SELECT prosrc INTO v_body
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'listing_type_for_category';
  IF v_body IS NULL OR v_body NOT ILIKE '%ACCOMMODATION%'
     OR v_body NOT ILIKE '%BOOKING_BASED%' THEN
    RAISE EXCEPTION
      'listing_type_for_category lost a rule (ACCOMMODATION or the '
      'BOOKING_BASED fallback) — a hotel room or a booking category would '
      'classify as nothing again';
  END IF;

  -- And the derivation has to agree with real data where that data exists: a
  -- SERVICES category must not classify as a purchase, whatever the tree looks
  -- like on this database.
  IF EXISTS (SELECT 1 FROM public.categories
              WHERE marketplace_sector = 'SERVICES') THEN
    SELECT string_agg(id::text, ', ') INTO v_mismatch
      FROM public.categories
     WHERE marketplace_sector = 'SERVICES'
       AND public.listing_type_for_category(id) <> 'SERVICE'::public.listing_type;
    IF v_mismatch IS NOT NULL THEN
      RAISE EXCEPTION
        'listing_type_for_category does not call these SERVICES categories a SERVICE: %',
        v_mismatch;
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM public.categories
              WHERE marketplace_sector = 'ACCOMMODATION') THEN
    SELECT string_agg(id::text, ', ') INTO v_mismatch
      FROM public.categories
     WHERE marketplace_sector = 'ACCOMMODATION'
       AND public.listing_type_for_category(id) <> 'ROOM'::public.listing_type;
    IF v_mismatch IS NOT NULL THEN
      RAISE EXCEPTION
        'listing_type_for_category does not call these ACCOMMODATION categories a ROOM: %',
        v_mismatch;
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. The live report: what the column actually says, row by row
-- ---------------------------------------------------------------------------
-- This is the answer to "run this and show me the actual data" that does not
-- depend on anyone having a psql session: the connectivity suite calls it and
-- prints what it returns, and a human with the SQL editor gets the same text
-- from `select public.assert_listing_types_are_true();`.
--
-- It returns 'ok: ...' or 'FAIL: ...' like every other assertion in this repo,
-- and it carries the values it measured so the log line is evidence rather than
-- a verdict.

CREATE OR REPLACE FUNCTION public.assert_listing_types_are_true()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total int;
  v_by_type text;
  v_wrong int;
  v_unclassified int;
  v_examples text;
BEGIN
  SELECT count(*) INTO v_total FROM public.products;
  IF v_total = 0 THEN
    RETURN 'ok: no listings yet, so there is no type to be wrong';
  END IF;

  SELECT string_agg(format('%s=%s', listing_type, n), ', '
                    ORDER BY listing_type)
    INTO v_by_type
    FROM (SELECT listing_type, count(*) AS n
            FROM public.products GROUP BY listing_type) s;

  -- Rows whose own category says something different from what is stored. This
  -- is the exact condition the report is about: a service stored as a PRODUCT
  -- is a service whose every card reads BUY.
  SELECT count(*) INTO v_wrong
    FROM public.products p
   WHERE p.category_id IS NOT NULL
     AND public.listing_type_for_category(p.category_id) IS NOT NULL
     AND p.listing_type IS DISTINCT FROM
         public.listing_type_for_category(p.category_id);

  -- Not a failure by itself — an unclassified category legitimately says
  -- nothing — but it is reported, because it is the population where the
  -- button falls back to BUY.
  SELECT count(*) INTO v_unclassified
    FROM public.products p
   WHERE p.category_id IS NULL
      OR public.listing_type_for_category(p.category_id) IS NULL;

  -- Real rows, not a count: the report asked for products by name and type.
  SELECT string_agg(format('%s = %s%s', name, listing_type,
                           CASE WHEN c_name IS NULL THEN '' ELSE ' [' || c_name || ']' END),
                    '; ' ORDER BY ord)
    INTO v_examples
    FROM (
      SELECT p.name, p.listing_type::text AS listing_type,
             c.name AS c_name, p.created_at AS ord
        FROM public.products p
        LEFT JOIN public.categories c ON c.id = p.category_id
       ORDER BY (p.listing_type = 'PRODUCT'::public.listing_type) DESC,
                p.created_at DESC
       LIMIT 5
    ) e;

  IF v_wrong > 0 THEN
    RETURN format(
      'FAIL: %s of %s listing(s) carry a type their own category contradicts, '
      'so a bookable listing reads BUY. by type: %s. examples: %s',
      v_wrong, v_total, v_by_type, coalesce(v_examples, 'none'));
  END IF;

  RETURN format(
    'ok: %s listing(s) by type: %s; %s with an unclassified category (those '
    'read BUY). examples: %s',
    v_total, v_by_type, v_unclassified, coalesce(v_examples, 'none'));
END;
$$;

REVOKE ALL ON FUNCTION public.assert_listing_types_are_true() FROM public;
GRANT EXECUTE ON FUNCTION public.assert_listing_types_are_true()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_listing_types_are_true() IS
  'The live BUY/BOOK diagnosis: the counts by listing_type, the number of '
  'listings whose own category contradicts the stored type (must be 0), and '
  'real example rows. Added with the listing_type trigger because the third '
  'report of "Buy vs Book still does not work" was a data question, and the '
  'only honest answer is the database''s own rows.';

notify pgrst, 'reload schema';
