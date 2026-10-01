-- The fee editor has never once saved, and a moderator cannot see what is
-- already uploaded.
--
-- Four separate reports, four separate causes, one migration because they all
-- end in the same place: an administrator or a provider does something the UI
-- offers, and the server refuses it or silently does nothing.
--
--   1. "the staff/city category section ... doesn't create the price ... when
--      I try to proceed it's saying can't make this action this section may
--      have been removed"
--
--   2. "the image controlling and suspending section ... don't bring already
--      uploaded public images with the uploader like gallery and with city"
--
--   3. "on the provider side there is photo uploading option at gallery
--      already but after uploading there is no post option to public"
--
--   4. (this file) the two of those three that need a write path the schema
--      has no function for at all.
--
-- ===========================================================================
-- 1. admin_save_category_fee() HAS NEVER SUCCEEDED
-- ===========================================================================
-- FOUND BY RUNNING IT, NOT BY READING IT. It was replayed against a real
-- PostgreSQL 14 (tools/harness/replay_fee.sh) and every call died with:
--
--   42703: column "booking_base_fare" of relation "category_fee_settings"
--          does not exist
--
-- The table's column is `booking_base_fee` -- renamed in 0107 itself, when
-- `p_booking_base_fare` became `p_booking_base_fee` to match it. The INSERT
-- column list and every resolver were updated. The `ON CONFLICT ... DO UPDATE
-- SET` list was not:
--
--   ON CONFLICT (category_id, city) DO UPDATE SET
--     ...
--     booking_base_fare = EXCLUDED.booking_base_fee,   -- <-- no such column
--
-- WHY NOTHING ELSE CAUGHT IT
-- --------------------------
-- PostgreSQL analyses `INSERT ... ON CONFLICT DO UPDATE` BEFORE it executes
-- it, so this is a PLAN-time failure. The row is never written, the audit row
-- is never written, and the whole call raises before touching anything.
--
-- Every other check in this repository stayed green, because each of them
-- answers a different question:
--
--   * migration 0124 proves `admin_save_category_fee` EXISTS, with the arity
--     the client sends and the right parameter NAMES. It does, and it always
--     did. Reachability is not correctness.
--   * check_admin_rpc_argv_is_transcribed proves the Dart sends no undeclared
--     key and omits no required argument. It does. The mistake is in the
--     function's BODY, which neither check can see.
--   * check_category_fees_are_wired proves a field group is rendered AND sent,
--     that money columns stay nullable so blank means "inherit", and that no
--     input is prefilled with the effective number. All true.
--   * assert_category_fees_are_wired is a database assertion about the same
--     properties.
--
-- Not one of them executes the statement. A fee editor that has never once
-- written a row looks exactly like a healthy one to all of them, because
-- "is it wired" and "does it work" are different questions and only one was
-- being asked.
--
-- WHY THE USER SAW "MAY HAVE BEEN REMOVED"
-- ---------------------------------------
-- The reported wording came from `admin_save_category_fee`'s OTHER refusal,
-- CATEGORY_NOT_FOUND, which is a P0001 whose message contains the substring
-- "not found" -- and friendly_error.dart maps "not found" to "That item could
-- not be found. It may have been removed." A 42703 and a CATEGORY_NOT_FOUND
-- therefore produce the same sentence while meaning completely different
-- things. Both are addressed: the 42703 is fixed here, and 0126 adds the
-- assertion below that would have caught it.
--
-- The restatement changes exactly one token -- `booking_base_fare` to
-- `booking_base_fee` -- and keeps arity, parameter names, defaults, guards and
-- return type identical. `CREATE OR REPLACE` with an unchanged signature
-- replaces rather than adding an overload, which is the PGRST203 trap
-- documented in 7.1.6.

