#!/usr/bin/env python3
"""Static harnesses for Aliob.

THERE IS NO DART SDK AND NO DENO IN THE AUDIT ENVIRONMENT, and the live-DB
suite (tools/integration_test/connectivity_test.dart) needs credentials the
sandbox does not have. These checks read the source instead: they are the
machine-checkable half of what docs/ARCHITECTURE.md section 6 claims, the
half that needs no compiler, no network and no secrets.

They live under tools/harness/ and NOT under build/ because `.gitignore`
contains a bare `build/` line (it is the Flutter output directory). Anything
placed there is never committed, does not survive a clone, and disappears at
the end of every session -- which is exactly what happened to the previous
set of harnesses.

Each check prints one line and returns a problem list. The runner fails the
whole harness if any check reports a problem.

Run:  sh build/run_all.sh      (shim)
      sh tools/harness/run_all.sh
"""

from __future__ import annotations

import re
import subprocess
import sys
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "lib"
MIGRATIONS = ROOT / "supabase" / "migrations"
FUNCTIONS = ROOT / "supabase" / "functions"
DEPLOY_WORKFLOW = ROOT / ".github" / "workflows" / "deploy-supabase.yml"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def dart_sources() -> list[Path]:
    return sorted(LIB.rglob("*.dart"))


def migration_files() -> list[Path]:
    """Migrations in the order the database applies them (filename order)."""
    return sorted(p for p in MIGRATIONS.glob("*.sql"))


def last_migration_defining(name: str) -> tuple[Path | None, str]:
    """The highest-ordered migration that defines public.<name>().

    The live database has no CLI history for the early files, so filename
    order is the only ordering that exists; the last definition in that
    order is the one that is authoritative.
    """
    pattern = re.compile(
        r"FUNCTION\s+public\.%s\s*\(" % re.escape(name), re.IGNORECASE
    )
    found: list[Path] = []
    for path in migration_files():
        if pattern.search(_read(path)):
            found.append(path)
    if not found:
        return None, ""
    return found[-1], _read(found[-1])


def function_body(sql: str, name: str) -> str:
    """The body between the AS $$ ... $$; of public.<name>(), if present.

    Needed because a naive count of `verified_at = now()` over the whole
    FILE also counts the header comment that explains the invariant -- which
    is how a correct file would look like a broken one.
    """
    m = re.search(
        r"FUNCTION\s+public\.%s\s*\([^)]*\).*?AS\s+\$\$(.*?)\$\$;" % re.escape(name),
        sql,
        re.IGNORECASE | re.DOTALL,
    )
    return m.group(1) if m else ""


def literal_calls(pattern: str, flags: int = re.DOTALL) -> dict[str, set[str]]:
    """Map every literal matched by `pattern` -> the files that contain it."""
    hits: dict[str, set[str]] = {}
    rx = re.compile(pattern, flags)
    for path in dart_sources():
        for m in rx.finditer(_read(path)):
            hits.setdefault(m.group(1), set()).add(
                str(path.relative_to(ROOT)).replace("\\", "/")
            )
    return hits


# ---------------------------------------------------------------------------
# 1. the signup OTP gate is a working toggle, on both sides
# ---------------------------------------------------------------------------
def check_signup_otp_contract() -> list[str]:
    """The load-bearing property of migrations 82 and 84.

    Registration works today only because the OTP gate is switched OFF. The
    three things that make that safe, and that a later edit could quietly
    break, are asserted here:

      * send-otp consults the toggle BEFORE it needs a mail provider, a
        captcha or a code -- so with the gate off it sends nothing and
        reports `skipped`, rather than failing registration with an opaque
        provider error.
      * verify_email_otp() completes a bypassed signup WITHOUT stamping
        verified_at, so switching the gate back on restores it for every
        address. Exactly one place may stamp it: the correct-code branch.
      * handle_new_user() still reads the toggle and still refuses an
        unverified signup when it is on.
      * the client asks the server whether to show the code screen at all,
        and fails closed (shows it) if the lookup fails.
    """
    problems: list[str] = []

    src = _read(FUNCTIONS / "send-otp" / "index.ts")
    if not src:
        return ["send-otp/index.ts is missing"]

    order = {
        "the signup_otp_required check": '"signup_otp_required"',
        "the mail provider lookup": "resolveProvider()",
        "the captcha check": 'admin.rpc("captcha_required")',
        "the code request": 'admin.rpc("request_email_otp"',
    }
    positions: dict[str, int] = {}
    for label, needle in order.items():
        pos = src.find(needle)
        if pos < 0:
            problems.append(f"send-otp: no {label} ({needle!r})")
        positions[label] = pos

    if not problems:
        sequence = [positions[label] for label in order]
        if sequence != sorted(sequence):
            problems.append(
                "send-otp: the signup_otp_required check is not the FIRST gate. "
                "With the toggle off it must return before any provider, "
                "captcha or code work, otherwise registration fails on a mail "
                "provider the owner has deliberately not configured. Order: "
                + " -> ".join(
                    f"{label}@{positions[label]}" for label in order
                )
            )

    if 'skipped: "email_verification_disabled"' not in src:
        problems.append(
            'send-otp: no `skipped: "email_verification_disabled"` response, '
            "so a switched-off gate is indistinguishable from a failure"
        )

    # --- verify_email_otp: the bypass must record nothing -----------------
    path, sql = last_migration_defining("verify_email_otp")
    if path is None:
        problems.append("no migration defines public.verify_email_otp()")
    else:
        body = function_body(sql, "verify_email_otp")
        if not body:
            problems.append(f"{path.name}: could not extract verify_email_otp body")
        else:
            if "signup_otp_required" not in body:
                problems.append(
                    f"{path.name}: verify_email_otp() no longer consults "
                    "signup_otp_required, so it cannot tell a switched-off "
                    "gate from a real verification"
                )
            stamps = len(re.findall(r"verified_at\s*=\s*now\(\)", body))
            if stamps != 1:
                problems.append(
                    f"{path.name}: verify_email_otp() stamps verified_at in "
                    f"{stamps} places; exactly the correct-code branch may (1). "
                    "0 means re-enabling the gate would not restore it; >1 "
                    "means the bypass records a verification and every address "
                    "that skipped the code stays exempt"
                )

    # --- handle_new_user: still a gate ------------------------------------
    path, sql = last_migration_defining("handle_new_user")
    if path is None:
        problems.append("no migration defines public.handle_new_user()")
    else:
        for token in ("signup_otp_required", "otp_verified_recently", "EMAIL_OTP_REQUIRED"):
            if token not in sql:
                problems.append(
                    f"{path.name}: handle_new_user() no longer references "
                    f"{token}, so the signup gate is not switchable back on"
                )

    # --- the guards that keep both properties honest ----------------------
    all_sql = "\n".join(_read(p) for p in migration_files())
    for guard in ("assert_signup_otp_toggle_is_consistent", "assert_otp_bypass_is_scoped"):
        if guard not in all_sql:
            problems.append(f"the source-level guard {guard}() is missing")

    # --- the client -------------------------------------------------------
    svc = _read(LIB / "core" / "services" / "otp_service.dart")
    if "rpc('signup_otp_required')" not in svc:
        problems.append(
            "otp_service.dart: isRequiredAtSignup() no longer asks the server "
            "(signup_otp_required), so the client is guessing"
        )
    if not re.search(r"catch\s*\(_\)\s*\{\s*return true;", svc):
        problems.append(
            "otp_service.dart: isRequiredAtSignup() does not fail closed "
            "(return true) when the lookup fails"
        )

    screen = _read(LIB / "features" / "auth" / "signup_screen.dart")
    if "'/otp-verify'" not in screen:
        problems.append("signup_screen.dart: no longer routes to /otp-verify")
    if not re.search(r"if\s*\(_otpRequired\)", screen):
        problems.append(
            "signup_screen.dart: /otp-verify is not gated on _otpRequired, so "
            "a build would demand a code whose email cannot be delivered"
        )
    if "_captchaRequired = results[0] && otpRequired" not in screen:
        problems.append(
            "signup_screen.dart: the captcha is no longer tied to the OTP "
            "requirement, so users are challenged for a code that is skipped"
        )

    return problems


