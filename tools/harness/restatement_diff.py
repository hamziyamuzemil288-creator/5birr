#!/usr/bin/env python3
"""Diff a restated SQL function body against its previous definition.

The brief for this task warns that careless restatement has twice dropped a
condition from a function in this repo (provider_profiles trigger, staff_task_feed
RPC). Reading is not a check. This compares the new body to the old one,
statement by statement, and reports anything present in the old body that is
absent from the new one.

Usage: python3 tools/harness/restatement_diff.py <new_migration> <fn> [<fn> ...]
"""
from __future__ import annotations

import glob
import os
import re
import sys

MIGRATIONS = "supabase/migrations"

# Statements that are intentionally ADDED by the restatement, and so are
# expected to be missing from the previous body.
ALLOWED_ADDITIONS = {
    "notify_user_once",
    "jsonb_build_object('event'",
    "'welcome to aliob'",
    "'your account is approved and ready to go.'",
    "'welcome to aliob, '",
}

# Branches this task deliberately REWROTE (same trigger point, richer message).
#
# The diff separates "rewritten" from "lost", because conflating them is how a
# dropped condition gets waved through as an intentional edit. A rewrite is
# only acceptable when the NEW body still notifies on the same status, so the
# test is: does the replacement text contain the same status label AND a
# notification call? If yes it is a MODIFIED branch; if no it is LOST.
#
# Each entry must be justified. An unexpected rewrite fails the check.
REVIEWED_REWRITES = {
    # order APPROVED: the buyer message now quotes the amount, and the
    # provider (previously told nothing) is now notified too.
    "fn_notify_order_status_change": {"approved"},
    # ride CLAIMED: names the driver who accepted instead of "a driver".
    # ride COMPLETED: rider gets a receipt with fare and driver name; the
    # driver is now notified as well.
    "fn_notify_ride_status_change": {"claimed", "completed"},
}

# Statements the differ reports as LOST that are intentionally REPLACED by a
# strictly larger form, with the reason. Kept separate from REVIEWED_REWRITES
# (which is about if/elsif status branches) because these are whole statements
# that were subsumed into another one rather than deleted.
#
# notify_user_once: the single-table dedupe IF became a two-table check, because
# notify_user() queues client-path notifications in notification_outbox and never
# touches notifications until the cron drain. Found by the first live run of the
# connectivity suite, not by reading the code.
INTENTIONAL_SUPERSESSIONS = {
    "notify_user_once": [
        (
            "if exists ( select 1 from public.notifications "
            "where (data ->> 'idem_key') = p_idem_key ) then return null",
            "replaced by a check of notifications AND notification_outbox; "
            "the notifications half is retained verbatim",
        ),
    ],
    # Migration 95 replaced the iteration mechanism for the declared needle
    # table, so four statements are reworded rather than deleted. Each has a
    # one-for-one counterpart in the new body: the same guard, the same
    # query, the same comparison, with the loop and the variable names
    # changed. Declared so the diff records the intent instead of reporting a
    # rewrite as a loss.
    "assert_source_needles_match": [
        (
            "for v_i in 1 .. coalesce(array_length(v_cases, 1), 0) loop",
            "the subscript loop that iterated zero times, replaced by "
            "FOR ... IN SELECT * FROM unnest(v_needles, v_targets)",
        ),
        (
            "into v_target from pg_proc",
            "unchanged query; v_target renamed to v_src",
        ),
        (
            "if v_target is null then v_bad := v_bad || v_row[2]",
            "unchanged missing-target guard; v_row[2] is now v_target_fn",
        ),
        (
            "if position(replace(v_row[1], ' ', '') in replace(v_target",
            "unchanged comparison; v_row[1]/v_target renamed to "
            "v_needle/v_src",
        ),
    ],
}


