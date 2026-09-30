#!/usr/bin/env python3
"""Falsification for check_fee_switches_survive_restatement.

The regression: 0073 wired fee_enabled_transaction into
platform_transaction_fee and fee_enabled_ride into calculate_fare_estimate.
0107 restated both as delegations to new category-aware resolvers -- a correct
refactor in every other respect -- and the switch reads went with the old
bodies. Both of the CEO's switches became stored but inert.

Nothing local caught it. 0073's own SQL assertion did, but only against a live
database, so it surfaced in the post-deploy connectivity run instead of before
the push.

Nothing writes to the repo: static_checks._read is overridden.
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import static_checks as sc  # noqa: E402

_real_read = sc._read
FIX = "20260927000115_fix_the_six_connectivity_findings.sql"

ok = True


def run(patch: dict[str, str]) -> list[str]:
    def _read(path):
        for suffix, text in patch.items():
            if str(path).replace("\\", "/").endswith(suffix):
                return text
        return _real_read(path)
    sc._read = _read
    try:
        return sc.check_fee_switches_survive_restatement()
    finally:
        sc._read = _real_read


def expect_red(label: str, patch: dict[str, str]) -> None:
    global ok
    ps = run(patch)
    if ps:
        print("[ ok ] %s -> caught" % label)
        print("         - " + ps[0][:130])
    else:
        ok = False
        print("[FAIL] %s -> stayed GREEN" % label)


def expect_green(label: str) -> None:
    global ok
    ps = run({})
    if not ps:
        print("[ ok ] %s -> stayed green (correct)" % label)
    else:
        ok = False
        print("[FAIL] %s -> false positive: %s" % (label, ps[0][:130]))


source = _real_read(sc.MIGRATIONS / FIX)

expect_green("A: the real 0115 reads both switches")

# B. The exact regression: the switch read is gone from the commission.
strip_tx = source.replace(
    "    WHEN NOT coalesce(public.get_setting_bool('fee_enabled_transaction'), true)",
    "    WHEN false")
assert strip_tx != source, "falsifier anchor missing: transaction switch"
expect_red("B: platform_transaction_fee drops fee_enabled_transaction",
           {FIX: strip_tx})

# C. The same for the ride model.
strip_ride = source.replace(
    "    WHEN NOT coalesce(public.get_setting_bool('fee_enabled_ride'), true)",
    "    WHEN false")
assert strip_ride != source, "falsifier anchor missing: ride switch"
expect_red("C: calculate_fare_estimate drops fee_enabled_ride",
           {FIX: strip_ride})

# D. A DELEGATION is the subtle shape. If the one-argument reader simply
#    forwards to the resolver and names no switch, 0073's assertion fails --
#    which is precisely how 0107 broke it. A check that only asked "does the
#    resolver read the switch?" would pass this.
delegated = source.replace(
    """  SELECT CASE
    WHEN NOT coalesce(public.get_setting_bool('fee_enabled_transaction'), true)
      THEN 0::numeric
    ELSE public.platform_transaction_fee_for(p_amount, NULL, NULL, false)
  END;""",
    """  SELECT public.platform_transaction_fee_for(p_amount, NULL, NULL, false);""")
assert delegated != source, "falsifier anchor missing: the CASE"
expect_red("D: a bare delegation names no switch", {FIX: delegated})

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
