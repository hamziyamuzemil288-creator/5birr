#!/usr/bin/env python3
"""Falsification for check_category_fields_are_wired.

A check that has never been seen red is not yet a check. Each case below
breaks ONE property the check asserts and proves it is caught. Nothing here
writes to the repo: `static_checks._read` is overridden with in-memory patched
copies, so the real check code runs against a mutated string.

  A. a SQL parameter is renamed on the server but not in the client contract
     (PGRST202 at runtime, invisible to the Dart compiler)
  B. `ranked_providers` orders by created_at again -- still parses, still
     returns rows, no longer a ranking
  C. the customer reader stops filtering on APPROVED -- a pending provider's
     declared values would join the public page
  D. the saver stops writing one of the value columns
  E. the admin sidebar card for the field editor is deleted
  F. signup stops asking the category
  G. a call site sends a key the function does not declare
"""
from __future__ import annotations

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
        return sc.check_category_fields_are_wired()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems[:3]:
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

    mig = sc.CATEGORY_FIELD_MIGRATION
    mig_src = sc._read(sc.MIGRATIONS / mig)
    signup = sc._read(sc.LIB / "features" / "auth" / "signup_screen.dart")
    dash = sc._read(sc.LIB / "features" / "admin" / "admin_dashboard.dart")
    detail = sc._read(sc.LIB / "features" / "user"
                      / "user_provider_detail_screen.dart")

    # A. a server-side parameter rename the client never follows.
    renamed = mig_src.replace(
        "  p_category_id uuid DEFAULT NULL,",
        "  p_cat_id uuid DEFAULT NULL,")
    if renamed == mig_src:
        print("[FAIL] A: could not find the ranked_providers parameter to "
              "rename -- the anchor changed")
        return 1
    ok &= expect_red("A: ranked_providers's p_category_id is renamed",
                     {mig: renamed})

    # B. the ranking reverts to signup order.
    reverted = mig_src.replace(
        "ORDER BY s.completed_transactions DESC,",
        "ORDER BY pp.created_at DESC,")
    if reverted == mig_src:
        print("[FAIL] B: could not find ranked_providers's ORDER BY to "
              "revert -- the anchor changed")
        return 1
    ok &= expect_red("B: ranked_providers orders by created_at again",
                     {mig: reverted})

    # C. the customer reader loses its APPROVED gate.
    ungated = mig_src.replace(
        "AND pp.status = 'APPROVED'::account_status;",
        ";")
    if ungated == mig_src:
        print("[FAIL] C: could not find provider_public_profile_fields's "
              "status gate -- the anchor changed")
        return 1
    ok &= expect_red("C: provider_public_profile_fields drops the APPROVED gate",
                     {mig: ungated})

    # D. the saver stops writing value_number.
    saver_broken = mig_src.replace("value_number", "value_num_x")
    if saver_broken == mig_src:
        print("[FAIL] D: could not find value_number in the migration")
        return 1
    ok &= expect_red("D: save_provider_profile_field stops using value_number",
                     {mig: saver_broken})

    # E. the admin door is removed.
    dash_broken = dash.replace(
        "context.push('/admin/category-fields')",
        "context.push('/admin/fees')")
    if dash_broken == dash:
        print("[FAIL] E: could not find the sidebar card to delete")
        return 1
    ok &= expect_red("E: the admin sidebar card for the field editor is deleted",
                     {"admin_dashboard.dart": dash_broken})

    # F. signup stops asking the category.
    signup_broken = signup.replace("_selectedCategoryId", "_chosenCategory")
    if signup_broken == signup:
        print("[FAIL] F: could not find _selectedCategoryId in signup_screen")
        return 1
    ok &= expect_red("F: signup stops asking the provider's category",
                     {"signup_screen.dart": signup_broken})

    # H. the category rail stops being ranked.
    home = sc._read(sc.LIB / "features" / "user" / "user_home_screen.dart")
    home_broken = home.replace("'ranked_categories'", "'categories_unranked'")
    if home_broken == home:
        print("[FAIL] H: could not find the ranked_categories call to break")
        return 1
    ok &= expect_red("H: the home category rail stops reading ranked_categories",
                     {"user_home_screen.dart": home_broken})

    # G. a call site sends a key the function does not declare.
    detail_broken = detail.replace("'p_provider_id'", "'p_provider'")
    if detail_broken == detail:
        print("[FAIL] G: could not find the provider_public_profile_fields "
              "call to break")
        return 1
    ok &= expect_red("G: the detail screen sends an undeclared key",
                     {"user_provider_detail_screen.dart": detail_broken})

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