def strip_comments(sql: str) -> str:
    """Remove SQL comments.

    Without this, adding a comment INSIDE a branch changes the branch's text
    and the diff reports the branch as lost. That is a false positive that
    trains you to ignore the tool, which is worse than not having it: a real
    loss and a well-commented branch then look identical.
    """
    sql = re.sub(r"--[^\n]*", " ", sql)
    return re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)


def normalise(sql: str) -> str:
    """Lowercase, drop comments, collapse whitespace, so formatting and
    commentary differences do not read as dropped conditions."""
    return re.sub(r"\s+", " ", strip_comments(sql)).lower().strip()


def split_statements(body: str) -> list[str]:
    """Split a plpgsql body on `;` at statement level, ignoring those inside
    string literals or parentheses. Comments are stripped first so an inline
    comment cannot split or pad a statement.

    The DECLARE block is dropped. A declaration carries no condition, and the
    failure this tool exists to catch is a lost condition — so comparing
    declarations only produces noise whenever a restatement reshapes its
    variables, which it is free to do. A restatement that drops a variable the
    body still references is a different bug: it deploys, then fails at run
    time, and the connectivity suite is what catches it (it is how the
    array_length and FOREACH bugs in 0093-0095 were found).
    """
    out, buf, depth, quote = [], [], 0, False
    body = strip_comments(body)
    dm = re.search(r"\bDECLARE\b", body, re.IGNORECASE)
    bm = re.search(r"\bBEGIN\b", body, re.IGNORECASE)
    if dm and bm and bm.start() > dm.start():
        body = body[bm.start():]
    i = 0
    while i < len(body):
        ch = body[i]
        if quote:
            if ch == "'":
                if i + 1 < len(body) and body[i + 1] == "'":
                    buf.append("''")
                    i += 2
                    continue
                quote = False
                buf.append(ch)
            else:
                # The contents of a literal ARE part of the statement. An
                # earlier version dropped them, so `status = 'APPROVED'`
                # compared as `status = ` and every restated line looked
                # different from itself.
                buf.append(ch)
        elif ch == "'":
            quote = True
            buf.append(ch)
        elif ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == ";" and depth == 0:
            stmt = "".join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []
        else:
            buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def function_body(sql: str, name: str) -> str | None:
    """Return the body of the last definition of `name` in `sql`.

    Matches the harness's existing helper: finds `create [or replace] function
    [public.]name` then takes everything between the first `$$`/`as $$` and the
    matching closing `$$`.
    """
    pattern = re.compile(
        r"create\s+(?:or\s+replace\s+)?function\s+(?:public\.)?" + re.escape(name) + r"\s*\(",
        re.IGNORECASE,
    )
    matches = list(pattern.finditer(sql))
    if not matches:
        return None
    m = matches[-1]
    rest = sql[m.end():]
    # Skip the parameter list (paren-balanced) to reach the body.
    depth, i = 1, 0
    while i < len(rest) and depth:
        if rest[i] == "(":
            depth += 1
        elif rest[i] == ")":
            depth -= 1
        i += 1
    tail = rest[i:]
    # The OPENING delimiter is the first `$$` after the signature, and the body
    # is everything up to the NEXT one.
    #
    # Do not "find" the delimiter with a pattern that also matches a closing
    # `$$;` — an earlier version searched for `\$\$\s*;` first, which skipped
    # the opening `$$` (it is followed by a newline and BEGIN, not `;`) and
    # matched the CLOSING one instead. That inverted the body, so the tool
    # reported the neighbouring function as "dropped" and would have passed a
    # genuinely truncated restatement.
    open_idx = tail.find("$$")
    if open_idx == -1:
        return None
    start = open_idx + 2
    end = tail.find("$$", start)
    if end == -1:
        return None
    return tail[start:end]


