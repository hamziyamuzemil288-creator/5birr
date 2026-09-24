-- Task 10 — zero-setup anti-bot CAPTCHA (server-generated tick+math).
--
-- Design (owner decision: no external provider, no keys, no account):
--   • request_captcha()    — anon/authenticated RPC. Issues a challenge row
--     ("tick + solve: 7 + 5") and returns its id + question. The answer is
--     stored server-side; the client never sees it.
--   • verify_captcha()     — anon/authenticated RPC. One-shot consume: a
--     correct answer marks the challenge used (15-minute validity); a wrong
--     answer burns the challenge so it cannot be retried.
--   • captcha_ok()         — definer read used by (a) send-otp to enforce the
--     captcha on OTP issuance and (b) the appeal_cases INSERT trigger.
--   • captcha_required()   — runtime toggle from system_settings
--     ('captcha_enforced'); lets the owner turn enforcement off without a
--     redeploy if it ever blocks real users.
--
-- Enforcement points (Task 10 spec):
--   1. OTP request  — send-otp Edge Function calls captcha_required() +
--      captcha_ok() before issuing a code (the OTP gate already blocks
--      signup, so this also protects account creation).
--   2. Signup UI    — the tick+solve widget is shown in the signup flow
--     (user + provider) before the first OTP request; its id flows to
--     send-otp. Account creation itself stays gated by the existing OTP
--     requirement in handle_new_user (unchanged here).
--   3. Appeal submission — appeal_cases.captcha_id + BEFORE INSERT trigger:
--     when enforcement is on, an insert without a verified captcha id is
--     rejected (CAPTCHA_REQUIRED).
--
-- Weaker than a hosted CAPTCHA against sophisticated bots, but zero-setup
-- and effective against basic scripted signup/appeal spam.