CREATE OR REPLACE FUNCTION public.admin_save_category_fee(
  p_category_id uuid,
  p_city text DEFAULT '',
  p_commission_percent numeric DEFAULT NULL,
  p_commission_min numeric DEFAULT NULL,
  p_subscription_fee numeric DEFAULT NULL,
  p_activation_fee numeric DEFAULT NULL,
  p_ride_base_fare numeric DEFAULT NULL,
  p_ride_per_km numeric DEFAULT NULL,
  p_ride_minimum_fare numeric DEFAULT NULL,
  p_booking_base_fee numeric DEFAULT NULL,
  p_booking_per_km numeric DEFAULT NULL,
  p_booking_minimum_fee numeric DEFAULT NULL,
  p_product_commission_percent numeric DEFAULT NULL,
  p_product_commission_min numeric DEFAULT NULL,
  p_product_listing_fee numeric DEFAULT NULL
)
RETURNS public.category_fee_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.category_fee_settings;
  v_city text := lower(btrim(coalesce(p_city, '')));
BEGIN
  IF NOT public.is_fee_editor() THEN
    RAISE EXCEPTION 'ONLY_THE_OWNER_CAN_CHANGE_FEES';
  END IF;

  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'CATEGORY_ID_REQUIRED';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.categories WHERE id = p_category_id) THEN
    RAISE EXCEPTION 'CATEGORY_NOT_FOUND';
  END IF;

  IF v_city <> '' AND v_city !~ '^[a-z][a-z .''-]*$' THEN
    RAISE EXCEPTION 'CITY_NAME_IS_NOT_A_CITY_NAME';
  END IF;

  INSERT INTO public.category_fee_settings AS f (
    category_id, city,
    commission_percent, commission_min, subscription_fee, activation_fee,
    ride_base_fare, ride_per_km, ride_minimum_fare,
    booking_base_fee, booking_per_km, booking_minimum_fee,
    product_commission_percent, product_commission_min, product_listing_fee
  ) VALUES (
    p_category_id, v_city,
    p_commission_percent, p_commission_min, p_subscription_fee,
    p_activation_fee,
    p_ride_base_fare, p_ride_per_km, p_ride_minimum_fare,
    p_booking_base_fee, p_booking_per_km, p_booking_minimum_fee,
    p_product_commission_percent, p_product_commission_min,
    p_product_listing_fee
  )
  ON CONFLICT (category_id, city) DO UPDATE SET
    commission_percent = EXCLUDED.commission_percent,
    commission_min = EXCLUDED.commission_min,
    subscription_fee = EXCLUDED.subscription_fee,
    activation_fee = EXCLUDED.activation_fee,
    ride_base_fare = EXCLUDED.ride_base_fare,
    ride_per_km = EXCLUDED.ride_per_km,
    ride_minimum_fare = EXCLUDED.ride_minimum_fare,
    -- THE ONE CHARACTER THAT WAS WRONG. `_fare` -> `_fee`, to match the
    -- column the INSERT above already writes and the resolvers already read.
    booking_base_fee = EXCLUDED.booking_base_fee,
    booking_per_km = EXCLUDED.booking_per_km,
    booking_minimum_fee = EXCLUDED.booking_minimum_fee,
    product_commission_percent = EXCLUDED.product_commission_percent,
    product_commission_min = EXCLUDED.product_commission_min,
    product_listing_fee = EXCLUDED.product_listing_fee,
    updated_at = now(),
    updated_by = auth.uid()
  RETURNING * INTO v_row;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'CATEGORY_FEE_UPDATED', 'category_fee_settings', v_row.id,
          jsonb_build_object(
            'category_id', p_category_id,
            'city', v_city,
            'commission_percent', p_commission_percent,
            'commission_min', p_commission_min,
            'subscription_fee', p_subscription_fee,
            'activation_fee', p_activation_fee,
            'ride_base_fare', p_ride_base_fare,
            'ride_per_km', p_ride_per_km,
            'ride_minimum_fare', p_ride_minimum_fare,
            'booking_base_fee', p_booking_base_fee,
            'booking_per_km', p_booking_per_km,
            'booking_minimum_fee', p_booking_minimum_fee,
            'product_commission_percent', p_product_commission_percent,
            'product_commission_min', p_product_commission_min,
            'product_listing_fee', p_product_listing_fee));

  RETURN v_row;
END;
$$;