# ---------------------------------------------------------------------------
# 2. every RPC the client calls exists in a migration
# ---------------------------------------------------------------------------
def check_rpc_targets_exist() -> list[str]:
    """A `client.rpc('does_not_exist')` is a runtime 404 in one screen.

    Only literal names are checked; names passed through a variable (the
    generic invoker in supabase_service.dart) cannot be resolved statically
    and are reported as a count instead of silently ignored.
    """
    calls = literal_calls(r"\.rpc\(\s*'([^']+)'")
    all_sql = "\n".join(_read(p) for p in migration_files())
    problems = []
    for name in sorted(calls):
        if not re.search(
            r"FUNCTION\s+public\.%s\s*\(" % re.escape(name), all_sql, re.IGNORECASE
        ):
            problems.append(
                "no migration defines public.%s() -- called from %s"
                % (name, ", ".join(sorted(calls[name])))
            )
    return problems


# ---------------------------------------------------------------------------
# 3. every Edge Function the client invokes is deployed by the workflow
# ---------------------------------------------------------------------------
def check_edge_functions_deployed() -> list[str]:
    """ARCHITECTURE.md 5.6: a function in supabase/functions/ is NOT deployed
    unless deploy-supabase.yml has a step for it. "Change password" and
    "approve account deletion" both shipped calling a function that did not
    exist. This is the check that would have caught both.
    """
    problems: list[str] = []
    workflow = _read(DEPLOY_WORKFLOW)
    if not workflow:
        return [f"{DEPLOY_WORKFLOW.relative_to(ROOT)} is missing"]

    # generic invoker: functions.invoke(<variable>) cannot be resolved.
    invoked = literal_calls(r"\.invoke\(\s*'([^']+)'")
    if not invoked:
        problems.append("no literal functions.invoke('...') calls found -- did the client move?")

    for name in sorted(invoked):
        if not (FUNCTIONS / name / "index.ts").is_file():
            problems.append(
                "supabase/functions/%s/index.ts is missing -- invoked from %s"
                % (name, ", ".join(sorted(invoked[name])))
            )
        if not re.search(r"functions\s+deploy\s+%s\b" % re.escape(name), workflow):
            problems.append(
                "%s is called from the app but has no deploy step in "
                "deploy-supabase.yml -- it will not exist in production"
                % name
            )

    # ...and the other direction: a function on disk that never deploys.
    for directory in sorted(p for p in FUNCTIONS.iterdir() if p.is_dir()):
        if directory.name == "_shared":
            continue
        if not re.search(r"functions\s+deploy\s+%s\b" % re.escape(directory.name), workflow):
            problems.append(
                "supabase/functions/%s/ exists but deploy-supabase.yml never "
                "deploys it" % directory.name
            )
    problems.extend(_pre_auth_functions_must_skip_jwt(workflow))
    return problems


# Functions the client calls BEFORE it has a session. The gateway refuses an
# anonymous request to a function deployed with the default verify_jwt=true,
# so deploying one of these without --no-verify-jwt makes it permanently
# unreachable and every caller fails. login-gate shipped exactly that way: the
# workflow deployed it with verification ON while its own header says it "must
# run BEFORE the credential check is even attempted", so the gate never ran
# and no login in the app could complete.
#
# The list is here, in the harness, rather than inferred: inferring it from
# the function source would need to decide whether a given function is
# pre-auth, and that judgement belongs next to the thing that gets deployed.
PRE_AUTH_FUNCTIONS = {
    "login-gate": "CAPTCHA + lockout gate; runs before the credential check",
    "staff-login": "staff credential check; the caller has no session yet",
    "index-chunks": "unauthenticated repository indexing",
}


def _pre_auth_functions_must_skip_jwt(workflow: str) -> list[str]:
    problems: list[str] = []
    for name, why in sorted(PRE_AUTH_FUNCTIONS.items()):
        m = re.search(r"functions\s+deploy\s+%s\b([^\n]*)" % re.escape(name), workflow)
        if not m:
            # Already reported by the catalogue check above; not this check's
            # business to say it twice.
            continue
        if "--no-verify-jwt" not in m.group(1):
            problems.append(
                "%s is a pre-authentication endpoint (%s) but its deploy step "
                "does not pass --no-verify-jwt, so the gateway rejects every "
                "anonymous call with a 401 before the function body runs"
                % (name, why)
            )
    return problems


# ---------------------------------------------------------------------------
# 4. every route the app navigates to is a defined route
# ---------------------------------------------------------------------------
def _parse_dart_literal(text: str, i: int) -> tuple[str, int] | None:
    """Read the single-quoted Dart string starting at text[i] -> (value, end).

    Interpolations are copied verbatim on purpose. `${...}` may itself
    contain quotes and braces -- `/admin/providers/${p['id']}/wallet` -- so a
    regex over `'...'` truncates the path at the inner quote and invents a
    dead route that does not exist.
    """
    if i >= len(text) or text[i] != "'":
        return None
    i += 1
    out: list[str] = []
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            out.append(text[i:i + 2])
            i += 2
            continue
        if ch == "'":
            return "".join(out), i + 1
        if ch == "$" and i + 1 < len(text) and text[i + 1] == "{":
            depth = 0
            out.append("${")
            i += 2
            while i < len(text):
                c = text[i]
                out.append(c)
                if c == "{":
                    depth += 1
                elif c == "}":
                    if depth == 0:
                        i += 1
                        break
                    depth -= 1
                i += 1
            continue
        out.append(ch)
        i += 1
    return None


