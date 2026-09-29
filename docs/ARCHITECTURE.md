# Architecture

Aliob is a Flutter + Supabase marketplace and ride-hailing app. This document
describes the app **as it is today**, not as it is meant to be: the layering
that exists, every place the code departs from it, who each role can actually
do what, the two flows that are hardest to hold in your head, what is known
broken, and what must be live for the app to work.

Everything here was checked against the tree at the commit that last touched
this file. Where a claim is machine-checked, the check is named. Where
something could only be read and not run (there is no Dart SDK and no device
in the audit environment), it says so.

---

## 1. The shape, and where it leaks

```
  screens          lib/features/**          user intent + local UI state
        │  MOSTLY no Supabase — but see the exceptions in §1.3
        ▼
  providers        lib/core/providers/**    derived state (auth, mostly)
        │          lib/core/models/**      pure data
        ▼
  services         lib/core/services/**     all I/O: queries, RPC, functions,
        │                                    storage, realtime
        ▼
  Supabase         Postgres + RLS + SECURITY DEFINER functions + Edge Functions
```

There is no repository layer. One existed, nothing traversed it, and it was
deleted rather than left as a layer that only some code obeyed.

### 1.1 What each layer is for

**Screens** (`lib/features/**`) hold widget state and intent. They should not
know what a query looks like.

**Providers** (`lib/core/providers/`) — in practice there is exactly one,
`authProvider`. It owns the session, the profile and the role list, and the
router's `redirect` reads it. Everything else is passed down through
constructor arguments.

**Services** (`lib/core/services/`, 31 files) own the I/O. `OrderService`,
`RideService`, `CartService`, `WalletService`, `PointsService`,
`ProductLikeService`, `DocumentUploadService`, `ProviderDocGate`,
`LocationService`, `LiveMapService` and the rest.

**Supabase** is the enforcement layer. Anything the client can be trusted to
enforce is something the client is trusted not to do.

### 1.2 The resilience layer exists and is only partly used

`lib/core/resilience/` and the widgets beside it are real and tested:

| Piece | Adopted by |
|-------|-----------|
| `AppFailureMapper` | `safeCall`, `safe_realtime`, most newer services |
| `ErrorLogger` → `client_error_logs` | `bootstrap.dart` (root), asserted by `assert_resilience_is_wired()` |
| `AppErrorBoundary` | `bootstrap.dart` (root) and `user_dashboard.dart` |
| `ResilientFeed` (channel **and** poller together) | **nothing — see §5.1** |
| `AsyncView` (loading / error / empty, content-preserving) | **nothing — see §5.2** |

The outcome is mostly right even where the layering is wrong: a service that
throws is caught by the calling screen's `friendlyError`, so a raw exception
does not reach a user. Verified by the 2026-09-28 audit — zero direct
renderings of an exception in `lib/`.

### 1.3 Screens that call Supabase directly (the real list)

Roughly 90 files make a Supabase call; 29 reference no resilience helper at
all, and 13 of those perform writes. The write-bearing ones are
`cart_service`, `staff_gateway_service`, `payment_methods_service`,
`help_chat_screen`, `document_upload_service`, `review_service`,
`favorites_service`, `order_chat_service`, `location_service`, `ride_service`,
`error_logger`, `city_service`, `wallet_service`. Most user-facing screens
(`user_category_screen`, `user_orders_screen`, `user_notifications_screen`,
and most of the 24 admin screens) build their own queries inline.

**This is the largest structural debt in the app** and it is not a
correctness bug — it is a durability one: a future refactor has no single
place to find "every write".

---

## 2. Role / permission map

The role enum is small and is not the same as the permission system.

```dart
enum AppUserRole { user, vehicleProvider, serviceProvider, admin }
```

(`lib/core/providers/auth_provider.dart`). `_getDashboardPath` in
`app_router.dart` is the only place a role becomes a landing page: staff
gateway → `/staff/dashboard`, admin → `/admin`, vehicle → `/vehicle`, service
→ `/provider`, otherwise `/user`.

