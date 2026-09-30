#!/usr/bin/env python3
"""Falsification for check_admin_sidebar_cards_are_guarded.

A check that has never been seen red is not yet a check. This proves the
sidebar-guard check actually goes red on the exact bug it was written for --
the dangling second `_menuCard` that Dart silently promotes to an
unconditional list element -- and stays green once each card carries its own
`if`. Neither run edits the real admin_dashboard.dart.

Every check in static_checks reads file contents through the single `_read`
helper, so overriding that one function runs the real check code against a
patched string.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

TARGET = "lib/features/admin/admin_dashboard.dart"

# The exact shape that shipped: ONE `if`, two cards, the second a dangling
# list element. In `[if (c) a, b]` Dart gives the `if` only `a`.
BROKEN = """class _Broken {
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (isAdmin)
          _menuCard(Icons.a, 'System Settings', null, () {}),
          _menuCard(Icons.b, 'Fees & Pricing', null, () {}),
      ],
    );
  }
"""

# The same list with the fix applied: each card owns its guard.
FIXED = """class _Fixed {
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (isAdmin)
          _menuCard(Icons.a, 'System Settings', null, () {}),
        if (isAdmin)
          _menuCard(Icons.b, 'Fees & Pricing', null, () {}),
      ],
    );
  }
"""

_real_read = sc._read


def with_dashboard(text: str | None):
    """Run the check with admin_dashboard.dart reading as `text`."""
    def _read(path: Path) -> str:
        try:
            if str(path).replace("\\", "/").endswith(TARGET) and text is not None:
                return text
        except Exception:
            pass
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_admin_sidebar_cards_are_guarded()
    finally:
        sc._read = _real_read


def main() -> int:
    problems = with_dashboard(BROKEN)
    if not problems:
        print("[FAIL] the check stayed GREEN on a dangling, unguarded "
              "_menuCard -- it does not detect the bug it was written for")
        return 1
    print("[ ok ] dangling card detected:")
    for p in problems:
        print("         - " + p)

    if with_dashboard(FIXED):
        print("[FAIL] the check stayed RED on the FIXED source -- it is a "
              "false positive, not a guard")
        return 1
    print("[ ok ] correctly green once each card has its own `if`")

    if with_dashboard(None):
        print("[FAIL] the real admin_dashboard.dart is still red")
        return 1
    print("[ ok ] the real admin_dashboard.dart is green")
    print("\nFALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
