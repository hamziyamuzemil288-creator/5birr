#!/usr/bin/env python3
"""Falsification for column_scope.py.

The defect the check exists for killed two consecutive deploys. 0112 wrote

    FROM (SELECT 1 FROM unnest(...) AS x) d WHERE x <> ''

and the live run died with `column "x" does not exist` (42703). 0115 answered
that by naming the column -- `AS x(part)` -- but left the subquery wrapped, so
the derived table still projected the constant 1 and `part` did not exist
either. Neither statement is a SYNTAX error: pglast, the whole-file parse, and
plpgsql_body_syntax.py all accept both, because a name that does not resolve is
only decidable against the scope.

The cases below prove the check bites on both shipped shapes, and -- the half
that matters more -- that it stays silent on the five things that LOOK like
unresolved columns and are not. `--all` over the 204-migration history reports
exactly those four statements and nothing else; every other case here is the
soundness half of that result isolated.

Nothing writes to the repo.
"""
from __future__ import annotations

import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import column_scope as cs  # noqa: E402

MIGRATIONS = cs.MIGRATIONS
ok = True


def run(text: str) -> list[str]:
    """Check one migration held in memory, without touching the repo."""
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as fh:
        fh.write(text)
        path = pathlib.Path(fh.name)
    try:
        return cs.check_file(path)
    finally:
        path.unlink()


def wrap(body: str) -> str:
    """A minimal plpgsql function carrying `body` as its statements."""
    return (
        "CREATE OR REPLACE FUNCTION public.f() RETURNS boolean\n"
        "LANGUAGE plpgsql AS $$\n"
        "DECLARE\n  v_n int;\nBEGIN\n"
        + body + "\n"
        "  RETURN true;\nEND;\n$$;\n"
    )


def expect_red(label: str, text: str, mentions: str) -> None:
    global ok
    ps = run(text)
    hit = [p for p in ps if mentions in p]
    if hit:
        print("[ ok ] %s -> caught" % label)
        print("         - " + hit[0].split(": ", 1)[-1].splitlines()[0][:110])
    else:
        ok = False
        print("[FAIL] %s -> stayed GREEN (%d finding(s))" % (label, len(ps)))


def expect_green(label: str, text: str) -> None:
    global ok
    ps = run(text)
    if not ps:
        print("[ ok ] %s -> stayed green (correct)" % label)
    else:
        ok = False
        print("[FAIL] %s -> false positive: %s" % (label, ps[0].splitlines()[0][:120]))


# --- The two shapes that shipped, restored verbatim -------------------------

expect_red(
    "A: 0112 -- `AS x` names the table, WHERE x is not a column",
    wrap('  SELECT count(*) INTO v_n FROM (\n'
         '    SELECT 1 FROM unnest(string_to_array(\'a(b\', \'c(\')) AS x\n'
         '  ) d WHERE x <> \'\';'),
    "`x`")

expect_red(
    "B: 0115 -- the column is named, but the subquery still projects 1",
    wrap('  SELECT count(*) INTO v_n FROM (\n'
         '    SELECT 1 FROM unnest(string_to_array(\'a(b\', \'c(\')) AS x(part)\n'
         '  ) d WHERE part <> \'\';'),
    "`part`")

# --- Soundness: things that resemble the defect and are valid ---------------

expect_green(
    "C: unnest in FROM (the FIXED shape) -- scope unknown, stay silent",
    wrap('  SELECT count(*) INTO v_n FROM unnest(string_to_array(\'a(b\', \'c(\')) '
         'AS part WHERE part <> \'\';'))

expect_green(
    "D: a derived table that really does have the column",
    wrap('  SELECT count(*) INTO v_n FROM (SELECT 1 AS part) d WHERE part <> \'\';'))

expect_green(
    "E: a base table -- its columns are unknown, so never judged",
    wrap('  SELECT count(*) INTO v_n FROM public.orders o WHERE o.city = \'\';'))

expect_green(
    "F: a DECLARE variable that is not a column",
    "CREATE OR REPLACE FUNCTION public.f() RETURNS boolean\n"
    "LANGUAGE plpgsql AS $$\nDECLARE\n  part text;\n  v_n int;\nBEGIN\n"
    "  SELECT count(*) INTO v_n FROM (SELECT 1) d WHERE part <> '';\n"
    "  RETURN true;\nEND;\n$$;\n")

expect_green(
    "G: a CTE column, referenced correctly",
    wrap('  SELECT count(*) INTO v_n FROM (WITH c AS (SELECT 1 AS n)\n'
         '    SELECT n FROM c) d WHERE n > 0;'))

expect_red(
    "G': a CTE column that does not exist",
    wrap('  SELECT count(*) INTO v_n FROM (WITH c AS (SELECT 1 AS n)\n'
         '    SELECT n FROM c) d WHERE missing > 0;'),
    "`missing`")

expect_red(
    "H: a qualified reference into a derived table",
    wrap('  SELECT count(*) INTO v_n FROM (SELECT 1 AS y) d WHERE d.x = 1;'),
    "`d.x`")

expect_green(
    "I: a schema-qualified name is not mistaken for a derived-table qualifier",
    wrap('  SELECT count(*) INTO v_n FROM (SELECT 1 AS y) d '
         'WHERE d.y = public.some_fn(1);'))

# --- The shipped files themselves ------------------------------------------

shipped_0112 = cs.check_file(
    MIGRATIONS / "20260927000112_staff_city_guards_on_money_and_task_feed.sql")
shipped_0115 = cs.check_file(
    MIGRATIONS / "20260927000115_fix_the_six_connectivity_findings.sql")
if any("`x`" in p for p in shipped_0112) and any("`part`" in p for p in shipped_0115):
    print("[ ok ] J: the two shipped defects are still detected in place")
else:
    ok = False
    print("[FAIL] J: a shipped defect was missed: 0112=%d, 0115=%d"
          % (len(shipped_0112), len(shipped_0115)))

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
