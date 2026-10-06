-- 20261006000004 — the admin image delete actually removes the file
-- =============================================================================
--
-- WHAT WAS BROKEN, REPRODUCED FROM THE EXACT CODE PATH
--
-- The admin taps "Delete image" in Content Control. The UI handler
-- (`_removeImageFromRow` / the ImageDeleteSheet) snapshots bucket+path from
-- an `admin_public_image_gallery` row and calls
-- `admin_moderate_image_with_reason(p_bucket, p_path, ...)` (0141), which
-- delegates to `admin_moderate_image` (0122). That function:
--
--   1. enforces is_admin() and a non-empty reason        — fine (0122 fixed
--      the `<> ANY` membership bug and the actor-name NULLing);
--   2. deletes the DB row by `storage_path = p_path`     — fine, path-only;
--   3. deletes the storage object with
--        DELETE FROM storage.objects
--         WHERE bucket_id = p_bucket AND name = p_path;
--      — THIS is the defect the earlier fixes did not reach.
--
-- Step 3 trusts `p_bucket` to be the bucket the object actually lives in.
-- The client has TWO ways of producing it:
--
--   * the gallery strip passes the row's own `bucket` column — correct;
--   * `_removeImage(path)` RECOVERS the bucket from the path's shape via
--     `_bucketFor()`, a chain of substring guesses (`/photo` → provider-
--     gallery, `/product` → product-images, ...). The real upload paths are
--     `uid/<productId>/<file>` (product form) and `uid/<imageId>/<file>`
--     (gallery) — a uuid folder containing none of those words — so every
--     product and vehicle image fell through to the default
--     'provider-gallery' and the storage delete matched ZERO rows.
--
-- Consequence: the DB row went, the grid refreshed, the admin was told
-- "provider_gallery" — and the FILE stayed in the bucket forever, with the
-- moderation audit recording a bucket the object was never in. "Images are
-- not deleting" is exactly what an admin sees when they check storage, or
-- when a later gallery read resurrects the object through a stale path.
--
-- THE FIX, AND WHY IT IS SAFE
--
-- The storage delete no longer trusts the caller's bucket at all. Every
-- upload path in this project is `<uid>/<folder>/<file>` and unique per
-- object, so the object is deleted from EVERY moderable bucket by name:
--
--     DELETE FROM storage.objects
--      WHERE name = p_path
--        AND bucket_id = ANY (the moderable list)
--
-- A wrong or stale `p_bucket` can therefore no longer strand a file, and
-- the row deletes (path-only, unchanged) still decide WHICH table the image
-- came from. The audit row keeps the caller's bucket for the record, and
-- the `removed_from` detail still names the table the row was deleted from.
--
-- Everything else in the function is verbatim from 0122: the is_admin()
-- gate, the reason requirement, the bucket membership test, the four row
-- delete branches (provider_gallery / product_images / vehicle_images /
-- profiles.avatar_storage_path), the NO_ROW refusal, the moderation_actions
-- and audit_logs writes, and the readable return. The grants are restated
-- for the record.
--
-- NEEDS A SUPABASE DEPLOY. Until it is applied, the live function keeps the
-- single-bucket delete and files can still be stranded; the client half of
-- this fix (the guessing helper is gone, friendly_error now shows the
-- server's real reason) ships in the app regardless.
-- =============================================================================

SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.admin_moderate_image(
  p_bucket text,
  p_path   text,
  p_reason text,
  p_severity text DEFAULT 'MODERATE'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_removed  text := '';
  v_owner    uuid;
  v_prov     uuid;
  v_actor    uuid;
  v_actor_name text := '';
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'A_REASON_IS_REQUIRED';
  END IF;

  -- `<> ALL`, NOT `<> ANY` — the membership test 0122 already repaired;
  -- restated unchanged because a CREATE OR_REPLACE that dropped it would
  -- resurrect the THAT_BUCKET_IS_NOT_MODERABLE dead end.
  IF p_bucket IS NULL OR p_bucket <> ALL (ARRAY[
       'provider-photos', 'provider-gallery', 'product-images',
       'vehicle-images', 'profile-avatars']) THEN
    RAISE EXCEPTION 'THAT_BUCKET_IS_NOT_MODERABLE';
  END IF;

  IF p_path IS NULL OR btrim(p_path) = '' THEN
    RAISE EXCEPTION 'A_PATH_IS_REQUIRED';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;

  -- Every image table this project has, in the order it is tried. Each is
  -- guarded by to_regclass so a table dropped by a later migration makes this
  -- skip rather than abort the whole call. The DB-row delete matches on the
  -- PATH only — a row's truth is its storage_path, not the caller's bucket
  -- guess — exactly as 0122 had it.
  IF to_regclass('public.provider_gallery') IS NOT NULL THEN
    DELETE FROM public.provider_gallery
     WHERE storage_path = p_path
    RETURNING provider_id INTO v_prov;
    IF v_prov IS NOT NULL THEN
      v_removed := 'provider_gallery';
    END IF;
  END IF;

  IF v_removed = '' AND to_regclass('public.product_images') IS NOT NULL THEN
    DELETE FROM public.product_images
     WHERE storage_path = p_path
    RETURNING (SELECT p.provider_id FROM public.products p
                WHERE p.id = product_images.product_id) INTO v_prov;
    IF v_prov IS NOT NULL THEN
      v_removed := 'product_images';
    END IF;
  END IF;

  IF v_removed = '' AND to_regclass('public.vehicle_images') IS NOT NULL THEN
    DELETE FROM public.vehicle_images
     WHERE storage_path = p_path
    RETURNING (SELECT v.provider_id FROM public.vehicles v
                WHERE v.id = vehicle_images.vehicle_id) INTO v_prov;
    IF v_prov IS NOT NULL THEN
      v_removed := 'vehicle_images';
    END IF;
  END IF;

  IF v_removed = '' AND EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'profiles'
           AND column_name = 'avatar_storage_path') THEN
    UPDATE public.profiles
       SET avatar_storage_path = NULL
     WHERE avatar_storage_path = p_path
    RETURNING id INTO v_owner;
    IF v_owner IS NOT NULL THEN
      v_removed := 'profiles.avatar_storage_path';
    END IF;
  END IF;

  IF v_removed = '' THEN
    RAISE EXCEPTION 'NO_ROW_REFERENCES_THAT_IMAGE:%', p_path;
  END IF;

  -- THE FIX. The object is removed from EVERY moderable bucket by name,
  -- because upload paths are uid-prefixed and unique: a wrong p_bucket from
  -- an older client, a stale strip row or a path-shape guess can no longer
  -- strand the file while the row is deleted. Same to_regclass guard as
  -- 0122.
  IF to_regclass('storage.objects') IS NOT NULL THEN
    DELETE FROM storage.objects
     WHERE name = p_path
       AND bucket_id = ANY (ARRAY[
             'provider-photos', 'provider-gallery', 'product-images',
             'vehicle-images', 'profile-avatars']);
  END IF;

  -- The owner of the removed image, so the record says whose it was.
  IF v_prov IS NOT NULL THEN
    SELECT pp.user_id INTO v_owner FROM public.provider_profiles pp WHERE pp.id = v_prov;
  END IF;

  -- The actor's name must be written UNCONDITIONALLY (0122's finding): a
  -- SELECT ... INTO matching no row sets the target to NULL, overwriting the
  -- '' default, and actioned_by_name is NOT NULL.
  v_actor_name := coalesce(v_actor_name, '');

  INSERT INTO public.moderation_actions (
    action_type, severity, reason, target_user_id, target_provider_id,
    object_bucket, object_path, detail, actioned_by, actioned_by_name)
  VALUES (
    'IMAGE_REMOVED', coalesce(nullif(p_severity, ''), 'MODERATE'), btrim(p_reason),
    v_owner, v_prov, p_bucket, p_path,
    jsonb_build_object('removed_from', v_removed), v_actor, v_actor_name);

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'CONTENT_IMAGE_REMOVED', 'storage', NULL,
          jsonb_build_object('bucket', p_bucket, 'path', p_path,
                             'removed_from', v_removed,
                             'storage_deleted_from_all_buckets', true,
                             'reason', btrim(p_reason)));

  RETURN 'ok: removed ' || p_path || ' from ' || v_removed;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_moderate_image(text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_moderate_image(text, text, text, text)
  TO authenticated, service_role;

-- The with_reason wrapper (0141) delegates to this function and is
-- unchanged; its grant is restated only because a CREATE OR REPLACE of the
-- inner function must never leave the outer path unreachable.
GRANT EXECUTE ON FUNCTION public.admin_moderate_image_with_reason(text, text, text, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
