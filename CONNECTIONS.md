# 5BIRR / Aliob — Connection map (Phase 3 reference)

Each verified connection: what writes it, what reads it, and which test in
`tools/integration_test/connectivity_test.dart` covers it. Wire new features
against these known-good paths — do not invent a parallel one.

The whole point of this file (and the CI suite): money/ledger connections
were wired one by one, and the admin **Total Income** still showed 0.00 for
months because two of them were silently broken. Trace action → write →
read → display every time; "looks connected" is not verification.

## Money / wallet ledger

| Connection | Written by | Read by | Covered by |
|---|---|---|---|
| Order transaction fee | `transition_order_status()` on STARTED → `deduct_transaction_fee()` → `wallet_transactions` (`TRANSACTION_FEE`, key `order:<id>`) | `AdminDashboard` + `AdminIncomeSummaryScreen` (sum `platform_fee`) | `assert_recent_started_orders_have_fees` |
| Ride transaction fee | `transition_ride_status()` on COMPLETED → `deduct_transaction_fee()` → `wallet_transactions` (`TRANSACTION_FEE`, key `ride:<id>`) | same | `assert_recent_completed_rides_have_fees` |
| 5birr monthly subscription fee | `charge_due_subscriptions()` (pg_cron daily 03:17 UTC, migration 20260922000004) → `deduct_subscription_fee()` (`SUBSCRIPTION_FEE`, key `sub:<provider>:<period>`) | same | `assert_subscription_scheduler_scheduled` |
| Wallet recharge credit | admin approval → `approve_wallet_recharge()` (`RECHARGE`, key `recharge:<id>`; withholds the one-time registration fee on the first) | `AdminIncomeSummaryScreen`, `WalletService` | `assert_recent_approved_recharges_credited` |
| Admin cash / adjustment | `admin_cash_recharge()` / `admin_wallet_adjustment()` (`ADMIN_CASH` / `ADJUSTMENT`) | wallet history | covered by ledger-consistency check below |
| Ledger ↔ balance integrity | every writer above updates `wallets.balance` in the same transaction | implicit invariant: `balance == sum(net_amount COMPLETED)` | `assert_income_ledger_consistent` + daily `reconcile_income_and_log()` (cron 03:47 UTC) logs `WALLET_LEDGER_DRIFT` rows to `admin_history` |

Payouts (provider withdrawals): no withdrawal flow exists anywhere in the
codebase (no endpoint, no RPC, no screen). Nothing to verify yet — wire a
future one through a SECURITY DEFINER function that writes a ledger row, or
the reconciliation check will flag it as drift on day one.

## Ride chain (user ↔ driver ↔ money)

`create_ride_request` → `claim_ride` (single-winner conditional UPDATE) →
`transition_ride_status`: CLAIMED → DRIVER_ARRIVING → ARRIVED →
TRIP_STARTED → COMPLETED (fee charged here) — with rider/admin cancel
paths. The edge function and the SQL function must authorize the SAME
chain; migration 20260922000005 restored that (the live function was
missing ARRIVED/TRIP_STARTED and froze every ride). Covered by
`assert_ride_transition_covers_chain`. Statuses also land in
`ride_status_history`, which both dashboards read.

## User ↔ provider (orders)

Checkout → `order-create` function → `create_order_secure()` (persists
`fulfillment_mode`, `delivery_address`, `city`; validates activation +
wallet gates) → provider queue (`provider_orders_screen` filters
`orders.provider_id`). Transitions via `order-transition` write
`order_status_history`, which the user's order detail reads back.
Covered by `assert_create_order_persists_fulfillment`.

## City / GPS scoping

Signup → `handle_new_user` stores `profiles.city` (from signup metadata);
profile editor and travel-mode switcher write via `CityService`.
Readers: home feed / search (`p_city`), `visible_products_for_city`,
ride proximity queries. Covered by `assert_profiles_have_city` (column
presence the whole scoping path depends on).

## Staff / sub-admin attribution

`log_admin_action()` appends to `admin_history` (actor, action, metadata);
`staff_performance()` reads approvals + orders + rides per staff user.
`staff_performance` originally queried a nonexistent
`ride_requests.provider_id`. Because 20260922000001 was already applied
to the live DB before the fix existed, the fix ships as NEW migration
20260922000008 (CREATE OR REPLACE, same signature — applied migrations
are never edited). Covered by `assert_staff_performance_uses_claimed_by`.

## How to run the safety net

```bash
flutter test tools/integration_test/connectivity_test.dart \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

CI runs it automatically on every push/PR (`.github/workflows/connectivity-ci.yml`),
with the local `flutter test` suite additionally gating Flutter CI. The
assertion RPCs are read-only booleans granted to `anon` — the suite never
writes app data and never needs a service key.
