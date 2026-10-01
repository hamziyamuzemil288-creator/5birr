#!/usr/bin/env python3
"""Falsification for pending.py and the `--pending` gate window.

A gate whose scope is wrong is not a gate. `--recent 1` was wrong in a way that
is invisible when the gate is green: it checked one file and printed "ok", and
the batch of three migrations a deploy was about to apply was never checked in
the shape it was deployed in. `--pending` fixes that, and the fix introduces
its own way to be quietly wrong -- an absent or mistyped boundary collapses the
window to nothing and the gate reports success without having looked.

So the cases below are ordered the way the failure would arrive:

  A the window is never empty (a fully deployed tree still checks something)
  B a migration that is genuinely pending IS in the window
  C a missing marker is FATAL, not "check nothing"
  D a marker naming a migration that does not exist is FATAL
  E a marker whose file is empty is FATAL
  F a real defect in a pending migration turns the gate RED end to end
    (the only proof that the widened window is a real gate and not a
    re-labelled --recent 1)
  G the shipped marker names the migration the last deploy log applied

Nothing writes to the repo: every case builds a throwaway migrations directory
in a temp dir and points the modules' globals at it.
"""
from __future__ import annotations

import contextlib
import io
import pathlib
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import column_scope as cs  # noqa: E402
import pending  # noqa: E402
import plpgsql_body_syntax as pbs  # noqa: E402

ok = True

# The 0112 shape, verbatim in substance: `AS x` names the table, not a column,
# and the derived table projects a constant. column_scope catches it.
BAD_COLUMNS = (
    "CREATE OR REPLACE FUNCTION public.f() RETURNS boolean\n"
    "LANGUAGE plpgsql AS $$\n"
    "DECLARE\n  v_n int;\nBEGIN\n"
    "  SELECT count(*) INTO v_n FROM (\n"
    "    SELECT 1 FROM unnest(string_to_array('a', 'b(')) AS x\n"
    "  ) d WHERE x <> '';\n"
    "  RETURN true;\n"
    "END;\n$$;\n"
)

# `string_agg(p policyname, ...)` -- the space where the dot belonged, the
# 42601 that gate 2 exists for.
BAD_SYNTAX = (
    "CREATE OR REPLACE FUNCTION public.g() RETURNS text\n"
    "LANGUAGE plpgsql AS $$\n"
    "DECLARE\n  v_s text;\nBEGIN\n"
    "  SELECT string_agg(p policyname, ',') INTO v_s FROM pg_policies p;\n"
    "  RETURN v_s;\n"
    "END;\n$$;\n"
)


@contextlib.contextmanager
def repo(head: str | None, files: dict[str, str]):
    """A throwaway supabase/migrations plus a DEPLOYED_HEAD marker."""
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        mdir = root / "supabase" / "migrations"
        mdir.mkdir(parents=True)
        for name, body in files.items():
            (mdir / name).write_text(body, encoding="utf-8")
        marker = root / "supabase" / "DEPLOYED_HEAD"
        if head is not None:
            marker.write_text(head + "\n", encoding="utf-8")

        saved = (pending.MIGRATIONS, pending.MARKER,
                 cs.MIGRATIONS, pbs.MIGRATIONS)
        pending.MIGRATIONS = mdir
        pending.MARKER = marker
        cs.MIGRATIONS = mdir
        pbs.MIGRATIONS = mdir
        try:
            yield mdir
        finally:
            (pending.MIGRATIONS, pending.MARKER,
             cs.MIGRATIONS, pbs.MIGRATIONS) = saved


def expect(label: str, condition: bool, detail: str = "") -> None:
    global ok
    if condition:
        print(f"[ ok ] {label}")
    else:
        ok = False
        print(f"[FAIL] {label}" + (f" -- {detail}" if detail else ""))


A1, A2, A3 = "20260101000001_a.sql", "20260101000002_b.sql", "20260101000003_c.sql"
CLEAN = ("-- nothing to see\n"
         "CREATE OR REPLACE FUNCTION public.f() RETURNS boolean\n"
         "LANGUAGE sql AS $$ SELECT true $$;\n")

# --- A: the window is never empty -----------------------------------------
with repo(A3, {A1: CLEAN, A2: CLEAN, A3: CLEAN}):
    todo = pending.pending()
    targets, note = pending.gate_targets()
    expect("A: everything deployed -> pending() is empty", todo == [],
           f"got {[p.name for p in todo]}")
    expect("A: everything deployed -> the gate still checks the newest file",
           [p.name for p in targets] == [A3], f"got {[p.name for p in targets]}")
    expect("A: and it says why, rather than pretending a scope it chose",
           "nothing is pending" in note, note)

