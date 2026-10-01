#!/usr/bin/env python3
"""Falsify `check_permission_flags_reach_the_widget`.

The check reports nothing on the real tree, because the defect it looks for has
been fixed. That is exactly the state a check cannot be trusted in: a check that
has never been seen red is not yet a check, and "it found nothing" and "its
anchor stopped matching" are the same output.

So this file puts the defect back into a COPY of the tree and requires the
check to notice. If a future edit to the check breaks its anchor, these cases go
green again and this file says so.

The original bug, for reference, in lib/features/admin/
category_fee_settings_screen.dart:

    setState(() { _rows = ...; _loading = false; });
    _canEdit = await _readEditorFlag();

Reported as "city/category management in admin side bar is not opening -- the
icon is there but no opening". Every route, card and GRANT was correct. The
owner was told by the screen that only the owner could edit, and could not
select a category to start.
"""

import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCREEN = "lib/features/admin/category_fee_settings_screen.dart"
DASH = "lib/features/admin/admin_dashboard.dart"
M0122 = ("supabase/migrations/"
         "20260927000122_the_admin_can_actually_take_something_down.sql")
M0121 = ("supabase/migrations/"
         "20260927000121_every_transaction_leaves_a_document.sql")


def replace_in(rel: str, old: str, new: str):
    """A mutation that asserts its anchor exists in the copy.

    A falsifier anchored on a string a later edit removed replaces nothing and
    passes while proving nothing.
    """
    def mutate(dest: pathlib.Path):
        p = dest / rel
        text = p.read_text(encoding="utf-8")
        if old not in text:
            raise AssertionError(
                f"falsifier anchor missing in {rel}: {old[:70]!r} -- the shape "
                f"it was written for no longer exists, so this case would "
                f"replace nothing and pass while proving nothing")
        p.write_text(text.replace(old, new, 1), encoding="utf-8")
    return mutate


CASES: list[tuple[str, str, object, bool]] = [
    (
        "A. baseline: the real repo passes",
        "the check reports nothing because the defect is fixed",
        lambda dest: None,
        True,
    ),
    (
        "B. the category-fee screen goes back to writing _canEdit after setState",
        "the original defect. The flag never reaches the widget, every control "
        "gated on it is dead, no category can be selected and the screen tells "
        "the OWNER that only the owner may edit -- which is what 'the icon is "
        "there but it does not open' looked like from the sidebar",
        replace_in(
            SCREEN,
            "      final canEdit = await _readEditorFlag();\n"
            "      if (!mounted) return;\n"
            "      setState(() {\n"
            "        _rows = List<Map<String, dynamic>>.from(rows as List);\n"
            "        _canEdit = canEdit;\n"
            "        _loading = false;\n"
            "      });",
            "      if (!mounted) return;\n"
            "      setState(() {\n"
            "        _rows = List<Map<String, dynamic>>.from(rows as List);\n"
            "        _loading = false;\n"
            "      });\n"
            "      _canEdit = await _readEditorFlag();",
        ),
        False,
    ),
    (
        "C. the content-control sidebar card is deleted",
        "the functions and the screen stay, and there is no way in -- the "
        "shape a whole admin section usually dies in",
        replace_in(DASH, "'/admin/content'", "'/admin/content-disabled'"),
        False,
    ),
    (
        "D. the content-control route is deleted",
        "same defect one layer down: the screen exists with no route",
        replace_in("lib/routing/app_router.dart",
                   "'/admin/content'", "'/admin/content-hidden'"),
        False,
    ),
    (
        "E. the image takedown loses its admin guard",
        "a function that removes a customer's photograph and is callable by "
        "any signed-in account. This is the check that says so, and it is the "
        "one that must never be silenced",
        replace_in(
            M0122,
            "  IF NOT public.is_admin() THEN\n    RAISE EXCEPTION 'ADMIN_ONLY';\n  END IF;\n\n  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN",
            "  IF length(btrim(coalesce(p_reason, ''))) < 3 THEN",
        ),
        False,
    ),
    (
        "F. the bucket membership test goes back to `<> ANY`",
        "AND-semantics: a bucket that IS on the list reads as not moderable, "
        "so every takedown fails with THAT_BUCKET_IS_NOT_MODERABLE and the "
        "section is dead on arrival. This is a bug that reads as correct",
        replace_in(M0122, "p_bucket <> ALL (ARRAY[", "p_bucket <> ANY (ARRAY["),
        False,
    ),
    (
        "G. the slip bucket is created public",
        "a slip carries a delivery address and two phone numbers, and a "
        "public bucket serves it to anyone who can guess the path",
        replace_in(
            M0121,
            "VALUES ('transaction-slips', 'transaction-slips', false, 5242880,",
            "VALUES ('transaction-slips', 'transaction-slips', true, 5242880,",
        ),
        False,
    ),
    (
        "H. the document reader's OR-chain loses its parentheses",
        "`AND` binds tighter than `OR`, so a CUSTOMER's documents ignore "
        "p_subject_type and p_subject_id and asking for one order returns "
        "every order they have ever placed",
        replace_in(
            M0121,
            "   WHERE (d.customer_user_id = (SELECT auth.uid())\n"
            "       OR d.provider_user_id = (SELECT auth.uid()))\n",
            "   WHERE d.customer_user_id = (SELECT auth.uid())\n"
            "      OR d.provider_user_id = (SELECT auth.uid())\n",
        ),
        False,
    ),
    (
        "I. the document trigger moves to BEFORE INSERT",
        "the document records the status the subject has not reached yet, and "
        "a transaction that rolls back leaves a slip for an order that never "
        "existed",
        replace_in(
            M0121,
            "  AFTER INSERT ON public.order_status_history",
            "  BEFORE INSERT ON public.order_status_history",
        ),
        False,
    ),
]


