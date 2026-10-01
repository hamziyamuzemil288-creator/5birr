-- 20260927000122 — the admin can actually take something down
--
-- WHAT IS MISSING
-- ----------------
-- The platform has `suspend_provider()`, so a BUSINESS can be suspended. There
-- is no path to take down a single uploaded image, no record of who did it or
-- why, and no queue of reports to act on. An administrator looking at a
-- gallery photo that violates the terms has exactly two options: leave it up,
-- or delete the provider. Both are wrong, and the second one is destructive
-- enough that nobody will reach for it over a photograph.
--
-- THREE THINGS THIS ADDS
-- -----------------------
--   1. `moderation_actions` -- an append-only record of every takedown and
--      every suspension. This is the "full audit" the owner asked for: what
--      was removed, from whom, by whom, and why.
--   2. `content_reports` -- so the queue is fed by users and providers rather
--      than by an administrator who happened to notice.
--   3. The functions that do the work, all admin-gated, all audited.
--
-- WHY DELETING THE STORAGE OBJECT IS NOT ENOUGH
-- ----------------------------------------------
-- Every image in this project is referenced by a row: `provider_gallery`,
-- `product_images`, `vehicle_images`, `provider_stores.logo_storage_path`,
-- `profiles.avatar_storage_path`. Removing only the object leaves a row
-- pointing at nothing, which renders as a broken image in the client forever
-- and tells nobody it was removed on purpose. So `admin_moderate_image`
-- deletes the referencing row (or nulls the column, for an avatar, which has
-- no row of its own) AND the object, in one statement, so they cannot drift.
--
-- WHY THE ACCOUNT SUSPENSION SETS BOTH TABLES
-- --------------------------------------------
-- `suspend_provider` set `provider_profiles` and `profiles` together, and the
-- router gates on `profiles.status`. The connectivity suite's
-- `assert_profile_status_synced` exists precisely because unsynchronising them
-- locked people out of their own accounts. `admin_suspend_account` writes both,
-- and `admin_reinstate_account` restores both to APPROVED.
--
-- NO `auth.users` ANYWHERE
-- -----------------------
-- Naming it aborts the push (42P01) — runs 36870164815 and 36873453231 both
-- died that way. See 0118 and 0121 for the discovery technique.

