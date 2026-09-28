# 5BIRR / Aliob — Audit (2026-09-28)

Scope: the stability pass requested as "Part 2" — a feature inventory, an
error-handling audit, a data-flow audit of the three money paths, and a
navigation audit. Every claim below is either a machine check that was run, or
a live assertion that Connectivity CI executed against the deployed database.
Where something is only known from reading, it says so.

Legend: ✅ verified · 🟡 works with a known gap · ❌ broken

This supersedes `functional_audit_2026-09-19.md` for anything marked stale
below. That document's screen-by-screen map is still the better index of what
each screen does; its gap list has partly aged out, and the differences are
called out.

---

## 1. Contract audit — the app against the database

Four mechanical checks, all run against the tree at `16bb0a2`.

| Check | Method | Result |
|---|---|---|
| Every in-app navigation target resolves | Extracted every `context.push`/`go`/`replace` string literal under `lib/` and matched it against the 82 `GoRoute` patterns in `app_router.dart` | ✅ **0 unresolved** |
| Every RPC the app calls exists | 65 distinct `rpc('...')` names vs every `FUNCTION public.*` in `supabase/migrations/` | ✅ **65/65 defined** |
| Every table/view the app reads exists | 42 distinct `.from('...')` targets vs `CREATE TABLE` + `CREATE VIEW` | ✅ **42/42 defined** |
| The client write surface is closed | `assert_client_write_surface_is_closed` (live) | ✅ green, 22 tables |

Two notes on the third row, because a bare count would be misleading:
`provider_trust_stats` and `public_provider_profiles` are **views**, not tables
(migration `0027` and `20260924000006`), so they legitimately have no
`CREATE TABLE`. Both are read-only projections.

The navigation check's one apparent miss — `/admin/providers/${p['id']}/wallet`
in `admin_provider_management_screen.dart` — is an interpolation and does match
`/admin/providers/:id/wallet`. Verified by hand.

## 2. Money paths — the three flows, end to end

Each of these is pinned by a **live behavioural assertion**, not by reading.
All were green in the Connectivity CI run that followed the deploy of
`16bb0a2`.

### 2.1 Recharge → approval → credit ✅

`wallet_recharge_requests` (PENDING) → admin approves → `approve_wallet_recharge()`
credits `wallets.balance` and writes the `RECHARGE` ledger row → `RECHARGE`
appears in the income summary and the wallet UI.

- Live: `assert_recent_approved_recharges_credited` ✅
- The registration-fee withholding on the **first** recharge is part of this
  path (0038 §5). Fixed this pass: the "Account activated" notice hardcoded
  "100 birr" regardless of `provider_registration_fee`, so a CEO who changed
  the fee was contradicted by the message the provider received. It now states
  the fee actually withheld.

### 2.2 Transaction → fee → debit ✅

`transition_order_status()` charges on `STARTED` → `deduct_transaction_fee()` →
`platform_transaction_fee()`, which reads `transaction_fee_percent` /
`transaction_fee_min` from `system_settings`. Rides charge the same way on
`COMPLETED` from `transition_ride_status()`.

- Live: `assert_recent_started_orders_have_fees` ✅
- Live: `assert_recent_completed_rides_have_fees` ✅
- Live: `assert_income_ledger_consistent` (no balance diverges from
  `sum(net_amount)`) ✅
- Live: `assert_fees_are_data_driven` ✅, returning the real numbers:
  `commission = GREATEST(1% of gross, 5 birr) (1000 -> 10.00, 100000 -> 1000.00)`

### 2.3 Registration → approval → activation ✅

`handle_new_user()` creates the profile at `PENDING_APPROVAL` → the router gates
on `profiles.status` → admin approves → `approve_user()` sets `APPROVED`,
resolves the `approval_requests` row and writes `approval_history`.

- Live: `assert_profile_status_synced` ✅ (this is the one that used to leak:
  `suspend_provider` set both tables and `unsuspend_provider` restored only one,
  locking people out of their own accounts)
- Live: `assert_otp_gate_uses_verified_at` ✅

### 2.4 Fee switches — fixed this pass ✅

The four `fee_enabled_*` switches were stored and **inert**: flipping one
changed nothing. Each now guards the single point where its money moves, and
`assert_fee_switches_are_wired` proves it against the live database:

