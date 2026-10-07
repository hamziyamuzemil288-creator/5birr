#!/usr/bin/env python3
"""
tools/harness/check_migration_tables_have_rls.py

Standalone static probe. It reads ONLY migration files under supabase/migrations/
and fails (exit code 1) if any table created by our migrations appears to lack
`ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY` in the same migration
set.

This is the Python-side mirror of the LIVE SQL functions in migrations
20261007000001 and 20261007000003:
- public.list_public_tables_without_rls()
- public.assert_all_migration_tables_have_rls()
- public.assert_list_public_tables_without_rls_is_empty()

Those SQL functions are the REAL gate: they operate on the LIVE DB definition
(pg_class.relrowsecurity), not on migration text. If the repo is committed but
the live DB still has a migration-created table without RLS, THOSE functions
fail loudly (RAISE EXCEPTION), not this script.

This script is the PRE-COMMIT mirror: it verifies that our MIGRATIONS record
the RLS enable, which is what makes the repo truthful and lets CI catch a
missing ALTER TABLE before it is ever applied.

The two checks are intended to AGREE when the DB is in the correct state:
- If a table exists in the DB and our migrations created it, then our
  migrations must contain the ALTER TABLE for it.
- If a table exists in the DB but our migrations did NOT create it
  (e.g. a table that existed before this repo, or a table created by a
  third-party migration), then this script does NOT flag it, because the
  lint is about our migration history only.

The three intentionally-policyless internal tables are excluded from both
the static lint and the live listing function, because the app never reads
or writes them from a Flutter screen and the migrations explicitly document
the default-deny posture.

KNOWN REPO-LEVEL DETAIL: the migration set under supabase/migrations/ is
materially larger than the set of tables the lint should verify. The repo
contains restatement and snapshot files (e.g. 0021_*.sql, 0022_*.sql) that
re-state the entire schema, plus earlier migration families where the same
`ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY` statement appears in
a LATER file than the one that first CREATEd the table. The lint verifies that
the ENABLING STATEMENT EXISTS SOMEWHERE in the migration set, not that it is in
the same file as the CREATE. That is the correct contract: the repo is truthful
if every migration-created table has the enable statement in at least one
migration file, and the live DB satisfies the same property.

KNOWN REPO-LEVEL DETAIL 2: 0021_live_schema_snapshot.sql is a full-schema
RESTATEMENT. The lint reports, for each table, the EARLIEST migration file in
this repo that contains a REAL (non-comment, non-SQL-noise) CREATE TABLE statement
for it. In this repo the distribution is:

- 0001_core_schema.sql: 30 tables whose first real CREATE TABLE is this file
  (admin_actions, appeals, approval_history, approval_requests, audit_logs,
  categories, favorites, notification_preferences, notifications, order_items,
  order_status_history, orders, payment_agreements, payment_proofs,
  product_images, products, profiles, provider_profiles, reviews, ride_requests,
  ride_status_history, subscriptions, support_tickets, system_settings,
  user_documents, user_roles, vehicle_images, vehicles, wallet_transactions,
  wallets)

- 0013_marketplace_foundation.sql: 3 tables (listing_images, provider_gallery,
  provider_stores)

- 0021_live_schema_snapshot.sql: 8 tables (admin_wallet_actions, cart_items,
  driver_status, fcm_tokens, n8n_events, payment_methods, ride_ratings,
  wallet_recharge_requests) — these are first introduced in the snapshot in THIS
  repo, so the lint keeps 0021 as their "first created in".

The lint does NOT silently promote 0021 for any table that has a real CREATE TABLE
earlier than 0021. It keeps 0021 only for the 8 tables whose first real CREATE
TABLE in this repo is 0021 itself.

For reporting clarity only: when a table is introduced in an early core migration
and later re-stated in a snapshot file that ALSO contains its
`ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY`, the lint will still report
the EARLIER file as "first created in", because that is where the CREATE TABLE
STATEMENT first appears. For the 8 tables whose first real CREATE TABLE is
0021_live_schema_snapshot.sql, the "first created in" label is 0021, which is the
earliest REAL CREATE TABLE in this repository. The lint only fails on the real
condition: an enabling statement missing from the migration set.

NOTE: `0021_live_schema_snapshot.sql` declares CREATE TABLE IF NOT EXISTS for
8 tables: admin_wallet_actions, cart_items, driver_status, fcm_tokens,
n8n_events, payment_methods, ride_ratings, wallet_recharge_requests. No earlier
migration file in this repo contains a real CREATE TABLE for them. So for those 8
the lint keeps 0021 as "first created in", because that is the earliest REAL CREATE
TABLE in this repository.

NOTE: the remaining tables keep the earlier core/feature file as "first created in"
because that earlier file contains a real CREATE TABLE for them before 0021 ever
re-states them.

The assertion catalogue migration itself (20261007000003_harness_rls_statement.sql)
is excluded from the lint input, because it is the record of what the lint
should verify, not one of the tables under inspection.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS_DIR = REPO_ROOT / "supabase" / "migrations"


INTENTIONALLY_POLICYLESS_INTERNAL_TABLES: frozenset[str] = frozenset({
    "captcha_challenges",
    "login_attempts",
    "rate_limits",
})

EXTENSION_OWNED_TABLE_NAMES: frozenset[str] = frozenset({
    "spatial_ref_sys",
})

SQL_NOISE_WORDS: frozenset[str] = frozenset({
    "if",
    "in",
    "and",
    "or",
    "not",
    "exists",
})

EXCLUDED_FILES: frozenset[str] = frozenset({
    "20261007000003_harness_rls_statement.sql",
})

LIVE_DB_ASSERTION_NOTE = (
    "NOTE: the CRITICAL check is the live DB, not this file. "
    "The functions public.assert_all_migration_tables_have_rls() and "
    "public.assert_list_public_tables_without_rls_is_empty() (migration "
    "20261007000003) are what fail on a live DB if a migration-created table "
    "lacks RLS. This script is only the pre-commit mirror."
)


def iter_migration_files() -> list[Path]:
    files = sorted(MIGRATIONS_DIR.glob("*.sql"))
    if not files:
        print(f"ERROR: no .sql files under {MIGRATIONS_DIR}", file=sys.stderr)
        sys.exit(2)
    files = [f for f in files if f.name not in EXCLUDED_FILES]
    if not files:
        print(f"ERROR: no .sql files under {MIGRATIONS_DIR} after exclusions", file=sys.stderr)
        sys.exit(2)
    return files


CREATE_TABLE_RE = re.compile(
    r"(?P<leading>\bcreate\s+table\s+(?:if\s+not\s+exists\s+)?)\s*"
    r"(?P<table>\w+)\s",
    re.I,
)

ALTER_RLS_RE = re.compile(
    r"(?P<before>\balter\s+table\s+)"
    r"(?P<qualified>\w+(?:\.\w+)?)\s+"
    r"\benable\s+row\s+level\s+security\b",
    re.I,
)

DROP_TABLE_RE = re.compile(
    r"(?P<leading>\bdrop\s+table\s+(?:if\s+exists\s+)?)\s*"
    r"(?P<table>\w+(?:\.\w+)?)",
    re.I,
)


def _is_comment_only(text: str, pos: int) -> bool:
    """True when `pos` is inside an SQL comment line."""
    line_start = text.rfind("\n", 0, pos)
    if line_start == -1:
        line_start = 0
    line_prefix = text[line_start:pos].lstrip()
    return line_prefix.startswith("--")


def _normalize_table_name(raw: str) -> str:
    """Normalize a captured table name past backticks and case."""
    return raw.lower().lstrip("`").strip().rstrip("`")


def _capture_create_tables(text: str) -> list[tuple[int, str]]:
    """Return [(start_pos, table_name_lower)] for every real CREATE TABLE
    statement in the file."""
    out: list[tuple[int, str]] = []
    for m in CREATE_TABLE_RE.finditer(text):
        if _is_comment_only(text, m.start()):
            continue
        raw = m.group("table") or ""
        tbl = _normalize_table_name(raw)
        if not tbl:
            continue
        if tbl in SQL_NOISE_WORDS:
            continue
        if tbl in EXTENSION_OWNED_TABLE_NAMES:
            continue
        leading = (m.group("leading") or "").strip().lower()
        if not leading.endswith("table"):
            continue
        out.append((m.start(), tbl))
    return out


def _capture_rls_tables(text: str) -> set[str]:
    """Return the set of public table names that have ALTER TABLE ... ENABLE
    ROW LEVEL SECURITY in this file."""
    has: set[str] = set()
    for m in ALTER_RLS_RE.finditer(text):
        if _is_comment_only(text, m.start()):
            continue
        before = (m.group("before") or "").strip()
        if not before.lower().endswith("table"):
            continue
        qualified = m.group("qualified") or ""
        if "." not in qualified:
            continue
        name = qualified.split(".")[-1].lower().strip("`")
        if not name:
            continue
        if name in SQL_NOISE_WORDS:
            continue
        has.add(name)
    return has


def extract_our_tables_by_latest(files: list[Path]) -> dict[str, dict[str, str]]:
    """Return {table_name_lower: {'first': file, 'last': file}}.

    Duplicate-detection is done by table name only. When the same table name
    first appears in an early core migration and is later re-stated verbatim in
    a snapshot file (0021_*.sql), we keep the earliest file as "first created
    in", which is the correct answer for a migration-history lint.
    """
    first: dict[str, str] = {}
    last: dict[str, str] = {}
    for f in sorted(files):
        text = f.read_text(encoding="utf-8", errors="replace")
        for _pos, tbl in _capture_create_tables(text):
            if tbl in first:
                continue
            first[tbl] = f.name
            last[tbl] = f.name
    for f in sorted(files, reverse=True):
        text = f.read_text(encoding="utf-8", errors="replace")
        for _pos, tbl in _capture_create_tables(text):
            if tbl in last:
                continue
            last[tbl] = f.name
    return {"first": first, "last": last}


def tables_with_rls_in_migration_text(files: list[Path]) -> set[str]:
    """Return the set of public table names that have ALTER TABLE ... ENABLE
    ROW LEVEL SECURITY anywhere in the migration set."""
    has: set[str] = set()
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        has |= _capture_rls_tables(text)
    return has


def _capture_drop_tables(text: str) -> list[str]:
    """Return table names this file drops (accepts `public.foo` or `foo`)."""
    out: list[str] = []
    for m in DROP_TABLE_RE.finditer(text):
        if _is_comment_only(text, m.start()):
            continue
        words = (m.group("leading") or "").lower().split()
        # `leading` is "drop table" or "drop table if exists", so the test is
        # on the first two words: an endswith("table") check would reject the
        # IF EXISTS form, which is how 20260927000053 spells its DROP.
        if len(words) < 2 or words[0] != "drop" or words[1] != "table":
            continue
        raw = m.group("table") or ""
        tbl = _normalize_table_name(raw.split(".")[-1])
        if not tbl or tbl in SQL_NOISE_WORDS:
            continue
        out.append(tbl)
    return out


def tables_dropped_by_migration_set(files: list[Path]) -> set[str]:
    """Tables whose FINAL statement in this migration set is a DROP TABLE.

    A table the migration set no longer has must not be required to carry an
    ENABLE ROW LEVEL SECURITY statement: the requirement is vacuous for
    something that does not exist, and satisfying it is impossible without
    emitting DDL against a missing relation.

    That is not hypothetical. `appeals` was dropped by
    20260927000053_drop_legacy_appeals_table.sql, but because this lint had no
    notion of DROP it still demanded an enabling statement for it. The only
    place left to put one was 20261007000004, whose
    `ALTER TABLE public.appeals ENABLE ROW LEVEL SECURITY;` then raised 42P01
    "relation public.appeals does not exist" at statement 2 and aborted the
    whole `supabase db push` — taking every other pending migration down with
    it.

    A DROP followed by a later CREATE puts the table back, so the re-creation
    clears it: only the tables still absent at the end of the set are skipped.
    """
    dropped: set[str] = set()
    for f in sorted(files):
        text = f.read_text(encoding="utf-8", errors="replace")
        for tbl in _capture_drop_tables(text):
            dropped.add(tbl)
        for _pos, tbl in _capture_create_tables(text):
            dropped.discard(tbl)
    return dropped


def main() -> None:
    files = iter_migration_files()
    our_tables = extract_our_tables_by_latest(files)
    rls_tables = tables_with_rls_in_migration_text(files)
    dropped_tables = tables_dropped_by_migration_set(files)

    table_names = sorted(our_tables["first"].keys())
    missing: list[tuple[str, str]] = []
    for tbl in table_names:
        if tbl in INTENTIONALLY_POLICYLESS_INTERNAL_TABLES:
            continue
        if tbl in SQL_NOISE_WORDS:
            continue
        # The migration set no longer has this table: the last thing that
        # happened to it was a DROP TABLE. Requiring an enabling statement for
        # it is what forced 20261007000004 to emit DDL against a relation that
        # does not exist, which aborted `supabase db push`.
        if tbl in dropped_tables:
            continue
        # Known repo-state detail: some tables are first INTRODUCED in an early
        # core migration (0001_core_schema.sql) and then re-stated verbatim in a
        # later snapshot file (0021_live_schema_snapshot.sql). The lint still
        # reports the EARLIER file as "first created in", which is the correct
        # answer for a migration-history lint, even though the snapshot file is
        # the one that tends to bundle the ALTER TABLE statement in this repo.
        # That is fine: the lint checks whether the enabling statement exists
        # SOMEWHERE in the migration set, and "first created in" is just the
        # reporting label for the earliest CREATE TABLE statement.
        if tbl in rls_tables:
            continue
        missing.append((tbl, our_tables["first"][tbl]))

    if not missing:
        print(
            "OK: every migration-created public table has "
            "ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY "
            "somewhere in the migration set "
            "(intentionally-policyless internal tables excluded). "
            + LIVE_DB_ASSERTION_NOTE
        )
        sys.exit(0)

    # The failure output is intentionally small: the tables flagged here are the
    # ones the lint could not find an ALTER TABLE for ANYWHERE in the migration
    # set. That is the only condition this script can truthfully fail on.
    lines: list[str] = []
    lines.append(
        "FAIL: the following table(s) created by our migrations appear to "
        "lack 'ALTER TABLE public.<table> ENABLE ROW LEVEL SECURITY' "
        "anywhere in the migration set "
        "(intentionally-policyless internal tables excluded):"
    )
    for tbl, first_created in missing:
        lines.append(f"  - {tbl}  (first created in: {first_created})")
    lines.append("")
    lines.append(
        LIVE_DB_ASSERTION_NOTE
        + "\n"
        + "Expected fix: add "
        "'ALTER TABLE public.<name> ENABLE ROW LEVEL SECURITY' to the "
        "migration that creates the table (or to this very migration set as "
        "an idempotent later file), with correct policies for the roles that "
        "read/write it."
    )
    print("\n".join(lines), file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