def _run(dest: pathlib.Path) -> tuple[list[str], bool]:
    """Run the three checks against `dest`. Returns (problems, ran_ok)."""
    code = (
        "import sys, json; sys.path.insert(0, %r); import static_checks as s;"
        "print(json.dumps("
        "s.check_permission_flags_reach_the_widget()"
        "+ s.check_content_control_is_wired()"
        "+ s.check_transaction_documents_are_wired()))"
        % str(dest / "tools" / "harness")
    )
    proc = subprocess.run(
        [sys.executable, "-c", code],
        cwd=str(dest), capture_output=True, text=True)
    if proc.returncode != 0:
        return [f"the harness itself failed: {proc.stderr.strip()[:400]}"], False
    import json
    try:
        return json.loads(proc.stdout.strip().splitlines()[-1]), True
    except Exception as exc:  # noqa: BLE001
        return [f"unparseable harness output: {exc}", proc.stdout[:200]], False


def _with_copy(mutate):
    tmp = tempfile.mkdtemp(prefix="falsify-permflag-")
    dest = pathlib.Path(tmp) / "repo"
    try:
        shutil.copytree(
            ROOT, dest,
            ignore=shutil.ignore_patterns(
                ".git", "__pycache__", "build", ".dart_tool", "ios", "android"))
        mutate(dest)
        return _run(dest)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    failures = 0
    for name, why, mutate, expect_green in CASES:
        try:
            problems, ran_ok = _with_copy(mutate)
        except AssertionError as exc:
            print(f"[BROKEN] {name}\n  falsifier itself failed: {exc}")
            failures += 1
            continue
        if not ran_ok:
            print(f"[BROKEN] {name}\n  {problems[0]}")
            failures += 1
            continue
        green = not problems
        if green == expect_green:
            print(f"[ok]     {name}")
            for p in problems[:2]:
                print(f"           -> {p[:130]}")
        else:
            want = "clean" if expect_green else "a finding"
            print(f"[FAILED] {name}\n  the check was {want} but reported:")
            for p in problems[:3]:
                print(f"           {p[:160]}")
            failures += 1

    total = len(CASES)
    if failures:
        print(f"\n{failures}/{total} falsification cases did not behave as "
              f"required")
        return 1
    print(f"\n{total}/{total} falsification cases behaved as required")
    return 0


if __name__ == "__main__":
    sys.exit(main())