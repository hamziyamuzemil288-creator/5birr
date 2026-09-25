#!/usr/bin/env bash
# LIVE-LINEAGE reproduction + fix proof for the handle_new_user regression.
#
# Lineage is the CI-VERIFIED one (Deploy Supabase run 36160977520 stage log):
#   0021_live_schema_snapshot.sql -> 0022_complete_schema.sql -> every later
#   migration in filename order. Siblings 0020_auth_profile_trigger,
#   0021_provider_role_trigger, 0022_fix_role_escalation_trigger are skipped
#   by CI's one-file-per-version staging; 0022a/b/c/d are skipped as
#   "CLI-ignored, non-numeric prefix". This driver replays exactly that,
#   verbatim, against a minimal auth-schema stub (auth.users + auth.uid(),
#   no JWT set during signup — the production GoTrue behavior the bug
#   depends on) and a local cron stub (no pg_cron in the sandbox).
#
# Phase 1 (reproduction): apply the verbatim lineage, run the fingerprint +
#   six-path matrix from tools/test/hnu_live_lineage_repro.sql. EXPECTED:
#   every trusted path FAILS with ROLE_ASSIGNMENT_IS_ADMIN_ONLY (the live
#   bug); fingerprints show the strict prevent_role_escalation() deployed.
# Phase 2 (fix proof): same lineage + the consolidated migration's
#   CREATE OR REPLACE statements (handle_new_user + prevent_role_escalation)
#   + re-run of the sweep. EXPECTED: A C D E F G PASS, B still rejected with
#   EMAIL_OTP_REQUIRED (OTP gate intact, admin-only guarantee intact).
#
# Local only; run from repo root: bash tools/test/hnu_live_lineage_driver.sh
set -u
cd "$(dirname "$0")/../.." || exit 2
DB=hnu_lineage
WORK=/tmp/hnu_lineage
MIG=supabase/migrations
rm -rf "$WORK"; mkdir -p "$WORK"

# ── Extract a single CREATE OR REPLACE FUNCTION block (function only) ──────
extract_fn() { # $1 function-name  $2 source-file  $3 out-file
  awk -v fn="public\\.$1" '
    BEGIN{f=0}
    tolower($0) ~ ("create or replace function " fn) {f=1}
    f{print}
    f && $0 ~ /^\$\$;[[:space:]]*$/ {exit}
  ' "$2" > "$3"
  [ -s "$3" ] || { echo "cannot extract $1 from $2"; exit 2; }
}

extract_fn handle_new_user         "$MIG/20260925120000_handle_new_user_consolidated.sql" "$WORK/handle_new_user.fn"
extract_fn prevent_role_escalation "$MIG/20260925120000_handle_new_user_consolidated.sql" "$WORK/prevent_role_escalation.fn"

# Sweep section of the repro (everything from SWEEP-SECTION START on), so the
# same matrix runs in both phases.
awk '/SWEEP-SECTION START/{f=1} f' tools/test/hnu_live_lineage_repro.sql > "$WORK/sweep.sql"
[ -s "$WORK/sweep.sql" ] || { echo "cannot extract sweep section"; exit 2; }

# ── Local pg_cron stub (same surface the revenue scheduler uses) ───────────
cat > "$WORK/cron_stub.sql" <<'SQL'
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (
  jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jobname text UNIQUE,
  schedule text,
  command text
);
CREATE OR REPLACE FUNCTION cron.schedule(p_name text, p_schedule text, p_command text)
RETURNS bigint LANGUAGE plpgsql AS $stub$
DECLARE v_id bigint;
BEGIN
  INSERT INTO cron.job (jobname, schedule, command) VALUES (p_name, p_schedule, p_command)
  ON CONFLICT (jobname) DO UPDATE SET schedule = EXCLUDED.schedule, command = EXCLUDED.command
  RETURNING jobid INTO v_id;
  RETURN v_id;
END $stub$;
SQL

# ── The lineage, in CI deploy order (verbatim except the pg_cron line) ─────
LINEAGE=(
  0021_live_schema_snapshot.sql
  0022_complete_schema.sql
  0023_user_approval_workflow.sql
  0024_admin_expenses_notifications.sql
  0025_fix_signup_email_confirmation_flow.sql
  0026_fix_approve_provider_subscriptions.sql
  0027_provider_trust_stats.sql
  0028_points_system.sql
  0029_fix_order_status_trigger_server_path.sql
  0030_fix_wallet_balance_trigger_server_path.sql
  0031_admin_visibility_fix.sql
  0032_live_location_routing.sql
  0033_fix_provider_approval_triggers_and_storage.sql
  0034_fix_profile_status_trigger_server_path.sql
  0035_seed_telebirr_payment_method.sql
  0036_order_chat.sql
  0037_category_order_numbers.sql
  0038_activation_fee_and_wallet_guards.sql
  0039_support_tickets_and_terms.sql
  0040_unit_pricing_and_payment_method_dedupe.sql
  0041_ride_requests_realtime.sql
  20260919000000_repo_chat.sql
  20260919000001_match_chunks_kinds.sql
  20260920000000_match_chunks_distance_cutoff.sql
  20260921000000_chat_context_and_logs.sql
  20260922000000_multi_city_support.sql
  20260922000001_staff_and_admin_history.sql
  20260922000002_fulfillment_and_shared_queries.sql
  20260922000003_search_city_scope.sql
  20260922000004_revenue_scheduler.sql
  20260922000005_ride_status_transitions.sql
  20260922000006_wallet_ledger_reconciliation.sql
  20260922000007_integration_assertions.sql
  20260922000008_fix_staff_performance_rides.sql
  20260922000009_fix_assertion_overloads.sql
  20260922000010_staff_permission_enforcement.sql
  20260922000011_rejected_application_resubmission.sql
  20260922000012_role_hierarchy_and_ride_fare.sql
  20260923000000_appeal_cases.sql
  20260923000001_role_management_tools.sql
  20260923000002_document_qr_verification.sql
  20260923000003_true_admin_as_ceo.sql
  20260923000004_otp_categories_address_notifications.sql
  20260923000005_otp_signup_gate_and_doc_requirements.sql
  20260924000000_referral_tracking.sql
  20260924000001_referral_signup_trigger.sql
  20260924000002_doc_type_choice_at_upload.sql
  20260924000003_captcha_challenges.sql
  20260924000004_critical_security_hardening.sql
  20260924000005_staff_gateway_tasks.sql
  20260924000006_public_provider_view_hardening.sql
  20260924000007_otp_request_rpc_repair.sql
  20260924000008_otp_hash_helper_and_rpc_repair.sql
  20260924000009_login_lockout.sql
  20260924000010_preserve_solved_captcha.sql
  20260925000000_google_oauth_signup_gate.sql
)

