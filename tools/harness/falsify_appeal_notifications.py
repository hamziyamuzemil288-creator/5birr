#!/usr/bin/env python3
"""Falsification for check_appeal_notifications_reach_reviewers.

A check that has never been seen red is not yet a check. This proves the
appeal check goes red on the exact three defects it was written for, and green
on the real sources. Neither run edits a file on disk.

The three defects, one per cause of "it is not showing at the admin front
dashboard and in notifications bars":

  1. count() reads `.count` off an int            -- the document queue reads 0
  2. the badge omits appeals and disputes          -- open work is carded and
                                                     invisible at the top
  3. the trigger never calls the recipient set     -- nobody who can act on a
                                                     filed appeal is told

Each case patches the real text through the same `_read` monkey-patch the
sidebar falsifier uses, so the real check code runs against a mutated string.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

DASH = "lib/features/admin/admin_dashboard.dart"
MIG = sc.APPEAL_MIGRATION
MIG_TARGET = str(sc.MIGRATIONS / MIG).replace("\\", "/")
FORM = "lib/features/appeal/appeal_screen.dart"
QUEUE = "lib/features/admin/admin_appeals_screen.dart"


def _count_back_to_the_original(dash: str) -> str:
    """count() accepts only a PostgrestList again."""
    return dash.replace(
        "        if (res is int) return res;\n"
        "        if (res is num) return res.toInt();\n",
        "")


def _drop_appeals_from_the_badge(dash: str) -> str:
    m = re.search(r"final pendingTotal = (.*?);", dash, re.DOTALL)
    assert m, "pendingTotal not found"
    body = m.group(1).replace("\n        _openAppeals", "").replace(
        " +\n        _openDisputes", "")
    return dash[: m.start(1)] + body + dash[m.end(1):]


def _drop_documents_from_the_badge(dash: str) -> str:
    m = re.search(r"final pendingTotal = (.*?);", dash, re.DOTALL)
    assert m, "pendingTotal not found"
    return dash[: m.start(1)] + m.group(1).replace("_pendingDocuments", "") \
        + dash[m.end(1):]


def _empty_the_reviewer_fanout(sql: str) -> str:
    """The recipient set is still named; the loop that used it is gone."""
    return re.sub(
        r"FOR\s+v_recipient\s+IN\s*\n\s*SELECT\s+r\.user_id\s+FROM\s+"
        r"public\.appeal_review_recipients\(\)\s*r\s*\n\s*LOOP[\s\S]*?\n\s*END\s+LOOP;",
        "", sql, flags=re.IGNORECASE)


def _drop_the_respondent_notice(sql: str) -> str:
    """The restatement that forgets the person named in the case."""
    return re.sub(
        r"PERFORM\s+public\.notify_user_safe\(\s*\n\s*'appeal-filed:'.*?"
        r"NEW\.case_type\)\s*\n\s*\);",
        "", sql, flags=re.IGNORECASE | re.DOTALL)


def _revert_to_the_raising_send(sql: str) -> str:
    """Back to notify_user, which can roll back the user's own appeal."""
    return sql.replace("public.notify_user_safe(", "public.notify_user(")


def _stop_sending_the_case_type(form: str) -> str:
    return form.replace("            'case_type': _caseType,\n", "")


def _drop_the_queue_filter(queue: str) -> str:
    return queue.replace("    'DOCUMENT_VERIFICATION',\n", "")


def _refuse_the_case_type(sql: str) -> str:
    """The migration runs but the CHECK still refuses the new value."""
    return sql.replace("'GENERAL', 'PASSWORD_RESET', 'DOCUMENT_VERIFICATION')",
                       "'GENERAL', 'PASSWORD_RESET')")


CASES = [
    (DASH, _count_back_to_the_original, None, "count() does not accept a plain int"),
    (DASH, _drop_appeals_from_the_badge, None, "omits _openAppeals"),
    (DASH, _drop_documents_from_the_badge, None, "omits _pendingDocuments"),
    (MIG, _empty_the_reviewer_fanout, "fn_notify_appeal_case_filed", "does not iterate the recipient set"),
    (MIG, _drop_the_respondent_notice, "fn_notify_appeal_case_filed", "has stopped notifying NEW.respondent_id"),
    (MIG, _revert_to_the_raising_send, "fn_notify_appeal_case_filed", "ROLLS BACK the user's appeal"),
    (MIG, _refuse_the_case_type, None, "refused by the constraint at runtime"),
    (FORM, _stop_sending_the_case_type, None, "does not send case_type"),
    (QUEUE, _drop_the_queue_filter, None, "does not offer DOCUMENT_VERIFICATION"),
]

_real_read = sc._read


def with_patches(dash=None, sql=None, form=None, queue=None) -> list[str]:
    """Run the real check with each source reading as the patched string."""
    overlays = {
        DASH: dash,
        "supabase/migrations/" + MIG: sql,
        FORM: form,
        QUEUE: queue,
    }

    def _read(path: Path) -> str:
        try:
            key = str(path).replace("\\", "/")
            for suffix, text in overlays.items():
                if key.endswith(suffix) and text is not None:
                    return text
        except Exception:
            pass
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_appeal_notifications_reach_reviewers()
    finally:
        sc._read = _real_read


def main() -> int:
    dash = sc._read(sc.LIB / "features" / "admin" / "admin_dashboard.dart")
    sql = sc._read(sc.MIGRATIONS / MIG)
    form = sc._read(sc.LIB / "features" / "appeal" / "appeal_screen.dart")
    queue = sc._read(sc.LIB / "features" / "admin" / "admin_appeals_screen.dart")

    failures = 0
    slot = {DASH: "dash", MIG: "sql", FORM: "form", QUEUE: "queue"}
    for target, mutate, check_fn, expect in CASES:
        key = slot[target]
        kwargs = {"dash": dash, "sql": sql, "form": form, "queue": queue}
        kwargs[key] = mutate(kwargs[key])
        problems = with_patches(**kwargs)

        label = "%s: %s" % (target.split("/")[-1], mutate.__name__[1:])
        if not problems:
            print("[FAIL] the check stayed GREEN when %s" % label)
            failures += 1
            continue
        if not any(expect in p for p in problems):
            print("[FAIL] %s was detected, but not by the assertion naming "
                  "%r -- passing for the wrong reason" % (label, expect))
            for p in problems:
                print("         - " + p)
            failures += 1
            continue
        print("[ ok ] detected: %s" % label)
        for p in problems:
            if expect in p:
                print("         - " + p)

    if with_patches():
        print("[FAIL] the real sources are still red")
        for p in with_patches():
            print("         - " + p)
        return 1
    print("[ ok ] the real sources are green")

    if failures:
        print("\nFALSIFICATION FAILED (%d case(s))" % failures)
        return 1
    print("\nFALSIFICATION PASSED (%d red cases, each green once repaired)"
          % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())