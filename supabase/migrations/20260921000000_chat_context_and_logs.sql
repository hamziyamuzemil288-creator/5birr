-- Chatbot upgrade: per-user data context for the in-app assistant + a
-- feedback log that powers the self-improvement loop.
--
-- 1) chat_logs — one row per assistant reply, with the user's optional
--    thumbs up/down. Written by the app (RLS: users see/grade only their
--    own rows); reviewed by admins via the summary RPC below.
-- 2) user_chat_context(...) — SECURITY DEFINER read-only aggregation of the
--    signed-in user's live status (wallet, orders, rides, provider state,
--    subscription). Called by the repo-chat Edge Function (service role) so
--    answers reflect the caller's actual account, not generic help text.

CREATE TABLE IF NOT EXISTS chat_logs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'assistant')),
  content text NOT NULL,
  intent text,
  helpful boolean,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_logs_user_created_idx
  ON chat_logs (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS chat_logs_unrated_idx
  ON chat_logs (created_at DESC) WHERE helpful IS NULL AND role = 'assistant';

ALTER TABLE chat_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS chat_logs_select_own ON chat_logs;
CREATE POLICY chat_logs_select_own ON chat_logs
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS chat_logs_insert_own ON chat_logs;
CREATE POLICY chat_logs_insert_own ON chat_logs
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS chat_logs_rate_own ON chat_logs;
CREATE POLICY chat_logs_rate_own ON chat_logs
  FOR UPDATE USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- No DELETE policy: conversation history is append-only for users.

-- ── Live per-user context for the assistant ──────────────────────────────
-- Returns a small JSON blob describing the caller's current state. The
-- Edge Function embeds this in its retrieval query; it is data the user can
-- already see in the app, so exposing it back to them is safe.
CREATE OR REPLACE FUNCTION public.user_chat_context()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_provider uuid;
  v_wallet numeric(12, 2);
  v_provider_status text;
  v_subscription jsonb;
  v_orders jsonb;
  v_ride jsonb;
BEGIN
  IF v_user IS NULL THEN
    RETURN jsonb_build_object('authenticated', false);
  END IF;

  SELECT pp.id, pp.status INTO v_provider, v_provider_status
  FROM provider_profiles pp
  WHERE pp.user_id = v_user
  LIMIT 1;

  IF v_provider IS NOT NULL THEN
    SELECT w.balance INTO v_wallet
    FROM wallets w
    WHERE w.provider_id = v_provider
    LIMIT 1;

    SELECT jsonb_build_object(
             'status', s.status,
             'next_due_date', s.next_due_date
           )
    INTO v_subscription
    FROM subscriptions s
    WHERE s.provider_id = v_provider
    ORDER BY s.created_at DESC
    LIMIT 1;
  END IF;

  SELECT jsonb_agg(
           jsonb_build_object('status', o.status, 'total_amount', o.total_amount)
           ORDER BY o.created_at DESC
         )
  INTO v_orders
  FROM (
    SELECT o.status, o.total_amount, o.created_at
    FROM orders o
    WHERE o.user_id = v_user
    ORDER BY o.created_at DESC
    LIMIT 5
  ) o;

  SELECT jsonb_build_object(
           'status', r.status,
           'created_at', r.created_at
         )
  INTO v_ride
  FROM ride_requests r
  WHERE r.user_id = v_user
    AND r.status NOT IN ('COMPLETED', 'CANCELLED', 'REJECTED')
  ORDER BY r.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'authenticated', true,
    'is_provider', v_provider IS NOT NULL,
    'provider_status', v_provider_status,
    'wallet_balance', v_wallet,
    'subscription', v_subscription,
    'recent_orders', COALESCE(v_orders, '[]'::jsonb),
    'active_ride', v_ride
  );
END;
$$;

REVOKE ALL ON FUNCTION public.user_chat_context() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.user_chat_context() TO authenticated;

-- ── Feedback-loop summary (admins only): worst-rated, unresolved chats ───
CREATE OR REPLACE FUNCTION public.chat_low_rated_summary(p_days int DEFAULT 30)
RETURNS TABLE (
  intent text,
  thumbs_down bigint,
  thumbs_up bigint,
  sample_question text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
BEGIN
  IF NOT has_role('ADMIN') THEN
    RAISE EXCEPTION 'admin role required';
  END IF;

  RETURN QUERY
  SELECT
    l.intent,
    count(*) FILTER (WHERE l.helpful = false) AS thumbs_down,
    count(*) FILTER (WHERE l.helpful = true) AS thumbs_up,
    (array_agg(l.content) FILTER (WHERE l.role = 'user'))[1] AS sample_question
  FROM chat_logs l
  WHERE l.created_at >= now() - make_interval(days => GREATEST(p_days, 1))
  GROUP BY l.intent
  HAVING count(*) FILTER (WHERE l.helpful = false) > 0
  ORDER BY thumbs_down DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.chat_low_rated_summary(int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_low_rated_summary(int) TO authenticated;
