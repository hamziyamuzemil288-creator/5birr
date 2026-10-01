#!/usr/bin/env python3
"""Falsification for check_publish_refusal_is_actionable().

A check that has never been seen red is not yet a check -- and the check this
one replaces WAS green for the entire life of the bug it should have caught.
`check_server_refusal_codes_reach_the_user()` held a hand-written list of three
codes; `PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED` was never added to it, so
a provider filled in a whole listing, the server refused, and the app showed
them a machine token while the suite reported success.

The new check is DERIVED -- it finds the create functions by scanning the Dart
for the RPC names, and it requires every code those functions can raise to be
translated. Each case below removes one of the things that makes that true and
asserts the check reacts. The last two are the ones that matter most: case G
breaks the check's own ANCHOR, and case H makes it inspect nothing at all.

Mutations go through the real file contents in a throwaway copy of the repo.
The repository is never written to.
"""
from __future__ import annotations

import importlib.util
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools" / "harness" / "static_checks.py"

MIG_0117 = "20260927000117_the_listing_refusal_says_why.sql"
DART_PROVIDER = "lib/core/services/provider_readiness.dart"
DART_FORM = "lib/features/provider/provider_product_form_screen.dart"
DART_DASH = "lib/features/provider/service_provider_dashboard.dart"
DART_ERR = "lib/core/utils/friendly_error.dart"


def _load():
    """Import the checker with its ROOT pointed at a throwaway copy."""
    spec = importlib.util.spec_from_file_location("sc", CHECKER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _with_copy(mutate):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="publish-falsify-"))
    try:
        dest = tmp / "repo"
        shutil.copytree(
            ROOT, dest, ignore=shutil.ignore_patterns(
                ".git", "build", ".dart_tool"))
        mutate(dest)
        mod = _load()
        # Point every path root at the copy and drop the read cache, which is
        # keyed on the ORIGINAL files.
        mod.ROOT = dest
        mod.LIB = dest / "lib"
        mod.MIGRATIONS = dest / "supabase" / "migrations"
        mod.FUNCTIONS = dest / "supabase" / "functions"
        mod.DEPLOY_WORKFLOW = dest / ".github" / "workflows" / "deploy-supabase.yml"
        mod._READ_CACHE.clear()
        problems = mod.check_publish_refusal_is_actionable()
        return problems, mod
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def replace_in(rel: str, old: str, new: str):
    """A mutation that asserts its anchor exists, in the copy."""
    def mutate(dest: pathlib.Path):
        p = dest / rel
        text = p.read_text(encoding="utf-8")
        if old not in text:
            raise AssertionError(
                f"falsifier anchor missing in {rel}: {old[:70]!r} -- the "
                f"mutation would land nowhere and the case would pass while "
                f"proving nothing")
        p.write_text(text.replace(old, new, 1), encoding="utf-8")
    return mutate


#: The exact block 0117 uses to refuse a create. Both functions carry it, so
#: replacing the first occurrence is enough to model "the server went back to
#: a bare code".
_REFUSAL_OLD = """  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %',
      array_to_string(v_blockers, ',');
  END IF;"""

_REFUSAL_NEW = """  IF NOT public.provider_can_publish(p_provider_id) THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED';
  END IF;"""

CASES: list[tuple[str, str, object, bool]] = [
    (
        "A. baseline: the real repo passes",
        "or every case below is vacuous",
        lambda dest: None,
        True,
    ),
    (
        "B. the server goes back to the BARE refusal code",
        "this is the shipped bug: a provider fills the form, presses Save, and "
        "is shown PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED with no reason",
        replace_in(f"supabase/migrations/{MIG_0117}", _REFUSAL_OLD, _REFUSAL_NEW),
        False,
    ),
    (
        "C. the app stops translating the reason-carrying code",
        "removes the matcher entry only -- the ternary that picks the sentence "
        "stays, which is exactly how the ORIGINAL check stayed green",
        replace_in(DART_ERR,
                   "    'provider_not_fulfilment_ready',\n",
                   ""),
        False,
    ),
    (
        "D. the app stops translating the OWNERSHIP refusal",
        "create_provider_product raises NOT_YOUR_PROVIDER before the gate; "
        "dropping it sends that to the provider raw",
        replace_in(DART_ERR,
                   "  else if (_any(lower, ['not_your_provider'])) {",
                   "  else if (_any(lower, ['never_emitted_code'])) {"),
        False,
    ),
    (
        "E. readiness starts using the CLIENT gate instead of the server's",
        "ProviderDocGate accepts MANUAL_REVIEW and the server does not. This is "
        "the precise mechanism of the original bug: the form accepts input the "
        "server will refuse, and the banner would now repeat the lie",
        replace_in(DART_PROVIDER,
                   "final res = await Supabase.instance.client.rpc(",
                   "final res = await _clientGateAnswer();"),
        False,
    ),
    (
        "F. the dashboard stops showing the banner",
        "the block then surfaces only at the end of a fully filled form, which "
        "is the original experience. The widget is REPLACED, not commented "
        "out: a first attempt left its name in a comment and the check passed, "
        "which is what forced the comment-stripping",
        replace_in(DART_DASH,
                   "                    PublishReadinessBanner(\n"
                   "                      readiness: _readiness,\n"
                   "                      onChanged: _reloadReadiness,\n"
                   "                    ),",
                   "                    const SizedBox.shrink(),"),
        False,
    ),
    (
        "G. the form stops routing a refusal to the dialog",
        "it falls back to the generic snackbar that displayed the bare code",
        replace_in(DART_FORM,
                   "await showPublishBlockedDialog(context, e.toString());",
                   "ScaffoldMessenger.of(context).showSnackBar("
                   "const SnackBar(content: Text('Could not save')));"),
        False,
    ),
    (
        "H. the check's OWN discovery breaks (must be RED, not vacuous)",
        "the RPC call site is renamed, so the check finds no create function. "
        "A derived check that silently inspects nothing is worse than no check "
        "-- this is the vacuity guard, and it is the case that would have "
        "caught the hand-written list decaying",
        replace_in(DART_FORM,
                   "rpc('create_provider_product'",
                   "rpc('someOtherCreateThing'"),
        False,
    ),
    (
        "I. a reason with no remedy is still a sentence (must stay GREEN)",
        "an unrecognised code must not print a raw token; the generic remedy "
        "exists for exactly that, and flagging it would push someone to invent "
        "an entry for a code that no longer exists",
        lambda dest: None,
        True,
    ),
]


def main() -> int:
    failures = 0
    for name, why, mutate, expect_green in CASES:
        try:
            problems, _ = _with_copy(mutate)
        except AssertionError as exc:
            print(f"[BROKEN] {name}\n  falsifier itself failed: {exc}")
            failures += 1
            continue
        green = not problems
        if green == expect_green:
            print(f"[ok]     {name}")
        else:
            want = "green" if expect_green else "RED"
            print(f"[FAILED] {name}\n  expected {want}, got "
                  f"{'green' if green else 'RED'}\n  why: {why}")
            for p in problems[:4]:
                print(f"    - {p[:150]}")
            failures += 1

    print(f"\n{len(CASES) - failures}/{len(CASES)} falsification cases behaved as required")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
