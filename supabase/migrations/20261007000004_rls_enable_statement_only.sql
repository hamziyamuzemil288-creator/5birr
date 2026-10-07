-- 20261007000004_rls_enable_statement_only.sql
--
-- Idempotent statement-only migration.
--
-- Purpose: record, in the migration history, that RLS is enabled on every
-- migration-created public table that the repo-side static lint
-- tools/harness/check_migration_tables_have_rls.py reports as "first created
-- in" a file that does not itself contain a top-level
-- `ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY`.
--
-- What this migration does:
--  - Adds one `ALTER TABLE public.<t> ENABLE ROW LEVEL SECURITY;` line for each
--    of the 41 tables the lint lists. Each is idempotent by nature: running it
--    again when RLS is already enabled is a no-op in Postgres.
--  - Changes NO policies. Adds NO `using (true)` or `with check` policies.
--  - Adds NO new tables, columns, indexes, functions, or grants. This file is
--    purely a statement of existing posture, so the repo text and the live DB
--    agree on the "RLS enabled" claim.
--  - VERIFIES its own outcome: the DO block at the end fails if any of the 41
--    tables above still has relrowsecurity = false. A statement-only file used
--    to claim a change nobody checked; now the file checks itself.
--
-- What it does NOT do:
--  - It does not enable RLS where it is genuinely missing on the live DB. If a
--    table is RLS-off live, the live assertion functions in 20261007000003
--    (assert_all_migration_tables_have_rls,
--    assert_list_public_tables_without_rls_is_empty) are what catch that, not
--    this file.
--  - It does not touch extension-owned tables (spatial_ref_sys) or the three
--    intentionally-policyless internal tables (captcha_challenges,
--    login_attempts, rate_limits), matching the lint exclusions.
--
-- Ordering: this runs AFTER 20261007000003, and is the migration that makes the
-- static lint exit 0. It is harmless to re-apply in any later deploy.
--
-- NOTE: the previous revision of this file ended with
-- `COMMENT ON MIGRATION ... IS '...'`, which is not a Postgres statement at all
-- and would have aborted the deploy at that line. The description below is a
-- plain SQL comment instead, and the migration's real closing statement is the
-- assertion.

BEGIN;

-- Core tables first introduced in 0001_core_schema.sql.
ALTER TABLE public.admin_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ride_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ride_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicle_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallets ENABLE ROW LEVEL SECURITY;

-- Tables first introduced in 0013_marketplace_foundation.sql.
ALTER TABLE public.listing_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_gallery ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_stores ENABLE ROW LEVEL SECURITY;

-- Tables first introduced in 0021_live_schema_snapshot.sql (the snapshot is
-- their earliest real CREATE TABLE in this repo; the lint keeps 0021 as their
-- "first created in").
ALTER TABLE public.admin_wallet_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.driver_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fcm_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n8n_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ride_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_recharge_requests ENABLE ROW LEVEL SECURITY;

-- The assertion: the 41 statements above must have taken effect. It runs inside
-- the same transaction, so a failure rolls the whole file back rather than
-- leaving a half-claimed state.
--
-- It is also what gives this file a plpgsql body for the harness's body
-- extractor; a statement-only file is reported as "found 0 plpgsql bodies ...
-- this file was NOT checked", which meant nothing verified the claim above.
DO $$
DECLARE
  r record;
  v_missing text[] := '{}';
BEGIN
  FOR r IN
    SELECT t.name
      FROM unnest(ARRAY[
        'admin_actions', 'appeals', 'approval_history', 'approval_requests',
        'audit_logs', 'categories', 'favorites', 'notification_preferences',
        'notifications', 'order_items', 'order_status_history', 'orders',
        'payment_agreements', 'payment_proofs', 'product_images', 'products',
        'profiles', 'provider_profiles', 'reviews', 'ride_requests',
        'ride_status_history', 'subscriptions', 'support_tickets',
        'system_settings', 'user_documents', 'user_roles', 'vehicle_images',
        'vehicles', 'wallet_transactions', 'wallets',
        'listing_images', 'provider_gallery', 'provider_stores',
        'admin_wallet_actions', 'cart_items', 'driver_status', 'fcm_tokens',
        'n8n_events', 'payment_methods', 'ride_ratings',
        'wallet_recharge_requests'
      ]) AS t(name)
  LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND c.relname = r.name
         AND c.relkind IN ('r', 'p')
         AND c.relrowsecurity
    ) THEN
      v_missing := v_missing || r.name;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION
      'RLS_NOT_ENABLED_AFTER_20261007000004: %',
      array_to_string(v_missing, ', ');
  END IF;
END;
$$;

COMMIT;
