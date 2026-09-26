#!/usr/bin/env bash
# Run the driver live-location trigger test (tools/test/driver_live_location_test.sql)
# against a local Postgres.
#
# postgres cannot read the repo checkout, so the suite and the migration under
# test are staged into /tmp first (same pattern as search_geo_scope_driver.sh).
#
# Local only; run from repo root: bash tools/test/driver_live_location_driver.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
DB=driver_live_location_test
MIG=20260925210000_driver_live_location.sql
WORK=/tmp/driver_live_location

rm -rf "$WORK"; mkdir -p "$WORK/supabase/migrations"
cp "$ROOT/tools/test/driver_live_location_test.sql" "$WORK/suite.sql"
cp "$ROOT/supabase/migrations/$MIG" "$WORK/supabase/migrations/$MIG"
chmod -R a+rX "$WORK"

sudo -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1
sudo -u postgres createdb "$DB" >/dev/null 2>&1 || { echo "cannot create $DB"; exit 9; }

out=$(sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" \
  -v repo_root="$WORK" -f "$WORK/suite.sql" 2>&1)
rc=$?
echo "$out" | grep -E 'PASS|FAIL|ERROR|ALL DRIVER' || true

if [ "$rc" -eq 0 ] && echo "$out" | grep -q 'ALL DRIVER LIVE LOCATION TESTS PASSED'; then
  echo "DRIVER LIVE LOCATION FIX PROVEN"
  exit 0
fi
echo "DRIVER LIVE LOCATION TEST FAILED"
exit 1
