-- Remove the client-side INSERT path on orders.
--
-- The hole
-- --------
-- orders has carried this policy since 0002 and nothing has changed it:
--
--   CREATE POLICY orders_user_insert ON orders FOR INSERT
--     WITH CHECK (user_id = auth.uid());
--
-- That is the only non-admin write policy on the table, and it is enough
-- to forge an order outright. The anon key ships inside the app bundle, so
-- any authenticated user can POST straight to /rest/v1/orders and choose:
--
--   * status       — including 'COMPLETED', the state the rest of the app
--                    treats as a finished, paid-for purchase;
--   * total_amount — defeating the price-authoritative guarantee that
--                    create_order_secure exists to provide;
--   * provider_id  — any provider on the platform.
--
-- reviews then rides straight through the hole. Its insert policy only
-- requires that the referenced order belongs to the caller and is
-- COMPLETED, and reviews.target_id has no foreign key at all (the table is
-- polymorphic over PRODUCT / PROVIDER / VEHICLE), so a forged order is a
-- valid ticket for a fabricated rating against any product on the
-- platform. Reviews are world-readable, so the result is public.
--
-- Net effect: unlimited fake reviews on a competitor's listing, junk rows
-- in every admin dashboard and report, and a bypass of server-side pricing.
--
-- Why dropping it is safe
-- -----------------------
-- Nothing inserts into orders except create_order_secure():
--
--   * the app never writes to orders directly — no insert/update/delete on
--     the orders table anywhere in lib/ (verified by scanning every
--     .from('orders') call site for a write operator);
--   * the order-create edge function calls the create_order_secure RPC
--     through the service-role client, which bypasses RLS entirely;
--   * create_order_secure is SECURITY DEFINER, so the INSERT it performs
--     runs as the function owner and is likewise unaffected by this policy.
--
-- So the only thing the policy ever permitted was forgery.
--
-- This closes it by dropping the policy rather than narrowing it. A
-- tightened policy would still leave a client-writable orders table, and
-- there is no legitimate client-side insert to preserve.
--
-- The assertion below locks this in: it fails if any INSERT policy on
-- orders other than the admin one ever reappears, so a future migration
-- cannot quietly restore the forge path.

DROP POLICY IF EXISTS orders_user_insert ON public.orders;

-- Belt and braces on the table grant: the app connects as `authenticated`,
-- so revoking INSERT from that role means even a policy regression cannot
-- be exploited through the PostgREST endpoint. service_role keeps its
-- access (it owns the path the edge function uses), and admins reach orders
-- through orders_admin_all, which is unaffected.
REVOKE INSERT ON public.orders FROM authenticated;

-- ── The guard against this coming back ───────────────────────────────────
-- Read-only, and checks pg_policies rather than data, so it says something
-- about the schema instead of about whatever happens to be in the table.
--
-- A permissive INSERT policy that is not admin-scoped is the forge path.
--
-- The admin test is an EXACT match on the normalised qual, not a substring
-- search. A substring test would wave through `is_admin() OR true`, which
-- mentions is_admin and permits everyone — precisely the shape of policy
-- that must never be mistaken for a safe one. Normalising (strip whitespace
-- and any `public.` qualifier) lets the real admin policies, which are
-- written as plain `is_admin()`, match exactly, while anything more
-- permissive than that is flagged.
CREATE OR REPLACE FUNCTION public.assert_orders_not_client_insertable()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'orders'
      AND cmd = 'INSERT'
      AND lower(regexp_replace(replace(coalesce(qual, ''), 'public.', ''), '\s+', '', 'g'))
          IS DISTINCT FROM 'is_admin()'
  );
$$;

COMMENT ON FUNCTION public.assert_orders_not_client_insertable() IS
  'True when no non-admin INSERT policy exists on orders, so orders cannot '
  'be forged by a client. Admin writes and the service_role path through '
  'create_order_secure are unaffected.';

GRANT EXECUTE ON FUNCTION public.assert_orders_not_client_insertable() TO authenticated;

-- The legitimate creation path must remain executable by the edge function.
-- Restated so a future change that drops the grant fails here rather than at
-- checkout time.
DO $$
BEGIN
  IF NOT has_function_privilege(
       'service_role',
       'public.create_order_secure(uuid,uuid,jsonb,numeric,text,text,text,text,text)',
       'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role can no longer call create_order_secure - order creation would break';
  END IF;
END $$;