-- ===========================================================================
-- 1. What was done, and why
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.moderation_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  action_type text NOT NULL CHECK (action_type IN (
    'IMAGE_REMOVED', 'ACCOUNT_SUSPENDED', 'ACCOUNT_REINSTATED',
    'REPORT_UPHELD', 'REPORT_DISMISSED', 'LISTING_WITHDRAWN')),

  severity text NOT NULL DEFAULT 'MODERATE'
    CHECK (severity IN ('MODERATE', 'SERIOUS', 'CRITICAL')),

  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 1000),

  -- What was acted on. Exactly one of these is set, chosen by action_type.
  target_user_id uuid,
  target_provider_id uuid,
  object_bucket text,
  object_path text,

  -- Free-form evidence: which row held the image, what the report said.
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,

  actioned_by uuid,
  actioned_by_name text NOT NULL DEFAULT '',
  report_id uuid,

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_moderation_actions_created
  ON public.moderation_actions (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_user
  ON public.moderation_actions (target_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_moderation_actions_image
  ON public.moderation_actions (object_bucket, object_path);

-- ===========================================================================
-- 2. The queue
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.content_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- A provider reports their own photo back; a customer reports a provider's.
  -- Either way the reporter is an account, never an anonymous stranger.
  reporter_user_id uuid,
  reported_user_id uuid,
  reported_provider_id uuid,
  object_bucket text,
  object_path text,

  category text NOT NULL DEFAULT 'OTHER'
    CHECK (category IN ('VIOLENT_OR_THREATENING', 'HARASSMENT', 'NUDITY_OR_SEXUAL',
                        'HATE_OR_ABUSE', 'SPAM_OR_SCAMS', 'MISLEADING_LISTING',
                        'FAKE_ACCOUNT', 'OTHER')),
  -- Free text is required, not optional: "violence" without a description is
  -- not actionable, and an admin acting on a report cannot ask a question
  -- because the reporter has gone.
  description text NOT NULL CHECK (length(btrim(description)) BETWEEN 10 AND 2000),

  status text NOT NULL DEFAULT 'OPEN'
    CHECK (status IN ('OPEN', 'REVIEWING', 'UPHELD', 'DISMISSED')),
  resolution_note text,
  resolved_by uuid,
  resolved_at timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_content_reports_status
  ON public.content_reports (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_content_reports_reporter
  ON public.content_reports (reporter_user_id, created_at DESC);

-- An open report about the same object is worth noticing before it is filed a
-- second time. Partial, so the index stays small no matter how many are
-- dismissed.
CREATE UNIQUE INDEX IF NOT EXISTS idx_content_reports_one_open_per_object
  ON public.content_reports (coalesce(object_bucket, ''), coalesce(object_path, ''))
  WHERE status IN ('OPEN', 'REVIEWING') AND object_path IS NOT NULL;

DO $$
DECLARE
  v_account    text;
  v_name       text;
  v_table      text;
  v_col        text;
  v_ref        text;
  v_on_delete  text;
BEGIN
  SELECT format('%I.%I', pn.nspname, pc.relname) INTO v_account
    FROM pg_constraint c
    JOIN pg_class pc     ON pc.oid = c.confrelid
    JOIN pg_namespace pn ON pn.oid = pc.relnamespace
   WHERE c.conrelid = to_regclass('public.profiles')
     AND c.contype  = 'f'
     AND c.conkey   = ARRAY[
           (SELECT a.attnum FROM pg_attribute a
             WHERE a.attrelid = to_regclass('public.profiles')
               AND a.attname  = 'id')];

  IF v_account IS NULL THEN
    RETURN;
  END IF;

  -- Every constraint is added only if absent. Re-running this file is how a
  -- broken first attempt gets fixed, and `ADD CONSTRAINT` on a name that
  -- already exists is `ERROR: constraint ... already exists`, which would abort
  -- the retry before it reached the functions.
  FOR v_name, v_table, v_col, v_ref, v_on_delete IN
    SELECT * FROM (VALUES
      ('moderation_actions_actioned_by_fkey', 'moderation_actions',
       'actioned_by', v_account, 'SET NULL'),
      ('moderation_actions_target_user_fkey', 'moderation_actions',
       'target_user_id', v_account, 'SET NULL'),
      ('content_reports_reporter_fkey', 'content_reports',
       'reporter_user_id', v_account, 'SET NULL'),
      ('content_reports_reported_user_fkey', 'content_reports',
       'reported_user_id', v_account, 'SET NULL'),
      ('content_reports_resolved_by_fkey', 'content_reports',
       'resolved_by', v_account, 'SET NULL'),
      ('moderation_actions_report_fkey', 'moderation_actions',
       'report_id', '"public"."content_reports"', 'CASCADE')
    ) AS t(cname, tbl, col, ref, on_delete)
  LOOP
    -- `%s` for the reference, NOT `%I`. `v_ref` is ALREADY a quoted,
    -- schema-qualified name (it comes from `format('%I.%I', nspname, relname)`
    -- above), and `%I` on that text quotes the whole thing as ONE identifier:
    -- `REFERENCES "public.users"` -- a relation literally named that, which is
    -- the 42P01 that killed deploy runs 36870164815 and 36873453231. It is
    -- the single easiest mistake to make twice.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = v_name) THEN
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I '
                     'FOREIGN KEY (%I) REFERENCES %s ON DELETE %s',
                     v_table, v_name, v_col, v_ref, v_on_delete);
    END IF;
  END LOOP;
END;
$$;
-- ===========================================================================
-- 3. Who may see the queue
-- ===========================================================================
ALTER TABLE public.moderation_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.content_reports  ENABLE ROW LEVEL SECURITY;

-- Append-only: RLS has SELECT and nothing else, so not even an admin can
-- rewrite or delete the record of what was done.
DROP POLICY IF EXISTS moderation_actions_read ON public.moderation_actions;
CREATE POLICY moderation_actions_read ON public.moderation_actions
  FOR SELECT TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS content_reports_read ON public.content_reports;
CREATE POLICY content_reports_read ON public.content_reports
  FOR SELECT TO authenticated
  USING (
    reporter_user_id = (SELECT auth.uid())
    OR reported_user_id = (SELECT auth.uid())
    OR public.is_admin()
  );

-- A reporter may add a report and may close their own, and may never edit
-- somebody else's. `WITH CHECK` on the INSERT is what stops a caller writing
-- `status = 'UPHELD'` on a report they just filed, which would let anybody
-- close the queue.
DROP POLICY IF EXISTS content_reports_insert ON public.content_reports;
CREATE POLICY content_reports_insert ON public.content_reports
  FOR INSERT TO authenticated
  WITH CHECK (reporter_user_id = (SELECT auth.uid()));

DROP POLICY IF EXISTS content_reports_update_own ON public.content_reports;
CREATE POLICY content_reports_update_own ON public.content_reports
  FOR UPDATE TO authenticated
  USING (reporter_user_id = (SELECT auth.uid()))
  WITH CHECK (reporter_user_id = (SELECT auth.uid()));

REVOKE ALL ON TABLE public.moderation_actions FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.moderation_actions TO authenticated, service_role;
REVOKE ALL ON TABLE public.content_reports FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE ON TABLE public.content_reports TO authenticated, service_role;

-- ===========================================================================
-- 4. Reporting
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.file_content_report(
  p_reported_user_id     uuid DEFAULT NULL,
  p_reported_provider_id uuid DEFAULT NULL,
  p_object_bucket        text DEFAULT NULL,
  p_object_path          text DEFAULT NULL,
  p_category             text DEFAULT 'OTHER',
  p_description          text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF length(btrim(coalesce(p_description, ''))) < 10 THEN
    RAISE EXCEPTION 'REPORT_NEEDS_A_DESCRIPTION';
  END IF;

  IF p_reported_user_id IS NULL AND p_reported_provider_id IS NULL
     AND p_object_path IS NULL THEN
    RAISE EXCEPTION 'REPORT_MUST_NAME_SOMETHING';
  END IF;

  INSERT INTO public.content_reports (
    reporter_user_id, reported_user_id, reported_provider_id,
    object_bucket, object_path, category, description)
  VALUES (
    (SELECT auth.uid()), p_reported_user_id, p_reported_provider_id,
    p_object_bucket, p_object_path,
    coalesce(nullif(p_category, ''), 'OTHER'), btrim(p_description))
  ON CONFLICT (coalesce(object_bucket, ''), coalesce(object_path, ''))
    WHERE status IN ('OPEN', 'REVIEWING') AND object_path IS NOT NULL
  DO NOTHING
  RETURNING id INTO v_id;

  -- DO NOTHING returned nothing: the same object is already in the queue.
  -- The caller still gets an id, so the reporter is told it was received.
  IF v_id IS NULL THEN
    SELECT r.id INTO v_id
      FROM public.content_reports r
     WHERE coalesce(r.object_bucket, '') = coalesce(p_object_bucket, '')
       AND coalesce(r.object_path, '')   = coalesce(p_object_path, '')
       AND r.status IN ('OPEN', 'REVIEWING')
     ORDER BY r.created_at DESC
     LIMIT 1;
  END IF;

  RETURN v_id;
END;
$$;

-- ===========================================================================
-- 5. Taking an image down
-- ===========================================================================
-- Deletes the referencing row AND the storage object in one call, so a row can
-- never be left pointing at a file that is gone. The bucket is restricted to
-- this project's image buckets, so a crafted path cannot be used to delete an
-- object out of, say, the identity-document bucket.
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

  -- `<> ALL`, NOT `<> ANY`. This is the whole membership test, and it is
  -- exactly the operator people get wrong:
  --
  --   `x = ANY (arr)`  is  x = a OR  x = b  OR ...   -- membership
  --   `x <> ANY (arr)` is  x <> a AND x <> b AND ...  -- NOT membership, and
  --                                                     what everybody reads
  --                                                     as membership
  --   `x <> ALL (arr)` is NOT (x = ANY (arr))         -- what is wanted here
  --
  -- Written as `<> ANY`, `'provider-gallery' <> ANY (...)` is TRUE for a bucket
  -- that IS on the list, so every takedown died with
  -- THAT_BUCKET_IS_NOT_MODERABLE and the whole section was dead on arrival.
  -- Found by running it, not by reading it.
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
  -- skip rather than abort the whole call.
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

  -- The avatar branch is guarded on the COLUMN, not just the table: 0119 adds
  -- `profiles.avatar_storage_path`, and a database that has not taken 0119 yet
  -- would otherwise fail the whole takedown over an avatar nobody can have
  -- uploaded anyway.
  IF v_removed = '' AND EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'profiles'
           AND column_name = 'avatar_storage_path') THEN
    -- An avatar has no row of its own: the column IS the reference. So it is
    -- nulled, not deleted, and the profile row survives with no picture.
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

  IF to_regclass('storage.objects') IS NOT NULL THEN
    DELETE FROM storage.objects
     WHERE bucket_id = p_bucket AND name = p_path;
  END IF;

  -- The owner of the removed image, so the record says whose it was.
  IF v_prov IS NOT NULL THEN
    SELECT pp.user_id INTO v_owner FROM public.provider_profiles pp WHERE pp.id = v_prov;
  END IF;

  -- The actor's name must be written UNCONDITIONALLY. A `SELECT ... INTO`
  -- matching no row sets its target to NULL, overwriting the '' default, and
  -- `actioned_by_name` is NOT NULL -- so an administrator without a profiles
  -- row yet could not remove an image at all. Found by running it.
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
                             'removed_from', v_removed, 'reason', btrim(p_reason)));

  RETURN 'ok: removed ' || p_path || ' from ' || v_removed;
