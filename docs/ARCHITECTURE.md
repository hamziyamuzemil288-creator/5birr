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
| Attach **images** to a vehicle | ❌ | ❌ | ✅ | — | — |
| Claim and complete a ride | ❌ | ❌ | ✅ | — | — |
| Rate the other side of a completed order | ✅ | ✅ | ✅ | — | — |
| Approve users / providers / payments | ❌ | ❌ | ❌ | ✅ | ✅ |
| Edit fees and the points rate | ❌ | ❌ | ❌ | read-only | ✅ |
| Create staff, set staff jobs | ❌ | ❌ | ❌ | ❌ | ✅ |
| View the CEO workspace | ❌ | ❌ | ❌ | ❌ | ✅ |
| Browse **all** users & providers, delete one outright | ❌ | ❌ | ❌ | ❌ | ✅ |

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
 │  sees "waiting for the provider" — no phone, no payment details,
 │  no upload option
 │
 │                        provider (or an admin)
 │                        accept ────────────────►  order-transition (Edge Fn)
 │                                                    -> ACCEPTED
 │                        ◄── payment details AND the upload button appear
 │                            together, in one card
 │
 │  pay into the account shown, then attach the screenshot
 │  ───────────────────────────► order-transition -> PAYMENT_PENDING   (85)
 │  ───────────────────────────► payment_proofs
 │                              order-transition -> PAYMENT_VERIFICATION
 │                        sees the proof ──────────  (admin queue)
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

**The chain has to end somewhere (migration 85).** Migration 74 built the gate
but not its last link. The buyer could only submit from `PAYMENT_PENDING`, and
only the provider could move an order there from `ACCEPTED` — so a gated order
sat at `ACCEPTED` with the accounts on screen and no button anywhere, until the
provider happened to open their own list and press "Request Payment". Checkout
was already promising the buyer an upload option that did not exist yet.
Migration 85 adds one clause: on an order whose snapshot is true, **the buyer
may move `ACCEPTED -> PAYMENT_PENDING` themselves**. It is scoped to the
order's own owner and to gated orders, so an un-gated order is byte-for-byte
unchanged, and it opens only the step where a proof can be *attached* — contact
and fulfilment stay behind a VERIFIED proof. Asserted by
`assert_gated_buyer_payment_request_is_wired()`.

The payment details and the upload button are rendered in **one card**
(`_paymentStepCard`). They used to be at opposite ends of a long scroll, so
"confirmation happened" and "there is something to act on" were two separate
facts. The card is gated on the buyer's eligibility, not on the read of
`payment_methods` succeeding, so a failed read cannot remove the only way to
pay.

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

### 4.x A money notification never blocks the money

Every notification attached to a payment, a credit or an approval goes through
`notify_user_once()` (migration 86), never a bare `INSERT INTO notifications`.
That is two guarantees in one call, and both have a failure mode that is
invisible until money is involved:

* **Once.** The key is checked under `pg_advisory_xact_lock`, so a retried
  call — a double tap, a redelivery, a scheduler running twice — cannot write a
  second row. Reading the key without the lock is a race: two calls both see
  "nothing there yet" and both write.

The check has to read **both** delivery tables, and the first live run proved
it. `notify_user()` routes on `is_server_write()`: a server write inserts into
`notifications` directly, a **client write inserts into `notification_outbox`**
and does not reach `notifications` until pg_cron drains it. A dedupe that read
only `notifications` therefore missed every client-path notification — and the
connectivity suite runs as `anon`, so the client path is the normal path, not a
corner case. A retried call found nothing, queued a second row, and both
messages were delivered. Migration 92 checks both.
* **Never fatal.** The body is wrapped so any error becomes a `RAISE WARNING`
  and a NULL return. Without this, an undeliverable notice inside
  `approve_wallet_recharge` or `convert_points_to_wallet` rolls the real
  payment back and reports it as a failure — the money would be correct and the
  user told it failed.

