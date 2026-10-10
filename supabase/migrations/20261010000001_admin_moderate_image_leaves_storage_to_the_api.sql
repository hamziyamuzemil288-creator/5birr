-- 20261010000001 — admin_moderate_image stops pretending it can delete the file
-- =============================================================================
--
-- WHY THE STORAGE DELETE HERE HAS TO GO
-- -------------------------------------
-- 20261006000004 "fixed" the admin image delete by widening the storage delete
-- from `bucket_id = p_bucket` to `bucket_id = ANY (every moderable bucket)`.
-- That repaired the wrong half of the defect: the file was still deleted with
--
--     DELETE FROM storage.objects WHERE name = p_path AND bucket_id = ANY (...);
--
-- a direct write to a storage table, which Supabase refuses outright. Its
-- storage guard is a statement-level trigger, not a privilege check, so it
-- raises
--
--     P0001: Direct deletion from storage tables is not allowed.
--             Use the Storage API instead.
--
-- for EVERY role — anon, authenticated, service_role, and a SECURITY DEFINER
-- function running as the owner alike. The result for an administrator was that
-- the function deleted the DB row, then threw on the object, and the throw
-- rolled the whole transaction back: the screen reported a failure and NOTHING
-- was removed. Only the caller's bucket guess differed; both bodies dead-ended
-- at the same trigger.
--
-- This is the same class of mistake 20261006000004 was written to repair (a
-- storage delete that matched zero rows), one layer deeper: the statement could
-- never match because it was never allowed to run.
--
-- THE FIX, AND WHERE THE FILE ACTUALLY GOES
-- -----------------------------------------
-- The file is removed through the Storage API by the `admin-image-delete` Edge
-- Function, which is the path Supabase's own error message names. It holds the
-- service-role key, so it can remove an object in a bucket whose delete policy
-- is owner-scoped (`auth.uid()::text = (string_to_array(name,'/'))[1]`) — an
-- administrator cannot remove another account's object from the client.
--
-- This function keeps everything it can still do correctly and is still the
-- authority for: the is_admin() gate, the reason requirement, the bucket
-- membership test, the four row-delete branches (provider_gallery /
-- product_images / vehicle_images / profiles.avatar_storage_path), the
-- moderation_actions and audit_logs writes, and the readable return. It is
-- called by the Edge Function with the ADMINISTRATOR'S OWN JWT, so the row
-- write stays server-side (a client that deleted product_images / vehicle_images
-- directly would be writing a table the database declares server-only — exactly
-- the drift client_write_surface_report() exists to catch). The function is
-- otherwise byte-for-byte 20261006000004 with the storage.objects statement
-- removed.
--
-- NEEDS A SUPABASE DEPLOY. Until it is applied, the live function keeps the
-- storage.objects delete and every takedown still fails with the storage
-- guard's P0001 before anything changes.
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
  -- restated unchanged because a CREATE OR REPLACE that dropped it would
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

  -- NO storage.objects write. Supabase refuses a direct delete on a storage
  -- table for every role, so a statement here could only ever abort the whole
  -- takedown (and, where forced through, would remove the metadata row and
  -- leave the file orphaned). The file is removed through the Storage API by
  -- the `admin-image-delete` Edge Function, which calls this function with the
  -- administrator's own JWT and then deletes the object with its service-role
  -- key. The row is deleted here FIRST, so a file-removal failure afterwards
  -- leaves an invisible orphan rather than a row pointing at a missing file.

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
    jsonb_build_object('removed_from', v_removed,
                       'file_removed_by', 'admin-image-delete'),
    v_actor, v_actor_name);

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'CONTENT_IMAGE_REMOVED', 'storage', NULL,
          jsonb_build_object('bucket', p_bucket, 'path', p_path,
                             'removed_from', v_removed,
                             'storage_deleted_by', 'admin-image-delete',
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
