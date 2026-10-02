#!/usr/bin/env python3
"""Falsification for check_registration_notifications_are_wired.

A check that has never been seen red is not yet a check. This proves the
registration-notification check actually goes red on the exact defects it was
written for, and stays green on the real migration. Neither run edits the real
file on disk.

The defects, in the order the check is able to see them:

  1. the trigger never created            -- the original bug: approval_requests
                                            had no trigger at all
  2. the reviewer fan-out emptied         -- the recipient set is still NAMED,
                                            so a substring check would pass
  3. the reactivation notice deleted      -- the 0026 regression, restated
  4. a guard clause dropped in that same  -- the failure mode that deleted the
     restatement                            notice in the first place
  5. the enum value never written         -- a notice with no type

Every check in static_checks reads file contents through the single `_read`
helper, so overriding that one function runs the real check code against a
patched string. `last_migration_defining` walks the migrations, so the patch
has to be installed there too, not only on `_read`.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

MIG = sc.REGISTRATION_MIGRATION
TARGET = str(sc.MIGRATIONS / MIG).replace("\\", "/")


def _drop_trigger(text: str) -> str:
    """The shipped state: the notice exists, nothing fires it.

    The CREATE TRIGGER statement is DELETED, not commented out. Commenting it
    would be a no-op against the check, which strips comments before it looks
    -- `-- CREATE TRIGGER x` strips back to `CREATE TRIGGER x`, so a
    comment-based mutation tests nothing and this falsifier would have
    reported a false green.
    """
    return re.sub(
        r"CREATE\s+TRIGGER\s+trg_registration_submitted\b[\s\S]*?"
        r"EXECUTE\s+FUNCTION\s+public\.on_registration_submitted\(\)\s*;",
        "", text, flags=re.IGNORECASE)


def _empty_the_fanout(text: str) -> str:
    """The recipient set is still named; the loop that used it is gone.

    This is the case a substring check cannot see, and it is why the check
    requires the FOR as well as the call.
    """
    return re.sub(r"FOR\s+v_recipient\s+IN\s*\n\s*SELECT\s+r\.user_id\s+FROM\s+"
                  r"public\.registration_review_recipients\(\)\s*r\s*\n\s*LOOP"
                  r"[\s\S]*?\n\s*END\s+LOOP;",
                  "", text, flags=re.IGNORECASE)


def _unname_the_recipient_set(text: str) -> str:
    """The loop survives; the call that made it reach anybody is renamed.

    The mirror of the case above: a check that only looked for the FOR would
    pass this, which is why both are required.
    """
    return text.replace("registration_review_recipients()",
                        "some_other_recipient_set()")


def _drop_the_reactivation_notice(text: str) -> str:
    """0026's regression, restated: the account comes back silently."""
    return re.sub(
        r"PERFORM\s+public\.notify_user_safe\(\s*\n\s*'provider-reactivated:.*?"
        r"\n\s*\);",
        "", text, flags=re.IGNORECASE | re.DOTALL)


def _drop_a_guard_clause(text: str) -> str:
    """The city scope, gone -- the exact line 0111 added and 0026 lost.

    The whole statement is removed rather than a fragment, because the
    continuation is on the next line and a partial edit leaves text that no
    longer parses, which is a different failure from the one being tested.
    """
    return re.sub(
        r"\n\s*OR NOT public\.staff_scope_allows_city\([\s\S]*?p_provider_id\)\)",
        "", text, count=1, flags=re.IGNORECASE)


def _drop_the_enum_value(text: str) -> str:
    """A notification with no type."""
    return text.replace("'REGISTRATION_RECEIVED'", "'SOME_TYPE_THAT_IS_NOT_THERE'")


CASES: list[tuple[str, callable, str]] = [
    ("the trigger is never created, so the notice never fires",
     _drop_trigger,
     "trg_registration_submitted"),
    ("the reviewer fan-out is emptied but the recipient set is still named",
     _empty_the_fanout,
     "does not iterate the recipient set"),
    ("the recipient set is renamed out from under a loop that survives",
     _unname_the_recipient_set,
     "never calls registration_review_recipients"),
    ("unsuspend_provider reactivates an account without telling the person",
     _drop_the_reactivation_notice,
     "reactivates an account without telling the person"),
    ("unsuspend_provider loses a guard clause in the same restatement",
     _drop_a_guard_clause,
     "has lost its city scope"),
    ("the notification is written with a type that is not the enum member",
     _drop_the_enum_value,
     "REGISTRATION_RECEIVED"),
]


def with_migration(text: str | None) -> list[str]:
    """Run the real check with the registration migration reading as `text`."""
    real_read = sc._read
    real_last = sc.last_migration_defining

    def _read(path: Path) -> str:
        try:
            if str(path).replace("\\", "/").endswith(TARGET) and text is not None:
                return text
        except Exception:
            pass
        return real_read(path)

    def _last(name: str):
        if text is not None and name == "unsuspend_provider":
            # The restated body lives in the same file, so a patched read has
            # to be visible to the "last definition" walk as well.
            from static_checks import function_body
            body = function_body(_strip(text), name)
            if body:
                return Path(MIG), body
        return real_last(name)

    def _strip(src: str) -> str:
        return sc._strip_comments(src)

    sc._read = _read
    sc.last_migration_defining = _last
    try:
        return sc.check_registration_notifications_are_wired()
    finally:
        sc._read = real_read
        sc.last_migration_defining = real_last


def main() -> int:
    real = (sc.MIGRATIONS / MIG).read_text(encoding="utf-8")
    if not real.strip():
        print("[FAIL] %s is empty -- there is nothing to falsify" % MIG)
        return 1

    failures = 0
    for label, mutate, expect in CASES:
        problems = with_migration(mutate(real))
        if not problems:
            print("[FAIL] the check stayed GREEN when %s" % label)
            failures += 1
            continue
        if not any(expect in p for p in problems):
            print("[FAIL] %s was detected, but not by the assertion that "
                  "names %r -- the check is passing for the wrong reason"
                  % (label, expect))
            for p in problems:
                print("         - " + p)
            failures += 1
            continue
        print("[ ok ] detected: %s" % label)
        for p in problems:
            if expect in p:
                print("         - " + p)

    if with_migration(None):
        print("[FAIL] the real %s is still red" % MIG)
        for p in with_migration(None):
            print("         - " + p)
        return 1
    print("[ ok ] the real %s is green" % MIG)

    if failures:
        print("\nFALSIFICATION FAILED (%d case(s))" % failures)
        return 1
    print("\nFALSIFICATION PASSED (%d red cases, each green once repaired)"
          % len(CASES))
    return 0


if __name__ == "__main__":
    sys.exit(main())
