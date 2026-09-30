#!/usr/bin/env python3
"""Refuse a column reference that the query's own scope cannot provide.

## Why this exists

20260927000112 shipped, inside a plpgsql body:

    SELECT count(*) INTO v_cat_guard FROM (
      SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x
    ) d WHERE x <> '';

`AS x` names the TABLE, not the column, and in any case the derived table `d`
projects the constant `1`, so there is no `x` in scope at all. 20260927000115
answered the diagnostic -- `column "x" does not exist` -- by naming the column
(`AS x(part)`) while LEAVING THE SUBQUERY WRAPPED, so the derived table still
projected `1` and `part` was still not a column of it.

Both statements PARSE. pglast accepts them, `plpgsql_body_syntax.py` accepts
them, the whole-file parse accepts them. A reference to a column no relation in
scope provides is a SEMANTIC error no parser can see: the name only has to
exist at execution time. Two consecutive deploys died on it (SQLSTATE 42703),
and each round cost a live deploy plus a full Connectivity run to discover.

## The rule, and why it cannot cry wolf

For each embedded statement, resolve the FROM clause. A column reference is
judged ONLY when EVERY relation in scope has a fully-known output column list --
i.e. every relation is a derived table or a CTE whose SELECT list is constants,
plain column names, or aliases. A base table, a set-returning function in FROM
(`unnest`, which is how the FIXED statement reads), `VALUES`, `SELECT *`, or an
unaliased function result makes the scope UNKNOWN, and the whole statement is
skipped.

That asymmetry is the point: an unrecognised relation can only ever SUPPRESS a
finding, never create one. plpgsql variables -- the DECLARE section and the
signature's parameters -- are collected and excluded for the same reason:
PostgreSQL would resolve such a name to the variable, so flagging it would be
wrong, and the variable list over-collects on purpose.

A qualified reference is judged only when its qualifier is one of the known
relations, so `public.some_table.col` and a row variable stay silent.

Usage:
    python3 tools/harness/column_scope.py <migration> [<migration>...]
    python3 tools/harness/column_scope.py --recent [N]   # default gate
    python3 tools/harness/column_scope.py --all           # audit
"""

from __future__ import annotations

import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MIGRATIONS = ROOT / "supabase" / "migrations"

sys.path.insert(0, str(HERE))

try:
    import pglast  # type: ignore
    from pglast import ast  # type: ignore
except ImportError:  # pragma: no cover
    print("pglast is not installed; cannot check column scope")
    sys.exit(0)

import plpgsql_body_syntax as pbs  # noqa: E402

#: plpgsql's own implicitly-declared names. A bare identifier matching one of
#: these is never a column lookup, so it must never be reported.
SPECIAL = {
    "new", "old", "found", "sqlstate", "sqlerrm",
    "tg_name", "tg_when", "tg_level", "tg_op", "tg_relid", "tg_relname",
    "tg_table_name", "tg_table_schema", "tg_nargs", "tg_argv",
}

#: `CREATE [OR REPLACE] FUNCTION name(...)`. The parameter list is taken
#: verbatim; a default expression containing a comma over-collects a name,
#: which is safe (an over-collected name only suppresses a finding).
_SIGNATURE = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+[^(]*\(([^)]*)\)", re.IGNORECASE
)


def _declared_names(body: str) -> set[str]:
    """Every name a DECLARE section could declare, over-collected on purpose.

    A declaration can span lines, so the leading identifier of every line
    inside a DECLARE region is taken -- continuation lines contribute their
    type (`text`, `int`), which is harmless. Nested blocks re-open `DECLARE`,
    so their variables are collected too.
    """
    names: set[str] = set()
    in_decl = False
    for raw in body.splitlines():
        line = raw.split("--", 1)[0].strip()
        if not line:
            continue
        if re.match(r"(?i)^DECLARE\b", line):
            in_decl = True
            continue
        if in_decl and re.match(r"(?i)^BEGIN\b", line):
            in_decl = False
            continue
        if in_decl:
            m = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", line)
            if m:
                names.add(m.group(1).lower())
    return names


