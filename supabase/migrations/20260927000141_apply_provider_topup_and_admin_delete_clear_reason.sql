-- 20260927000141 — provider topup RPC + admin image delete clear-reason wrapper
--
-- WHAT THIS ADDS
-- -------------
-- 1. public.apply_provider_topup(p_provider_id, p_amount, p_note) — a
--    provider-facing, RLS-bypassing SERVER function that credits the
--    provider wallet and writes a wallet_transaction row, so a provider can
--    proceed with a transaction from a settings/button path instead of only
--    from the cash-recharge admin screen.
--
--    Self-scoped: a provider may only top up their OWN wallet. The caller's
--    uid is matched to provider_profiles.user_id, never to a parameter.
--
--    Best-effort audit: if audit_logs is missing the call still succeeds, it
--    just does not write the audit row.
--
-- 2. public.admin_moderate_image_with_reason(p_bucket, p_path, p_reason,
--    p_severity) — a thin wrapper around admin_moderate_image that catches
--    the server-side exceptions and re-raises them with a stable, human
--    message the client can show instead of a raw PostgREST error string.
--    This is what makes the admin sidebar delete say WHY it failed rather
--    than "not permitted" for every refusal.
--
--    It is NOT a permissions change. It still calls is_admin() inside the
--    real function. It only makes the refusal readable.

-- ===========================================================================
-- 1. Provider topup
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.apply_provider_topup(
  p_provider_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS public.wallet_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider public.provider_profiles;
  v_wallet public.wallets;
  v_row public.wallet_transactions;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  -- Self-scope: the caller may only credit their OWN provider wallet.
  SELECT pp.* INTO v_provider
    FROM public.provider_profiles pp
   WHERE pp.id = p_provider_id;

  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'NO_SUCH_PROVIDER';
  END IF;

  IF v_provider.user_id <> auth.uid() THEN
    RAISE EXCEPTION 'NOT_YOUR_WALLET';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'AMOUNT_MUST_BE_POSITIVE';
  END IF;

  -- Ensure a wallet row exists for the provider (idempotent best-effort).
  INSERT INTO public.wallets (provider_id, balance, currency)
    VALUES (p_provider_id, 0, 'ETB')
    ON CONFLICT (provider_id) DO NOTHING;

  UPDATE public.wallets
     SET balance = balance + p_amount
   WHERE provider_id = p_provider_id
   RETURNING * INTO v_wallet;

  INSERT INTO public.wallet_transactions (
      provider_id, transaction_type, amount, currency, balance_after, note
    )
    VALUES (
      p_provider_id, 'MANUAL_TOPUP', p_amount, 'ETB',
      coalesce(v_wallet.balance, 0)::numeric, nullif(btrim(coalesce(p_note, '')), '')
    )
  RETURNING * INTO v_row;

  -- Audit, best-effort: missing table must not fail the topup.
  BEGIN
    INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
      VALUES (auth.uid(), 'WALLET_TOPUP', 'wallet', p_provider_id,
              jsonb_build_object('amount', p_amount::text, 'note', p_note));
  EXCEPTION WHEN undefined_table OR undefined_column THEN
    NULL;
  END;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_provider_topup(uuid, numeric, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.apply_provider_topup(uuid, numeric, text)
  TO authenticated, service_role;

-- ===========================================================================
-- 2. Admin image delete — clear-reason wrapper
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.admin_moderate_image_with_reason(
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
BEGIN
  -- This delegates to the real function, which still enforces is_admin()
  -- and every other rule. We only catch its exceptions so the client sees
  -- a stable sentence instead of a raw PostgREST error.
  RETURN public.admin_moderate_image(p_bucket, p_path, p_reason, p_severity);
EXCEPTION
  WHEN raise_exception THEN
    -- Postgres raise_exception keeps the message we raised; re-raise it
    -- unchanged so the client reads the server's own refusal reason.
    RAISE;
  WHEN OTHERS THEN
    -- Anything else (storage unavailable, internal error) becomes a single
    -- readable sentence rather than a stack the moderator cannot act on.
    RAISE EXCEPTION 'IMAGE_MODERATION_FAILED: %', SQLERRM;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_moderate_image_with_reason(text, text, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_moderate_image_with_reason(text, text, text, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
