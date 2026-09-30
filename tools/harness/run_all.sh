#!/bin/sh
# Static analysis for Aliob, runnable with no Dart SDK, no Deno and no
# database credentials. Durable copy: build/run_all.sh shims to this file
# because .gitignore excludes build/.
set -u
here="$(dirname "$0")"

# 1. The source-level checks.
python3 "$here/static_checks.py"
rc=$?

# 2. SQL inside plpgsql bodies, which static_checks (and pglast on a whole
#    file) cannot see: a migration can parse clean and still be rejected by
#    `supabase db push` the moment the function is created. Scoped to the
#    newest migration -- the one being authored -- because the already-applied
#    history trips the splitter on control flow that shares a `;` boundary,
#    and failing the build on live, working SQL is how a real signal gets
#    ignored. `--all` is available for a deliberate audit.
python3 "$here/plpgsql_body_syntax.py" --recent 1
rc2=$?

# 3. The router's redirect rules, searched for cycles by simulation.
#    A redirect loop is a property of two branches in combination, so no
#    source scan of either branch alone can find one -- which is exactly how
#    `redirect loop detected` shipped to a device.
python3 "$here/redirect_cycle_simulation.py"
rc3=$?

# 4. Every `CREATE OR REPLACE FUNCTION` that re-issues a body must be a pure
#    superset of the body it replaces, adding only the approved scope guard.
#    Restating a function is how a city guard gets silently deleted along with
#    the half of the guard nobody remembered was there: the file still parses,
#    the function still exists, and one line of enforcement is simply gone.
python3 "$here/restated_body_diff.py"
rc4=$?

# 5. The Dart compiler, when a Flutter SDK is on PATH.
#
#    Gates 1-4 all read Dart as TEXT. That is their structural limit, not an
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
  rc5=$?
else
  echo "skip: no Flutter SDK on PATH -- the Dart compiler did NOT run"
  echo "      (static checks cannot find compile errors; see ARCHITECTURE.md 7.1)"
  rc5=0
fi

[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && [ $rc3 -eq 0 ] && [ $rc4 -eq 0 ] && [ $rc5 -eq 0 ]
exit $?