NAV_RX = re.compile(
    r"(?:context\.(?:go|push|replace)|GoRouter\.of\(context\)\.(?:go|push))"
    r"(?:<[^>]*>)?\(\s*'"
)


def nav_targets() -> dict[str, set[str]]:
    """Every literal route the app navigates to -> the files that do it."""
    hits: dict[str, set[str]] = {}
    for path in dart_sources():
        text = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for m in NAV_RX.finditer(text):
            parsed = _parse_dart_literal(text, m.end() - 1)
            if parsed:
                hits.setdefault(parsed[0], set()).add(rel)
    return hits


def _wildcard_nav(target: str) -> str:
    """`/user/orders/$orderId` -> `/user/orders/*` (and the same for ${...})."""
    target = target.split("?")[0].split("#")[0]
    out: list[str] = []
    i = 0
    while i < len(target):
        ch = target[i]
        if ch == "$" and i + 1 < len(target) and target[i + 1] == "{":
            depth = 1
            i += 2
            while i < len(target) and depth:
                if target[i] == "{":
                    depth += 1
                elif target[i] == "}":
                    depth -= 1
                i += 1
            out.append("*")
        elif ch == "$":
            i += 1
            while i < len(target) and (target[i].isalnum() or target[i] == "_"):
                i += 1
            out.append("*")
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def _segments(pattern: str) -> list[str]:
    return [s if not s.startswith(":") else "*" for s in pattern.split("/")]


def check_routes_resolve() -> list[str]:
    """A tap that navigates to an undefined path lands on the router's error
    page. The 2026-09-28 audit found 0 dead targets across 82 routes; this
    keeps it that way.

    Only the safe direction is asserted: every nav target must match a
    declared route. Unused routes are NOT reported, because many are
    legitimately reached only by redirect or deep link.
    """
    router = _read(LIB / "routing" / "app_router.dart")
    declared = re.findall(r"path:\s*['\"]([^'\"]*)['\"]", router)
    declared = [p for p in declared if p.startswith("/")]
    if not declared:
        return ["app_router.dart declares no absolute GoRoute paths"]

    patterns = [(_segments(p), p) for p in declared]
    problems: list[str] = []
    found = nav_targets()
    if not found:
        return ["no navigation calls found in lib/ -- did the router API change?"]
    for raw, files in sorted(found.items()):
        target = _wildcard_nav(raw)
        if ":" in target:
            # a path parameter built at runtime that we could not normalise
            continue
        seg = _segments(target)
        if not any(len(seg) == len(p) and
                   all(s == "*" or t == "*" or s == t for s, t in zip(seg, p))
                   for p, _ in patterns):
            problems.append(
                "no GoRoute matches %r -- navigated from %s"
                % (raw, ", ".join(sorted(files)))
            )
    return problems


# ---------------------------------------------------------------------------
# 5. both email gateways still work, including the free one
# ---------------------------------------------------------------------------
def check_email_provider_gateways() -> list[str]:
    """send-otp has two independent ways to send mail, and the second is the
    one that works on a free tier with no card (Brevo).

    Checked against Brevo's published contract (developers.brevo.com,
    "Send a transactional email"): POST /v3/smtp/email, the key in an
    `api-key` header, a `sender` object and a `to` array of objects, and
    exactly one of htmlContent / textContent / templateId. The two ways to
    lose email with no code change are also asserted, because both are
    silent: a provider pair that is only half-set reads as "not configured",
    and Resend wins whenever a leftover RESEND_API_KEY plus OTP_FROM_EMAIL
    are both present, so Brevo is never reached.
    """
    src = _read(FUNCTIONS / "send-otp" / "index.ts")
    if not src:
        return ["send-otp/index.ts is missing"]
    problems: list[str] = []

    for name in ("RESEND_API_KEY", "OTP_FROM_EMAIL", "BREVO_API_KEY", "BREVO_FROM_EMAIL"):
        if f'Deno.env.get("{name}")' not in src:
            problems.append(
                f"send-otp does not read {name}; that gateway is a Python-style "
                "guess about a secret nobody sets"
            )

    # Resend: Bearer token, from/to arrays, `text` body.
    for needle, why in (
        ('fetch("https://api.resend.com/emails"', "the Resend endpoint"),
        ("Authorization: `Bearer ${apiKey}`", "Resend's Bearer auth"),
        ("body: JSON.stringify({ from, to: [to], subject, text })", "Resend's payload shape"),
    ):
        if needle not in src:
            problems.append(f"send-otp: {why} changed or vanished ({needle!r})")

    # Brevo free tier: `api-key` header, sender object, to array, textContent.
    for needle, why in (
        ('fetch("https://api.brevo.com/v3/smtp/email"', "the Brevo endpoint"),
        ('"api-key": apiKey', "Brevo's api-key header"),
        ("sender: { email: from },", "Brevo's sender object"),
        ("to: [{ email: to }],", "Brevo's recipient array"),
        ("textContent: text,", "Brevo's text body (exactly one body type per request)"),
    ):
        if needle not in src:
            problems.append(f"send-otp: {why} changed or vanished ({needle!r})")

    if 'Deno.env.get("BREVO_FROM_EMAIL") ?? resendFrom' not in src:
        problems.append(
            "send-otp: BREVO_FROM_EMAIL no longer falls back to OTP_FROM_EMAIL, "
            "so a Brevo user who set only the shared sender address gets "
            "`email_provider_not_configured`"
        )

    # Precedence is a documented decision, not an accident: it has to stay
    # readable, because "why is Brevo not sending?" is answered by it.
    resend_at = src.find("RESEND_API_KEY")
    brevo_at = src.find("BREVO_API_KEY")
    if 0 <= brevo_at < resend_at:
        problems.append(
            "send-otp: Brevo is now tried before Resend, the opposite of what "
            "ARCHITECTURE.md documents"
        )
    if "email_provider_not_configured" not in src:
        problems.append(
            "send-otp: no email_provider_not_configured refusal -- an "
            "unconfigured provider must fail closed, not send silently"
        )

    return problems


