-- Provider gallery writes, owner-scoped.
--
-- WHAT EXISTED
-- ------------
-- provider_gallery has existed since 0013 with a complete set of owner RLS
-- policies (0014/0022b) and owner-scoped storage policies on the
-- `provider-gallery` bucket (0017). ProviderGalleryImage has existed in Dart
-- since the model was written. Nothing read or wrote the table: the app had no
-- gallery screen, so the table was empty and the model was dead code.
--
-- WHY THIS IS A FUNCTION AND NOT A DIRECT INSERT
-- ----------------------------------------------
-- 20260927000050 closed the client write surface: anon and authenticated lost
-- INSERT/UPDATE/DELETE/TRUNCATE on every public table outside the twenty the
-- app writes, and provider_gallery was one of the twenty-one it revoked. Its
-- owner RLS policies are now unreachable by a client, which is exactly the
-- point of that migration -- a grant nobody needs is half of the pair that
-- makes a policy mistake exploitable.
--
-- The app genuinely needs to write here now, so the write goes back as a
-- SECURITY DEFINER function rather than as a grant. That keeps the invariant
-- "a client may write the twenty tables the app writes, and nothing else"
-- literally true, and it puts the ownership check in one place instead of
-- relying on a policy the caller is not allowed to reach.
--
-- READS STAY DIRECT
-- ------------------
-- SELECT was never revoked, and provider_gallery_owner_read /
-- provider_gallery_public_read already scope it. Reading a gallery is a plain
-- client read, exactly as it was, and needs no function.

-- ===========================================================================
-- 1. Add an image
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.add_gallery_image(
  p_provider_id uuid,
  p_storage_path text,
  p_caption text DEFAULT NULL,
  p_display_order integer DEFAULT NULL
)
RETURNS public.provider_gallery
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_image public.provider_gallery;
  v_next integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF NOT public.owns_provider_profile(p_provider_id) THEN
    RAISE EXCEPTION 'NOT_YOUR_PROFILE';
  END IF;

  IF p_storage_path IS NULL OR btrim(p_storage_path) = '' THEN
    RAISE EXCEPTION 'STORAGE_PATH_REQUIRED';
  END IF;

  -- The storage policies on `provider-gallery` scope every write to
  -- auth.uid()::text = (string_to_array(name, '/'))[1], so an object uploaded
  -- outside the caller's own folder is unviewable and undeletable even though
  -- the upload succeeded. Refusing the row here means the two halves can never
  -- disagree: a gallery row always points at an object its owner can manage.
  IF (string_to_array(btrim(p_storage_path), '/'))[1] IS DISTINCT FROM auth.uid()::text THEN
    RAISE EXCEPTION 'STORAGE_PATH_NOT_OWNED';
  END IF;

  -- Append to the end when the caller does not say where it goes.
  v_next := coalesce(p_display_order, (
    SELECT coalesce(max(g.display_order), -1) + 1
      FROM public.provider_gallery g
     WHERE g.provider_id = p_provider_id));

  INSERT INTO public.provider_gallery
    (provider_id, storage_path, caption, display_order, is_active)
  VALUES
    (p_provider_id, btrim(p_storage_path),
     NULLIF(btrim(coalesce(p_caption, '')), ''), v_next, true)
  RETURNING * INTO v_image;

  RETURN v_image;
END;
$$;

-- ===========================================================================
-- 2. Delete an image
-- ===========================================================================
-- The row goes; the stored object is left alone on purpose. Storage deletes
-- are irreversible and the bucket is PUBLIC-read, so a path that some other
-- listing still references is better left on disk than silently broken. The
-- gallery row is what the app shows, and it is what "remove this photo" means.
CREATE OR REPLACE FUNCTION public.delete_gallery_image(p_image_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT provider_id INTO v_owner
    FROM public.provider_gallery g
   WHERE g.id = p_image_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_owner) THEN
    RAISE EXCEPTION 'NOT_YOUR_IMAGE';
  END IF;

  DELETE FROM public.provider_gallery g WHERE g.id = p_image_id;
  RETURN true;
END;
$$;

-- ===========================================================================
-- 3. Caption / reorder
-- ===========================================================================
-- The display_order column and idx_provider_gallery_order already existed and
-- nothing could ever set them, which is why the table was unusable as a
-- gallery. One function covers both fields so ordering has a single owner.
CREATE OR REPLACE FUNCTION public.update_gallery_image(
  p_image_id uuid,
  p_caption text DEFAULT NULL,
  p_display_order integer DEFAULT NULL
)
RETURNS public.provider_gallery
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_image public.provider_gallery;
  v_owner uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT g.* INTO v_image FROM public.provider_gallery g WHERE g.id = p_image_id;
  IF v_image.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;

  v_owner := v_image.provider_id;
  IF NOT public.owns_provider_profile(v_owner) THEN
    RAISE EXCEPTION 'NOT_YOUR_IMAGE';
  END IF;

  UPDATE public.provider_gallery g
     SET caption = CASE
                     WHEN p_caption IS NULL THEN g.caption
                     ELSE NULLIF(btrim(p_caption), '')
                   END,
         display_order = coalesce(p_display_order, g.display_order),
         updated_at = now()
   WHERE g.id = p_image_id
   RETURNING * INTO v_image;

  RETURN v_image;
END;
$$;

-- ===========================================================================
-- 4. Grants
-- ===========================================================================
REVOKE ALL ON FUNCTION public.add_gallery_image(uuid, text, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_gallery_image(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_gallery_image(uuid, text, integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.add_gallery_image(uuid, text, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_gallery_image(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_gallery_image(uuid, text, integer) TO authenticated;

NOTIFY pgrst, 'reload schema';
