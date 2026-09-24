-- Task 13 item 2: real server-side login throttling.
--
-- The login CAPTCHA alone only slows a script down; credential stuffing is
-- defeated by counting failures per account and locking the target for a
-- cool-off window. This table is the single source of truth and is written
-- ONLY by the user-login Edge Function (service role / SECURITY DEFINER):
-- RLS is enabled with no policies so anon/authenticated clients can neither
-- read nor write it directly.

CREATE TABLE IF NOT EXISTS public.login_attempts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email_key text NOT NULL,          -- normalized lower(email); IP side is hashed
  ip_hash text,                     -- sha256 hex of the client IP, never the raw IP
  success boolean NOT NULL DEFAULT false,
  attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_login_attempts_key_time
  ON public.login_attempts (email_key, attempted_at DESC);

ALTER TABLE public.login_attempts ENABLE ROW LEVEL SECURITY;

-- Count recent failures for a key. STABLE + SECURITY DEFINER so the Edge
-- Function's service-role call cannot be replaced by client-side arithmetic.
CREATE OR REPLACE FUNCTION public.recent_login_failures(
  p_key text,
  p_window interval DEFAULT interval '15 minutes'
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::int
    FROM public.login_attempts
   WHERE email_key = p_key
     AND success = false
     AND attempted_at > now() - p_window;
$$;

-- Record one attempt (and on success clear the failure window so a legit
-- user who mistyped once is never punished later). Also prunes rows older
-- than 7 days on every write to keep the table tiny without a cron job.
CREATE OR REPLACE FUNCTION public.record_login_attempt(
  p_email_key text,
  p_success boolean,
  p_ip_hash text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.login_attempts
   WHERE attempted_at < now() - interval '7 days';

  INSERT INTO public.login_attempts (email_key, ip_hash, success)
  VALUES (p_email_key, p_ip_hash, p_success);

  IF p_success THEN
    DELETE FROM public.login_attempts
     WHERE email_key = p_email_key AND success = false;
  END IF;
END;
$$;

-- Success path helper (kept separate so the Edge Function can clear a
-- stale failure window even on paths that skip recording).
CREATE OR REPLACE FUNCTION public.clear_login_failures(p_key text)
RETURNS void
LANGUAGE sql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
  DELETE FROM public.login_attempts
   WHERE email_key = p_key AND success = false;
$$;

-- These are enforcement internals: no client role may call them directly.
-- service_role keeps EXECUTE: the user-login Edge Function is the only
-- intended caller and authenticates with the service-role key.
REVOKE EXECUTE ON FUNCTION public.recent_login_failures(text, interval) FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.record_login_attempt(text, boolean, text) FROM public, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.clear_login_failures(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.recent_login_failures(text, interval) TO service_role;
GRANT EXECUTE ON FUNCTION public.record_login_attempt(text, boolean, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.clear_login_failures(text) TO service_role;
