-- 5BIRR — Points system (Feature 3)
-- Migration 0028_points_system.sql
-- Applied: 2026-09-18
--
-- Points are awarded ONLY on transitions into a genuinely COMPLETED state
-- (never on pending/unconfirmed rows):
--   * orders:        status -> COMPLETED   (user + provider each earn)
--   * ride_requests: status -> COMPLETED   (rider + claiming provider earn)
--
-- Design:
--   * points_ledger  — immutable audit of every award; UNIQUE(source_type,
--     source_id, subject_id) makes awards idempotent, so a COMPLETED ->
--     DISPUTED -> COMPLETED round-trip can never double-award.
--   * user_points    — fast per-subject total, bumped only when the ledger
--     insert actually landed (RETURNING), keeping both in lockstep.
--   * points_per_trade in system_settings (default 1) — one knob to change
--     future point values; also lets admins disable awards by setting 0.
--   * RLS: subjects can read their own points; admins read anyone's. No
--     client-write policies — only the SECURITY DEFINER triggers write.
--     Admin UI adjustments can reuse the ledger shape (insert rows with a
--     NULL source via a future admin RPC) — deliberately out of scope here.

-- ── Setting: points per completed trade (adjustable, labeled) ──
-- trg_system_settings_security blocks ALL inserts unless an admin is
-- logged in, so lift it briefly for this one-time seed (same transaction).
BEGIN;
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;
INSERT INTO public.system_settings (key, value, description)
VALUES ('points_per_trade', '1'::jsonb,
        'Points awarded per completed trade (order or ride), to each side')
ON CONFLICT (key) DO NOTHING;
ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;
COMMIT;

-- ── Ledger ──
CREATE TABLE IF NOT EXISTS public.points_ledger (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL CHECK (subject_type IN ('USER','PROVIDER')),
  subject_id   uuid NOT NULL,
  source_type  text NOT NULL CHECK (source_type IN ('ORDER','RIDE')),
  source_id    uuid NOT NULL,
  points       integer NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT points_ledger_source_unique UNIQUE (source_type, source_id, subject_id)
);
CREATE INDEX IF NOT EXISTS idx_points_ledger_subject
  ON public.points_ledger (subject_type, subject_id);

-- ── Fast totals ──
CREATE TABLE IF NOT EXISTS public.user_points (
  subject_type text NOT NULL CHECK (subject_type IN ('USER','PROVIDER')),
  subject_id   uuid NOT NULL,
  points       integer NOT NULL DEFAULT 0,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_points_pk PRIMARY KEY (subject_type, subject_id)
);

-- ── RLS: self-read + admin-read; no client writes ──
ALTER TABLE public.points_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_points   ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS points_ledger_select ON public.points_ledger;
CREATE POLICY points_ledger_select ON public.points_ledger
  FOR SELECT TO authenticated
  USING (
    (subject_type = 'USER' AND subject_id = auth.uid())
    OR (subject_type = 'PROVIDER' AND subject_id IN (
          SELECT id FROM public.provider_profiles WHERE user_id = auth.uid()))
    OR public.is_admin()
  );

DROP POLICY IF EXISTS user_points_select ON public.user_points;
CREATE POLICY user_points_select ON public.user_points
  FOR SELECT TO authenticated
  USING (
    (subject_type = 'USER' AND subject_id = auth.uid())
    OR (subject_type = 'PROVIDER' AND subject_id IN (
          SELECT id FROM public.provider_profiles WHERE user_id = auth.uid()))
    OR public.is_admin()
  );

GRANT SELECT ON public.points_ledger TO authenticated;
GRANT SELECT ON public.user_points   TO authenticated;

-- ── Award function: orders ──
CREATE OR REPLACE FUNCTION public.fn_award_order_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_points integer;
  v_awarded uuid;
BEGIN
  SELECT get_setting_numeric('points_per_trade')::integer INTO v_points;
  IF v_points IS NULL OR v_points <= 0 THEN RETURN NEW; END IF;

  -- User side
  INSERT INTO points_ledger (subject_type, subject_id, source_type, source_id, points)
  VALUES ('USER', NEW.user_id, 'ORDER', NEW.id, v_points)
  ON CONFLICT (source_type, source_id, subject_id) DO NOTHING
  RETURNING id INTO v_awarded;
  IF v_awarded IS NOT NULL THEN
    INSERT INTO user_points (subject_type, subject_id, points)
    VALUES ('USER', NEW.user_id, v_points)
    ON CONFLICT (subject_type, subject_id)
    DO UPDATE SET points = user_points.points + v_points, updated_at = now();
  END IF;

  -- Provider side
  v_awarded := NULL;
  INSERT INTO points_ledger (subject_type, subject_id, source_type, source_id, points)
  VALUES ('PROVIDER', NEW.provider_id, 'ORDER', NEW.id, v_points)
  ON CONFLICT (source_type, source_id, subject_id) DO NOTHING
  RETURNING id INTO v_awarded;
  IF v_awarded IS NOT NULL THEN
    INSERT INTO user_points (subject_type, subject_id, points)
    VALUES ('PROVIDER', NEW.provider_id, v_points)
    ON CONFLICT (subject_type, subject_id)
    DO UPDATE SET points = user_points.points + v_points, updated_at = now();
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_orders_points ON public.orders;
CREATE TRIGGER trg_orders_points
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'COMPLETED' AND OLD.status IS DISTINCT FROM 'COMPLETED')
  EXECUTE FUNCTION public.fn_award_order_points();

-- ── Award function: rides ──
CREATE OR REPLACE FUNCTION public.fn_award_ride_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_points integer;
  v_awarded uuid;
BEGIN
  SELECT get_setting_numeric('points_per_trade')::integer INTO v_points;
  IF v_points IS NULL OR v_points <= 0 THEN RETURN NEW; END IF;

  -- Rider
  INSERT INTO points_ledger (subject_type, subject_id, source_type, source_id, points)
  VALUES ('USER', NEW.user_id, 'RIDE', NEW.id, v_points)
  ON CONFLICT (source_type, source_id, subject_id) DO NOTHING
  RETURNING id INTO v_awarded;
  IF v_awarded IS NOT NULL THEN
    INSERT INTO user_points (subject_type, subject_id, points)
    VALUES ('USER', NEW.user_id, v_points)
    ON CONFLICT (subject_type, subject_id)
    DO UPDATE SET points = user_points.points + v_points, updated_at = now();
  END IF;

  -- Claiming provider (may be NULL if the ride completed unclaimed)
  IF NEW.claimed_by_provider_id IS NOT NULL THEN
    v_awarded := NULL;
    INSERT INTO points_ledger (subject_type, subject_id, source_type, source_id, points)
    VALUES ('PROVIDER', NEW.claimed_by_provider_id, 'RIDE', NEW.id, v_points)
    ON CONFLICT (source_type, source_id, subject_id) DO NOTHING
    RETURNING id INTO v_awarded;
    IF v_awarded IS NOT NULL THEN
      INSERT INTO user_points (subject_type, subject_id, points)
      VALUES ('PROVIDER', NEW.claimed_by_provider_id, v_points)
      ON CONFLICT (subject_type, subject_id)
      DO UPDATE SET points = user_points.points + v_points, updated_at = now();
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_rides_points ON public.ride_requests;
CREATE TRIGGER trg_rides_points
  AFTER UPDATE ON public.ride_requests
  FOR EACH ROW
  WHEN (NEW.status = 'COMPLETED' AND OLD.status IS DISTINCT FROM 'COMPLETED')
  EXECUTE FUNCTION public.fn_award_ride_points();
