#!/usr/bin/env python3
"""Line-level diff of a restated function body against its last defining migration.

When a migration re-issues `CREATE OR REPLACE FUNCTION foo(...)`, the single
most dangerous failure mode is a *silent* one: the restatement drops a line the
original had, and nothing in SQL parsing notices.  This tool proves that a
restated body is a pure superset of its predecessor -- every non-blank,
non-comment line of the original still appears, in the same order, and the
only lines the restatement adds are the ones we explicitly allow.

Usage:
    python3 tools/harness/restated_body_diff.py            # run every case
    python3 tools/harness/restated_body_diff.py --verbose  # print each diff

Exit code 0 when every case is clean, 1 otherwise.
"""
from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"

# Strict: only a top-level `CREATE OR REPLACE FUNCTION` opens a definition.
# `non_grouped_calls` on the name stops `CREATE OR REPLACE VIEW foo` etc. from
# being mistaken for a function, and the trailing `(` anchors the arg list.
FN_HEAD = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:public\.)?([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.IGNORECASE,
)

# Anything that legitimately differs from line to line and must not be judged.
NOISE = re.compile(
    r"""(
          ^\s*$                                  # blank
        | ^\s*--                                  # line comment
        | ^\s*/\* | \*/\s*$                       # block comment edges
        | ^\s*\*                                  # block comment body
    )""",
    re.VERBOSE | re.IGNORECASE,
)


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _files() -> list[Path]:
    return sorted(MIGRATIONS.glob("*.sql"))


def _strip_inline_comments(line: str) -> str:
    """Drop a trailing `--` comment but keep string literals intact."""
    out: list[str] = []
    i = 0
    quote: str | None = None
    while i < len(line):
        ch = line[i]
        if quote:
            out.append(ch)
            if ch == quote:
                quote = None
        elif ch in "'\"":
            quote = ch
            out.append(ch)
        elif ch == "-" and line[i : i + 2] == "--":
            break
        elif ch == "/" and line[i : i + 2] == "/*":
            break
        else:
            out.append(ch)
        i += 1
    return "".join(out).strip()


def function_bodies(sql: str) -> dict[str, str]:
    """Map function name -> full text of its last `CREATE OR REPLACE` body.

    Later definitions win *within* a file only when they are genuinely a new
    statement; because we scan the file top to bottom and overwrite, the last
    occurrence in the file is what we return.  Across files the caller decides
    the ordering, and a file that merely *references* the name (in a COMMENT,
    a DROP, or a grant) never opens a definition because the regex is anchored
    on `CREATE OR REPLACE FUNCTION`.
    """
    bodies: dict[str, str] = {}
    for m in FN_HEAD.finditer(sql):
        name = m.group(1).lower()
        # Walk forward to the matching $$ / $body$ terminator.
        rest = sql[m.end():]
        end = _find_terminator(rest)
        bodies[name] = rest[:end] if end is not None else rest
    return bodies


def _find_terminator(rest: str) -> int | None:
    """Return index just past the `$$;` that closes the body, or None."""
    i = 0
    n = len(rest)
    tag: str | None = None
    while i < n:
        if rest[i] == "$":
            m = re.match(r"\$[A-Za-z_]*\$", rest[i:])
            if m:
                tok = m.group(0)
                if tag is None:
                    tag = tok
                elif tok == tag:
                    j = i + len(tok)
                    while j < n and rest[j] in " \t":
                        j += 1
                    if j < n and rest[j] == ";":
                        return j + 1
                i += len(tok)
                continue
        i += 1
    return None


def _code_lines(body: str) -> list[str]:
    """Significant lines only: comments and blanks removed, leading ws gone."""
    out: list[str] = []
    for raw in body.splitlines():
        if NOISE.search(raw):
            continue
        line = _strip_inline_comments(raw)
        if not line:
            continue
        out.append(line)
    return out


def last_defining(fn: str) -> tuple[Path, str] | None:
    """Find the newest migration (excluding `skip`) that defines `fn`."""
    found: tuple[Path, str] | None = None
    for p in _files():
        bodies = function_bodies(_read(p))
        if fn in bodies:
            found = (p, bodies[fn])
    return found


def defining_in_file(fn: str, filename_glob: str) -> tuple[Path, str] | None:
    for p in _files():
        if not p.name.startswith(filename_glob):
            continue
        bodies = function_bodies(_read(p))
        if fn in bodies:
            return p, bodies[fn]
    return None


def _runs(lines: list[str]) -> list[list[str]]:
    """Split a diff's +/- lines into contiguous blocks of the same sign.

    An `@@` entry is a hunk boundary and always starts a fresh block, so two
    additions separated by unrelated hunks stay two blocks.
    """
    out: list[list[str]] = []
    for line in lines:
        if line == "@@":
            out.append(["@@", []])
            continue
        sign, text = line[0], line[1:].strip()
        if out and out[-1][0] == sign:
            out[-1][1].append(text)
        else:
            out.append([sign, [text]])
    return [[s, b] for s, b in out]


def _flat(block: list[str]) -> str:
    return " ".join(block)


# ---------------------------------------------------------------- cases ----
# (function, source-file glob, restating-file glob, approved added blocks)
# The approved entries are EXACT whitespace-normalised contiguous blocks from
# the diff, not substring hints.  That is the strongest form of the assertion:
# it proves the restatement added precisely the scope guard and nothing else,
# and it goes red the moment anyone edits the guard, drops a half of it, or
# slips an unrelated change into a restated body.
CASES: list[tuple[str, str, str, tuple[str, ...]]] = [
    (
        "verify_payment_proof",
        "20260922000012",
        "20260927000112",
        (
            "WHERE proof.id = p_proof_id)) OR NOT public.staff_scope_allows_city( "
            "(SELECT o.city FROM public.payment_proofs proof "
            "JOIN public.orders o ON o.id = proof.order_id",
        ),
    ),
    (
        "staff_task_feed",
        "20260927000052",
        "20260927000112",
        (
            "AND (v_view_all OR public.staff_scope_allows_city( "
            "coalesce(pp.city, us.city), v_staff.user_id))",
            "AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))",
            "AND (v_view_all OR public.staff_scope_allows_city( "
            "coalesce(o.city, pp.city), v_staff.user_id))",
        ),
    ),
    # The fulfilment gate. `claim_ride`'s only definition is the pre-baseline
    # 0021 snapshot, whose body is a single line, so the restatement reformats
    # it -- which is why this case proves the value of the tool rather than
    # just using it: it confirms nothing was DROPPED even though almost every
    # line differs.
    (
        "transition_order_status",
        "20260927000085",
        "20260927000113",
        (
            "v_blockers text[];",
            # The whole guard is one contiguous block, so it is approved as one
            # entry. Splitting it per line would let a half-guard pass.
            "IF v_actor_is_provider AND NOT v_actor_is_admin THEN "
            "v_blockers := public.provider_fulfilment_blockers(v_order.provider_id); "
            "IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN "
            "RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', "
            "array_to_string(v_blockers, ','); END IF; END IF;",
        ),
    ),
]


def check_case(fn: str, src_glob: str, dst_glob: str, allowed: tuple[str, ...],
               verbose: bool) -> list[str]:
    problems: list[str] = []
    src = defining_in_file(fn, src_glob)
    dst = defining_in_file(fn, dst_glob)
    if src is None:
        return [f"{fn}: source definition not found in {src_glob}*"]
    if dst is None:
        return [f"{fn}: restated definition not found in {dst_glob}*"]
    if src[0] == dst[0]:
        return [f"{fn}: source and restatement resolved to the same file ({src[0].name})"]

    old = _code_lines(src[1])
    new = _code_lines(dst[1])
    if not old:
        return [f"{fn}: source body produced no code lines"]
    if not new:
        return [f"{fn}: restated body produced no code lines"]

    # Keep the leading sign: _runs() needs it to group contiguous same-sign
    # blocks, and difflib interleaves + and - inside a changed hunk.  A hunk
    # header is kept as a separator so two additions in different hunks are
    # never flattened into one block.
    signed: list[str] = []
    for line in difflib.unified_diff(old, new, lineterm="", n=0):
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("@@"):
            signed.append("@@")
        elif line[0] in "+-":
            signed.append(line.strip())

    added = [s for s in signed if s == "@@" or s.startswith("+")]
    removed = [s for s in signed if s.startswith("-")]

    if verbose:
        print(f"\n--- {fn}: {src[0].name} -> {dst[0].name}")
        for line in difflib.unified_diff(old, new, fromfile=src[0].name,
                                         tofile=dst[0].name, lineterm="", n=1):
            print("   " + line)

    for line in removed:
        problems.append(f"{fn}: DROPPED original line: {line[1:].strip()!r}")

    # Every added line must belong to an approved contiguous block, and every
    # approved block must actually be used -- an unused entry means the guard
    # it was written for has silently disappeared.
    blocks = [b for s, b in _runs(added) if s == "+"]
    used: set[str] = set()
    for block in blocks:
        flat = _flat(block)
        match = next((a for a in allowed if a == flat), None)
        if match is None:
            problems.append(f"{fn}: unapproved added block: {flat!r}")
            continue
        used.add(match)
        if not flat.strip():
            problems.append(f"{fn}: an approved added block is empty")

    for a in allowed:
        if a not in used:
            problems.append(
                f"{fn}: expected guard block is absent from the restatement: {a!r}")

    if not added:
        problems.append(f"{fn}: restatement adds nothing (guard missing?)")

    return problems


def main() -> int:
    verbose = "--verbose" in sys.argv
    all_problems: list[str] = []
    for fn, src_glob, dst_glob, allowed in CASES:
        all_problems += check_case(fn, src_glob, dst_glob, allowed, verbose)

    if all_problems:
        print("RESTATED BODY DIFF: FAILED")
        for p in all_problems:
            print(f"  - {p}")
        return 1

    print(f"ok: {len(CASES)} restated function bodies are pure supersets of their "
          f"predecessors, and every added line is an approved scope guard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
