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


def _load():
    spec = importlib.util.spec_from_file_location("rbd", CHECKER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _with_copy(mutate):
    """Copy migrations to a temp dir, apply `mutate(path)`, run the checker."""
    mod = _load()
    tmp = Path(tempfile.mkdtemp(prefix="rbd-falsify-"))
    try:
        dest = tmp / "supabase" / "migrations"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "supabase" / "migrations", dest)
        mutate(dest / RESTATE)
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
    return ok, "\n".join(detail)


def _replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise AssertionError(f"falsifier anchor not found in {path.name}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


CASES: list[tuple[str, str, object, bool]] = [
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
]


def main() -> int:
    failures = 0
    for name, why, mutate, expect_green in CASES:
        try:
            green, detail = _with_copy(mutate)
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
