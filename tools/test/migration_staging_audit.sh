#!/usr/bin/env bash
# Which migration files does the deploy workflow's one-file-per-version staging
# silently drop, and do any of them define a function that an APPLIED file
# re-emits (i.e. the fix is unreachable through deploys)?
#
# This mirrors .github/workflows/deploy-supabase.yml "Stage migrations" step
# exactly: glob order, version = "${base%%_*}", non-numeric prefix skipped,
# first file per version wins.
set -eu
cd "$(dirname "$0")/../.."
MIG=supabase/migrations
stage="$(mktemp -d)"; seen="$(mktemp)"
applied=()

for f in "$MIG"/*.sql; do
  base="$(basename "$f")"
  v="${base%%_*}"
  case "$v" in
    ''|*[!0-9]*) echo "SKIP (non-numeric prefix): $base"; continue ;;
  esac
  if grep -qx "$v" "$seen"; then
    echo "DROP (duplicate version $v): $base"
    continue
  fi
  echo "$v" >> "$seen"
  applied+=("$f")
  cp "$f" "$stage/"
done

echo
echo "=== staged: $(ls "$stage" | wc -l) files ==="

echo
echo "=== functions defined in DROPPED files that a later APPLIED file re-emits ==="
for f in "$MIG"/*.sql; do
  base="$(basename "$f")"
  v="${base%%_*}"
  case "$v" in ''|*[!0-9]*) continue ;; esac
  grep -qx "$v" "$seen" && first_of_version="$v" || continue
  # determine if THIS file is the staged one
  is_staged=0
  for a in "${applied[@]}"; do [ "$a" = "$f" ] && is_staged=1; done
  [ "$is_staged" -eq 1 ] && continue
  grep -qi "create or replace function" "$f" || continue
  echo "DROPPED: $base"
  grep -oiE "create (or replace )?function (public\.)?[a-z0-9_]+" "$f" \
    | sed -E 's/.*function (public\.)?//' | tr 'A-Z' 'a-z' | sort -u | while read -r fn; do
      hits=""
      for a in "${applied[@]}"; do
        if grep -qiE "create (or replace )?function (public\.)?$fn\b" "$a"; then
          hits="$hits $(basename "$a")"
        fi
      done
      [ -n "$hits" ] && echo "    $fn -> also emitted by applied:$hits"
    done
done
rm -rf "$stage" "$seen"
