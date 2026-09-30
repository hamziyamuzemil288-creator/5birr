#!/usr/bin/env python3
"""Falsification for the LANGUAGE sql branch of plpgsql_body_syntax.py.

The defect this session shipped: 0107 wrote ten scalar fee readers whose first
fallback line was

    WHERE f.id = (SELECT public.category_fee(p_category_id, p_city).id))

A function call cannot be qualified with `.id`. It reached the database inside
`AS $$ ... $$`, which an outer pglast pass sees as a string literal, so the
whole-file parse passed, and the deploy failed at runtime with

    ERROR: syntax error at or near "." (SQLSTATE 42601)

The gate now also parses LANGUAGE sql bodies. These cases prove it bites, and
-- just as importantly -- that it stays quiet on the two things that look like
bugs and are not.

Nothing writes to the repo.
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import plpgsql_body_syntax as pbs  # noqa: E402

MIG = pbs.MIGRATIONS if hasattr(pbs, "MIGRATIONS") else HERE.parent.parent / "supabase" / "migrations"
FEES = MIG / "20260927000107_per_category_and_city_fees.sql"
ROLE = MIG / "20260922000012_role_hierarchy_and_ride_fare.sql"

ok = True


def run(text: str) -> list[str]:
    """Check one migration held in memory, without touching the repo."""
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(text)
        path = pathlib.Path(fh.name)
    try:
        return pbs.check_file(path)
    finally:
        path.unlink()


def expect_red(label: str, text: str) -> None:
    global ok
    problems = run(text)
    hit = [p for p in problems if "does not parse" in p]
    if hit:
        print("[ ok ] %s -> caught" % label)
        print("         - " + hit[0].split(": ", 1)[-1].splitlines()[0][:110])
    else:
        ok = False
        print("[FAIL] %s -> stayed GREEN" % label)


def expect_green(label: str, text: str) -> None:
    global ok
    problems = [p for p in run(text) if "does not parse" in p]
    if not problems:
        print("[ ok ] %s -> stayed green (correct)" % label)
    else:
        ok = False
        print("[FAIL] %s -> false positive: %s"
              % (label, problems[0].splitlines()[0][:110]))


# The real files must be clean. If this goes red the shipped code is broken.
expect_green("A: the real 0107 parses, after the fix", FEES.read_text())

# B. The shipped defect, restored verbatim.
broken = FEES.read_text().replace(
    "(SELECT (public.category_fee(p_category_id, p_city)).id))",
    "(SELECT public.category_fee(p_category_id, p_city).id))")
assert broken != FEES.read_text(), "falsifier anchor missing: the fix"
expect_red("B: a function call qualified with .id", broken)

# C. A plpgsql-only construct in a LANGUAGE sql body is a real error, and the
#    same text in a plpgsql body is fine.
#
#    The first attempt at this case used `SELECT ... INTO v`, which pglast
#    accepts: that is Postgres's own SELECT-INTO, which creates a table. It is
#    valid in both languages, so the case stayed green for a reason that had
#    nothing to do with the gate. `RETURN` is the construct that is genuinely
#    plpgsql-only.
expect_red(
    "C: RETURN inside a LANGUAGE sql body",
    "CREATE FUNCTION public.f() RETURNS int LANGUAGE sql AS $$\n"
    "  SELECT 1;\n  RETURN 1;\n$$;\n")
expect_green(
    "C': the same RETURN inside a plpgsql body",
    "CREATE FUNCTION public.f() RETURNS int LANGUAGE plpgsql AS $$\n"
    "BEGIN\n  RETURN 1;\nEND;\n$$;\n")

# D. The bug in the FIX for the check: a fixed 800-char lookback reached into
#    the previous function, so a `LANGUAGE sql` above a plpgsql body relabelled
#    it and reported valid SQL as broken.
expect_green(
    "D: a plpgsql body following a LANGUAGE sql one",
    "CREATE FUNCTION public.a() RETURNS int LANGUAGE sql AS $$\n"
    "  SELECT 1;\n$$;\n\n"
    "CREATE FUNCTION public.b() RETURNS int LANGUAGE plpgsql AS $$\n"
    "DECLARE v int;\nBEGIN\n  SELECT x INTO v FROM public.t;\n"
    "  RETURN v;\nEND;\n$$;\n")

# E. ...and the reverse order, which is the arrangement that produced nine
#    false positives across already-applied history.
expect_green(
    "E: a LANGUAGE sql body following a plpgsql one",
    "CREATE FUNCTION public.a() RETURNS int LANGUAGE plpgsql AS $$\n"
    "BEGIN RETURN 1; END;\n$$;\n\n"
    "CREATE FUNCTION public.b() RETURNS int LANGUAGE sql AS $$\n"
    "  SELECT 2;\n$$;\n")

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
