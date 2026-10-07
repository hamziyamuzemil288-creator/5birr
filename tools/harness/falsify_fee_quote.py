#!/usr/bin/env python3
"""Falsification for check_quoted_fees_resolve_like_the_charge.

This check guards a real money bug that shipped to review green: the checkout
quoted the GLOBAL commission while the wallet was debited with the provider's
category and city, behind a comment asserting the two "could not drift".

Case E is the one worth reading. The FIRST fix for that bug passed every
other assertion and was still wrong, because the quote ran before the provider
read that supplies the category and city. Both were null, the RPC inherited
the global rate, and the call looked right. A check that only asks "is the
right function named" would have been satisfied by that fix.

Nothing writes to the repo: `static_checks._read` is overridden.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

CHECKOUT = "lib/features/user/user_checkout_screen.dart"
RIDE = "lib/features/user/user_ride_request_screen.dart"
SUB = "lib/features/provider/provider_subscription_screen.dart"
#: The shared fee resolver (item H). The ride-fare quote lives here now, so
#: the ride cases below patch THIS file: the invariant did not move, the code
#: did, and a falsifier that kept patching the screen would have stopped
#: testing anything the moment the screen stopped containing the RPC name.
RESOLVER = "lib/core/services/fee_resolver.dart"


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
        return sc.check_quoted_fees_resolve_like_the_charge()
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

    checkout = sc._read(sc.LIB / "features" / "user" / "user_checkout_screen.dart")

    # A. the original defect, restored exactly: the one-argument global quote.
    #    The quote now resolves inside FeeResolver, so the patch moves there —
    #    the defect is the same, the file holding it is not.
    checkout_resolver = sc._read(sc.LIB / "core" / "services" / "fee_resolver.dart")
    ok &= expect_red(
        "A: the checkout reverts to the global-rate quote",
        {RESOLVER: checkout_resolver.replace(
            "rpc('platform_transaction_fee_for'",
            "rpc('platform_transaction_fee'")})

    # B. the rate class flag is dropped, so an order is quoted as a product.
    ok &= expect_red(
        "B: the quote stops passing isProduct",
        {CHECKOUT: checkout.replace("isProduct: true,", "")})

    # C. THE ONE THAT MATTERS. The first fix named the right function and
    #    passed everything else, but the quote still ran before the provider
    #    read that supplies category and city, so both were null and the RPC
    #    inherited the global rate. Nothing in the code looked wrong. The
    #    checkout now resolves the provider context itself and HANDS it to the
    #    quote, so the defect is "resolve the context, then do not pass it" —
    #    which is what this patch restores.
    reordered = checkout.replace(
        "          final ctx =\n"
        "              await FeeResolver.instance.providerContext(widget.providerId);\n",
        "", 1)
    if reordered == checkout:
        raise AssertionError(
            "falsifier anchor missing: providerContext call not found")
    ok &= expect_red(
        "C: the quote loses the provider context it resolves (the first-fix bug)",
        {CHECKOUT: reordered})

    # D. the server stops charging per-category at all.
    target, _ = sc.last_migration_defining("deduct_transaction_fee")
    fees = sc._read(target)
    ok &= expect_red(
        "D: deduct_transaction_fee() stops charging per category/city",
        {target.name: fees.replace("platform_transaction_fee_for(",
                                    "platform_transaction_fee(")})

    # E. the ride fare reverts to the five-argument wrapper, which hardcodes
    #    p_city to NULL. Identical drift, second surface. The quote lives in
    #    the resolver now, so that is what is patched.
    ride = sc._read(sc.LIB / "features" / "user" / "user_ride_request_screen.dart")
    resolver = sc._read(sc.LIB / "core" / "services" / "fee_resolver.dart")
    ok &= expect_red(
        "E: the ride fare reverts to the city-blind wrapper",
        {RESOLVER: resolver.replace("'calculate_fare_estimate_at'",
                                    "'calculate_fare_estimate'")})

    # F. the city-aware call survives but stops passing the city, so it
    #    resolves exactly as the old wrapper did -- the function name looks
    #    right and the behaviour does not.
    ok &= expect_red(
        "F: the city-aware ride fare is called without p_city",
        {RESOLVER: resolver.replace(
            "        if (city != null) 'p_city': city,\n", "")})

    # G. the fallback goes, so a deployment that has not run 0107 shows
    #    "Fare unavailable" on every ride.
    ok &= expect_red(
        "G: the pre-0107 fare fallback is removed",
        {RESOLVER: resolver.replace("rpc('calculate_fare_estimate',",
                                    "rpc('no_such_fare_reader',")})

    # J. THE SHARED-RESOLVER CONTRACT (item H). The ride screen quotes the
    #    RIGHT function name but calls it itself, so the screen and the
    #    resolver are two copies of the fare path again -- exactly the drift
    #    the single-resolver rule exists to remove.
    ok &= expect_red(
        "J: the ride screen calls the fare RPC itself",
        {RIDE: ride.replace(
            "FeeResolver.instance.rideFare(",
            "Supabase.instance.client.rpc('calculate_fare_estimate_at',")})

    # H. the subscription screen reverts to the flat global amount -- the
    #    third surface, and the one whose whole job is stating the number.
    sub = sc._read(sc.LIB / "features" / "provider"
                   / "provider_subscription_screen.dart")
    ok &= expect_red(
        "H: the subscription screen states the flat global fee again",
        {SUB: sub.replace("'fee_subscription'", "'system_settings_only'")})

    # I. the per-category quote is resolved and then thrown away by the flat
    #    setting, which is the subtler half of the same bug.
    ok &= expect_red(
        "I: the flat setting overwrites the per-category subscription fee",
        {SUB: sub.replace("            if (fee == 0) fee = parsed;",
                          "            fee = parsed;")})

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