# ---------------------------------------------------------------------------
# 6. every table/view the client queries is created by a migration
# ---------------------------------------------------------------------------
def check_data_targets_exist() -> list[str]:
    """A `.from('typo')` is a screen that renders "no data" forever.

    Storage buckets are excluded on purpose: they are reached through
    `storage.from('bucket-name')` and are hyphenated, which no table name in
    this schema is, so `.from('payment-proofs')` is the bucket and
    `.from('payment_proofs')` is the table.
    """
    all_sql = "\n".join(_read(p) for p in migration_files())
    defined = {
        m.group(1).lower()
        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW|MATERIALIZED\s+VIEW)\s+"
            r"(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?\"?([A-Za-z0-9_]+)\"?",
            all_sql,
            re.IGNORECASE,
        )
    }
    problems: list[str] = []
    targets = literal_calls(r"(?<!storage)\.from\(\s*'([^']+)'")
    checked = 0
    for name, files in sorted(targets.items()):
        if "-" in name:
            continue  # a storage bucket
        checked += 1
        if name.lower() not in defined:
            problems.append(
                "lib/ queries public.%s, which no migration creates (from %s)"
                % (name, ", ".join(sorted(files)))
            )
    if checked == 0:
        problems.append("no .from('...') targets found -- did the client change shape?")
    return problems


# ---------------------------------------------------------------------------
# 7. CEO -> staff -> admin -> provider -> user is wired on both sides
# ---------------------------------------------------------------------------
def check_role_permission_wiring() -> list[str]:
    """The five-way chain, checked end to end at source level.

    The router decides a landing page from the session; the database decides
    everything that matters afterwards. A route without a server-side check
    is decoration, and a role with no landing page is an account that cannot
    sign in. Both directions are asserted.
    """
    problems: list[str] = []

    auth = _read(LIB / "core" / "providers" / "auth_provider.dart")
    m = re.search(r"enum\s+AppUserRole\s*\{([^}]*)\}", auth)
    if not m:
        problems.append("auth_provider.dart: AppUserRole is gone")
    else:
        roles = [r.strip() for r in m.group(1).split(",") if r.strip()]
        expected = ["user", "vehicleProvider", "serviceProvider", "admin"]
        if roles != expected:
            problems.append(
                "AppUserRole is [%s]; ARCHITECTURE.md 5.4 pins the four as [%s]"
                % (", ".join(roles), ", ".join(expected))
            )

    router = _read(LIB / "routing" / "app_router.dart")
    declared = set(re.findall(r"path:\s*['\"]([^'\"]*)['\"]", router))
    for route in ("/staff/dashboard", "/staff/login", "/admin", "/ceo",
                  "/vehicle", "/provider", "/user", "/pending-approval",
                  "/rejected", "/suspended"):
        if route not in declared:
            problems.append(f"the {route} route is gone")

    dm = re.search(
        r"String\s+_getDashboardPath\(AuthState\s+\w+\)\s*\{(.*?)\n\}",
        router,
        re.DOTALL,
    )
    if not dm:
        problems.append(
            "app_router.dart: _getDashboardPath is gone, so no role reaches a "
            "landing page"
        )
    else:
        body = dm.group(1)
        for path in re.findall(r"return\s*'([^']+)'", body):
            if path not in declared:
                problems.append(
                    f"_getDashboardPath lands on {path!r}, which is not a declared GoRoute"
                )
        for token, who in (
            ("isStaffMember", "the staff gateway"),
            ("isAdmin", "admin"),
            ("vehicleProvider", "vehicle providers"),
            ("serviceProvider", "service providers"),
        ):
            if token not in body:
                problems.append(f"_getDashboardPath no longer branches on {token} ({who})")

    all_sql = "\n".join(_read(p) for p in migration_files())
    for fn in ("is_admin", "is_ceo", "is_super_admin", "staff_has_permission", "admin_can"):
        if not re.search(r"FUNCTION\s+public\.%s\s*\(" % re.escape(fn), all_sql, re.I):
            problems.append(
                f"public.{fn}() is gone; the route is now the only thing holding it"
            )
    return problems


# ---------------------------------------------------------------------------
# 8. controllers, focus nodes, timers and subscriptions are released
# ---------------------------------------------------------------------------
def _is_released(text: str, name: str, releaser: str) -> bool:
    if re.search(r"\b%s\s*\??\s*\.\s*%s\s*\(" % (re.escape(name), releaser), text):
        return True
    # a collection released in a loop: for (final c in _controllers) c.dispose();
    for loop in re.finditer(r"for\s*\([^)]*\bin\s+%s\b[^)]*\)" % re.escape(name), text):
        if re.search(r"\.\s*%s\s*\(" % releaser, text[loop.end():loop.end() + 400]):
            return True
    return False


def check_lifecycle_hygiene() -> list[str]:
    """A controller or subscription nobody releases leaks the screen.

    Only fields are checked (names starting with `_`): a local timer inside a
    debounce closure is released through the closure's own disposable, and
    flagging those produces noise that hides real leaks.
    """
    problems: list[str] = []
    resource_rx = (
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*TextEditingController\(",
         "dispose", "TextEditingController"),
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*FocusNode\(",
         "dispose", "FocusNode"),
        (r"(?:final|late\s+final|late|var)\s+(_\w+)\s*=\s*List<TextEditingController>",
         "dispose", "TextEditingController list"),
        (r"(?:final|late\s+final|late)\s+StreamSubscription\s*<[^>]*>\??\s+(_\w+)\s*;",
         "cancel", "StreamSubscription"),
        (r"(?:final|late\s+final|late)\s+StreamSubscription\??\s+(_\w+)\s*;",
         "cancel", "StreamSubscription"),
        (r"(?:final|late\s+final|late)\s+Timer\??\s+(_\w+)\s*;",
         "cancel", "Timer"),
    )
    for path in dart_sources():
        text = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        for rx, releaser, kind in resource_rx:
            for m in re.finditer(rx, text):
                name = m.group(1)
                if not _is_released(text, name, releaser):
                    problems.append(
                        f"{rel}: {kind} {name} is created but never .{releaser}()d"
                    )
    return problems


# ---------------------------------------------------------------------------
# 8b. the two reported product flows, pinned at the source level
# ---------------------------------------------------------------------------
def _method_body(text: str, signature_rx: str) -> str:
    """The text of one Dart method, from its body brace to the brace that
    closes it. Brace counting, not a regex: the bodies under test are long
    and full of nested blocks, and a `\\n  }` match would truncate them.

    The parameter list is skipped first, and this is not a detail. A Dart
    signature with named parameters opens its own brace --
    `Future<void> signIn({required String email, ...}) {` -- so taking the
    first `{` after the signature name returns the PARAMETER LIST and every
    check written against the body silently inspects the wrong text. That is
    exactly the failure mode this file's own header warns about: a test that
    flatters the code it tests.
    """
    m = re.search(signature_rx, text)
    if not m:
        return ""
    i = m.end()
    # Skip the parameter list, brace- and paren-balanced.
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    if i < len(text) and text[i] == "(":
        depth = 0
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    i += 1
                    break
            i += 1
    brace = text.find("{", i)
    if brace < 0:
        return ""
    depth = 0
    for j in range(brace, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:j + 1]
    return text[brace:]


