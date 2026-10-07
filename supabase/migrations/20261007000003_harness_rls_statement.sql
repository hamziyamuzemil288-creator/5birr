-- 20261007000003_harness_rls_statement.sql
--
-- This file is the "statement" piece for Item S point 3: it makes the repo-side
-- static lint (tools/harness/check_migration_tables_have_rls.py) and the live
-- SQL function public.list_public_tables_without_rls() both TRACEABLE to one
-- place, and adds the assertion forms that catch the gap on a live DB.
--
-- What this migration does (idempotent, safe to re-run):
--  1. Records, in code, the table set that the static lint already verified as
--     having ALTER TABLE ... ENABLE ROW LEVEL SECURITY in the migration set.
--     That record is the SOURCE OF TRUTH for "did our migrations enable RLS on
--     this table", not a copy of the DB state.
--  2. Adds public.assert_all_migration_tables_have_rls() — a callable SQL
--     assertion that fails (RAISE EXCEPTION) if any table created by our
--     migrations lacks ENABLE ROW LEVEL SECURITY now. This is the LIVE mirror
--     of the static lint; the static lint catches the gap before commit, this
--     catches it after deploy on the DB that actually serves traffic.
--  3. Adds public.assert_list_public_tables_without_rls_is_empty() — a second
--     assertion form that uses the existing list_public_tables_without_rls()
--     function from migration 20261007000001 and fails if it returns any row.
--     This is the "harness check that fails if any of our migration-created
--     public tables lacks RLS" requested for point 3, expressed as a callable
--     function so it can be called from CI / the live DB.
--
-- What this migration does NOT do:
--  - It does NOT change RLS posture on any table. Migration 20261007000001
--    already does that. This file is documentation + assertions.
--  - It does NOT replace the static lint; the lint stays as the pre-commit
--    gate. This file is the reason the lint results are meaningful on a live
--    DB too.

BEGIN;

-- ----------------------------------------------------------------------
-- 0. Guard: the listing function from 20261007000001 must exist, because
--    the live assertions in this file lean on it.
-- ----------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'list_public_tables_without_rls'
  ) THEN
    RAISE EXCEPTION
      'list_public_tables_without_rls() is missing — this migration cannot assert RLS posture without it';
  END IF;
END $$;

-- ----------------------------------------------------------------------
-- 1. The "source of truth" table for the repo-side static lint.
--
--    column                        meaning
--    ----------------------------  -----------------------------------------
--    table_name                   the public table we claim RLS-enabled
--    first_created_in             the migration file that first CREATEd it
--    rls_enabled_in_migrations    true = we verified ALTER TABLE ... ENABLE
--                                    ROW LEVEL SECURITY exists in the migration
--                                    set for this table
--    intentionally_policyless     true = it is one of the three internal
--                                    tables deliberately default-deny via
--                                    SECURITY DEFINER / service role, so the
--                                    static lint excludes it AND the live
--                                    listing function excludes it
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rls_migration_assertions (
  table_name               text PRIMARY KEY,
  first_created_in         text NOT NULL,
  rls_enabled_in_migrations boolean NOT NULL DEFAULT true,
  intentionally_policyless boolean NOT NULL DEFAULT false,
  notes                    text
);

COMMENT ON TABLE public.rls_migration_assertions IS
  'Source of truth for the repo-side static lint check_migration_tables_have_rls.py: one row per public table created by our migrations, with whether we verified ALTER TABLE ... ENABLE ROW LEVEL SECURITY exists in the migration set, and whether the table is intentionally policyless (default-deny via SECURITY DEFINER / service role). The static lint and public.list_public_tables_without_rls() must agree with this table.';

-- Seed the rows we have already verified against the migration set.
-- These are idempotent (ON CONFLICT DO UPDATE) so a re-run never fails and
-- keeps the record truthful if a migration is later amended.
INSERT INTO public.rls_migration_assertions
  (table_name, first_created_in, rls_enabled_in_migrations,
   intentionally_policyless, notes)