**There is no Booking Provider role.** See §5.4.

### 2.1 What each role can do

| | User | Service provider | Vehicle provider | Admin | CEO |
|---|---|---|---|---|---|
| Browse All/Booking/Vehicles/Shops tabs | ✅ | ✅ | ✅ | — | — |
| Like / dislike a product | ✅ | ✅ | ✅ | — | — |
| Cart → checkout → place an order | ✅ | ✅ | ✅ | — | — |
| Pay a provider by screenshot proof | ✅ | ✅ | ✅ | — | — |
| See a provider's phone number | **after APPROVED only** | same rule | same rule | ✅ | ✅ |
| Request a ride / track / rate | ✅ | ✅ | ✅ | — | — |
| Wallet, recharge, points, rank badge | ✅ | ✅ | ✅ | — | ✅ (read) |
| Upload a product / service | ❌ | ✅ | ❌ | — | — |
| Manage the provider gallery | ❌ | ✅ | ❌ | — | — |
| Confirm availability on an order | ❌ | ✅ | ❌ | — | — |
| Post and edit a vehicle | ❌ | ❌ | ✅ | — | — |
| Attach **images** to a vehicle | ❌ | ❌ | **❌ see §5.3** | — | — |
| Claim and complete a ride | ❌ | ❌ | ✅ | — | — |
| Rate the other side of a completed order | ✅ | ✅ | ✅ | — | — |
| Approve users / providers / payments | ❌ | ❌ | ❌ | ✅ | ✅ |
| Edit fees and the points rate | ❌ | ❌ | ❌ | read-only | ✅ |
| Create staff, set staff jobs | ❌ | ❌ | ❌ | ❌ | ✅ |
| View the CEO workspace | ❌ | ❌ | ❌ | ❌ | ✅ |

### 2.2 The permission system underneath

Two things that are often confused:

1. **`user_roles`** — coarse: is this account an ADMIN, a STAFF member, a
   PROVIDER, a USER. Drives `_getDashboardPath` and the router.
2. **`staff` + `staff_jobs` + `staff_warnings`** — the fine-grained system for
   people who work *for* the platform. Nine job keys (`registrations`,
   `payment_verification`, `sales_transactions`, …) describe what a staff
   member may do; `staff_has_permission()` is checked inside the RPCs, and the
   UI only ever reflects it.

**A route in `app_router.dart` is navigation, never protection.** Every
sensitive read and write re-checks server-side — `is_admin()`, `is_ceo()`,
`staff_has_permission()`, `admin_can()`. `/ceo` renders an explanation to a
non-CEO rather than the workspace, and that is a courtesy, not a control.

### 2.3 Exposure rules worth knowing

- `public_provider_profiles` is a `SECURITY_BARRIER` view granted to `anon`.
  It is the only public projection of a provider, and it deliberately carries
  city and category but **not** street address or phone.
- `provider_trust_stats` is a plain view of aggregates (rating, review count,
  completion rate, member-since) with no RLS of its own — views run with the
  owner's privileges. Deliberate, documented in migration 27.
- `staff_jobs` is session-only as of migration 83 (§5.5).
- Precise driver positions are never public: `nearby_provider_markers()`
  rounds to ~110 m and requires a session; a driver's exact location is only
  readable by a rider who has claimed a ride with them.

---

## 3. The two hard flows

### 3.1 Order → payment → contact reveal

