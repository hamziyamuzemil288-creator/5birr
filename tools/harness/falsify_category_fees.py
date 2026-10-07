#!/usr/bin/env python3
"""Falsification for check_category_fees_are_wired.

A check that has never been seen red is not yet a check. Each case below
breaks ONE of the four properties the check asserts and asserts it is caught.
Nothing here writes to the repo: `static_checks._read` is overridden with
in-memory patched copies.

  A. a money column becomes NOT NULL -- an empty table would then mean
     "every fee is zero" instead of "inherit today's global rate"
  B. deduct_subscription_fee stops reading the per-category resolver
  C. a fee field group is rendered but not sent on save
  D. the sidebar card is deleted
  E. an input is prefilled with the EFFECTIVE number (the inheritance trap)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read


def _rel(path: Path) -> str:
    try:
        return str(Path(path)).replace("\\", "/")
    except Exception:
        return ""


def with_patches(patches: dict[str, str]) -> list[str]:
    def _read(path: Path) -> str:
        rel = _rel(path)
        for suffix, text in patches.items():
            if rel.endswith(suffix):
                return text
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_category_fees_are_wired()
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


def main() -> int:
    ok = True

    base = with_patches({})
    if base:
        print("[FAIL] the real sources are already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] real sources are green")

    # Locate the fee migration and the screen, the way the check does --
    # through the shared locator, not a second copy of the rule. This used to
    # be "the last migration mentioning category_fee_settings", which after
    # 0115 restated an assertion that READS that table name became 0115: a
    # file with no table definition in it. Every mutation below then landed
    # nowhere and the cases passed while proving nothing.
    fee_migration = sc.category_fee_storage_migration()
    if fee_migration is None:
        print("[FAIL] could not find the fee migration")
        return 1

    sql = sc._read(fee_migration)
    screen = sc.LIB / "features" / "admin" / "category_fee_settings_screen.dart"
    screen_src = sc._read(screen)
    dash = sc._read(sc.LIB / "features" / "admin" / "admin_dashboard.dart")

    # A. NOT NULL on a money column
    ok &= expect_red(
        "A: subscription_fee becomes NOT NULL",
        {fee_migration.name: sql.replace(
            "subscription_fee   numeric,",
            "subscription_fee   numeric NOT NULL DEFAULT 0,")},
    )

    # B. the subscription money path stops consulting the resolver
    path, defn = sc.last_migration_defining("deduct_subscription_fee")
    rewired = defn.replace("public.fee_subscription(v_ctx.category_id, v_ctx.city)",
                           "coalesce(get_setting_numeric('monthly_subscription_fee'), 0)")
    if rewired != defn:
        ok &= expect_red(
            "B: deduct_subscription_fee stops reading fee_subscription()",
            {path.name: rewired},
        )
    else:
        print("[skip] B: the subscription resolver call shape changed; "
              "the A/C/D cases still prove the check bites")

    # C. a rendered field group can never be sent on save.
    #
    # Re-anchored for the per-model editor: the save call no longer names the
    # groups (it iterates whatever the model mapping returns), so the defect is
    # now "declared and rendered, but no fee model returns it". Dropping
    # _productFields from the mapping is exactly that -- the product section
    # still renders and every input in it is discarded.
    product_branch = screen_src.replace("    _productFields,\n", "", 1)
    if product_branch == screen_src:
        raise AssertionError(
            "falsifier anchor missing: _productFields in the model mapping")
    ok &= expect_red(
        "C: _productFields is rendered but no fee model sends it",
        {screen.name: product_branch},
    )

    # D. the sidebar door is removed
    ok &= expect_red(
        "D: the sidebar card for /admin/fees/categories is deleted",
        {"admin_dashboard.dart": dash.replace(
            "'/admin/fees/categories')", "'/admin/fees')")},
    )

    # E. an input is prefilled with the EFFECTIVE number
    ok &= expect_red(
        "E: a fee input is prefilled from the resolved value",
        {screen.name: re.sub(
            r"TextEditingController\(text:\s*_drafts\[f\.param\]\s*\?\?\s*''\)",
            "TextEditingController(text: effectiveText)",
            screen_src)},
    )

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
