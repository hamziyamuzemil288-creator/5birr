-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Exercises everything 0126 adds, as the right actor and as the wrong one.
-- The fee half is in fee_probe.sql; this is the image half.

\set QUIET on
\set ON_ERROR_STOP off
-- auth.uid() reads this setting, which is how the harness impersonates a role.
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS 'SELECT NULLIF(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
\set QUIET off

DO $$
DECLARE
  v_admin   constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_other   constant uuid := '00000000-0000-4000-8000-0000000000b2';
  v_bajaj   uuid;
  v_image   uuid;
  v_msg     text;
BEGIN
  INSERT INTO auth.users (id, email) VALUES
    (v_admin, 'owner@test'), (v_other, 'other@test')
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.staff (user_id, is_ceo, is_active) VALUES (v_admin, true, true);
  INSERT INTO public.profiles (id, full_name, city) VALUES
    (v_admin, 'Owner', 'addis ababa'),
    (v_other, 'Someone Else', 'hawassa');
  SELECT id INTO v_bajaj FROM public.categories WHERE name = 'Bajaj';

  -- ── IMAGES: one per source table, so the UNION is really exercised ─────
  INSERT INTO public.provider_profiles (id, user_id, business_name, city, status)
  VALUES ('00000000-0000-4000-8000-00000000c001', v_other, 'Bole Repair', 'addis ababa', 'APPROVED'),
         ('00000000-0000-4000-8000-00000000c002', v_other, 'Hawassa Cabs',  'hawassa',      'PENDING');

  INSERT INTO public.provider_gallery (provider_id, storage_path, caption)
  VALUES ('00000000-0000-4000-8000-00000000c001', 'u1/photo-1.jpg', 'Our workshop')
  RETURNING id INTO v_image;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    SELECT count(*) INTO v_msg FROM public.admin_public_image_gallery('');
    RAISE NOTICE 'IMG 1 gallery rows (all cities)  -> %', v_msg;
    SELECT count(*) INTO v_msg FROM public.admin_public_image_gallery('hawassa');
    RAISE NOTICE 'IMG 1 gallery rows (hawassa)    -> %', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 1 gallery                     -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── Hide, then restore ────────────────────────────────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    SELECT public.admin_set_gallery_image_public(v_image, false) INTO v_msg;
    RAISE NOTICE 'IMG 2 hide by admin             -> %', v_msg;
    SELECT is_active INTO v_msg FROM public.provider_gallery WHERE id = v_image;
    RAISE NOTICE 'IMG 2 is_active now             -> %', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 2 hide by admin             -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    SELECT public.admin_set_gallery_image_public(v_image, true, 'Checked, it is fine') INTO v_msg;
    RAISE NOTICE 'IMG 3 restore with no reason    -> %',
      (SELECT public.admin_set_gallery_image_public(v_image, true) );
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 3 restore with no reason    -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── A provider's own unpublish, and someone else's ────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_other::text, false);
    SELECT public.set_gallery_image_public(v_image, false) INTO v_msg;
    RAISE NOTICE 'IMG 4 owner unpublishes          -> %', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 4 owner unpublishes          -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    -- v_admin is a staff row, NOT the owner of provider ...c001.
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    SELECT public.set_gallery_image_public(v_image, true) INTO v_msg;
    RAISE NOTICE 'IMG 5 non-owner publishes        -> ok, RETURNED % (MUST be NOT_YOUR_IMAGE)', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 5 non-owner publishes        -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    -- A photo on a PENDING account: "published" must say so honestly rather
    -- than claim it is now visible, because provider_gallery_public_read also
    -- requires an APPROVED provider.
    UPDATE public.provider_profiles
       SET user_id = v_other, status = 'PENDING'
     WHERE id = '00000000-0000-4000-8000-00000000c001';
    INSERT INTO public.provider_gallery (provider_id, storage_path, caption)
    VALUES ('00000000-0000-4000-8000-00000000c001', 'u1/photo-2.jpg', 'Pending shop')
    RETURNING id INTO v_image;
    -- is_active defaults to true, so unpublish first: otherwise this exercises
    -- the "already published" branch instead of the pending-account message.
    PERFORM public.set_gallery_image_public(v_image, false);
    SELECT public.set_gallery_image_public(v_image, true) INTO v_msg;
    RAISE NOTICE 'IMG 6 publish on a PENDING owner  -> %', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 6 publish on a PENDING owner  -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── The warning ───────────────────────────────────────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    SELECT public.admin_warn_user(v_other, 'Your photo breaks our rules',
                                  'Please replace the photograph of the road junction.') INTO v_msg;
    RAISE NOTICE 'IMG 7 admin warns a user        -> %', v_msg;
    SELECT count(*) INTO v_msg FROM public.moderation_actions WHERE action_type = 'USER_WARNED';
    RAISE NOTICE 'IMG 7 USER_WARNED rows written  -> %', v_msg;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 7 admin warns a user        -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── A non-admin must be refused everywhere ────────────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_other::text, false);
    SELECT public.admin_public_image_gallery('') INTO v_msg;
    RAISE NOTICE 'IMG 8 non-admin reads gallery    -> ok (MUST be ADMIN_ONLY)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 8 non-admin reads gallery    -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_other::text, false);
    SELECT public.admin_warn_user(v_other, 'x', 'y') INTO v_msg;
    RAISE NOTICE 'IMG 9 non-admin warns            -> ok (MUST be ADMIN_ONLY)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'IMG 9 non-admin warns            -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── The three zero-argument reports the connectivity suite will print ──
  RAISE NOTICE 'RPT assert_category_fee_save_plans -> %', public.assert_category_fee_save_plans();
  RAISE NOTICE 'RPT image_moderation_signature    -> %', public.image_moderation_signature_report();
  RAISE NOTICE 'RPT gallery_visibility            -> %', public.gallery_visibility_report();

  -- ── And the log the new verbs write ───────────────────────────────────
  FOR v_msg IN
    SELECT action_type || ' | ' || coalesce(reason, '') FROM public.moderation_actions ORDER BY created_at
  LOOP
    RAISE NOTICE 'LOG %', v_msg;
  END LOOP;
END;
$$;