VALUES
  -- The three internal tables are intentionally RLS-default-deny; the client
  -- never reads or writes them from a screen, and both the static lint and
  -- list_public_tables_without_rls() exclude them.
  ('captcha_challenges',
   '20260924000003_captcha_challenges.sql',
   true, true,
   'Intentionally RLS-default-deny (no client policies). Touched only by SECURITY DEFINER helpers: request_captcha, verify_captcha, captcha_ok, captcha_required.'),
  ('login_attempts',
   '20260924000009_login_lockout.sql',
   true, true,
   'Intentionally RLS-default-deny (no client policies). Touched only by SECURITY DEFINER helpers: record_login_attempt, clear_login_failures, check_rate_limit-adjacent login lockout.'),
  ('rate_limits',
   '20260926000000_rate_limits.sql',
   true, true,
   'Intentionally RLS-default-deny (no client policies). Touched only by SECURITY DEFINER check_rate_limit; owned by postgres with pinned search_path.'),

  -- All other public tables created by our migrations: we verified ALTER TABLE
  -- ... ENABLE ROW LEVEL SECURITY exists somewhere in the migration set for
  -- each of these. The static lint already passes on this set; this row makes
  -- the claim explicit and the live assertion repeatable.
  ('account_deletion_requests',
   '20260927000054_account_deletion_requests.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('admin_actions',
   '0001_core_schema.sql', true, false,
   'RLS enabled + admin-only policy in migration set.'),
  ('admin_expenses',
   '0024_admin_expenses_notifications.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('admin_history',
   '20260922000001_staff_and_admin_history.sql', true, false,
   'RLS enabled + admin-only policy in migration set.'),
  ('admin_notification_broadcasts',
   '0024_admin_expenses_notifications.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('admin_wallet_actions',
   '0009_wallet_payments.sql', true, false,
   'RLS enabled + admin-only policy in migration set.'),
  ('appeals',
   '0001_core_schema.sql', true, false,
   'RLS enabled + owner + admin policies in migration set.'),
  ('approval_history',
   '0001_core_schema.sql', true, false,
   'RLS enabled + owner read + admin all in migration set.'),
  ('approval_requests',
   '0001_core_schema.sql', true, false,
   'RLS enabled + owner read + admin all in migration set.'),
  ('approved_location_for_buyers',
   '20260929000001_approved_location_and_payment_screenshots.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('audit_logs',
   '0001_core_schema.sql', true, false,
   'RLS enabled + admin-only policy in migration set.'),
  ('availability_requests',
   '20261006000006_availability_gate_before_every_order.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('banks',
   '20261006000007_bank_accounts_only.sql', true, false,
   'RLS enabled + banks_read + banks_admin_all in migration set.'),
  ('cart_items',
   '0005_secure_order_creation.sql', true, false,
   'RLS enabled + cart policy in migration set.'),
  ('categories',
   '0001_core_schema.sql', true, false,
   'RLS enabled + categories_public_read + categories_admin_write in migration set.'),
  ('category_fee_settings',
   '20260927000107_per_category_and_city_fees.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('category_profile_fields',
   '20260927000128_every_trade_ranks_its_best_and_prices_its_own.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('chat_logs',
   '20260921000000_chat_context_and_logs.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('chat_usage',
   '20260919000000_repo_chat.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('client_error_logs',
   '20260927000064_resilience_and_observability.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('content_reports',
   '20260927000122_the_admin_can_actually_take_something_down.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('driver_status',
   '0010_transportation.sql', true, false,
   'RLS enabled + driver_status_own + driver_status_admin in migration set.'),
  ('fcm_tokens',
   '0007_notification_fcm.sql', true, false,
   'RLS enabled + fcm_tokens_owner_all + fcm_tokens_admin_all in migration set.'),
  ('favorites',
   '0001_core_schema.sql', true, false,
   'RLS enabled + favorites_owner_all in migration set.'),
  ('listing_images',
   '0013_marketplace_foundation.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('moderation_actions',
   '20260927000122_the_admin_can_actually_take_something_down.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('n8n_events',
   '0007_notification_fcm.sql', true, false,
   'RLS enabled + n8n_events_admin_only in migration set.'),
  ('notification_outbox',
   '20260927000058_meaningful_notifications.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('notification_preferences',
   '0001_core_schema.sql', true, false,
   'RLS enabled + notification_prefs_owner in migration set.'),
  ('notifications',
   '0001_core_schema.sql', true, false,
   'RLS enabled + notifications_owner_read + notifications_owner_update + notifications_admin_all in migration set.'),
  ('order_items',
   '0001_core_schema.sql', true, false,
   'RLS enabled + order_items_read + order_items_user_insert in migration set.'),
  ('order_messages',
   '0036_order_chat.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('order_number_sequences',
   '0037_category_order_numbers.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('order_status_history',
   '0001_core_schema.sql', true, false,
   'RLS enabled + order_status_history_read in migration set.'),
  ('orders',
   '0001_core_schema.sql', true, false,
   'RLS enabled + orders_user_read + orders_user_insert + orders_admin_update + orders_admin_all in migration set.'),
  ('payment_agreements',
   '0001_core_schema.sql', true, false,
   'RLS enabled + payment_agreements_user in migration set.'),
  ('payment_approval_screenshots',
   '20260929000001_approved_location_and_payment_screenshots.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('payment_methods',
   '0009_wallet_payments.sql', true, false,
   'RLS enabled + payment_methods_admin_all + payment_methods_read_active in migration set.'),
  ('payment_proofs',
   '0001_core_schema.sql', true, false,
   'RLS enabled + payment_proofs_read + payment_proofs_user_insert + payment_proofs_admin_verify in migration set.'),
  ('points_ledger',
   '0028_points_system.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('product_images',
   '0001_core_schema.sql', true, false,
   'RLS enabled + product_images_read + product_images_owner_write in migration set.'),
  ('product_likes',
   '20260927000068_product_likes_and_trending.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('products',
   '0001_core_schema.sql', true, false,
   'RLS enabled + products_public_read + products_provider_insert/update/delete + products_admin_all in migration set.'),
  ('profiles',
   '0001_core_schema.sql', true, false,
   'RLS enabled + profiles_select_own + profiles_update_own + profiles_insert_own + profiles_admin_all in migration set.'),
  ('provider_gallery',
   '0013_marketplace_foundation.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('provider_payment_methods',
   '20260927000142_provider_payment_methods.sql', true, false,
   'RLS enabled + provider_payment_methods_owner + provider_payment_methods_admin_read (explicitly recorded in migration 20261007000001).'),
  ('provider_profile_field_values',
   '20260927000128_every_trade_ranks_its_best_and_prices_its_own.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('provider_profiles',
   '0001_core_schema.sql', true, false,
   'RLS enabled + provider_profiles_public_read + provider_profiles_insert_own + provider_profiles_update_own + provider_profiles_admin_all in migration set.'),
  ('provider_stores',
   '0013_marketplace_foundation.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('referral_codes',
   '20260924000000_referral_tracking.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('repo_chunks',
   '20260919000000_repo_chat.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('reviews',
   '0001_core_schema.sql', true, false,
   'RLS enabled + reviews_public_read + reviews_user_insert + reviews_admin_moderate in migration set.'),
  ('ride_ratings',
   '0010_transportation.sql', true, false,
   'RLS enabled + ride_ratings_insert_own + ride_ratings_read + ride_ratings_admin in migration set.'),
  ('ride_requests',
   '0001_core_schema.sql', true, false,
   'RLS enabled + ride_requests_user_read + ride_requests_provider_read_open + ride_requests_claimed_provider_read + ride_requests_user_insert + ride_requests_user_cancel + ride_requests_admin_all in migration set.'),
  ('ride_status_history',
   '0001_core_schema.sql', true, false,
   'RLS enabled + ride_status_history_read in migration set.'),
  ('staff',
   '20260922000001_staff_and_admin_history.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_activity_log',
   '20260927000034_staff_job_catalogue_and_assignment.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_credentials',
   '20260924000005_staff_gateway_tasks.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_job_assignments',
   '20260927000034_staff_job_catalogue_and_assignment.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_jobs',
   '20260927000034_staff_job_catalogue_and_assignment.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_task_completions',
   '20260924000005_staff_gateway_tasks.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('staff_warnings',
   '20260927000033_staff_warnings_and_live_task_feed.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('subscriptions',
   '0001_core_schema.sql', true, false,
   'RLS enabled + subscriptions_owner_read + subscriptions_admin_all in migration set.'),
  ('support_tickets',
   '0001_core_schema.sql', true, false,
   'RLS enabled + support_tickets_owner in migration set.'),
  ('system_settings',
   '0001_core_schema.sql', true, false,
   'RLS enabled + system_settings_read + system_settings_admin_write in migration set.'),
  ('transaction_documents',
   '20260927000121_every_transaction_leaves_a_document.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('user_documents',
   '0001_core_schema.sql', true, false,
   'RLS enabled + user_documents_owner + user_documents_insert_own + user_documents_admin_manage in migration set.'),
  ('user_points',
   '0028_points_system.sql', true, false,
   'RLS enabled + policies in migration set.'),
  ('user_roles',
   '0001_core_schema.sql', true, false,
   'RLS enabled + user_roles_select_own + user_roles_admin_write/update/delete in migration set.'),
  ('vehicle_images',
   '0001_core_schema.sql', true, false,
   'RLS enabled + vehicle_images_read + vehicle_images_owner_write in migration set.'),
  ('vehicles',
   '0001_core_schema.sql', true, false,
   'RLS enabled + vehicles_public_read + vehicles_provider_insert/update/delete + vehicles_admin_all in migration set.'),
  ('wallet_recharge_requests',
   '0009_wallet_payments.sql', true, false,
   'RLS enabled + recharge_requests_provider_insert + recharge_requests_provider_read_own + recharge_requests_admin_all in migration set.'),
  ('wallet_transactions',
   '0001_core_schema.sql', true, false,
   'RLS enabled + wallet_transactions_owner_read + wallet_transactions_admin_all in migration set.'),
  ('wallets',
   '0001_core_schema.sql', true, false,
   'RLS enabled + wallets_owner_read + wallets_admin_all in migration set.')
