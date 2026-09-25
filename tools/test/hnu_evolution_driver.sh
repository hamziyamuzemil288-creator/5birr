#!/usr/bin/env bash
# handle_new_user EVOLUTION REPLAY driver (local only; run from repo root).
#
# Rebuilds a stub database for every historical revision of handle_new_user,
# applies that revision, and runs the six-path signup matrix. Each revision's
# results are judged against its historical contract:
#   R1 20260923000005 (OTP gate + address fields): A B C D must pass; E F fail
#   R2 20260924000001 (referral tracking):         A B C D must pass; E F fail
#   R3 20260924000005 (staff gateway bypass):      A B C D F must pass; E fail
#   R4 20260925000000 (Google OAuth gate):         A B C D E F must ALL pass
#   R5 20260925120000 (consolidated):              A B C D E F must ALL pass
# The consolidated migration is validated only if every historical contract
# holds AND R5 is all-green.
set -u
cd "$(dirname "$0")/../.." || exit 2
REPO="$(pwd)"
DB=hnu_replay
WORK=/tmp/hnu_replay
rm -rf "$WORK"; mkdir -p "$WORK"
cp tools/test/hnu_evolution_prelude.sql tools/test/hnu_sweep_runner.sql "$WORK/"
for f in 20260923000005_otp_signup_gate_and_doc_requirements \
         20260924000001_referral_signup_trigger \
         20260924000005_staff_gateway_tasks \
         20260925000000_google_oauth_signup_gate; do
  awk 'BEGIN{f=0} tolower($0) ~ /create or replace function public\.handle_new_user/{f=1} f{print} f && $0 ~ /^\$\$;[[:space:]]*$/{exit}' \
    "supabase/migrations/$f.sql" > "$WORK/$f.fn"
done
cp supabase/migrations/20260925120000_handle_new_user_consolidated.sql "$WORK/"
chmod 644 "$WORK"/*

run_rev() { # $1 label  $2 fn-file   (empty fn-file = consolidated only)
  sudo -u postgres dropdb --if-exists "$DB" >/dev/null 2>&1
  sudo -u postgres createdb "$DB" || { echo "  cannot create $DB"; return 9; }
  sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/hnu_evolution_prelude.sql" >/dev/null 2>&1 \
    || { echo "  prelude FAILED"; return 9; }
  if [ -n "${2:-}" ]; then
    sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$WORK/$2" >/dev/null 2>&1 \
      || { echo "  revision apply FAILED"; return 9; }
  fi
  # RAISE NOTICE lands on stderr — merge before filtering.
  sudo -u postgres psql -q -v ON_ERROR_STOP=0 -d "$DB" -f "$WORK/hnu_sweep_runner.sql" 2>&1 \
    | grep -oE '(PASS|FAIL) [A-F]_[a-z_]+'
}

fails=0
judge() { # $1 label $2 output $3 expected-pass letters e.g. ABCDF
  local label="$1" out="$2" exp="$3" p f
  echo "--- $label"
  p=$(echo "$out" | grep -c '^PASS' || true)
  f=$(echo "$out" | grep -c '^FAIL' || true)
  local bad=""
  for L in A B C D E F; do
    if echo "$exp" | grep -q "$L"; then
      echo "$out" | grep -q "^PASS ${L}_" || bad="$bad L($L) expected pass"
    else
      echo "$out" | grep -q "^FAIL ${L}_" || bad="$bad L($L) expected fail"
    fi
  done
  echo "    pass=$p fail=$f contract=$( [ -z "$bad" ] && echo OK || echo VIOLATION )$bad"
  [ -z "$bad" ] || fails=$((fails+1))
}

echo "=== handle_new_user EVOLUTION REPLAY ==="
o=$(run_rev R1 20260923000005_otp_signup_gate_and_doc_requirements.fn); judge "R1 otp-gate+address"      "$o" "ABCD"
o=$(run_rev R2 20260924000001_referral_signup_trigger.fn);          judge "R2 referral-tracking"        "$o" "ABCD"
o=$(run_rev R3 20260924000005_staff_gateway_tasks.fn);              judge "R3 staff-gateway"            "$o" "ABCDF"
o=$(run_rev R4 20260925000000_google_oauth_signup_gate.fn);         judge "R4 google-oauth-gate"        "$o" "ABCDEF"
o=$(run_rev R5 20260925120000_handle_new_user_consolidated.sql);                 judge "R5 CONSOLIDATED (the fix)"   "$o" "ABCDEF"

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL REVISION CONTRACTS HOLD — consolidated fix validated on every path"
else
  echo "CONTRACT VIOLATIONS: $fails revision(s) — DO NOT SHIP"
fi
exit $fails
