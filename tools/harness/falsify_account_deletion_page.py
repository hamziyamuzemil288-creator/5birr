#!/usr/bin/env python3
"""Falsification for check_account_deletion_page_is_public_and_true().

A check that has never been seen red is not yet a check. The failure it is
built for is already public: Google Play rejected the listing because the
account-deletion page was not a page at all -- it was `delete-account.md` in a
private repository, describing an email address instead of the app's own
`request_account_deletion` flow, and nothing in the repository could tell the
difference between "a truthful page" and "a plausible page".

The check is DERIVED. The deleted/kept split comes from walking the foreign
keys in the migrations, the instruction labels come from the screen that calls
`request_account_deletion`, and the "did we say anything about this table?"
rule comes from the tables the app actually reads. So the mutations below are
aimed at the three ways it can be wrong:

  * it stops being PUBLIC (a form, a remote asset, an unreachable root);
  * it starts DESCRIBING A DIFFERENT APP (a label that is not on the screen);
  * it starts claiming something the SCHEMA DOES NOT DO -- in either
    direction, since over-claiming deletion is a lie to a policy reviewer and
    filing a genuinely split table under one bucket is a lie about half the
    accounts.

Case J is the one that matters most: it edits a MIGRATION rather than the
page, so a green run cannot be explained by the check having memorised today's
answer.

Mutations go through the real file contents in a throwaway copy of the repo.
The repository is never written to.
"""
from __future__ import annotations

import importlib.util
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools" / "harness" / "static_checks.py"

PAGE = "docs/delete-account.html"
INDEX = "docs/index.html"
SCREEN = "lib/features/settings/account_deletion_screen.dart"
MIG_DOCS = "supabase/migrations/0022a_extensions_enums_tables.sql"


def _load():
    """Import the checker with its ROOT pointed at a throwaway copy."""
    spec = importlib.util.spec_from_file_location("sc", CHECKER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _with_copy(mutate):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="deletion-page-falsify-"))
    try:
        dest = tmp / "repo"
        shutil.copytree(
            ROOT, dest, ignore=shutil.ignore_patterns(
                ".git", "build", ".dart_tool"))
        mutate(dest)
        mod = _load()
        mod.ROOT = dest
        mod.LIB = dest / "lib"
        mod.MIGRATIONS = dest / "supabase" / "migrations"
        mod.FUNCTIONS = dest / "supabase" / "functions"
        mod.DEPLOY_WORKFLOW = dest / ".github" / "workflows" / "deploy-supabase.yml"
        mod._READ_CACHE.clear()
        return mod.check_account_deletion_page_is_public_and_true(), mod
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def replace_in(rel: str, old: str, new: str):
    """A mutation that asserts its anchor exists, in the copy.

    A falsifier anchored on a string a later edit removed replaces nothing and
    passes while proving nothing -- that has happened in this repository before,
    and the whole point of these files is that they cannot.
    """
    def mutate(dest: pathlib.Path):
        p = dest / rel
        text = p.read_text(encoding="utf-8")
        if old not in text:
            raise AssertionError(
                f"falsifier anchor missing in {rel}: {old[:70]!r} -- the "
                f"mutation would land nowhere and the case would pass while "
                f"proving nothing")
        p.write_text(text.replace(old, new, 1), encoding="utf-8")
    return mutate


def drop_file(rel: str):
    def mutate(dest: pathlib.Path):
        p = dest / rel
        if not p.exists():
            raise AssertionError(f"falsifier anchor missing: {rel} does not exist")
        p.unlink()
    return mutate


def compose(*mutators):
    def mutate(dest: pathlib.Path):
        for m in mutators:
            m(dest)
    return mutate


_ORDERS_ROW = ('    <li data-table="orders">Orders: kept for accounting. The '
               'delivery address you typed stays on the order.</li>\n')

#: The whole one-line definition, so the mutation changes the ACTION rather
#: than adding a column beside it.
_USER_DOCUMENTS_DDL = (
    "CREATE TABLE IF NOT EXISTS user_documents (id uuid PRIMARY KEY DEFAULT "
    "uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id) ON "
    "DELETE CASCADE, document_type text NOT NULL, storage_path text NOT NULL, "
    "uploaded_at timestamptz NOT NULL DEFAULT now());")

