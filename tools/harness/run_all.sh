#!/bin/sh
# Static analysis for Aliob, runnable with no Dart SDK, no Deno and no
# database credentials. Durable copy: build/run_all.sh shims to this file
# because .gitignore excludes build/.
set -u
here="$(dirname "$0")"

# 1. The source-level checks.
python3 "$here/static_checks.py"
rc1=$?

# 2. SQL inside plpgsql bodies, which static_checks (and pglast on a whole
#    file) cannot see: a migration can parse clean and still be rejected by
#    `supabase db push` the moment the function is created. Scoped to the
#    migrations a deploy would actually apply (see pending.py) -- NOT the whole
#    history, because the already-applied files trip the splitter on control
#    flow that shares a `;` boundary, and failing the build on live, working SQL
#    is how a real signal gets ignored. `--all` is available for an audit.
python3 "$here/plpgsql_body_syntax.py" --pending
rc2=$?

# 3. Column references a query's own scope cannot provide.
#
#    Two consecutive deploys died on `column "x"/"part" does not exist`
#    (42703), and NEITHER statement is a syntax error: pglast, the whole-file
#    parse, and gate 2 all accept a reference to a name that does not resolve,
#    because resolution is not a parsing question. 0112 wrote `AS x` (a table
#    alias where a column was meant); 0115 named the column but left the
#    subquery wrapped, so the derived table still projected the constant 1.
#    Judged only when EVERY relation in scope is a derived table or CTE with a
#    fully-known output, so an unknown relation can only suppress a finding,
#    never invent one. `--all` over the history reports exactly those four
#    statements and nothing else. Same window as gate 2: everything not yet on
#    the live database, so one run answers "is what I am about to push clean?"
#    rather than "is the file I am typing clean?".
python3 "$here/column_scope.py" --pending
rc3=$?

# 4. The router's redirect rules, searched for cycles by simulation.
#    A redirect loop is a property of two branches in combination, so no
#    source scan of either branch alone can find one -- which is exactly how
#    `redirect loop detected` shipped to a device.
python3 "$here/redirect_cycle_simulation.py"
rc4=$?

# 5. Every `CREATE OR REPLACE FUNCTION` that re-issues a body must be a pure
#    superset of the body it replaces, adding only the approved scope guard.
#    Restating a function is how a city guard gets silently deleted along with
#    the half of the guard nobody remembered was there: the file still parses,
#    the function still exists, and one line of enforcement is simply gone.
python3 "$here/restated_body_diff.py"
rc5=$?

# 6. Every `ON CONFLICT ... DO UPDATE SET col =` names a real column.
#
#    This one exists because gates 1-5 were ALL green over a function that had
#    never once written a row. `admin_save_category_fee` set
#    `booking_base_fare` on a table whose column is `booking_base_fee`, and
#    PostgreSQL analyses that clause before it executes -- so every save died
#    with 42703 and nothing behind it changed.
#
#    Nothing else could see it, and that is the point. 0124 proved the
#    function EXISTS with the arity and parameter names the client sends. The
#    Dart check proved the client sends no undeclared key. The fee check proved
#    every field group is rendered AND sent. All three were correct, and all
#    three describe the CALL rather than the STATEMENT. A body that is
#    correctly named, correctly granted and correctly called can still be
#    unable to run.
#
#    A restatement supersedes: the live database holds the last definition, so a
#    bug in a superseded body is history and not a live defect. Flagging it
#    anyway would leave this gate permanently red over a migration that can
#    never be edited.
python3 "$here/conflict_targets.py"
rc6=$?

# 7. The Dart compiler, when a Flutter SDK is on PATH.
#
#    Gates 1-5 all read Dart as TEXT. That is their structural limit, not an
#    oversight: no regex can tell that `"…$"` inside a string literal is an
#    interpolation with no identifier, that GoTrue exports an `AuthState` that
#    collides with the app's own, or that `DropdownMenu.onChanged` passes a
#    `String?` to a handler declared `String`. All 39 checks and all 12
#    falsifiers were green over 7 real compile errors.
#
#    Skipped, not failed, when the SDK is absent -- a gate that cannot run in
#    the environment it is invoked from trains people to ignore its output.
#    CI always has it, and this project's CI runs the same command, so the
#    authoritative check never depends on this script.
if command -v flutter >/dev/null 2>&1; then
  flutter analyze --no-fatal-infos --no-fatal-warnings
  rc7=$?
else
  echo "skip: no Flutter SDK on PATH -- the Dart compiler did NOT run"
  echo "      (static checks cannot find compile errors; see ARCHITECTURE.md 7.1)"
  rc7=0
fi

# 8. A CREATE OR REPLACE FUNCTION that changes an existing return type.
#
#    PostgreSQL refuses that with 42P13 ("cannot change return type of existing
#    function") WHILE ANALYSING the statement, before it reads the new body --
#    and CREATE OR REPLACE cannot do it at all; the signature has to be DROPPED
#    first. That is how this batch died: 0126 restated admin_warn_user, which
#    the live database already had returning void, so the deploy stopped on
#    0126 and 0127 and 0128 never applied.
#
#    Every other gate was green over it. The body was allowed to change, the
#    statement parsed, the ON CONFLICT targets were real, the call and the
#    grant were correct -- the only thing compared was the BODY, never the
#    return type, and that comparison happens nowhere but at push time.
#
#    Same pending window as gates 2 and 3: the question is "will what I am
#    about to push apply?". A return-type change that already deployed is not a
#    finding here, because it could not have deployed without its DROP.
python3 "$here/return_type_changes.py" --pending
rc8=$?

[ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ $rc3 -eq 0 ] && [ $rc4 -eq 0 ] && \
[ $rc5 -eq 0 ] && [ $rc6 -eq 0 ] && [ $rc7 -eq 0 ] && [ $rc8 -eq 0 ]
exit $?
