#!/usr/bin/env python3
"""Falsification for check_account_deletion_removes_the_files.

A check that has never been seen red is not yet a check. This proves the
account-file check goes red on each way it could be green while broken, and
green on the real sources. Neither run edits a file on disk: every case
patches the real text through the same `_read` monkey-patch the appeal
falsifier uses, so the real check code runs against a mutated string.

The defects, one per way "the rows go but the files stay":

  1. the purge stops deleting              -- it counts objects and does
                                               nothing about them
  2. a source query is dropped             -- a bucket is still named, so a
                                               bucket-only check stays green
                                               while every file in it survives
  3. the sweep reaches into payment_proofs -- a RETAINED accounting record
                                               loses the proof image that
                                               record still points at
  4. the recharge condition is dropped     -- a customer's retained recharge
                                               row loses its screenshot
  5. the CEO wrapper stops calling it      -- the directory path leaks
  6. user-admin stops calling it           -- the Staff Assignment path
                                               leaks, because that gateway
                                               bypasses delete_user_account()
  7. the REVOKE is dropped                 -- any signed-in user could delete
                                               another person's documents
  8. the privacy page is not updated       -- the published promise stays
                                               false
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import static_checks as sc  # noqa: E402

MIG = sc.STORAGE_MIGRATION
MIG_KEY = "supabase/migrations/" + MIG
GATEWAY = "supabase/functions/account-deletion-gateway/index.ts"
USER_ADMIN = "supabase/functions/user-admin/index.ts"
PAGE = "docs/delete-account.html"

_real_read = sc._read


def _count_instead_of_deleting(sql: str) -> str:
    """The purge tallies the objects it found and removes none of them."""
    return sql.replace("    DELETE FROM storage.objects\n", "    -- DELETE FROM storage.objects\n")


def _drop_the_respondent_evidence(sql: str) -> str:
    """The appeal answer photo is no longer collected."""
    return re.sub(
        r"  UNION ALL\n  -- The photo they attached answering an appeal filed"
        r" against them\.[\s\S]*?nullif\(btrim\(a\.response_photo_path\), ''\)"
        r" IS NOT NULL\n",
        "", sql, flags=re.IGNORECASE)


def _sweep_the_retained_proofs(sql: str) -> str:
    """payment_proofs -- a record row that is deliberately kept."""
    m = re.search(r"(  UNION ALL\n  -- The recharge screenshot)", sql)
    assert m, "the recharge branch anchor is gone"
    extra = (
        "  UNION ALL\n"
        "  SELECT 'payment-proofs', pf.storage_path\n"
        "    FROM public.payment_proofs pf\n"
        "   WHERE pf.order_id IS NOT NULL\n"
        "     AND nullif(btrim(pf.storage_path), '') IS NOT NULL\n")
    return sql[:m.start(1)] + extra + sql[m.start(1):]


def _drop_the_recharge_condition(sql: str) -> str:
    """The recharge branch stops asking whose recharge it is."""
    m = re.search(r"   WHERE \(\n           r\.provider_id IN \(SELECT id FROM prov\)[\s\S]*?\(SELECT id FROM prov\)\)\)\n", sql)
    assert m, "the recharge condition anchor is gone"
    return sql[:m.start()] + "   WHERE true\n" + sql[m.end():]


def _drop_the_ceo_call(sql: str) -> str:
    return sql.replace(
        "  v_storage := public.purge_account_storage(p_target_user_id);\n", "")


def _drop_the_grant_revoke(sql: str) -> str:
    return re.sub(
        r"REVOKE ALL ON FUNCTION public\.purge_account_storage\(uuid\)[\s\S]*?"
        r"TO service_role;\n", "", sql)


def with_patches(sql=None, gateway=None, user_admin=None, page=None) -> list[str]:
    """Run the real check with each source reading as the patched string."""
    overlays = {
        MIG_KEY: sql,
        GATEWAY: gateway,
        USER_ADMIN: user_admin,
        PAGE: page,
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
        return sc.check_account_deletion_removes_the_files()
    finally:
        sc._read = _real_read


CASES = [
    ("the purge counts objects instead of deleting them",
     lambda sql, gw, ua, pg: (_count_instead_of_deleting(sql), gw, ua, pg),
     "no longer deletes from storage.objects"),
    ("the respondent's appeal photo is dropped from the collector",
     lambda sql, gw, ua, pg: (_drop_the_respondent_evidence(sql), gw, ua, pg),
     "no longer reads appeal_cases"),
    ("the sweep reaches into the retained payment proofs",
     lambda sql, gw, ua, pg: (_sweep_the_retained_proofs(sql), gw, ua, pg),
     "now sweeps payment_proofs"),
    ("the recharge branch stops asking whose recharge it is",
     lambda sql, gw, ua, pg: (_drop_the_recharge_condition(sql), gw, ua, pg),
     "no longer conditioned on the provider/wallet"),
    ("the CEO wrapper stops sweeping the files",
     lambda sql, gw, ua, pg: (_drop_the_ceo_call(sql), gw, ua, pg),
     "ceo_delete_user_account closes an account without calling"),
    ("user-admin stops sweeping the files",
     lambda sql, gw, ua, pg: (
         sql,
         gw,
         ua.replace('    const { data: purged, error: purgeError } = await admin.rpc(\n'
                    '      "purge_account_storage",\n'
                    '      { p_user_id: targetId },\n'
                    '    );\n', ""),
         pg),
     "user-admin closes an account without calling"),
    ("the REVOKE from the client roles is dropped",
     lambda sql, gw, ua, pg: (_drop_the_grant_revoke(sql), gw, ua, pg),
     "not revoked from PUBLIC"),
    ("the privacy page still promises nothing about files",
     lambda sql, gw, ua, pg: (
         sql, gw, ua,
         re.sub(r"[Ff]ile storage", "the database", pg)),
     "says nothing about file storage"),
]


def main() -> int:
    sql = sc._read(sc.MIGRATIONS / MIG)
    gw = sc._read(sc.ROOT / GATEWAY)
    ua = sc._read(sc.ROOT / USER_ADMIN)
    pg = sc._read(sc.ROOT / PAGE)

    print("falsification: closing an account removes the uploaded files")
    print("-" * 70)

    if with_patches():
        print("[FAIL] the real sources are already red -- the check is "
              "reporting something that is actually in the repository")
        for p in with_patches():
            print("         - " + p)
        return 1
    print("[ ok ] the real sources are green")

    failures = 0
    for label, patch, expect in CASES:
        sql_p, gw_p, ua_p, pg_p = patch(sql, gw, ua, pg)
        if (sql_p, gw_p, ua_p, pg_p) == (sql, gw, ua, pg):
            print("[FAIL] %s: the patch changed nothing, so this case would "
                  "pass for the wrong reason" % label)
            failures += 1
            continue
        problems = with_patches(sql_p, gw_p, ua_p, pg_p)
        if not problems:
            print("[FAIL] %s was NOT detected -- the check is green on a "
                  "broken source" % label)
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