def check_availability_payment_flow() -> list[str]:
    """The availability gate has to END somewhere.

    Migration 74 built the gate and the screens rendered it correctly: the
    buyer was told to wait, the provider got a "Confirm Availability"
    button, and payment details appeared once the order was ACCEPTED. The
    chain still did not close, because ACCEPTED -> PAYMENT_PENDING was
    provider-or-admin only. The order sat at ACCEPTED with the accounts on
    screen and no button anywhere, so the buyer could never attach a receipt
    unless the provider happened to open their own order list and press
    "Request Payment".

    Three things have to hold, and each decays on its own:

      1. the order-level gate migration exists and both columns still exist;
      2. the buyer can act once the provider has confirmed (migration 85);
      3. the accounts to pay into and the button that attaches the receipt
         are rendered together, not at opposite ends of a long scroll.
    """
    problems: list[str] = []
    screen = _read(LIB / "features" / "user" / "user_order_detail_screen.dart")
    if not screen:
        return ["lib/features/user/user_order_detail_screen.dart is missing"]

    # ── 1. the server side ──
    all_sql = "\n".join(_read(p) for p in migration_files())
    for token, why in (
        ("orders.requires_availability_confirmation",
         "has no per-order snapshot for the client to read"),
        ("v_buyer_may_open_payment",
         "has no clause letting a gated buyer open the payment step"),
        ("assert_gated_buyer_payment_request_is_wired",
         "has nothing asserting that clause is still present"),
    ):
        if token not in all_sql:
            problems.append(
                "%s is gone from supabase/migrations, so the availability "
                "gate %s" % (token, why)
            )

    # ── 2. the client offers the buyer the step ──
    body = _method_body(screen, r"bool\s+get\s+_awaitingMyPayment\b")
    if not body:
        problems.append(
            "user_order_detail_screen.dart has no _awaitingMyPayment getter, "
            "so nothing decides when the buyer may pay"
        )
    else:
        flat = re.sub(r"\s+", " ", body)
        if "'ACCEPTED'" not in flat:
            problems.append(
                "_awaitingMyPayment does not consider ACCEPTED, so a gated "
                "order is not payable until the provider makes a SECOND move "
                "(ACCEPTED -> PAYMENT_PENDING). The buyer is left looking at "
                "payment details with no button"
            )
        if "_needsAvailabilityConfirmation" not in flat:
            problems.append(
                "_awaitingMyPayment ignores requires_availability_confirmation, "
                "so the widened step would apply to un-gated orders too and "
                "change behaviour for orders that work today"
            )

    # The submit must actually perform the hop, or the button is a no-op that
    # the server refuses.
    submit = _method_body(screen, r"Future<void>\s+_submitPayment\b")
    if not submit:
        problems.append("user_order_detail_screen.dart has no _submitPayment")
    else:
        flat = re.sub(r"\s+", " ", _strip_comments(submit))
        if "'PAYMENT_PENDING'" not in flat:
            problems.append(
                "_submitPayment never moves the order to PAYMENT_PENDING, so a "
                "gated order confirmed at ACCEPTED cannot reach the state a "
                "payment proof is submitted from"
            )
        if "'PAYMENT_VERIFICATION'" not in flat:
            problems.append(
                "_submitPayment never moves the order to PAYMENT_VERIFICATION, "
                "so the proof is attached and no admin ever sees the order"
            )

    # ── 3. the details and the action are one card ──
    if "_paymentStepCard" not in screen:
        problems.append(
            "the order screen no longer builds a combined payment step; the "
            "accounts to pay into and the upload button must render together"
        )
    card = _method_body(screen, r"Widget\s+_paymentStepCard\b")
    if card and "PAY & UPLOAD PROOF" not in card:
        problems.append(
            "_paymentStepCard does not contain the upload button, so the "
            "buyer is told where to pay with no way to attach the receipt"
        )
    card_flat = re.sub(r"\s+", " ", _strip_comments(card)) if card else ""
    if card and "_awaitingMyPayment" not in card_flat:
        problems.append(
            "_paymentStepCard is not gated on _awaitingMyPayment, so the "
            "upload button would show before the provider has confirmed"
        )
    return problems


def check_login_reports_its_own_outcome() -> list[str]:
    """A login screen that accepts the credentials and then says nothing is
    indistinguishable from one that rejects them.

    The email path awaited signInWithPassword and returned. It never cleared
    _isLoading on the success path, so between "session established" and
    "profile loaded" -- a window the router deliberately sits in, retrying --
    the button was disabled and said nothing. If the profile load then failed,
    the single retry was not enough and the user was stuck on a dead LOGIN
    button: the reported "the login screen does not accept the account the
    admin approved".
    """
    problems: list[str] = []
    path = LIB / "features" / "auth" / "login_screen.dart"
    screen = _read(path)
    if not screen:
        return ["lib/features/auth/login_screen.dart is missing"]

    body = _method_body(screen, r"Future<void>\s+_handleLogin\b")
    if not body:
        return ["login_screen.dart has no _handleLogin"]
    flat = re.sub(r"\s+", " ", _strip_comments(body))

    if "_awaitAccountLoaded" not in flat:
        problems.append(
            "_handleLogin does not wait for the account to load after a "
            "successful sign-in, so the button can stay disabled with no "
            "message when the profile load fails"
        )
    if "_isLoading = false" not in body:
        problems.append(
            "_handleLogin never sets _isLoading = false, so a failed attempt "
            "leaves the LOGIN button permanently spinning"
        )

    # A wrong password and a downed gate are different problems with different
    # fixes. Reporting one as the other sends the user (and support) the wrong
    # way: the canonical example is telling somebody to change a perfectly
    # good password because the security service was unreachable.
    if "Sign-in is temporarily unavailable" not in screen:
        problems.append(
            "login_screen.dart has no message for an unavailable login gate, "
            "so a gate outage is reported as a credential failure"
        )

    # The copy-paste that shipped: a rejected PASSWORD labelled itself a
    # Google sign-in, and splash_screen renders state.error verbatim.
    provider = _read(LIB / "core" / "providers" / "auth_provider.dart")
    # `signIn\b` and not `signInWithGoogle`: the word boundary is what keeps
    # this from matching the OAuth method one declaration below.
    sign_in = _method_body(provider, r"Future<void>\s+signIn\b")
    if sign_in and "Google" in _strip_comments(sign_in):
        problems.append(
            "auth_provider.signIn (the email+password path) mentions Google "
            "in its error context; splash_screen renders state.error "
            "verbatim, so a wrong password is reported as a Google failure"
        )
    return problems