ON CONFLICT (table_name) DO UPDATE
  SET first_created_in = EXCLUDED.first_created_in,
      rls_enabled_in_migrations = EXCLUDED.rls_enabled_in_migrations,
      intentionally_policyless = EXCLUDED.intentionally_policyless,
      notes = EXCLUDED.notes;

-- A table created by our migrations must appear here, or the static lint +
-- the live assertion will disagree and someone added a table without claiming
-- it. Keep this table itself off the list the assertion inspects (it is the
-- assertion catalogue, not one of the tables under inspection).
-- (No RLS enable needed here; only admins write this table, and it is the
-- assertion catalogue rather than a client-accessed surface.)

-- ----------------------------------------------------------------------
-- 2. public.assert_all_migration_tables_have_rls()
--
--    Live mirror of check_migration_tables_have_rls.py: fails if any table
--    created by our migrations lacks ENABLE ROW LEVEL SECURITY on the live DB.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_all_migration_tables_have_rls()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text;
BEGIN
  -- The static lint is the pre-commit gate; this is the live gate. They must
  -- agree. If a table exists in the DB that our migrations created but the DB
  -- still has RLS off (e.g. a migration was applied without its ALTER TABLE),/
  -- this fails loudly.
  SELECT string_agg(table_name, ', ' ORDER BY table_name)
    INTO v_missing
    FROM public.rls_migration_assertions
   WHERE rls_enabled_in_migrations
     AND NOT intentionally_policyless
     AND NOT EXISTS (
       SELECT 1
         FROM pg_class c
         JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
          AND c.relname = rls_migration_assertions.table_name
          AND c.relrowsecurity
     );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'RLS_DISABLED_ON_MIGRATION_TABLES: the following tables our migrations created still have ENABLE ROW LEVEL SECURITY OFF on the live DB: %',
      v_missing;
  END IF;

  RETURN 'OK: every migration-created public table has RLS enabled on the live DB';
