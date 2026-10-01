#!/usr/bin/env python3
"""The migrations a deploy would actually apply: everything after the applied head.

## Why this exists

The pre-deploy gates were scoped to `--recent 1`: the newest migration, the one
being authored. That is right for a single file and wrong as a statement of
intent, because the question the gate answers is not "is the file I am typing
clean?" but "is everything I am about to push to the live database clean?".

Those two diverge as soon as more than one migration is waiting: a batch of
three, each checked on the day it was written, goes out in one `db push` and
none of them has been checked in the shape it is actually deployed in. One run
of the suite should be able to say yes to the whole set.

## Where the boundary comes from

`supabase/DEPLOYED_HEAD` holds the filename of the newest migration a
successful `Deploy Supabase` run APPLIED -- not merely ran without error, since
a no-op deploy logs `Remote database is up to date` and applies nothing.

It is committed and updated by hand, immediately after the deploy log shows
`Applying migration <name>` (ARCHITECTURE.md 7.5 step 6). A boundary that is
recorded by the same deploy it describes is not a heuristic, and it is the only
thing in this repository that knows which migrations the live database has.

## Why the marker is fatal, not optional

If the marker is missing, names a migration that does not exist, or names one
that is somehow ahead of the newest migration on disk, this module raises. A
window that silently collapses to "nothing" or "everything" is a gate that
reports success without having looked at anything, which is worse than no gate:
`--recent 1` was wrong in exactly that direction, and the fix must not
reintroduce it through a missing file.
"""

from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
MARKER = ROOT / "supabase" / "DEPLOYED_HEAD"


class PendingError(RuntimeError):
    """The applied-migration boundary is unusable, so the window is unknown."""


def all_migrations() -> list[pathlib.Path]:
    return sorted(MIGRATIONS.glob("*.sql"))


def deployed_head() -> pathlib.Path:
    """The newest migration the live database has actually applied.

    Raises PendingError rather than guessing. See the module docstring.
    """
    if not MARKER.exists():
        raise PendingError(
            f"{MARKER} is missing, so which migrations the live database has "
            f"applied is unknown. Write the filename of the newest migration a "
            f"deploy log reported as 'Applying migration ...' (or the newest "
            f"migration at all if the database has never been pushed).")
    raw = MARKER.read_text(encoding="utf-8").strip()
    if not raw:
        raise PendingError(f"{MARKER} is empty.")
    files = all_migrations()
    head = MIGRATIONS / raw
    if head not in files:
        raise PendingError(
            f"{MARKER} names {raw!r}, which is not a migration in "
            f"supabase/migrations/.")
    return head


def pending() -> list[pathlib.Path]:
    """Every migration a deploy would apply, oldest first. May be empty.

    An empty result is a real state (the working tree is fully deployed), not an
    error, and the caller decides what to do about it -- see `gate_targets`.
    """
    files = all_migrations()
    return files[files.index(deployed_head()) + 1:]


def gate_targets(fallback: int = 1) -> tuple[list[pathlib.Path], str]:
    """The file set a pre-deploy gate should check, plus a note explaining it.

    When nothing is pending, the gates fall back to the newest `fallback`
    migration rather than checking an empty set. A gate whose scope is empty
    has proved nothing, and the newest migration is still worth re-reading --
    and it is the file a hand-edited deploy boundary is most likely to have
    just been drawn past.
    """
    todo = pending()
    if todo:
        return todo, f"{len(todo)} migration(s) not yet on the live database"
    files = all_migrations()
    newest = files[-fallback:]
    return newest, (
        f"nothing is pending -- every migration is deployed; re-checking the "
        f"newest {len(newest)} so the gate is never vacuous")
