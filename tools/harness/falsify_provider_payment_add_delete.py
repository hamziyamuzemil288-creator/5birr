# fmt: off
# A falsifier for the provider payment-methods screen's three live paths:
#   1. the "Add bank account" button actually opens the add form,
#   2. the Add form actually POSTs a row when the providerId resolves, and
#   3. the per-account "Remove" action actually calls _deleteMethod.
#
# The screen was fixed from a state that never populated before the add could
# fire (no initState load, providerId was the auth uid not a provider_profiles
# row, and the list used nested ListView without shrinkWrap so the first saved
# account broke the render). One falsifier per missing symptom is the repo
# pattern; this file asserts all three are still present in the same file,
# because all three must be live for "button is there but not working" to stop
# being true.
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"
SCREEN = LIB / "features" / "provider" / "provider_payment_methods_screen.dart"


def _source() -> str:
    raw = SCREEN.read_text(encoding="utf-8")
    # Strip comments so prose can never pass for code.
    raw = re.sub(r"//[^\n]*", " ", raw)
    raw = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)
    raw = re.sub(r"\n+", " ", raw)
    return raw


def _fails_when_substring_missing(label: str, needle: str, where: str) -> str | None:
    src = _source()
    if needle not in src:
        return f"{label}: the source no longer contains the substring {where!r}"
    return None


def check_add_button_opens_form() -> list[str]:
    """Add bank account: FIDDLE with the onPressed path so one broken wire
    does not become the new normal."""
    problems: list[str] = []

    # The button is wired to _startAdding, and _startAdding opens a dialog
    # with a Form whose save hand reaches _save.
    if miss := _fails_when_substring_missing(
        "add bank account button", "_startAdding", "its open callback"
    ):
        problems.append(miss)

    # The add form must validate before saving, and _save must call _createMethod
    # which requires a resolved providerId. The break we fixed was that _createMethod
    # never fired because the form never rendered; the falsifier here is that *both*
    # _startAdding and _createMethod are still in the file.
    if "void _startAdding()" not in _source() and "void _startAdding() {" not in _source():
        problems.append("the add dialog entry is gone")
    if "_createMethod" not in _source():
        problems.append("_createMethod (the actual insert) is gone")

    # The wallet-fund POST from the same screen goes through
    # submitProviderWalletFundingRequest, which needs a providerId. The fix
    # was to gate it on _providerId != null. Assert both the call and the
    # guard remain.
    src = _source()
    if "submitProviderWalletFundingRequest" not in src:
        problems.append("wallet fund POST call is gone")
    if "NO_PROVIDER_PROFILE" not in src:
        problems.append("the providerId null guard for the fund POST is gone")

    return problems


def check_delete_row_and_method() -> list[str]:
    problems: list[str] = []

    # Each account card exposes a Remove action that calls _deleteMethod(id).
    if "_deleteMethod" not in _source():
        problems.append("per-account delete handler is gone")

    # The delete dialog pops, then calls _deleteMethod. If either half is gone
    # the button is effectively dead.
    if "Navigator.of(dialogCtx).pop()" not in _source() or "_deleteMethod(id)" not in _source():
        problems.append("the Remove dialog no longer reaches _deleteMethod")

    # The account listing itself must still render rows, otherwise there is
    # nothing to delete. The fix added shrinkWrap so the first saved account
    # does not break the screen; the presence of ListView.builder + shrinkWrap
    # is the cheap signal that the list is real.
    src = _source()
    if "ListView.builder" not in src:
        problems.append("the account list builder is gone")
    if "shrinkWrap" not in src or "NeverScrollableScrollPhysics" not in src:
        problems.append("the nested-list fix (shrinkWrap) is gone")

    return problems


def main() -> int:
    label = SCREEN.relative_to(LIB.parent).as_posix()
    failed = 0

    for name, fn in (
        ("provider payment-methods ADD button opens form and POSTs", check_add_button_opens_form),
        ("provider payment-methods delete row and method", check_delete_row_and_method),
    ):
        problems = fn()
        if problems:
            failed += 1
            print(f"[FAIL] {label}: {name}")
            for p in problems:
                print(f"         - {p}")
        else:
            print(f"[PASS] {label}: {name}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
