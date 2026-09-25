#!/usr/bin/env bash
# Replay the real deploy lineage locally, then run the search proximity
# regression suite (tools/test/search_geo_scope_test.sql) BEFORE and AFTER
# 20260925140000_search_geo_scope.sql.
#
# Phase 1 (regression proof): lineage only. EXPECTED: A and D fail — a caller
#   that supplies a position but no radius loses every located listing, which
#   is the "results from other countries" symptom.
# Phase 2 (fix proof): same lineage + the geo-scope migration. EXPECTED: all
#   five checks pass, and the no-position legacy path is unchanged.
#
# Local only; run from repo root: bash tools/test/search_geo_scope_driver.sh
set -u
cd "$(dirname "$0")/../.." || exit 2
DB=search_geo
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/search_geo
MIG=supabase/migrations
rm -rf "$WORK"; mkdir -p "$WORK"
# postgres cannot read the repo tree, so stage the files it must -f.
cp "$ROOT/tools/test/search_geo_scope_test.sql" "$WORK/suite.sql"
cp "$ROOT/$MIG/20260925140000_search_geo_scope.sql" "$WORK/geo_scope.sql"
chmod -R a+rX "$WORK"

sudo -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1
sudo -u postgres createdb "$DB" >/dev/null 2>&1 || { echo "cannot create $DB"; exit 9; }

sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" >/dev/null 2>&1 <<'PRE'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE SCHEMA IF NOT EXISTS auth;
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
DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticator NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
PRE

# pg_cron stub so the revenue-scheduler migration applies locally.
sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" >/dev/null 2>&1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS cron;
CREATE TABLE IF NOT EXISTS cron.job (
  jobid bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jobname text UNIQUE, schedule text, command text);
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

# Lineage in the deploy workflow's own staging order: one file per numeric
# version, first glob match wins, non-numeric prefixes skipped.
seen="$(mktemp)"
for f in "$MIG"/*.sql; do
  base="$(basename "$f")"
  v="${base%%_*}"
  case "$v" in ''|*[!0-9]*) continue ;; esac
  if [ "$base" = "20260925140000_search_geo_scope.sql" ]; then continue; fi
  if grep -qx "$v" "$seen"; then continue; fi
  echo "$v" >> "$seen"
  sed 's/^create extension if not exists pg_cron;[[:space:]]*$/-- pg_cron stubbed/' "$f" \
    | sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" >/dev/null 2>&1 \
    || { echo "  migration failed: $base"; exit 9; }
done
rm -f "$seen"

run_suite() {
  sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" -f "$WORK/suite.sql" 2>&1 \
    | grep -oE '(PASS|FAIL) [A-F]_[a-z_]+.*'
}

echo "=== PHASE 1: deployed search_products (no geo-scope fix) ==="
o=$(run_suite); echo "$o"
echo "    pass=$(echo "$o" | grep -c '^PASS' || true) fail=$(echo "$o" | grep -c '^FAIL' || true)"

echo
echo "=== PHASE 2: + 20260925140000_search_geo_scope.sql ==="
sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/geo_scope.sql" >/dev/null 2>&1 \
  || { echo "  geo-scope migration apply FAILED"; sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/geo_scope.sql" 2>&1 | tail -5; exit 2; }
o=$(run_suite); echo "$o"
p=$(echo "$o" | grep -c '^PASS' || true); f=$(echo "$o" | grep -c '^FAIL' || true)
echo "    pass=$p fail=$f  (fix contract: all six checks pass)"

if [ "$f" -eq 0 ] && [ "$p" -ge 6 ]; then
  echo; echo "FIX PROVEN: proximity applies, global flag honored, no-position path unchanged"
  exit 0
fi
echo; echo "SEARCH FIX CONTRACT VIOLATIONS — DO NOT SHIP"
exit 1