def _strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    # `//` after a `:` is a URL, not a comment.
    return re.sub(r"(?m)(?<![:\w])//[^\n]*", "", text)


def _strip_mappers(text: str) -> str:
    """Remove `*Error(...)`-style wrappers, balanced, so the raw argument
    inside them is not mistaken for text rendered to a user.

    This project's mappers are named for what they do -- `friendlyError`,
    `_passwordError`, `_friendlyError` -- and all of them take the raw error
    and return a sentence. Anything passed through one is safe by design;
    only text that reaches `Text()` unmapped is not.
    """
    out: list[str] = []
    i = 0
    rx = re.compile(r"[A-Za-z_]*[Ee]rror\(")
    while True:
        m = rx.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i:m.start()])
        depth = 1
        j = m.end()
        while j < len(text) and depth:
            if text[j] == "(":
                depth += 1
            elif text[j] == ")":
                depth -= 1
            j += 1
        i = j
    return "".join(out)


def check_error_handling_wiring() -> list[str]:
    """ARCHITECTURE.md 1.2: one classifier, a durable sink, an error
    boundary, and zero direct renderings of an exception in lib/.

    That last one is asserted, because it is the property that decays
    silently -- a raw PostgrestException in a snackbar is unreadable and
    leaks schema detail, and it arrives one `catch` at a time.
    """
    problems: list[str] = []

    for rel, why in (
        ("lib/core/resilience/failure_mapper.dart", "the single classifier"),
        ("lib/core/resilience/safe_call.dart", "safeCall/withRetry"),
        ("lib/core/services/error_logger.dart", "the error sink writer"),
        ("lib/core/widgets/app_error_boundary.dart", "the error boundary"),
        ("lib/core/widgets/load_error_view.dart", "the load-failure view"),
        ("lib/core/utils/friendly_error.dart", "friendlyError"),
    ):
        if not (ROOT / rel).is_file():
            problems.append(f"{rel} is missing ({why})")

    all_sql = "\n".join(_read(p) for p in migration_files())
    if "client_error_logs" not in all_sql:
        problems.append("the client_error_logs sink table is gone")
    if "assert_resilience_is_wired" not in all_sql:
        problems.append("assert_resilience_is_wired() is gone; nothing asserts the wiring")

    bootstrap = _read(LIB / "core" / "bootstrap.dart")
    for token, why in (
        ("AppErrorBoundary", "the root error boundary"),
        ("ErrorLogger", "the root error sink"),
    ):
        if token not in bootstrap:
            problems.append(f"core/bootstrap.dart no longer wires {why} ({token})")
    if "SupabaseService.init()" not in bootstrap and "Supabase.initialize" not in bootstrap:
        problems.append("core/bootstrap.dart never initialises Supabase")

    raw_rx = re.compile(
        r"\be\.toString\(\)|\berror\.toString\(\)|\bex\.toString\(\)"
        r"|\$\{e\}|\$e\b|\$\{error\}|\$error\b"
    )
    for path in dart_sources():
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        text = _strip_mappers(_strip_comments(_read(path)))
        for m in re.finditer(r"Text\(", text):
            depth = 1
            j = m.end()
            while j < len(text) and depth:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            window = text[m.end():j]
            hit = raw_rx.search(window)
            if not hit:
                continue
            # A diagnostic behind `if (kDebugMode)` never ships: it is a
            # developer affordance on the crash screen, not user-facing text.
            if "kDebugMode" in text[max(0, m.start() - 400):m.start()]:
                continue
            problems.append(
                f"{rel}: a raw exception is rendered to the user ({hit.group(0)!r}); "
                "use friendlyError()"
            )
    return problems


# ---------------------------------------------------------------------------
# 10. the names ARCHITECTURE.md builds its argument on still exist
# ---------------------------------------------------------------------------
def check_documented_components_exist() -> list[str]:
    """ARCHITECTURE.md is the source of truth, so a component it names must
    be a component that exists.

    Checked in both directions on purpose. The doc had drifted to calling
    `ResilientFeed` (lib/core/services/safe_realtime.dart) by the name
    `SafeRealtimeFeed`, which appears nowhere in lib/ -- and a reader who then
    searched for it would find nothing and conclude the file was missing
    rather than renamed. A rename in either the code or the doc now fails
    here.
    """
    documented = [
        "AppFailureMapper", "AppFailure", "safeCall", "RetryPolicy",
        "ErrorLogger", "AppErrorBoundary", "ResilientFeed",
        "ResilientSubscription", "AsyncView", "LoadErrorView", "RetryWidget",
        "friendlyError", "staff_has_permission", "is_ceo", "is_admin",
        "signup_otp_required", "client_error_logs", "vehicle_images",
    ]
    doc = _read(ROOT / "docs" / "ARCHITECTURE.md")
    if not doc:
        return ["docs/ARCHITECTURE.md is missing"]

    everything = "\n".join(
        _read(p) for p in list(dart_sources()) + migration_files()
    ) + "\n".join(
        _read(p) for p in sorted(FUNCTIONS.glob("*/index.ts"))
    )

    problems: list[str] = []
    for name in documented:
        in_doc = name in doc
        in_code = name in everything
        if in_doc and not in_code:
            problems.append(
                f"ARCHITECTURE.md names {name}, which appears nowhere in lib/, "
                "supabase/ or the Edge Functions -- renamed or deleted?"
            )
        elif in_code and not in_doc:
            problems.append(
                f"{name} exists in the code but ARCHITECTURE.md never mentions "
                "it -- the doc has fallen behind the tree"
            )
    return problems


