#!/usr/bin/env python3
"""Falsification for check_staff_management_is_reachable.

The user's standing instruction is that staff creation must never be removed
from the admin sidebar, so this check is the thing that notices if it is. A
check that has never been seen red is not yet a check.

Four cases, each removing exactly one guarantee:

  A. the "Staff / Sub-admins" card is deleted from the sidebar
  B. a sidebar card is left pointing at a route that no longer exists
  C. staff_scope_allows_city() is not defined at all
  D. the predicate exists and is MENTIONED but never tested in a WHERE clause
     -- the exact shape that made staff.city decorative in the first place

D is the important one: a check that only looked for the string would have
passed the broken version. This proves the WHERE-clause requirement bites.

Nothing here writes to the repo; `static_checks._read` is overridden.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

_real_read = sc._read

DASH = "lib/features/admin/admin_dashboard.dart"
ROUTER = "lib/routing/app_router.dart"
CITY_MIGRATION = "20260927000109_staff_city_scope_is_enforced.sql"
QUEUE_MIGRATION = "20260927000110_staff_city_guards_on_the_registration_queue.sql"


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
        return sc.check_staff_management_is_reachable()
    finally:
        sc._read = _real_read


QUEUE_MIGRATION = "20260927000110_staff_city_guards_on_the_registration_queue.sql"
ACTIONS_MIGRATION = "20260927000111_staff_city_guards_on_provider_actions.sql"
MONEY_MIGRATION = "20260927000112_staff_city_guards_on_money_and_task_feed.sql"

CREATE_RE = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(?:public\.)?(\w+)\s*\(", re.I)


def bodies(text: str) -> dict:
    """function name -> body between AS $$ and $$;  (last definition wins)"""
    out: dict = {}
    for m in CREATE_RE.finditer(text):
        i, d = m.end() - 1, 0
        while i < len(text):
            if text[i] == "(":
                d += 1
            elif text[i] == ")":
                d -= 1
                if d == 0:
                    i += 1
                    break
            i += 1
        b = text.find("$$", i)
        e = text.find("$$;", b)
        out[m.group(1)] = text[b + 2:e]
    return out


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

    dash = sc._read(sc.LIB / "features" / "admin" / "admin_dashboard.dart")
    router = sc._read(sc.LIB / "routing" / "app_router.dart")
    city = sc._read(sc.MIGRATIONS / CITY_MIGRATION)
    queue = sc._read(sc.MIGRATIONS / QUEUE_MIGRATION)
    actions = sc._read(sc.MIGRATIONS / ACTIONS_MIGRATION)

    # A. the staff creation card is deleted outright
    stripped = dash.replace("/admin/staff')", "/admin/somewhere-else')")
    ok &= expect_red("A: the Staff / Sub-admins card is deleted",
                     {DASH: stripped})

    # B. the card survives but its route does not
    ok &= expect_red("B: /admin/staff-assignment is no longer a route",
                     {ROUTER: router.replace(
                         "path: '/admin/staff-assignment'", "path: '/admin/gone'")})

    # C. the city predicate is not defined anywhere
    ok &= expect_red("C: staff_scope_allows_city() is not defined",
                     {CITY_MIGRATION: city.replace(
                         "CREATE OR REPLACE FUNCTION public.staff_scope_allows_city(",
                         "CREATE OR REPLACE FUNCTION public.not_the_city_scope(")})

    # D. the predicate is MENTIONED everywhere but enforced NOWHERE.
    #    Both migrations have to be neutered: 0010's three queue branches and
    #    0011's five provider actions. Neutering only one leaves the other
    #    enforcing, so the honest answer is still "yes, something enforces it".
    #    Turning them into comments keeps the name in the files, so a naive
    #    "is the string present" check would still pass this too.
    neutered_queue = queue
    for col in ("r.city", "pr.city", "st.city"):
        neutered_queue = neutered_queue.replace(
            "AND public.staff_scope_allows_city(coalesce(%s, ''), auth.uid())" % col,
            "-- public.staff_scope_allows_city(coalesce(%s, ''), auth.uid())" % col)

    neutered_actions = actions
    for col in ("r.city", "pr.city", "st.city"):
        neutered_actions = neutered_actions.replace(
            "OR NOT public.staff_scope_allows_city(\n"
            "            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id))",
            "-- public.staff_scope_allows_city(\n"
            "            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id))")

    ok &= expect_red(
        "D: the city guard is mentioned in 8 places and enforced in none",
        {QUEUE_MIGRATION: neutered_queue, ACTIONS_MIGRATION: neutered_actions})

    # E. ONE of the five provider lifecycle actions loses the guard. This is
    #    the "half a scope" case: the queue is filtered, the button is not.
    ok &= expect_red(
        "E: suspend_provider alone drops the city guard",
        {ACTIONS_MIGRATION: actions.replace(
            "       OR NOT public.staff_scope_allows_city(\n"
            "            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN\n"
            "      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';\n"
            "    END IF;\n"
            "  END IF;\n"
            "\n"
            "  UPDATE provider_profiles SET status = 'SUSPENDED'",
            "      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';\n"
            "    END IF;\n"
            "  END IF;\n"
            "\n"
            "  UPDATE provider_profiles SET status = 'SUSPENDED'")})

    # F. the pin is removed from the assertion. The five bodies would still
    #    carry the guard TODAY, so only the assertion pins it tomorrow.
    ok &= expect_red(
        "F: assert_admin_rpc_service_role_access stops pinning the city guard",
        {ACTIONS_MIGRATION: actions.replace(
            "      IF position('staff_scope_allows_city' in v_flat) = 0 THEN\n"
            "        RETURN false;\n"
            "      END IF;\n",
            "")})

    # G. a restatement copied from the STALE 00026 text silently drops the
    #    welcome notification as well as the guard -- the 00020 regression,
    #    re-run. This is the case that argues for basing approve_provider on
    #    00087 rather than 00026.
    stale = open("supabase/migrations/20260927000026_restore_staff_scope_on_provider_actions.sql",
                 encoding="utf-8", errors="replace").read()
    for fn in ("approve_provider",):
        stale_body = bodies(stale).get(fn, "")
        ok &= expect_red(
            "G: approve_provider restated from the stale 00026 text",
            {ACTIONS_MIGRATION: actions.replace(
                bodies(actions)["approve_provider"], stale_body)})

    # H. staff_task_feed -- the queue the city scope is judged by -- loses all
    #    three of its city guards, and nothing else is touched. This is the
    #    case the restated-body diff was written for: the feed would still
    #    parse, still exist, still enforce the CATEGORY scope, and would show
    #    an Addis Ababa task to a Hawassa manager.
    money = sc._read(sc.MIGRATIONS / MONEY_MIGRATION)
    neutered_feed = money
    for old in (
        "      AND (v_view_all OR public.staff_scope_allows_city(\n"
        "             coalesce(pp.city, us.city), v_staff.user_id))\n",
        "      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))\n",
        "      AND (v_view_all OR public.staff_scope_allows_city(\n"
        "             coalesce(o.city, pp.city), v_staff.user_id))\n",
    ):
        if old not in neutered_feed:
            raise AssertionError("falsifier anchor missing from 0012 feed guard")
        neutered_feed = neutered_feed.replace(old, "-- " + old[2:])

    ok &= expect_red(
        "H: staff_task_feed loses all three city guards (category scope intact)",
        {MONEY_MIGRATION: neutered_feed})

    # I. verify_payment_proof moves money with no city guard. Deliberately
    #    leaves 0109/0010/0011 fully enforcing, so the ONLY way to catch this
    #    is the per-function pin rather than the "something enforces it" count.
    neutered_proof = money.replace(
        "     OR NOT public.staff_scope_allows_city(\n"
        "          (SELECT o.city\n"
        "             FROM public.payment_proofs proof\n"
        "             JOIN public.orders o ON o.id = proof.order_id\n"
        "            WHERE proof.id = p_proof_id)) THEN",
        "     OR false THEN")
    if neutered_proof == money:
        raise AssertionError("falsifier anchor missing from 0012 proof guard")
    ok &= expect_red(
        "I: verify_payment_proof moves money with the city guard removed",
        {MONEY_MIGRATION: neutered_proof})

    # J. the assertion pinning the feed stops pinning it. The feed body would
    #    still carry the guard TODAY, so only the assertion catches this -- and
    #    it is what makes the pin survive tomorrow's restatement.
    ok &= expect_red(
        "J: assert_staff_city_scope_covers_the_task_feed stops pinning the guard",
        {MONEY_MIGRATION: money.replace(
            "  IF position('staff_scope_allows_city' in v_proof) = 0 THEN\n"
            "    RAISE EXCEPTION 'verify_payment_proof no longer enforces the city scope"
            " -- a city-scoped person could verify another city''s payment';\n"
            "  END IF;\n",
            "")})

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
