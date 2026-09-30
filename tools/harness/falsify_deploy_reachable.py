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
# nothing created. It must be removed before the file can express the bug --
# and that is exactly the point. The fix is not "the arity happens to match",
# it is "the loop can no longer name a function that does not exist".
GUARD = """      IF v_oid IS NULL THEN
        CONTINUE;
      END IF;

"""
assert GUARD in REAL, "falsifier anchor missing: the pg_proc guard"

# A. The real file, after the fix.
expect_green("A: the real 0107, guarded against a missing overload", REAL)

# B. The shipped defect: an unguarded loop that grants a 3-arg signature for
#    functions that are only ever created with 2 args. This is run 2 exactly.
expect_red("B: an unguarded loop granting an arity nothing creates",
           REAL.replace(GUARD, ""))

# C. A function name nobody creates at all -- the other shape of 42883, and
#    one the arity check alone would miss.
expect_red("C: a loop granting a function nothing creates",
           REAL.replace(GUARD, "").replace(
               "'fee_commission_min',", "'fee_commission_min', 'fee_never_written',"))

# D. A function that exists but with the wrong arity is the subtler case: the
#    name is real, so a check that only asked "does this function exist?" would
#    pass it.
expect_red("D: a loop granting an existing function at the wrong arity",
           REAL.replace(GUARD, "").replace(
               "ARRAY['uuid', 'text', 'boolean']];",
               "ARRAY['uuid', 'text', 'boolean'], ARRAY['uuid', 'text', 'numeric']];"))

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
