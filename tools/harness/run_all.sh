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

[ $rc -eq 0 ] && [ $rc2 -eq 0 ]
exit $?
