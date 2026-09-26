-- 0049 — Option C rate limiting: the rate_limits table from the 0024
-- resilience notes, actually built.
--
-- WHY THIS FILE EXISTS
-- -------------------
-- 0024_resilience_hardening.sql proposed Option C as a SQL comment only. The
-- CREATE TABLE and the check_rate_limit function were never executed, so
-- neither exists in the database. Nothing in lib/ called check_rate_limit.
-- This file builds the real thing.
--
-- RLS POSTURE — default-deny, deliberately policyless
-- -------------------------------------------------
-- rate_limits holds per-user request counters. RLS is enabled and NO policies
-- are created, which means anon and authenticated get zero rows: a client
-- cannot read how many requests any user has made, cannot inflate their own
-- counter, and cannot reset anyone else's. This is the same default-deny
-- shape already used for login_attempts, captcha_challenges and chat_usage,
-- where table access is expected to arrive through SECURITY DEFINER
-- functions or the service role rather than directly.
--
-- The table is NOT a client-facing API surface. Do not add a policy to "fix"
-- a read error from a screen — call check_rate_limit instead.
--
-- SECURITY DEFINER + the search_path trap
-- ---------------------------------------
-- check_rate_limit writes on behalf of its caller, so it must be SECURITY
-- DEFINER. That makes it able to do things the caller could not, so the
-- function is owned by postgres and pins its own search_path. Without
-- `SET search_path = public, pg_temp` a caller who can create objects in a
-- schema ahead of public could shadow the table or the function. Revoking
-- EXECUTE from public is not enough on its own; the search_path is the part
-- that actually holds.
--
-- WHY p_user_id IS A PARAMETER AND NOT auth.uid()
-- -------------------------------------------------
-- Same trap as delete_staff (20260925190000) and create_staff_gateway (0035):
-- an Edge Function calling this with the service-role client carries no
-- end-user JWT, so auth.uid() would be NULL. The caller resolves the user
-- from the caller's own verified JWT and passes it explicitly. Because the
-- function is service-role-only (see grants below), an end user cannot pass
-- somebody else's id to burn their budget.
--
-- WINDOW ARITHMETIC — the proposal's version was wrong
-- ----------------------------------------------------
-- The 0024 comment computed its window as:
--
--     v_window := date_trunc('second', now()) - (p_window_seconds || ' seconds')::interval;
--
-- and then matched `window_start >= v_window` while INSERTING with
-- window_start = date_trunc('second', now()). That is a moving window keyed to
-- a per-second bucket, so a caller at second 59 and one at second 00 are
-- counted in different buckets with the same conflict target — requests
-- spread across a bucket boundary escape the limit. It is also a window that
-- never expires old rows, so the table grows without bound.
--
-- This version uses a fixed bucket derived from now() and the window length,
-- so the UNIQUE key is stable for the whole window and the limit holds across
-- bucket boundaries. A cleanup helper is provided; it is not scheduled by a
-- pg_cron extension (not enabled, and adding an extension is a dependency
-- decision rather than a migration decision) — it is callable and safe to
-- schedule later, and is invoked opportunistically from check_rate_limit at a
-- low probability so the table stays bounded without a scheduler.

CREATE TABLE IF NOT EXISTS public.rate_limits (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  endpoint      text NOT NULL,
  window_start  timestamptz NOT NULL,
  request_count integer NOT NULL DEFAULT 1,
  CONSTRAINT rate_limits_window_unique UNIQUE (user_id, endpoint, window_start)
);

CREATE INDEX IF NOT EXISTS rate_limits_user_endpoint_idx
  ON public.rate_limits (user_id, endpoint);

-- Default-deny: enabled, no policies. See the posture note at the top.
ALTER TABLE public.rate_limits ENABLE ROW LEVEL SECURITY;

-- Bound the table. Windows that ended long ago can never affect a decision.
CREATE INDEX IF NOT EXISTS rate_limits_window_start_idx
  ON public.rate_limits (window_start);

COMMENT ON TABLE public.rate_limits IS
  'Per-user, per-endpoint request counters for Option C rate limiting. RLS enabled with no policies (default-deny): access is expected via check_rate_limit (SECURITY DEFINER) or the service role, never directly from a client.';

-- Opportunistic cleanup. Deliberately low-probability: it is a safety net for
-- unbounded growth, not the primary retention mechanism.
CREATE OR REPLACE FUNCTION public.purge_expired_rate_limits()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_deleted integer;
BEGIN
  DELETE FROM public.rate_limits
   WHERE window_start < now() - interval '1 day';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_expired_rate_limits() FROM public, anon, authenticated;

-- Returns true when the caller is still within budget. The counter is
-- incremented first and the post-increment total is compared, so the
-- p_max_requests'th call in a window returns true and the next returns false.
CREATE OR REPLACE FUNCTION public.check_rate_limit(
  p_user_id         uuid,
  p_endpoint        text,
  p_max_requests    integer DEFAULT 10,
  p_window_seconds  integer DEFAULT 60
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bucket  timestamptz;
  v_count   integer;
BEGIN
  IF p_user_id IS NULL OR p_endpoint IS NULL OR p_endpoint = '' THEN
    -- Never fail open or closed silently on a malformed call: refuse.
    RETURN false;
  END IF;
  IF p_max_requests IS NULL OR p_max_requests < 1 THEN
    p_max_requests := 10;
  END IF;
  IF p_window_seconds IS NULL OR p_window_seconds < 1 THEN
    p_window_seconds := 60;
  END IF;

  -- Fixed window: stable for the whole window, so the UNIQUE conflict target
  -- does not move under the caller mid-window.
  v_bucket := to_timestamp(
    floor(extract(epoch FROM now()) / p_window_seconds) * p_window_seconds
  );

  INSERT INTO public.rate_limits (user_id, endpoint, window_start, request_count)
  VALUES (p_user_id, p_endpoint, v_bucket, 1)
  ON CONFLICT (user_id, endpoint, window_start)
  DO UPDATE SET request_count = public.rate_limits.request_count + 1
  RETURNING request_count INTO v_count;

  -- ~1% of calls also trim expired windows. Cheap, and keeps an unused
  -- deployment from growing without bound.
  IF random() < 0.01 THEN
    PERFORM public.purge_expired_rate_limits();
  END IF;

  RETURN v_count <= p_max_requests;
END;
$$;

REVOKE ALL ON FUNCTION public.check_rate_limit(uuid, text, integer, integer)
  FROM public, anon, authenticated;

-- Service role only, matching delete_staff and create_staff_gateway: the
-- caller is an Edge Function that already authenticated the end user from
-- their JWT. Granting this to authenticated would let any signed-up user
-- burn another user's budget by passing their id.
GRANT EXECUTE ON FUNCTION public.check_rate_limit(uuid, text, integer, integer)
  TO service_role;

COMMENT ON FUNCTION public.check_rate_limit(uuid, text, integer, integer) IS
  'Fixed-window request budget check. SECURITY DEFINER, service_role only. p_user_id is passed explicitly (not auth.uid()) because a service-role Edge Function call carries no end-user JWT — see delete_staff (20260925190000). Returns false when the caller is over budget.';
