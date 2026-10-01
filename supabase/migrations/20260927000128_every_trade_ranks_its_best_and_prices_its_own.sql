-- Two half-built promises, both reported by the founder.
--
--   1. "build the remaining trending and most transact providers profile to
--      appear at top and that logic will work for categories also and
--      everywhere from the best to the least it will go"
--
--   2. "providers must be asked their specific category from signup gate and
--      their settings / price setting system must match their section ...
--      a hotel provider has room-type sections because they have different
--      types of products ... a home care doctor has a price-per-hour section
--      ... wire the root in every section from admin to end user"
--
-- ===========================================================================
-- 1. NOTHING WAS RANKED. THIS IS WHY.
-- ===========================================================================
-- `products.sales_count` exists and the home feed orders by it, but no screen
-- orders PROVIDERS by anything. The provider rail orders by `created_at DESC`
-- -- the newest signup, not the busiest -- and the "All providers" sheet
-- orders by `business_name`. So a provider who has taken a hundred jobs sits
-- exactly where a provider who signed up yesterday does.
--
-- The count it needs has never been computed anywhere. It is not a column; it
-- is the join of two tables that are not related in the schema:
--
--   * `orders.provider_id` + `orders.status = 'COMPLETED'`
--   * `ride_requests.claimed_by_provider_id` + `ride_requests.status =
--     'COMPLETED'`
--
-- A SERVICE provider's completed work is in the first; a VEHICLE provider's is
-- in the second. Counting either one alone ranks half the marketplace at zero.
-- `provider_transaction_stats()` is that count, in one place, so the rail, the
-- sheet, the category screen and the category ordering cannot disagree about
-- what "most transacted" means.
--
-- Categories are ranked by the same count: the transactions of their providers
-- plus the recorded sales of the products filed under them. A category with no
-- provider and no sale is last, and the ordering is total (a stable tiebreak on
-- the name), because an ordering the client re-derives is an ordering two
-- screens can implement differently.
--
-- ===========================================================================
-- 2. THE PROVIDER FORM WAS ONE FORM FOR 118 TRADES
-- ===========================================================================
-- `provider_profiles` has one `price_range` text column, and every provider
-- edits the same five fields on the Business Profile screen regardless of what
-- they sell. A hotel needs room types and a nightly rate; a doctor needs an
-- hourly consultation price and the services offered; a restaurant needs a
-- delivery fee.
--
-- `category_profile_fields` is the admin-owned definition of what a given
-- category's provider should be asked -- field key, label, input type, unit,
-- whether it is required, and, for a price field, that it IS a price. The
-- default field sets are SEEDED per marketplace sector so the screen is useful
-- on the day it ships rather than empty for all 118 categories, and an
-- administrator can edit any of them from the sidebar.
--
-- `provider_profile_field_values` holds the answers, keyed by `field_key`
-- rather than by a foreign key to the definition on purpose: an administrator
-- who renames a label, changes an input type or deletes a field must not
-- orphan or silently re-type the answers providers already gave.

