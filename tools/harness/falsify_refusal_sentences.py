#!/usr/bin/env python3
"""Falsification for check_server_refusal_codes_reach_the_user.

The bug: Postgres refusals reach the client as `RAISE EXCEPTION 'CODE'`, and
PostgREST returns those as a 400 whose body is the raw code. The authorisation
branch of `friendlyError` only matched 403-shaped errors, so a staff member who
acted outside their assigned city got "Something went wrong. Please try
again." — indistinguishable from a crash, and silent about the fact that a
scope rule was the reason.

This check was written by adding one code and it immediately found two more
with no sentence at all (ADMIN_ONLY, AUTH_REQUIRED). So the cases below are the
three real codes, not a general shape.

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

ERR = "lib/core/utils/friendly_error.dart"


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
        return sc.check_server_refusal_codes_reach_the_user()
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

    err = sc._read(sc.LIB / "core" / "utils" / "friendly_error.dart")

    # A. the city-scope refusal loses its sentence again.
    ok &= expect_red(
        "A: INSUFFICIENT_PERMISSION is no longer recognised",
        {ERR: err.replace("    'insufficient_permission',\n", "")})

    # B. the admin-only gates.
    ok &= expect_red(
        "B: ADMIN_ONLY is no longer recognised",
        {ERR: err.replace("    'admin_only',\n", "")})

    # C. the signed-out refusal.
    ok &= expect_red(
        "C: AUTH_REQUIRED is no longer recognised",
        {ERR: err.replace("    'auth_required',\n", "")})

    # D. THE SUBTLE ONE. Keeping the code inside a COMMENT is enough to satisfy
    #    a naive presence test, and the whole file is full of prose about these
    #    refusals. The check strips comments first, so this must still be red.
    ok &= expect_red(
        "D: the code survives only in a comment",
        {ERR: err.replace("    'insufficient_permission',\n", "")
                   .replace("    'admin_only',\n", "")
                   .replace("    'auth_required',\n", "")
                   + "\n// 'insufficient_permission' 'admin_only' 'auth_required'\n"})

    # E. a code mentioned only in a doc comment above the function.
    ok &= expect_red(
        "E: the codes survive only in the file's header doc comment",
        {ERR: err.replace("    'insufficient_permission',\n", "")
                   .replace("    'admin_only',\n", "")
                   .replace("    'auth_required',\n", "")})

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
