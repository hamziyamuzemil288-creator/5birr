-- Appeal respondents: the OTHER party can see and answer a case filed
-- against them.
--
-- WHAT EXISTED
-- ------------
-- `appeal_cases` (20260923000000) models only one side. The submitter files
-- a case with an evidence photo; admins and support staff resolve it. The
-- person or business the report is ABOUT never learns of it and has no way
-- to answer — an accusation with no reply channel. The submitter, meanwhile,
-- had no screen to check the status of what they filed (only the one-shot
-- success view after submitting).
--
-- WHAT THIS ADDS
-- --------------
--   1. respondent_id + response columns on appeal_cases — the SAME table and
--      the SAME lifecycle, not a second system. The linkage is a nullable
--      auth user picked by the submitter from the counterparties they
--      actually met (their orders / rides); a case may also name nobody.
--   2. Three read RPCs styled after staff_task_feed(): the submitter's own
--      list, the respondent's list, and the counterparty picker. The
--      respondent deliberately gets NO direct SELECT policy on the table:
--      the reporter's phone/email stay with staff, so the respondent reads
--      through a column-curated SECURITY DEFINER function instead.
--   3. respond_to_appeal_case() — the one write path for a response. It
--      checks respondent identity, OPEN status and single-shot reply, and
--      the write fires trg_appeal_case_responded so the response lands in
--      admin_actions exactly the way a resolution already does.
--   4. A storage SELECT policy — evaluated through a SECURITY DEFINER helper
--      so it cannot be starved by appeal_cases' RLS from the caller's seat —
--      that lets a respondent sign the `appeal_*` evidence photo of the case
--      filed against them, and nothing else in that folder (a National ID
--      upload shares the same folder and must stay private).

-- ===========================================================================
-- 1. The respondent columns — same table, same lifecycle
-- ===========================================================================
ALTER TABLE public.appeal_cases
  ADD COLUMN IF NOT EXISTS respondent_id uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS response_text text,
  ADD COLUMN IF NOT EXISTS response_photo_path text,
  ADD COLUMN IF NOT EXISTS responded_at timestamptz;

-- You cannot file a report against yourself.
ALTER TABLE public.appeal_cases
  DROP CONSTRAINT IF EXISTS appeal_cases_not_own_respondent;
ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_not_own_respondent
  CHECK (respondent_id IS NULL OR respondent_id <> user_id);

CREATE INDEX IF NOT EXISTS idx_appeal_cases_respondent
  ON public.appeal_cases (respondent_id)
  WHERE respondent_id IS NOT NULL;