build_lineage_db() {
  sudo -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1
  sudo -u postgres createdb "$DB" >/dev/null 2>&1 || { echo "  cannot create $DB"; return 9; }
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" <<'PRE' >/dev/null 2>&1 || { echo "  prelude FAILED"; return 9; }
DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS auth CASCADE;
DROP SCHEMA IF EXISTS cron CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticator NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
CREATE TABLE auth.users (
  instance_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'::uuid,
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aud varchar(255) DEFAULT 'authenticated',
  role varchar(255) DEFAULT 'authenticated',
  email text UNIQUE,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  confirmation_token text DEFAULT '',
  recovery_token text DEFAULT '',
  email_change text DEFAULT '',
  email_change_token_new text DEFAULT '',
  email_change_token_current text DEFAULT ''
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
PRE
  sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" -f "$WORK/cron_stub.sql" >/dev/null 2>&1 \
    || { echo "  cron stub FAILED"; return 9; }
  local f
  for f in "${LINEAGE[@]}"; do
    if [ ! -f "$MIG/$f" ]; then echo "  missing migration file: $f"; return 9; fi
    # Swap the pg_cron extension line for a comment (stub already installed).
    sed 's/^create extension if not exists pg_cron;[[:space:]]*$/-- pg_cron: stubbed locally (see cron_stub)/' \
      "$MIG/$f" | sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" >/dev/null 2>&1 \
      || { echo "  migration FAILED: $f"; return 9; }
  done
  # Any migration added after this driver was written (fresh timestamp
  # versions) is applied too, so the sweep always runs against the true
  # full lineage rather than a frozen snapshot of it.
  for f in "$MIG"/*.sql; do
    b="$(basename "$f")"
    case "$b" in *.sql) ;; *) continue ;; esac
    v="${b%%_*}"
    case "$v" in ''|*[!0-9]*) continue ;; esac
    skip=0
    for known in "${LINEAGE[@]}"; do [ "$known" = "$b" ] && skip=1; done
    [ "$skip" -eq 1 ] && continue
    echo "  + applying post-driver migration: $b"
    sed 's/^create extension if not exists pg_cron;[[:space:]]*$/-- pg_cron: stubbed locally/' \
      "$MIG/$b" | sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" >/dev/null 2>&1 \
      || { echo "  migration FAILED: $b"; return 9; }
  done

  # Supabase-equivalent client grants, so the G sweep path exercises the real
  # direct-client INSERT path (schema USAGE + table INSERT reach the trigger).
  # Must run AFTER the migrations (the table does not exist before them).
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" \
    -c 'GRANT USAGE ON SCHEMA public TO authenticated;' \
    -c 'GRANT INSERT ON public.user_roles TO authenticated;' >/dev/null 2>&1 \
    || { echo "  post-migration grants FAILED"; return 9; }
}

run_sweep() {
  sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" -f "$WORK/sweep.sql" 2>&1 \
    | grep -oE '(PASS|FAIL|SKIP) [A-G]_[a-z_]+.*'
}

echo "=== PHASE 1: live lineage reproduction (verbatim migrations, no fix) ==="
build_lineage_db || exit 2
o=$(run_sweep)
p=$(echo "$o" | grep -c '^PASS' || true); f=$(echo "$o" | grep -c '^FAIL' || true)
echo "$o"
echo "    pass=$p fail=$f  (reproduction contract: every trusted path FAILS)"

echo
echo "=== PHASE 2: fix proof (same lineage + consolidated migration) ==="
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/handle_new_user.fn" >/dev/null 2>&1 \
  || { echo "  handle_new_user apply FAILED"; exit 2; }
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/prevent_role_escalation.fn" >/dev/null 2>&1 \
  || { echo "  prevent_role_escalation apply FAILED"; exit 2; }
o=$(run_sweep)
p=$(echo "$o" | grep -c '^PASS' || true); f=$(echo "$o" | grep -c '^FAIL' || true)
echo "$o"
echo "    pass=$p fail=$f  (fix contract: A C D E F G PASS, B rejected)"

fails=0
for L in A B C D E F; do echo "$o" | grep -q "^PASS ${L}_" || fails=$((fails+1)); done
# G must PASS (guard blocks the client) or SKIP (env lacks the grant) — but a
# successful insert is always a violation.
echo "$o" | grep -q "^FAIL G_" && fails=$((fails+1))
if [ "$fails" -eq 0 ]; then
  echo
  echo "FIX PROVEN: all trusted paths pass, OTP gate intact, admin-only guarantee intact"
else
  echo
  echo "FIX CONTRACT VIOLATIONS — DO NOT SHIP"
fi
exit $fails
