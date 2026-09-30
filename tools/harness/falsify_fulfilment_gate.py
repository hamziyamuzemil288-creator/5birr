#!/usr/bin/env python3
"""Falsification for check_provider_fulfilment_gate_is_wired.

Two real defects are guarded here, and both shipped green:

  * the document half of the gate was satisfied by UPLOADING an ID, because
    `provider_docs_satisfied()` admits MANUAL_REVIEW and a document row is
    born in that state (column default + a BEFORE INSERT trigger);
  * `claim_ride` and `transition_order_status` never consulted the gate at
    all, so an unfunded, unreviewed provider could take a rider's trip.

Case B is the subtle one and is why this suite exists rather than a grep: a
check that merely looks for the string `MANUAL_REVIEW` in the predicate is
satisfied by the comment explaining why it is excluded.

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

GATE = "20260927000113_provider_fulfilment_gate.sql"
# claim_ride is restated again by 0114 (which added the rider notification),
# so mutating 0113's copy proves nothing -- `last_migration_defining` resolves
# to 0114. A falsifier aimed at a superseded definition stays green forever,
# which is its own kind of lie.
CLAIM = "20260927000114_the_other_side_is_told.sql"
ERR = "lib/core/utils/friendly_error.dart"


def with_patches(patches: dict[str, str]) -> list[str]:
    def _read(path: Path) -> str:
        try:
            rel = str(path).replace("\\", "/")
        except Exception:
            rel = ""
        for suffix, text in patches.items():
            if rel.endswith(suffix):
                return text
        return _real_read(path)

    sc._read = _read
    try:
        return sc.check_provider_fulfilment_gate_is_wired()
    finally:
        sc._read = _real_read


def expect_red(label: str, patches: dict[str, str]) -> bool:
    problems = with_patches(patches)
    if problems:
        print("[ ok ] %s -> caught" % label)
        for p in problems:
            print("         - " + p)
        return True
    print("[FAIL] %s -> stayed GREEN" % label)
    return False


def main() -> int:
    ok = True

    base = with_patches({})
    if base:
        print("[FAIL] the real sources are already red:")
        for p in base:
            print("         - " + p)
        return 1
    print("[ ok ] real sources are green")

    gate = sc._read(sc.MIGRATIONS / GATE)
    err = sc._read(sc.LIB / "core" / "utils" / "friendly_error.dart")

    # A. the whole gate is gone.
    ok &= expect_red(
        "A: provider_fulfilment_blockers() is not defined at all",
        {GATE: gate.replace(
            "CREATE OR REPLACE FUNCTION public.provider_fulfilment_blockers",
            "CREATE OR REPLACE FUNCTION public.not_the_gate")})

    # B. THE SUBTLE ONE. "Verified" goes back to meaning "uploaded": the
    #    strict predicate starts admitting MANUAL_REVIEW again. A check that
    #    only grepped for the token would stay green on this, because the
    #    string is still present in the explanation either way.
    ok &= expect_red(
        "B: provider_documents_verified() admits MANUAL_REVIEW again",
        {GATE: gate.replace(
            "       AND COALESCE(d.verification_status, 'MANUAL_REVIEW')\n"
            "             IN ('AUTO_APPROVED', 'VERIFIED')",
            "       AND COALESCE(d.verification_status, 'MANUAL_REVIEW')\n"
            "             IN ('MANUAL_REVIEW', 'AUTO_APPROVED', 'VERIFIED')")})

    # C. claim_ride loses the gate -- the ride-claim hole, reopened. Aimed at
    #    0114, which is now the newest definition of claim_ride.
    claim = sc._read(sc.MIGRATIONS / CLAIM)
    ok &= expect_red(
        "C: claim_ride stops consulting the fulfilment gate",
        {CLAIM: claim.replace("  v_blockers := public.provider_fulfilment_blockers("
                              "p_provider_id);", "  v_blockers := '{}'::text[];")})

    # D. order acceptance loses it too.
    ok &= expect_red(
        "D: transition_order_status stops consulting the gate",
        {GATE: gate.replace(
            "  IF v_actor_is_provider AND NOT v_actor_is_admin THEN", "  IF false THEN")})

    # E. the activation fee stops being part of the gate.
    ok &= expect_red(
        "E: the activation fee is no longer a blocker",
        {GATE: gate.replace("v_out := v_out || ARRAY['ACTIVATION_FEE_UNPAID']"
                            "::text[];", "NULL;")})

    # F. an empty wallet stops being a blocker -- the failure then surfaces
    #    later, at the moment a buyer is waiting.
    ok &= expect_red(
        "F: an empty wallet is no longer a blocker",
        {GATE: gate.replace("v_out := v_out || ARRAY['WALLET_EMPTY']::text[];",
                            "NULL;")})

    # G. the listing path goes back to the weaker rule by no longer
    #    delegating, which is how the two rules drift apart silently.
    ok &= expect_red(
        "G: provider_can_publish no longer delegates to the gate",
        {GATE: gate.replace("  SELECT public.provider_can_fulfil(p_provider_id);",
                            "  SELECT EXISTS (SELECT 1 FROM public.provider_profiles"
                            " WHERE id = p_provider_id);")})

    # H. the provider is told only that something went wrong.
    ok &= expect_red(
        "H: the client cannot explain PROVIDER_NOT_FULFILMENT_READY",
        {ERR: err.replace("['provider_not_fulfilment_ready']", "['never_matches']")})

    if not ok:
        print("\nFALSIFICATION FAILED")
        return 1

    if with_patches({}):
        print("\n[FAIL] the real sources went red")
        return 1
    print("\n[ ok ] real sources still green")
    print("FALSIFICATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