```
all four fee switches are wired: transaction=t, subscription=t, registration=t, ride=t
```

Wiring the transaction switch required making `assert_fees_are_data_driven`
switch-aware first — otherwise CI would have gone red the first time a CEO used
it. Half-wiring money is worse than not wiring it; the assertion now checks
both directions.

## 3. Error-handling audit

Rule under test (`docs/ARCHITECTURE.md`): every network call goes through
`safeCall`/`withRetry`; a service translates to `AppFailure` and never lets a
raw exception escape; a failed refresh never replaces good content with an
error.

### 3.1 Does a raw exception ever reach a user? ✅ No

Searched every `lib/**/*.dart` for an exception rendered directly
(`Text('$e')`, `Text(e.toString())`). **Zero matches.** Every failure path that
reaches a screen goes through `friendlyError(...)` or `AppFailure.message`.

Spot-checked the money paths by hand, since "no pattern matched" is weaker
evidence than reading the call site:

- `recharge_screen.dart` — the submit path and the load path both use
  `friendlyError` ✅
- `user_checkout_screen.dart` — same ✅
- `admin_payment_verification_screen.dart` — same ✅

### 3.2 Silent catches 🟡 (21 found, all deliberate)

21 `catch` blocks with no code and no comment. Read individually; every one is
a documented best-effort read whose worst case is a hidden hint, not a lost
write:

| Site | Why it is safe |
|---|---|
| `user_checkout_screen` (platform fee quote) | informational row; the server rechages authoritatively at `STARTED` |
| `user_checkout_screen` (national-ID check) | falls back to *asking* for the ID, which is always safe |
| `recharge_screen` (activations status + fee) | renders a hint; the real fee is applied server-side |
| `provider_activation_service` | falls back to `100`, the same default the server uses |
| `admin_dashboard` (income, permissions) | commented: a failure must not blank the dashboard; RLS still guards every screen |
| `review_service` | reviewer names only; falls back to `''` |
| `geocoding_service` (×3), `vehicle_form_screen`, etc. | optional enrichment |

Verdict: no silent swallow is hiding a broken write. This is the correct
pattern for enrichment reads, and it is applied correctly.

### 3.3 The layering rule is not enforced 🟡 (unchanged, known)

90 files make a Supabase call. **29 mention no resilience helper at all**, and
**13 of those perform writes** with no `try` block:

`cart_service` (5 writes), `staff_gateway_service` (3),
`payment_methods_service` (3), `help_chat_screen` (3),
`document_upload_service` (2), `review_service` (2), `favorites_service` (2),
`order_chat_service` (2), `location_service` (2), `ride_service` (2),
`error_logger` (1), `city_service` (1), `wallet_service` (1).

Mitigation is currently at the call site: if the service throws, the screen's
`friendlyError` catches it. So the **outcome** is right and the **layering** is
wrong. This is the same gap `ARCHITECTURE.md` already records
("Screens call Supabase directly — widespread"). Not fixed here: it is a
per-screen refactor, and doing it in bulk without a device is how a working
screen becomes a broken one.

## 4. Navigation audit ✅

- All 82 routes resolve; every literal target in `lib/` matches one of them.
- Per-role entry points verified by reading `_getDashboardPath`: staff gateway →
  `/staff/dashboard`, ADMIN → `/admin`, vehicle → `/vehicle`, service →
  `/provider`, else `/user`.
- `/ceo` is reachable only in the sense that its route exists; the screen
  re-checks `isCeo` and every query behind it is re-checked server-side by
  `is_ceo()`. A route gate in Flutter is a way to avoid showing a button that
  will be refused, never a protection.
- Approval gating (`/pending-approval`, `/rejected`, `/suspended`) applies to
  buyers and providers and is bypassed for admin accounts, as designed.

## 5. Feature inventory — what is real

Only areas where this pass produced new evidence are listed; the
screen-by-screen map from 2026-09-19 stands.

