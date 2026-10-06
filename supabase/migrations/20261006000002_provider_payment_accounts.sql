-- 5BIRR — the provider's payment accounts, read the way a buyer needs them
-- ===========================================================================
--
-- `provider_payment_methods` is owner-scoped on purpose (migration
-- 20260927000142): a provider's bank, Telebirr and CBE Birr details are
-- private, and the only public read on that table is an administrator's.
-- Widening the table's RLS to `public` would expose every row of it — the
-- inactive ones, the abandoned ones, and the rows of providers nobody has
-- approved — to every caller, forever.
--
-- The buyer flow needs exactly one question answered: "where do I send the
-- money for THIS provider, right now?" This function is that question and
-- nothing else:
--
--   * one provider, by id — no list, no scan;
--   * active rows only;
--   * an APPROVED provider only, unless the caller IS the owner (previewing
--     their own card) or an administrator (dispute/reconciliation), so a
--     pending or rejected account never reaches a buyer;
--   * `stable`, so PostgREST can read it as a plain GET and the check is
--     not a write path.
--
-- The client turns "empty" into a Contact-seller button and "unreadable"
-- into silence — it never blocks a purchase on a failed read.

CREATE OR REPLACE FUNCTION public.provider_payment_accounts(
  p_provider_id uuid
)
RETURNS SETOF public.provider_payment_methods
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT m.*
    FROM public.provider_payment_methods m
    JOIN public.provider_profiles pp
      ON pp.id = m.provider_id
   WHERE m.provider_id = p_provider_id
     AND m.is_active = true
     AND (
       pp.status = 'APPROVED'::account_status
       OR public.owns_provider_profile(m.provider_id)
       OR public.is_admin()
     )
   ORDER BY m.sort_order, m.created_at;
$$;

REVOKE ALL ON FUNCTION public.provider_payment_accounts(uuid)
  FROM PUBLIC;

-- anon on purpose: the product page is public, and this row carries the
-- same information checkout shows the moment a buyer is ready to pay. It is
-- not a balance, not a fee, and nothing about the provider's account with
-- the platform.
GRANT EXECUTE ON FUNCTION public.provider_payment_accounts(uuid)
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.provider_payment_accounts(uuid) IS
  'The ACTIVE payment accounts of one provider, for the buyer about to pay them: APPROVED providers only (or your own rows, or any row if you are an administrator). Exists instead of a public RLS policy on provider_payment_methods so the widened read is exactly this question, not the whole table.';
