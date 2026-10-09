-- 20261009000002 — client-side image delete needs two server helpers
-- =============================================================================
--
-- WHY THIS EXISTS
-- ---------------
-- The client-side image-delete path (PublicImageGallery._remove and
-- ImageDeleteSheet._remove) now goes through the Supabase Storage API
-- (storage.from(bucket).remove([path])) instead of calling the server RPC
-- admin_moderate_image / admin_moderate_image_with_reason. That is because
-- the live database still runs the PRE-FIX body of admin_moderate_image
-- (migration 20261006000004 is behindsupabase/DEPLOYED_HEAD), and that body
-- writes directly to storage.objects — which Supabase's storage RLS trigger
-- blocks with P0001 ("Direct deletion from storage tables is not allowed.
-- Use the Storage API instead.").
--
-- The Storage API call handles step 1 (remove the file). But the client
-- still needs help with:
--   2. deleting the app's own row that references the file, and
--   3. writing the moderation_actions audit entry.
--
-- Step 2: admin_delete_provider_gallery_by_path
--   provider_gallery is RLS-protected (provider_gallery_public_read,
--   provider_gallery_admin_write). An admin acting through the client
--   cannot DELETE from it directly — the RLS policy blocks it. So we need a
--   SECURITY DEFINER RPC that deletes by storage_path and returns the count.
--   The client deletes product_images and vehicle_images directly because
--   those tables' RLS policies already allow authenticated writers.
--
-- Step 3: admin_log_moderation_action
--   moderation_actions is append-only with no edit/delete RLS policy (see
--   20260927000122). Only admins may insert. This RPC enforces is_admin()
--   and writes the row, so the client does not need service_role rights.
--
-- Both functions are thin wrappers. The real guarantee — file, row, every
-- reference, plus an audit entry — is assembled client-side in the two
-- callers, which call Storage API → row delete → audit in order.

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Delete a provider_gallery row by storage_path (RLS-safe for admins)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_delete_provider_gallery_by_path(
  p_path text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_path IS NULL OR btrim(p_path) = '' THEN
    RAISE EXCEPTION 'A_PATH_IS_REQUIRED';
  END IF;

  DELETE FROM public.provider_gallery
   WHERE storage_path = p_path;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_provider_gallery_by_path(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_provider_gallery_by_path(text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Append a moderation_actions row (admin-only, append-only table)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.admin_log_moderation_action(
  p_action_type text,
  p_severity    text,
  p_reason      text,
  p_object_bucket  text DEFAULT NULL,
  p_object_path    text DEFAULT NULL,
  p_target_user_id uuid DEFAULT NULL,
  p_target_provider_id uuid DEFAULT NULL,
  p_detail      jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor    uuid;
  v_actor_name text := '';
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;
  v_actor_name := coalesce(v_actor_name, '');

  INSERT INTO public.moderation_actions
    (action_type, severity, reason,
     target_user_id, target_provider_id,
     object_bucket, object_path, detail,
     actioned_by, actioned_by_name)
  VALUES
    (p_action_type, coalesce(nullif(p_severity, ''), 'MODERATE'),
     btrim(coalesce(p_reason, '')),
     p_target_user_id, p_target_provider_id,
     p_object_bucket, p_object_path, p_detail,
     v_actor, v_actor_name);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_log_moderation_action(
  text, text, text, text, text, uuid, uuid, jsonb
)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_log_moderation_action(
  text, text, text, text, text, uuid, uuid, jsonb
)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