| Area | State | Evidence |
|---|---|---|
| Auth, approval gating, OTP | ✅ | `assert_otp_gate_uses_verified_at`, `assert_profile_status_synced` |
| Buyer surfaces (search, cart, checkout, orders) | ✅ | contract audit; `order-create` price-authoritative |
| Provider + vehicle surfaces | ✅ | contract audit; live-map and ride-chain assertions green |
| Wallet + recharge | ✅ | `assert_recent_approved_recharges_credited`; correct bucket (`payment-screenshots`) |
| Admin (25 screens) | ✅ | contract audit |
| **CEO workspace** (Staff / Finance / Data / Other) | ✅ | `assert_ceo_authority_is_wired`, `assert_ceo_staff_terms_is_wired`, `assert_ceo_reports_are_callable` |
| Fee on/off + amount editing | ✅ | `assert_fee_switches_are_wired`, `assert_fees_are_data_driven` |
| Favorites list | ✅ fixed | was rendering `"PRODUCT"` + a raw UUID; now hydrates the target's name |
| Push notifications (FCM) | 🟡 | `firebase_messaging` is **not** a dependency — notifications are in-app only |
| Category listing | 🟡 | `visible_products_for_city` ranks by sales and caps at **100** server-side; no pagination past that |
| Realtime | 🟡 | live rides, live map and order status use realtime; `ResilientFeed` (channel + poller together) is built but adopted by no screen |
| Layering rule for network calls (§3.3) | 🟡 | 29 files without helpers; 13 with unwrapped writes |

### Corrected from the 2026-09-19 audit

- "`subscription-process` is orphaned, nothing schedules the fee" — **stale**.
  `assert_subscription_scheduler_scheduled` is green: pg_cron invokes
  `charge_due_subscriptions()`, and the Edge Function is the n8n path. Both now
  honour the subscription switch so they cannot disagree.
- "Category list hard-capped at 50" — the cap is now **100**, server-side, and
  the list is ranked by popularity rather than truncating arbitrarily.
- "`deletion_requests` table does not exist" — the table is
  `account_deletion_requests` (migration 54) and the screen drives it through
  `pending_account_deletion_requests` / `reject_account_deletion`. The path is
  intact; the earlier note used the wrong name.
- "Favorites shows raw UUIDs" — **was true, fixed in this pass.**

## 6. Fixed in this pass

1. **Fee switches enforced end to end** (`20260927000073`): all four wired into
   the five functions that apply a charge, CEO-only like every numeric fee, and
   `subscription-process` updated so the cron cannot suspend anyone for a fee
   that is switched off.
2. **`assert_fees_are_data_driven` made switch-aware** — without this, wiring
   the switch would have broken CI on first use.
3. **`assert_fee_switches_are_wired`** (new, in Connectivity CI).
4. **`assert_ceo_reports_are_callable`** (`20260927000072`) — the CEO payroll
   and city-finance reports are now **called**, not merely checked for
   existence. Migration 69's first deploy shipped a `42703` that only a human
   reading a deploy log caught; this class of failure now fails CI.
5. **`assert_ceo_authority_is_wired` added to Connectivity CI** — it existed and
   nothing called it.
6. **Favorites screen shows real names**, with a non-tappable "no longer
   available" state instead of a dead link.
7. **Activation notice no longer hardcodes "100 birr"**.

## 7. What is still open

Ranked by value, largest first. None of these is a broken money path.

1. **Push notifications.** Needs `firebase_messaging` plus a Firebase project;
   the migration groundwork (0007) exists. Blocks background order/ride alerts.
2. **The layering rule (§3.3).** Introducing `AppFailureMapper` at the service
   boundary for the 13 write-bearing services. Mechanical but per-file.
3. **Pagination for large categories.** The 100-row server cap is honest and
   ranked, but a >100-product category still truncates silently.
4. **Adopting `ResilientFeed`** on the screens that still use
   `ResilientSubscription`. Built and API-verified against the real
   `realtime_client` source; needs a device to exercise.
5. **`AsyncView` adoption** on the 26 screens still using `LoadErrorView`.
6. **An unexplained `pg_policies` row naming a relation `job`** that no
   migration creates. Surfaced by `client_write_surface_report()` raising
   `42P01`. Not user-facing; worth a look before it confuses the next audit.

---

*Audit performed at `16bb0a2`. Fixes are recorded above; the mechanical checks
in §1 and the evidence in §2–§4 were run in this pass, not carried forward.*
