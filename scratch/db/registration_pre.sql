-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- The schema 20260927000130_a_submission_tells_both_sides.sql reads and writes,
-- and nothing else. Purpose-built rather than an extension of scratch/db/
-- fee_pre.sql so the two replays cannot perturb each other: this file is about
-- who gets told about a submission, that one is about per-category fees, and a
-- shared fixture would mean a change to either test silently altered the
-- other.
--
-- postgis and uuid-ossp are unavailable in this sandbox, so ids are supplied
-- by the probe rather than generated. The notification_type enum is declared
-- with the SAME members the real database has, including REGISTRATION_RECEIVED
-- -- which exists since 0001 and which 0130 is the first thing to write.

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

-- The real enum, verbatim from 0001 plus every value added since. A fixture
-- that declared only the values 0130 happens to use could not catch a typo
-- against a member that exists only in production.
CREATE TYPE public.notification_type AS ENUM (
  'REGISTRATION_RECEIVED','APPROVAL','REJECTION','CORRECTION_REQUIRED',
  'ADMIN_MESSAGE','ORDER_RECEIVED','ORDER_ACCEPTED','ORDER_REJECTED',
  'RIDE_REQUEST','RIDE_CLAIMED','RIDE_TAKEN','RIDE_STARTED','RIDE_COMPLETED',
  'PAYMENT_REMINDER','PAYMENT_PROOF_REQUIRED','WALLET_LOW','WALLET_EMPTY',
  'SUBSCRIPTION_DUE','PROVIDER_INACTIVE','TRANSACTION_FEE_DEDUCTED','SECURITY'
);

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  full_name text,
  city text,
  status text DEFAULT 'PENDING_APPROVAL',
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  business_name text NOT NULL DEFAULT '',
  category_id uuid,
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

-- The table 0130 puts a trigger on. `status` is text rather than the real
-- account_status enum because the probe writes the literals directly and the
-- comparison under test is on the string, not on the type.
CREATE TABLE public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'PENDING_APPROVAL',
  created_at timestamptz NOT NULL DEFAULT now()
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

CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid, event_type text NOT NULL, entity_type text, entity_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb, created_at timestamptz DEFAULT now()
);

-- The send chain, in the shape 0130 depends on.
--
-- notify_user here writes through unconditionally. On the live database
-- notify_user routes to notification_outbox when is_server_write() is false,
-- and both signup paths ARE client-initiated -- so in production these notices
-- land via the pg_cron drain within a minute. Modelling the write-through here
-- is deliberate: the thing under test is WHICH rows are produced, and routing
-- them to a queue this fixture never drains would make every assertion
-- vacuously true.
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

-- The real signature: (text, uuid, notification_type, text, text, jsonb). An
-- enum has no implicit cast to text, so a third parameter declared `text`
-- makes every call raise -- and notify_user_safe swallows the raise, which is
-- indistinguishable from "nobody was told". 0127 asserts this signature and
-- so does 0130; the fixture declares it correctly so the replay can see a
-- wrong one fail.
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

-- notify_user_safe, verbatim in shape from 20260927000127. 0130 DEPENDS on it
-- and the replay proved that: without this function the trigger raised
-- `function public.notify_user_safe(text, uuid, unknown, unknown, text, jsonb)
-- does not exist` on the first submission. A migration that names a helper
-- another migration created parses cleanly and fails at the first write, which
-- is the whole reason this replay exists.
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

-- The four authorization helpers unsuspend_provider calls. Real logic, not
-- stubs: the point of the probe is that the guard still refuses, and a stub
-- that always returned true would make that assertion meaningless.
CREATE FUNCTION public.is_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles
                  WHERE user_id = auth.uid() AND role = 'ADMIN');
$$;

CREATE FUNCTION public.is_server_write() RETURNS boolean
LANGUAGE sql STABLE AS $f$
  SELECT coalesce(current_setting('role', true), 'none') = 'service_role';
$f$;

CREATE FUNCTION public.staff_has_permission(p_user_id uuid, p_permission text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_permission IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.staff
     WHERE user_id = p_user_id AND is_active
       AND (is_super_admin OR p_permission = ANY (permissions)));
$$;

CREATE FUNCTION public.admin_can(p_permission text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT public.is_admin() OR public.staff_has_permission(auth.uid(), p_permission); $$;

CREATE FUNCTION public.staff_is_action_manager() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_admin() OR public.staff_has_permission(auth.uid(), 'registrations');
$$;

CREATE FUNCTION public.staff_scope_allows_category(p_category_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT true; $$;

CREATE FUNCTION public.staff_scope_allows_city(p_city text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT true; $$;

CREATE FUNCTION public.log_admin_action(
  p_admin_id uuid, p_action text, p_target uuid,
  p_category text, p_city text, p_cities text[] DEFAULT '{}',
  p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END; $$;