-- ===========================================================================
-- 3. The transaction count
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.provider_transaction_stats()
RETURNS TABLE (
  provider_id uuid,
  completed_orders bigint,
  completed_rides bigint,
  completed_transactions bigint,
  gross_value numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    pp.id AS provider_id,
    COALESCE(o.n, 0)::bigint AS completed_orders,
    COALESCE(r.n, 0)::bigint AS completed_rides,
    (COALESCE(o.n, 0) + COALESCE(r.n, 0))::bigint AS completed_transactions,
    (COALESCE(o.v, 0) + COALESCE(r.v, 0))::numeric AS gross_value
  FROM public.provider_profiles pp
  LEFT JOIN (
    SELECT provider_id, count(*) AS n, sum(total_amount) AS v
    FROM public.orders
    WHERE status = 'COMPLETED'::order_status
    GROUP BY provider_id
  ) o ON o.provider_id = pp.id
  LEFT JOIN (
    SELECT claimed_by_provider_id AS provider_id, count(*) AS n,
           sum(fare_estimate) AS v
    FROM public.ride_requests
    WHERE status = 'COMPLETED'::ride_status
      AND claimed_by_provider_id IS NOT NULL
    GROUP BY claimed_by_provider_id
  ) r ON r.provider_id = pp.id
  WHERE pp.status = 'APPROVED'::account_status;
$$;

GRANT EXECUTE ON FUNCTION public.provider_transaction_stats()
  TO anon, authenticated;

-- ===========================================================================
-- 4. The ranked provider list
-- ===========================================================================
-- One read for the home rail, the "All providers" sheet and the category
-- screen. `rank_position` is computed here rather than by the client so two
-- screens cannot disagree about who is number one.
CREATE OR REPLACE FUNCTION public.ranked_providers(
  p_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  business_name text,
  photo_storage_path text,
  city text,
  provider_type app_role,
  category_id uuid,
  category_name text,
  price_range text,
  completed_transactions bigint,
  rank_position bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(COALESCE(p_limit, 20), 1);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  RETURN QUERY
  SELECT
    v.id,
    v.business_name,
    v.photo_storage_path,
    v.city,
    v.provider_type,
    v.category_id,
    v.category_name,
    v.price_range,
    v.completed_transactions,
    v.rank_position
  FROM (
    SELECT
      pp.id,
      pp.business_name,
      pp.photo_storage_path,
      pp.city,
      pp.provider_type,
      pp.category_id,
      c.name AS category_name,
      pp.price_range,
      s.completed_transactions,
      row_number() OVER (
        ORDER BY s.completed_transactions DESC,
                 pp.created_at ASC,
                 pp.id ASC
      ) AS rank_position
    FROM public.provider_profiles pp
    LEFT JOIN public.categories c ON c.id = pp.category_id
    JOIN public.provider_transaction_stats() s ON s.provider_id = pp.id
    WHERE pp.status = 'APPROVED'::account_status
      AND (p_category_id IS NULL OR pp.category_id = p_category_id)
      AND (
        p_city IS NULL
        OR btrim(p_city) = ''
        OR pp.city = p_city
        OR pp.city IS NULL
      )
  ) v
  ORDER BY v.rank_position
  LIMIT v_limit OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ranked_providers(uuid, text, integer, integer)
  TO anon, authenticated;

-- ===========================================================================
-- 5. The ranked category list
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.ranked_categories(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  category_id uuid,
  name text,
  slug text,
  marketplace_sector text,
  provider_count bigint,
  completed_transactions bigint,
  rank_position bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(COALESCE(p_limit, 50), 1);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  RETURN QUERY
  SELECT
    v.category_id,
    v.name,
    v.slug,
    v.marketplace_sector,
    v.provider_count,
    v.completed_transactions,
    v.rank_position
  FROM (
    SELECT
      c.id AS category_id,
      c.name,
      c.slug,
      c.marketplace_sector,
      COALESCE(pr.provider_count, 0)::bigint AS provider_count,
      (COALESCE(pr.txn_count, 0) + COALESCE(pd.sales, 0))::bigint
        AS completed_transactions,
      row_number() OVER (
        ORDER BY (COALESCE(pr.txn_count, 0) + COALESCE(pd.sales, 0)) DESC,
                 c.name ASC,
                 c.id ASC
      ) AS rank_position
    FROM public.categories c
    LEFT JOIN (
      SELECT pp.category_id,
             count(*) AS provider_count,
             sum(s.completed_transactions) AS txn_count
      FROM public.provider_profiles pp
      JOIN public.provider_transaction_stats() s ON s.provider_id = pp.id
      WHERE pp.status = 'APPROVED'::account_status
        AND pp.category_id IS NOT NULL
      GROUP BY pp.category_id
    ) pr ON pr.category_id = c.id
    LEFT JOIN (
      SELECT p.category_id, sum(COALESCE(p.sales_count, 0)) AS sales
      FROM public.products p
      WHERE p.is_active
        AND p.category_id IS NOT NULL
      GROUP BY p.category_id
    ) pd ON pd.category_id = c.id
    WHERE c.is_active
  ) v
  ORDER BY v.rank_position
  LIMIT v_limit OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ranked_categories(integer, integer)
  TO anon, authenticated;

-- ===========================================================================
-- 6. Admin-defined per-category provider fields
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.category_profile_fields (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  category_id uuid NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,
  field_key text NOT NULL,
  label text NOT NULL,
  input_type text NOT NULL DEFAULT 'TEXT',
  unit_label text,
  help_text text,
  is_required boolean NOT NULL DEFAULT false,
  is_price boolean NOT NULL DEFAULT false,
  options jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT category_profile_fields_input_type_check
    CHECK (input_type IN ('TEXT', 'NUMBER', 'PRICE', 'BOOLEAN', 'SELECT')),
  CONSTRAINT category_profile_fields_key_unique UNIQUE (category_id, field_key)
);

CREATE INDEX IF NOT EXISTS idx_category_profile_fields_category
  ON public.category_profile_fields(category_id)
  WHERE is_active;

CREATE TABLE IF NOT EXISTS public.provider_profile_field_values (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id) ON DELETE CASCADE,
  field_key text NOT NULL,
  value_text text,
  value_number numeric,
  value_boolean boolean,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provider_profile_field_values_key_unique
    UNIQUE (provider_id, field_key)
);

CREATE INDEX IF NOT EXISTS idx_provider_profile_field_values_provider
  ON public.provider_profile_field_values(provider_id);

ALTER TABLE public.category_profile_fields ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_profile_field_values ENABLE ROW LEVEL SECURITY;

-- The field DEFINITIONS are a catalogue: readable by anyone (the customer page
-- needs the label for a value it is showing), writable by the definer RPCs
-- below only.
DROP POLICY IF EXISTS category_profile_fields_read ON public.category_profile_fields;
CREATE POLICY category_profile_fields_read ON public.category_profile_fields
  FOR SELECT TO anon, authenticated
  USING (is_active OR public.is_admin());

DROP POLICY IF EXISTS category_profile_fields_admin_write ON public.category_profile_fields;
CREATE POLICY category_profile_fields_admin_write ON public.category_profile_fields
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- A VALUE is private to its owner and its administrators. The public page
-- reads them through `provider_public_profile_fields()` below, which is a
-- definer function and exposes only an APPROVED provider's declared fields.
DROP POLICY IF EXISTS provider_profile_field_values_own ON public.provider_profile_field_values;
CREATE POLICY provider_profile_field_values_own ON public.provider_profile_field_values
  FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR provider_id IN (
      SELECT pp.id FROM public.provider_profiles pp WHERE pp.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS provider_profile_field_values_admin_write
  ON public.provider_profile_field_values;
CREATE POLICY provider_profile_field_values_admin_write
  ON public.provider_profile_field_values
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

GRANT SELECT ON public.category_profile_fields TO anon, authenticated;
GRANT SELECT ON public.provider_profile_field_values TO authenticated;

-- ===========================================================================
-- 7. The seeded default field sets, per marketplace sector
-- ===========================================================================
-- Written as one INSERT ... SELECT over the VALUES list rather than 118
-- statements. ON CONFLICT DO NOTHING throughout: a re-run is a no-op, and an
-- administrator who has edited a seeded field keeps their edit.
--
-- Only TOP-LEVEL categories are seeded. The RPC walks to the parent when a
-- category defines nothing of its own, so seeding all 118 would multiply the
-- rows an administrator has to review by eight for no additional coverage.
INSERT INTO public.category_profile_fields (
  category_id, field_key, label, input_type, unit_label, help_text,
  is_required, is_price, sort_order
)
SELECT
  c.id,
  f.field_key,
  f.label,
  f.input_type,
  f.unit_label,
  f.help_text,
  f.is_required,
  f.is_price,
  f.sort_order
FROM public.categories c
JOIN (
  VALUES
    -- ACCOMMODATION: a hotel sells ROOMS, not one price.
    ('ACCOMMODATION', 'room_types', 'Room types offered', 'TEXT',
     NULL, 'e.g. Single, Double, Suite', false, false, 10),
    ('ACCOMMODATION', 'price_per_night', 'Price per night', 'PRICE',
     'ETB / night', 'The rate for a standard room', true, true, 20),
    ('ACCOMMODATION', 'check_in_time', 'Check-in time', 'TEXT',
     NULL, 'e.g. 2:00 PM', false, false, 30),
    ('ACCOMMODATION', 'amenities', 'Amenities', 'TEXT',
     NULL, 'e.g. Wi-Fi, breakfast, parking', false, false, 40),
    -- FOOD: a restaurant sells a menu and a delivery.
    ('FOOD', 'cuisine', 'Cuisine', 'TEXT',
     NULL, 'e.g. Ethiopian, Italian, Fast food', false, false, 10),
    ('FOOD', 'average_price', 'Average price per plate', 'PRICE',
     'ETB', NULL, false, true, 20),
    ('FOOD', 'delivery_fee', 'Delivery fee', 'PRICE',
     'ETB', 'Leave blank if you do not deliver', false, true, 30),
    ('FOOD', 'delivery_time', 'Typical delivery time', 'TEXT',
     NULL, 'e.g. 30 - 45 min', false, false, 40),
    -- RETAIL: a shop sells stock.
    ('RETAIL', 'brands', 'Brands stocked', 'TEXT',
     NULL, NULL, false, false, 10),
    ('RETAIL', 'delivery_fee', 'Delivery fee', 'PRICE',
     'ETB', NULL, false, true, 20),
    ('RETAIL', 'warranty', 'Warranty', 'TEXT',
     NULL, 'e.g. 6 months', false, false, 30),
    -- SERVICES: this is the doctor / home-care case in the report.
    ('SERVICES', 'services_offered', 'Services offered', 'TEXT',
     NULL, 'List the services you provide', true, false, 10),
    ('SERVICES', 'price_per_hour', 'Price per hour', 'PRICE',
     'ETB / hour', 'Your hourly rate', false, true, 20),
    ('SERVICES', 'availability', 'Availability', 'TEXT',
     NULL, 'e.g. Mon - Sat, 8:00 - 18:00', false, false, 30),
    ('SERVICES', 'years_experience', 'Years of experience', 'NUMBER',
     'years', NULL, false, false, 40),
    -- TRANSPORT: a fleet sells a vehicle and a distance.
    ('TRANSPORT', 'vehicle_class', 'Vehicle class', 'TEXT',
     NULL, 'e.g. Bajaj, Sedan, Minibus', false, false, 10),
    ('TRANSPORT', 'price_per_km', 'Price per km', 'PRICE',
     'ETB / km', NULL, false, true, 20),
    ('TRANSPORT', 'seats', 'Passenger seats', 'NUMBER',
     'seats', NULL, false, false, 30),
    -- OTHER, and every category with no sector: a general shape, so the form
    -- is never empty for a category the seed above does not name.
    ('OTHER', 'services_offered', 'What you offer', 'TEXT',
     NULL, NULL, false, false, 10),
    ('OTHER', 'price_from', 'Starting price', 'PRICE',
     'ETB', NULL, false, true, 20),
    ('OTHER', 'opening_hours', 'Opening hours', 'TEXT',
     NULL, NULL, false, false, 30)
) AS f(
  sector, field_key, label, input_type, unit_label, help_text,
  is_required, is_price, sort_order
) ON f.sector = COALESCE(c.marketplace_sector, 'OTHER')
WHERE c.is_active
  AND c.parent_id IS NULL
ON CONFLICT (category_id, field_key) DO NOTHING;

-- ===========================================================================
-- 8. The effective field set, with the parent walk
-- ===========================================================================
-- Returns whole rows, not a projection. The first version of this was a thin
-- projection without `id`, and `save_provider_profile_field` -- which needs the
-- row to read `input_type` -- matched on a column the projection did not have,
-- so every save would have been refused with
-- THAT_FIELD_IS_NOT_PART_OF_YOUR_CATEGORY. A projection is exactly where that
-- bug hides: it compiles, it returns rows, and it is missing the one column the
-- caller needed.
--
-- The walk: a subcategory with no fields of its own inherits its nearest
-- ancestor that has some, up to three levels. Without it, a provider who chose
-- "Hostels" would be asked nothing while one who chose "Hotels & Lodging" got
-- the full form.
CREATE OR REPLACE FUNCTION public.provider_effective_profile_fields(
  p_category_id uuid
)
RETURNS SETOF public.category_profile_fields
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH RECURSIVE chain AS (
    SELECT c.id, c.parent_id, 0 AS depth
    FROM public.categories c
    WHERE c.id = p_category_id
    UNION ALL
    SELECT c.id, c.parent_id, ch.depth + 1
    FROM public.categories c
    JOIN chain ch ON ch.parent_id = c.id
    WHERE ch.depth < 3
  )
  SELECT f.*
  FROM public.category_profile_fields f
  JOIN chain ch ON ch.id = f.category_id
  WHERE f.is_active
    AND ch.depth = COALESCE((
      SELECT min(ch2.depth)
      FROM chain ch2
      WHERE EXISTS (
        SELECT 1 FROM public.category_profile_fields f2
        WHERE f2.category_id = ch2.id AND f2.is_active
      )
    ), 0)
  ORDER BY f.sort_order, f.label;
$$;

GRANT EXECUTE ON FUNCTION public.provider_effective_profile_fields(uuid)
  TO anon, authenticated;

-- The thin projection the forms render.
CREATE OR REPLACE FUNCTION public.provider_profile_fields_for(
  p_category_id uuid
)
RETURNS TABLE (
  field_key text,
  label text,
  input_type text,
  unit_label text,
  help_text text,
  is_required boolean,
  is_price boolean,
  sort_order integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    f.field_key,
    f.label,
    f.input_type,
    f.unit_label,
    f.help_text,
    f.is_required,
    f.is_price,
    f.sort_order
  FROM public.provider_effective_profile_fields(p_category_id) f
  ORDER BY f.sort_order, f.label;
$$;

GRANT EXECUTE ON FUNCTION public.provider_profile_fields_for(uuid)
  TO anon, authenticated;

-- ===========================================================================
-- 9. The provider's own form and the customer's view
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.provider_profile_fields()
RETURNS TABLE (
  field_key text,
  label text,
  input_type text,
  unit_label text,
  help_text text,
  is_required boolean,
  is_price boolean,
  sort_order integer,
  value_text text,
  value_number numeric,
  value_boolean boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider_id uuid;
  v_category_id uuid;
BEGIN
  SELECT pp.id, pp.category_id INTO v_provider_id, v_category_id
  FROM public.provider_profiles pp
  WHERE pp.user_id = auth.uid()
  ORDER BY pp.created_at
  LIMIT 1;

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'NO_PROVIDER_PROFILE';
  END IF;

  RETURN QUERY
  SELECT
    f.field_key,
    f.label,
    f.input_type,
    f.unit_label,
    f.help_text,
    f.is_required,
    f.is_price,
    f.sort_order,
    v.value_text,
    v.value_number,
    v.value_boolean
  FROM public.provider_effective_profile_fields(v_category_id) f
  LEFT JOIN public.provider_profile_field_values v
    ON v.provider_id = v_provider_id
   AND v.field_key = f.field_key
  ORDER BY f.sort_order, f.label;
END;
$$;

GRANT EXECUTE ON FUNCTION public.provider_profile_fields()
  TO authenticated;

-- What the customer's provider page shows: the declared fields and the values,
-- for an APPROVED provider only. Definer, so it needs no read policy on the
-- values table, and it reports nothing for a provider that is not approved.
CREATE OR REPLACE FUNCTION public.provider_public_profile_fields(
  p_provider_id uuid
)
RETURNS TABLE (
  field_key text,
  label text,
  input_type text,
  unit_label text,
  is_price boolean,
  sort_order integer,
  value_text text,
  value_number numeric,
  value_boolean boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_category_id uuid;
BEGIN
  SELECT pp.category_id INTO v_category_id
  FROM public.provider_profiles pp
  WHERE pp.id = p_provider_id
    AND pp.status = 'APPROVED'::account_status;

  IF v_category_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    f.field_key,
    f.label,
    f.input_type,
    f.unit_label,
    f.is_price,
    f.sort_order,
    v.value_text,
    v.value_number,
    v.value_boolean
  FROM public.provider_effective_profile_fields(v_category_id) f
  JOIN public.provider_profile_field_values v
    ON v.provider_id = p_provider_id
   AND v.field_key = f.field_key
  WHERE v.value_text IS NOT NULL
     OR v.value_number IS NOT NULL
     OR v.value_boolean IS NOT NULL
  ORDER BY f.sort_order, f.label;
END;
$$;

GRANT EXECUTE ON FUNCTION public.provider_public_profile_fields(uuid)
  TO anon, authenticated;

-- ===========================================================================
-- 10. The provider's save path
-- ===========================================================================
-- One field at a time, keyed by the definition's own key. The column written is
-- chosen by the FIELD'S declared input type, so a client cannot smuggle a
-- number into a text field or the reverse. A key the provider's category does
-- not define is refused -- not silently stored -- because a value nothing
-- renders is a write that looks like it worked.
CREATE OR REPLACE FUNCTION public.save_provider_profile_field(
  p_field_key text,
  p_value_text text DEFAULT NULL,
  p_value_number numeric DEFAULT NULL,
  p_value_boolean boolean DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider_id uuid;
  v_category_id uuid;
  v_input_type text;
  v_is_required boolean;
  v_key text := lower(btrim(coalesce(p_field_key, '')));
  v_text text := NULLIF(btrim(coalesce(p_value_text, '')), '');
  v_number numeric := p_value_number;
BEGIN
  SELECT pp.id, pp.category_id INTO v_provider_id, v_category_id
  FROM public.provider_profiles pp
  WHERE pp.user_id = auth.uid()
  ORDER BY pp.created_at
  LIMIT 1;

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'NO_PROVIDER_PROFILE';
  END IF;

  SELECT f.input_type, f.is_required
    INTO v_input_type, v_is_required
  FROM public.provider_effective_profile_fields(v_category_id) f
  WHERE f.field_key = v_key
  LIMIT 1;

  IF v_input_type IS NULL THEN
    RAISE EXCEPTION 'THAT_FIELD_IS_NOT_PART_OF_YOUR_CATEGORY';
  END IF;

  IF v_is_required
     AND v_text IS NULL
     AND v_number IS NULL
     AND p_value_boolean IS NULL THEN
    RAISE EXCEPTION 'THIS_FIELD_IS_REQUIRED';
  END IF;

  IF v_input_type IN ('NUMBER', 'PRICE') AND v_text IS NOT NULL THEN
    -- A number field may arrive as text from a form; refuse anything that is
    -- not actually a number rather than storing "about 500" into value_text,
    -- where every renderer would skip a row whose value is in the wrong column.
    IF v_text !~ '^[0-9]+(\.[0-9]+)?$' THEN
      RAISE EXCEPTION 'THAT_FIELD_EXPECTS_A_NUMBER';
    END IF;
    v_number := v_text::numeric;
    v_text := NULL;
  END IF;

  IF v_input_type = 'TEXT' AND v_number IS NOT NULL THEN
    v_text := trim(to_char(v_number, 'FM999999999990.99'));
    v_number := NULL;
  END IF;

  INSERT INTO public.provider_profile_field_values (
    provider_id, field_key, value_text, value_number, value_boolean, updated_at
  )
  VALUES (
    v_provider_id,
    v_key,
    CASE WHEN v_input_type IN ('NUMBER', 'PRICE') THEN NULL ELSE v_text END,
    CASE WHEN v_input_type IN ('NUMBER', 'PRICE') THEN v_number ELSE NULL END,
    CASE WHEN v_input_type = 'BOOLEAN' THEN p_value_boolean ELSE NULL END,
    now()
  )
  ON CONFLICT (provider_id, field_key) DO UPDATE SET
    value_text = EXCLUDED.value_text,
    value_number = EXCLUDED.value_number,
    value_boolean = EXCLUDED.value_boolean,
    updated_at = now();

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_provider_profile_field(
  text, text, numeric, boolean
) TO authenticated;

-- ===========================================================================
-- 11. The admin write path
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.admin_category_profile_fields()
RETURNS TABLE (
  id uuid,
  category_id uuid,
  category_name text,
  marketplace_sector text,
  field_key text,
  label text,
  input_type text,
  unit_label text,
  help_text text,
  is_required boolean,
  is_price boolean,
  sort_order integer,
  is_active boolean,
  provider_value_count bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  RETURN QUERY
  SELECT
    f.id,
    f.category_id,
    c.name AS category_name,
    c.marketplace_sector,
    f.field_key,
    f.label,
    f.input_type,
    f.unit_label,
    f.help_text,
    f.is_required,
    f.is_price,
    f.sort_order,
    f.is_active,
    -- Counted as a SCALAR subquery, not a join. Joined on the field key alone
    -- this returns one row per matching value ANYWHERE, so a key that appears
    -- in eight categories would have listed the field eight times and counted
    -- every category's answers against each copy.
    (
      SELECT count(*)
      FROM public.provider_profile_field_values v
      JOIN public.provider_profiles pv ON pv.id = v.provider_id
      WHERE v.field_key = f.field_key
        AND pv.category_id = f.category_id
    )::bigint AS provider_value_count
  FROM public.category_profile_fields f
  JOIN public.categories c ON c.id = f.category_id
  ORDER BY c.name, f.sort_order, f.label;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_category_profile_fields()
  TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_save_category_profile_field(
  p_category_id uuid,
  p_field_key text,
  p_label text,
  p_input_type text DEFAULT 'TEXT',
  p_unit_label text DEFAULT NULL,
  p_help_text text DEFAULT NULL,
  p_is_required boolean DEFAULT false,
  p_is_price boolean DEFAULT false,
  p_sort_order integer DEFAULT 0,
  p_is_active boolean DEFAULT true
)
RETURNS public.category_profile_fields
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.category_profile_fields;
  v_key text := lower(btrim(coalesce(p_field_key, '')));
  v_label text := btrim(coalesce(p_label, ''));
  v_type text := upper(btrim(coalesce(p_input_type, 'TEXT')));
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_category_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM public.categories WHERE id = p_category_id) THEN
    RAISE EXCEPTION 'CATEGORY_NOT_FOUND';
  END IF;

  -- A key is the identifier answers are filed under, so it is normalised here
  -- rather than trusted: an uppercase or spaced key would silently create a
  -- second field beside an answer that already exists.
  IF v_key !~ '^[a-z][a-z0-9_]{1,48}$' THEN
    RAISE EXCEPTION 'FIELD_KEY_MUST_BE_LOWERCASE_WITH_UNDERSCORES';
  END IF;

  IF v_label = '' THEN
    RAISE EXCEPTION 'A_LABEL_IS_REQUIRED';
  END IF;

  IF v_type NOT IN ('TEXT', 'NUMBER', 'PRICE', 'BOOLEAN', 'SELECT') THEN
    RAISE EXCEPTION 'INPUT_TYPE_IS_NOT_ONE_OF_THE_FIVE';
  END IF;

  INSERT INTO public.category_profile_fields (
    category_id, field_key, label, input_type, unit_label, help_text,
    is_required, is_price, sort_order, is_active, updated_at
  )
  VALUES (
    p_category_id,
    v_key,
    v_label,
    v_type,
    NULLIF(btrim(coalesce(p_unit_label, '')), ''),
    NULLIF(btrim(coalesce(p_help_text, '')), ''),
    COALESCE(p_is_required, false),
    COALESCE(p_is_price, false) OR v_type = 'PRICE',
    COALESCE(p_sort_order, 0),
    COALESCE(p_is_active, true),
    now()
  )
  ON CONFLICT (category_id, field_key) DO UPDATE SET
    label = EXCLUDED.label,
    input_type = EXCLUDED.input_type,
    unit_label = EXCLUDED.unit_label,
    help_text = EXCLUDED.help_text,
    is_required = EXCLUDED.is_required,
    is_price = EXCLUDED.is_price,
    sort_order = EXCLUDED.sort_order,
    is_active = EXCLUDED.is_active,
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_save_category_profile_field(
  uuid, text, text, text, text, text, boolean, boolean, integer, boolean
) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_category_profile_field(
  p_field_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_field_id IS NULL THEN
    RAISE EXCEPTION 'FIELD_ID_REQUIRED';
  END IF;

  DELETE FROM public.category_profile_fields
  WHERE id = p_field_id
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'FIELD_NOT_FOUND';
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_category_profile_field(uuid)
  TO authenticated;

-- ===========================================================================
-- 12. Record the signup category
-- ===========================================================================
-- The signup form asks which trade the provider is registering as, and this is
-- what records it. Deliberately NOT folded into handle_new_user: that trigger
-- runs with no JWT and cannot validate a category, and restating it for one
-- column would put the whole OTP signup gate back on the critical path of a
-- feature that has nothing to do with it.
--
-- The sector must MATCH the provider type: a SERVICE_PROVIDER cannot file
-- themselves under a VEHICLE category, because that would give them the wrong
-- form and file their products where no customer looks.
CREATE OR REPLACE FUNCTION public.provider_claim_category(
  p_category_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider_id uuid;
  v_provider_type app_role;
  v_sector text;
BEGIN
  SELECT pp.id, pp.provider_type INTO v_provider_id, v_provider_type
  FROM public.provider_profiles pp
  WHERE pp.user_id = auth.uid()
  ORDER BY pp.created_at
  LIMIT 1;

  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'NO_PROVIDER_PROFILE';
  END IF;

  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'PLEASE_PICK_YOUR_CATEGORY';
  END IF;

  SELECT c.sector INTO v_sector
  FROM public.categories c
  WHERE c.id = p_category_id
    AND c.is_active;

  IF v_sector IS NULL THEN
    RAISE EXCEPTION 'CATEGORY_NOT_FOUND';
  END IF;

  IF v_provider_type = 'VEHICLE_PROVIDER'::app_role AND v_sector <> 'VEHICLE' THEN
    RAISE EXCEPTION 'THAT_IS_NOT_A_VEHICLE_CATEGORY';
  END IF;

  IF v_provider_type = 'SERVICE_PROVIDER'::app_role AND v_sector <> 'SERVICE' THEN
    RAISE EXCEPTION 'THAT_IS_NOT_A_SERVICE_CATEGORY';
  END IF;

  UPDATE public.provider_profiles
  SET category_id = p_category_id,
      updated_at = now()
  WHERE id = v_provider_id;

  RETURN p_category_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.provider_claim_category(uuid)
  TO authenticated;

-- ===========================================================================
-- 13. The reports the deploy and the connectivity suite assert against
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.ranking_wiring_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text := '';
  v_with_txn bigint;
  v_ranked bigint;
  v_categories bigint;
  v_top text;
BEGIN
  IF to_regprocedure('public.provider_transaction_stats()') IS NULL THEN
    v_missing := v_missing || 'provider_transaction_stats;';
  END IF;
  IF to_regprocedure('public.ranked_providers(uuid,text,integer,integer)') IS NULL THEN
    v_missing := v_missing || 'ranked_providers;';
  END IF;
  IF to_regprocedure('public.ranked_categories(integer,integer)') IS NULL THEN
    v_missing := v_missing || 'ranked_categories;';
  END IF;

  IF v_missing <> '' THEN
    RETURN 'missing: ' || v_missing;
  END IF;

  SELECT count(*) INTO v_with_txn
  FROM public.provider_transaction_stats()
  WHERE completed_transactions > 0;

  SELECT count(*) INTO v_ranked FROM public.ranked_providers(NULL, NULL, 500, 0);
  SELECT count(*) INTO v_categories FROM public.ranked_categories(500, 0);

  SELECT rp.business_name INTO v_top
  FROM public.ranked_providers(NULL, NULL, 1, 0) rp;

  RETURN 'ok: providers ranked=' || v_ranked::text
    || ', with completed transactions=' || v_with_txn::text
    || ', categories ranked=' || v_categories::text
    || ', top=' || COALESCE(v_top, '(none)');
END;
$$;

GRANT EXECUTE ON FUNCTION public.ranking_wiring_report() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.category_field_wiring_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text := '';
  v_fields bigint;
  v_categories bigint;
  v_values bigint;
  v_sectors bigint;
BEGIN
  IF to_regclass('public.category_profile_fields') IS NULL THEN
    v_missing := v_missing || 'category_profile_fields;';
  END IF;
  IF to_regclass('public.provider_profile_field_values') IS NULL THEN
    v_missing := v_missing || 'provider_profile_field_values;';
  END IF;
  IF to_regprocedure('public.admin_save_category_profile_field(uuid,text,text,text,text,text,boolean,boolean,integer,boolean)') IS NULL THEN
    v_missing := v_missing || 'admin_save_category_profile_field;';
  END IF;
  IF to_regprocedure('public.save_provider_profile_field(text,text,numeric,boolean)') IS NULL THEN
    v_missing := v_missing || 'save_provider_profile_field;';
  END IF;
  IF to_regprocedure('public.provider_public_profile_fields(uuid)') IS NULL THEN
    v_missing := v_missing || 'provider_public_profile_fields;';
  END IF;
  IF to_regprocedure('public.provider_claim_category(uuid)') IS NULL THEN
    v_missing := v_missing || 'provider_claim_category;';
  END IF;
  IF to_regprocedure('public.provider_effective_profile_fields(uuid)') IS NULL THEN
    v_missing := v_missing || 'provider_effective_profile_fields;';
  END IF;

  IF v_missing <> '' THEN
    RETURN 'missing: ' || v_missing;
  END IF;

  SELECT count(*) INTO v_fields
  FROM public.category_profile_fields WHERE is_active;

  SELECT count(DISTINCT category_id) INTO v_categories
  FROM public.category_profile_fields WHERE is_active;

  SELECT count(*) INTO v_values FROM public.provider_profile_field_values;

  SELECT count(DISTINCT COALESCE(c.marketplace_sector, 'OTHER'))
    INTO v_sectors
  FROM public.category_profile_fields f
  JOIN public.categories c ON c.id = f.category_id
  WHERE f.is_active;

  IF v_fields = 0 THEN
    RETURN 'no category profile fields exist, so every provider form is empty '
      'and this is a screen with nothing on it';
  END IF;

  RETURN 'ok: ' || v_fields::text || ' field definition(s) across '
    || v_categories::text || ' category/categories, '
    || v_sectors::text || ' marketplace sector(s) seeded, '
    || v_values::text || ' provider answer(s) stored';
END;
$$;

GRANT EXECUTE ON FUNCTION public.category_field_wiring_report()
  TO anon, authenticated;

-- Can a caller with no provider profile write a field value?
--
-- Returns the SQL error message it got, or the literal 'ACCEPTED' if the write
-- went through. That spelling is deliberate: a boolean "true = refused" is
-- indistinguishable from "refused for the wrong reason", and a first version
-- written that way would have reported a healthy save path on a database with
-- no providers at all.
--
-- The connectivity suite runs as anon -- no JWT, therefore auth.uid() IS NULL,
-- therefore no provider profile -- so this is exactly the caller it exercises.
-- What it proves is that a value cannot be written by anyone who is not a
-- provider. The per-category key guard is asserted by the source-level check in
-- tools/harness/static_checks.py, which can read the function body.
--
-- Its own top-level function with ONE try, because the scanner in
-- tools/harness/plpgsql_body_syntax.py splits a body on `;` at paren depth 0 and
-- mis-handles a nested `BEGIN ... EXCEPTION` (see ARCHITECTURE.md 7.1).
CREATE OR REPLACE FUNCTION public.save_provider_value_outcome()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.save_provider_profile_field('a_field_no_category_defines', 'x');
  RETURN 'ACCEPTED';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_provider_value_outcome()
  TO anon, authenticated;

-- The assertion the pre-deploy suite runs. It EXERCISES the paths rather than
-- reading them: the ranking lists run against the real database, the field
-- catalogue is counted, and a write by a non-provider is attempted. A schema
-- that parses and a save that silently writes nothing look identical to every
-- static check in this repository.
CREATE OR REPLACE FUNCTION public.assert_ranking_and_category_fields()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_provider uuid;
  v_category uuid;
  v_field_key text;
  v_outcome text;
  v_fields text;
  v_ranking text;
BEGIN
  v_outcome := public.save_provider_value_outcome();
  v_fields := public.category_field_wiring_report();
  v_ranking := public.ranking_wiring_report();

  SELECT pp.id, pp.category_id INTO v_provider, v_category
  FROM public.provider_profiles pp
  WHERE pp.status = 'APPROVED'::account_status
    AND pp.category_id IS NOT NULL
  ORDER BY pp.created_at
  LIMIT 1;

  SELECT f.field_key INTO v_field_key
  FROM public.provider_effective_profile_fields(v_category) f
  ORDER BY f.sort_order
  LIMIT 1;

  RETURN jsonb_build_object(
    'ok', (v_outcome <> 'ACCEPTED') AND v_fields LIKE 'ok:%' AND v_ranking LIKE 'ok:%',
    'write_outcome', v_outcome,
    'category_fields', v_fields,
    'ranking', v_ranking,
    'approved_provider', v_provider,
    'provider_category', v_category,
    'first_effective_field', v_field_key
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_ranking_and_category_fields()
  TO anon, authenticated;
