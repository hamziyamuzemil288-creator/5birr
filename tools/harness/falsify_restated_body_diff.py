#!/usr/bin/env python3
"""Falsification suite for tools/harness/restated_body_diff.py.

A check that has never been seen red is not a check.  This suite mutates a
throwaway copy of supabase/migrations/ in a temp directory, repoints the
checker at the copy, and asserts the checker reacts.  The real repository is
never written to.

Each case states the defect it injects and the failure it must provoke.
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools" / "harness" / "restated_body_diff.py"
RESTATE = "20260927000112_staff_city_guards_on_money_and_task_feed.sql"
FIX = "20260927000116_the_task_feed_assertion_can_count.sql"


def _load():
    spec = importlib.util.spec_from_file_location("rbd", CHECKER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _with_copy(mutate, target: str = RESTATE):
    """Copy migrations to a temp dir, apply `mutate(path)`, run the checker."""
    mod = _load()
    tmp = Path(tempfile.mkdtemp(prefix="rbd-falsify-"))
    try:
        dest = tmp / "supabase" / "migrations"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "supabase" / "migrations", dest)
        mutate(dest / target)
        mod.MIGRATIONS = dest
        return run_case(mod)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def run_case(mod) -> tuple[bool, str]:
    """Run every case against the (possibly mutated) module; report pass/fail."""
    ok = True
    detail = []
    for fn, src, dst, allowed in mod.CASES:
        problems = mod.check_case(fn, src, dst, allowed, verbose=False)
        ok = ok and not problems
        detail.append(f"{fn}: {'clean' if not problems else str(len(problems)) + ' problem(s)'}")
        for p in problems:
            detail.append(f"    {p}")
    for fn, src, dst, vocab, present, absent in mod.FIXES:
        problems = mod.check_fix(fn, src, dst, vocab, present, absent)
        ok = ok and not problems
        detail.append(f"{fn} (fix): {'clean' if not problems else str(len(problems)) + ' problem(s)'}")
        for p in problems:
            detail.append(f"    {p}")
    return ok, "\n".join(detail)


def _replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise AssertionError(f"falsifier anchor not found in {path.name}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


CASES: list[tuple] = [
    (
        "A. baseline: the real repo is clean",
        "with no mutation the checker must pass, or every case below is vacuous",
        lambda p: None,
        True,
    ),
    (
        "B. a restatement silently DROPS an original line",
        "delete the city guard's supporting WHERE from verify_payment_proof",
        lambda p: _replace_once(
            p,
            "     WHERE proof.id = p_proof_id))\n",
            "",
        ),
        False,
    ),
    (
        "C. a restatement SNEAKS IN an unrelated change",
        "add a real statement inside verify_payment_proof, one the checker diffs",
        lambda p: _replace_once(
            p,
            "     OR NOT public.staff_scope_allows_city(",
            "     OR false -- temporarily bypassed while investigating\n"
            "     OR NOT public.staff_scope_allows_city(",
        ),
        False,
    ),
    (
        "D. a guard is REMOVED entirely",
        "the task feed loses one of its three city guards",
        lambda p: _replace_once(
            p,
            "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))\n",
            "",
        ),
        False,
    ),
    (
        "E. a guard is WEAKENED, not removed",
        "the wallet-recharge guard no longer honours v_view_all",
        lambda p: _replace_once(
            p,
            "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
            "      AND public.staff_scope_allows_city(pp.city, v_staff.user_id)",
        ),
        False,
    ),
    (
        "F. a guard is re-indented only (must stay GREEN)",
        "proves the check judges content, not column position",
        lambda p: _replace_once(
            p,
            "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
            "        AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
        ),
        True,
    ),
    (
        "G. only comments change (must stay GREEN)",
        "proves the check is not defeated by prose",
        lambda p: _replace_once(
            p,
            "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
            "      -- re-asserted on review\n"
            "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
        ),
        True,
    ),
    # --- the fix-restatement assertion (0115 -> 0116) -------------------------
    (
        "H. the 0116 fix is reverted to the broken 0115 shape",
        "the derived-table wrapper and its missing column come straight back -- "
        "the exact pair of 42703 deploy failures the fix exists to end",
        lambda p: _replace_once(
            p,
            "  SELECT count(*) INTO v_cat_guard\n"
            "    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS part\n"
            "   WHERE part <> '';",
            "  SELECT count(*) INTO v_cat_guard FROM (\n"
            "    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x\n"
            "  ) d WHERE x <> '';",
        ),
        False,
        FIX,
    ),
    # Same revert, in the exact form 0115 shipped: the alias list that DID
    # name a column, still wrapped in a subquery that does not project it. This
    # is the subtle half -- `part` is a real name, and the defect is that the
    # derived table has no such column.
    (
        "I. the fix is reverted to 0115's alias-list-but-wrapped form",
        "`AS x(part)` is in the body but `part` is still not a column of the "
        "derived table, so this must be caught on the absent-wrapper rule",
        lambda p: _replace_once(
            p,
            "  SELECT count(*) INTO v_cat_guard\n"
            "    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS part\n"
            "   WHERE part <> '';",
            "  SELECT count(*) INTO v_cat_guard FROM (\n"
            "    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x(part)\n"
            "  ) d WHERE part <> '';",
        ),
        False,
        FIX,
    ),
    (
        "J. HALF the fix is applied (must be RED)",
        "the category count is repaired and the city count is not, which is the "
        "half-repair that passes a reviewer's eye and ships one broken statement",
        lambda p: _replace_once(
            p,
            "  SELECT count(*) INTO v_city_guard\n"
            "    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_city(')) AS part\n"
            "   WHERE part <> '';",
            "  SELECT count(*) INTO v_city_guard FROM (\n"
            "    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_city(')) AS x(part)\n"
            "  ) d WHERE part <> '';",
        ),
        False,
        FIX,
    ),
    (
        "K. the fix also touches an UNRELATED line (must be RED)",
        "a defect repair that quietly drops the missing-function check would "
        "leave the assertion green when staff_task_feed is gone",
        lambda p: _replace_once(
            p,
            "  IF v_feed IS NULL THEN\n    RAISE EXCEPTION 'staff_task_feed is missing';\n  END IF;\n",
            "",
        ),
        False,
        FIX,
    ),
    (
        "L. the repaired statement is merely re-wrapped (must stay GREEN)",
        "proves the fix rule judges the statement, not its line breaks",
        lambda p: _replace_once(
            p,
            "  SELECT count(*) INTO v_cat_guard\n"
            "    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS part\n"
            "   WHERE part <> '';",
            "  SELECT count(*) INTO v_cat_guard FROM unnest(\n"
            "    string_to_array(v_feed, 'staff_scope_allows_category(')) AS part\n"
            "   WHERE part <> '';",
        ),
        True,
        FIX,
    ),
]


def main() -> int:
    failures = 0
    for entry in CASES:
        name, why, mutate, expect_green = entry[:4]
        # The last element names the migration the mutation is injected into;
        # cases A-G all target the 0112 restatement, H-L the 0116 repair.
        target = entry[4] if len(entry) > 4 else RESTATE
        try:
            green, detail = _with_copy(mutate, target)
        except AssertionError as exc:
            print(f"[BROKEN] {name}\n  falsifier itself failed: {exc}")
            failures += 1
            continue
        if green == expect_green:
            print(f"[ok]     {name}")
        else:
            want = "green" if expect_green else "RED"
            print(f"[FAILED] {name}\n  expected {want}, got "
                  f"{'green' if green else 'RED'}\n  why: {why}\n{detail}")
            failures += 1

    print(f"\n{len(CASES) - failures}/{len(CASES)} falsification cases behaved as required")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
