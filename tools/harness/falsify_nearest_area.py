#!/usr/bin/env python3
"""Falsification for check_nearest_area_is_wired.

A check that has never been seen red is not yet a check. Each case below
re-introduces ONE of the three original defects and asserts the check catches
it. Nothing here writes to the repo: `static_checks._read` is overridden with
in-memory patched copies, so the real files are only ever read.

The three defects, each of which alone reproduces "the where button shows the
nearest city and big institution but never the nearest area":

  A. ReverseGeocode has no `area` field to put a kebele name in.
  B. reverseGeocode() stops reading the `suburb` / `neighbourhood` keys.
  C. The ride screen stops calling reverseGeocode on the GPS path.
  D. nearbyAreas() -- the only source that can return a kebele -- is gone.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

GEO = "lib/core/services/geocoding_service.dart"
RIDE = "lib/features/user/user_ride_request_screen.dart"
MAP = "lib/features/user/live_map_screen.dart"

_real_read = sc._read


def with_patches(patches: dict[str, str]) -> list[str]:
    """Run the check with the named files replaced by patched text."""
    def _read(path: Path) -> str:
        try:
            rel = str(path).replace("\\", "/")
            for suffix, text in patches.items():
                if rel.endswith(suffix):
                    return text
        except Exception:
            pass
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_nearest_area_is_wired()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems:
            print("         - " + p)
        return True
    print("[FAIL] %s -> stayed GREEN. The check does not detect this." % label)
    return False


def main() -> int:
    ok = True

    # Baseline: the real tree must be green, or every case below is noise.
    base = with_patches({})
    if base:
        print("[FAIL] the real sources are already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] real sources are green")

    geo = sc._read(sc.LIB / "core" / "services" / "geocoding_service.dart")
    ride = sc._read(sc.LIB / "features" / "user"
                    / "user_ride_request_screen.dart")

    # A. the area field disappears from the result object
    ok &= expect_red(
        "A: ReverseGeocode loses its `area` field",
        {GEO: geo.replace("  final String area;", "  final String unusedAreaField;")},
    )

    # B. the small-area address keys stop being read
    ok &= expect_red(
        "B: reverseGeocode() stops reading `suburb`",
        {GEO: geo.replace("'suburb',", "'discarded',")},
    )

    # C. the GPS pickup path stops resolving anything
    ok &= expect_red(
        "C: the ride screen stops calling reverseGeocode",
        {RIDE: ride.replace("reverseGeocode", "someOtherLookup")},
    )

    # D. the only small-area source is removed
    ok &= expect_red(
        "D: nearbyAreas() is gone",
        {GEO: geo.replace("nearbyAreas(", "nearbyBigPlaces(")},
    )

    if not ok:
        print("\nFALSIFICATION FAILED")
        return 1

    # And the real tree must still be green after all that patching.
    if with_patches({}):
        print("\n[FAIL] the real sources went red")
        return 1
    print("\n[ ok ] real sources still green")
    print("FALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