def check_transaction_notifications() -> list[str]:
    """Money and approval events notify both parties, exactly once, and a
    failed notice cannot roll back the payment.

    The bugs this catches, all of which are silent:
      * a message written somewhere nobody reads, because the app has no
        surface for it,
      * a notification insert inside a money function with no error handling,
        so an undeliverable notice rolls back a real payment,
      * a message that claims money moved when it did not (the ride
        commission is DEBITED; a wallet is never credited on completion),
      * a dedupe key that is not actually derived from the event, so a retry
        notifies twice or two different events collide on one key.
    """
    problems: list[str] = []
    all_sql = "\n".join(_read(p) for p in migration_files())
    new_sql = "\n".join(
        _read(p) for p in migration_files()
        if p.name >= "20260927000086"
    )

    # 1. The shared call site exists and does the two things it promises.
    if "notify_user_once" not in all_sql:
        problems.append("no notify_user_once() call site: money notifications "
                        "have no idempotent, failure-isolated helper")
    else:
        path, sql = last_migration_defining("notify_user_once")
        body = function_body(sql, "notify_user_once")
        body_l = body.lower()
        # The dedupe check itself, not just the key: a helper that takes a lock
        # but never reads the table notifies twice on a retry.
        if "data ->> 'idem_key'" not in body_l and \
           "data->>'idem_key'" not in body_l:
            problems.append("notify_user_once() no longer checks for an "
                            "existing row for the key, so a retried payment "
                            "notifies twice")
        # Dedupe must be under a lock. Checking for the key alone passes on a
        # body that reads-then-writes, which is the race it exists to prevent.
        if "pg_advisory_xact_lock" not in body_l:
            problems.append("notify_user_once() dedupes without taking a lock, "
                            "so two concurrent calls both pass the check and "
                            "both write")
        if "exception" not in body_l:
            problems.append("notify_user_once() has no exception handler, so a "
                            "failed notification insert would roll back the "
                            "money movement it is attached to")
        if "raise warning" not in body_l:
            problems.append("notify_user_once() swallows failures without "
                            "logging them, making them invisible")
        # A client that could call this could notify any user id.
        if "revoke all on function public.notify_user_once" not in sql.lower():
            problems.append("notify_user_once() is not revoked from the client "
                            "roles; a client could notify any user")

    # 2. Both parties are notified on the two money events. A buyer-only or
    #    provider-only regression is the specific failure this feature fixes.
    #
    #    Every needle below is searched in the FUNCTION BODY, lowercased, and
    #    never in the whole migration file. Two earlier versions of this check
    #    did search the file, and both were vacuous: each migration carries the
    #    assert_* function that names these same strings, so disabling the real
    #    call left the string sitting in the assertion and the check stayed
    #    green. A check that passes on broken input is worse than none.
    def _body(name: str) -> str:
        path, sql = last_migration_defining(name)
        return function_body(sql, name).lower() if path else ""

    order_src = _body("fn_notify_order_status_change")
    if not order_src:
        problems.append("fn_notify_order_status_change() not found")
    else:
        if "order-payment-verified:" not in order_src:
            problems.append("the buyer no longer gets a payment-confirmed "
                            "notification on order APPROVED")
        if "order-payment-received:" not in order_src:
            problems.append("the provider no longer gets a payment-received "
                            "notification on order APPROVED (both parties are "
                            "the requirement)")

    ride_src = _body("fn_notify_ride_status_change")
    if not ride_src:
        problems.append("fn_notify_ride_status_change() not found")
    else:
        if "ride-completed:" not in ride_src:
            problems.append("the rider no longer gets a trip-completed notice")
        if "ride-completed-driver:" not in ride_src:
            problems.append("the driver no longer gets a trip-completed notice")
        # A trigger that fires on an unchanged status re-notifies on every
        # unrelated write to the row (the fee and updated_at writes).
        if "is not distinct from old.status" not in ride_src:
            problems.append("the ride trigger lost its 'no status change' "
                            "guard, so unrelated row updates re-notify")

    # 3. The claim the brief got wrong. Completing a ride DEBITS the platform
    #    commission via deduct_transaction_fee; the fare is settled outside the
    #    app and never credited to a wallet. A message saying money was added
    #    contradicts the wallet screen immediately.
    #
    #    Checked against the notifier bodies only. Searching the raw migration
    #    text matches the COMMENT that explains why the message is not written
    #    that way, which is the opposite of the finding being looked for.
    notifier_src = "".join(
        _body(n) for n in ("fn_notify_order_status_change",
                           "fn_notify_ride_status_change",
                           "convert_points_to_wallet",
                           "approve_provider",
                           "approve_user"))
    for phrase in ("added to your wallet", "added to their wallet"):
        if phrase in notifier_src:
            problems.append(
                f"a notification message claims '{phrase}'. Ride completion "
                f"debits the platform commission and order payment is settled "
                f"outside the app; neither credits a wallet, so the message is "
                f"false and the wallet screen will contradict it")

    # 4. Dedupe keys must be derived from the event, not from the amount.
    #    Two conversions of the same size are two different events, and a key
    #    built from the amount would make the second one a silent no-op.
    points_src = _body("convert_points_to_wallet")
    if not points_src:
        problems.append("convert_points_to_wallet() not found")
    else:
        if "notify_user_once" not in points_src:
            problems.append("the points conversion credits the wallet and "
                            "notifies nobody; the balance changes with no way "
                            "for the user to find out")
        else:
            # Anchor on the notify call itself. The bare key string also appears
            # in the wallet ledger's idempotency_key, so searching for the key
            # anywhere in the body passes even when the notification is
            # disabled — which is exactly what fault injection found.
            #
            # The call is delimited by paren BALANCE, not by the first ')':
            # the arguments are v_birr::text, jsonb_build_object(...) and
            # friends, so a non-greedy match stopped inside the first one and
            # reported a message that had lost its amount as intact.
            m = re.search(
                r"notify_user_once\(\s*'points-convert:'.*?\n\s*\);",
                points_src, re.DOTALL)
            if not m:
                problems.append("the points conversion notice is not keyed on "
                                "the points ledger id, so a retry notifies "
                                "twice and two identical conversions collide "
                                "on one key")
            else:
                call = m.group(0)
                if "v_ledger_id" not in call.split("'points-convert:'")[1][:80]:
                    problems.append("the points conversion key is not derived "
                                    "from the ledger row id; a key built from "
                                    "the amount would collide across two "
                                    "identical conversions")
                # The two figures the brief asks the MESSAGE to carry. Both are
                # checked in the message argument, not merely in the call: the
                # data payload also carries them, so a call-wide search passes
                # on a message that quotes neither.
                msg = call.split("'POINTS_REDEEMED',", 1)[-1]
                msg = msg.rsplit("jsonb_build_object", 1)[0]
                if "p_points::text" not in msg:
                    problems.append("the conversion message no longer reports "
                                    "the points spent")
                if "v_birr::text" not in msg:
                    problems.append("the conversion message no longer reports "
                                    "the birr received")
        # Money invariants that a restatement of a money function loses.
        for needle, why in [
            ("pg_advisory_xact_lock", "its concurrency lock"),
            ("for update", "the FOR UPDATE balance re-read"),
            ("not_your_provider_profile", "its provider-ownership check"),
            ("wallet_transactions", "its ADJUSTMENT ledger row"),
        ]:
            if needle not in points_src:
                problems.append(f"convert_points_to_wallet() lost {why}")

    # 5. The user must have somewhere to read these. A notification nobody can
    #    see is a row in a table.
    notif_screen = ROOT / "lib/features/user/user_notifications_screen.dart"
    if not notif_screen.exists():
        problems.append("lib/features/user/user_notifications_screen.dart is "
                        "gone: notifications are written but have no UI")
    else:
        screen = _read(notif_screen)
        if "from('notifications')" not in screen:
            problems.append("the notifications screen no longer reads the "
                            "notifications table")
        # A receipt message that ellipsizes before the amount is visible
        # defeats the point of quoting the amount.
        m = re.search(r"maxLines:\s*(\d+)", screen)
        if m and int(m.group(1)) < 3:
            problems.append(
                f"the notifications screen truncates the body to "
                f"{m.group(1)} line(s). The money messages are receipts "
                f"('Payment of ETB 12,400.00 for Order #1841 has been "
                f"verified...') and ellipsize before the amount shows.")
        # Every notification family this series sends must map to a real icon
        # and colour. An unmapped type still renders (there is a default), but
        # a generic bell on a payment notice is how a receipt gets missed.
        # The screen branches on the enum PREFIX, which is why the families
        # are checked rather than the four full type names.
        for branch, why in [
            ("ORDER", "order payment receipts"),
            ("RIDE", "ride completion receipts"),
            ("POINTS", "points conversion receipts"),
            ("APPROVAL", "the welcome on approval"),
        ]:
            # Must appear in BOTH the colour mapper and the icon mapper.
            if screen.count(f"'{branch}'") + screen.count(f'"{branch}"') < 2:
                problems.append(f"the notifications screen does not map "
                                f"{branch} in both the icon and colour "
                                f"helpers, so {why} render with the default")
    # ...and an entry point, not just a screen that exists.
    #
    # The ROUTER is excluded: app_router.dart registers the /admin-notifications
    # route, so counting it as an entry point means the check passes even when
    # no screen links to it — a route nothing navigates to is not a surface.
    entry = 0
    for dart in dart_sources():
        if dart.name == "app_router.dart":
            continue
        if "'/admin-notifications'" in _read(dart):
            entry += 1
    if entry == 0:
        problems.append("no screen navigates to the notifications route, so the "
                        "new notifications are written and never seen (the "
                        "route alone is not a surface)")

    # 6. The two approval functions must actually send a welcome. Checked in
    #    the body, for the same reason as the money events above.
    for fn, key in [("approve_provider", "provider-approved:"),
                    ("approve_user", "user-approved:")]:
        body = _body(fn)
        if not body:
            problems.append(f"{fn}() not found")
        elif key not in body:
            problems.append(f"{fn}() no longer sends the welcome "
                            f"({key})")

    # 7. The live assertions must be registered in the connectivity suite, or
    #    they never run against a real database.
    conn = ROOT / "tools/integration_test/connectivity_test.dart"
    if not conn.exists():
        problems.append("tools/integration_test/connectivity_test.dart is gone")
    else:
        conn_sql = _read(conn)
        for fn in ("assert_notify_user_once_is_idempotent",
                   "assert_approval_welcome_covers_all_paths",
                   "assert_order_and_ride_receipts_are_sent",
                   "assert_points_conversion_notifies"):
            if fn not in all_sql:
                problems.append(f"{fn}() is not defined by any migration")
            if fn not in conn_sql:
                problems.append(f"{fn}() is never called from the connectivity "
                                f"test, so it will not run against the live "
                                f"database")

    # 8. The restatements in this series must not have lost anything. This runs
    #    the real differ rather than a proxy for it, because a proxy that
    #    cannot tell a rewrite from a deletion is the exact failure mode that
    #    has hit this repo twice.
    differ = ROOT / "tools/harness/restatement_diff.py"
    if not differ.exists():
        problems.append("tools/harness/restatement_diff.py is missing: the "
                        "restatements in this series are unverified")
    else:
        for migration, fns in [
            ("20260927000087_welcome_on_approval.sql",
             ["approve_provider", "approve_user"]),
            ("20260927000088_order_and_ride_receipts.sql",
             ["fn_notify_order_status_change", "fn_notify_ride_status_change"]),
            ("20260927000089_points_conversion_notice.sql",
             ["convert_points_to_wallet"]),
        ]:
            target = ROOT / "supabase/migrations" / migration
            if not target.exists():
                problems.append(f"{migration} is missing")
                continue
            proc = subprocess.run(
                [sys.executable, str(differ), str(target), *fns],
                capture_output=True, text=True, cwd=str(ROOT))
            if proc.returncode != 0:
                for line in proc.stdout.splitlines():
                    if line.strip().startswith(("-", "LOST", "FAIL")):
                        problems.append(f"{migration}: {line.strip()}")

    return problems


