#!/usr/bin/env python3
"""Falsification for check_guarded_tables_are_lifted_at_migration_time.

The failure this check exists for: 0113 seeded `system_settings` without
lifting `trg_system_settings_security`, and the deploy died with

    ERROR: SETTINGS_ARE_ADMIN_ONLY (SQLSTATE P0001)

after 0107-0112 had all applied. The trigger's body is `IF NOT is_admin() THEN
RAISE EXCEPTION`, `is_admin()` is `auth.uid()`-derived, and a migration
connection has no JWT -- so it raises no matter how privileged the role is.

The first version of this check reported **1014** problems across already-
applied history, by treating every trigger function that merely mentions
is_admin() as a blanket guard. Those others (`prevent_role_escalation`,
`prevent_notification_injection`, `enforce_provider_write_gate`) are
selective, which is why the migrations that write profiles, provider_profiles
and notifications all applied cleanly. So the cases below test narrowness as
much as detection.

Nothing writes to the repo.
"""
from __future__ import annotations

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import static_checks as sc  # noqa: E402

_real_read = sc._read
GATE = "20260927000113_provider_fulfilment_gate.sql"
REAL = _real_read(sc.MIGRATIONS / GATE)

LIFT_OPEN = """do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings disable trigger %I', r.tgname);
  end loop;
end $$;"""

ok = True


def run(sql: str) -> list[str]:
    def _read(path):
        if str(path).replace("\\", "/").endswith(GATE):
            return sql
        return _real_read(path)
    sc._read = _read
    try:
        return sc.check_guarded_tables_are_lifted_at_migration_time()
    finally:
        sc._read = _real_read


def expect_red(label: str, sql: str) -> None:
    global ok
    ps = run(sql)
    if ps:
        print("[ ok ] %s -> caught" % label)
        print("         - " + ps[0].split(". ")[-1][:110])
    else:
        ok = False
        print("[FAIL] %s -> stayed GREEN" % label)


def expect_green(label: str, sql: str) -> None:
    global ok
    ps = run(sql)
    if not ps:
        print("[ ok ] %s -> stayed green (correct)" % label)
    else:
        ok = False
        print("[FAIL] %s -> false positive: %s" % (label, ps[0][:120]))


# A. The real file, after the fix.
expect_green("A: the real 0113 lifts the guard before seeding", REAL)

# B. The shipped defect: the seed with no lift at all. Both halves of the
#    dynamic pair must go, since either one alone is not a lift.
stripped = REAL
for marker in ("disable trigger %I", "enable trigger %I"):
    out = []
    lines = stripped.split("\n")
    i = 0
    while i < len(lines):
        if marker in lines[i]:
            # drop the enclosing do $$ .. end $$; block
            start = i
            while start > 0 and "do $$" not in lines[start]:
                start -= 1
            end = i
            while end < len(lines) and "end $$;" not in lines[end]:
                end += 1
            del lines[start:end + 1]
            i = start
        else:
            i += 1
    stripped = "\n".join(lines)
assert "disable trigger %I" not in stripped, "falsifier: disable survived"
assert "enable trigger %I" not in stripped, "falsifier: enable survived"
expect_red("B: the seed with no guard lift (what shipped)", stripped)

# C. NARROWNESS. A migration that writes a table with a SELECTIVE guard must
#    stay green. These exact writes applied cleanly in this repo; flagging them
#    is the 1014-finding mistake.
expect_green(
    "C: a write to profiles, whose guard is selective",
    REAL.replace(
        "INSERT INTO public.system_settings (key, value, description)",
        "INSERT INTO public.profiles (id, full_name)\n"
        "SELECT id, full_name FROM public.profiles LIMIT 0;\n"
        "INSERT INTO public.system_settings (key, value, description)"))

# D. A write INSIDE a function body is not a migration-time write and must not
#    be reported: it runs in the caller's context, where auth.uid() is real.
expect_green(
    "D: a system_settings write inside a function body only",
    "CREATE OR REPLACE FUNCTION public.f() RETURNS void\n"
    "LANGUAGE plpgsql AS $$\nBEGIN\n"
    "  INSERT INTO public.system_settings (key, value) VALUES ('a', 'b');\n"
    "END;\n$$;\n")

# E. The literal lift (0028/0038/0062 style) is equally valid.
expect_green(
    "E: the literal ALTER TABLE ... DISABLE/ENABLE pair",
    REAL.replace(LIFT_OPEN,
                 "ALTER TABLE public.system_settings DISABLE TRIGGER "
                 "trg_system_settings_security;")
        .replace("""do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings enable trigger %I', r.tgname);
  end loop;
end $$;""",
                 "ALTER TABLE public.system_settings ENABLE TRIGGER "
                 "trg_system_settings_security;"))

if not ok:
    print("\nFALSIFICATION FAILED")
    raise SystemExit(1)
print("\nFALSIFICATION PASSED")