```
user                    client                    database
 │  add to cart
 │──────────────────────────────────────────────►  cart_items (own rows only)
 │  checkout ─────────────────────────────────►  order-create  (Edge Function,
 │                                                  price is computed server-side;
 │                                                  the client cannot set it)
 │                                          ◄──  order PENDING_PROVIDER
 │                                                  requires_availability_confirmation
 │                                                  snapshotted onto the order
 │
 │  sees "waiting for the provider" — no phone, no payment details
 │
 │                        provider
 │                        accept ────────────────►  order-transition (Edge Fn)
 │                                                    -> ACCEPTED
 │                        ◄── payment details now visible (same rule both ways)
 │
 │  attach payment screenshot ────────────────────►  payment_proofs
 │                        sees the proof ──────────  order-transition -> PAYMENT_VERIFICATION
 │                        admin verifies ──────────►  order APPROVED
 │  ◄── release_order_contact(order_id) ──────────  phone number, once, audited
 │  ◄── review allowed only after COMPLETED
```

Three flags carry the gating, all `NOT NULL DEFAULT false`, so nothing that
works today changes until a provider opts in: `products.requires_availability_confirmation`
and `orders.requires_availability_confirmation` (migration 74). The order-level
copy is what the screens read, deliberately — re-joining through `order_items`
would let a provider close the payment screen on an order a buyer has already
paid for.

`release_order_contact()` is server-side and idempotent: before APPROVED it
refuses, and it writes the release to `admin_history`.

### 3.2 Ride request → match → complete

```
rider                                   driver
 │  /map  (live map, "Where to?" search)
 │  /user/ride-request
 │  GPS entry OR manual address OR map pin
 │──────────────────────────────────────────────►  create_ride_request()
 │                                          ◄──  ride_requests REQUESTED
 │
 │                                    driver online ──► set_driver_online()
 │                                    /vehicle/ride-requests  (live_map_open_rides)
 │                                    claims ──────────────►  ride-claim (Edge Fn)
 │                                                        -> CLAIMED, ride_id set
 │  /user/ride-active  ◄── realtime on ride_requests ──┐
 │                                                        │
 │                                    /vehicle/trip ─────┘
 │                                    transition_ride_status: EN_ROUTE ->
 │                                    ARRIVED -> TRIP_STARTED -> COMPLETED
 │                                    driver pushes GPS throughout
 │  ◄── fare charged on COMPLETED ───────────────────────
 │  both sides may rate (ride_ratings)
```

`ride_requests` and `driver_status` are in the `supabase_realtime`
publication with `REPLICA IDENTITY FULL` (migration 61) — without FULL, a
stream filtered on a non-key column (`status`) is rejected outright with a
CHANNEL_ERROR. That is the whole reason migration 61 exists.

---

## 4. Cross-cutting rules the code does follow

These are all load-bearing, and all of them have a test or an assertion.

**One classifier.** `AppFailureMapper` is the only place an exception becomes
a kind. Two classifiers is how one fault starts producing two different
sentences in two screens.

**Data beats "[data] wins".** A failed refresh never replaces good content
with an error.

**No unbounded queries.** Every list query has a `limit`.

**Money is never retried.** `RetryPolicy.money()` is one attempt. Duplicate
charges are worse than failed ones, and the idempotency key is the real
protection. 20 migrations reference `idempotency_key`.

**A denormalised counter is not a client write.** `products.like_count` and
`dislike_count` are maintained by `trg_product_likes_count`, which runs as the
table owner and therefore is exempt from both RLS and
`enforce_provider_write_gate` (which exempts `pg_trigger_depth() > 1`). Any
future counter on a guarded table needs this.

**A reaction is a set, not a toggle.** `set_product_reaction(product, LIKE |
DISLIKE | NONE)` states intent; it does not flip what is there.

**Identity is verified after signup, and the liveness signal is a signal, not
a gate.** No ID is collected at registration — for users or providers. The
document step lives in-app, before a booking, a listing or a ride claim. When
a document row is written, `DocumentUploadService` takes one GPS fix and
records it on that row. It never blocks: GPS off or permission denied records
`UNAVAILABLE` and the upload proceeds.

**The signup OTP is a toggle, not a rule.** `signup_otp_required` (migration
82) is currently **false**, because `send-otp` has no working email provider
and the gate was taking registration down entirely. Admin approval is the gate
on a new account, and identity is checked later at the document step. Turning
the OTP back on is one `UPDATE`.