-- ===========================================================================
-- 2. A response is audited like a resolution
-- ===========================================================================
-- Same shape as on_appeal_case_resolved (20260923000000): the moment the
-- response lands, admin_actions gets a row. The auth.uid() guard keeps a
-- server-initiated write (no user seat) from aborting the update against the
-- NOT NULL admin_id column.
CREATE OR REPLACE FUNCTION public.on_appeal_case_responded()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (
    auth.uid(),
    'APPEAL_CASE_RESPONSE',
    'appeal_case',
    NEW.id,
    jsonb_build_object('respondent_id', NEW.respondent_id)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_case_responded ON public.appeal_cases;
CREATE TRIGGER trg_appeal_case_responded
AFTER UPDATE ON public.appeal_cases
FOR EACH ROW
WHEN (NEW.responded_at IS NOT NULL AND OLD.responded_at IS NULL)
EXECUTE FUNCTION public.on_appeal_case_responded();

-- ===========================================================================
-- 3. Reads: both sides, plus the picker for who a case is about
-- ===========================================================================
-- Submitter view: their own cases, with the respondent's public name
-- (business name first — that is how a seller is recognised) resolved in SQL,
-- because the submitter cannot read other profiles through RLS.

CREATE OR REPLACE FUNCTION public.my_appeal_cases()
RETURNS TABLE (
  id uuid,
  status text,
  description text,
  photo_path text,
  response_text text,
  response_photo_path text,
  responded_at timestamptz,
  resolution_note text,
  resolved_at timestamptz,
  created_at timestamptz,
  respondent_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.status,
    c.description,
    c.photo_path,
    c.response_text,
    c.response_photo_path,
    c.responded_at,
    c.resolution_note,
    c.resolved_at,
    c.created_at,
    COALESCE(
      (SELECT NULLIF(btrim(pp.business_name), '')
         FROM public.provider_profiles pp
        WHERE pp.user_id = c.respondent_id
        LIMIT 1),
      (SELECT NULLIF(btrim(p.full_name), '')
         FROM public.profiles p
        WHERE p.id = c.respondent_id),
      CASE WHEN c.respondent_id IS NULL
           THEN NULL ELSE 'Another Aliob user' END
    )
  FROM public.appeal_cases c
  WHERE c.user_id = auth.uid()
  ORDER BY c.created_at DESC;
END;
$$;

-- Respondent view: cases filed against the caller. Reporter phone/email are
-- intentionally NOT returned — the reporter's contact details are staff
-- context, and the free-text description already carries whatever the
-- reporter chose to write.

CREATE OR REPLACE FUNCTION public.appeals_against_me()
RETURNS TABLE (
  id uuid,
  status text,
  description text,
  photo_path text,
  response_text text,
  response_photo_path text,
  responded_at timestamptz,
  resolution_note text,
  resolved_at timestamptz,
  created_at timestamptz,
  submitter_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    c.id,
    c.status,
    c.description,
    c.photo_path,
    c.response_text,
    c.response_photo_path,
    c.responded_at,
    c.resolution_note,
    c.resolved_at,
    c.created_at,
    COALESCE(
      (SELECT NULLIF(btrim(p.full_name), '')
         FROM public.profiles p
        WHERE p.id = c.user_id),
      'Aliob user'
    )
  FROM public.appeal_cases c
  WHERE c.respondent_id = auth.uid()
  ORDER BY c.created_at DESC;
END;
$$;

-- The picker: counterparties the caller has actually dealt with — sellers
-- from their orders and drivers from their rides — so "report this person"
-- names a real account instead of free text.

CREATE OR REPLACE FUNCTION public.appeal_counterparties()
RETURNS TABLE (
  counterpart_user_id uuid,
  display_name text,
  kind text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH links AS (
    SELECT DISTINCT o.provider_id AS profile_id, 'SELLER'::text AS kind
    FROM public.orders o
    WHERE o.user_id = auth.uid() AND o.provider_id IS NOT NULL
    UNION
    SELECT DISTINCT r.claimed_by_provider_id AS profile_id, 'DRIVER'::text AS kind
    FROM public.ride_requests r
    WHERE r.user_id = auth.uid() AND r.claimed_by_provider_id IS NOT NULL
  )
  SELECT
    pp.user_id,
    COALESCE(
      NULLIF(btrim(pp.business_name), ''),
      NULLIF(btrim(pf.full_name), ''),
      'Aliob provider'
    ),
    l.kind
  FROM links l
  JOIN public.provider_profiles pp ON pp.id = l.profile_id
  LEFT JOIN public.profiles pf ON pf.id = pp.user_id
  WHERE pp.user_id IS NOT NULL AND pp.user_id <> auth.uid()
  ORDER BY 3, 2;
END;
$$;

REVOKE ALL ON FUNCTION public.my_appeal_cases() FROM public, anon;
REVOKE ALL ON FUNCTION public.appeals_against_me() FROM public, anon;
REVOKE ALL ON FUNCTION public.appeal_counterparties() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.my_appeal_cases() TO authenticated;
GRANT EXECUTE ON FUNCTION public.appeals_against_me() TO authenticated;
GRANT EXECUTE ON FUNCTION public.appeal_counterparties() TO authenticated;

-- ===========================================================================
-- 4. The one write path for a response
-- ===========================================================================
-- SECURITY DEFINER so the respondent needs no UPDATE policy on the table —
-- the owner-only UPDATE policy from 20260923000000 ("users cannot edit their
-- own cases after submission") stays exactly as it was.

CREATE OR REPLACE FUNCTION public.respond_to_appeal_case(
  p_case_id uuid,
  p_response_text text,
  p_response_photo_path text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case public.appeal_cases;
BEGIN
  IF p_case_id IS NULL OR length(btrim(coalesce(p_response_text, ''))) = 0 THEN
    RAISE EXCEPTION 'RESPONSE_TEXT_REQUIRED';
  END IF;

  SELECT * INTO v_case FROM public.appeal_cases WHERE id = p_case_id;
  IF v_case.id IS NULL THEN
    RAISE EXCEPTION 'APPEAL_CASE_NOT_FOUND';
  END IF;
  IF v_case.respondent_id IS NULL OR v_case.respondent_id <> auth.uid() THEN
    RAISE EXCEPTION 'ONLY_THE_RESPONDENT_CAN_RESPOND';
  END IF;
  IF v_case.status <> 'OPEN' THEN
    RAISE EXCEPTION 'APPEAL_CASE_IS_NO_LONGER_OPEN';
  END IF;
  IF v_case.responded_at IS NOT NULL THEN
    RAISE EXCEPTION 'ALREADY_RESPONDED';
  END IF;

  UPDATE public.appeal_cases
  SET response_text = btrim(p_response_text),
      response_photo_path = p_response_photo_path,
      responded_at = now()
  WHERE id = p_case_id;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.respond_to_appeal_case(uuid, text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.respond_to_appeal_case(uuid, text, text)
  TO authenticated;

-- ===========================================================================
-- 5. The respondent may sign ONLY the appeal photo
-- ===========================================================================
-- The evidence photo lives in the submitter's own user-documents folder,
-- which also holds National ID uploads. The read policy therefore cannot be
-- "the respondent may read that folder" — only files named appeal_* inside
-- it, and only while a case filed BY that folder's owner names the caller as
-- respondent. The helper is SECURITY DEFINER so the EXISTS sees appeal_cases
-- unfiltered by the caller's row-level seat (the respondent has no table
-- SELECT policy, by design).

CREATE OR REPLACE FUNCTION public.respondent_can_read_appeal_photo(
  p_path text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.appeal_cases c
    WHERE c.respondent_id = auth.uid()
      AND (string_to_array(p_path, '/'))[1] = c.user_id::text
  );
$$;

GRANT EXECUTE ON FUNCTION public.respondent_can_read_appeal_photo(text)
  TO authenticated, anon;
REVOKE ALL ON FUNCTION public.respondent_can_read_appeal_photo(text)
  FROM public;

DROP POLICY IF EXISTS appeal_cases_respondent_photo_read ON storage.objects;
CREATE POLICY appeal_cases_respondent_photo_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND (string_to_array(name, '/'))[2] LIKE 'appeal\_%'
    AND public.respondent_can_read_appeal_photo(name)
  );

-- And the mirror: the submitter must be able to SEE the response evidence
-- the respondent uploaded into their own folder. Same shape, opposite
-- direction, file prefix narrowed to `appeal_response_` so a respondent's
-- National ID (same folder, same owner) is never reachable.

CREATE OR REPLACE FUNCTION public.submitter_can_read_appeal_response(
  p_path text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.appeal_cases c
    WHERE c.user_id = auth.uid()
      AND (string_to_array(p_path, '/'))[1] = c.respondent_id::text
  );
$$;

GRANT EXECUTE ON FUNCTION public.submitter_can_read_appeal_response(text)
  TO authenticated, anon;
REVOKE ALL ON FUNCTION public.submitter_can_read_appeal_response(text)
  FROM public;

DROP POLICY IF EXISTS appeal_cases_submitter_response_photo_read
  ON storage.objects;
CREATE POLICY appeal_cases_submitter_response_photo_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND (string_to_array(name, '/'))[2] LIKE 'appeal_response\_%'
    AND public.submitter_can_read_appeal_response(name)
  );

-- New functions + a new column: let PostgREST see them without waiting for
-- its next schema cache refresh (house convention since 20260927000049).
NOTIFY pgrst, 'reload schema';
