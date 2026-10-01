#!/usr/bin/env python3
"""Falsifier for check_grantable_permissions_open_something().

This check exists because `document_verification` was seeded into `staff_jobs`
in 20260927000034, labelled "Review identity documents and record a verified or
rejected decision", and offered in the admin staff screen's checklist -- and
gated absolutely nothing. No screen consulted it, because the only route to
`review_user_document()` was a dialog inside one user row on the Users page,
behind the `registrations` key instead. A CEO could assign it and the assignee
would see no difference at all.

The hard part is not detecting that key but *not* reporting 63 others. The first
version of this check scanned every `('x', 'y', ...)` tuple in all 220
migrations and reported fee names, category slugs, trigger names and GRANT roles
as dead permissions. A check that reports everything is as useless as one that
reports nothing, so the narrowing is itself what these cases defend.

A check that has never been seen red is not yet a check. Each case mutates a
copy of the tree, asserts the anchor it relies on existed in the mutant, and
requires the specific defect to be reported.
"""
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

import static_checks as sc  # noqa: E402

MIGRATION = "20260927000034_staff_job_catalogue_and_assignment.sql"

CATALOGUE = """
-- 20260927000034 -- staff job catalogue
INSERT INTO public.staff_jobs (key, label, description, group_name, sort_order)
VALUES
  ('registrations', 'Registrations', 'Approve sign-ups.', 'Verification', 10),
  ('document_verification', 'Document verification',
   'Review identity documents.', 'Verification', 20),
  ('view_reports', 'View reports', 'Read the dashboards.', 'Oversight', 70)
ON CONFLICT (key) DO NOTHING;
"""

# What the app's own staff checklist offers, and what the dashboard gates on.
STAFF_SCREEN = """
class StaffScreen {
  static const _permissionOptions = {
    'registrations': 'Registrations',
    'document_verification': 'Document verification',
    'view_reports': 'View reports',
  };
}
"""

DASHBOARD_GOOD = """
class AdminDashboard {
  bool _can(String perm) => perms.contains(perm);

  Widget build(BuildContext context) {
    if (_can('registrations'))
      return Text('Registrations');
    if (_can('document_verification'))
      return Text('Document verification');
    if (_can('view_reports'))
      return Text('View reports');
    return Text('nothing');
  }
}
"""


