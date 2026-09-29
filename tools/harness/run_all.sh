#!/bin/sh
# Static analysis for Aliob, runnable with no Dart SDK, no Deno and no
# database credentials. Durable copy: build/run_all.sh shims to this file
# because .gitignore excludes build/.
set -u
exec python3 "$(dirname "$0")/static_checks.py"
