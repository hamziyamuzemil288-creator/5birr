#!/usr/bin/env python3
"""Does every `ON CONFLICT ... DO UPDATE SET col =` name a real column?

WHY THIS CHECK EXISTS
---------------------
It was written after running `admin_save_category_fee()` against a real
PostgreSQL and watching every single call die with:

    42703: column "booking_base_fare" of relation "category_fee_settings"
           does not exist

0107 renamed the column `booking_base_fare` -> `booking_base_fee` when it
renamed the matching argument `p_booking_base_fare` -> `p_booking_base_fee`.
The INSERT column list was updated. Every resolver was updated. The
`ON CONFLICT ... DO UPDATE SET` list was not, and PostgreSQL analyses that
clause BEFORE it executes -- so the statement could never run at all. The
per-category fee editor had therefore never once saved a row, since the day it
was written.

WHAT MADE IT INVISIBLE
----------------------
Every check that existed answered a DIFFERENT question and answered it
correctly:

  * "does admin_save_category_fee exist with the right arity and parameter
    names?" -- yes, it always did. Reachability is not correctness.
  * "does the Dart send any undeclared parameter?" -- no. The mistake is in the
    function's BODY, which no client-side check can see.
  * "is every fee field group both rendered and sent?" -- yes.
  * "can the rows be written?" -- nobody asked. Nothing in the repository
    executed an INSERT.

So the class of bug is: a statement that is correctly NAMED, correctly GRANTED,
correctly CALLED, and still cannot run. Naming and reaching a function say
nothing about whether it works.

WHAT IT DOES
------------
Collects every table's columns from every `CREATE TABLE` and every
`ALTER TABLE ... ADD COLUMN`, then checks each `ON CONFLICT ... DO UPDATE SET`
target against the columns of the table being updated. Reports a mismatch.

Deliberately one-sided: it only reports a column it positively knows is wrong.
Silence means "no mismatch found", never "no mismatch exists".

The ALTER TABLE handling is the part that had to be right before this check
could be trusted. An earlier version parsed only the first ADD COLUMN of a
multi-clause ALTER TABLE and reported three false findings -- profiles.street_road
and two staff_task_completions columns, all of which a later migration really
does add. A scanner that cries wolf gets deleted on first sight, taking the one
true finding with it.
"""
from __future__ import annotations

import re
from pathlib import Path

MIGRATIONS = Path(__file__).resolve().parents[2] / "supabase" / "migrations"

CREATE_TABLE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)\s*\((.*?)\n\);",
    re.IGNORECASE | re.DOTALL,
)
# `col type` at the start of a table-body line.
COLUMN = re.compile(r"^\s{2}([a-z_][a-z0-9_]*)\s+[a-z]", re.IGNORECASE | re.MULTILINE)

# Matched per ALTER TABLE STATEMENT, not per file: one statement can add four
# columns separated by commas after the first, and taking only the first is how
# the first version of this scanner produced three false findings.
ALTER_TABLE = re.compile(
    r"ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?([\w.]+)([^;]*);",
    re.IGNORECASE | re.DOTALL,
)
ADD_COLUMN_IN = re.compile(
    r"ADD\s+(?:COLUMN\s+)?(?:IF\s+NOT\s+EXISTS\s+)?([a-z_][a-z0-9_]*)\s+",
    re.IGNORECASE,
)
DROP_COLUMN_IN = re.compile(
    r"DROP\s+(?:COLUMN\s+)?(?:IF\s+EXISTS\s+)?([a-z_][a-z0-9_]*)", re.IGNORECASE
)

INSERT_ON_CONFLICT = re.compile(
    r"INSERT\s+INTO\s+([\w.]+)[^;]*?ON\s+CONFLICT[^;]*?DO\s+UPDATE\s+SET\s+(.*?)(?:WHERE|RETURNING|;)",
    re.IGNORECASE | re.DOTALL,
)
ASSIGNMENT = re.compile(r"^\s*([a-z_][a-z0-9_]*)\s*=", re.IGNORECASE | re.MULTILINE)

# Tables this repository does not create and cannot be expected to know.
# `storage.buckets` is Supabase-managed; a finding against it would be a claim
# about a schema this repository has never seen.
EXTERNAL_TABLES = {"buckets"}


