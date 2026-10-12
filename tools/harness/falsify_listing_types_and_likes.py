# fmt: off
"""A falsifier for the two checks this round added.

    * a listing takes its own type from its own category (the BUY vs BOOK
      report, third time: the button logic was right and the column was never
      written), and
    * the like/dislike buttons are on every listing card and reflect the
      reader (reported removed; they were there, but three surfaces never
      hydrated the caller's own reaction, so the heart always rendered empty).

A check that passes over the tree as it stands proves nothing on its own — the
previous round's checks were green over a database that stored every service as
a PRODUCT. So this copies the tree the checks read into a scratch directory,
confirms both checks pass there, then reintroduces one real regression at a time
and requires each one to make a check FAIL. The working tree is never modified:
the scratch copy is what gets edited.

Run:  python3 tools/harness/falsify_listing_types_and_likes.py
"""
from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HARNESS = Path(__file__).resolve().parent / "static_checks.py"

MIGRATION = ("supabase/migrations/"
             "20261012000001_every_listing_carries_its_own_type_from_its_category.sql")

# (what regression this reintroduces, file, [(substring to cut, text to paste)])
MUTATIONS = [
    ("the write path stops stamping listing_type, so every service is stored as "
     "a PRODUCT again (the exact original defect)",
     MIGRATION, [("NEW.listing_type := v_type;", "")]),
    ("the backfill is dropped, so the rows that are already wrong stay wrong",
     MIGRATION, [("LISTING_TYPE_BACKFILL_INCOMPLETE", "")]),
    ("search stops resolving the missing column the DEPLOYED search_products "
     "does not project, so every service found by search reads BUY until a "
     "deploy happens",
     "lib/features/user/user_search_screen.dart", [("inFilter('id', ids)", "")]),
    ("a cart line stops carrying the listing's type, so a booking is not "
     "recognisable as one at checkout",
     "lib/core/services/cart_service.dart", [("bool get isBooking {", "")]),
    ("checkout demands a delivery address for a basket of bookings again",
     "lib/features/user/user_checkout_screen.dart",
     [("items.every((i) => i.isBooking)) {", "")]),
    ("the shared card loses the thumb-down",
     "lib/core/widgets/product_card.dart", [("DislikeButton(", "")]),
    # A MOVE, not a removal: the count stays 1 and only the layout rule is
    # broken, so this one is caught by the row invariant itself.
    ("a reaction is moved into the BUY/BOOK row",
     "lib/core/widgets/product_card.dart",
     [("                        DislikeButton(\n"
       "                            productId: _data.id,\n"
       "                            fallbackCount: _data.likeCount),\n", ""),
      ("                      ProductBuyButton(",
       "                      DislikeButton(\n"
       "                        productId: _data.id,\n"
       "                        fallbackCount: _data.likeCount),\n"
       "                      ProductBuyButton(")]),
    ("a card surface stops hydrating the reader's own reactions, so an "
     "already-liked listing renders an empty heart",
     "lib/features/user/user_provider_detail_screen.dart",
     [("ProductLikeService.instance.ensureLoaded(", "")]),
    ("the provider is asked whether a booking is \"AVAILABLE\" again",
     "lib/features/provider/service_provider_dashboard.dart",
     [("ACCEPT BOOKING", "")]),
]

CHECKS = ("check_every_listing_takes_its_type_from_its_category",
          "check_like_and_dislike_are_offered_wherever_a_listing_is")


def _load():
    """A fresh static_checks bound to a scratch copy of the tree."""
    scratch = Path(tempfile.mkdtemp(prefix="falsify-types-likes-"))
    for rel in ("lib", "supabase/migrations", "supabase/functions",
                ".github/workflows", "tools/integration_test", "docs"):
        src = ROOT / rel
        if src.exists():
            shutil.copytree(src, scratch / rel)

    spec = importlib.util.spec_from_file_location("sc_falsify", HARNESS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # The checks read the tree through these module globals.
    module.ROOT = scratch
    module.LIB = scratch / "lib"
    module.MIGRATIONS = scratch / "supabase" / "migrations"
    module.FUNCTIONS = scratch / "supabase" / "functions"
    module.DEPLOY_WORKFLOW = scratch / ".github" / "workflows" / "deploy-supabase.yml"
    module._READ_CACHE.clear()
    return scratch, module


def _run(module) -> list[str]:
    problems: list[str] = []
    for name in CHECKS:
        problems += ["%s: %s" % (name, p) for p in getattr(module, name)()]
    return problems


def main() -> int:
    failures = 0

    scratch, module = _load()
    problems = _run(module)
    if problems:
        failures += 1
        print("[FAIL] the tree as it stands fails the checks it is supposed to "
              "defend")
        for p in problems:
            print("         - %s" % p)
    else:
        print("[PASS] both checks pass over the working tree")
    shutil.rmtree(scratch, ignore_errors=True)

    for label, rel, edits in MUTATIONS:
        scratch, module = _load()
        path = scratch / rel
        text = path.read_text(encoding="utf-8")
        missing = [needle for needle, _ in edits if needle not in text]
        if missing:
            failures += 1
            print("[FAIL] mutation does not apply (the code moved): %s" % label)
            for needle in missing:
                print("         - %r is not in %s" % (needle, rel))
        else:
            for needle, replacement in edits:
                text = text.replace(needle, replacement, 1)
            path.write_text(text, encoding="utf-8")
            module._READ_CACHE.clear()
            found = _run(module)
            if found:
                print("[PASS] caught: %s" % label)
                print("         - %s" % found[0])
            else:
                failures += 1
                print("[FAIL] NOT caught: %s" % label)
        shutil.rmtree(scratch, ignore_errors=True)

    print()
    if failures:
        print("FALSIFIER FAILED (%d)" % failures)
        return 1
    print("FALSIFIER OK: %d regression(s), each one caught" % len(MUTATIONS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
