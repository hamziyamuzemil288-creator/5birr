#!/bin/sh
# LOCAL ONLY -- rebuilds the sandbox database used to EXECUTE 0128's ranking
# lists, field catalogue and provider save path for real. Not a migration and
# never deployed.
#
#   sh tools/harness/replay_ranking.sh
#     -> rebuilds `ranking`, replays the migration verbatim, runs the probe.
#
#   sh tools/harness/replay_ranking.sh --without-ranking
#     -> replays a mutated copy whose provider ordering is the OLD one
#        (created_at DESC). This is the falsification of the probe's central
#        claim: the probe MUST come back red, because a check that has never
#        been seen red is not a check.
#
# postgis and uuid-ossp are unavailable in this sandbox, so the schema is a
# purpose-built stand-in (scratch/db/ranking_pre.sql) carrying only the tables
# the migration reads or writes. The mutation is applied to a COPY in /tmp; the
# migration on disk is never edited.
set -e
PGBIN=/usr/lib/postgresql/14/bin
SOCK=/tmp/pgrun
PORT=5433
DB=ranking
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=/tmp/ranking_replay
mkdir -p "$TMP"

cp "$ROOT/scratch/db/ranking_pre.sql" "$TMP/ranking_pre.sql"
cp "$ROOT/supabase/migrations/20260927000128_every_trade_ranks_its_best_and_prices_its_own.sql" \
   "$TMP/0128.sql"
cp "$ROOT/scratch/db/ranking_probe.sql" "$TMP/ranking_probe.sql"

if [ "${1:-}" = "--without-ranking" ]; then
  python3 - "$TMP/0128.sql" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
old = """      row_number() OVER (
        ORDER BY s.completed_transactions DESC,
                 pp.created_at ASC,
                 pp.id ASC
      ) AS rank_position"""
new = """      row_number() OVER (
        ORDER BY pp.created_at DESC,
                 pp.id ASC
      ) AS rank_position"""
assert src.count(old) == 1, "ranking ORDER BY anchor not found"
p.write_text(src.replace(old, new))
print("mutated: provider ordering reverted to created_at DESC")
PY
fi

chmod 644 "$TMP"/*.sql

su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'DROP DATABASE IF EXISTS $DB'" 2>/dev/null
su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d postgres -q -c 'CREATE DATABASE $DB'"

for f in ranking_pre.sql 0128.sql ranking_probe.sql; do
  echo "== $f"
  su postgres -c "cd $TMP && $PGBIN/psql -h $SOCK -p $PORT -d $DB -q -v ON_ERROR_STOP=1 -f $TMP/$f" || exit 1
done