While it is off, `verify_email_otp()` completes the code screen **without
stamping `verified_at`** (migration 84). That single property is the whole
safety of the arrangement: `handle_new_user()` reads `otp_verified_recently()`,
which reads `verified_at`, so an address that skipped the code carries no
verification forward and must produce a real code the moment the OTP is
switched back on. `assert_otp_bypass_is_scoped()` fails if that ever changes —
because a bypass that records a verification is invisible in review and its
consequence is a security property quietly disappearing, not a crash.

---

## 5. Known gaps

Ranked by how much they hurt a real user. Effort: small = an afternoon,
medium = a day or two, large = more.

### 5.1 `ResilientFeed` is adopted by no screen — **medium**
The class is `ResilientFeed` in `lib/core/services/safe_realtime.dart`; the
name `SafeRealtimeFeed` this section used to use appears nowhere in `lib/`.
It runs a channel and a poller together and emits from whichever works, which
is the correct answer for a dropped socket. Nothing uses it. What five screens
adopt instead is `ResilientSubscription`, which has no poller —
`live_map_service`, `live_map_screen`, `user_active_ride_screen`,
`driver_ride_requests_screen` and `driver_trip_screen`. And
`staff_dashboard_screen._listen()` subscribes through
`_service.subscribeToTaskFeed()` then awaits `channel.subscribe()` with
**no status callback, no reconnect and no fallback** — if that channel errors,
the one screen whose whole job is telling staff what to work on goes quiet
until someone pulls to refresh.
*Fix:* move `staff_dashboard` onto `ResilientFeed`; needs a device to verify.

### 5.2 `AsyncView` is still barely adopted — **medium**
The widget exists and is correct, and three screens now use it
(`user_home_screen`, `user_orders_screen`, `user_notifications_screen`). The
rest hand-roll `LoadErrorView` + `RetryWidget` — `LoadErrorView` is referenced
by 33 files, including `async_view.dart` itself. The behaviour is mostly
right, so this is consistency, not breakage.
*Fix:* per-screen swap, mechanical.

### 5.3 Vehicles cannot have images — **medium**
`vehicle_images` has existed since migration 0001 with RLS and storage
policies, and **no Dart file references it**. `vehicle_form_screen.dart` has
no image picker at all, so a vehicle provider can post a vehicle but cannot
photograph it. The database work is done; only the client is missing.
*Fix:* mirror `add_gallery_image` / `delete_gallery_image` for vehicles in
`vehicle_form_screen`.

### 5.4 There is no Booking Provider role — **large**
`AppUserRole` has four values and none of them is a booking provider. "Booking"
exists only as a product `service_group` / category tab that determines which
order lifecycle applies. Building the role means a fifth enum value, a
dashboard, a booking-specific lifecycle and its own approval path.
*Deliberately not built — see the brief.*

### 5.5 `staff_jobs` was readable with the anon key — **fixed, migration 83**
RLS was disabled on a table whose whole purpose is to be withheld from anon
(`list_staff_jobs()` is explicitly `REVOKE`d from anon). Now RLS on, a
read-only policy for `authenticated`, `REVOKE` from anon, with
`assert_staff_jobs_are_session_only()` proving both directions.

### 5.6 Two Edge Functions were never deployed — **fixed**
`account-change-password` and `account-deletion-gateway` are called from
Flutter and were absent from `deploy-supabase.yml`, so **"Change password" and
"approve account deletion" were both calling functions that did not exist.**
Same class of bug as the `user-admin` omission recorded in that workflow.
Both deploy steps added.

### 5.7 Sponsored ads do not exist — **large**
There is no ad product anywhere in `lib/`: no table, no RPC, no screen, no
purchase path. `grep -ri 'sponsor\|advert\|promo' lib/` returns three
unrelated files. A provider cannot buy placement, so the corresponding step in
a provider walkthrough is a no-op.

