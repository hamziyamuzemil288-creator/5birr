#!/bin/sh
# LOCAL ONLY -- rebuilds the sandbox database used to EXECUTE the registration
# notification path for real. Not a migration and never deployed.
#
#   sh tools/harness/replay_registration.sh
#   sh tools/harness/replay_registration.sh --without-fix   # must be RED
#
# 20260927000130 is two functions and two triggers, and neither is a syntax
# question: `FOR v_recipient IN SELECT ... LOOP` over a set-returning function,
# an AFTER UPDATE trigger comparing OLD and NEW, and a report that reads
# pg_proc.prosrc are all things pglast accepts happily and the database may
# not. Parsing clean is not evidence, so the migration is run.
#
# The schema is a purpose-built stand-in (scratch/db/registration_pre.sql)
# rather than an extension of scratch/db/fee_pre.sql, so this replay and the
# fee replay cannot perturb one another.
set -e
PGBIN=/usr/lib/postgresql/14/bin
SOCK=/tmp/pgrun
PORT=5433
DB=registration
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=/tmp/registration_replay
mkdir -p "$TMP"

cp "$ROOT/scratch/db/registration_pre.sql" "$TMP/registration_pre.sql"
cp "$ROOT/supabase/migrations/20260927000130_a_submission_tells_both_sides.sql" "$TMP/0130.sql"
cp "$ROOT/scratch/db/registration_probe.sql" "$TMP/registration_probe.sql"
chmod 644 "$TMP"/*.sql

su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'DROP DATABASE IF EXISTS $DB'" 2>/dev/null
su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'CREATE DATABASE $DB'"

# `--without-fix` omits 0130 entirely, which is the falsification of this
# script's central claim: without the migration the probe MUST come back with
# zero notices for every case, because that is the shipped state.
if [ "${1:-}" = "--without-fix" ]; then
  MIGRATIONS=""
  echo "== NOTE: applying NO migration -- this is the pre-0130 state"
else
  MIGRATIONS="0130.sql"
fi

for f in registration_pre.sql $MIGRATIONS registration_probe.sql; do
  echo "== $f"
  su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d $DB -q -v ON_ERROR_STOP=1 -f $TMP/$f" || exit 1
done
