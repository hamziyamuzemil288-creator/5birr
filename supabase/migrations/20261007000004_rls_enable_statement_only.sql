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

COMMIT;

COMMENT ON MIGRATION 20261007000004 IS
  'Idempotent statement-only migration: records ALTER TABLE public.<t> ENABLE ROW LEVEL SECURITY for the 41 migration-created public tables the static lint lists, with no policy changes. The live DB already has RLS enabled on all of these (verified by live scan); this file makes the repo text agree with that fact so the static lint exits 0. Runs after 20261007000003. Does not touch extension-owned tables or the three intentionally-policyless internal tables.';