def _parameter_names(prefix: str) -> set[str]:
    """Names from the newest function signature in `prefix`, over-collected."""
    last = None
    for last in _SIGNATURE.finditer(prefix):
        pass
    if last is None:
        return set()
    names: set[str] = set()
    for part in last.group(1).split(","):
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", part)
        if m:
            names.add(m.group(1).lower())
    return names


# ------------------------------------------------------------------ AST ----


def _select_outputs(stmt, ctes: dict[str, set[str]]) -> tuple[bool, set[str]]:
    """(fully_known, names) for a SelectStmt used as a derived table."""
    if not isinstance(stmt, ast.SelectStmt):
        return False, set()
    if int(getattr(stmt, "op", 0)) != 0:
        # UNION/INTERSECT/EXCEPT takes its output names from the first branch.
        return _select_outputs(stmt.larg, ctes)
    if stmt.valuesLists or not stmt.targetList:
        return False, set()
    names: set[str] = set()
    for t in stmt.targetList:
        if not isinstance(t, ast.ResTarget):
            return False, set()
        if t.name:
            names.add(t.name.lower())
            continue
        val = t.val
        if isinstance(val, ast.ColumnRef):
            fields = val.fields
            if fields and all(isinstance(f, ast.String) for f in fields):
                names.add(fields[-1].sval.lower())
            else:
                return False, set()
        elif isinstance(val, ast.A_Const):
            # An unaliased constant is named `?column?` by PostgreSQL.
            names.add("?column?")
        else:
            # An unaliased function/expression has a derived name; do not guess.
            return False, set()
    return True, names


def _from_relations(from_clause, ctes):
    """(all_known, union_of_outputs, alias -> outputs) for a FROM clause."""
    known = True
    union: set[str] = set()
    by_alias: dict[str, set[str]] = {}

    def record(alias_obj, names):
        union.update(names)
        if alias_obj is not None and alias_obj.aliasname:
            by_alias[alias_obj.aliasname.lower()] = set(names)

    def visit(node):
        nonlocal known
        if node is None:
            return
        if isinstance(node, (list, tuple)):
            for x in node:
                visit(x)
            return
        if isinstance(node, ast.RangeSubselect):
            ok, names = _select_outputs(node.subquery, ctes)
            if not ok:
                known = False
                return
            if node.alias is not None and node.alias.colnames:
                names = {c.sval.lower() for c in node.alias.colnames}
            record(node.alias, names)
            return
        if isinstance(node, ast.RangeVar):
            relname = (node.relname or "").lower()
            if relname in ctes:
                names = set(ctes[relname])
                if node.alias is not None and node.alias.colnames:
                    names = {c.sval.lower() for c in node.alias.colnames}
                record(node.alias, names)
                if node.alias is None or not node.alias.aliasname:
                    by_alias[relname] = set(names)
                return
            known = False
            return
        if isinstance(node, ast.RangeFunction):
            if node.alias is not None and node.alias.colnames:
                names = {c.sval.lower() for c in node.alias.colnames}
                record(node.alias, names)
                return
            known = False
            return
        if isinstance(node, ast.JoinExpr):
            visit(node.larg)
            visit(node.rarg)
            return
        known = False

    visit(from_clause)
    return known, union, by_alias


def _refs(node):
    """Every ColumnRef in `node`, stopping at nested SelectStmt scopes."""
    if isinstance(node, ast.SelectStmt):
        return
    if isinstance(node, ast.ColumnRef):
        yield node
        return
    if isinstance(node, ast.Node):
        for field in node:
            yield from _refs(getattr(node, field))
    elif isinstance(node, (list, tuple)):
        for x in node:
            yield from _refs(x)


def _walk(node, ctes, locals_, inherited, findings):
    if node is None:
        return
    if isinstance(node, ast.SelectStmt):
        _select(node, ctes, locals_, inherited, findings)
        return
    if isinstance(node, ast.Node):
        for field in node:
            _walk(getattr(node, field), ctes, locals_, inherited, findings)
    elif isinstance(node, (list, tuple)):
        for x in node:
            _walk(x, ctes, locals_, inherited, findings)


