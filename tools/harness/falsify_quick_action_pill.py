#!/usr/bin/env python3
"""Falsification for check_quick_action_shortcuts_are_wired.

This check was rewritten in this session (the user home screen gained a second
legitimate pill, and the old version demanded every pill be labelled "Book a
ride"). A rewritten check is the most dangerous kind: it can be narrowed until
it no longer catches anything, and still be green.

It also shipped with an assertion that had NEVER RUN -- the "gallery pill must
interpolate the provider id" check sat inside a branch an earlier `continue`
had already made unreachable. That is case D below, and it is the reason this
suite exists: a check that looks thorough on the page and reads nothing.

Cases:

  A. a role screen loses its QuickActionPill entirely
  B. the role's pill is relabelled (it still exists, it is now the wrong one)
  C. the role's pill is re-pointed at a different route
  D. the gallery pill stops interpolating the provider id  (the dead branch)
  E. a role screen hand-rolls a brand-green pill instead of using the widget
  F. a second pill is added with no label and no onTap (must stay RED)
  G. a SECOND, legitimately different pill exists (must stay GREEN)
  H. a constant-false guard disables a tile

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

USER = "lib/features/user/user_home_screen.dart"
SERVICE = "lib/features/provider/service_provider_dashboard.dart"
VEHICLE = "lib/features/vehicle/vehicle_provider_dashboard.dart"


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
        return sc.check_quick_action_shortcuts_are_wired()
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
    print("[FAIL] %s -> went red on legitimate input" % label)
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

    user = sc._read(sc.LIB / "features" / "user" / "user_home_screen.dart")
    service = sc._read(sc.LIB / "features" / "provider"
                       / "service_provider_dashboard.dart")

    # A. the user's pill is gone entirely.
    ok &= expect_red(
        "A: the user home screen loses its QuickActionPill",
        {USER: user.replace("QuickActionPill(", "PlainContainer(")})

    # B. the pill survives but is relabelled -- the exact regression this
    #    check exists for, and the one a file-level search cannot see.
    ok &= expect_red(
        "B: the 'Book a ride' pill is relabelled",
        {USER: user.replace("label: 'Book a ride'", "label: 'Get around'")})

    # C. the pill keeps its label but is re-pointed.
    ok &= expect_red(
        "C: the 'Book a ride' pill points somewhere else",
        {USER: user.replace("'/user/ride-request'", "'/user/cart'")})

    # D. THE DEAD BRANCH. The gallery pill pushes a literal path instead of
    #    interpolating the provider id. The route still matches, so a
    #    route-resolution check passes -- and the app would show whichever
    #    provider happened to be first. This assertion had never executed
    #    before this rewrite.
    ok &= expect_red(
        "D: the gallery pill stops interpolating the provider id",
        {SERVICE: service.replace(
            "'/provider/gallery/${_providerProfile!['id']}'",
            "'/provider/gallery/first'")})

    # E. a role screen hand-rolls the pill instead of using the widget.
    ok &= expect_red(
        "E: a role screen hand-rolls a brand-green pill",
        {VEHICLE: sc._read(sc.LIB / "features" / "vehicle"
                           / "vehicle_provider_dashboard.dart").replace(
            "QuickActionPill(", "Container(") + """
  Widget _handRolled() => Material(
        color: AppTheme.primaryGreen,
        borderRadius: BorderRadius.circular(20),
        child: const SizedBox(height: 40),
      );
"""})

    # F. a second pill with neither a label nor a tap target is dead UI.
    ok &= expect_red(
        "F: an unlabelled, untappable pill is added",
        {USER: user.replace("class _UserHomeScreenState",
                            "  Widget _deadPill() => const QuickActionPill("
                            "  icon: Icons.star, label: '', "
                            "onTap: _noop),\n\n"
                            "class _UserHomeScreenState")})

    # G. a SECOND, legitimately different pill must stay green. This is the
    #    false positive the rewrite exists to remove: the gallery entry is a
    #    real second shortcut, not a defect.
    ok &= expect_green(
        "G: a second legitimate pill (the gallery entry) is present",
        {USER: user})

    # H. a constant-false guard silently disables a tile.
    ok &= expect_red(
        "H: a constant-false guard disables a shortcut",
        {USER: user.replace("Widget _gallerySection() {",
                            "Widget _gallerySection() {\n    if (false) return "
                            "const SizedBox.shrink();")})

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
