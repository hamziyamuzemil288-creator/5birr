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
_READ_CACHE: dict[str, str] = {}


def _read(path: Path) -> str:
    """Read a file, memoised.

    The FOREACH check resolves the last definition of every function in the
    schema, and last_migration_defining re-reads all 189 migrations each time.
    Uncached that is a few million reads per harness run, which pushed the
    fault injector past the shell's time limit. The injector edits files
    between runs, so the cache is keyed on path plus mtime and size.
    """
    try:
        st = path.stat()
    except OSError:
        return ""
    key = f"{path}:{st.st_mtime_ns}:{st.st_size}"
    if key not in _READ_CACHE:
        try:
            _READ_CACHE[key] = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            _READ_CACHE[key] = ""
    return _READ_CACHE[key]


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

    COMMENTS ARE STRIPPED, for the same reason one level down. An inline
    comment inside the body naming a table or an expression is enough to
    satisfy a substring check about that table: deleting the real
    `EXISTS (SELECT 1 FROM notification_outbox ...)` while leaving the
    comment that explains it passed the check. A body check that prose can
    satisfy is not a body check.
    """
    m = re.search(
        r"FUNCTION\s+public\.%s\s*\([^)]*\).*?AS\s+\$\$(.*?)\$\$;" % re.escape(name),
        sql,
        re.IGNORECASE | re.DOTALL,
    )
    if not m:
        return ""
    body = m.group(1)
    body = re.sub(r"--[^\n]*", " ", body)
    body = re.sub(r"/\*.*?\*/", " ", body, flags=re.DOTALL)
    return body


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
# 6b. every storage bucket lib/ uses is created by a migration the deploy
#     workflow actually executes
# ---------------------------------------------------------------------------
# The deploy workflow's `Baseline migration history` step marks every staged file
# whose version is below BASELINE as applied via `migration repair`, and its own
# comment says the step "never executes the files" -- the live database was built
# by pasting SQL into the editor. A bucket whose only creation statement lives in
# one of those files therefore exists only if somebody pasted it by hand.
#
# That is how the provider gallery shipped: `provider-gallery` is declared in
# 0017, its upload path is in provider_gallery_screen.dart, the RPC and the table
# are live -- and every upload failed with "Bucket not found" (404) because the
# bucket was never created. "It has a creation migration" and "it has a creation
# migration the pipeline runs" are different tests, and only the second one is
# about reality.
BASELINE = 20260919000000
BUCKET_CREATE_RX = re.compile(
    r"INSERT\s+INTO\s+storage\.buckets[^;]*;", re.IGNORECASE | re.DOTALL
)
BUCKET_ID_RX = re.compile(r"'([a-z0-9][a-z0-9-]*)'")


#: Buckets lib/ is known to use, so the check below cannot pass vacuously.
#: user-documents, payment-screenshots, payment-proofs, product-images,
#: provider-gallery and vehicle-images. The last one was added in migration 97
#: together with the first Dart code that writes it -- the bucket, the policy
#: and the upload path move together, or the check below is the thing that says
#: so.
EXPECTED_CLIENT_BUCKETS = 6


def dart_buckets() -> tuple[dict[str, set[str]], list[str]]:
    """Every bucket named in lib/, resolving a file's `_bucket` constant.

    `storage.from('provider-gallery')` is read directly; `storage.from(_bucket)`
    reads `static const _bucket = 'provider-gallery'` from the same file. The
    indirect form is not a nicety: the gallery uses it, so a check that only
    understood literals would have skipped the one path that was broken.
    """
    buckets: dict[str, set[str]] = {}
    unresolved: list[str] = []
    for path in dart_sources():
        src = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        consts = {
            m.group(1): m.group(2)
            for m in re.finditer(r"\bconst\s+([A-Za-z_]\w*)\s*=\s*'([^']+)'", src)
            if "ucket" in m.group(1)
        }
        # A non-const declaration means a runtime value, which is known to be
        # legitimate in two places: admin_history_screen derives the bucket from
        # a stored `bucket/path`, and photo_grid is handed one by its caller.
        # Those can only be checked by running the app, so they are skipped
        # rather than guessed at.
        runtime = set(
            re.findall(r"\b(?:final|var|late|String)\s+([A-Za-z_]\w*)\s*=", src)
        )
        for m in re.finditer(r"storage\s*\.\s*from\(([^)]*)\)", src):
            arg = m.group(1).strip()
            if re.fullmatch(r"'[^']+'", arg):
                buckets.setdefault(arg.strip("'"), set()).add(rel)
            elif re.fullmatch(r"[A-Za-z_]\w*", arg):
                if arg in consts:
                    buckets.setdefault(consts[arg], set()).add(rel)
                elif arg in runtime:
                    continue
                else:
                    unresolved.append(
                        "%s: storage.from(%s) is neither a literal nor a "
                        "constant nor a local variable, so which bucket it "
                        "targets cannot be checked" % (rel, arg)
                    )
            # Anything else -- a field, a getter, `item.bucket!` -- is dynamic
            # by design and cannot be resolved without running the app.
    return buckets, unresolved


def _buckets_created_by_the_pipeline() -> dict[str, list[str]]:
    """Bucket id -> the migrations at/after the baseline that create it."""
    created: dict[str, list[str]] = {}
    for path in migration_files():
        version = path.name.split("_", 1)[0]
        if not version.isdigit() or int(version) < BASELINE:
            continue
        for stmt in BUCKET_CREATE_RX.finditer(_read(path)):
            for name in BUCKET_ID_RX.findall(stmt.group(0)):
                created.setdefault(name, []).append(path.name)
    return created


def check_client_buckets_are_created() -> list[str]:
    buckets, problems = dart_buckets()
    created = _buckets_created_by_the_pipeline()
    for name, files in sorted(buckets.items()):
        if name not in created:
            problems.append(
                "lib/ writes to bucket %r (from %s), but no migration at or "
                "after the deploy baseline %d creates it. Older files are "
                "marked applied WITHOUT being executed, so this bucket exists "
                "only if it was pasted into the SQL editor by hand -- and when "
                "it was not, every upload to it fails with 'Bucket not found' "
                "(404). Add it to an INSERT INTO storage.buckets in a current "
                "migration."
                % (name, ", ".join(sorted(files)), BASELINE)
            )
    if len(buckets) < EXPECTED_CLIENT_BUCKETS:
        problems.append(
            "only %d storage bucket(s) were resolved from lib/, fewer than the "
            "%d the client is known to use. A check that reads no buckets "
            "cannot report a missing one -- if a bucket was genuinely removed, "
            "lower EXPECTED_CLIENT_BUCKETS in the same change."
            % (len(buckets), EXPECTED_CLIENT_BUCKETS)
        )
    return problems


# ---------------------------------------------------------------------------
# 6c. every income figure counts every fee the platform charges
# ---------------------------------------------------------------------------
# The three transaction types a fee is written on in wallet_transactions:
#
#   TRANSACTION_FEE  -- deduct_transaction_fee(): orders on STARTED, rides on
#                       COMPLETED
#   SUBSCRIPTION_FEE -- deduct_subscription_fee() and the monthly scheduler
#   RECHARGE         -- approve_wallet_recharge(), which withholds the one-time
#                       provider_registration_fee from the FIRST approved
#                       recharge and records it as platform_fee (gross = amount
#                       paid, net = amount - fee); every later recharge carries
#                       platform_fee = 0
#
# A reader that sums platform_fee while ignoring RECHARGE reports ETB 0.00 on a
# deployment whose providers are still activating -- which is where the admin
# income summary and the dashboard total both were, with no error and no empty
# state, just a confidently wrong number. These three constants and the
# transaction_type filters in lib/ move together.
FEE_TYPES = ("TRANSACTION_FEE", "SUBSCRIPTION_FEE", "RECHARGE")


#: Readers of wallet_transactions.platform_fee that build an income figure, so
#: the check cannot pass vacuously if they are renamed away.
EXPECTED_INCOME_READERS = 2

#: What "building an income figure" looks like: selecting the fee column on its
#: own, or folding/ reducing over it. Deliberately NOT "the file mentions
#: platform_fee" -- admin_transaction_history_screen.dart selects `*` and prints
#: each row's fee (the ledger browser, which already shows RECHARGE rows), and
#: flagging it would have been a false positive.
INCOME_READER_RX = re.compile(
    r"select\(\s*'platform_fee'"
    r"|fold\([^;]{0,200}platform_fee"
    r"|reduce\([^;]{0,200}platform_fee",
    re.DOTALL,
)


def check_income_readers_count_every_fee_type() -> list[str]:
    problems: list[str] = []
    readers = 0
    for path in dart_sources():
        src = _read(path)
        rel = str(path.relative_to(ROOT)).replace("\\", "/")
        if "from('wallet_transactions')" not in src or "platform_fee" not in src:
            continue
        if not INCOME_READER_RX.search(src):
            continue
        readers += 1
        # The transaction types this file names, taken from the filter argument
        # rather than from the whole file, so a UI category name cannot be
        # mistaken for a ledger type.
        named: set[str] = set()
        for m in re.finditer(
            r"transaction_type['\"]\s*,?\s*(.{0,160})", src, re.DOTALL
        ):
            named.update(re.findall(r"'([A-Z][A-Z_]{3,})'", m.group(1)))
        missing = [t for t in FEE_TYPES if t not in named]
        if missing:
            problems.append(
                "%s sums wallet_transactions.platform_fee but never queries "
                "transaction_type %s. The one-time activation fee is stored as "
                "platform_fee on a RECHARGE row (approve_wallet_recharge), so "
                "omitting it under-reports income: a deployment whose "
                "providers are still activating renders 0.00 while money has "
                "been collected." % (rel, ", ".join(missing))
            )
    if readers < EXPECTED_INCOME_READERS:
        problems.append(
            "only %d file(s) read wallet_transactions.platform_fee, fewer than "
            "the %d that build an income figure (the admin income summary and "
            "the admin dashboard). Those readers are the contract this check "
            "exists for; if one was genuinely removed, lower "
            "EXPECTED_INCOME_READERS in the same change."
            % (readers, EXPECTED_INCOME_READERS)
        )
    return problems


# ---------------------------------------------------------------------------
# 6d. the activation fee is written where an income reader can see it
# ---------------------------------------------------------------------------
def check_activation_fee_is_recorded_as_income() -> list[str]:
    """The server half of the contract 6c pins on the client.

    check_income_readers_count_every_fee_type() proves the READERS query all
    three fee types. This proves the WRITER puts the activation fee somewhere a
    reader can find. approve_wallet_recharge withholds the one-time
    registration fee from a provider's FIRST approved recharge and records it
    as platform_fee on a RECHARGE row -- gross is what was paid, net is what
    was credited, and the difference is the platform's income. If it stops
    doing that, or writes the fee on a type nothing reads, or stops reading the
    fee from system_settings, the readers keep working and the income quietly
    drops. Same symptom, other end.

    Read from the LAST migration that defines the function, not from the
    earliest: a restatement is what the database ends up with, so a check
    against an earlier copy would keep passing on a function that no longer
    exists. That is the failure the restatement_diff tool exists for, applied
    here to a property rather than to a whole body.

    Deliberately NOT checked: that the notice text quotes the fee. Migration 73
    fixed a hardcoded "100 birr" in that message, and a check on prose would
    pass on a message that contradicts the ledger as long as it still said
    something.
    """
    problems: list[str] = []
    path, sql = last_migration_defining("approve_wallet_recharge")
    if path is None:
        return [
            "no migration defines public.approve_wallet_recharge(), so the "
            "one-time activation fee has no writer at all and RECHARGE rows "
            "carry no platform_fee for any income reader to sum"
        ]
    rel = str(path.relative_to(ROOT)).replace("\\", "/")
    body = function_body(sql, "approve_wallet_recharge")
    if not body:
        return [
            "could not read the body of approve_wallet_recharge() out of %s, "
            "so whether it records the activation fee as income cannot be "
            "checked" % rel
        ]

    if "'RECHARGE'" not in body:
        problems.append(
            "approve_wallet_recharge() in %s no longer writes a 'RECHARGE' "
            "ledger row, and that row is where every income reader finds the "
            "withheld activation fee" % rel
        )

    # The withheld amount itself. The fee is an expression over what was paid,
    # not a constant: gross is v_recharge.amount and net is v_credit, so
    # platform_fee must be their difference. A literal 0 here is exactly the
    # shape that made admin income render ETB 0.00 while money had been
    # collected.
    if not re.search(
        r"amount\s*-\s*v_credit[\s\S]{0,400}?platform_fee"
        r"|platform_fee[\s\S]{0,400}?amount\s*-\s*v_credit",
        body,
    ):
        problems.append(
            "the RECHARGE insert in approve_wallet_recharge() (%s) does not "
            "record platform_fee as the withheld part of the payment "
            "(v_recharge.amount - v_credit), so the platform can keep money "
            "that no income figure counts" % rel
        )

    if "provider_registration_fee" not in body:
        problems.append(
            "approve_wallet_recharge() in %s no longer reads "
            "provider_registration_fee from system_settings, so the activation "
            "fee stopped being data-driven" % rel
        )

    # A literal in place of the setting: the CEO changes the fee and the charge
    # keeps using the old number. This is the regression 73 fixed in the notice
    # text, and it is worth failing on in the arithmetic too.
    if re.search(r"v_reg_fee\s*:?=\s*\d", body):
        problems.append(
            "approve_wallet_recharge() in %s assigns a numeric literal to "
            "v_reg_fee, so the registration fee no longer follows the "
            "provider_registration_fee setting" % rel
        )

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
        # It must check BOTH delivery tables. notify_user() writes to
        # notifications on the server path and to notification_outbox on the
        # client path; the outbox row does not reach notifications until the
        # cron drain. A dedupe that reads only notifications therefore misses
        # every client-path notification — and the connectivity suite runs as
        # anon, so that is not a corner case, it is the normal case.
        if "notification_outbox" not in body_l:
            problems.append(
                "notify_user_once() deduplicates against notifications only. "
                "notify_user() queues client-path notifications in "
                "notification_outbox and they do not reach notifications until "
                "pg_cron drains them, so a retried call on that path finds no "
                "existing row and queues the same message a second time. The "
                "connectivity suite runs as anon, so this is the path it "
                "exercises.")
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
    # 5. The claim the brief got wrong. Completing a ride DEBITS the platform
    #    commission via deduct_transaction_fee; the fare is settled outside the
    #    app and never credited to a wallet. A message saying money was added
    #    contradicts the wallet screen immediately.
    #
    #    Checked against the notifier bodies only. Searching the raw migration
    #    text matches the COMMENT that explains why the message is not written
    #    that way, which is the opposite of the finding being looked for.
    def _body(name: str) -> str:
        path, sql = last_migration_defining(name)
        return function_body(sql, name).lower() if path else ""

    # 7. A plpgsql FOREACH may not iterate with an array-typed loop variable.
    #
    #    plpgsql refuses it at run time with 42804, and nothing catches it
    #    earlier: CREATE FUNCTION does not parse a plpgsql body, db push
    #    succeeds, and the privilege check passes because the function exists
    #    and is executable. Only calling it raises — so the assertion silently
    #    stops asserting, which is the most expensive way to fail.
    #
    #    The static approximation: find FOREACH loops and confirm the loop
    #    variable is not declared as an array type in the same file.
    foreach_rx = re.compile(r"FOREACH\s+(\w+)\s+IN\s+ARRAY", re.IGNORECASE)
    defn_rx = re.compile(
        r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?(\w+)\s*\(",
        re.IGNORECASE)
    # Only the CURRENT definition of each function is judged. A migration that
    # restated a function to fix it must not leave the harness permanently red
    # on the superseded body — that trains people to ignore it, and the fix
    # itself is what the check is asking for.
    all_fns: set[str] = set()
    for path in migration_files():
        all_fns.update(m.group(1) for m in defn_rx.finditer(_read(path)))

    for fn in sorted(all_fns):
        latest, sql = last_migration_defining(fn)
        if not sql:
            continue
        body = function_body(sql, fn)
        if not body:
            continue
        for f in foreach_rx.finditer(body):
            var = f.group(1)
            if re.search(r"\b%s\s+[a-z_]+\[\]" % re.escape(var), body,
                         re.IGNORECASE):
                problems.append(
                    f"{fn}() (last defined in {latest.name}) does FOREACH "
                    f"{var} IN ARRAY ... but {var} is declared as an array. "
                    f"plpgsql refuses an array-typed FOREACH loop variable at "
                    f"run time (42804) and CREATE FUNCTION will not catch it, "
                    f"so the function deploys and then raises on every call. "
                    f"Use a subscripted FOR i IN 1 .. array_length(x, 1) loop "
                    f"instead.")

    # 8. Declared source needles must occur in the bodies they inspect.
    #
    #    Two needles in this series were wrong and each reported a defect that
    #    did not exist, on every run, until a live run caught it: one was
    #    sensitive to line wrapping, one had a typo (v_ledgerid). The assertion
    #    is the thing that is broken in both cases, so nothing else in CI can
    #    notice. The live function declares the needles; this reads the same
    #    declaration so the typo is caught before a deploy rather than a cycle
    #    after one.
    #
    #    Read from the CURRENT definition of assert_source_needles_match, not
    #    from a hardcoded migration. The declaration moved from a 2-D ARRAY
    #    table (0093/0094) to two parallel 1-D arrays (0095), and pinning a
    #    filename would have quietly checked a superseded list.
    path, sql = last_migration_defining("assert_source_needles_match")
    if not sql:
        problems.append("assert_source_needles_match() is not defined, so the "
                        "declared source needles are never verified")
    else:
        body = function_body(sql, "assert_source_needles_match")

        def _declared(var: str) -> list[str]:
            """Entries of `var text[] := ARRAY[ ... ];`, in order.

            Scoped to the array literal rather than matching every lone quoted
            line in the body: a looser pattern also matched the string
            fragments in the failure messages, and reported 16 needles against
            9 targets.
            """
            m = re.search(
                r"%s\s+text\[\]\s*:=\s*ARRAY\[(.*?)\]\s*;" % re.escape(var),
                body, re.DOTALL)
            if not m:
                return []
            return [e.replace("''", "'")
                    for e in re.findall(r"'((?:[^']|'')*)'", m.group(1))]

        needles = _declared("v_needles")
        targets = _declared("v_targets")
        if not needles or not targets:
            problems.append(
                f"the declared needle list in {path.name} is empty or "
                f"unparseable ({len(needles)} needles, {len(targets)} "
                f"targets), so no needle is being verified")
        elif len(needles) != len(targets):
            problems.append(
                f"the needle and target lists in {path.name} are different "
                f"lengths ({len(needles)} vs {len(targets)}), so needles "
                f"would be checked against the wrong functions")
        else:
            for lit, fn in zip(needles, targets):
                needle = lit.replace("''", "'")
                target = _body(fn)
                if not target:
                    problems.append(f"declared needle {needle!r} names {fn}(), "
                                    f"which is not defined")
                    continue
                if needle.replace(" ", "") not in target.replace(" ", ""):
                    problems.append(
                        f"declared needle {needle!r} does not occur in "
                        f"{fn}(). An assertion comparing against text that is "
                        f"not there reports defects that do not exist and "
                        f"passes when it should fail; this exact typo shipped "
                        f"once (v_ledgerid for v_ledger_id).")


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

    # 3. Source-matching assertions must not be sensitive to line wrapping.
    #    Two assertions written in this series compared a hand-typed needle
    #    against whitespace-normalised prosrc and so reported defects that did
    #    not exist, purely because of where the author had wrapped a line.
    #    The rule the live database taught: match on the key, with whitespace
    #    removed on both sides, not on a formatted string.
    # A substring check against prosrc is fine for a single token
    # ('pg_advisory_xact_lock'); it is only the KEY match that broke, because a
    # key is written across a line break in the source and the needle was not.
    # So the rule is narrow: an assertion that embeds a multi-token SQL
    # expression (a quoted fragment with an operator) inside a position() call
    # must compare against a whitespace-stripped copy.
    #
    # The fragment is `''`-aware: SQL doubles an embedded quote, so the real
    # needle reads 'points-convert:''||v_ledger_id' and a plain [^']* stops at
    # the first doubled quote and never matches. That blindness is why the
    # mutation below went unnoticed until this was fixed.
    # Structural rather than regex-per-needle: SQL doubles an embedded quote,
    # so a needle like 'points-convert:''||v_ledger_id' cannot be matched by a
    # pattern that assumes one closing quote. Scanning the position() call and
    # asking two questions about it is immune to that.
    call_rx = re.compile(r"position\((.*?)\)", re.IGNORECASE | re.DOTALL)
    for name in ("assert_points_conversion_notifies",
                 "assert_notification_inbox_is_owner_only",
                 "assert_order_and_ride_receipts_are_sent",
                 "assert_approval_welcome_covers_all_paths",
                 "assert_notify_user_once_is_idempotent"):
        path, sql = last_migration_defining(name)
        if not path:
            problems.append(f"{name}() not found")
            continue
        for m in call_rx.finditer(sql):
            call = m.group(1)
            if "||" not in call:
                continue  # a single token, safe against line wrapping
            compared = re.search(r"\bIN\s+(\w+)\s*$", call.strip(),
                                 re.IGNORECASE)
            if compared and compared.group(1).lower() == "v_src":
                problems.append(
                    f"{name}() matches a multi-token SQL key (one containing "
                    f"||) against the whitespace-normalised function source. "
                    f"prosrc is normalised to single spaces, so that "
                    f"comparison depends on where the author wrapped the line "
                    f"and it reported a defect that did not exist on the "
                    f"first live run. Compare against a whitespace-stripped "
                    f"copy of the source instead.")
                break
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

    # 8. Every assertion the suite calls must be executable by the role the
    #    suite ACTUALLY runs as.
    #
    #    The suite builds SupabaseClient with the anon key and no session, so
    #    its RPCs run as `anon`. An assertion granted to `authenticated` only is
    #    invisible to it, and PostgREST reports that as PGRST202 "could not find
    #    the function in the schema cache" — which reads like a missing
    #    migration and sends the reader to the wrong file. Five assertions
    #    shipped that way and failed CI after a clean deploy.
    #
    #    The check has to pair the GRANT with the revoke: a function created in
    #    public has EXECUTE for PUBLIC by default and anon inherits it, so a
    #    GRANT naming authenticated looks correct while `REVOKE ... FROM anon`
    #    silently removes the only path the suite has.
    conn_path = ROOT / "tools/integration_test/connectivity_test.dart"
    if conn_path.exists():
        conn_sql = _read(conn_path)
        # (privilege statements are scanned in file order below, so a later
        # grant correctly supersedes an earlier revoke)

        # The real rule, established by checking what actually passes:
        #
        #   * A function created in public has EXECUTE for PUBLIC by default,
        #     and anon inherits it. GRANTing to `authenticated` is ADDITIVE and
        #     changes nothing for anon — several older assertions do exactly
        #     that and pass.
        #   * REVOKE ... FROM public, anon is what REMOVES the anon path. That
        #     is the active narrowing, and it is the mistake: the GRANT beside
        #     it reads correct while the suite still cannot call the function.
        #
        # So the check is not "is anon in the grant" but "is there a revoke of
        # anon/PUBLIC that the last privilege statement does not undo".
        #
        # Verified by the failure this was written for: five assertions in
        # migrations 86-90 were granted `authenticated, service_role` AND
        # revoked anon, and failed CI with PGRST202 after a clean deploy.
        # assert_ride_chain_has_no_dead_ends and six others are granted
        # `authenticated` only and are fine, because nothing revokes them.
        # Both statement shapes are used in this repo and both must be read:        #
        #   GRANT EXECUTE ON FUNCTION public.assert_x() TO anon, authenticated;
        #   GRANT EXECUTE ON FUNCTION public.assert_x(), public.assert_y()
        #     TO anon, authenticated, service_role;
        #
        # An earlier version of this check only understood the first and read
        # the second's "revoke ... from public" as removing the suite's only
        # access, flagging an assertion that demonstrably passes.
        stmt_rx = re.compile(
            r"(GRANT|REVOKE)\s+(?:ALL\s+)?(?:EXECUTE\s+)?ON\s+FUNCTION\s+"
            r"((?:public\.\w+\s*\(\s*\)\s*,?\s*)+)"
            r"((?:TO|FROM)\s+[^;]+);", re.IGNORECASE)
        # Postgres applies these in ORDER and cumulatively, so the final state
        # has to be modelled, not guessed:
        #
        #   GRANT  EXECUTE ... TO anon   -> anon has a DIRECT grant
        #   REVOKE EXECUTE ... FROM anon -> removes that direct grant
        #   REVOKE EXECUTE ... FROM public -> removes the INHERITED path, but
        #                                        a direct anon grant survives
        #
        # Two earlier versions of this check got this wrong in opposite
        # directions: one kept only the last statement (so a grant sitting
        # before a revoke-from-public looked lost), and one treated any grant
        # anywhere as permanent (so a revoke AFTER a grant was ignored — which
        # is exactly the shape of the bug this is meant to catch).
        direct: dict[str, set[str]] = {}
        public_revoked: set[str] = set()
        for path in migration_files():
            text = _read(path)
            for m in stmt_rx.finditer(text):
                verb = m.group(1).upper()
                funcs = re.findall(r"public\.(\w+)\s*\(\s*\)", m.group(2))
                keyword = "TO" if verb == "GRANT" else "FROM"
                roles_m = re.search(keyword + r"\s+([^;]+)", m.group(3),
                                    re.IGNORECASE)
                named = ({r.strip().lower() for r in roles_m.group(1).split(",")}
                         if roles_m else set())
                for fn in funcs:
                    if verb == "GRANT":
                        direct.setdefault(fn, set()).update(named)
                    else:
                        if "anon" in named:
                            direct.setdefault(fn, set()).discard("anon")
                        if "public" in named:
                            public_revoked.add(fn)

        # "Called by the suite" must mean CALLED, not merely named. A substring
        # search matched list_staff_jobs() and my_staff_record(), which appear
        # only inside comments explaining that anon is correctly refused — and
        # those two are supposed to be anon-revoked. Reading the comment as a
        # call is how a check starts demanding the opposite of the invariant.
        called = set(re.findall(r"rpcText(?:Diagnosed)?\('([\w]+)'\)", conn_sql))
        called |= set(re.findall(r"\bok\('([\w]+)'\)", conn_sql))
        # One test calls a function with a named argument list rather than
        # through ok()/rpcText; pick those up too.
        called |= set(re.findall(r"client\.rpc\('([\w]+)'", conn_sql))

        for name in sorted(called):
            has_direct = "anon" in direct.get(name, set())
            if has_direct:
                continue  # anon holds a direct grant; the suite can call it
            if name not in public_revoked:
                continue  # anon still inherits EXECUTE-for-PUBLIC
            problems.append(
                f"{name}() is called by the connectivity suite, which runs as "
                f"the anon role, but its final privilege state leaves anon "
                f"with no path: EXECUTE from PUBLIC is revoked and there is no "
                f"direct GRANT to anon. PostgREST reports that as PGRST202 "
                f"'could not find the function in the schema cache', which "
                f"reads like a missing migration rather than a missing "
                f"privilege.")

    # 9. The restatements in this series must not have lost anything. This runs
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
# 17. the Other document type is wired end to end
# ---------------------------------------------------------------------------
def check_other_document_type_is_wired() -> list[str]:
    """The fourth document-type choice collects and keeps its label.

    The schema half is asserted in SQL (assert_other_document_type_is_wired,
    migration 0099). This is the half SQL cannot see: the Dart surfaces that
    offer the choice and the upload pipeline that carries the label. Fails
    the moment any of the five pieces go missing, because each one failing
    silently produces a different dead end — a choice that cannot be named,
    a name nobody stores, or a stored label nobody displays.
    """
    problems: list[str] = []

    gate = _strip_comments(
        _read(LIB / "core" / "services" / "provider_doc_gate.dart"))
    service = _strip_comments(
        _read(LIB / "core" / "services" / "document_upload_service.dart"))
    partner = _strip_comments(
        _read(LIB / "features" / "provider" / "become_partner_screen.dart"))
    review = _strip_comments(
        _read(LIB / "features" / "admin" / "admin_provider_management_screen.dart"))

    # 1. The constant exists and is deliberately OUTSIDE the gate map: an
    #    OTHER document must not satisfy identity verification by existing.
    if "otherDocType = 'OTHER'" not in gate:
        problems.append("ProviderDocGate.otherDocType ('OTHER') is missing")
    other_in_map = re.search(
        r"acceptedDocTypes\s*=\s*<String, String>\{([^}]*)\}", gate)
    if other_in_map and "OTHER" in other_in_map.group(1):
        problems.append(
            "acceptedDocTypes contains OTHER — an Other document would "
            "satisfy the identity gate without proving identity")

    # 2. The upload pipeline carries the label.
    if "otherDocumentLabel" not in service:
        problems.append("uploadAndRecord has no otherDocumentLabel parameter")
    if "other_document_label" not in service:
        problems.append(
            "the upload service never writes other_document_label, so the "
            "label is collected and dropped")

    # 3. Both upload surfaces offer the choice.
    for label, src, needle in (
        ("the doc-gate upload sheet", gate, "otherDocType, 'Other'"),
        ("Become a Partner", partner, "ProviderDocGate.otherDocType"),
    ):
        if needle not in src:
            problems.append(f"{label} no longer offers the Other choice")

    # 4. The admin review shows the label, not a bare Other.
    if "other_document_label" not in review:
        problems.append(
            "the admin review screen never reads other_document_label, so "
            "staff review an unnamed Other document")
    if "_typeOf" not in review:
        problems.append("the admin review screen lost the row-level type name")

    return problems


# ---------------------------------------------------------------------------
# 18. the CEO account directory routes through the shared cascade
# ---------------------------------------------------------------------------
def check_ceo_account_directory_is_wired() -> list[str]:
    """The CEO delete reuses delete_user_account; it never forks it.

    The SQL half is asserted in the database
    (assert_ceo_delete_is_wired, migration 0100). This is the Dart half: the
    screen exists, is routed and tiled, gates on CEO in the client as well as
    the server, asks for a reason, confirms by typed word, and calls the two
    RPCs — while nothing in lib/ ever writes auth-adjacent tables directly.
    """
    problems: list[str] = []

    screen_path = LIB / "features" / "admin" / "admin_account_directory_screen.dart"
    raw_screen = _read(screen_path)
    if not raw_screen:
        return ["lib/features/admin/admin_account_directory_screen.dart is missing"]
    # Comments stripped: this screen's own doc comment names ceo_delete_user_
    # account() and the cascade, so a raw search would be satisfied by prose
    # describing code that no longer exists — the failure mode the 00093
    # needle bug in this repo already cost two deploy cycles to.
    screen = _strip_comments(raw_screen)

    router = _read(LIB / "routing" / "app_router.dart")
    dashboard = _read(LIB / "features" / "admin" / "admin_dashboard.dart")
    ceo_dash = _read(LIB / "features" / "ceo" / "ceo_dashboard.dart")

    # The RPCs, both called, and the typed destructive confirmation.
    for needle in ("ceo_account_directory", "ceo_delete_user_account",
                   "TypedConfirmDialog", "p_reason"):
        if needle not in screen:
            problems.append(f"the directory screen no longer references {needle}")

    # Client-side CEO gate (the server re-checks everything; this avoids
    # rendering a refused workspace).
    if "is_ceo_authority" not in screen:
        problems.append(
            "the directory screen no longer checks is_ceo_authority() before "
            "loading")

    # Routed and tiled.
    if "/admin/accounts" not in router:
        problems.append("/admin/accounts is not routed")
    if "/admin/accounts" not in dashboard:
        problems.append("no dashboard tile points at /admin/accounts")
    if "/admin/accounts" not in ceo_dash:
        problems.append(
            "the CEO workspace danger-zone no longer links the directory")

    # The new path must not go THROUGH the request table: writing a request
    # and then approving it from the same account is a form filled in twice,
    # and it would blur whose decision a row recorded. (The request queue
    # itself — admin_deletion_requests_screen.dart calling reject_account_
    # deletion — is the existing non-CEO flow and must keep working, so only
    # THIS screen is inspected.)
    for forbidden in ("account_deletion_requests", "approve_account_deletion"):
        if forbidden in screen:
            problems.append(
                f"the directory screen references {forbidden} — the CEO path "
                "is a direct delete through the shared cascade, not a "
                "self-approved request")

    return problems


# ---------------------------------------------------------------------------
# 19. every picker that feeds a storage bucket is downscaled first
# ---------------------------------------------------------------------------
def check_payment_screenshots_are_downscaled() -> list[str]:
    """Every picker that feeds a storage bucket must re-encode, not forward.

    A bare `pickImage(source: ImageSource.gallery, imageQuality: 85)` sends
    the camera's original bytes. Every bucket here has a file_size_limit and
    an image/jpeg|png|webp mime list, so that upload is refused for a modern
    phone photo or an iOS HEIC — and the report that reaches us is never
    "the screenshot is too big", it is "payment screenshot is not accepting
    from provider section", because the refusal happens server-side inside a
    bucket the client never sees.

    Checked at the call site, not in the picker: these are independent
    screens, and the one that was wrong was correct code in isolation.

    `pickMultiImage` takes no `source:` argument, so a regex written for
    `pickImage` silently reports zero matches against it — a check that
    reads as green because it never looked. Both spellings are matched here,
    and the multi-image sites (provider gallery, product form, vehicle form)
    are the three that had been uncovered for the life of the check.
    """
    problems: list[str] = []

    # Every screen that uploads a payment proof or a screenshot, with the
    # bucket it targets (migration 96's limits).
    sites = [
        ("recharge_screen.dart (payment-screenshots, 5MB)",
         LIB / "features" / "wallet" / "recharge_screen.dart",
         ["_pickScreenshot"], "single"),
        ("user_checkout_screen.dart (payment-proofs)",
         LIB / "features" / "user" / "user_checkout_screen.dart",
         ["_pickScreenshot", "_pickNationalId"], "single"),
        ("user_order_detail_screen.dart (payment-proofs)",
         LIB / "features" / "user" / "user_order_detail_screen.dart",
         ["_submitPayment"], "single"),
        # Multi-image pickers are a different API with no `source:` argument,
        # so the pickImage regex above can never see them. That is how three
        # 5MB-bucket uploads sat here forwarding full-resolution phone photos
        # with nothing complaining: this check read as green the whole time.
        ("provider_gallery_screen.dart (provider-gallery, 5MB)",
         LIB / "features" / "provider" / "provider_gallery_screen.dart",
         ["_add"], "multi"),
        ("provider_product_form_screen.dart (product-images, 5MB)",
         LIB / "features" / "provider" / "provider_product_form_screen.dart",
         ["_pickImages"], "multi"),
        ("vehicle_form_screen.dart (vehicle-images, 5MB)",
         LIB / "features" / "vehicle" / "vehicle_form_screen.dart",
         ["_addPhotos"], "multi"),
    ]

    for label, path, fns, kind in sites:
        src = _strip_comments(_read(path))
        if not src:
            problems.append(f"{label}: the file is missing")
            continue
        if kind == "single":
            found = re.finditer(
                r"pickImage\(\s*source:\s*ImageSource\.gallery(.{0,320}?)\)",
                src, re.DOTALL)
        else:
            found = re.finditer(
                r"pickMultiImage\((.{0,320}?)\)\s*;", src, re.DOTALL)
        for m in found:
            args = m.group(1)
            if "maxWidth" not in args or "maxHeight" not in args:
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    f"{label}: the gallery pick at line {line} forwards the "
                    "original image (no maxWidth/maxHeight), so a large photo "
                    "or a HEIC is refused by the bucket")
        # The named methods must still exist at all.
        for fn in fns:
            if fn not in src:
                problems.append(f"{label}: {fn} is gone — check the upload path")

    # The service must quote a limit the bucket actually has, and check it
    # before uploading rather than surfacing storage's refusal.
    wallet = _strip_comments(
        _read(LIB / "core" / "services" / "wallet_service.dart"))
    if "payment-screenshots" not in wallet:
        problems.append(
            "WalletService no longer targets the payment-screenshots bucket")
    if not re.search(r"5\s*\*\s*1024\s*\*\s*1024", wallet):
        problems.append(
            "uploadScreenshot no longer checks the 5MB limit up front, so a "
            "refused image reaches the provider as a raw storage error")

    return problems


# ---------------------------------------------------------------------------
# 20. the policies the upload and money paths need are in a migration the
#     pipeline actually executes
# ---------------------------------------------------------------------------
# check_client_buckets_are_created (6b) asks whether each bucket EXISTS in a
# migration at or after the baseline. It does not ask whether anyone is allowed
# to write to it -- and those are separate questions, which is how the gallery
# was fixed while document upload stayed broken.
#
# The live half is assert_client_buckets_have_write_and_read_policies() and
# assert_owner_can_read_and_write_their_money() (migration 0102). This is the
# source half: that a CURRENT migration declares those policies at all, so the
# pipeline has something to execute and the assertions have something to find.
BUCKET_POLICY_RX = re.compile(
    r"CREATE\s+POLICY\s+(\w+)\s+ON\s+storage\.objects\s+"
    r"FOR\s+(INSERT|SELECT|UPDATE|DELETE|ALL)\b(.*?);",
    re.IGNORECASE | re.DOTALL,
)

#: (table, command) a non-staff caller must be able to perform. Names the
#: caller, never is_admin()/staff_has_permission(): a provider is neither, and
#: that gap is the bug migration 0102 exists for.
MONEY_POLICY_NEEDS = (
    ("wallets", "SELECT"),
    ("wallet_recharge_requests", "INSERT"),
    ("wallet_recharge_requests", "SELECT"),
)


def _current_migrations():
    """Migrations at or after the deploy baseline -- the only ones that run."""
    for path in migration_files():
        version = path.name.split("_", 1)[0]
        if version.isdigit() and int(version) >= BASELINE:
            yield path


def check_client_write_policies_are_executable() -> list[str]:
    """Every bucket lib/ writes to has a write AND a read policy, and the
    wallet tables have caller-named ones, all declared after the baseline.

    A policy declared below the baseline is a policy in a file nobody runs: the
    deploy workflow marks those applied with `migration repair`, which writes
    the history table and never executes the file. The gallery bucket proved
    the assumption is false, and the same reasoning applied to a policy says a
    bucket can be present, correctly sized, correctly private -- and still
    refuse every upload, because the INSERT policy that would have permitted it
    only ever existed on paper.
    """
    problems: list[str] = []

    # --- storage buckets ---------------------------------------------------
    # bucket -> commands declared in a current migration, comments stripped so
    # a header explaining the policy cannot stand in for the policy itself.
    cmds: dict[str, set[str]] = {}
    for path in _current_migrations():
        body = re.sub(r"--[^\n]*", " ", _read(path))
        body = re.sub(r"/\*.*?.\*/", " ", body, flags=re.DOTALL)
        for m in BUCKET_POLICY_RX.finditer(body):
            rest = m.group(3)
            names = re.findall(r"bucket_id\s*=\s*'([a-z0-9][a-z0-9-]*)'", rest)
            for bucket in names:
                cmds.setdefault(bucket, set()).add(m.group(2).upper())

    for bucket in sorted(dart_buckets()[0]):
        have = cmds.get(bucket, set())
        # ALL covers both sides, which is why it is expanded rather than
        # compared: a bucket guarded by one FOR ALL policy is not half-open.
        writes = bool(have & {"INSERT", "ALL"})
        reads = bool(have & {"SELECT", "ALL"})
        if not writes or not reads:
            missing = ", ".join(
                c for c, ok in (("INSERT", writes), ("SELECT", reads)) if not ok
            )
            problems.append(
                "no migration at or after the deploy baseline %d creates a %s "
                "policy on storage.objects for bucket %r (declared there: %s). "
                "A bucket with no INSERT policy refuses every upload with 'new "
                "row violates row-level security policy for table objects', and "
                "one with no SELECT policy fails every signed-URL fetch. Older "
                "files are marked applied WITHOUT being executed, so a policy "
                "declared only there does not exist."
                % (BASELINE, " and ".join(missing.split(" and ")), bucket,
                   ", ".join(sorted(have)) or "none")
            )

    # --- the money tables --------------------------------------------------
    all_current = "\n".join(
        re.sub(r"--[^\n]*", " ", _read(p)) for p in _current_migrations()
    )
    for table, cmd in MONEY_POLICY_NEEDS:
        rx = re.compile(
            r"CREATE\s+POLICY\s+\w+\s+ON\s+(?:public\.)?%s\s+FOR\s+%s\b(.*?);"
            % (re.escape(table), cmd),
            re.IGNORECASE | re.DOTALL,
        )
        bodies = [m.group(1).lower() for m in rx.finditer(all_current)]
        if not bodies:
            problems.append(
                "no migration at or after the baseline creates a %s policy on "
                "public.%s, so the client path that performs it is refused and "
                "the user is told the record does not exist" % (cmd, table)
            )
        elif not any(re.search(r"auth\.uid|owns_provider_profile", b) for b in bodies):
            problems.append(
                "the only %s policy on public.%s declared after the baseline "
                "does not name the caller (no auth.uid() and no "
                "owns_provider_profile()). A staff- or admin-scoped policy is "
                "unreachable for the signed-in provider who owns the row, which "
                "is exactly how a wallet lookup returns nothing"
                % (cmd, table)
            )

    # --- the assertions that make it stick ---------------------------------
    for guard in ("assert_client_buckets_have_write_and_read_policies",
                  "assert_owner_can_read_and_write_their_money"):
        if guard not in all_current:
            problems.append(
                "the live guard %s() is missing, so the policies above can "
                "quietly stop existing and nothing would say so" % guard
            )

    problems.extend(_money_assertion_cannot_pass_vacuously())

    return problems


def _money_assertion_cannot_pass_vacuously() -> list[str]:
    """The money assertion shipped broken and reported itself as a finding.

    The first version (migration 0102) walked a `text[][]` by subscript and
    produced a NULL table name on the live database, so it raised
    `MONEY_TABLE_MISSING: public.<NULL>` -- naming a table that has never been
    missing. Two separate defects let that read as a schema problem:

      * a 2-D array walked by subscript is the same construct migration 95
        records as having cost two deploy cycles, so the shape is banned here
        rather than rediscovered;
      * its vacuity guard was `v_checked <> array_length(...)`, which is NULL
        -- not true -- when the loop never runs, and `IF NULL` falls through.
        A guard that cannot fail is worse than no guard, because it converts a
        broken check into a green build.

    `function_body` strips comments, so the prose above cannot satisfy these.
    """
    problems: list[str] = []
    path, sql = last_migration_defining(
        "assert_owner_can_read_and_write_their_money")
    if path is None:
        return ["no migration defines assert_owner_can_read_and_write_their_money()"]

    body = function_body(sql, "assert_owner_can_read_and_write_their_money")
    if not body:
        return [
            "%s: could not extract the body of "
            "assert_owner_can_read_and_write_their_money(), so its shape "
            "cannot be checked" % path.name
        ]
    rel = path.name

    if re.search(r"\w+\s+text\s*\[\s*\]\s*\[\s*\]", body):
        problems.append(
            "%s: the money assertion declares a 2-D array. Walking one by "
            "subscript is the construct that shipped broken (it yielded a NULL "
            "table name live and reported a table that exists as missing), and "
            "migration 95 already records a 2-D needle table costing two deploy "
            "cycles. Use two flat arrays zipped with unnest, the shape "
            "migration 0101 uses." % rel
        )

    if re.search(r"\bFOREACH\b", body):
        problems.append(
            "%s: the money assertion uses FOREACH. plpgsql refuses an "
            "array-typed FOREACH loop variable at RUN time (42804); "
            "CREATE FUNCTION does not catch it, so the function deploys green "
            "and raises on every call. The FOREACH lint elsewhere in this file "
            "exists for exactly that." % rel
        )

    if "unnest(" not in body:
        problems.append(
            "%s: the money assertion does not zip its requirement list with "
            "unnest(a, b). The two flat arrays plus "
            "`FOR x, y IN SELECT * FROM unnest(a, b)` shape is what migration "
            "0101 uses in production and is the one that has been proven "
            "against a live database." % rel
        )

    # A guard that cannot fail converts a broken check into a green build. The
    # coalesce need not sit inline in the comparison -- assigning it to the
    # expected count first is the same thing -- so this asks whether the body
    # neutralises NULL anywhere it compares, rather than pinning one spelling.
    if not re.search(r"v_checked\s*<>", body):
        problems.append(
            "%s: the money assertion has no `v_checked <> ...` comparison, so "
            "there is nothing stopping it reporting success after "
            "examining nothing" % rel
        )
    elif "coalesce" not in body.lower():
        problems.append(
            "%s: the money assertion compares v_checked against an expected "
            "count with no coalesce anywhere. When the loop never runs that "
            "count is NULL and `v_checked <> NULL` is NULL, which `IF` treats "
            "as false -- so the guard reports success precisely when it has "
            "checked nothing, which is the failure this check exists to "
            "prevent." % rel
        )

    # An empty requirement list must also fail. coalesce(... , 0) alone does
    # not catch `0 <> 0`.
    if not re.search(r"expected\s*=\s*0|=\s*0\s+OR|OR\s+\w*expected\w*\s*=\s*0", body):
        problems.append(
            "%s: the money assertion never fails on an EMPTY requirement "
            "list. `0 <> 0` is false, so a list that unzips to nothing is "
            "reported as a clean pass rather than as a check that examined "
            "nothing." % rel
        )

    if "MONEY_CHECK_MALFORMED" not in body:
        problems.append(
            "%s: the money assertion has no MONEY_CHECK_MALFORMED guard, so if "
            "its own loop breaks again it reports the breakage as a finding "
            "about the schema and sends the reader to the wrong file." % rel
        )

    return problems


# ---------------------------------------------------------------------------
# 21. a refused recharge names what is actually missing
# ---------------------------------------------------------------------------
def check_recharge_refusals_name_the_real_cause() -> list[str]:
    """friendly_error() maps any error whose text contains 'not found' to
    "That item could not be found. It may have been removed."

    recharge_screen.dart threw `Exception('Wallet not found')` for a lookup
    that returned nothing, and `Exception('Provider profile not found')` for
    the same thing one step earlier. Both were caught by the generic handler
    and rendered as the generic sentence -- so three unrelated failures (no
    provider profile, no wallet, an insert RLS refused) reached the user as
    one indistinguishable "not found", and the report that came back said the
    wrong thing about which layer was broken.

    The rule this pins: a locally-raised refusal must not carry a phrase the
    shared mapper will swallow. Either map it to something a person can act
    on, or let it fall through to the generic fallback -- but it must not
    borrow the mapper's vocabulary.
    """
    problems: list[str] = []
    screen = _strip_comments(
        _read(LIB / "features" / "wallet" / "recharge_screen.dart"))
    if not screen:
        return ["lib/features/wallet/recharge_screen.dart is missing"]

    mapper = _strip_comments(_read(LIB / "core" / "utils" / "friendly_error.dart"))
    m = re.search(r"'404',\s*'not found'", mapper)
    if not m:
        # The mapper changed shape. Stop asserting against a needle that may no
        # longer mean what it meant -- a check that cannot see its own subject
        # is worse than no check.
        return [
            "friendly_error.dart no longer contains the 'not found' needle list, "
            "so this check cannot tell which local refusals it swallows; "
            "re-derive it against the new classifier"
        ]

    for thrown in re.findall(r"throw\s+Exception\(\s*'([^']*)'\s*\)", screen):
        if "not found" in thrown.lower():
            problems.append(
                "recharge_screen.dart throws Exception(%r), and "
                "friendly_error maps any error containing 'not found' to "
                '"That item could not be found. It may have been removed." A '
                "local precondition failure must not borrow the mapper's "
                "vocabulary -- say what is missing in terms the user can act "
                "on, so this failure is distinguishable from a genuinely "
                "deleted record" % thrown
            )

    # The two lookups must still exist: a check that passes because the code
    # was deleted is the failure mode this file's header warns about.
    for needle, why in (
        ("from('provider_profiles')", "the provider profile lookup is gone"),
        ("from('wallets')", "the wallet lookup is gone"),
        ("submitRecharge", "the recharge submit call is gone"),
    ):
        if needle not in screen:
            problems.append(f"recharge_screen.dart: {why}")

    return problems


# ---------------------------------------------------------------------------
# 22. the provider gallery is still reachable from the provider dashboard
# ---------------------------------------------------------------------------
# Reported as "the gallery is gone from the dashboard". Nothing had been
# deleted: the dashboard redesign had moved the tile one level down, into the
# Business tab of DashboardTopTabs, and the screen, the route, the bucket and
# the RPCs were all exactly where they had been since the root commit.
#
# A feature that is one refactor away from being unreachable needs its entry
# point asserted, the same way the CEO directory's is (check 18). The tile is
# allowed to live inside a tab -- what cannot be allowed is for the tab, the
# route, or the tile to disappear without a check going red.
def check_provider_gallery_is_wired() -> list[str]:
    """Gallery screen, route, dashboard tile, shared grid, loud errors.

    The SQL half is asserted in the database (assert_app_buckets_exist in
    migration 96 for the bucket; the INSERT/UPDATE/DELETE policies on
    `provider-gallery` are checked by check_client_write_policies_are_executable).
    This is the Dart half: the feature a provider is told to use actually has
    something to tap.
    """
    problems: list[str] = []

    screen_path = LIB / "features" / "provider" / "provider_gallery_screen.dart"
    raw = _read(screen_path)
    if not raw:
        return ["lib/features/provider/provider_gallery_screen.dart is missing"]
    # Comments stripped: this screen's doc comment names the bucket, the path
    # convention and both RPCs, so a raw search would be satisfied by prose
    # describing code that is no longer there.
    screen = _strip_comments(raw)

    # The screen's own contract: read its table, write through the two RPCs,
    # render the shared grid.
    for needle, why in (
        ("from('provider_gallery')", "the gallery is no longer read"),
        ("add_gallery_image", "the add call is gone"),
        ("delete_gallery_image", "the delete call is gone"),
        ("PhotoGrid", "the gallery no longer uses the shared photo grid"),
        ("provider-gallery", "the gallery no longer names its bucket"),
    ):
        if needle not in screen:
            problems.append(f"provider_gallery_screen.dart: {why}")

    # The owner-scoped storage path. The bucket's INSERT/UPDATE/DELETE
    # policies scope on `auth.uid()::text = first path segment`, so a path
    # that does not lead with the caller's uid is refused by storage with an
    # error the provider cannot act on.
    if not re.search(r"\$uid/\$", screen):
        problems.append(
            "provider_gallery_screen.dart no longer builds the owner-scoped "
            "'<uid>/<image id>/<file>' path its bucket policies require")

    # Routed, and tiled from the provider dashboard. The tile may sit inside a
    # DashboardTopTabs entry -- that is a design choice, not a lost feature.
    router = _read(LIB / "routing" / "app_router.dart")
    if "/provider/gallery/:id" not in router:
        problems.append("/provider/gallery/:id is no longer routed")
    if "ProviderGalleryScreen" not in router:
        problems.append("the gallery route no longer builds ProviderGalleryScreen")

    dashboard = _strip_comments(
        _read(LIB / "features" / "provider" / "service_provider_dashboard.dart"))
    if not dashboard:
        problems.append("service_provider_dashboard.dart is missing")
    else:
        if "/provider/gallery/" not in dashboard:
            problems.append(
                "no tile on the provider dashboard points at /provider/gallery/ "
                "-- the gallery is unreachable")
        # The route is /provider/gallery/:id, so the tile must interpolate the
        # provider id. Pushing a literal or a null would match no route.
        if not re.search(r"/provider/gallery/\$\{", dashboard):
            problems.append(
                "the gallery tile does not interpolate the provider id into "
                "/provider/gallery/, so the path it pushes matches no route")
        # A string search finds dead code. A tile switched off with
        # `if (false)`, or commented out, still contains the path -- the
        # feature is unreachable and this check reads green. Falsification
        # caught exactly that when this check was written: the guard is not
        # adjacent to the push, so matching "the nearest if before the string"
        # does not catch it either. The rule is therefore blunt on purpose --
        # a constant-false condition anywhere in a dashboard is always a
        # disabled feature, never a legitimate branch.
        for cond in re.findall(r"if\s*\(\s*(false|0|null)\s*\)", dashboard,
                               re.IGNORECASE):
            problems.append(
                "the provider dashboard contains a constant-false guard "
                "`if (%s)`, which disables a tile -- the gallery is "
                "unreachable however correct the rest of it is"
                % cond.lower())
        # The tile must actually be inside a tab/entry list that gets built,
        # not commented out of one.
        if "DashboardTopTabs" not in dashboard:
            problems.append(
                "the provider dashboard no longer builds DashboardTopTabs; "
                "the gallery tile is expected to live in one of its tabs")
        # ...and that id has to come from a provider profile row that the
        # dashboard actually loads, or the tile is dead on arrival.
        if "from('provider_profiles')" not in dashboard:
            problems.append(
                "the provider dashboard no longer loads provider_profiles, so "
                "it has no id to push to the gallery route with")

    # Errors surface. A gallery that silently swallows a failed upload reads
    # to the provider as "the app is broken", which is the exact report that
    # sent us looking.
    if "friendlyError" not in screen:
        problems.append(
            "provider_gallery_screen.dart no longer routes failures through "
            "friendlyError, so a refused upload would fail silently")

    # The shared grid must still be the 3-across default; a per-screen
    # column override here would diverge from every other photo surface.
    if re.search(r"PhotoGrid\([^)]*crossAxisCount", screen, re.DOTALL):            problems.append(
                "provider_gallery_screen.dart overrides the shared PhotoGrid "
                "column count; the 3-across default is the product decision")

    return problems


# ---------------------------------------------------------------------------
# 23. the role quick-action shortcuts share one definition and still resolve
# ---------------------------------------------------------------------------
# "Book a ride" on the user home screen was the only instance of this pill
# pattern, which made it simultaneously the only definition of the pattern and
# the reason two provider dashboards had no shortcut at all. Giving each role
# its own hand-written pill would restore the drift in a new place, so the
# markup lives once in QuickActionPill and the roles call it.
#
# What this protects, in the order things actually broke here:
#   1. the pill style is defined once (no second hand-rolled green pill)
#   2. each role still offers a shortcut at all
#   3. each shortcut's target is a declared route, not a hopeful push
#   4. no shortcut is invented for a role that cannot exist
QUICK_ACTION_ROLES = (
    ("user_home_screen.dart", "user", "Book a ride", "/user/ride-request"),
    ("service_provider_dashboard.dart", "service provider",
     "My Gallery", "/provider/gallery/"),
    ("vehicle_provider_dashboard.dart", "vehicle provider",
     "Ride Requests", "/vehicle/ride-requests"),
)


def check_quick_action_shortcuts_are_wired() -> list[str]:
    problems: list[str] = []

    if not _read(LIB / "core" / "widgets" / "quick_action_pill.dart"):
        return ["lib/core/widgets/quick_action_pill.dart is missing"]

    # One definition. A role screen that hand-rolls a brand-green rounded pill
    # is the drift this widget exists to prevent.
    #
    # Scoped to the three role screens on purpose. Scanned across all of lib/
    # it also matches legitimate components that merely share the colour and
    # radius -- the category chip in the user home tab rail was the first
    # false positive -- and a check that cries wolf gets ignored.
    pill_style = re.compile(
        r"AppTheme\.primaryGreen\s*,[\s\S]{0,200}?BorderRadius\.circular\(20\)")
    role_files = {f for f, _, _, _ in QUICK_ACTION_ROLES}
    for path in sorted(dart_sources()):
        if path.name not in role_files:
            continue
        src = _strip_comments(_read(path))
        # A match that is not inside a QuickActionPill call is a second pill.
        for m in pill_style.finditer(src):
            window = src[max(0, m.start() - 400):m.start()]
            if "QuickActionPill" not in window:
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    "%s hand-rolls a brand-green pill at line %d instead of "
                    "using QuickActionPill — that is how the dashboards end up "
                    "with three different button styles"
                    % (path.name, line))

    router = _read(LIB / "routing" / "app_router.dart")

    for filename, role, label, target in QUICK_ACTION_ROLES:
        found = False
        for path in sorted(dart_sources()):
            if path.name != filename:
                continue
            src = _strip_comments(_read(path))
            if "QuickActionPill" not in src:
                problems.append(
                    "%s (%s) offers no QuickActionPill shortcut" % (filename, role))
                continue
            found = True
            # The label and the target must be inside the PILL'S OWN call, not
            # merely somewhere in the file. A file-level search is satisfied
            # by the tab entry that the pill duplicates -- so a pill pointed at
            # the wrong route reads green. Falsification caught exactly that.
            for m in re.finditer(r"QuickActionPill\(", src):
                # From this call to the next one (or a generous cap).
                nxt = src.find("QuickActionPill(", m.end())
                block = src[m.start():nxt if nxt != -1 else m.start() + 600]
                if label not in block:
                    problems.append(
                        "%s: a QuickActionPill is not labelled %r"
                        % (filename, label))
                if target not in block:
                    problems.append(
                        "%s: the %s pill does not push %s (found %r in it)"
                        % (filename, role, target,
                           re.findall(r"context\.push\('([^']*)'\)", block)))
            if not re.search(r"QuickActionPill\(", src):
                problems.append(
                    "%s (%s) offers no QuickActionPill shortcut"
                    % (filename, role))
                # A gallery shortcut needs a provider id in the path; a literal
                # would match a route but show the wrong provider's photos.
                if target.endswith("/") and not re.search(
                        re.escape(target) + r"\$\{", block):
                    problems.append(
                        "%s: the gallery pill does not interpolate the provider "
                        "id into the path" % filename)
            if not re.search(r"QuickActionPill\(", src):
                problems.append(
                    "%s (%s) offers no QuickActionPill shortcut"
                    % (filename, role))
            if re.search(r"if\s*\(\s*(false|0|null)\s*\)", src, re.IGNORECASE):
                problems.append(
                    "%s contains a constant-false guard, which disables a tile "
                    "or shortcut" % filename)
        if not found:
            problems.append("%s is missing" % filename)

    # Every target must be a declared route. check_routes_resolve covers
    # every push in lib/; this states the expectation for these three so the
    # failure names the shortcut rather than a bare push.
    for filename, role, label, target in QUICK_ACTION_ROLES:
        route = target.rstrip("/")
        if route == "/provider/gallery":
            continue  # parameterised; asserted above
        if ("path: '%s'" % route) not in router:
            problems.append(
                "the %s shortcut targets %s, which is not a declared route"
                % (role, route))

    # There is no booking provider. `app_role` is exactly
    # (USER, VEHICLE_PROVIDER, SERVICE_PROVIDER, ADMIN) and provider_type is
    # constrained to the two provider values, so a booking-provider dashboard
    # shortcut would point at a screen no account can ever reach. BOOKING is a
    # category service_group on the shopper side, not a provider role.
    for path in sorted(dart_sources()):
        src = _strip_comments(_read(path))
        if re.search(r"QuickActionPill\([\s\S]{0,200}?BOOKING", src):
            problems.append(
                "%s offers a BOOKING_PROVIDER shortcut, but no such role "
                "exists in app_role" % path.name)

    return problems


# ---------------------------------------------------------------------------
# 24. the gallery's READ path is in a migration the pipeline executes
# ---------------------------------------------------------------------------
# Reported fixed three times. The write path was rebuilt post-baseline as
# SECURITY DEFINER functions; the read path was "already covered" by
# provider_gallery_owner_read, which lives in 0014 -- below BASELINE, so the
# deploy marks it applied without executing it. The 0102 assertion cannot see
# this: it inspects storage.objects, not the table the rows live in.
def check_gallery_read_path_is_migrated() -> list[str]:
    problems: list[str] = []

    # The policies must be created in a migration the pipeline runs, not only
    # in one that is skipped.
    for policy in ("provider_gallery_owner_read", "provider_gallery_public_read"):
        defining = []
        for p in _current_migrations():
            src = _strip_comments(_read(p))
            if src and f"CREATE POLICY {policy}" in src:
                defining.append(p.name)
        if not defining:
            pre = [
                p.name for p in migration_files()
                # isdigit, not int(): 0022a is a real migration prefix and
                # int() raises on it. Falsification caught this the hard way
                # -- the ValueError aborted the whole harness instead of
                # failing one check, which hides every other result.
                if p.name.split("_", 1)[0].isdigit()
                and int(p.name.split("_", 1)[0]) < BASELINE
                and policy in (_strip_comments(_read(p)) or "")
            ]
            problems.append(
                "%s is only defined in pre-baseline migrations (%s), which the "
                "deploy workflow marks applied WITHOUT executing. A provider "
                "reading their own gallery gets zero rows while their upload "
                "succeeds -- migration 0104 restates it."
                % (policy, ", ".join(pre) or "none found"))

    screen = _strip_comments(
        _read(LIB / "features" / "provider" / "provider_gallery_screen.dart"))
    if "from('provider_gallery')" not in screen:
        problems.append(
            "the gallery screen no longer reads provider_gallery directly")

    return problems


# ---------------------------------------------------------------------------
# 25. profile completion + no dead menu rows
# ---------------------------------------------------------------------------
# Two failures that look identical from the user's side -- a tap that does
# nothing. "Edit Profile" was a _menuTile with no onTap at all, so a
# tappable-looking row swallowed the tap silently, which is indistinguishable
# from a broken app. Nothing asserted it, because nothing looked.
def check_profile_completion_and_taps_are_wired() -> list[str]:
    problems: list[str] = []

    # -- The OAuth gate --
    router = _strip_comments(_read(LIB / "routing" / "app_router.dart"))
    if "CompleteProfileScreen" not in router:
        problems.append("CompleteProfileScreen is not routed")
    if "isVerifiable" not in router:
        problems.append(
            "the router no longer gates on profile.isVerifiable, so an OAuth "
            "account can reach the app without a phone number")
    # The gate must exempt the screen it sends people to, or the user
    # ping-pongs between the app and the form forever.
    if "'/complete-profile'" not in (function_body(router, "_isApprovalRoute")
                                     or router):
        problems.append(
            "/complete-profile is not an approval route. An OAuth account is "
            "PENDING_APPROVAL, so the pending gate would bounce it off the "
            "completion screen and the completeness gate would send it back")

    model = _strip_comments(_read(LIB / "core" / "models" / "user_profile.dart"))
    if "isVerifiable" not in model:
        problems.append(
            "UserProfile.isVerifiable is gone, so the router gate has nothing "
            "to test")
    # 'New User' is the trigger's placeholder, not a name. A null check alone
    # waves every Google account straight through.
    if "'New User'" not in model:
        problems.append(
            "UserProfile no longer treats the trigger's 'New User' placeholder "
            "as incomplete -- a Google account has a non-null name that is not "
            "a name")

    for screen, folder in (("complete_profile_screen.dart", "auth"),
                           ("edit_profile_screen.dart", "user")):
        src = _strip_comments(
            _read(LIB / "features" / folder / screen))
        if not src:
            problems.append("%s is missing" % screen)
            continue
        if "complete_profile" not in src:
            problems.append("%s no longer calls the complete_profile RPC"
                            % screen)
        # The RPC raises on empty values; the client must not be the only
        # thing enforcing them, and the two must agree on which fields.
        for field in ("p_full_name", "p_phone", "p_kebele", "p_street_road"):
            if field not in src:
                problems.append(
                    "%s does not send %s, so the form and the RPC disagree "
                    "about what is required" % (screen, field))

    # -- No dead menu rows --
    profile = _read(LIB / "features" / "user" / "user_profile_screen.dart")
    if profile:
        for m in re.finditer(r"_menuTile\(", profile):
            i = m.end() - 1
            depth = 0
            for j in range(i, len(profile)):
                if profile[j] == "(":
                    depth += 1
                elif profile[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
            call = profile[m.start():j + 1]
            if "onTap" not in call and "Navigator" not in call:
                label = re.search(r"'([^']+)'", call)
                problems.append(
                    "the %r menu row on the account screen still has no onTap "
                    "-- a tappable-looking row that does nothing when tapped"
                    % (label.group(1) if label else "?"))

    return problems


# ---------------------------------------------------------------------------
# 26. the redirect rules the cycle simulation models
# ---------------------------------------------------------------------------
# `redirect_cycle_simulation.py` proves the router's rules cannot deadlock,
# but it mirrors them. The moment app_router.dart's redirect() and the mirror
# disagree, the simulation is asserting something the app does not do, which
# is a green light for a crash. These are the exact clauses it depends on.
def check_router_matches_the_cycle_simulation() -> list[str]:
    problems: list[str] = []
    router = _strip_comments(_read(LIB / "routing" / "app_router.dart"))

    # The simulation exempts approved accounts from the completeness gate. If
    # the app stops doing that, an approved account with an incomplete profile
    # is sent to /complete-profile and forwarded straight back out of it.
    if "needsProfileCompletion" not in router:
        problems.append(
            "the profile-completeness gate no longer exists as "
            "needsProfileCompletion; redirect_cycle_simulation.py models it")
    if "!authState.isApproved" not in router:
        problems.append(
            "the completeness gate no longer exempts APPROVED accounts. That "
            "exemption is what stops /complete-profile <-> dashboard looping "
            "for an account whose profile predates kebele/street_road")

    # "Approval resolved" must mean approved, not "not pending and not
    # rejected": the looser form also matched SUSPENDED and INACTIVE, which
    # are approval routes, and looped /suspended <-> dashboard.
    # Compared with whitespace collapsed, because the condition spans lines.
    flat = re.sub(r"\s+", " ", router)
    if "isApprovalRoute && authState.isApproved" not in flat:
        problems.append(
            "the approval-resolved branch is no longer `isApprovalRoute && "
            "authState.isApproved`. A looser condition (not pending, not "
            "rejected) also matches SUSPENDED/INACTIVE and deadlocks them "
            "against /suspended")

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
    ("every storage bucket lib/ uses is created by a migration the deploy "
     "workflow executes",
     check_client_buckets_are_created),
    ("every income figure counts every fee type, including the activation fee",
     check_income_readers_count_every_fee_type),
    ("the activation fee is written where an income reader can see it",
     check_activation_fee_is_recorded_as_income),
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
    ("the Other document type is offered, stored, and displayed where it is reviewed",
     check_other_document_type_is_wired),
    ("the CEO account directory routes through the one deletion cascade",
     check_ceo_account_directory_is_wired),
    ("every image picker that feeds a storage bucket is downscaled before upload, "
     "so the bucket accepts it",
     check_payment_screenshots_are_downscaled),
    ("the bucket and money policies the client needs are in a migration the "
     "pipeline executes",
     check_client_write_policies_are_executable),
    ("a refused recharge names what is missing instead of borrowing the "
     "not-found sentence",
     check_recharge_refusals_name_the_real_cause),
    ("the provider gallery is still reachable from the provider dashboard",
     check_provider_gallery_is_wired),
    ("every role's quick-action shortcut shares one pill and still resolves",
     check_quick_action_shortcuts_are_wired),
    ("the gallery's READ path is in a migration the pipeline executes",
     check_gallery_read_path_is_migrated),
    ("an OAuth account can complete its profile, and no account menu row is dead",
     check_profile_completion_and_taps_are_wired),
    ("the router's redirect clauses still match the cycle simulation",
     check_router_matches_the_cycle_simulation),
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
