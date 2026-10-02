-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- The schema 20260927000131_an_appeal_reaches_the_people_who_act_on_it.sql
-- reads and writes, and nothing else. Separate from scratch/db/
-- registration_pre.sql so the two replays stay independent.
--
-- Built from the real history: appeal_cases as 20260923000000 created it, then
-- case_type/email/evidence as 20260927000120 changed it. 0131 only alters the
-- two CHECK constraints, so the fixture must carry the PRE-0131 definitions --
-- with the constraint present, because a DROP IF EXISTS against a missing
-- constraint proves nothing.

\set ON_ERROR_STOP on

CREATE SCHEMA IF NOT EXISTS auth;

CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS 'SELECT NULL::uuid';

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  email text
);

CREATE FUNCTION public.uuid_generate_v4() RETURNS uuid
LANGUAGE sql AS 'SELECT gen_random_uuid()';

CREATE TYPE public.notification_type AS ENUM (
  'REGISTRATION_RECEIVED','APPROVAL','REJECTION','CORRECTION_REQUIRED',
  'ADMIN_MESSAGE','ORDER_RECEIVED','ORDER_ACCEPTED','ORDER_REJECTED',
  'RIDE_REQUEST','RIDE_CLAIMED','RIDE_TAKEN','RIDE_STARTED','RIDE_COMPLETED',
  'PAYMENT_REMINDER','PAYMENT_PROOF_REQUIRED','WALLET_LOW','WALLET_EMPTY',
  'SUBSCRIPTION_DUE','PROVIDER_INACTIVE','TRANSACTION_FEE_DEDUCTED','SECURITY',
  'APPEAL_FILED','APPEAL_RESOLVED'
);

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  full_name text,
  city text,
  status text DEFAULT 'PENDING_APPROVAL',
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  is_ceo boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  permissions text[] NOT NULL DEFAULT '{}',
  is_super_admin boolean NOT NULL DEFAULT false
);

CREATE TABLE public.user_roles (
  user_id uuid NOT NULL,
  role text NOT NULL,
  PRIMARY KEY (user_id, role)
);

CREATE TABLE public.admin_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid, event_type text NOT NULL, entity_type text, entity_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb, created_at timestamptz DEFAULT now()
);

CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid, type public.notification_type, title text, body text,
  is_read boolean DEFAULT false, data jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid, type public.notification_type, title text, body text,
  data jsonb DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now(),
  drained_at timestamptz
);

-- appeal_cases as 20260927000120 leaves it: case_type present and constrained
-- to the TWO values, and the evidence CHECK in place. 0131 widens both.
CREATE TABLE public.appeal_cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  respondent_id uuid,
  photo_path text,
  description text NOT NULL,
  phone text,
  email text,
  status text NOT NULL DEFAULT 'OPEN',
  case_type text NOT NULL DEFAULT 'GENERAL',
  resolution_note text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  captcha_id text
);

ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_case_type_known
  CHECK (case_type IN ('GENERAL', 'PASSWORD_RESET'));

ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_evidence_required
  CHECK (
    (case_type = 'GENERAL'
       AND photo_path IS NOT NULL
       AND length(btrim(phone)) > 0)
    OR
    (case_type = 'PASSWORD_RESET'
       AND (NULLIF(btrim(coalesce(email, '')), '') IS NOT NULL
            OR NULLIF(btrim(coalesce(phone, '')), '') IS NOT NULL))
  );

-- The send chain, as in 20260927000058 and 20260927000127. notify_user writes
-- through unconditionally here: what is under test is WHICH rows a filed
-- appeal produces, and routing them to a queue this fixture never drains
-- would make every assertion vacuously true.
CREATE FUNCTION public.notify_user(
  p_user_id uuid, p_type public.notification_type,
  p_title text, p_body text, p_data jsonb DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF p_user_id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.notifications (user_id, type, title, body, data)
  VALUES (p_user_id, p_type, p_title, p_body, coalesce(p_data, '{}'::jsonb))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

CREATE FUNCTION public.notify_user_once(
  p_idem_key text, p_user_id uuid, p_type public.notification_type,
  p_title text, p_body text, p_data jsonb DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF p_user_id IS NULL OR p_idem_key IS NULL OR p_idem_key = '' THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.notifications
              WHERE data ->> 'idem_key' = p_idem_key) THEN
    RETURN NULL;
  END IF;
  v_id := public.notify_user(
    p_user_id, p_type, p_title, p_body,
    coalesce(p_data, '{}'::jsonb) || jsonb_build_object('idem_key', p_idem_key));
  RETURN v_id;
END;
$$;

CREATE FUNCTION public.notify_user_safe(
  p_idem_key text, p_user_id uuid, p_type public.notification_type,
  p_title text, p_body text, p_data jsonb DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  v_id := public.notify_user_once(p_idem_key, p_user_id, p_type, p_title, p_body, p_data);
  RETURN v_id IS NOT NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END;
$$;

-- The 0058 version of the trigger function, so the replay shows 0131 actually
-- changing behaviour rather than a function that was already correct.
CREATE OR REPLACE FUNCTION public.fn_notify_appeal_case_filed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.notify_user(
    NEW.respondent_id, 'APPEAL_FILED', 'A case was filed about you',
    'Someone opened a support case that names you.',
    jsonb_build_object('appeal_case_id', NEW.id));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_cases_notify_filed ON public.appeal_cases;
CREATE TRIGGER trg_appeal_cases_notify_filed
  AFTER INSERT ON public.appeal_cases
  FOR EACH ROW EXECUTE FUNCTION public.fn_notify_appeal_case_filed();

-- `anon` must EXIST for the report's has_function_privilege check to mean
-- anything: a role that is absent makes the check raise rather than answer.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
END $$;