#!/bin/sh
# LOCAL ONLY -- rebuilds the sandbox database used to execute the per-category
# fee write path for real. Not a migration and never deployed.
#
#   sh tools/harness/replay_fee.sh
#
# postgis and uuid-ossp are unavailable in this sandbox, so the schema is a
# purpose-built stand-in (scratch/db/fee_pre.sql) carrying only the tables the
# fee functions read or write. The two migrations that define the path are then
# replayed over it verbatim -- nothing about the functions is edited.
set -e
PGBIN=/usr/lib/postgresql/14/bin
SOCK=/tmp/pgrun
PORT=5433
DB=fee
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=/tmp/fee_replay
mkdir -p "$TMP"

cp "$ROOT/scratch/db/fee_pre.sql" "$TMP/fee_pre.sql"
cp "$ROOT/supabase/migrations/20260927000062_fees_are_data.sql" "$TMP/0062.sql"
cp "$ROOT/supabase/migrations/20260927000107_per_category_and_city_fees.sql" "$TMP/0107.sql"
cp "$ROOT/supabase/migrations/20260927000126_the_fee_editor_never_worked.sql" "$TMP/0126.sql"
cp "$ROOT/supabase/migrations/20260927000127_a_document_tells_both_sides.sql" "$TMP/0127.sql"
cp "$ROOT/scratch/db/fee_probe.sql" "$TMP/fee_probe.sql"
cp "$ROOT/scratch/db/image_probe.sql" "$TMP/image_probe.sql"
cp "$ROOT/scratch/db/document_probe.sql" "$TMP/document_probe.sql"
chmod 644 "$TMP"/*.sql

su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'DROP DATABASE IF EXISTS $DB'" 2>/dev/null
su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'CREATE DATABASE $DB'"

# `sh tools/harness/replay_fee.sh --without-fix` omits 0126. That is the
# falsification of this file's central claim: the fee probe MUST come back red
# for CASE 1 and CASE 2b when the corrected restatement is not applied.
#
# The order is FILENAME order, the order the deploy applies them. It used to be
# 0062 0107 0127 0126, which put the document migration before the fee one it
# follows on the real database -- harmless while neither depended on the other,
# but a replay that applies the batch out of order is not reproducing the thing
# it claims to reproduce.
FEE_BASE="0062.sql 0107.sql"
if [ "${1:-}" = "--without-fix" ]; then
  MIGRATIONS="$FEE_BASE 0127.sql"
else
  MIGRATIONS="$FEE_BASE 0126.sql 0127.sql"
fi

for f in fee_pre.sql $MIGRATIONS fee_probe.sql image_probe.sql document_probe.sql; do
  echo "== $f"
  su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d $DB -q -v ON_ERROR_STOP=1 -f $TMP/$f" || exit 1
done