def table_columns() -> dict[str, set[str]]:
    """Every table any migration creates, with its declared columns."""
    known: dict[str, set[str]] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        text = path.read_text(encoding="utf-8", errors="replace")
        for name, body in CREATE_TABLE.findall(text):
            short = name.split(".")[-1].lower()
            cols = {c.lower() for c in COLUMN.findall(body)}
            if cols:
                known.setdefault(short, set()).update(cols)
        for table, clauses in ALTER_TABLE.findall(text):
            short = table.split(".")[-1].lower()
            cols = known.setdefault(short, set())
            for col in ADD_COLUMN_IN.findall(clauses):
                cols.add(col.lower())
            for col in DROP_COLUMN_IN.findall(clauses):
                cols.discard(col.lower())
    return known


def _function_definitions() -> list[tuple[str, int, int]]:
    """(function name, file index, offset) for every CREATE OR REPLACE."""
    out: list[tuple[str, int, int]] = []
    for i, path in enumerate(sorted(MIGRATIONS.glob("*.sql"))):
        text = path.read_text(encoding="utf-8", errors="replace")
        for m in re.finditer(
            r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+([\w.]+)\s*\(", text, re.IGNORECASE
        ):
            out.append((m.group(1).split(".")[-1].lower(), i, m.start()))
    return out


def _latest_definition_index() -> dict[str, int]:
    """Function name -> the file index of the LAST file that defines it."""
    latest: dict[str, int] = {}
    for name, file_index, _ in _function_definitions():
        latest[name] = file_index
    return latest


def find_bad_targets() -> tuple[list[str], int, int]:
    known = table_columns()
    files = sorted(MIGRATIONS.glob("*.sql"))
    latest = _latest_definition_index()
    findings: list[str] = []
    scanned = 0
    superseded = 0

    for i, path in enumerate(files):
        text = path.read_text(encoding="utf-8", errors="replace")
        # Where each CREATE OR REPLACE FUNCTION starts in THIS file, so an
        # ON CONFLICT can be attributed to the function that contains it.
        starts = [
            (m.start(), m.group(1).split(".")[-1].lower())
            for m in re.finditer(
                r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+([\w.]+)\s*\(", text, re.IGNORECASE
            )
        ]

        for m in INSERT_ON_CONFLICT.finditer(text):
            table, setlist = m.group(1), m.group(2)
            owner = None
            for offset, name in starts:
                if offset < m.start():
                    owner = name
                else:
                    break
            # A later migration restating the same function supersedes this
            # text: the deployed database holds the LAST definition, so a bug
            # in a superseded body is a historical fact, not a live defect.
            # Flagging it anyway would leave this check permanently red over a
            # migration that can never be edited, and a check that is always
            # red is a check nobody reads.
            if owner is not None and latest.get(owner, i) != i:
                superseded += 1
                continue

            scanned += 1
            short = table.split(".")[-1].lower()
            cols = known.get(short)
            if not cols:
                if short in EXTERNAL_TABLES:
                    continue
                findings.append(
                    f"{path.name}: upsert into {table}, a table no migration "
                    f"creates -- cannot be checked"
                )
                continue
            for col in ASSIGNMENT.findall(setlist):
                target = col.lower()
                if target not in cols:
                    findings.append(
                        f"{path.name}: ON CONFLICT DO UPDATE on {short} sets "
                        f"'{target}', which is not a column of that table -- the "
                        f"statement cannot plan (42703) and has never run"
                    )
    return findings, scanned, superseded


def main() -> int:
    findings, scanned, superseded = find_bad_targets()
    for f in sorted(set(findings)):
        print(f)
    if findings:
        print(f"\nFAIL: {len(set(findings))} statement(s) name a column that "
              f"does not exist. Each one raises 42703 at PLAN time, before "
              f"writing anything, so the feature behind it has never worked.")
        return 1
    print(f"ok: {scanned} ON CONFLICT DO UPDATE statement(s) name a real "
          f"column of the table they update"
          + (f"; {superseded} ignored as superseded by a later restatement"
             if superseded else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())