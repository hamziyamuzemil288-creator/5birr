-- 20261006000010 — "Hide" must be reversible for EVERY image, not just the
-- provider gallery
--
-- THE REPORT (item 2, second half)
-- ---------------------------------
-- Content Control offers two actions per image: "Hide from public"
-- (reversible) and "Delete permanently". Only one of them worked.
--
-- REPRODUCED ROOT CAUSE (code + schema, migration chain):
--   admin_set_gallery_image_public() (20260927000126) resolved p_image_id
--   with a single `SELECT ... FROM provider_gallery WHERE id = p_image_id`,
--   and raised NO_SUCH_IMAGE when nothing matched. But the gallery screen
--   (admin_public_image_gallery) hands out ids from THREE tables —
--   provider_gallery, product_images, vehicle_images — and for the product
--   and vehicle rows is_public is derived from the LISTING
--   (products.listing_status, vehicles.status), so every published product
--   photo was offered "Hide from public" and every tap came back
--   NO_SUCH_IMAGE: a dead action dressed as a feature.
--
-- THE FIX
--   admin_set_gallery_image_public is restated (same 3-argument signature,
--   so no PostgREST overload ambiguity) to detect which of the three tables
--   holds the id and to hide/restore the thing that actually controls that
--   image's public visibility:
--     provider_gallery  g.is_active          (as before)
--     product_images    products.is_active   (new — takes the listing out
--                                              of buyers' read policy and
--                                              search, one flag, reversible)
--     vehicle_images    vehicles.status      (APPROVED <-> SUSPENDED; the
--                                              public read policy requires
--                                              APPROVED, so this is the
--                                              visibility switch)
--   Restores that cannot apply (a draft listing, a vehicle still awaiting
--   approval) do not lie: they change nothing and return the sentence that
--   says why. Every change still lands in moderation_actions with the
--   acting admin, and hiding needs no reason while restoring does — the
--   original 0126 rule, kept.
--
--   admin_public_image_gallery is restated so the product chip reads
--   `listing_status = 'ACTIVE' AND is_active` — before this file a hidden
--   listing still showed the image as "Public" and the moderator had no
--   way to see their own takedown.
--
-- Deploy: needs a Supabase deploy (two function restatements).

