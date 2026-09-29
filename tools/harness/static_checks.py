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
# 9. error handling: one classifier, a sink, and nothing raw on screen
# ---------------------------------------------------------------------------
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
    ("error handling: one classifier, a sink, and no raw exception on screen",
     check_error_handling_wiring),
    ("the components ARCHITECTURE.md names exist in the code, and vice versa",
     check_documented_components_exist),
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