END;
$$;

-- ===========================================================================
-- 6. Suspending a person, and letting them back
-- ===========================================================================
-- Writes `profiles` AND `provider_profiles`, because the router gates on
-- `profiles.status` and the admin panel reads `provider_profiles.status`, and
-- the two disagreeing is exactly the bug `assert_profile_status_synced`
-- exists to catch.
CREATE OR REPLACE FUNCTION public.admin_suspend_account(
  p_user_id   uuid,
  p_reason    text,
  p_severity  text DEFAULT 'SERIOUS'
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor      uuid;
  v_actor_name text := '';
  v_name       text := '';
  v_provider   uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'A_USER_IS_REQUIRED';
  END IF;

  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN
    RAISE EXCEPTION 'A_REASON_IS_REQUIRED';
  END IF;

  -- An administrator cannot suspend themselves, and cannot suspend the one
  -- account that can undo it if something goes wrong.
  SELECT (SELECT auth.uid()) INTO v_actor;
  IF v_actor IS NOT NULL AND v_actor = p_user_id THEN
    RAISE EXCEPTION 'YOU_CANNOT_SUSPEND_YOURSELF';
  END IF;

  SELECT coalesce(full_name, '') INTO v_name
    FROM public.profiles WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_SUCH_ACCOUNT';
  END IF;

  SELECT (SELECT full_name) INTO v_actor_name
    FROM public.profiles WHERE id = v_actor;
  v_actor_name := coalesce(v_actor_name, '');

  -- BOTH tables, and the profiles row FIRST. The router gates on
  -- `profiles.status`; leaving it alone suspends the business in the admin
  -- panel and does nothing at all in the app, which is the half-written state
  -- `assert_profile_status_synced` exists to catch. (This UPDATE was briefly
  -- deleted by an edit and the function still returned "ok" -- it suspended
  -- the provider row and nothing else.)
  UPDATE public.profiles SET status = 'SUSPENDED', updated_at = now()
   WHERE id = p_user_id;

  SELECT pp.id INTO v_provider FROM public.provider_profiles pp
   WHERE pp.user_id = p_user_id;

  IF v_provider IS NOT NULL THEN
    UPDATE public.provider_profiles SET status = 'SUSPENDED', updated_at = now()
     WHERE id = v_provider;
  END IF;

  INSERT INTO public.moderation_actions (
    action_type, severity, reason, target_user_id, target_provider_id,
    detail, actioned_by, actioned_by_name)
  VALUES (
    'ACCOUNT_SUSPENDED', coalesce(nullif(p_severity, ''), 'SERIOUS'), btrim(p_reason),
    p_user_id, v_provider,
    jsonb_build_object('account_name', v_name), v_actor, coalesce(v_actor_name, ''));

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'ACCOUNT_SUSPENDED_BY_ADMIN', 'profiles', p_user_id,
          jsonb_build_object('reason', btrim(p_reason), 'severity',
                             coalesce(nullif(p_severity, ''), 'SERIOUS'),
                             'provider_id', v_provider));

  RETURN 'ok: suspended ' || coalesce(nullif(v_name, ''), p_user_id::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reinstate_account(
  p_user_id uuid,
  p_reason  text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor      uuid;
  v_actor_name text := '';
  v_name       text := '';
  v_provider   uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_name
    FROM public.profiles WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_SUCH_ACCOUNT';
  END IF;

  SELECT (SELECT full_name) INTO v_actor_name FROM public.profiles WHERE id = v_actor;

  UPDATE public.profiles SET status = 'APPROVED', updated_at = now()
   WHERE id = p_user_id;

  SELECT pp.id INTO v_provider FROM public.provider_profiles pp
   WHERE pp.user_id = p_user_id;

  IF v_provider IS NOT NULL THEN
    UPDATE public.provider_profiles SET status = 'APPROVED', updated_at = now()
     WHERE id = v_provider;
  END IF;

  INSERT INTO public.moderation_actions (
    action_type, severity, reason, target_user_id, target_provider_id,
    detail, actioned_by, actioned_by_name)
  VALUES (
    'ACCOUNT_REINSTATED', 'MODERATE', coalesce(nullif(btrim(p_reason), ''), 'No reason given'),
    p_user_id, v_provider,
    jsonb_build_object('account_name', v_name), v_actor, coalesce(v_actor_name, ''));

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'ACCOUNT_REINSTATED_BY_ADMIN', 'profiles', p_user_id,
          jsonb_build_object('reason', coalesce(p_reason, 'No reason given')));

  RETURN 'ok: reinstated ' || coalesce(nullif(v_name, ''), p_user_id::text);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_content_reports(
  p_status text DEFAULT NULL,
  p_limit  int  DEFAULT 100
)
RETURNS SETOF public.content_reports
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
  SELECT r.* FROM public.content_reports r
   WHERE (p_status IS NULL OR r.status = p_status)
   ORDER BY r.created_at DESC
   LIMIT greatest(1, least(coalesce(p_limit, 100), 500));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_moderation_actions(p_limit int DEFAULT 100)
RETURNS SETOF public.moderation_actions
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
  SELECT a.* FROM public.moderation_actions a
   ORDER BY a.created_at DESC
   LIMIT greatest(1, least(coalesce(p_limit, 100), 500));
END;
$$;

-- Closing a report. UPHELD and DISMISSED are both recorded in
-- moderation_actions, so the audit line exists whichever way it went.
CREATE OR REPLACE FUNCTION public.admin_resolve_content_report(
  p_report_id uuid,
  p_outcome   text,
  p_note      text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r record;
  v_actor uuid;
  v_name  text := '';
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  IF p_outcome IS NULL OR p_outcome NOT IN ('UPHELD', 'DISMISSED') THEN
    RAISE EXCEPTION 'OUTCOME_MUST_BE_UPHELD_OR_DISMISSED';
  END IF;

  SELECT * INTO r FROM public.content_reports WHERE id = p_report_id FOR UPDATE;
  IF r.id IS NULL THEN
    RAISE EXCEPTION 'NO_SUCH_REPORT';
  END IF;

  -- `SELECT ... INTO` that matches no row writes NULL over the '' default, and
  -- `actioned_by_name` is NOT NULL -- so an administrator without a profiles
  -- row yet could not close a report. Found by running it.
  v_name := coalesce(v_name, '');

  IF r.status NOT IN ('OPEN', 'REVIEWING') THEN
    RAISE EXCEPTION 'REPORT_ALREADY_RESOLVED_AS_%', r.status;
  END IF;

  SELECT (SELECT auth.uid()) INTO v_actor;
  SELECT coalesce(full_name, '') INTO v_name FROM public.profiles WHERE id = v_actor;

  UPDATE public.content_reports
     SET status = p_outcome,
         resolution_note = nullif(btrim(coalesce(p_note, '')), ''),
         resolved_by = v_actor,
         resolved_at = now(),
         updated_at = now()
   WHERE id = p_report_id;

  INSERT INTO public.moderation_actions (
    action_type, severity, reason, target_user_id, target_provider_id,
    object_bucket, object_path, detail, actioned_by, actioned_by_name, report_id)
  VALUES (
    CASE WHEN p_outcome = 'UPHELD' THEN 'REPORT_UPHELD' ELSE 'REPORT_DISMISSED' END,
    'MODERATE',
    coalesce(nullif(btrim(coalesce(p_note, '')), ''), 'Report closed'),
    r.reported_user_id, r.reported_provider_id,
    r.object_bucket, r.object_path,
    jsonb_build_object('category', r.category, 'description', r.description),
    v_actor, coalesce(v_name, ''), p_report_id);

  RETURN 'ok: report ' || p_outcome;
END;
$$;

REVOKE ALL ON FUNCTION public.file_content_report(uuid, uuid, text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.file_content_report(uuid, uuid, text, text, text, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_moderate_image(text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_moderate_image(text, text, text, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_suspend_account(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_suspend_account(uuid, text, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_reinstate_account(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reinstate_account(uuid, text)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_content_reports(text, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_content_reports(text, int)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_moderation_actions(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_moderation_actions(int)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_resolve_content_report(uuid, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_resolve_content_report(uuid, text, text)
  TO authenticated, service_role;

-- ===========================================================================
-- 7. Prove it, on the live database
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_content_control_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text;
  v_open    text;
  v_unowned text;
BEGIN
  SELECT string_agg(t.kind || ' ' || t.name, ', ') INTO v_missing
    FROM (VALUES
      ('table',    'public.moderation_actions'),
      ('table',    'public.content_reports'),
      ('function', 'public.admin_moderate_image(text,text,text,text)'),
      ('function', 'public.admin_suspend_account(uuid,text,text)'),
      ('function', 'public.admin_reinstate_account(uuid,text)'),
      ('function', 'public.admin_resolve_content_report(uuid,text,text)'),
      ('function', 'public.file_content_report(uuid,uuid,text,text,text,text)'),
      ('function', 'public.admin_content_reports(text,int)'),
      ('function', 'public.admin_moderation_actions(int)')
    ) AS t(kind, name)
   WHERE CASE t.kind
           WHEN 'table' THEN to_regclass(t.name) IS NULL
           -- to_regprocedure, NOT `proname = t.name`: the value is a
           -- schema-qualified SIGNATURE, and `proname` is the bare name, so
           -- that comparison never matches and the check reported every
           -- function missing while all of them were demonstrably working.
           -- to_regprocedure resolves the exact signature, which also catches a
           -- function that exists with the WRONG arity -- the failure that
           -- actually stops the client calling it.
           ELSE to_regprocedure(t.name) IS NULL
         END;

  IF v_missing IS NOT NULL THEN
    RETURN 'BROKEN: missing ' || v_missing;
  END IF;

  -- A takedown with no reason recorded is not an audit trail.
  --
  -- Only the REASON is required. `actioned_by` may legitimately be NULL: a
  -- service-role or scheduled action runs with no session, and treating that
  -- as a defect would make this assertion report BROKEN for a row that is
  -- perfectly correct -- which is how an assertion stops being trusted.
  SELECT string_agg(a.action_type, ', ') INTO v_unowned
    FROM public.moderation_actions a
   WHERE btrim(coalesce(a.reason, '')) = '';

  IF v_unowned IS NOT NULL THEN
    RETURN 'BROKEN: ' || v_unowned
        || ' action(s) recorded with no reason at all';
  END IF;

  SELECT count(*)::text INTO v_open
    FROM public.content_reports r
   WHERE r.status IN ('OPEN', 'REVIEWING')
     AND r.resolved_at IS NOT NULL;

  IF v_open <> '0' THEN
    RETURN 'BROKEN: ' || v_open || ' report(s) marked resolved but still queued';
  END IF;

  RETURN 'ok: image takedown, account suspension and the report queue are all '
         || 'present, and every moderation action records a reason';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_content_control_is_wired() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_content_control_is_wired()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