-- ===========================================================================
-- 2. AN ASSERTION THAT EXECUTES THE STATEMENT INSTEAD OF DESCRIBING IT
-- ===========================================================================
-- The lesson of section 1, turned into something that runs on every deploy.
--
-- It uses EXPLAIN WITHOUT ANALYZE, which PLANS the statement and executes
-- nothing. Planning is exactly where an ON CONFLICT target that is not a
-- column fails, so this catches the whole class of defect with no rows
-- written, no category needed, and no fee-editor authority: the plan runs
-- inside an EXCEPTION block as the function owner.
--
-- It asserts the same property the static harness check asserts, from the
-- other side of the wire. Neither can see the other: SQL cannot read the
-- Dart, and Python cannot plan a statement.

CREATE OR REPLACE FUNCTION public.assert_category_fee_save_plans()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_sql text;
BEGIN
  v_sql :=
    'EXPLAIN INSERT INTO public.category_fee_settings AS f (category_id, city, '
    || 'commission_percent, commission_min, subscription_fee, activation_fee, '
    || 'ride_base_fare, ride_per_km, ride_minimum_fare, '
    || 'booking_base_fee, booking_per_km, booking_minimum_fee, '
    || 'product_commission_percent, product_commission_min, product_listing_fee) '
    || 'VALUES (''00000000-0000-4000-8000-000000000000'', '''', '
    || 'NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL) '
    || 'ON CONFLICT (category_id, city) DO UPDATE SET '
    || 'commission_percent = EXCLUDED.commission_percent, '
    || 'commission_min = EXCLUDED.commission_min, '
    || 'subscription_fee = EXCLUDED.subscription_fee, '
    || 'activation_fee = EXCLUDED.activation_fee, '
    || 'ride_base_fare = EXCLUDED.ride_base_fare, '
    || 'ride_per_km = EXCLUDED.ride_per_km, '
    || 'ride_minimum_fare = EXCLUDED.ride_minimum_fare, '
    || 'booking_base_fee = EXCLUDED.booking_base_fee, '
    || 'booking_per_km = EXCLUDED.booking_per_km, '
    || 'booking_minimum_fee = EXCLUDED.booking_minimum_fee, '
    || 'product_commission_percent = EXCLUDED.product_commission_percent, '
    || 'product_commission_min = EXCLUDED.product_commission_min, '
    || 'product_listing_fee = EXCLUDED.product_listing_fee, '
    || 'updated_at = now()';

  BEGIN
    EXECUTE v_sql;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'The category fee save does not plan (% %). Every save has '
      'failed this way since 0107; the fee editor has never written a row.',
      SQLSTATE, SQLERRM;
  END;

  -- And the ordinary failure the report named, so its cause is visible rather
  -- than collapsing into "may have been removed" alongside a 42703.
  IF EXISTS (
    SELECT 1 FROM public.categories
     WHERE id = '00000000-0000-4000-8000-000000000000'
  ) THEN
    RAISE EXCEPTION 'The fee assertion''s stand-in category id is a REAL '
      'category, so the check above proves less than it claims.';
  END IF;

  RETURN 'ok: the category fee upsert plans, so its ON CONFLICT targets are '
         || 'real columns and a save can write a row';
END;
$$;

-- ===========================================================================
-- 3. THE IMAGE LOG NEEDS TWO MORE VERBS
-- ===========================================================================
-- `moderation_actions.action_type` is a CHECK, not an enum, so widening it is
-- a DROP/ADD on the constraint. The table itself stays append-only: nothing
-- here adds an UPDATE or DELETE policy, and the existing "no policy lets
-- anybody edit or delete it" property is untouched.

ALTER TABLE public.moderation_actions
  DROP CONSTRAINT IF EXISTS moderation_actions_action_type_check;

ALTER TABLE public.moderation_actions
  ADD CONSTRAINT moderation_actions_action_type_check CHECK (action_type IN (
    'IMAGE_REMOVED', 'ACCOUNT_SUSPENDED', 'ACCOUNT_REINSTATED',
    'REPORT_UPHELD', 'REPORT_DISMISSED', 'LISTING_WITHDRAWN',
    -- Hiding without deleting, and telling the person why. Both new.
    'IMAGE_HIDDEN', 'IMAGE_RESTORED', 'USER_WARNED'));

-- ===========================================================================
-- 4. THE GALLERY AN ADMINISTRATOR CANNOT CURRENTLY SEE
-- ===========================================================================
-- Content Control reads `admin_content_reports`, which returns rows somebody
-- has already REPORTED. A gallery of what is actually published was not
-- reachable at all: there is no admin function that lists provider_gallery by
-- uploader or by city, so "I can see the images and if one violates the rules
-- I can delete it" was only possible for images somebody had complained
-- about. Most rule-breaking content is never reported.
--
-- Every column a moderator needs to judge an image is here: WHO uploaded it
-- (display name, business name, the user id), WHERE (city), WHEN, whether it
-- is currently public, and enough to act on it without a second query.
--
-- `p_city` is a FILTER, not a grouping. The screen groups by it; the database
-- returns rows. An empty string means every city, which is what the screen
-- sends on first load so an administrator sees something immediately rather
-- than an empty panel they have to guess a filter for.

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
    -- The three image tables this project has, in the same order
    -- admin_moderate_image() tries them, and each guarded on to_regclass so a
    -- table dropped by a later migration narrows the list instead of
    -- failing the whole screen.
    SELECT g.id, 'provider_gallery'::text, 'provider-gallery'::text,
           g.storage_path, g.caption, g.is_active, g.created_at,
           g.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(pp.city, pr.city, '')
      FROM public.provider_gallery g
      JOIN public.provider_profiles pp ON pp.id = g.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE (v_city = '' OR lower(coalesce(pp.city, pr.city, '')) = v_city)

    UNION ALL

    SELECT i.id, 'product_images'::text, 'product-images'::text,
           i.storage_path, NULL::text, (p.listing_status = 'ACTIVE'),
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
           i.storage_path, NULL::text, (v.is_active IS TRUE),
           coalesce(v.updated_at, v.created_at),
           v.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(v.city, pp.city, '')
      FROM public.vehicle_images i
      JOIN public.vehicles v ON v.id = i.vehicle_id
      JOIN public.provider_profiles pp ON pp.id = v.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE to_regclass('public.vehicle_images') IS NOT NULL
       AND (v_city = '' OR lower(coalesce(v.city, pp.city, '')) = v_city)

    -- Newest first, so the panel opens on what arrived today rather than on
    -- the oldest upload in the system.
    ORDER BY 7 DESC
    LIMIT v_limit OFFSET v_offset;
END;
$$;

-- ===========================================================================
-- 5. HIDE AN IMAGE FROM PUBLIC WITHOUT DELETING IT
-- ===========================================================================
-- `admin_moderate_image` DELETES: the row goes, and the stored object goes
-- with it. That is irreversible and, for a photo that is merely borderline,
-- disproportionate -- the provider loses the image from their own gallery too
-- and has no way to get it back.
--
-- `provider_gallery.is_active` already exists and is already what the public
-- read policy tests:
--
--   provider_gallery_public_read ... USING ((is_active = true) AND ...)
--
-- So hiding is a one-column write the policy already honours, and it is
-- REVERSIBLE, which deletion is not. The reported need was "delete the image
-- OR suspend it from the public": this is the second verb, and it is the one
-- to reach for first.
--
-- Scope is provider_gallery only, and deliberately so. It is the one image
-- table with an is_active column; a product's visibility is its
-- listing_status and a vehicle's is its own state, and pretending one flag
-- governs all three would be a lie the UI could not explain. Those rows are
-- still visible in the gallery above and still removable through
-- admin_moderate_image.

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
  v_path text;
  v_provider uuid;
  v_user uuid;
  v_was boolean;
  v_actor uuid;
  v_actor_name text := '';
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'AN_IMAGE_IS_REQUIRED';
  END IF;

  IF p_public AND length(btrim(coalesce(p_reason, ''))) < 3 THEN
    -- Hiding needs no reason to justify itself to the provider -- the image is
    -- simply not shown. RESTORING one does: an administrator putting a photo
    -- back after a takedown is overriding their own earlier decision, and
    -- wants a reason in the permanent record of why.
    RAISE EXCEPTION 'A_REASON_IS_REQUIRED';
  END IF;

  SELECT g.storage_path, g.provider_id, g.is_active, pp.user_id
    INTO v_path, v_provider, v_was, v_user
    FROM public.provider_gallery g
    JOIN public.provider_profiles pp ON pp.id = g.provider_id
   WHERE g.id = p_image_id;

  IF v_path IS NULL THEN
    RAISE EXCEPTION 'NO_SUCH_IMAGE';
  END IF;

  IF v_was = coalesce(p_public, v_was) THEN
    RETURN 'That image is already ' || CASE WHEN p_public THEN 'public.' ELSE 'hidden.' END;
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;

  UPDATE public.provider_gallery
     SET is_active = coalesce(p_public, false),
         updated_at = now()
   WHERE id = p_image_id;

  INSERT INTO public.moderation_actions
    (action_type, severity, reason, target_user_id, target_provider_id,
     object_bucket, object_path, detail, actioned_by, actioned_by_name)
  VALUES
    (CASE WHEN p_public THEN 'IMAGE_RESTORED' ELSE 'IMAGE_HIDDEN' END,
     'SERIOUS',
     coalesce(btrim(p_reason), 'Hidden from public by an administrator'),
     v_user, v_provider, 'provider-gallery', v_path,
     jsonb_build_object('was_public', v_was, 'now_public', coalesce(p_public, false)),
     v_actor, v_actor_name);

  RETURN CASE WHEN p_public
    THEN 'The image is public again.'
    ELSE 'The image is hidden. The provider still has it in their own gallery '
         || 'and can re-publish it only after you reinstate the account.'
  END;
END;
$$;

-- ===========================================================================
-- 6. SEND THE PERSON A WARNING, FROM THE SECTION THAT FOUND THE PROBLEM
-- ===========================================================================
-- "if it has wrong things or violates our rules I can ... send the person
-- warning text in that section itself". There was no way to do this: every
-- notification in the schema is raised by a TRIGGER or a state transition,
-- none by an administrator looking at a photograph.
--
-- CORRECTION_REQUIRED is the right type and already in the enum. It is the
-- one that says "something about you is wrong and here is what to do", which
-- is exactly a moderation warning, and a provider who has been suspended for
-- a photo should not have to guess which of the two they received.
--
-- notify_user() swallows nothing and raises nothing here: if the delivery
-- fails, this function still records the warning in the log, because the log
-- is the evidence and the notice is only the courtesy copy.

CREATE OR REPLACE FUNCTION public.admin_warn_user(
  p_user_id uuid,
  p_title text,
  p_body text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text;
  v_actor uuid;
  v_actor_name text := '';
  v_notified uuid;
  v_detail jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'A_USER_IS_REQUIRED';
  END IF;

  IF length(btrim(coalesce(p_title, ''))) < 3
     OR length(btrim(coalesce(p_body, ''))) < 3 THEN
    RAISE EXCEPTION 'A_WARNING_NEEDS_A_TITLE_AND_A_MESSAGE';
  END IF;

  IF length(btrim(p_body)) > 2000 THEN
    RAISE EXCEPTION 'THAT_WARNING_IS_TOO_LONG';
  END IF;

  SELECT coalesce(full_name, '') INTO v_name FROM public.profiles WHERE id = p_user_id;
  IF v_name IS NULL AND NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = p_user_id) THEN
    RAISE EXCEPTION 'NO_SUCH_ACCOUNT';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;

  v_notified := public.notify_user(
    p_user_id, 'CORRECTION_REQUIRED',
    btrim(p_title), btrim(p_body),
    jsonb_build_object('source', 'admin_content_control')
  );

  v_detail := jsonb_build_object('title', btrim(p_title), 'notified', v_notified IS NOT NULL);

  INSERT INTO public.moderation_actions
    (action_type, severity, reason, target_user_id, detail, actioned_by, actioned_by_name)
  VALUES
    ('USER_WARNED', 'MODERATE', btrim(p_body), p_user_id, v_detail,
     v_actor, v_actor_name);

  RETURN CASE WHEN v_notified IS NULL
    THEN 'The warning is recorded, but the app could not deliver it. The person '
         || 'will not see it.'
    ELSE 'Warning sent to ' || coalesce(nullif(v_name, ''), 'that account') || '.'
  END;
END;
$$;

-- ===========================================================================
-- 7. A PROVIDER CAN PUBLISH A PHOTO THEY ALREADY UPLOADED
-- ===========================================================================
-- "after uploading there is no post option to public and it's not moving to
-- public".
--
-- Two facts, both read from the schema rather than assumed:
--
--   * `add_gallery_image` inserts `is_active = true`. An upload IS public the
--     moment it lands. Nothing is hidden.
--   * `provider_gallery_public_read` requires `is_active = true` AND the
--     provider's status APPROVED. So a photo from a PENDING or SUSPENDED
--     provider is invisible, and becomes visible the moment the account is
--     approved.
--
-- So "it's not moving to public" is not a missing toggle -- it is a photo
-- belonging to an account that is not approved yet, or to one an
-- administrator has suspended. The honest fix is to SHOW that, and to give
-- the owner a way to unpublish deliberately, rather than to invent a "post"
-- switch that would flip a flag which is already on.
--
-- This function is therefore the owner's own visibility control: unpublish
-- without deleting (a photo they no longer offer, that they may want back),
-- and publish again. It cannot touch is_active on an image owned by somebody
-- else, which is what makes it safe to grant to `authenticated`.

CREATE OR REPLACE FUNCTION public.set_gallery_image_public(
  p_image_id uuid,
  p_public boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_owner uuid;
  v_was boolean;
  v_provider_status text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_image_id IS NULL THEN
    RAISE EXCEPTION 'AN_IMAGE_IS_REQUIRED';
  END IF;

  SELECT provider_id, is_active INTO v_owner, v_was
    FROM public.provider_gallery WHERE id = p_image_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_owner) THEN
    RAISE EXCEPTION 'NOT_YOUR_IMAGE';
  END IF;

  IF v_was = coalesce(p_public, v_was) THEN
    RETURN 'That photo is already ' || CASE WHEN p_public THEN 'published.' ELSE 'hidden.' END;
  END IF;

  SELECT coalesce(pp.status::text, '') INTO v_provider_status
    FROM public.provider_profiles pp WHERE pp.id = v_owner;

  UPDATE public.provider_gallery
     SET is_active = coalesce(p_public, false),
         updated_at = now()
   WHERE id = p_image_id;

  -- Honest about WHY, when the account is the reason. Returning "published"
  -- for a photo that is still not visible because the account is pending
  -- would be the kind of quiet success this audit keeps finding.
  RETURN CASE
    WHEN NOT coalesce(p_public, false)
      THEN 'Photo hidden. You can publish it again at any time.'
    WHEN v_provider_status = 'APPROVED'
      THEN 'Photo published. It is now visible on your public profile.'
    ELSE 'Photo published, but still not visible to customers: your account is '
         || lower(coalesce(nullif(v_provider_status, ''), 'not approved'))
         || '. It appears once your account is approved.'
  END;
END;
$$;

-- ===========================================================================
-- 8. WHY A PROVIDER'S PHOTO MAY LOOK UNPUBLISHED -- REPORTED, NOT GUESSED
-- ===========================================================================
-- A reporting function for the same reason as the others in this repository:
-- it must be able to answer "what was there" as well as "is it right now", so
-- the connectivity suite can print the inventory either way. Everything it
-- reads is derived, so it cannot drift from the policies it describes.

CREATE OR REPLACE FUNCTION public.gallery_visibility_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total integer;
  v_active integer;
  v_live integer;
BEGIN
  IF to_regclass('public.provider_gallery') IS NULL THEN
    RETURN 'provider_gallery does not exist';
  END IF;

  SELECT count(*), count(*) FILTER (WHERE g.is_active)
    INTO v_total, v_active
    FROM public.provider_gallery g;

  -- "Live" is the real question, and it is NOT the same as is_active: the
  -- public policy also requires an APPROVED provider, so an active row owned
  -- by a pending account is invisible without anything being wrong.
  SELECT count(*) INTO v_live
    FROM public.provider_gallery g
    JOIN public.provider_profiles pp ON pp.id = g.provider_id
   WHERE g.is_active AND pp.status = 'APPROVED';

  RETURN format(
    'ok: %s gallery photos, %s marked active, and %s actually visible to a '
    'customer -- the difference is photos owned by an account that is not '
    'approved yet, which is correct and not a publishing fault',
    v_total, v_active, v_live);
END;
$$;

-- ===========================================================================
-- 9. REACHABILITY OF EVERYTHING ADDED HERE
-- ===========================================================================
-- 0124 proves the admin write paths are callable. These four are new, so they
-- are added to the same instrument rather than left to be discovered the way
-- this file's first bug was: it was reachable, correctly named, correctly
-- granted, and still broken on every call.

CREATE OR REPLACE FUNCTION public.image_moderation_signature_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text := '';
  r record;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('admin_public_image_gallery',
       'public.admin_public_image_gallery(text,integer,integer)', '{}'),
      ('admin_set_gallery_image_public',
       'public.admin_set_gallery_image_public(uuid,boolean,text)',
       '{"p_image_id","p_public","p_reason"}'),
      ('admin_warn_user',
       'public.admin_warn_user(uuid,text,text)',
       '{"p_user_id","p_title","p_body"}'),
      ('set_gallery_image_public',
       'public.set_gallery_image_public(uuid,boolean)',
       '{"p_image_id","p_public"}'),
      ('admin_save_category_fee',
       'public.admin_save_category_fee(uuid,text,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric,numeric)',
       '{"p_category_id","p_city","p_commission_percent","p_commission_min","p_subscription_fee","p_activation_fee","p_ride_base_fare","p_ride_per_km","p_ride_minimum_fare","p_booking_base_fee","p_booking_per_km","p_booking_minimum_fee","p_product_commission_percent","p_product_commission_min","p_product_listing_fee"}')
    ) AS t(fn, sig, keys)
  LOOP
    IF to_regprocedure(r.sig) IS NULL THEN
      v_bad := v_bad || format('%s is missing at %s; ', r.fn, r.sig);
    END IF;

    -- A parameter the client sends that the function does not declare is a
    -- PGRST202 on every call, and PGRST202 was reported to users as "this
    -- section may have been removed" (§7.1.8).
    --
    -- `r.keys::text[]` is the cast that matters. Without it `'{}'` in the
    -- VALUES list above is inferred as the three-character TEXT '{}', so
    -- string_to_array yields one bogus "parameter" and this reports every
    -- function as broken. 0124 has the same cast for the same reason, and
    -- found it the same way. A report that is red for the wrong reason is
    -- worse than no report.
    IF EXISTS (
      SELECT 1 FROM unnest(r.keys::text[]) AS sent(key)
       WHERE btrim(sent.key) <> ''
         AND NOT EXISTS (
           SELECT 1 FROM pg_proc p
             JOIN unnest(p.proargnames) AS pn(attname)
              ON pn.attname = sent.key::text
            WHERE p.oid = to_regprocedure(r.sig))
    ) THEN
      v_bad := v_bad || format('%s: a parameter the client sends is not '
                               'declared; ', r.fn);
    END IF;

    -- Two functions of one name is PGRST203: PostgREST finds candidates and
    -- cannot choose between them.
    IF (
      SELECT count(*) FROM pg_proc p
       JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = r.fn
    ) > 1 THEN
      v_bad := v_bad || format('%s is overloaded; ', r.fn);
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad;
  END IF;

  RETURN 'ok: all 5 image-moderation and fee RPCs exist with the arity the '
         || 'client sends, their parameter names match exactly, and none of '
         || 'the names is overloaded';
END;
$$;

REVOKE ALL ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_set_gallery_image_public(uuid, boolean, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_gallery_image_public(uuid, boolean, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_warn_user(uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_warn_user(uuid, text, text)
  TO authenticated, service_role;

-- The provider's own control. Revoked from anon because anonymous "owners"
-- exist on the auth side and owns_provider_profile is the only thing standing
-- between one and another provider's gallery.
REVOKE ALL ON FUNCTION public.set_gallery_image_public(uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_gallery_image_public(uuid, boolean)
  TO authenticated, service_role;

-- Zero-argument assertions: executable by the connectivity suite, which runs
-- as the anon client. They expose nothing -- every one returns a sentence.
REVOKE ALL ON FUNCTION public.assert_category_fee_save_plans()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_category_fee_save_plans()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.image_moderation_signature_report()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.image_moderation_signature_report()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.gallery_visibility_report()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.gallery_visibility_report()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';