# ---------------------------------------------------------------------------
# runner
# ---------------------------------------------------------------------------
CHECKS = [
    ("signup OTP toggle contract (server pre-checks the toggle; bypass records no verification)",
     check_signup_otp_contract),
    ("every RPC called from lib/ exists in supabase/migrations",
     check_rpc_targets_exist),
    ("every Edge Function the app invokes exists and has a deploy step",
     check_edge_functions_deployed),
    ("every navigation target in lib/ resolves to a declared GoRoute",
     check_routes_resolve),
    ("both email gateways (Resend and the free Brevo tier) still match their APIs",
     check_email_provider_gateways),
    ("every table/view the client queries is created by a migration",
     check_data_targets_exist),
    ("CEO -> staff -> admin -> provider -> user routing and permissions agree",
     check_role_permission_wiring),
    ("controllers, focus nodes, timers and subscriptions are released",
     check_lifecycle_hygiene),
    ("a confirmed availability can actually be paid: gate, step, and one card",
     check_availability_payment_flow),
    ("the login screen reports its own outcome instead of spinning forever",
     check_login_reports_its_own_outcome),
    ("error handling: one classifier, a sink, and no raw exception on screen",
     check_error_handling_wiring),
    ("the components ARCHITECTURE.md names exist in the code, and vice versa",
     check_documented_components_exist),
    ("money/approval notifications: both parties, once, and never fatal to the payment",
     check_transaction_notifications),
]


def main() -> int:
    print("static harnesses (source-level: no Dart SDK, no Deno, no credentials)")
    print(f"  repo: {ROOT}")
    print(f"  {len(migration_files())} migrations, "
          f"{len(list(FUNCTIONS.glob('*/index.ts')))} edge functions, "
          f"{len(dart_sources())} dart files")
    print()

    failed = 0
    for label, fn in CHECKS:
        problems = fn()
        if problems:
            failed += 1
            print(f"[FAIL] {label}")
            for problem in problems:
                print(f"         - {problem}")
        else:
            print(f"[PASS] {label}")

    print()
    if failed:
        print(f"HARNESSES FAILED ({failed} of {len(CHECKS)})")
        return 1
    print(f"ALL HARNESSES PASS ({len(CHECKS)} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
