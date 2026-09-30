#!/usr/bin/env python3
"""Search the router's redirect rules for a cycle, by simulation.

## Why this exists

A device crash found in device testing, in the app's own words:

    GoException: redirect loop detected
    / => /complete-profile => /complete-profile => /user => /user => /complete-profile

Two branches in `app_router.dart`'s `redirect()` fought each other:

  * the profile-completeness gate sent any non-admin with an incomplete
    profile to `/complete-profile`;
  * `/complete-profile` was registered as an approval route, so the
    "approval resolved" branch — which forwards anything that is neither
    pending nor rejected to its dashboard — sent the user straight back out
    to `/user`.

An **approved** account with an incomplete profile (every account predating
`kebele`/`street_road`, which is most of the test data) satisfied both at
once, forever. go_router gave up and the app rendered Page Not Found.

Neither branch is wrong on its own, and neither test failed: the gate had a
route exemption, the approval branch had a status condition, and the
incompleteness check lived in neither. The defect was only ever visible as a
*cycle*, which is a property of the pair.

## What it does

Enumerates every combination of (starting location, approval status, profile
verifiable, admin, staff) and follows the redirect to a fixed point. Any
location that never settles is reported, with the path that repeats.

This mirrors the two interacting rules rather than the whole redirect, and it
is deliberately a simulation rather than a source scan: a source scan can only
check the branches in isolation, which is precisely what let the bug through.

Keep in step with the `redirect()` in `lib/routing/app_router.dart`. If the
router gains a rule that can move a user between two locations, add it here.
"""

from __future__ import annotations

import sys

# Locations the redirect can land on or be evaluated at.
LOCATIONS = [
    "/",
    "/user",
    "/complete-profile",
    "/pending-approval",
    "/rejected",
    "/suspended",
    "/login",
    "/role-select",
    "/staff/dashboard",
    "/admin",
    "/provider",
    "/vehicle",
]

#: `/complete-profile` is registered as an approval route so the pending /
#: rejected / suspended gates skip it. That registration is what made the
#: "approval resolved" branch able to fire on it.
APPROVAL_ROUTES = {
    "/pending-approval",
    "/rejected",
    "/suspended",
    "/complete-profile",
}

AUTH_ROUTES = {
    "/login",
    "/role-select",
    "/admin-login",
    "/staff/login",
    "/terms",
    "/update-password",
    "/otp-verify",
}

STATUSES = ["PENDING_APPROVAL", "APPROVED", "REJECTED", "SUSPENDED", "INACTIVE"]


def dashboard_path(*, is_admin: bool, is_staff: bool, role: str) -> str:
    if is_staff:
        return "/staff/dashboard"
    if is_admin:
        return "/admin"
    if role == "vehicle":
        return "/vehicle"
    if role == "provider":
        return "/provider"
    return "/user"


def redirect(loc: str, *, status: str, verifiable: bool, is_admin: bool,
             is_staff: bool, role: str = "user") -> str | None:
    """The subset of app_router.dart's redirect() that can move a user.

    Returns the next location, or None when the router stops and renders.
    """
    is_approval = loc in APPROVAL_ROUTES
    is_pending = status == "PENDING_APPROVAL"
    is_rejected = status == "REJECTED"
    is_suspended = status in ("SUSPENDED", "INACTIVE")
    is_approved = status == "APPROVED"

    # 1. Profile completeness. Approved accounts are exempt: they have been
    #    through verification once, and re-gating one locks a working
    #    customer out over a field added after they signed up.
    needs = (not is_admin and not is_staff and not is_approved and not verifiable)
    if needs and loc != "/complete-profile":
        return "/complete-profile"

    # 2. Staff gateway.
    if is_staff and loc in ("/staff/login", "/", *AUTH_ROUTES):
        return "/staff/dashboard"

    # 3. Pending / rejected / suspended, all skipped on approval routes.
    if not is_admin:
        if is_pending and not is_approval:
            return "/pending-approval"
        if is_rejected and not is_approval:
            return "/rejected"
        if is_suspended and not is_approval:
            return "/suspended"

    # 4. Approval resolved -> forward to the dashboard.
    if is_approval and is_approved:
        return dashboard_path(is_admin=is_admin, is_staff=is_staff, role=role)

    # 5. Off an auth route, or off the splash screen.
    if loc in AUTH_ROUTES or loc.startswith("/signup/") or loc == "/":
        return dashboard_path(is_admin=is_admin, is_staff=is_staff, role=role)

    return None


def settle(start: str, **state):
    """Follow redirects until the router stops. Returns the path, or None."""
    seen: list[str] = []
    loc = start
    for _ in range(40):  # go_router itself gives up after a bounded number
        if loc in seen:
            return seen + [loc]
        seen.append(loc)
        nxt = redirect(loc, **state)
        if nxt is None:
            return seen
        loc = nxt
    return None  # never settled


def main() -> int:
    problems: list[str] = []
    checked = 0

    for loc in LOCATIONS:
        for status in STATUSES:
            for verifiable in (True, False):
                for is_admin in (False, True):
                    for is_staff in (False, True):
                        for role in ("user", "provider", "vehicle"):
                            state = dict(status=status, verifiable=verifiable,
                                         is_admin=is_admin, is_staff=is_staff,
                                         role=role)
                            checked += 1
                            path = settle(loc, **state)
                            if path is None:
                                problems.append(
                                    f"{loc} [status={status} "
                                    f"verifiable={verifiable} admin={is_admin} "
                                    f"staff={is_staff} role={role}] never settles"
                                )
                            elif path[0] == path[-1] and len(path) > 1:
                                problems.append(
                                    f"{loc} [status={status} "
                                    f"verifiable={verifiable} admin={is_admin} "
                                    f"staff={is_staff} role={role}] -> "
                                    f"{' -> '.join(path)}"
                                )

    for p in sorted(set(problems))[:12]:
        print(f"[FAIL] redirect cycle: {p}")
    if problems:
        print(f"\n{len(set(problems))} redirect cycle(s) across "
              f"{checked} state/location combinations.")
        return 1
    print(f"ok: all {checked} redirect state/location combinations settle "
          f"on a single screen")
    return 0


if __name__ == "__main__":
    sys.exit(main())