CASES: list[tuple[str, str, object, bool]] = [
    (
        "A. baseline: the real repo passes",
        "or every case below is vacuous",
        lambda dest: None,
        True,
    ),
    (
        "B. the page is deleted",
        "this is the state Play rejected: a private repo, no page, and the "
        "only instructions living in a markdown file nobody can load",
        drop_file(PAGE),
        False,
    ),
    (
        "C. the page claims a KEPT table is deleted",
        "the failure mode that makes the page a lie to a policy reviewer. "
        "`orders` is detached by the ON DELETE SET NULL in 20260927000054, so "
        "the account's order history survives deletion",
        compose(
            replace_in(PAGE, _ORDERS_ROW, ""),
            replace_in(PAGE,
                       '  <h3>Deleted with the account</h3>',
                       '  <h3>Deleted with the account</h3>\n'
                       '  <ul id="deleted-tables-orders">\n'
                       '    <li data-table="orders">Everything about you.</li>\n'
                       '  </ul>'),
        ),
        False,
    ),
    (
        "D. the page says nothing about a table the app reads",
        "silence is the failure nobody catches by reading. `user_documents` "
        "holds identity documents; a page that simply omits it tells the reader "
        "nothing either way",
        replace_in(PAGE,
                   '    <li data-table="user_documents">Your uploaded identity, '
                   'business and driving documents.</li>\n',
                   ""),
        False,
    ),
    (
        "E. a genuinely SPLIT table is filed under one bucket",
        "`wallet_recharge_requests` cascades with the provider wallet and is "
        "nulled out of `approved_by`: a business account loses it, a customer "
        "account keeps it. Filed as plainly deleted it is false for every "
        "customer who has ever recharged",
        replace_in(PAGE,
                   '    <li data-table="wallet_recharge_requests">A wallet recharge '
                   'request is deleted if it belonged to the provider wallet you '
                   'ran, together with that wallet. If you were only ever a '
                   'customer, it is kept for accounting with the approving account '
                   'set to nothing.</li>\n',
                   ""),
        False,
    ),
    (
        "F. the page stops being PUBLIC: it grows a sign-in form",
        "Play's rejection names three causes -- down, geo-restricted, wrong URL. "
        "A login wall is the same defect wearing a different hat",
        replace_in(PAGE,
                   "<h2>How to request deletion in the app</h2>",
                   '<form method="post" action="/login">\n'
                   '  <input type="password" name="pw">\n'
                   '</form>\n'
                   "<h2>How to request deletion in the app</h2>"),
        False,
    ),
    (
        "G. the page starts loading a remote stylesheet",
        "self-contained is what makes it load everywhere. One remote asset is "
        "one more thing that can be blocked, and the reviewer sees a blank page",
        replace_in(PAGE,
                   "  :root {",
                   '  <link rel="stylesheet" '
                   'href="https://cdn.example.com/site.css">\n  :root {'),
        False,
    ),
    (
        "H. the site root stops linking to the page",
        "the page exists and is still unreachable from where a reviewer lands. "
        "This is the state the repo was in: correct content, no way to reach it",
        replace_in(INDEX, '<a href="delete-account.html">', '<a href="#">'),
        False,
    ),
    (
        "I. the instructions drift away from the app",
        "the page tells the user to type a label the screen does not have. The "
        "flow is unchanged in the database, so nothing else in the repository "
        "notices -- this is how a policy page starts describing a product that "
        "no longer exists",
        replace_in(PAGE,
                   '<span class="ui">Why are you leaving? (required)</span>',
                   '<span class="ui">Tell us why you are leaving</span>'),
        False,
    ),
    (
        "J. the SCHEMA stops deleting what the page promises",
        "the strongest case, because it edits a migration instead of the page: "
        "`user_documents` stops cascading. The page's deleted list is now false, "
        "and a check that had memorised today's answer would still be green",
        replace_in(MIG_DOCS, _USER_DOCUMENTS_DDL,
                   _USER_DOCUMENTS_DDL.replace("ON DELETE CASCADE",
                                               "ON DELETE SET NULL")),
        False,
    ),
    (
        "K. the page's whole deleted list is removed",
        "an unfalsifiable page: it would claim everything is kept and pass a "
        "reviewer who never ran the database",
        replace_in(PAGE, '  <ul id="deleted-tables">', '  <ul id="nothing">'),
        False,
    ),
    (
        "L. the page names a table that does not exist",
        "the appendix is the part a reviewer uses to check the summary, so a "
        "typo there is not cosmetic",
        replace_in(PAGE, 'data-table="user_documents"', 'data-table="user_document"'),
        False,
    ),
]


# ---------------------------------------------------------------------------
# The same falsifier also covers check_account_deletion_is_unblocked(), because
# the two share a derivation and a green answer from a shared helper is worth
# exactly as much as a green answer from a shared list.
# ---------------------------------------------------------------------------

MIG_0118 = "supabase/migrations/20260927000118_nothing_blocks_the_account_deletion.sql"

#: One tuple out of the VALUES list the migration detaches. Removing it is
#: "the business-side fix was lost" -- the exact regression the check exists for,
#: and the one that shipped as 0054's silent under-coverage.
#:
#: The tuples are PAIRS, not (table, column, parent) triples, and that is not
#: cosmetic: run 36870164815 died on 0118 with
#: `relation "auth.users" does not exist`, because a migration that names the
#: auth schema aborts on the push connection's search_path. The migration now
#: looks each key up by column and never names a parent. These anchors were
#: the triple form and went stale on that edit -- which the falsifier reported
#: as [BROKEN] rather than passing green, which is the only acceptable outcome
#: for a stale anchor.
_ORDERS_DETACH = "      ('orders',                'provider_id'),\n"

