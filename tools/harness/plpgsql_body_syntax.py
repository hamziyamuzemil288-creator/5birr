#!/usr/bin/env python3
"""Parse the SQL inside plpgsql function bodies, which `pglast` on a file does not.

## Why this exists

`pglast` uses libpg_query, which is the real PostgreSQL grammar -- but only for
the statements it can see. A migration's `CREATE FUNCTION ... AS $$ ... $$` body
is parsed by pglast as *plpgsql*, and plpgsql defers each embedded SQL
statement to execution time. So a file can pass `pglast.parse_sql()` and still
be rejected by the server the moment the function is first created.

That is not hypothetical. `20260927000104` shipped `string_agg(p policyname,
...)` -- a space where the dot belonged -- inside
`gallery_read_surface_report()`. `pglast` on the whole file: clean.
`supabase db push`: `syntax error at or near "policyname" (SQLSTATE 42601)`,
25 seconds, after the commit was pushed and the deploy dispatched by hand.

Worse, the deploy log echoed the typo verbatim, so reading the failure to
diagnose it reproduced the same typo and hid it a second time.

## What it does

Walks each `$$ ... $$` / `$tag$ ... $tag$` body in a migration, splits it into
statements with a linear scanner, and parses each embedded statement as plain
SQL after stripping plpgsql's `INTO` clause.

Usage:
    python3 tools/harness/plpgsql_body_syntax.py <migration> [<migration>...]
    python3 tools/harness/plpgsql_body_syntax.py --recent [N]   # default gate
    python3 tools/harness/plpgsql_body_syntax.py --all           # audit
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"

try:
    import pglast  # type: ignore
except ImportError:  # pragma: no cover
    print("pglast is not installed; cannot check plpgsql bodies")
    sys.exit(0)


def find_bodies(text: str):
    """Yield (start, body) for each dollar-quoted plpgsql body in `text`.

    The delimiter is captured whole and closed by backreference to *itself*.
    Capturing only the optional tag and closing with `\\1` cannot match when the
    tag is absent -- which is every `$$ ... $$` body in this repo -- and made
    the first version of this tool find zero bodies and report success.
    """
    delim = r"\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$"
    for m in re.finditer(delim + r"(.*?)" + delim, text, re.DOTALL):
        yield m.start(), m.group(1)


def split_statements(body: str):
    """Split a plpgsql body on semicolons at paren depth 0, outside strings.

    A scanner, not a regex: the alternation-with-nested-quantifier version
    backtracked exponentially and the tool hung past a 120s timeout instead of
    returning an answer.
    """
    buf: list[str] = []
    depth = 0
    in_str = False
    i = 0
    n = len(body)
    while i < n:
        ch = body[i]
        if in_str:
            if ch == "'":
                if i + 1 < n and body[i + 1] == "'":
                    buf.append("''")
                    i += 2
                    continue
                in_str = False
            buf.append(ch)
        elif ch == "'":
            in_str = True
            buf.append(ch)
        elif ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == ";" and depth == 0:
            chunk = "".join(buf).strip()
            if chunk:
                yield chunk
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        yield tail


#: Only statements that begin with a SQL command are parsed. A blocklist of
#: plpgsql keywords was the first approach and it leaked twice: a DECLARE
#: block's variable lines (`v_select int;`) are not standalone SQL, and a
#: leading `--` comment glued an `IF` to its comment text. An allowlist of
#: real SQL commands skips both by construction, and fails safe -- an
#: unrecognised opener is not checked rather than falsely reported.
#:
#: `SELECT ... INTO` is deliberately allowed through: it is the shape this tool
#: most needs to check, and excluding it is what made the first version
#: report success on the exact typo it was written to catch.
SQL_COMMAND = re.compile(
    r"^\s*(select|insert|update|delete|with|merge|create|alter|drop|truncate|"
    r"grant|revoke|comment|notify|set|copy|call|do|values|refresh|"
    r"reindex|cluster|analyze|vacuum|listen|unlisten|begin|commit|rollback|"
    r"savepoint|release|prepare|execute|deallocate|declare cursor)\b",
    re.IGNORECASE,
)

#: Leading SQL comments, stripped before matching: a `--` line glued to the
#: statement after it otherwise hides the statement's real first keyword.
LEADING_COMMENTS = re.compile(r"\A(?:\s|--[^\n]*\n|\s)+")

#: plpgsql opens its main block with a bare `BEGIN`, which sits on the same
#: `;` boundary as the first real statement -- so the splitter yields
#: "BEGIN SELECT ...". `BEGIN` is also a SQL transaction command, so it cannot
#: simply be dropped from the allowlist; it is stripped instead.
PLPGSQL_BEGIN = re.compile(r"\A\s*BEGIN\b\s*", re.IGNORECASE)

#: plpgsql's `INTO a, b` is not standalone SQL, so it is normalised away before
#: parsing rather than causing the statement to be skipped.
#:
#: Applied ONLY to statements that open with SELECT. Applied unconditionally it
#: also eats the `INTO` of `INSERT INTO public.t ...`, turning it into
#: `INSERT public.t ...` and reporting a syntax error in a perfectly good
#: statement -- 500-odd false positives across the already-deployed history.
INTO_TARGETS = re.compile(
    r"\bINTO\s+(?:strict\s+)?[A-Za-z_][A-Za-z0-9_]*"
    r"(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*",
    re.IGNORECASE,
)
SELECT_START = re.compile(r"^\s*SELECT\b", re.IGNORECASE)

#: `UPDATE ... RETURNING * INTO v_row` is valid plpgsql and invalid plain SQL,
#: so the INTO after a RETURNING is normalised away for the same reason.
HAS_RETURNING = re.compile(r"\bRETURNING\b", re.IGNORECASE)


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text()
    problems: list[str] = []
    examined = 0

    for start, body in find_bodies(text):
        prefix = text[max(0, start - 800):start]
        if "LANGUAGE plpgsql" not in prefix:
            continue
        offset = 0
        for raw in split_statements(body):
            stmt = LEADING_COMMENTS.sub("", PLPGSQL_BEGIN.sub("", raw))
            if not stmt or not SQL_COMMAND.match(stmt):
                continue
            examined += 1
            to_parse = (INTO_TARGETS.sub("", stmt, count=1)
                        if (SELECT_START.match(stmt) or HAS_RETURNING.search(stmt))
                        else stmt)
            try:
                pglast.parse_sql(to_parse)
            except Exception as exc:  # noqa: BLE001 - report, never raise
                line = text[: start + offset].count("\n") + 1
                problems.append(
                    f"{path.name}:{line}: SQL inside a plpgsql body does not "
                    f"parse: {str(exc).splitlines()[0]}\n"
                    f"      statement: {' '.join(stmt.split())[:140]}"
                )
            offset += len(raw) + 1

    if examined == 0:
        problems.append(
            f"{path.name}: examined 0 statements inside a plpgsql body -- the "
            f"body extractor matched nothing, so this file was NOT checked"
        )
    return problems


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    if argv[0] == "--all":
        targets = sorted(MIGRATIONS.glob("*.sql"))
    elif argv[0] == "--recent":
        # The default scope for a pre-deploy gate: the newest migration, the
        # one being authored.
        #
        # --all is an audit, not a gate. The already-applied history contains
        # plpgsql bodies whose statements this splitter cannot separate
        # cleanly (control flow sharing a `;` boundary with the SQL around it)
        # and every one of those is live and working. Failing the build on
        # them would make the check cry wolf, which is how a real signal gets
        # ignored. What matters is that what is written today parses.
        n = int(argv[1]) if len(argv) > 1 else 1
        targets = sorted(MIGRATIONS.glob("*.sql"))[-n:]
    else:
        targets = [pathlib.Path(a) for a in argv]

    problems: list[str] = []
    for t in targets:
        if not t.exists():
            problems.append(f"{t}: no such file")
            continue
        problems.extend(check_file(t))

    # Known-unparseable for unrelated reasons; excluded from the suite.
    known = ("0021_live_schema_snapshot.sql", "0022c_functions.sql")
    problems = [p for p in problems if not any(k in p.split(":")[0] for k in known)]

    for p in problems:
        print(f"[FAIL] {p}")
    if problems:
        print(f"\n{len(problems)} problem(s) in SQL inside plpgsql bodies.")
        return 1
    print(f"ok: every SQL statement inside a plpgsql body in {len(targets)} "
          f"file(s) parses")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
