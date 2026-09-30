#!/usr/bin/env python3
"""Falsification for a check that a dynamic GRANT/REVOKE can only name a
signature which actually exists.

Two deploys in a row died on this file, both after it had parsed clean
everywhere:

  run 1  ERROR: syntax error at or near "."  (SQLSTATE 42601)
         -- `(SELECT public.category_fee(a, b).id)`, a function call
            qualified like a row.
  run 2  ERROR: function public.fee_ride_base_fare(uuid, text, boolean)
         does not exist  (SQLSTATE 42883)
         -- the privilege loop named a 3-arg overload for all ten readers,
            but only fee_commission_percent and fee_commission_min have one.

Neither is a syntax error, so `pglast` on the file, and on the body, both
pass. They are semantic: a name that resolves to nothing, and an arity
that was never created. This check reads the file the way Postgres would
and asks whether every signature a dynamic privilege statement names is
actually one the same file creates.

Nothing writes to the repo.
"""
from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import static_checks as sc  # noqa: E402

FEES = "20260927000107_per_category_and_city_fees.sql"

ok = True


def expect_red(label: str, sql: str) -> None:
    global ok
    sc._read = _patched(sql)
    try:
        problems = sc.check_dynamic_privileges_name_real_signatures()
    finally:
        sc._read = _real_read
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems[:2]:
            print("         - " + p.splitlines()[0][:120])
    else:
        ok = False
        print("[FAIL] %s -> stayed GREEN" % label)


def expect_green(label: str, sql: str) -> None:
    global ok
    sc._read = _patched(sql)
    try:
        problems = sc.check_dynamic_privileges_name_real_signatures()
    finally:
        sc._read = _real_read
    if not problems:
        print("[ ok ] %s -> stayed green (correct)" % label)
    else:
        ok = False
        print("[FAIL] %s -> false positive: %s"
              % (label, problems[0].splitlines()[0][:120]))


_real_read = sc._read


def _patched(sql: str):
    def _read(path):
        if str(path).replace("\\", "/").endswith(FEES):
            return sql
        return _real_read(path)
    return _read


REAL = _real_read(sc.MIGRATIONS / FEES)

# The guard that repairs it: the loop consults pg_proc and skips a signature
# The fix: the privileges are DERIVED from pg_proc rather than written out, so
# the loop cannot name a signature that does not exist.
DERIVED = "    FROM pg_proc p"
assert DERIVED in REAL, "falsifier anchor missing: the pg_proc-derived loop"

# A. The real file, after the fix.
expect_green("A: the real 0107 derives its privileges from pg_proc", REAL)

# The shipped defect, reconstructed: a loop that hard-codes both signatures for
# all ten readers. Only two of the ten take a third argument, so eight of those
# GRANTs named a function that does not exist -- SQLSTATE 42883, run 2.
HARDCODED = """  FOREACH v_fn IN ARRAY ARRAY[
    'fee_ride_base_fare', 'fee_ride_per_km', 'fee_ride_minimum_fare',
    'fee_booking_base_fare', 'fee_booking_per_km', 'fee_booking_minimum_fee',
    'fee_commission_percent', 'fee_commission_min',
    'fee_subscription', 'fee_activation']
  LOOP
    FOREACH v_args IN ARRAY ARRAY[
      ARRAY['uuid', 'text'], ARRAY['uuid', 'text', 'boolean']]
    LOOP
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role',
                      v_fn || '(' || array_to_string(v_args, ', ') || ')');
    END LOOP;
  END LOOP;"""

def _unguarded(sql: str) -> str:
    """Replace the pg_proc-derived loop with the hard-coded one it replaced.

    Every occurrence is removed, not just the first: the file mentions
    `FROM pg_proc` twice (the loop's own query and the comment above it), so
    replacing one left the guard detectable and every case below passed green
    while proving nothing -- the same stale-anchor failure this file already
    exists to catch, committed by me a second time.
    """
    out = sql.replace(DERIVED, HARDCODED.replace(DERIVED, ""))
    # The assertion functions later in the file legitimately read pg_proc, so
    # the guard that matters is the one inside the privilege loop. Asserting
    # the file no longer mentions it would be wrong, and asserting nothing
    # would let a silent no-op mutation pass -- which is what happened twice.
    assert not sc._privilege_loop_is_derived(out), \
        "falsifier: the privilege loop still reads pg_proc"
    assert out != sql, "falsifier: the mutation did not change the file"
    return out


# B. The shipped defect, verbatim in shape.
expect_red("B: an unguarded loop granting an arity nothing creates",
           _unguarded(REAL))

# C. A function name nobody creates at all -- the other shape of 42883, and one
#    an arity-only check would miss.
expect_red("C: a loop granting a function nothing creates",
           _unguarded(REAL).replace(
               "'fee_commission_min',", "'fee_commission_min', 'fee_never_written',"))

# D. A real function at an arity it was never created with: the subtler case,
#    because the name resolves. A check that only asked "does this function
#    exist?" would pass it.
expect_red("D: a loop granting an existing function at the wrong arity",
           _unguarded(REAL).replace(
               "ARRAY['uuid', 'text', 'boolean']]",
               "ARRAY['uuid', 'text', 'boolean'], ARRAY['uuid', 'text', 'numeric']]"))

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