#: And one out of the account side, which is the half 0054 never did at all.
#:
#: The exact spacing matters and this file learned that the hard way. 0118
#: carries the same pair TWICE -- once in the block that detaches, once in the
#: block that verifies -- and the two are aligned differently. The first anchor
#: matched the VERIFICATION copy, so `replace_in` succeeded, the anchor
#: assertion passed, the case went green, and it had mutated a list that
#: changes nothing. A falsifier that lands in the wrong list is worse than one
#: with a missing anchor, because it reports a result.
_AUDIT_DETACH = "      ('audit_logs',                        'actor_id'),\n"
# The twentieth pair, and the one every earlier draft of this file missed.
# `target_user_id` is nullable with no ON DELETE action, which every migration
# before 0118 read as survivable. It is not, and it was invisible to the harness
# as well, because the harness collapsed a table's keys to the strongest action
# per parent and so saw the SET NULL `admin_id` and reported the pair clean.
_BROADCAST_DETACH = ("      ('admin_notification_broadcasts',"
                     "     'target_user_id'),\n")


def _unblocked(mutate):
    """Run the schema-side check over a mutated copy."""
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="deletion-schema-falsify-"))
    try:
        dest = tmp / "repo"
        shutil.copytree(
            ROOT, dest, ignore=shutil.ignore_patterns(
                ".git", "build", ".dart_tool"))
        mutate(dest)
        mod = _load()
        mod.ROOT = dest
        mod.LIB = dest / "lib"
        mod.MIGRATIONS = dest / "supabase" / "migrations"
        mod.FUNCTIONS = dest / "supabase" / "functions"
        mod.DEPLOY_WORKFLOW = dest / ".github" / "workflows" / "deploy-supabase.yml"
        mod._READ_CACHE.clear()
        return mod.check_account_deletion_is_unblocked(), mod
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


SCHEMA_CASES: list[tuple[str, str, object, bool]] = [
    (
        "M. baseline: no key blocks the account deletion",
        "or the cases below are vacuous",
        lambda dest: None,
        True,
    ),
    (
        "N. the business-side detach for orders.provider_id is lost",
        "the regression this migration exists to prevent. `orders` survives the "
        "delete, so a NOT NULL NO ACTION key onto provider_profiles raises 23503 "
        "for every provider who has ever taken an order -- and the request is "
        "already APPROVED by then",
        replace_in(MIG_0118, _ORDERS_DETACH, ""),
        False,
    ),
    (
        "O. the account-side detach for audit_logs.actor_id is lost",
        "the half 0054 never did. audit_logs has had a trigger on the mutation "
        "paths since 0035, so this one blocks the delete for essentially every "
        "real account",
        replace_in(MIG_0118, _AUDIT_DETACH, ""),
        False,
    ),
    (
        "P. the values-shaped detach list stops being readable",
        "the derivation reads the migration's own VALUES tuples rather than a "
        "transcribed copy. Drop the alias column list -- a tidy-up edit -- and "
        "the reader's anchor stops matching, zero tuples come back, and the "
        "derivation reverts to 'every key is NO ACTION'. It must report that it "
        "found a block it could not read rather than answering from a blind "
        "pattern",
        replace_in(MIG_0118, "AS v(tbl, col)", "AS v"),
        False,
    ),
    (
        "Q. the account-side detach for a BROADCAST's target is lost",
        "the twentieth pair, and the only one a per-parent reader cannot see. "
        "`admin_notification_broadcasts` has two keys to the account table: "
        "`admin_id`, detached here, and `target_user_id`, nullable with no "
        "action. Collapse the pair to the strongest action per parent and the "
        "table reads SET NULL and clean, while a delete still raises 23503 for "
        "every admin who has ever addressed a broadcast to one person. Dropping "
        "this line must therefore go red -- and if it does not, the blocker "
        "reader has gone back to answering per parent",
        replace_in(MIG_0118, _BROADCAST_DETACH, ""),
        False,
    ),
]


def main() -> int:
    failures = 0
    for name, why, mutate, expect_green in CASES:
        try:
            problems, _ = _with_copy(mutate)
        except AssertionError as exc:
            print(f"[BROKEN] {name}\n  falsifier itself failed: {exc}")
            failures += 1
            continue
        green = not problems
        if green == expect_green:
            print(f"[ok]     {name}")
        else:
            want = "green" if expect_green else "RED"
            print(f"[FAILED] {name}\n  expected {want}, got "
                  f"{'green' if green else 'RED'}\n  why: {why}")
            for p in problems[:4]:
                print(f"    - {p[:150]}")
            failures += 1

    for name, why, mutate, expect_green in SCHEMA_CASES:
        try:
            problems, _ = _unblocked(mutate)
        except AssertionError as exc:
            print(f"[BROKEN] {name}\n  falsifier itself failed: {exc}")
            failures += 1
            continue
        green = not problems
        if green == expect_green:
            print(f"[ok]     {name}")
        else:
            want = "green" if expect_green else "RED"
            print(f"[FAILED] {name}\n  expected {want}, got "
                  f"{'green' if green else 'RED'}\n  why: {why}")
            for p in problems[:4]:
                print(f"    - {p[:150]}")
            failures += 1

    total = len(CASES) + len(SCHEMA_CASES)
    print(f"\n{total - failures}/{total} falsification cases behaved as required")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