def previous_body(name: str, new_file: str) -> tuple[str, str] | None:
    """The last definition of `name` in any migration before `new_file`."""
    files = sorted(
        f for f in glob.glob(os.path.join(MIGRATIONS, "*.sql"))
        if os.path.basename(f) < os.path.basename(new_file)
    )
    found = None
    for f in files:
        body = function_body(open(f, encoding="utf-8").read(), name)
        if body is not None:
            found = (f, body)
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    new_file, names = argv[1], argv[2:]
    new_sql = open(new_file, encoding="utf-8").read()
    failures = 0

    for name in names:
        new_body = function_body(new_sql, name)
        if new_body is None:
            print(f"FAIL {name}: no definition in {os.path.basename(new_file)}")
            failures += 1
            continue
        prev = previous_body(name, new_file)
        if prev is None:
            print(f"WARN {name}: no previous definition found (nothing to diff)")
            continue
        prev_file, prev_body = prev
        print(f"\n=== {name}")
        print(f"    previous: {os.path.basename(prev_file)}")
        print(f"    new:      {os.path.basename(new_file)}")

        prev_stmts = split_statements(prev_body)
        new_norm = normalise(new_body)
        new_stmts = split_statements(normalise(new_body))

        # A statement is a BRANCH if it opens an if/elsif on a status. Branches
        # are held to a stricter test than plain statements, because a branch
        # that stops notifying is a user who is never told anything happened.
        branch_rx = re.compile(
            r"^(?:els)?if\s+new\.status\s*=\s*'([a-z_]+)'", re.IGNORECASE)

        dropped, modified = [], []
        for stmt in prev_stmts:
            n = normalise(stmt).strip(" ;")
            if not n:
                continue
            # A statement counts as preserved if it appears verbatim, or if all
            # of its significant lines appear (a restatement may re-wrap).
            if n in new_norm:
                continue
            if any(n in s for s in new_stmts):
                continue
            if any(a in n for a in ALLOWED_ADDITIONS):
                continue

            bm = branch_rx.match(n)
            if bm:
                status = bm.group(1)
                # A branch is only MODIFIED, never silently dropped, if the new
                # body still notifies on that same status. Otherwise the status
                # stopped being notified and it is a real loss.
                still_notifies = any(
                    re.match(r"^(?:els)?if\s+new\.status\s*=\s*'"
                             + status + r"'", s)
                    and ("notify_user" in s)
                    for s in new_stmts
                )
                if still_notifies:
                    modified.append((status, n))
                    continue
            sup = INTENTIONAL_SUPERSESSIONS.get(name, [])
            superseded = False
            for needle, why in sup:
                if needle in n:
                    print(f"    SUPERSEDED (declared): {why}")
                    superseded = True
            if superseded:
                continue
            dropped.append(n)

        expected = REVIEWED_REWRITES.get(name, set())
        unexpected = [s for s, _ in modified if s not in expected]
        missed = sorted(expected - {s for s, _ in modified})

        if dropped:
            failures += 1
            print(f"    LOST {len(dropped)} statement(s) from the old body:")
            for d in dropped:
                print(f"      - {d[:160]}")
        else:
            print(f"    ok: no statement lost ({len(prev_stmts)} old statements checked)")

        if modified:
            print(f"    REWRITTEN branch(es), as reviewed:")
            for s, _ in modified:
                tag = "reviewed" if s in expected else "UNEXPECTED"
                print(f"      ~ {s}  [{tag}]")

        if unexpected:
            failures += 1
            print(f"    FAIL: branch(es) rewritten without being listed as "
                  f"reviewed: {', '.join(unexpected)}")

        if missed:
            print(f"    note: listed as reviewed but unchanged: {', '.join(missed)}")

        added = [
            s for s in new_stmts
            if s not in [normalise(x).strip(" ;") for x in prev_stmts]
            and not any(normalise(x).strip(" ;") in s for x in prev_stmts)
        ]
        if added:
            print(f"    added {len(added)} statement(s):")
            for a in added:
                print(f"      + {a[:160]}")

    print()
    if failures:
        print(f"RESTATEMENT DIFF: {failures} problem(s) — see above")
        return 1
    print("RESTATEMENT DIFF: no lost statements; all rewrites were reviewed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
