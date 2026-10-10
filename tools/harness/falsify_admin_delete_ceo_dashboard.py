# fmt: off
# A falsifier for the admin-sidebar delete reachability story:
#   - the CEO dashboard's "Danger zone / Delete an account" card navigates to
#     /admin/accounts and is guarded by canOpenCeoOnly,
#   - the admin dashboard's "All Users & Providers" card is similarly guarded,
#   - the account-directory screen's delete button is rendered per row and calls
#     ceo_delete_user_account through the shared cascade.
#
# The defect we reconciled was that the client gate `isCeo` missed the shape
# where the database grants CEO authority through a staff row flagged is_ceo
# (and also the server-side is_ceo_authority answer). The screens and the RPCs
# all check is_ceo_authority; the client only decided whether to show the door.
# This falsifier asserts the door is still shown and still wired, and that it is
# still gated (so a non-CEO does not get a delete button they cannot act on).
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"
CEO = LIB / "features" / "ceo" / "ceo_dashboard.dart"
ADMIN = LIB / "features" / "admin" / "admin_dashboard.dart"
DIR = LIB / "features" / "admin" / "admin_account_directory_screen.dart"


def _source(path: Path) -> str:
    raw = path.read_text(encoding="utf-8")
    raw = re.sub(r"//[^\n]*", " ", raw)
    raw = re.sub(r"/\*.*?\*/", " ", raw, flags=re.S)
    raw = re.sub(r"\n+", " ", raw)
    return raw


def _odds(label: str, needle: str, where: str, src: str) -> str | None:
    if needle not in src:
        return f"{label}: the source no longer contains what {where!r} needs"
    return None


def check_ceo_dashboard_delete_card() -> list[str]:
    problems: list[str] = []
    src = _source(CEO)

    # The danger-zone card is still present and still navigates to /admin/accounts.
    if _odds("CEO delete card", "Delete an account", "its title", src):
        problems.append("CEO danger-zone delete card is gone")
    if _odds("CEO delete card nav", "/admin/accounts", "the card's navigation", src):
        problems.append("the CEO delete card no longer navigates to /admin/accounts")
    # The card must still be gated by canOpenCeoOnly.
    if "canOpenCeoOnly" not in src:
        problems.append("the CEO dashboard no longer gates the delete card on canOpenCeoOnly")
    # The card must not be unconditional: before the fix a non-CEO could see it.
    if "if (!auth.canOpenCeoOnly)" not in src and "if (!auth.canOpenCeoOnly)\n" not in src:
        problems.append("the CEO dashboard no longer refuses non-CEOs")

    return problems


def check_admin_dashboard_delete_card() -> list[str]:
    problems: list[str] = []
    src = _source(ADMIN)

    # The admin sidebar "All Users & Providers" card is still present and
    # still navigates to /admin/accounts.
    if _odds("admin delete card", "All Users & Providers", "the card label", src):
        problems.append("the admin sidebar delete card is gone")
    if _odds("admin delete card nav", "/admin/accounts", "the card's navigation", src):
        problems.append("the admin sidebar delete card no longer navigates to /admin/accounts")
    # Still gated by canOpenCeoOnly.
    if "canOpenCeoOnly" not in src:
        problems.append("the admin dashboard no longer gates the delete card on canOpenCeoOnly")

    return problems


def check_account_directory_delete_button() -> list[str]:
    problems: list[str] = []

    # The directory screen still renders per-row delete buttons and routes the
    # row through ceo_delete_user_account with a reason.
    src = _source(DIR)
    if _odds("directory delete flow", "ceo_delete_user_account", "the RPC it calls", src):
        problems.append("the directory no longer calls ceo_delete_user_account")
    if _odds("directory reason gate", "p_reason", "the reason parameter", src):
        problems.append("the directory delete RPC no longer sends a reason")
    # A typed confirm dialog with the DELETE word is still required before firing.
    if "DELETE" not in src:
        problems.append("the typed confirmation word for deletion is gone")
    # The row still shows the delete icon for non-self, non-CEO rows.
    if "IconButton" not in src or "person_remove_outlined" not in src:
        problems.append("the per-row delete button in the directory is gone")

    # The directory still re-loads after a deletion so the list stays honest.
    if "_load()" not in src:
        problems.append("the directory no longer refreshes after a deletion")

    return problems


def main() -> int:
    failed = 0
    for name, fn in (
        ("CEO dashboard delete card", check_ceo_dashboard_delete_card),
        ("admin dashboard delete card", check_admin_dashboard_delete_card),
        ("account-directory delete button", check_account_directory_delete_button),
    ):
        problems = fn()
        if problems:
            failed += 1
            print(f"[FAIL] admin delete reachability: {name}")
            for p in problems:
                print(f"         - {p}")
        else:
            print(f"[PASS] admin delete reachability: {name}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
