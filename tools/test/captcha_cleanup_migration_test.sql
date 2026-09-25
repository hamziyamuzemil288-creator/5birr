-- Regression harness for 20260924000010_preserve_solved_captcha.sql.
-- Run against a disposable PostgreSQL database:
--   cp supabase/migrations/20260924000010_preserve_solved_captcha.sql /tmp/
--   sudo -u postgres createdb captcha_cleanup_test
--   sudo -u postgres psql -d captcha_cleanup_test -f tools/test/captcha_cleanup_migration_test.sql

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE public.captcha_challenges (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  answer text NOT NULL,
  used_at timestamptz,
  solved_at timestamptz,
  consumed_at timestamptz,
  consumed_target text,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '15 minutes',
  created_at timestamptz NOT NULL DEFAULT now()
);

\ir /tmp/20260924000010_preserve_solved_captcha.sql

-- Reproduce the production sequence: challenge A is solved, then challenge B
-- is requested by another client before A reaches login-gate.
CREATE TEMP TABLE challenge_a AS
SELECT * FROM public.request_captcha();
UPDATE public.captcha_challenges
   SET used_at = now(), solved_at = now()
 WHERE id = (SELECT captcha_id FROM challenge_a);

CREATE TEMP TABLE challenge_b AS
SELECT * FROM public.request_captcha();

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.captcha_challenges
     WHERE id = (SELECT captcha_id FROM challenge_a)
       AND solved_at IS NOT NULL
       AND consumed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'a later request deleted the solved unconsumed challenge';
  END IF;

  IF (SELECT captcha_id FROM challenge_a) = (SELECT captcha_id FROM challenge_b) THEN
    RAISE EXCEPTION 'request_captcha returned a duplicate id';
  END IF;
END $$;

-- Wrong answers remain disposable and must still be cleaned up.
INSERT INTO public.captcha_challenges(answer, used_at)
VALUES ('999', now());
CREATE TEMP TABLE challenge_c AS
SELECT * FROM public.request_captcha();
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.captcha_challenges WHERE answer = '999'
  ) THEN
    RAISE EXCEPTION 'wrong CAPTCHA attempt was not cleaned up';
  END IF;
END $$;

\echo 'CAPTCHA CLEANUP REGRESSION TEST PASSED'