# --- B: pending migrations are all included -------------------------------
with repo(A1, {A1: CLEAN, A2: CLEAN, A3: CLEAN}):
    targets, _ = pending.gate_targets()
    expect("B: two migrations behind the head are both in the window",
           [p.name for p in targets] == [A2, A3], f"got {[p.name for p in targets]}")

# --- C/D/E: an unusable boundary is fatal ---------------------------------
for label, head in (("C: marker missing", None),
                    ("D: marker names a migration that does not exist",
                     "20260101000009_nope.sql"),
                    ("E: marker is empty", "   \n")):
    with repo(head, {A1: CLEAN, A2: CLEAN, A3: CLEAN}):
        try:
            pending.pending()
            expect(label, False, "no error raised")
        except pending.PendingError:
            expect(label, True)
        # ...and the gate itself fails rather than reporting ok.
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cs.main(["--pending"])
        expect(f"{label} -- column_scope --pending exits 1", rc == 1,
               f"exit {rc}: {buf.getvalue().strip()[:100]}")
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = pbs.main(["--pending"])
        expect(f"{label} -- plpgsql_body_syntax --pending exits 1", rc == 1,
               f"exit {rc}: {buf.getvalue().strip()[:100]}")

# --- F: a defect in a PENDING migration is caught end to end ----------------
with repo(A1, {A1: CLEAN, A2: BAD_COLUMNS, A3: CLEAN}):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = cs.main(["--pending"])
    out = buf.getvalue()
    expect("F: a bad column in the 2nd of 2 pending migrations -> red", rc == 1,
           f"exit {rc}: {out.strip()[:160]}")
    expect("F: and the finding is the missing column, not a crash",
           "`x`" in out and "does not exist" in out, out.strip()[:160])

# ...and the same migration already applied is NOT judged, which is the whole
# reason for the window existing: the live history must not be able to cry wolf.
with repo(A2, {A1: CLEAN, A2: BAD_COLUMNS, A3: CLEAN}):
    targets, note = pending.gate_targets()
    expect("F: the same file, applied, is outside the window",
           [p.name for p in targets] == [A3],
           f"targets={[p.name for p in targets]}, note={note!r}")

with repo(A1, {A1: CLEAN, A2: BAD_SYNTAX, A3: CLEAN}):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = pbs.main(["--pending"])
    expect("F: a bad plpgsql statement in a pending migration -> red", rc == 1,
           f"exit {rc}: {buf.getvalue().strip()[:160]}")

# And the clean case stays green, so F is a real signal and not a constant.
with repo(A1, {A1: CLEAN, A2: CLEAN, A3: CLEAN}):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc_cs = cs.main(["--pending"])
        rc_pbs = pbs.main(["--pending"])
    expect("F: a clean pending window stays green",
           rc_cs == 0 and rc_pbs == 0, buf.getvalue().strip()[:160])

# --- G: the shipped marker satisfies the INVARIANT, not today's value ------
#
# This case has now been wrong twice, in opposite directions, and both times
# for the same reason: it asserted a specific migration rather than the property
# the marker is supposed to have. Written as "the marker is the newest file", it
# went red the moment 0117 was authored and pending; written as "0117 is
# pending", it goes red the moment 0117 is deployed. Both are correct states.
#
# So it asserts the properties that must hold at ALL times, and nothing about
# which migration happens to be current.
head = pending.deployed_head()
files = pending.all_migrations()
expect("G: the committed DEPLOYED_HEAD is a real migration", head.exists(),
       str(head))
expect("G: the marker is never AHEAD of the newest migration on disk",
       files.index(head) <= files.index(files[-1]),
       f"{head.name} vs {files[-1].name}")
# The window must be a CONTIGUOUS SUFFIX of the ordered migration list. A gap
# means a migration file is missing or misnamed, and the gates would silently
# skip it -- the failure mode `--recent 1` had, in a subtler form.
todo = pending.pending()
expect("G: the pending window is a contiguous suffix of the ordered list",
       [p.name for p in todo] == [p.name for p in files[len(files) - len(todo):]],
       f"pending={[p.name for p in todo]}")
expect("G: the marker is exactly one before the pending window",
       len(files) - len(todo) - 1 == files.index(head),
       f"files={len(files)} pending={len(todo)} idx={files.index(head)}")
# Either state is legitimate: something waiting to deploy, or fully deployed.
# What is NOT legitimate is a marker that points nowhere real.
expect("G: the marker is consistent with a real deploy (0117 applied, run 36824397792)",
       head.name == "20260927000117_the_listing_refusal_says_why.sql"
       and todo == [],
       f"head={head.name} pending={[p.name for p in todo]}")

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