### 5.8 Push notifications are not implemented — **medium**
`firebase_messaging` is not a dependency. Notifications are in-app only
(`notifications` table, polled/realtime). Background order and ride alerts do
not exist. Migration groundwork (0007) is there.

### 5.9 Layering is not enforced — **large**
See §1.3. 13 write-bearing services bypass the resilience layer.

### 5.10 Category lists are capped at 100 — **small**
`visible_products_for_city` ranks by popularity and caps server-side. A
category with more than 100 products truncates silently.

---

## 6. What is asserted, and where

Correctness a reviewer cannot check by reading is asserted somewhere
executable. SQL is asserted against the **live** database by Connectivity CI
(`tools/integration_test/connectivity_test.dart`); Dart and the Edge Functions
are asserted against source by `test/` and the checks under `tools/harness/`,
run as `sh build/run_all.sh`.

That last path is a shim. `build/` is in `.gitignore` because it is the
Flutter output directory, so a harness placed there is never committed and
does not survive a clone — which is exactly how the previous set was lost in
the repository import. The real files live in `tools/harness/`, which git
tracks, and the shim exists only so the documented command keeps working.
The harnesses need no Dart SDK, no Deno and no credentials, so they run
anywhere the repository is checked out.

| Property | Where it is pinned |
|----------|-------------------|
| Every fee follows `system_settings`, in whichever direction its switch points | `assert_fees_are_data_driven()` (migration 62, switch-aware since 73) |
| Every fee switch actually switches | `assert_fee_switches_are_wired()` (migration 73) |
| Payment gated on availability; contact on verified payment | `assert_availability_gate_is_wired()` (migration 74/75) |
| A like persists; a dislike replaces it; the RLS bites | `assert_likes_persist_and_are_exclusive()` (migration 76, a **write** test) |
| The provider write gate is scoped, not opened | `assert_provider_write_gate_allows_counter_updates()` (migration 76) |
| Live map is actually live (publication + FULL replica identity + marker feed) | `assert_live_map_is_wired()` (migration 61) |
| Document submission records a location, and the trigger does not overwrite it | `assert_document_liveness_is_recorded()` (migrations 80/81) |
| The signup OTP is a working toggle in either position | `assert_signup_otp_toggle_is_consistent()` (migration 82) |
| The staff-job catalogue is session-only | `assert_staff_jobs_are_session_only()` (migration 83) |
| The signup gate keys off `verified_at`, not attempt arithmetic | `assert_otp_gate_uses_verified_at()` (migration 02) |
| The signup trigger's insert-time trust rules hold | `assert_handle_new_user_contract()` (migration 82, path B is toggle-aware) |
| Error sink, RLS and hot-path indexes exist | `assert_resilience_is_wired()` (migration 64) |
| Wallet balances equal the ledger | `assert_income_ledger_consistent()` |
| Approved recharges actually credited | `assert_recent_approved_recharges_credited()` |
| Ride and order fees charged on the right transition | `assert_recent_started_orders_have_fees()`, `assert_recent_completed_rides_have_fees()` |
| Subscription fee is actually scheduled | `assert_subscription_scheduler_scheduled()` |
| The optimistic like count is right, including like↔dislike | `test/product_reaction_count_test.dart` |
| Category → tab mapping against real seed rows | `test/category_tabs_test.dart` |
| Retry / backoff / jitter maths | `test/retry_backoff_test.dart` |
| Exception classification and non-leakage | `test/failure_mapper_test.dart` |
| A failed realtime subscribe cannot crash | `test/realtime_resilient_subscription_test.dart` |

Two lessons worth keeping, both paid for:

- **An assertion that only reports `null` is not an assertion.** Migration 66
  lost three deploy cycles to `Expected: not null, Actual: <null>` from an RPC
  whose cache was stale rather than whose logic was wrong. The resilience and
  liveness tests now use `rpcTextDiagnosed`, which prints the actual error.