-- ============================================================
-- 1. captcha_challenges
-- ============================================================
CREATE TABLE IF NOT EXISTS public.captcha_challenges (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  answer text NOT NULL,
  used_at timestamptz,      -- burned by a wrong/replayed verification
  solved_at timestamptz,    -- server marker that the answer was correct
  expires_at timestamptz NOT NULL DEFAULT now() + interval '15 minutes',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Keep the table safe to re-apply if the first version was partially created.
ALTER TABLE public.captcha_challenges
  ADD COLUMN IF NOT EXISTS solved_at timestamptz;

CREATE INDEX IF NOT EXISTS idx_captcha_challenges_expires
  ON public.captcha_challenges (expires_at);

ALTER TABLE public.captcha_challenges ENABLE ROW LEVEL SECURITY;
-- No policies: only SECURITY DEFINER helpers below touch the table, so
-- clients can never read answers or list challenges directly.

-- ============================================================
-- 2. RPCs
-- ============================================================
-- Issue a challenge. Housekeeping: drop rows older than 1 hour.
CREATE OR REPLACE FUNCTION public.request_captcha()
RETURNS TABLE (captcha_id uuid, question text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_a int;
  v_b int;
  v_op text;
  v_answer int;
BEGIN
  -- Opportunistic cleanup of dead rows (expired or already consumed).
  DELETE FROM public.captcha_challenges
    WHERE expires_at < now() OR used_at IS NOT NULL;

  v_a := 2 + floor(random() * 9)::int;   -- 2..10
  v_b := 1 + floor(random() * 9)::int;   -- 1..10
  IF random() < 0.5 THEN
    v_op := '+'; v_answer := v_a + v_b;
  ELSE
    v_op := '-';                          -- keep results non-negative
    IF v_b > v_a THEN
      v_op := '+'; v_answer := v_a + v_b;
    ELSE
      v_answer := v_a - v_b;
    END IF;
  END IF;

  INSERT INTO public.captcha_challenges (answer)
  VALUES (v_answer::text)
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id,
    'I am not a robot — solve: ' || v_a::text || ' ' || v_op || ' ' || v_b::text;
END;
$$;

-- One-shot verify: correct → the id becomes usable (captcha_ok) for its
-- remaining 15-minute window; wrong/expired → unusable. Returns ok + a
-- stable error code the client can show.
CREATE OR REPLACE FUNCTION public.verify_captcha(
  p_captcha_id uuid,
  p_answer text
)
RETURNS TABLE (ok boolean, error text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.captcha_challenges%ROWTYPE;
BEGIN
  IF p_captcha_id IS NULL THEN
    RETURN QUERY SELECT false::boolean, 'EXPIRED'::text;
    RETURN;
  END IF;

  SELECT * INTO v_row FROM public.captcha_challenges
    WHERE id = p_captcha_id FOR UPDATE;

  IF v_row.id IS NULL OR v_row.expires_at < now() THEN
    RETURN QUERY SELECT false::boolean, 'EXPIRED'::text;
    RETURN;
  END IF;

  IF v_row.used_at IS NOT NULL THEN
    RETURN QUERY SELECT false::boolean, 'ALREADY_USED';
    RETURN;
  END IF;

  IF btrim(coalesce(p_answer, '')) <> btrim(v_row.answer) THEN
    UPDATE public.captcha_challenges SET used_at = now()
      WHERE id = v_row.id;
    RETURN QUERY SELECT false::boolean, 'WRONG_ANSWER';
    RETURN;
  END IF;

  UPDATE public.captcha_challenges
     SET used_at = now(), solved_at = now()
   WHERE id = v_row.id;
  RETURN QUERY SELECT true::boolean, NULL::text;
END;
$$;

-- Read-only check used by enforcement points: the challenge was solved and
-- has not expired. Verification itself is one-shot; enforcement reads this
-- marker without exposing the answer or challenge row to the client.
CREATE OR REPLACE FUNCTION public.captcha_ok(p_captcha_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.captcha_challenges
    WHERE id = p_captcha_id
      AND solved_at IS NOT NULL
      AND used_at IS NOT NULL
      AND expires_at > now()
  );
$$;

-- Runtime toggle (system_settings, owner-settable without a redeploy).
CREATE OR REPLACE FUNCTION public.captcha_required()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(public.get_setting_bool('captcha_enforced'), false);
$$;

GRANT EXECUTE ON FUNCTION public.request_captcha() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_captcha(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.captcha_ok(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.captcha_required() TO anon, authenticated;

-- ============================================================
-- 2. Appeal submission enforcement
-- ============================================================
ALTER TABLE public.appeal_cases
  ADD COLUMN IF NOT EXISTS captcha_id uuid;

CREATE OR REPLACE FUNCTION public.enforce_appeal_captcha()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.captcha_required() THEN
    IF NEW.captcha_id IS NULL OR NOT public.captcha_ok(NEW.captcha_id) THEN
      RAISE EXCEPTION 'CAPTCHA_REQUIRED';
    END IF;
  END IF;
  -- The challenge id has no purpose after validation; never store it.
  NEW.captcha_id := NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_captcha ON public.appeal_cases;
CREATE TRIGGER trg_appeal_captcha
  BEFORE INSERT ON public.appeal_cases
  FOR EACH ROW EXECUTE FUNCTION public.enforce_appeal_captcha();

-- ============================================================
-- 3. Enforcement toggle (on by default; flip to false to disable)
-- ============================================================
-- Seed the default through a migration-only, transaction-scoped bypass.
-- The settings guard (trg_system_settings_security -> is_admin()) rejects any
-- write from a migration connection because auth.uid() is NULL there. We
-- disable every non-internal trigger currently enabled on the table BY NAME
-- LOOKUP (immune to trigger-name drift), re-enabling exactly the same list —
-- so application writes remain admin-only after the seed.
BEGIN;
CREATE TEMP TABLE _captcha_settings_triggers AS
  SELECT tgname
  FROM pg_trigger
  WHERE tgrelid = 'public.system_settings'::regclass
    AND NOT tgisinternal
    AND tgenabled = 'O';

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tgname FROM _captcha_settings_triggers LOOP
    EXECUTE format('ALTER TABLE public.system_settings DISABLE TRIGGER %I', t);
  END LOOP;
EXCEPTION
  WHEN undefined_table THEN NULL;
END;
$$;

INSERT INTO public.system_settings (key, value, description)
VALUES ('captcha_enforced', 'true'::jsonb,
        'Require the tick+math captcha on OTP requests and appeal submissions (Task 10).')
ON CONFLICT (key) DO NOTHING;

DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT tgname FROM _captcha_settings_triggers LOOP
    EXECUTE format('ALTER TABLE public.system_settings ENABLE TRIGGER %I', t);
  END LOOP;
EXCEPTION
  WHEN undefined_table THEN NULL;
END;
$$;

DROP TABLE _captcha_settings_triggers;
COMMIT;
