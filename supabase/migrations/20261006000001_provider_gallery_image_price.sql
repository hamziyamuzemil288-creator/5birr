-- A price on one gallery photo.
--
-- THE REPORT
-- ----------
-- "the gallery price editing under image settings is still not there".
--
-- WHAT WAS ACTUALLY MISSING
-- -------------------------
-- Not a wiring gap. `provider_gallery` has never had a price column: 0022a
-- creates it as id, provider_id, storage_path, caption, display_order,
-- is_active, created_at, updated_at. So a provider could describe a photo
-- (caption), decide who sees it (is_active) and choose its order -- and there
-- was no field anywhere to say what the photo costs, which is the one number a
-- customer wants before they call.
--
-- WHY A PER-PHOTO COLUMN AND NOT `provider_profiles.price_range`
-- -------------------------------------------------------------
-- `price_range` is the shop's headline range and it is deliberately free text
-- ("50 - 200 ETB"), because a provider with six unrelated services genuinely
-- has six prices. A price on a photo answers the more specific question --
-- THIS photo, THIS price -- which is exactly the thing the shop-wide string
-- cannot say. Both may be true at once; neither replaces the other.
--
-- WHY THE WRITE IS A FUNCTION
-- ---------------------------
-- 20260927000050 revoked INSERT/UPDATE/DELETE on provider_gallery from anon and
-- authenticated, and 20260927000055 put the writes the app genuinely needs back
-- as SECURITY DEFINER functions. This follows that: the ownership check lives
-- in one place, and the invariant "a client may write the twenty tables the app
-- writes, and nothing else" stays literally true.
--
-- The signature is NEW rather than an argument added to add_gallery_image().
-- Adding a parameter to a live function creates a second overload, which is the
-- PGRST203 trap documented in ARCHITECTURE.md 7.1.6: PostgREST finds two
-- candidates and refuses both, so every existing caller breaks at once. The
-- screen sets the price on a photo that is already uploaded, so nothing is
-- lost by keeping the two apart.

-- ===========================================================================
-- 1. The column
-- ===========================================================================
ALTER TABLE public.provider_gallery
  ADD COLUMN IF NOT EXISTS price numeric(12, 2);

-- NULL means "this photo carries no price", which is not the same claim as
-- 0.00, and it is the state every existing row is already in -- so the feature
-- ships dark until somebody sets a price, rather than showing "0 ETB" on every
-- photograph in the app.
--
-- A negative price is not a price. A CHECK rather than a trigger, because the
-- value only ever arrives through the one function below and this is the
-- property that must hold however it is written.
ALTER TABLE public.provider_gallery
  DROP CONSTRAINT IF EXISTS provider_gallery_price_check;
ALTER TABLE public.provider_gallery
  ADD CONSTRAINT provider_gallery_price_check
  CHECK (price IS NULL OR price >= 0);

COMMENT ON COLUMN public.provider_gallery.price IS
  'Per-photo price in ETB. NULL means the photo carries no price. Written only '
  'through set_gallery_image_price().';

-- ===========================================================================
-- 2. Set or clear a photo's price
-- ===========================================================================
-- Shaped like set_gallery_image_public() (0126 section 7), its neighbour in
-- the same grid: the same guards, the same "only your own image" rule, and the
-- same habit of returning the updated row so the screen can show what was
-- actually stored rather than what it hoped it stored.
--
-- `p_price DEFAULT NULL` cannot be distinguished from an explicit NULL, and
-- deliberately so: clearing a price and never having had one are the same
-- row state. There is no third outcome to confuse it with.
CREATE OR REPLACE FUNCTION public.set_gallery_image_price(
  p_image_id uuid,
  p_price numeric DEFAULT NULL
)
RETURNS public.provider_gallery
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_image public.provider_gallery;
  v_owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'AN_IMAGE_IS_REQUIRED';
  END IF;

  -- Refused here as well as by the CHECK, so the caller gets a sentence that
  -- names the problem instead of a 23514 they cannot act on.
  IF p_price IS NOT NULL AND p_price < 0 THEN
    RAISE EXCEPTION 'A_PRICE_CANNOT_BE_NEGATIVE';
  END IF;

  SELECT g.provider_id INTO v_owner
    FROM public.provider_gallery g
   WHERE g.id = p_image_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_owner) THEN
    RAISE EXCEPTION 'NOT_YOUR_IMAGE';
  END IF;

  UPDATE public.provider_gallery g
     SET price = p_price,
         updated_at = now()
   WHERE g.id = p_image_id
   RETURNING * INTO v_image;

  RETURN v_image;
END;
$$;

COMMENT ON FUNCTION public.set_gallery_image_price(uuid, numeric) IS
  'Sets or clears (p_price NULL) the price on one of the caller''s own gallery '
  'photos. Owner-scoped; provider_gallery has no client UPDATE grant.';

-- ===========================================================================
-- 3. An instrument that EXECUTES instead of describing
-- ===========================================================================
-- The lesson of 0126 section 2 and 0137, applied before it costs a deploy:
-- plpgsql does not validate a function body at CREATE time, so a body naming a
-- column that does not exist deploys cleanly and then fails on every call.
-- 0137 is the standing proof -- admin_public_image_gallery() referenced
-- `vehicles.is_active` and `vehicles.updated_at`, neither of which exists, and
-- the admin image panel returned nothing at all while every check stayed green.
--
-- EXPLAIN WITHOUT ANALYZE plans the statement and executes nothing, so this
-- proves `provider_gallery.price` is a real column with no rows written, no
-- provider needed and no ownership authority -- the plan is where a missing
-- column fails. Same technique and same reasoning as
-- assert_category_fee_save_plans().
--
-- It is NOT wired into the connectivity suite on purpose: that suite runs
-- against the LIVE database, so a suite entry for a function this migration has
-- not deployed yet would turn Connectivity CI red for a correct push. The
-- function is here so the instrument exists and can be called the moment the
-- migration lands.
CREATE OR REPLACE FUNCTION public.assert_gallery_price_save_plans()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_sql text;
BEGIN
  v_sql :=
    'EXPLAIN UPDATE public.provider_gallery '
    || 'SET price = 1.00, updated_at = now() '
    || 'WHERE id = ''00000000-0000-4000-8000-000000000000''::uuid';

  BEGIN
    EXECUTE v_sql;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'The gallery price save does not plan (% %): '
      'provider_gallery.price is missing, so every price save fails however '
      'well the screen is wired.', SQLSTATE, SQLERRM;
  END;

  RETURN 'ok: the gallery price update plans, so provider_gallery.price exists '
         || 'and a price can be stored';
END;
$$;

-- ===========================================================================
-- 4. Reachability
-- ===========================================================================
-- Revoked from anon for the same reason set_gallery_image_public() is: an
-- anonymous "owner" exists on the auth side, and owns_provider_profile() is the
-- only thing standing between one provider's gallery and another's.
REVOKE ALL ON FUNCTION public.set_gallery_image_price(uuid, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_gallery_image_price(uuid, numeric)
  TO authenticated, service_role;

-- Zero-argument assertion: callable by the connectivity suite, which runs as
-- the anon client. It exposes nothing -- it returns one sentence.
REVOKE ALL ON FUNCTION public.assert_gallery_price_save_plans()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_gallery_price_save_plans()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
