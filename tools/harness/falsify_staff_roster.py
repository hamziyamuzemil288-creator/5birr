#!/usr/bin/env python3
"""Falsification for check_staff_roster_is_wired.

The defect being asserted against is not a crash and not a 500. It is a staff
member whose city and rank are recorded correctly in the database and shown to
nobody, so a manager sets someone to Hawassa and then works an Addis Ababa
queue without ever being told. That is invisible in tests, invisible in CI,
and invisible in the logs -- the only symptom is a human being trusting a
screen that is not showing them what they set.

So each case removes exactly one link:

  A. the roster RPC is never called from the client
  B. the movement RPC is never called
  C. the roster is fetched and the CITY is then discarded
  D. the rank (job_role) is never read
  E. the obligations are never read
  F. the roster is called but the whole result is thrown away
  G. the RPC name survives only inside a comment  (a string check's blind spot)

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

SCREEN = "lib/features/admin/admin_staff_screen.dart"


def with_patches(patches: dict[str, str]) -> list[str]:
    def _read(path: Path) -> str:
        try:
            rel = str(path).replace("\\", "/")
        except Exception:
            rel = ""
        for suffix, text in patches.items():
            if rel.endswith(suffix):
                return text
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_staff_roster_is_wired()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems:
            print("         - " + p)
        return True
    print("[FAIL] %s -> stayed GREEN" % label)
    return False


def expect_green(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if not problems:
        print("[ ok ] %s -> stayed green (correct)" % label)
        return True
    print("[FAIL] %s -> went red on harmless input" % label)
    for p in problems:
        print("         - " + p)
    return False


def main() -> int:
    ok = True

    base = with_patches({})
    if base:
        print("[FAIL] the real sources are already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] real sources are green")

    screen = sc._read(sc.LIB / "features" / "admin" / "admin_staff_screen.dart")

    # A. the roster is never fetched. This is the ORIGINAL defect: the column
    #    exists, the screen never reads it, nothing is wrong anywhere.
    ok &= expect_red(
        "A: admin_staff_roster() is never called",
        {SCREEN: screen.replace("'admin_staff_roster'", "'unused_roster_probe'")})

    # B. the movement log is never called, so the counters on the card have
    #    no drill-down behind them.
    ok &= expect_red(
        "B: staff_activity_feed() is never called",
        {SCREEN: screen.replace("'staff_activity_feed'", "'unused_feed_probe'")})

    # C. the roster IS fetched, and the city is then thrown away. The important
    #    case: a check that only looked for the RPC name passes this, which is
    #    precisely the failure this check exists to prevent.
    ok &= expect_red(
        "C: the roster is fetched but the city is never read",
        {SCREEN: screen.replace("r['city']", "r['not_the_city_column']")})

    # D. the rank is never surfaced.
    ok &= expect_red(
        "D: the rank (job_role) is never read",
        {SCREEN: screen.replace("'job_role'", "'not_the_rank_column'")})

    # E. the obligations are never surfaced.
    ok &= expect_red(
        "E: the granted obligations are never read",
        {SCREEN: screen.replace("'obligations'", "'not_the_obligations_column'")})

    # F. the whole enrichment is computed and discarded.
    ok &= expect_red(
        "F: the roster result is assigned and then thrown away",
        {SCREEN: screen.replace("_roster\n          ..clear()\n          ..addAll(roster);",
                                "_roster.clear();")})

    # G. the RPC name survives ONLY in a comment. A substring check would be
    #    satisfied; a call-site check must not be.
    ok &= expect_red(
        "G: the roster RPC name survives only inside a comment",
        {SCREEN: screen.replace("'admin_staff_roster'",
                                "// 'admin_staff_roster'")})

    # H. a pure RENAME must NOT trip it: the check discovers the map's name
    #    from its declaration, so renaming it everywhere is a refactor, not a
    #    regression. A check that punishes an honest rename gets disabled, and
    #    then catches nothing. The word boundary matters -- `_roster` is a
    #    substring of the RPC name `admin_staff_roster`, and a plain str.replace
    #    renames the RPC too, which is a DIFFERENT defect and not a refactor.
    renamed = re.sub(r"\b_roster\b", "_personnel", screen)
    if "'admin_staff_roster'" not in renamed:
        raise AssertionError("rename collided with the RPC name")
    ok &= expect_green(
        "H: renaming the roster map everywhere (harmless refactor)",
        {SCREEN: renamed})

    if not ok:
        print("\nFALSIFICATION FAILED")
        return 1

    if with_patches({}):
        print("\n[FAIL] the real sources went red")
        return 1
    print("\n[ ok ] real sources still green")
    print("FALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