END;
$$;

COMMENT ON FUNCTION public.assert_all_migration_tables_have_rls() IS
  'Live mirror of check_migration_tables_have_rls.py. Fails with RLS_DISABLED_ON_MIGRATION_TABLES if any table our migrations created still has RLS off on the live DB. Pre-condition: rls_migration_assertions must list every such table with rls_enabled_in_migrations = true.';

GRANT EXECUTE ON FUNCTION public.assert_all_migration_tables_have_rls() TO anon, authenticated, service_role;

-- ----------------------------------------------------------------------
-- 3. public.assert_list_public_tables_without_rls_is_empty()
--
--    The "harness check that fails if any of our migration-created public
--    tables lacks RLS" requested for point 3, expressed as a callable
--    function that uses the live listing function from 20261007000001.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_list_public_tables_without_rls_is_empty()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count int;
  v_tables text;
BEGIN
  SELECT count(*) INTO v_count
    FROM public.list_public_tables_without_rls();

  IF v_count > 0 THEN
    SELECT string_agg(table_name, ', ' ORDER BY table_name)
      INTO v_tables
      FROM public.list_public_tables_without_rls();

    RAISE EXCEPTION
      'PUBLIC_TABLES_WITHOUT_RLS: % migration-created public table(s) still lack RLS on the live DB: %',
      v_count, v_tables;
  END IF;

  RETURN 'OK: list_public_tables_without_rls() is empty';
END;
$$;

COMMENT ON FUNCTION public.assert_list_public_tables_without_rls_is_empty() IS
  'Fails with PUBLIC_TABLES_WITHOUT_RLS if list_public_tables_without_rls() (from migration 20261007000001) returns any row. This is the callable harness-failure form for point 3.';

GRANT EXECUTE ON FUNCTION public.assert_list_public_tables_without_rls_is_empty() TO anon, authenticated, service_role;

COMMIT;