def _judge(ref, by_alias, allowed, findings):
    fields = ref.fields
    if not fields or any(isinstance(f, ast.A_Star) for f in fields):
        return
    if not all(isinstance(f, ast.String) for f in fields):
        return
    names = [f.sval.lower() for f in fields]
    if len(names) == 1:
        name = names[0]
        if name in allowed:
            return
        findings.append((name, None))
        return
    qualifier, column = names[0], names[-1]
    outputs = by_alias.get(qualifier)
    if outputs is not None and column not in outputs:
        findings.append((column, qualifier))


def _select(stmt, ctes, locals_, inherited, findings):
    ctes = dict(ctes)
    if stmt.withClause is not None:
        for cte in stmt.withClause.ctes:
            ok, names = _select_outputs(cte.ctequery, ctes)
            if cte.aliascolnames:
                names = {c.sval.lower() for c in cte.aliascolnames}
                ok = True
            if ok:
                ctes[cte.ctename.lower()] = names

    if int(getattr(stmt, "op", 0)) != 0:
        _walk(stmt.larg, ctes, locals_, inherited, findings)
        _walk(stmt.rarg, ctes, locals_, inherited, findings)
        return

    known, union, by_alias = _from_relations(stmt.fromClause, ctes)
    allowed = set(inherited) | union | set(by_alias) | set(locals_) | SPECIAL
    for t in (stmt.targetList or ()):
        if isinstance(t, ast.ResTarget) and t.name:
            allowed.add(t.name.lower())
    ok, names = _select_outputs(stmt, ctes)
    if ok:
        allowed |= names

    if stmt.fromClause and known:
        for clause in (stmt.targetList, stmt.whereClause, stmt.groupClause,
                       stmt.havingClause, stmt.sortClause, stmt.windowClause,
                       stmt.fromClause, stmt.valuesLists, stmt.distinctClause):
            for ref in _refs(clause):
                _judge(ref, by_alias, allowed, findings)

    # Nested scopes inherit this scope's known names, so a LATERAL subquery
    # that legitimately reads the outer row is never reported.
    if stmt.withClause is not None:
        for cte in stmt.withClause.ctes:
            _walk(cte.ctequery, ctes, locals_, set(), findings)
    for clause in (stmt.targetList, stmt.whereClause, stmt.groupClause,
                   stmt.havingClause, stmt.sortClause, stmt.windowClause,
                   stmt.fromClause, stmt.valuesLists, stmt.distinctClause,
                   stmt.limitCount, stmt.limitOffset):
        _walk(clause, ctes, locals_, allowed, findings)


# -------------------------------------------------------------- per file ----


def check_file(path: pathlib.Path) -> list[str]:
    text = path.read_text()
    problems: list[str] = []

    locals_by_start: dict[int, set[str]] = {}
    for start, prefix, body, _sql_body in pbs.iter_bodies(text):
        locals_by_start[start] = _declared_names(body) | _parameter_names(prefix)

    for line, body_start, _sql_body, stmt, to_parse in pbs.iter_statements(text):
        try:
            tree = pglast.parse_sql(to_parse)
        except Exception:  # noqa: BLE001 - the syntax gate owns this failure
            continue
        locals_ = locals_by_start.get(body_start, set())
        findings: list[tuple] = []
        statement_text = " ".join(stmt.split())
        for raw in tree:
            _walk(raw.stmt, {}, locals_, set(), findings)
        for (name, qualifier) in findings:
            where = f"{qualifier}.{name}" if qualifier else name
            problems.append(
                f"{path.name}:{line}: `{where}` is not a column any relation in "
                f"scope provides, so the statement raises "
                f'`column "{name}" does not exist` (SQLSTATE 42703) at run time\n'
                f"      statement: {statement_text[:140]}"
            )
    return problems


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--all":
        targets = sorted(MIGRATIONS.glob("*.sql"))
    elif argv[0] == "--recent":
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
        print(f"\n{len(problems)} column reference(s) a query's scope cannot provide.")
        return 1
    print(f"ok: every column a query references, in {len(targets)} file(s), is "
          f"provided by its own scope")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
