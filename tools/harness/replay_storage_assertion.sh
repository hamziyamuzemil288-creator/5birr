#!/bin/sh
# tools/harness/replay_storage_assertion.sh
#
# PROVES the 0134 fix against a real PostgreSQL, instead of shipping it on the
# strength of a code review.
#
# The bug it exists for is invisible to every gate in this repository. The
# static checks read migration TEXT; they saw a twelve-row list with three
# columns per row and a loop over it, which is correct, and had nothing to say
# about how PostgreSQL resolves `v_sources[v_i]` at runtime. The plpgsql body
# parses, the columns resolve, the return type is unchanged -- all 55 checks
# passed while the function was wrong, and it took the connectivity suite
# against a live database to find it.
#
# So the only honest way to be sure is to RUN it. This builds the smallest
# schema the assertion needs (storage.buckets plus one column per source),
# installs the real function body out of the migration, and calls it.
#
# Usage:  sh tools/harness/replay_storage_assertion.sh [--without-fix]
#
#   --without-fix  installs 0132's body instead, to show the failure.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PGBIN=${PGBIN:-/usr/lib/postgresql/14/bin}
PGSOCK=${PGSOCK:-/tmp/pgrun}
PGPORT=${PGPORT:-5433}
DB=${PGDB:-assert_replay}
FIX=20260927000134_the_check_that_guarded_the_file_sweep.sql
OLD=20260927000132_the_uploaded_files_go_too.sql

if [ "$1" = "--without-fix" ]; then
  MIGRATION="$OLD"
  LABEL="WITHOUT the fix (0132, as deployed)"
else
  MIGRATION="$FIX"
  LABEL="WITH the fix (0134)"
fi

as_postgres() { su postgres -c "$1"; }

echo "=== replay: the account file sweep assertion, $LABEL ==="

as_postgres "$PGBIN/psql -h $PGSOCK -p $PGPORT -d postgres -q -c 'DROP DATABASE IF EXISTS $DB;' -c 'CREATE DATABASE $DB;'"

# The minimum schema the assertion reads. Every name here is also a row in the
# function's own source list, so the assertion verifies itself against a schema
# that really has them.
as_postgres "$PGBIN/psql -h $PGSOCK -p $PGPORT -d $DB -q -v ON_ERROR_STOP=1" <<'SQL'
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE storage.buckets (id text PRIMARY KEY);
INSERT INTO storage.buckets (id) VALUES
  ('user-documents'), ('profile-avatars'), ('provider-photos'),
  ('product-images'), ('provider-gallery'), ('vehicle-images'),
  ('payment-screenshots');

CREATE TABLE public.user_documents         (user_id uuid, storage_path text);
CREATE TABLE public.appeal_cases           (user_id uuid, respondent_id uuid,
                                             photo_path text, response_photo_path text);
CREATE TABLE public.profiles               (id uuid, avatar_storage_path text);
CREATE TABLE public.provider_profiles      (id uuid, user_id uuid, photo_storage_path text);
CREATE TABLE public.products               (id uuid, provider_id uuid);
CREATE TABLE public.product_images         (product_id uuid, storage_path text);
CREATE TABLE public.listing_images         (listing_id uuid, storage_path text);
CREATE TABLE public.provider_gallery       (provider_id uuid, storage_path text);
CREATE TABLE public.vehicles               (id uuid, provider_id uuid);
CREATE TABLE public.vehicle_images         (vehicle_id uuid, storage_path text);
CREATE TABLE public.provider_stores        (provider_id uuid, logo_storage_path text,
                                             cover_image_storage_path text);
CREATE TABLE public.wallet_recharge_requests(provider_id uuid, wallet_id uuid,
                                             screenshot_storage_path text);
CREATE TABLE public.wallets                (id uuid, provider_id uuid);

-- The two functions the assertion requires to exist.
CREATE FUNCTION public.account_storage_objects(uuid) RETURNS TABLE(bucket_id text, object_name text)
  LANGUAGE sql AS $$ SELECT 'user-documents'::text, 'x'::text $$;
CREATE FUNCTION public.purge_account_storage(uuid) RETURNS integer
  LANGUAGE sql AS $$ SELECT 0 $$;
REVOKE ALL ON FUNCTION public.purge_account_storage(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_account_storage(uuid) TO service_role;
SQL

# Install the real function body, lifted out of the migration itself so this
# can never test a copy that has drifted from what would be deployed.
python3 - "$ROOT/supabase/migrations/$MIGRATION" > /tmp/assert_replay_body.sql <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'CREATE OR REPLACE FUNCTION public\.assert_account_storage_is_purged\b', s)
i = s.index('$$', m.start())
j = s.find('$$', i + 2)
sys.stdout.write(s[m.start():j + 2] + ';\n')
PY

set +e
as_postgres "cat /tmp/assert_replay_body.sql | $PGBIN/psql -h $PGSOCK -p $PGPORT -d $DB -q -v ON_ERROR_STOP=1" \
  && as_postgres "$PGBIN/psql -h $PGSOCK -p $PGPORT -d $DB -q -A -t -c 'SELECT public.assert_account_storage_is_purged();'"
STATUS=$?
set -e

echo
if [ "$STATUS" -eq 0 ]; then
  echo "replay: assertion PASSED against real PostgreSQL"
else
  echo "replay: assertion FAILED -- this is the behaviour the migration has to fix"
fi
exit $STATUS