class Tree:
    """A throwaway copy of the repo with the three files this check reads."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="falsify_perm_"))
        (self.dir / "lib/features/admin").mkdir(parents=True)
        (self.dir / "supabase/migrations").mkdir(parents=True)
        self.mig = self.dir / "supabase/migrations" / MIGRATION
        self.screen = self.dir / "lib/features/admin/admin_staff_screen.dart"
        self.dash = self.dir / "lib/features/admin/admin_dashboard.dart"
        self.mig.write_text(CATALOGUE)
        self.screen.write_text(STAFF_SCREEN)
        self.dash.write_text(DASHBOARD_GOOD)
        self._orig = (sc.ROOT, sc.LIB, sc.MIGRATIONS)

    def __enter__(self):
        sc.ROOT = self.dir
        sc.LIB = self.dir / "lib"
        sc.MIGRATIONS = self.dir / "supabase/migrations"
        return self

    def __exit__(self, *exc):
        sc.ROOT, sc.LIB, sc.MIGRATIONS = self._orig
        shutil.rmtree(self.dir, ignore_errors=True)
        return False

    def run(self):
        return sc.check_grantable_permissions_open_something()


CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


@case("baseline: every offered permission gates something")
def _baseline(t):
    problems = t.run()
    assert problems == [], "clean tree reported %r" % (problems,)


@case("A: the live bug -- document_verification gated by nothing")
def _dead_key(t):
    """Exactly the defect: offered in the checklist, gating no screen."""
    src = t.dash.read_text()
    assert "_can('document_verification')" in src, "anchor missing from mutant"
    t.dash.write_text(src.replace(
        "    if (_can('document_verification'))\n"
        "      return Text('Document verification');\n", ""))
    problems = t.run()
    assert any("document_verification" in p for p in problems), \
        "a granted-but-ungated permission went unreported: %r" % (problems,)


@case("B: a catalogue key the checklist does not offer is not a finding")
def _not_offered(t):
    """`probe_customer_orders` and `password_reset` exist in staff_jobs but the
    CEO interface never lists them, so no user can assign them from the app."""
    src = t.mig.read_text()
    assert "ON CONFLICT (key) DO NOTHING;" in src, "anchor missing from mutant"
    t.mig.write_text(src.replace(
        "ON CONFLICT (key) DO NOTHING;",
        "  ('probe_customer_orders', 'Probe customer orders', 'Fixture.', "
        "'Oversight', 200)\nON CONFLICT (key) DO NOTHING;"))
    problems = t.run()
    assert problems == [], \
        "a key the app cannot grant was reported: %r" % (problems,)


@case("C: fee names and category slugs are NOT read as permissions")
def _no_wildcard(t):
    """The first version of this check reported 63 of these. They are VALUES
    tuples in unrelated migrations, and must never look like permissions."""
    src = t.mig.read_text()
    assert "INSERT INTO public.staff_jobs" in src, "anchor missing from mutant"
    t.mig.write_text(
        src
        + "\nINSERT INTO public.system_settings (key, value)\n"
          "VALUES ('ride_per_km', '12.00'), ('retail', 'Grocery'),\n"
          "       ('commission_percent', '5.00'), ('true', '(true)');\n"
          "GRANT EXECUTE ON FUNCTION f(text) TO service_role;\n")
    problems = t.run()
    assert problems == [], \
        "unrelated VALUES tuples were read as permissions: %r" % (problems,)


@case("D: the allowlist only excuses the key it names")
def _allowlist_is_narrow(t):
    """`view_auth_logs` is excused because no auth-event table exists. A
    DIFFERENT ungated key must still fail -- an allowlist that excuses
    everything is a suppression list.

    The new key is deliberately NOT `view_auth_logs`: adding that one to the
    checklist and expecting a failure is the wrong test, because excusing it is
    exactly what it is on the allowlist for. The first run of this case did
    precisely that and failed, which is the argument for writing these at all.
    """
    src = t.screen.read_text()
    assert "'view_reports': 'View reports'," in src, \
        "anchor missing from mutant"
    t.screen.write_text(src.replace(
        "'view_reports': 'View reports',",
        "'view_reports': 'View reports',\n    'wage_management': 'Wages',"))
    src2 = t.mig.read_text()
    assert "ON CONFLICT (key) DO NOTHING;" in src2, \
        "anchor missing from mutant"
    t.mig.write_text(src2.replace(
        "ON CONFLICT (key) DO NOTHING;",
        "  ('wage_management', 'Wages', 'Adjust staff wages.', 'Oversight', 210)\n"
        "ON CONFLICT (key) DO NOTHING;"))
    problems = t.run()
    assert any("wage_management" in p for p in problems), \
        "a new key escaped the allowlist and was silently excused: %r" % (problems,)


@case("E: a broken anchor is a falsifier failure, not a green check")
def _anchor_guard(t):
    """The catalogue insert removed entirely: the check must say it cannot
    read the catalogue, not report zero problems."""
    t.mig.write_text("-- nothing here\n")
    problems = t.run()
    assert problems and any("keys could be read" in p for p in problems), \
        "an unreadable catalogue was reported as clean: %r" % (problems,)


@case("F: a key gated through a different helper is still a gate")
def _alt_gate_shape(t):
    src = t.dash.read_text()
    assert "_can('view_reports')" in src, "anchor missing from mutant"
    t.dash.write_text(src.replace(
        "    if (_can('view_reports'))\n      return Text('View reports');\n",
        "    if (hasPermission('view_reports'))\n"
        "      return Text('View reports');\n"))
    problems = t.run()
    assert problems == [], \
        "a differently-shaped gate was missed: %r" % (problems,)


def main() -> int:
    failed = []
    for name, fn in CASES:
        try:
            with Tree() as tree:
                fn(tree)
            print("  ok   %s" % name)
        except AssertionError as exc:
            print("  FAIL %s\n         %s" % (name, exc))
            failed.append(name)
    print("\nfalsify_grantable_permission: %d/%d cases green"
          % (len(CASES) - len(failed), len(CASES)))
    if failed:
        print("FAILED: %s" % ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