The same discipline the wallet ledger already used for `idempotency_key`. The
key is stored in the existing `data` jsonb under `idem_key`, so no column and
no table were added.

**Where the notice is written, and why not always a trigger.** Order and ride
notices hang off the existing status triggers: an `AFTER UPDATE` trigger runs in
the same transaction as the write, so it cannot drift out of sync with it, and
restating `transition_ride_status` would mean reproducing all nine status
branches — the blast radius that once froze every ride stuck in
`DRIVER_EN_ROUTE`. Points conversion is the exception and lives in the function
body, because it moves money without updating any row a trigger covers, and the
message has to quote figures that exist only as local variables.

**Messages state what actually happened.** Ride completion does *not* add money
to the driver's wallet: it calls `deduct_transaction_fee()`, which debits the
platform commission, and the fare is settled outside the app. Order payment is
likewise made outside the app and verified from a screenshot. So the messages
quote the amount and say the commission was deducted; none of them claims a
wallet credit. `assert_order_and_ride_receipts_are_sent()` fails if that
wording comes back.

**Batching.** One ride completion produces two driver notifications by design —
one about the trip, one about the fee, the latter from `deduct_transaction_fee`
with the exact figure. They are deliberately non-overlapping rather than merged,
because the fee amount is computed inside the fee function and is not available
to the trigger. Approvals are single: the status notice and the welcome are
different messages, and both are keyed, so a retried approval adds neither.

**Every fee the platform charges is income, and every reader has to see all
three.** Income lives in `wallet_transactions.platform_fee`, written by three
paths: `deduct_transaction_fee()` (orders on `STARTED`, rides on `COMPLETED`,
type `TRANSACTION_FEE`), `deduct_subscription_fee()` and the monthly scheduler
(`SUBSCRIPTION_FEE`), and `approve_wallet_recharge()`, which withholds the
one-time `provider_registration_fee` from a provider's **first** approved
recharge and records it as `platform_fee` on a `RECHARGE` row (gross = the
amount paid, net = amount − fee; every later recharge carries
`platform_fee = 0`, so summing the column cannot double-count a deposit).

Only the first two were counted for a long time, in both the admin income
summary and the dashboard total. The result was not an error and not an empty
state but a confident **ETB 0.00** on a deployment whose providers were still
activating — and the activation fee is the only income a provider pays before
completing an order. Both readers now query all three types, and
`check_income_readers_count_every_fee_type()` fails the build if a file that
folds `platform_fee` stops naming one of them.

The related trap: the ledger assertions (`assert_recent_started_orders_have_-
fees()`, `assert_recent_completed_rides_have_fees()`,
`assert_income_ledger_consistent()`) are **existential-negative** — "no row that
exists lacks its fee row". They pass with zero rows, so a green money suite is
not evidence that any income exists. Read the counts before trusting the
number on the screen.

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

### 5.3 Vehicles cannot have images — **fixed, migration 97**
`vehicle_images` had existed since migration 0001 with RLS and storage
policies, and **no Dart file referenced it**: `vehicle_form_screen.dart` had
no image picker at all, so a vehicle provider could post a vehicle but could
not photograph it. The database work was written but unreachable, and the
`vehicle-images` bucket was in the state `provider-gallery` had been in —
declared only by `0012`, which is below the deploy baseline and therefore
marked applied without ever being executed, so it did not exist live. The
client and the bucket were the two halves of one gap.

