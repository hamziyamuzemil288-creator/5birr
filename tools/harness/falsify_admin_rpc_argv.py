#!/usr/bin/env python3
"""Falsifier for check_admin_rpc_argv_is_transcribed().

This check exists because `admin_rpc_signature_report()` carries a hand-written
copy of the parameter names each admin RPC is called with. That copy is the
second copy of a list the Dart already states, and it had already rotted: the
fee editor sent `p_booking_base_fare` while the database has declared
`p_booking_base_fee` since 0107. PostgREST matches named arguments by name, so
every save was a PGRST202, which `friendlyError` renders as "the category may
have been removed". The check found it -- but only after the collection-for
branch was taught to read the declared `_FeeField` lists instead of skipping
them, which is exactly the branch that had been hiding it.

A check that has never been seen red is not yet a check. Each case below
mutates a copy of the tree and asserts the check reports the specific defect,
then asserts the anchor it relies on actually existed in the mutant -- so a
broken anchor reports a falsifier failure rather than a silent green.
"""
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

import static_checks as sc  # noqa: E402

SCREEN = "lib/features/admin/category_fee_settings_screen.dart"
MIG = "supabase/migrations/20260927000124_every_admin_write_path_is_reachable.sql"

# A well-formed screen, reduced to the shapes the check reads.
GOOD_SCREEN = """
const List<_FeeField> _rideFields = [
  _FeeField(param: 'p_ride_base_fare', label: 'Base fare'),
  _FeeField(param: 'p_ride_per_km', label: 'Per km'),
];
const List<_FeeField> _bookingFields = [
  _FeeField(param: 'p_booking_base_fee', label: 'Booking base'),
];

Future<void> _save() async {
  await Supabase.instance.client.rpc('admin_save_category_fee', params: {
    'p_category_id': id,
    'p_city': city,
    for (final f in [
      ..._rideFields,
      ..._bookingFields,
    ])
      f.param: parse(f.param),
  });
}

Future<void> _clear() async {
  await Supabase.instance.client.rpc('admin_clear_category_fee', params: {
    'p_category_id': id,
    'p_city': city,
  });
}
"""

GOOD_SQL = """
  VALUES
    ('admin_save_category_fee',
     'public.admin_save_category_fee(uuid,text)',
     '{p_category_id,p_city,p_ride_base_fare,p_ride_per_km,p_booking_base_fee}'),
    ('admin_clear_category_fee',
     'public.admin_clear_category_fee(uuid,text)',
     '{p_category_id,p_city}')
"""


class Tree:
    """A throwaway copy of the repo with the files this check reads."""

    def __init__(self):
        self.dir = Path(tempfile.mkdtemp(prefix="falsify_argv_"))
        (self.dir / "lib/features/admin").mkdir(parents=True)
        (self.dir / "supabase/migrations").mkdir(parents=True)
        self.screen = self.dir / SCREEN
        self.sql = self.dir / MIG
        self.screen.write_text(GOOD_SCREEN)
        self.sql.write_text(GOOD_SQL)
        self._orig = (sc.ROOT, sc.LIB)

    def __enter__(self):
        sc.ROOT = self.dir
        sc.LIB = self.dir / "lib"
        return self

    def __exit__(self, *exc):
        sc.ROOT, sc.LIB = self._orig
        shutil.rmtree(self.dir, ignore_errors=True)
        return False

    def run(self):
        return sc.check_admin_rpc_argv_is_transcribed()


CASES = []


def case(name):
    def deco(fn):
        CASES.append((name, fn))
        return fn
    return deco


@case("baseline: the well-formed tree reports nothing")
def _baseline(t):
    problems = t.run()
    assert problems == [], "clean tree reported %r" % (problems,)


@case("A: a renamed declared field is caught (the live p_booking_base_fare bug)")
def _renamed_field(t):
    """This is the defect as it actually shipped."""
    src = t.screen.read_text()
    assert "param: 'p_booking_base_fee'" in src, "anchor missing from mutant"
    t.screen.write_text(src.replace("param: 'p_booking_base_fee'",
                                    "param: 'p_booking_base_fare'"))
    problems = t.run()
    assert any("admin_save_category_fee" in p and "field" in p
               for p in problems), \
        "renaming a collection-for field went unreported: %r" % (problems,)


@case("B: a field dropped from a declared list is caught")
def _dropped_field(t):
    src = t.screen.read_text()
    assert "_FeeField(param: 'p_ride_per_km', label: 'Per km')," in src, \
        "anchor missing from mutant"
    t.screen.write_text(src.replace(
        "  _FeeField(param: 'p_ride_per_km', label: 'Per km'),\n", ""))
    problems = t.run()
    assert any("admin_save_category_fee" in p for p in problems), \
        "dropping a declared field went unreported: %r" % (problems,)


@case("C: an extra field added to a declared list is caught")
def _extra_field(t):
    src = t.screen.read_text()
    assert "const List<_FeeField> _bookingFields = [" in src, \
        "anchor missing from mutant"
    t.screen.write_text(src.replace(
        "const List<_FeeField> _bookingFields = [",
        "const List<_FeeField> _bookingFields = [\n"
        "  _FeeField(param: 'p_nonexistent_fee', label: 'Nope'),"))
    problems = t.run()
    assert any("admin_save_category_fee" in p for p in problems), \
        "an undeclared parameter went unreported: %r" % (problems,)


@case("D: an extra LITERAL key beside the loop is caught")
def _extra_literal(t):
    src = t.screen.read_text()
    assert "    'p_city': city,\n" in src, "anchor missing from mutant"
    t.screen.write_text(src.replace(
        "    'p_city': city,\n",
        "    'p_city': city,\n    'p_typo_fare': 1,\n"))
    problems = t.run()
    assert any("admin_save_category_fee" in p for p in problems), \
        "an extra literal key went unreported: %r" % (problems,)


@case("E: 0124 drifting away from the client is caught")
def _sql_drift(t):
    src = t.sql.read_text()
    assert "{p_category_id,p_city,p_ride_base_fare,p_ride_per_km," \
           "p_booking_base_fee}" in src, "anchor missing from mutant"
    t.sql.write_text(src.replace("p_ride_per_km,", "p_ride_per_mile,"))
    problems = t.run()
    assert any("admin_save_category_fee" in p for p in problems), \
        "0124 drifting from the client went unreported: %r" % (problems,)


@case("F: a function the app no longer calls is caught")
def _uncalled(t):
    src = t.screen.read_text()
    assert "'admin_clear_category_fee'" in src, "anchor missing from mutant"
    t.screen.write_text(src.replace(
        ".rpc('admin_clear_category_fee', params: {",
        ".rpc('admin_clear_category_fee_X', params: {"))
    problems = t.run()
    assert any("admin_clear_category_fee" in p and "no Dart file calls it" in p
               for p in problems), \
        "an uncalled function went unreported: %r" % (problems,)


@case("G: a function called but absent from 0124 is NOT invented")
def _no_false_positive(t):
    """A clean tree must stay clean; the check must not manufacture findings."""
    assert t.run() == [], "clean tree was not clean"


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
    print("\nfalsify_admin_rpc_argv: %d/%d cases green"
          % (len(CASES) - len(failed), len(CASES)))
    if failed:
        print("FAILED: %s" % ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
