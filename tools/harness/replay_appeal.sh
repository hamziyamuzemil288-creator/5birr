#!/bin/sh
# LOCAL ONLY -- rebuilds the sandbox database used to EXECUTE the appeal
# notification path for real. Not a migration and never deployed.
#
#   sh tools/harness/replay_appeal.sh
#   sh tools/harness/replay_appeal.sh --without-fix   # must be RED
#
# 20260927000131 restates a trigger function, drops and re-adds two CHECK
# constraints, and asserts against pg_constraint and pg_proc. None of that is
# a parsing question: `pg_constraint.consrc` reads fine on a linter and raises
# `column "consrc" does not exist` on PostgreSQL 12+, and a widened CHECK that
# never actually widened parses perfectly while refusing every document appeal
# at runtime. So the migration is run, and it runs against the PRE-0131
# constraint definitions -- a DROP IF EXISTS against a constraint that was
# never there would prove nothing.
set -e
PGBIN=/usr/lib/postgresql/14/bin
SOCK=/tmp/pgrun
PORT=5433
DB=appeal
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=/tmp/appeal_replay
mkdir -p "$TMP"

cp "$ROOT/scratch/db/appeal_pre.sql" "$TMP/appeal_pre.sql"
cp "$ROOT/supabase/migrations/20260927000131_an_appeal_reaches_the_people_who_act_on_it.sql" "$TMP/0131.sql"
cp "$ROOT/scratch/db/appeal_probe.sql" "$TMP/appeal_probe.sql"
chmod 644 "$TMP"/*.sql

su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'DROP DATABASE IF EXISTS $DB'" 2>/dev/null
su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'CREATE DATABASE $DB'"

# `--without-fix` omits 0131 entirely: the falsification of this script's
# central claim. Without it the probe MUST show the reviewers told zero times,
# DOCUMENT_VERIFICATION refused by the CHECK, and anon able to read the roster.
if [ "${1:-}" = "--without-fix" ]; then
  MIGRATIONS=""
  echo "== NOTE: applying NO migration -- this is the pre-0131 state"
else
  MIGRATIONS="0131.sql"
fi

for f in appeal_pre.sql $MIGRATIONS appeal_probe.sql; do
  echo "== $f"
  su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d $DB -q -v ON_ERROR_STOP=1 -f $TMP/$f" || exit 1
done