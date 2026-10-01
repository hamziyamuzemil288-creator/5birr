#!/usr/bin/env python3
"""Refuse a CREATE OR REPLACE FUNCTION that changes an existing return type.

## Why this exists

Migration 20260927000126 restated `public.admin_warn_user(uuid, text, text)`,
which the live database already had from 20260923000001 -- returning VOID there
and TEXT here. `CREATE OR REPLACE` cannot change a function's return type:
PostgreSQL raises

    ERROR: cannot change return type of existing function (SQLSTATE 42P13)

while ANALYSING the statement, before it ever reads the new body. The deploy
died on 0126 and 0127 and 0128 never applied, so a whole batch of finished work
sat behind one keyword.

Nothing in the repository could see it. pglast parses it, the whole-file parse
accepts it, `plpgsql_body_syntax.py` accepts it, `column_scope.py` accepts it,
`conflict_targets.py` looks only at ON CONFLICT, and `restated_body_diff.py`
compares the BODY (which is allowed to change freely) rather than the return
type. The signature is only compared with the live database at push time.

## The rule

Walk every migration in filename order -- the order a deploy applies them --
keeping a map of (name, argument types) -> return type, exactly the shape
PostgreSQL resolves a function by.

  * `DROP FUNCTION [IF EXISTS] name[(args)]` removes the entry (the whole name
    when no signature is given), because after it the signature genuinely does
    not exist.
  * `CREATE [OR REPLACE] FUNCTION name(args) RETURNS t` sets it, and -- for a
    CREATE OR REPLACE -- is a FINDING when the entry existed with a different
    return type and the file has not dropped it first.

Only files in the gate's scope are reported, so re-reading history does not
resurrect a change that already deployed cleanly (it could not have, which is
the point: a clean deploy means a DROP was there or the types matched).

Return types are NORMALISED before comparison, because PostgreSQL considers
`PROVIDER_PROFILES`, `public.provider_profiles` and `provider_profiles` the same
type, and `int`, `INTEGER` and `int4` too. Comparing raw text would report every
cosmetic restatement as a 42P13 that never happened -- a gate that cries wolf is
one people learn to ignore.

Usage:
    python3 tools/harness/return_type_changes.py --pending    # the deploy gate
    python3 tools/harness/return_type_changes.py --all        # audit history
    python3 tools/harness/return_type_changes.py <migration> [...]
"""

from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"

sys.path.insert(0, str(HERE))
import pending  # noqa: E402

_FUNC = re.compile(
    r"CREATE\s+(OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-z_0-9]+)\s*\(",
    re.I)
# A DROP may or may not carry a signature: `DROP FUNCTION IF EXISTS public.foo;`
# (valid when the name is unique) drops every overload of `foo`.
_DROP = re.compile(
    r"DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?(?:public\.)?([a-z_0-9]+)\s*(\()?",
    re.I)

_TYPE_SYNONYMS = {
    "int4": "integer",
    "int8": "bigint",
    "int2": "smallint",
    "int": "integer",
    "bool": "boolean",
    "float8": "double precision",
    "float4": "real",
    "decimal": "numeric",
    "varchar": "character varying",
    "timestamptz": "timestamp with time zone",
    "timetz": "time with time zone",
}