- **A test must not flatter the code it tests.** Migration 44's probe set
  fixtures that were more generous than production (a confirmed email the
  trigger cannot see at insert time) and reported success for two live paths
  that were in fact broken.

---

## 7. Deployment checklist

Verify a deploy against this list rather than assuming. "The workflow went
green" does not mean the app works.

### 7.1 Migrations

Applied through `Deploy Supabase` (`supabase db push --include-all`) or, when
GitHub Actions cannot run, the Supabase SQL Editor.

| Migration | Brings | If missing |
|-----------|--------|------------|
| `0001`–`0043` | core schema, RLS, storage, escrows | nothing works |
| `0044` / `20260925150000` | `handle_new_user()` with insert-time trust rules | signup rejected or trust rules inert |
| `0074` | availability-confirmation gate | payment visible before confirmation |
| `0076` | likes persist, dislikes replace | a like fills and empties silently |
| `0080` | GPS liveness columns on `user_documents` | **document upload fails** — the client inserts them |
| `0081` | fixed liveness assertion | Connectivity CI red (test only) |
| `0082` | `signup_otp_required` toggle | registration fails with "Database error saving new user" |
| `0083` | `staff_jobs` RLS | the job catalogue is readable with the anon key |
| `0084` | OTP bypass that records no verification | a build in circulation cannot pass the code screen |

**0080 before any build that ships the liveness client.** The client inserts
the new columns; if they are absent, every document upload fails.

### 7.2 Edge Functions

Deployed by the `Deploy function …` steps in `.github/workflows/deploy-supabase.yml`.
Every one of these is called from Flutter:

```
repo-chat  index-chunks  provider-approval  admin-wallet-recharge
wallet-deduct-fee  subscription-process  order-create  order-transition
ride-claim  ride-transition  document-verify  user-admin  send-otp
staff-create-gateway  staff-delete-gateway  staff-change-password
staff-login (--no-verify-jwt)  login-gate
account-change-password  account-deletion-gateway
```

Two notes that are easy to get wrong:

- A function present in `supabase/functions/` is **not** deployed unless the
  workflow has a step for it. That is how "Change password" and "approve
  account deletion" shipped broken (§5.6).
- `send-otp` additionally needs an email provider configured in
  Supabase → Edge Functions → `send-otp → Secrets`. **Resend**:
  `RESEND_API_KEY` + `OTP_FROM_EMAIL`. **Brevo** (free tier, no card):
  `BREVO_API_KEY` + `BREVO_FROM_EMAIL`. Resend is tried first; with neither
  pair set the function returns `email_provider_not_configured` and **no
  registration email is ever sent**.

### 7.3 Secrets

| Key | Where | Consequence if missing |
|-----|-------|------------------------|
| `RESEND_API_KEY` | Supabase edge-function secret | no OTP email |
| `OTP_FROM_EMAIL` | Supabase edge-function secret | no OTP email |
| `INDEXER_KEY`, `INDEXER_URL` | GitHub Actions + Supabase | help chat cannot index or answer |
| `LLM_PROVIDER` | Supabase (`none` is the only supported mode) | — |

`supabase secrets set` in the deploy workflow only ever writes `INDEXER_KEY`
and `LLM_PROVIDER`; it upserts and does not delete, so anything set by hand in
the dashboard survives a deploy.

### 7.4 Supabase Auth configuration

- **Email confirmation must stay disabled.** Registration relies on
  `signUp()` returning a session immediately; the approval gate is
  `profiles.status = PENDING_APPROVAL`, not a confirmation email.
- Google OAuth must stay enabled if the app's Google button is advertised.

### 7.5 After a deploy

1. Connectivity CI green (53 tests). If it is red, the failure message names
   the assertion — read the `Diagnostic:` line before changing anything.
2. Flutter CI green.
3. `select public.assert_signup_otp_toggle_is_consistent();` returns a string,
   not an exception.
4. `select public.assert_document_liveness_is_recorded();` returns a string.
5. `select public.assert_live_map_is_wired();` returns a string.