`0097` closes both. It creates `vehicle-images` with `ON CONFLICT DO UPDATE`
(public, 5 MB, jpeg/png/webp), restates the four storage policies (`0012`
never executed), restates the table and its owner/read policies, and revokes
`INSERT`/`UPDATE`/`DELETE` from `anon`/`authenticated` so the app writes only
through two new `SECURITY DEFINER` functions — `add_vehicle_image()` (which
refuses a path outside the caller's own `{uid}/{vehicle_id}/` folder) and
`delete_vehicle_image()` — mirroring the provider gallery's
`add_gallery_image` / `delete_gallery_image` from `0055`. The Dart side is the
consumer: `vehicle_form_screen.dart` now picks, uploads (path
`{uid}/{vehicle_id}/{stamp}-{name}`), lists and removes vehicle photos, and
the two silent early returns in its `_save()` now report their failure.

The rule that the bucket, the policy and the upload path are introduced
together is what `0096` stated when it deliberately left `vehicle-images` out.
`check_client_buckets_are_created()` fails the build if a bucket appears in
`lib/` without a migration the pipeline runs, and `assert_app_buckets_exist()`
fails the live suite if it is not there or has the wrong visibility.
`assert_bucket_writes_are_owner_scoped()` now covers all six buckets.

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

Confirmed again while building the money notifications (migrations 86–89): the
"ad purchase charged" and "ad refund" notifications that were requested have no
function to attach to. There is no ad table in any migration and no ad purchase
path in `supabase/functions/`. Building them would mean inventing the feature,
not wiring a notification to it, so they are listed here as not-applicable
rather than silently skipped. The nearest real equivalent — money leaving a
wallet and coming back — is covered: a points conversion notifies with both
figures (89), and `ORDER_REFUNDED` already notifies the buyer (58).

### 5.8 Push notifications are not implemented — **medium**
`firebase_messaging` is not a dependency. Notifications are in-app only
(`notifications` table, polled/realtime). Background order and ride alerts do
not reach a locked phone, so a user who has not opened the app since a payment
cleared learns about it only on next launch. Worth knowing when reading the
money notifications in §4.x: they are written correctly and delivered, but
delivery is pull-based.
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

**Restatements are diffed, not eyeballed.** Two tools back the restatements in
§4.x, because this repo has twice lost a condition from a function that was
re-emitted from memory (the `provider_profiles` trigger, the `staff_task_feed`
RPC):

* `python3 tools/harness/restatement_diff.py <migration> <fn>…` compares a
  restated body against the previous definition statement by statement. It
  separates *lost* from *rewritten*: a branch only counts as rewritten if the
  new body still notifies on that same status, and every rewrite must be
  declared in `REVIEWED_REWRITES`. An undeclared rewrite fails.
* `python3 tools/harness/fault_inject_notifications.py` reintroduces 25 real
  bugs — a dropped dedupe check, a dedupe that reads only one delivery table,
  a missing lock, a removed error handler, an unrevoked privilege, a lost
  authorization clause, a false "money added" claim, an assertion the CI
  client cannot reach, a mistyped source needle, a plpgsql loop that cannot
  run — and requires the harness to go red for each. A check that passes on
  broken input is worse than no check, because it is reported as a safety net
  while providing none.

  It found **thirteen** vacuous or wrong checks across five rounds. The
  recurring cause was matching on text that was not the thing being checked: a
  substring of the whole migration that also appears in that migration's own
  assertion; a comment inside a function body keeping a deleted `EXISTS`
  alive; a needle sensitive to the author's line wrapping; a needle with a
  typo; and a privilege model that ignored statement order.

**The pattern across five live rounds is worth stating plainly:** of the ten
failures, **one** was a defect in the notifications and **nine** were defects
in the assertions written to check them. Two of those would have "passed" only
by deleting a working feature. `assert_source_needles_match()` exists because
of that: an assertion whose needle does not match its target cannot be caught
by anything else, since it is the thing doing the checking.

**A plpgsql body is not validated by `CREATE FUNCTION`.** A function with a
body that cannot run deploys cleanly and then raises on every call — which for
an assertion means it silently stops asserting while still reporting as a
safety net. Migration 93 shipped exactly that (`FOREACH` over a 2-D array is
refused at run time, 42804) and only Connectivity CI calling it found out:
`db push` succeeded, and the privilege check passed because the function
existed and was executable. Migration 94 replaced the loop and it then
iterated **zero** times, which the `v_checked` counter caught as a red build
rather than a green one.

That third outcome is the general rule: **a check that examines nothing and
returns success is indistinguishable, in CI, from a check that examined
everything and found nothing wrong.** Only an explicit "did I actually look at
anything" counter separates them, and every assertion in this series has one
now. The 2-D array was removed entirely rather than re-looped — it cost two
deploy cycles — and the harness rejects array-typed `FOREACH` variables
statically, scoped to the current definition of each function.

All SQL is parsed with `pglast` (libpg_query, the real PostgreSQL parser)
before commit rather than read by eye. Two pre-existing files fail to parse and
are known: `0021_live_schema_snapshot.sql` (a `CREATE POLICY` name containing
spaces, unquoted) and `0022c_functions.sql` (`SECURITY_DEFINER` written with
an underscore). Both are historical and already applied; they are recorded here
rather than fixed, because editing a migration that has already run changes
nothing and rewriting a 2000-line snapshot is its own risk.

| Property | Where it is pinned |
|----------|-------------------|
| Every fee follows `system_settings`, in whichever direction its switch points | `assert_fees_are_data_driven()` (migration 62, switch-aware since 73) |
| Every fee switch actually switches | `assert_fee_switches_are_wired()` (migration 73) |
| Payment gated on availability; contact on verified payment | `assert_availability_gate_is_wired()` (migration 74/75) |
| A confirmed availability can actually be paid, by the buyer who placed it | `assert_gated_buyer_payment_request_is_wired()` (migration 85) |
| A like persists; a dislike replaces it; the RLS bites | `assert_likes_persist_and_are_exclusive()` (migration 76, a **write** test) |
| The provider write gate is scoped, not opened | `assert_provider_write_gate_allows_counter_updates()` (migration 76) |
| Live map is actually live (publication + FULL replica identity + marker feed) | `assert_live_map_is_wired()` (migration 61) |
| Document submission records a location, and the trigger does not overwrite it | `assert_document_liveness_is_recorded()` (migrations 80/81) |
| The signup OTP is a working toggle in either position | `assert_signup_otp_toggle_is_consistent()` (migration 82) |
| The staff-job catalogue is session-only | `assert_staff_jobs_are_session_only()` (migration 83) |
| A money notification is delivered once, and a failed one never rolls back the payment | `assert_notify_user_once_is_idempotent()` (migration 86, a **write** test) |
| Every approval path welcomes, and no restatement lost its guards | `assert_approval_welcome_covers_all_paths()` (migration 87) |
| Both parties are told an order payment and a ride completion, with the amount | `assert_order_and_ride_receipts_are_sent()` (migration 88) |
| Points→birr says so, and the money invariants survived the restatement | `assert_points_conversion_notifies()` (migration 89) |
| The notifications inbox is owner-scoped and still guarded | `assert_notification_inbox_is_owner_only()` (migration 90) |
| Every assertion the suite calls is reachable by the role the suite runs as | `assert_every_assertion_is_reachable()` (migration 91) |
| Source-matching assertions compare against text that exists | `assert_source_needles_match()` (migration 93) |
| Every storage bucket the client uses exists, and is as visible as the app expects | `assert_app_buckets_exist()` (migrations 96/97, six buckets) |
| The activation fee is withheld as income, and a second recharge withholds nothing | `assert_activation_fee_writes_income()` (migration 98, a **write** test) |
| The income report counts every fee type, and says what it measured | `assert_income_covers_every_fee_type()` (migration 98) |
| An `OTHER` document keeps its label, the constraints hold, and the insert path is intact | `assert_other_document_type_is_wired()` (migration 99) |
| The CEO delete is CEO-gated, the service-role-only cascade is unchanged, and the wrapper calls it | `assert_ceo_delete_is_wired()` (migration 100) |
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
| Pre-auth endpoints are deployed reachable (`--no-verify-jwt`) | `check_edge_functions_deployed()` + `PRE_AUTH_FUNCTIONS` |
| A gated order is payable after confirmation, details and upload in one card | `check_availability_payment_flow()` |
| The login screen reports its own outcome instead of spinning forever | `check_login_reports_its_own_outcome()` |
| A bucket the client writes to is created by a migration the deploy workflow actually *executes* | `check_client_buckets_are_created()` |
| Every income figure counts every fee type, the activation fee included | `check_income_readers_count_every_fee_type()` |
| The activation fee is written where an income reader can see it | `check_activation_fee_is_recorded_as_income()` |

Two lessons worth keeping, both paid for:

- **An assertion that only reports `null` is not an assertion.** Migration 66
  lost three deploy cycles to `Expected: not null, Actual: <null>` from an RPC
  whose cache was stale rather than whose logic was wrong. The resilience and
  liveness tests now use `rpcTextDiagnosed`, which prints the actual error.
- **A test must not flatter the code it tests.** Migration 44's probe set
  fixtures that were more generous than production (a confirmed email the
  trigger cannot see at insert time) and reported success for two live paths
  that were in fact broken. The same failure has a source-level shape: the
  harness helper that reads a Dart method body took the first `{` after the
  signature, which for `Future<void> signIn({required String email, ...})` is
  the **parameter list**, so a check written against the body silently
  inspected the wrong text and passed. Every new check was verified by
  reintroducing its bug and confirming it goes red — a check that has never
  failed is not evidence of anything.

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
| `0085` | a gated buyer may open the payment step after confirmation | a confirmed order sits at ACCEPTED with payment details and no way to pay |
| `0076` | likes persist, dislikes replace | a like fills and empties silently |
| `0080` | GPS liveness columns on `user_documents` | **document upload fails** — the client inserts them |
| `0081` | fixed liveness assertion | Connectivity CI red (test only) |
| `0082` | `signup_otp_required` toggle | registration fails with "Database error saving new user" |
| `0083` | `staff_jobs` RLS | the job catalogue is readable with the anon key |
| `0084` | OTP bypass that records no verification | a build in circulation cannot pass the code screen |
| `0086` | `notify_user_once()`: keyed + failure-isolated notification call site | a retried payment notifies twice; an undeliverable notice rolls the payment back |
| `0087` | a welcome on every path that approves an account | accounts are approved and told only that a status changed |
| `0088` | both parties notified on an order payment and a completed ride, with the amount | the provider is never told a payment cleared; the rider is told nothing about the fare |
| `0089` | points→wallet conversion notifies with both figures | points convert to birr silently |
| `0090` | the notifications inbox is still owner-scoped (assertion) | a new definer function could widen who reads the inbox |
| `0091` | the new assertions are executable by `anon` | Connectivity CI cannot call them; PostgREST reports PGRST202, which reads like a missing migration |
| `0092` | the dedupe covers the client-path queue, and two wrong assertions corrected | a retried payment queues the same message twice |
| `0093` | two more assertion needles corrected, and needles are declared + verified | an assertion searches for text that is not there and reports phantom defects |
| `0094` | `assert_source_needles_match()` can actually run (subscripted FOR) | it raises 42804 on every call, so it silently asserts nothing |
| `0095` | the needle table is two flat arrays walked by `unnest(a, b)` | the second dimension cost two deploy cycles: a refused `FOREACH`, then an empty loop |
| `0096` | the five buckets the app then used are declared by a migration the pipeline runs, plus the `provider-gallery` policies `0017` never created | **the provider gallery cannot upload at all** — `provider-gallery` was created only by `0017`, which the workflow marks applied without executing it, so every upload failed with "Bucket not found" (404) and the screen could only show its generic error |
| `0097` | the `vehicle-images` bucket, its policies and table restated, and `add_vehicle_image()` / `delete_vehicle_image()` for the new vehicle-photo client | **a vehicle cannot have a photograph** — the bucket was created only by `0012` (marked applied, never executed), so every vehicle-photo upload 404s; and nothing in `lib/` could write `vehicle_images` at all |
| `0098` | `assert_activation_fee_writes_income()` (write test) and `assert_income_covers_every_fee_type()`, which report the fee figures instead of the vacuous existential negatives | the activation fee keeps being collected with nothing that proves it reaches the ledger, and the money assertions stay green on an empty wallet table |
| `0099` | `other_document_label` + a `document_type` CHECK carrying every value the app has ever written, and the pairing constraint that requires a label exactly when the type is `OTHER` | an `OTHER` upload is refused by the insert (`column "other_document_label" does not exist`), and nothing records which document the person actually uploaded |
| `0100` | `is_ceo_authority()`, `ceo_account_directory()`, `ceo_delete_user_account()` — the wrapper that records the reason in `admin_actions` and then CALLS `delete_user_account()` | the CEO directory and its delete button do not exist (`function … in the schema cache`); `delete_user_account` itself is untouched, and it stays service-role-only |

**0080 before any build that ships the liveness client.** The client inserts
the new columns; if they are absent, every document upload fails.

**A bucket is only as deployed as the migration that creates it.** `0012`,
`0017` and `0033` are all below the workflow's baseline, so the workflow records
them as applied and never runs them; the four buckets that work today work
because they were pasted into the SQL editor, and the two that were not pasted
(the gallery, and `vehicle-images`) did not exist. `0096` re-declares those five
with `ON CONFLICT DO UPDATE` and `0097` adds the sixth (`vehicle-images`) the
same way, so the set no longer depends on that history, and
`check_client_buckets_are_created()` fails the build if a bucket named in `lib/`
is created only by a pre-baseline file. The failure mode this guards against is
the one that shipped: `grep provider-gallery supabase/migrations/` found a
creation statement and looked reassuring — in a file that is never executed.

**The activation fee is income, and `0098` is what proves it.**
`approve_wallet_recharge` withholds the one-time `provider_registration_fee`
from a provider's first approved recharge and records it as `platform_fee` on a
`RECHARGE` ledger row — not a `TRANSACTION_FEE` and not a `SUBSCRIPTION_FEE`. A
reader that filtered on those two types only therefore rendered a confident
`ETB 0.00` while the money had been collected. The read side is fixed (there are
now two income readers, and `check_income_readers_count_every_fee_type()` fails
the build if either stops counting `RECHARGE`); the write side is
`assert_activation_fee_writes_income()`, the only test that drives the
withholding branch — the existing wallet write test deliberately sets
`registration_fee_paid = true` to keep its arithmetic simple. The three
read-only money assertions (`assert_recent_approved_recharges_credited` and the
ride/order fee checks) are existential negatives that pass with zero rows, which
is why `assert_income_covers_every_fee_type()` returns the live figures, fails on
impossible arithmetic, and says so when the ledger is empty.

### 7.2 Edge Functions

Deployed by the `Deploy function …` steps in `.github/workflows/deploy-supabase.yml`.
Every one of these is called from Flutter:

```
repo-chat  index-chunks (--no-verify-jwt)  provider-approval  admin-wallet-recharge
wallet-deduct-fee  subscription-process  order-create  order-transition
ride-claim  ride-transition  document-verify  user-admin  send-otp
staff-create-gateway  staff-delete-gateway  staff-change-password
staff-login (--no-verify-jwt)  login-gate (--no-verify-jwt)
account-change-password  account-deletion-gateway
```

Three notes that are easy to get wrong:

- A function present in `supabase/functions/` is **not** deployed unless the
  workflow has a step for it. That is how "Change password" and "approve
  account deletion" shipped broken (§5.6).
- **A pre-authentication endpoint must be deployed with `--no-verify-jwt`.**
  The gateway refuses an anonymous request to a function deployed with the
  default `verify_jwt=true`, with a bare 401 before the function body runs.
  Three functions are pre-auth by construction — `login-gate`, `staff-login`,
  `index-chunks` — because the caller has no session yet. `login-gate` shipped
  without the flag while its own header said it "must run BEFORE the credential
  check is even attempted", so the gate never executed and no login in the app
  could complete. Being reachable is not the same as being usable, and the
  symptom (a generic "sign-in unavailable") pointed nowhere near the cause.
  `PRE_AUTH_FUNCTIONS` in `tools/harness/static_checks.py` now fails the build
  if one of them loses the flag.
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

1. Connectivity CI green (69 tests). If it is red, the failure message names
   the assertion — read the `Diagnostic:` line before changing anything.
2. Flutter CI green.
3. `select public.assert_signup_otp_toggle_is_consistent();` returns a string,
   not an exception.
4. `select public.assert_document_liveness_is_recorded();` returns a string.
5. `select public.assert_live_map_is_wired();` returns a string.
6. `select public.assert_gated_buyer_payment_request_is_wired();` returns a
   string.
7. `select public.assert_notify_user_once_is_idempotent();` returns a string.
   This one is a **write** test that rolls itself back; run it once after the
   first deploy of `0086`, because it is the only place the dedupe and the
   failure isolation are actually exercised rather than inspected.
8. `select public.assert_approval_welcome_covers_all_paths();`,
   `assert_order_and_ride_receipts_are_sent();`,
   `assert_points_conversion_notifies();`,
   `assert_notification_inbox_is_owner_only();` and
   `assert_every_assertion_is_reachable();` each return a string beginning
   `ok:`. A `FAIL:` prefix names the specific thing that regressed.
9. `select public.assert_source_needles_match();` returns `ok:` — the
   source-matching assertions are comparing against text that exists.
10. `select public.assert_app_buckets_exist();` returns `ok:` and names all
   six buckets. A `FAIL:` prefix names the bucket that is missing or has the
   wrong visibility: `product-images` / `provider-gallery` / `vehicle-images`
   have to be there and public, `user-documents` / `payment-proofs` /
   `payment-screenshots` have to stay private. This is the only check that can
   see a missing bucket — the policy-shape assertion next to it reads
   `pg_policies`, where a bucket with no policies and a bucket that does not
   exist look identical.
11. `select public.assert_activation_fee_writes_income();` returns `true`.
   This is a **write** test that rolls itself back, and it is the only place the
   activation-fee withholding branch is exercised rather than inspected: it
   drives `approve_wallet_recharge` for a provider whose
   `registration_fee_paid` is false and asserts the fee lands as `platform_fee`
   on the `RECHARGE` row. Run it once after the first deploy of `0098`.
   `select public.assert_income_covers_every_fee_type();` returns a string
   beginning `ok:` that prints every fee figure — a `FAIL:` prefix means the
   ledger's arithmetic is impossible or a recharge withheld money without
   recording it as a fee.

**Migrations must be applied before Connectivity CI can pass.** It runs against
the live database, and it runs as the **`anon`** role: the suite builds
`SupabaseClient(_url, _anonKey)` with no session. An assertion granted to
`authenticated` only, and revoked from `anon`, is invisible to it — and
PostgREST reports that as `PGRST202 "could not find the function in the schema
cache"`, which reads like a missing migration and sends you to the wrong file.
Five new assertions failed exactly that way after a clean deploy; migration 91
fixes them and `assert_every_assertion_is_reachable()` now checks the whole
`assert_*` family so the next one fails by name. A `GRANT` to `authenticated` on
its own is harmless — anon inherits EXECUTE-for-PUBLIC — and it is the
`REVOKE ... FROM anon` that removes the suite's only path.

**Nothing can log in until `login-gate` is redeployed with `--no-verify-jwt`**
(§7.2). The flag is in `deploy-supabase.yml`, so any run of the Deploy Supabase
workflow picks it up — but no migration can fix it, because the failure is at
the gateway, before the function body. A build shipped against the old
configuration cannot sign in *anyone* in, and the app says "sign-in is
temporarily unavailable", which names neither the function nor the flag.