def _norm_type(text: str) -> str:
    """A comparable form of a return type.

    Schema qualifier, comments, case, whitespace and type synonyms are all
    removed, because none of them is a return-type CHANGE and PostgreSQL would
    accept each of them in a CREATE OR REPLACE.
    """
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"--[^\n]*", " ", text)
    text = text.lower().replace("public.", "")
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s*([(),])\s*", r"\1", text)
    for short, long_form in _TYPE_SYNONYMS.items():
        text = re.sub(r"\b%s\b" % short, long_form, text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _split_top(text: str) -> list[str]:
    parts, cur, depth = [], "", 0
    for ch in text:
        if ch == "(":
            depth += 1
        if ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += ch
    parts.append(cur)
    return parts


def _paren_end(sql: str, start: int) -> int:
    """Index just past the `)` that closes the `(` at `start - 1`."""
    depth, i = 1, start
    while i < len(sql) and depth:
        if sql[i] == "(":
            depth += 1
        elif sql[i] == ")":
            depth -= 1
        i += 1
    return i


def _argtypes(text: str) -> tuple[str, ...]:
    """Normalised argument types, which is what PostgreSQL resolves on.

    The DEFAULT clause is cut off first: `p_limit integer DEFAULT 20` is the
    signature `integer`, and comparing the whole thing would make a changed
    default look like a changed signature.
    """
    types: list[str] = []
    for piece in _split_top(text):
        piece = re.sub(r"--[^\n]*", "", piece).strip()
        if not piece:
            continue
        piece = re.split(r"\bDEFAULT\b", piece, flags=re.I)[0].strip()
        words = piece.split()
        if len(words) < 2:
            types.append(_norm_type(piece))
            continue
        if words[0].upper() in ("OUT", "INOUT", "IN"):
            words = words[1:]
        types.append(_norm_type(" ".join(words[1:])))
    return tuple(types)


def _return_type(tail: str) -> str | None:
    m = re.match(r"\s*RETURNS\s+(.+?)\s+(?:LANGUAGE|AS)\b", tail, re.I | re.S)
    if not m:
        return None
    return _norm_type(m.group(1))


def _definitions(sql: str):
    """(position, is_drop, name, argtypes_or_None, (or_replace, returns))."""
    events = []
    for m in _DROP.finditer(sql):
        if m.group(2) is None:
            events.append((m.start(), True, m.group(1).lower(), None, None))
        else:
            end = _paren_end(sql, m.end())
            events.append((m.start(), True, m.group(1).lower(),
                           _argtypes(sql[m.end():end - 1]), None))
    for m in _FUNC.finditer(sql):
        end = _paren_end(sql, m.end())
        events.append((m.start(), False, m.group(2).lower(),
                       _argtypes(sql[m.end():end - 1]),
                       (bool(m.group(1)), _return_type(sql[end:]))))
    events.sort(key=lambda e: e[0])
    return events


def _sources(names: list[str] | None = None) -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(MIGRATIONS.glob("*.sql")):
        if names is None or path.name in names:
            out[path.name] = path.read_text(encoding="utf-8", errors="replace")
    return out


def check(targets: list[pathlib.Path],
          sources: dict[str, str] | None = None) -> list[str]:
    """Findings for `targets`, over the whole migration history.

    `sources` exists for the falsifier: it replays real history with one file
    mutated in memory, so the proof of a red does not touch the repository.
    """
    if sources is None:
        sources = _sources()
    scope = {t.name for t in targets}
    known: dict[tuple[str, tuple[str, ...]], str] = {}
    problems: list[str] = []
    for name, sql in sources.items():
        for _pos, is_drop, fn, args, payload in _definitions(sql):
            if is_drop:
                if args is None:
                    for key in [k for k in known if k[0] == fn]:
                        known.pop(key, None)
                else:
                    known.pop((fn, args), None)
                continue
            or_replace, ret = payload
            if ret is None:
                # No readable return type (a language other than SQL/plpgsql, or
                # an unusual shape). Leave the map untouched rather than guess:
                # a wrong entry would invent a finding later.
                continue
            key = (fn, args)
            previous = known.get(key)
            if (previous is not None and previous != ret and or_replace
                    and name in scope):
                problems.append(
                    "%s: CREATE OR REPLACE FUNCTION %s(%s) returns %s, but an "
                    "earlier migration defined the same signature returning %s. "
                    "PostgreSQL refuses this with 42P13 (cannot change return "
                    "type of existing function) and the deploy stops here, "
                    "leaving every migration behind it unapplied. Add a "
                    "`DROP FUNCTION IF EXISTS %s(%s);` before the restatement "
                    "and re-issue its GRANT."
                    % (name, fn, ", ".join(args), ret, previous, fn,
                       ", ".join(args)))
            known[key] = ret
    return problems


def main(argv: list[str]) -> int:
    if not argv:
        argv = ["--pending"]
    note = ""
    if argv[0] == "--all":
        targets = sorted(MIGRATIONS.glob("*.sql"))
    elif argv[0] == "--pending":
        try:
            targets, note = pending.gate_targets()
        except pending.PendingError as exc:
            print(f"[FAIL] {exc}")
            return 1
    else:
        targets = [pathlib.Path(a) for a in argv]

    problems = check(targets)
    for p in problems:
        print(f"[FAIL] {p}")
    if note:
        print(f"note: {note}")
    if problems:
        print(f"\n{len(problems)} return type change(s) no deploy can apply.")
        return 1
    print(f"ok: no return type changes in {len(targets)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
