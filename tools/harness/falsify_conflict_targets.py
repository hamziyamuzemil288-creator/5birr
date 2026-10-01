#!/usr/bin/env python3
"""Falsification for the `ON CONFLICT DO UPDATE` column check.

A check that has never been seen red is not yet a check.

The bug it exists to catch was REAL: migration 0107's
`admin_save_category_fee` set `booking_base_fare` on a table whose column is
`booking_base_fee`, so every save died at plan time with 42703 and the
per-category fee editor had never once written a row.

Each case below breaks ONE property the check relies on and asserts the check
catches it, or -- just as important -- asserts the check stays QUIET when it
should. Nothing here writes to the repo: the module's `MIGRATIONS` is pointed
at a temporary directory holding patched copies.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import conflict_targets as ct  # noqa: E402

REAL = ct.MIGRATIONS


def run_over(patched: dict[str, str]) -> tuple[list[str], int, int]:
    """Run the check over a copy of the migrations with [file] replaced."""
    tmp = Path(tempfile.mkdtemp())
    try:
        for p in sorted(REAL.glob("*.sql")):
            text = patched.get(p.name, p.read_text(encoding="utf-8", errors="replace"))
            (tmp / p.name).write_text(text, encoding="utf-8")
        original = ct.MIGRATIONS
        ct.MIGRATIONS = tmp
        try:
            return ct.find_bad_targets()
        finally:
            ct.MIGRATIONS = original
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def expect_red(label: str, patched: dict[str, str]) -> bool:
    findings, _, _ = run_over(patched)
    hit = [f for f in findings if "not a column of that table" in f]
    if hit:
        print(f"  ok   {label}: caught -> {hit[0].split(': ', 1)[-1][:90]}")
        return True
    print(f"  FAIL {label}: the check stayed green over a broken statement")
    return False


def expect_green(label: str, patched: dict[str, str]) -> bool:
    findings, _, _ = run_over(patched)
    if findings:
        print(f"  FAIL {label}: the check reported {findings[0][:110]}")
        return False
    print(f"  ok   {label}: stays quiet")
    return True


def main() -> int:
    # The real thing must be green: 0126 restates the function correctly, and a
    # restatement supersedes the broken body in 0107.
    findings, scanned, superseded = ct.find_bad_targets()
    ok = True
    if findings:
        print(f"  FAIL the live migrations report {findings}")
        ok = False
    else:
        print(f"  ok   the live migrations are clean ({scanned} checked, "
              f"{superseded} superseded)")

    # A. THE REAL BUG, re-introduced into the restatement that supersedes it.
    #    This is the case that matters: without the fix in 0126, the check is
    #    green and the fee editor is dead.
    fee = "20260927000126_the_fee_editor_never_worked.sql"
    body = (REAL / fee).read_text(encoding="utf-8")
    assert "booking_base_fee = EXCLUDED.booking_base_fee," in body, "anchor missing"
    ok &= expect_red(
        "A. the 0126 restatement sets a column that does not exist",
        {fee: body.replace("booking_base_fee = EXCLUDED.booking_base_fee,",
                           "booking_base_fare = EXCLUDED.booking_base_fee,", 1)},
    )

    # C. THE DECISIVE CASE. 0107 in the repository still carries the broken
    #    line -- it is deployed history and must never be edited -- and the
    #    check is green only because 0126 restates the function. Remove the
    #    restatement and nothing supersedes 0107, which is EXACTLY the state of
    #    the live database before this fix. The check must be red there, or it
    #    is not really checking anything.
    per_cat = "20260927000107_per_category_and_city_fees.sql"
    per_cat_body = (REAL / per_cat).read_text(encoding="utf-8")
    broken_line = "    booking_base_fare = EXCLUDED.booking_base_fee,\n"
    assert broken_line in per_cat_body, "anchor missing in 0107"
    ok &= expect_red(
        "C. 0107's broken body with no restatement to supersede it",
        {
            fee: body.replace(
                "CREATE OR REPLACE FUNCTION public.admin_save_category_fee(",
                "CREATE OR REPLACE FUNCTION public.admin_save_category_fee_disabled(",
                1),
        },
    )

    # D. A column added by a LATER ALTER TABLE must NOT be reported. The first
    #    version of this scanner took only the first ADD COLUMN of a multi-clause
    #    ALTER TABLE and produced exactly this false positive for
    #    staff_task_completions.cancelled_at, plus two others. A check that
    #    cries wolf is deleted on first sight.
    alter = "20260927000052_cancel_a_single_staff_task.sql"
    alter_body = (REAL / alter).read_text(encoding="utf-8")
    ok &= expect_green(
        "D. a column added by a MULTI-CLAUSE ALTER TABLE is not a finding "
        "(staff_task_completions.cancelled_at and friends)",
        {alter: alter_body},
    )

    # E. Same for a column added by an ordinary single-column ALTER TABLE, which
    #    is the profiles.kebele case.
    ok &= expect_green(
        "E. a column added by an ORDINARY ALTER TABLE is not a finding",
        {per_cat: per_cat_body},
    )

    # F. A table this repository never creates must not be guessed at.
    #    storage.buckets is Supabase-managed; claiming to know its columns would
    #    be inventing evidence.
    bucket_file = "20260927000096_provider_gallery_bucket_exists.sql"
    bucket_body = (REAL / bucket_file).read_text(encoding="utf-8")
    ok &= expect_green(
        "F. storage.buckets is treated as external, not guessed at",
        {bucket_file: bucket_body},
    )

    print()
    print("falsify_conflict_targets: PASS" if ok else "falsify_conflict_targets: FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())