-- ---------------------------------------------------------------------------
-- 1. Hide or restore, for any of the three image tables
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_set_gallery_image_public(
  p_image_id uuid,
  p_public boolean,
  p_reason text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_source text := NULL;
  v_path text;
  v_provider uuid;
  v_user uuid;
  v_was boolean;
  v_bucket text;
  v_actor uuid;
  v_actor_name text := '';
  v_product uuid;
  v_vehicle uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'AN_IMAGE_IS_REQUIRED';
  END IF;

  IF p_public AND length(btrim(coalesce(p_reason, ''))) < 3 THEN
    -- Hiding needs no reason: the image is simply not shown. RESTORING one
    -- does: putting a photo back after a takedown overrides an earlier
    -- decision, and the permanent record should say who decided and why.
    RAISE EXCEPTION 'A_REASON_IS_REQUIRED';
  END IF;

  -- Which of the three image tables holds this id? The first match wins;
  -- ids are uuids issued by the tables themselves, so they cannot collide.
  IF to_regclass('public.provider_gallery') IS NOT NULL THEN
    SELECT 'provider_gallery', g.storage_path, g.provider_id, g.is_active,
           pp.user_id, 'provider-gallery'
      INTO v_source, v_path, v_provider, v_was, v_user, v_bucket
      FROM public.provider_gallery g
      JOIN public.provider_profiles pp ON pp.id = g.provider_id
     WHERE g.id = p_image_id;
  END IF;

  IF v_source IS NULL AND to_regclass('public.product_images') IS NOT NULL THEN
    SELECT 'product_images', i.storage_path, p.provider_id,
           (p.listing_status = 'ACTIVE' AND p.is_active),
           pp.user_id, 'product-images'
      INTO v_source, v_path, v_provider, v_was, v_user, v_bucket
      FROM public.product_images i
      JOIN public.products p ON p.id = i.product_id
      JOIN public.provider_profiles pp ON pp.id = p.provider_id
     WHERE i.id = p_image_id;
  END IF;

  IF v_source IS NULL AND to_regclass('public.vehicle_images') IS NOT NULL THEN
    SELECT 'vehicle_images', i.storage_path, v.provider_id,
           (v.status = 'APPROVED'),
           pp.user_id, 'vehicle-images'
      INTO v_source, v_path, v_provider, v_was, v_user, v_bucket
      FROM public.vehicle_images i
      JOIN public.vehicles v ON v.id = i.vehicle_id
      JOIN public.provider_profiles pp ON pp.id = v.provider_id
     WHERE i.id = p_image_id;
  END IF;

  IF v_source IS NULL THEN
    RAISE EXCEPTION 'NO_SUCH_IMAGE';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;

  IF v_source = 'provider_gallery' THEN
    IF v_was = coalesce(p_public, v_was) THEN
      RETURN 'That image is already '
             || CASE WHEN p_public THEN 'public.' ELSE 'hidden.' END;
    END IF;
    UPDATE public.provider_gallery
       SET is_active = coalesce(p_public, false),
           updated_at = now()
     WHERE id = p_image_id;

  ELSIF v_source = 'product_images' THEN
    SELECT product_id INTO v_product
      FROM public.product_images WHERE id = p_image_id;
    IF p_public THEN
      -- Restoring only means something while the listing itself is one
      -- buyers can see; a draft or archived listing is not "hidden by us".
      UPDATE public.products
         SET is_active = true, updated_at = now()
       WHERE id = v_product AND listing_status = 'ACTIVE';
      IF NOT FOUND THEN
        RETURN 'That listing is not published (it is a draft or archived), '
               || 'so there is nothing to put back — publish it from '
               || 'Listings instead.';
      END IF;
    ELSE
      IF NOT v_was THEN
        RETURN 'That image is already hidden.';
      END IF;
      UPDATE public.products
         SET is_active = false, updated_at = now()
       WHERE id = v_product AND listing_status = 'ACTIVE';
      IF NOT FOUND THEN
        RETURN 'That listing is no longer published, so it is already out '
               || 'of buyers'' sight.';
      END IF;
    END IF;

  ELSIF v_source = 'vehicle_images' THEN
    SELECT vehicle_id INTO v_vehicle
      FROM public.vehicle_images WHERE id = p_image_id;
    IF p_public THEN
      UPDATE public.vehicles SET status = 'APPROVED' WHERE id = v_vehicle
        AND status = 'SUSPENDED';
      IF NOT FOUND THEN
        RETURN 'That vehicle is not suspended, so there is nothing to put '
               || 'back — it may simply be awaiting approval.';
      END IF;
    ELSE
      IF NOT v_was THEN
        RETURN 'That image is already hidden.';
      END IF;
      UPDATE public.vehicles SET status = 'SUSPENDED' WHERE id = v_vehicle
        AND status = 'APPROVED';
      IF NOT FOUND THEN
        RETURN 'That vehicle is awaiting approval, not published — there '
               || 'is nothing to hide.';
      END IF;
    END IF;
  END IF;

  INSERT INTO public.moderation_actions
    (action_type, severity, reason, target_user_id, target_provider_id,
     object_bucket, object_path, detail, actioned_by, actioned_by_name)
  VALUES
    (CASE WHEN p_public THEN 'IMAGE_RESTORED' ELSE 'IMAGE_HIDDEN' END,
     'SERIOUS',
     coalesce(btrim(p_reason), 'Hidden from public by an administrator'),
     v_user, v_provider, v_bucket, v_path,
     jsonb_build_object('source', v_source, 'was_public', v_was,
                        'now_public', coalesce(p_public, false)),
     v_actor, v_actor_name);

  RETURN CASE WHEN p_public
    THEN 'It is public again.'
    ELSE 'Hidden from buyers. Nothing was deleted — put it back any time.'
  END;
END;
$$;

COMMENT ON FUNCTION public.admin_set_gallery_image_public(uuid, boolean, text) IS
  'Hide (reversible) or restore one published image. The id may come from '
  'provider_gallery, product_images or vehicle_images — the function works '
  'out which table holds it and flips the visibility switch that table '
  'actually uses, writing every change to moderation_actions. Restores need '
  'a reason; hides do not.';

-- ---------------------------------------------------------------------------
-- 2. The gallery must show a hidden listing as Hidden
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_public_image_gallery(
  p_city text DEFAULT '',
  p_limit integer DEFAULT 120,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  image_id uuid,
  source text,
  bucket text,
  storage_path text,
  caption text,
  is_public boolean,
  uploaded_at timestamptz,
  provider_id uuid,
  provider_name text,
  uploader_user_id uuid,
  uploader_name text,
  city text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city text := lower(btrim(coalesce(p_city, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 120), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  RETURN QUERY
    SELECT g.id, 'provider_gallery'::text, 'provider-gallery'::text,
           g.storage_path, g.caption, g.is_active, g.created_at,
           g.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(pp.city, pr.city, '')
      FROM public.provider_gallery g
      JOIN public.provider_profiles pp ON pp.id = g.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE (v_city = '' OR lower(coalesce(pp.city, pr.city, '')) = v_city)

    UNION ALL

    -- is_public honours BOTH switches since 20261006000010: a listing the
    -- admin hid (is_active = false) must show as Hidden here, or the
    -- moderator cannot see their own takedown and "Hide" looks broken.
    SELECT i.id, 'product_images'::text, 'product-images'::text,
           i.storage_path, NULL::text,
           (p.listing_status = 'ACTIVE' AND p.is_active),
           coalesce(p.updated_at, p.created_at),
           p.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(p.city, pp.city, '')
      FROM public.product_images i
      JOIN public.products p ON p.id = i.product_id
      JOIN public.provider_profiles pp ON pp.id = p.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE to_regclass('public.product_images') IS NOT NULL
       AND (v_city = '' OR lower(coalesce(p.city, pp.city, '')) = v_city)

    UNION ALL

    SELECT i.id, 'vehicle_images'::text, 'vehicle-images'::text,
           i.storage_path, NULL::text, (v.status = 'APPROVED'),
           v.created_at,
           v.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(v.city, pp.city, '')
      FROM public.vehicle_images i
      JOIN public.vehicles v ON v.id = i.vehicle_id
      JOIN public.provider_profiles pp ON pp.id = v.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE to_regclass('public.vehicle_images') IS NOT NULL
       AND (v_city = '' OR lower(coalesce(v.city, pp.city, '')) = v_city)

    ORDER BY 7 DESC
    LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. The assertion Connectivity CI runs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_image_hide_is_reversible()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hide text;
  v_gallery text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_hide
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'admin_set_gallery_image_public'
     AND pg_get_function_identity_arguments(p.oid) =
         'p_image_id uuid, p_public boolean, p_reason text';
  IF v_hide IS NULL THEN
    v_bad := v_bad || ARRAY[
      'admin_set_gallery_image_public(uuid,boolean,text) is missing'];
  ELSE
    IF v_hide NOT ILIKE '%product_images%' THEN
      v_bad := v_bad || ARRAY[
        'Hide does not handle product_images — the product-photo action '
        || 'still dies with NO_SUCH_IMAGE'];
    END IF;
    IF v_hide NOT ILIKE '%vehicle_images%' THEN
      v_bad := v_bad || ARRAY[
        'Hide does not handle vehicle_images — that action is dead too'];
    END IF;
    IF v_hide NOT ILIKE '%moderation_actions%' THEN
      v_bad := v_bad || ARRAY[
        'a hide or restore writes no moderation_actions row — the takedown '
        || 'has no audit trail'];
    END IF;
    IF v_hide NOT ILIKE '%auth.uid()%' THEN
      v_bad := v_bad || ARRAY[
        'the acting administrator is no longer recorded on the action'];
    END IF;
  END IF;

  SELECT prosrc INTO v_gallery
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'admin_public_image_gallery'
     AND pg_get_function_identity_arguments(p.oid) =
         'p_city text, p_limit integer, p_offset integer';
  IF v_gallery IS NULL THEN
    v_bad := v_bad || ARRAY['admin_public_image_gallery is missing'];
  ELSIF v_gallery NOT ILIKE '%p.is_active%' THEN
    v_bad := v_bad || ARRAY[
      'the gallery reports a hidden listing as Public — the moderator '
      || 'cannot see their own takedown'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'hide/restore is not reversible everywhere: %',
      array_to_string(v_bad, '; ');
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_image_hide_is_reversible()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_image_hide_is_reversible() IS
  'True when Hide works for all three image tables, every change is '
  'audited, and the gallery shows hidden listings as hidden.';
