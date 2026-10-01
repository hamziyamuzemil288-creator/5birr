#!/usr/bin/env python3
"""Falsification for return_type_changes.check.

A check that has never been seen red is not yet a check. This replays the REAL
migration history with one file mutated in memory -- nothing on disk is touched
-- and proves:

  1. the history as it stands is green;
  2. removing the `DROP FUNCTION` 0126 needs to change admin_warn_user's return
     type from void to text makes it RED, naming 42P13;
  3. a COSMETIC difference (schema qualifier, whitespace, int/INTEGER) stays
     GREEN -- otherwise the gate would cry wolf on every restatement and be
     ignored.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import return_type_changes as rtc  # noqa: E402

TARGET = "20260927000126_the_fee_editor_never_worked.sql"


def main() -> int:
    sources = rtc._sources()
    if TARGET not in sources:
        print(f"[FAIL] {TARGET} is missing")
        return 1
    targets = [rtc.MIGRATIONS / TARGET]

    # 1. the real history is green.
    base = rtc.check(targets, dict(sources))
    if base:
        print("[FAIL] the real history is already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] the real history is green")

    # 2. drop the DROP and the return-type change is caught.
    without_drop = sources[TARGET].replace(
        "DROP FUNCTION IF EXISTS public.admin_warn_user(uuid, text, text);\n",
        "")
    if without_drop == sources[TARGET]:
        print("[FAIL] could not find the admin_warn_user DROP to remove -- the "
              "anchor changed")
        return 1
    mutated = dict(sources)
    mutated[TARGET] = without_drop
    problems = rtc.check(targets, mutated)
    if not problems:
        print("[FAIL] removing the DROP stayed GREEN -- the gate does not "
              "detect the 42P13 it was written for")
        return 1
    if not any("42P13" in p and "admin_warn_user" in p for p in problems):
        print("[FAIL] it went red, but not for the return-type change:")
        for p in problems:
            print("         - " + p)
        return 1
    print("[ ok ] without the DROP, the return-type change is caught:")
    print("         - " + problems[0].split(".")[0] + ".")

    # 3. a COSMETIC restatement must NOT be flagged, or the gate cries wolf on
    #    every restatement and gets ignored. Schema qualifier, case, whitespace
    #    and an int/INTEGER synonym are all the same type to PostgreSQL.
    synthetic = {
        "a.sql": "CREATE OR REPLACE FUNCTION public.foo() RETURNS "
                 "provider_profiles LANGUAGE sql AS $$ SELECT NULL; $$;",
        "b.sql": "CREATE OR REPLACE FUNCTION public.foo() RETURNS "
                 "public.PROVIDER_PROFILES LANGUAGE sql AS $$ SELECT NULL; $$;",
        "c.sql": "CREATE OR REPLACE FUNCTION public.bar() RETURNS int "
                 "LANGUAGE sql AS $$ SELECT 1; $$;",
        "d.sql": "CREATE OR REPLACE FUNCTION public.bar() RETURNS INTEGER "
                 "LANGUAGE sql AS $$ SELECT 1; $$;",
    }
    for target in ("b.sql", "d.sql"):
        if rtc.check([rtc.MIGRATIONS / target], synthetic):
            print("[FAIL] a cosmetic restatement (%s) was flagged -- the gate "
                  "cries wolf" % target)
            return 1
    print("[ ok ] cosmetic restatements stay silent")

    print("\nFALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
