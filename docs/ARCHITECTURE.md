# Architecture

Aliob is a Flutter + Supabase marketplace and ride-hailing app. This document
describes the layering the code is meant to follow, one rule per layer, and —
importantly — where the code currently departs from it. The second half is
the honest part; a document that only describes the target is a wish list.

## The shape

```
  screens          lib/features/**
        │  user intent only: no Supabase, no HTTP, no SQL
        ▼
  providers        lib/core/providers/**, lib/core/models/**
        │  derived state: watches services, exposes plain values
        ▼
  services         lib/core/services/**
        │  all I/O lives here: queries, RPC, functions, storage, realtime
        ▼
  Supabase         Postgres + RLS + SECURITY DEFINER + Edge Functions
```

## One rule per layer

### Screens (`lib/features/**`)

A screen renders state and turns taps into calls. It does not talk to
Supabase, does not build a query, does not parse a driver error, and does not
decide what a user should read when something fails.

Anything a screen needs from the network arrives through a service or a
provider. If a screen finds itself writing `.from('products')`, that is a
service that wants extracting — not an exception.

**Error handling in a screen** is presentation only. A screen may decide
*where* to show a failure; it must not decide *what it says*. That is
`AppFailure.message`, already classified and phrased.

### Providers (`lib/core/providers/**`)

Derived state, cached and shared. A provider is invalidated by its
dependencies, never by a manual refresh flag. Providers hold no I/O of their
own — a provider that calls Supabase is a service wearing a disguise.

`ErrorLogger` and `ConnectivityService` are deliberate exceptions: they are
called from `main()` before the provider tree exists, so they are singletons
with a `ValueNotifier` rather than providers.

### Services (`lib/core/services/**`)

All I/O. Every query, RPC call, Edge Function invocation, storage upload,
realtime subscription and third-party HTTP call happens here, and nowhere
else.

**Every network call goes through `safeCall` or `withRetry`.** Not "most" —
every. Resilience applied per call site drifts, and the call sites that
forget are exactly the ones on the critical path.

A service translates exceptions into `AppFailure` via `AppFailureMapper`, and
never lets a raw exception escape to a caller.

### Supabase

The database is the enforcement layer, not the client. Anything the client
can be trusted to enforce is something the client is trusted not to do. RLS,
`SECURITY DEFINER` functions and Edge Functions are where a rule actually
holds.

## Cross-cutting rules

These apply to every layer.

**One classifier.** `AppFailureMapper` is the only place an exception becomes
a kind. Two classifiers is how one fault starts producing two different
sentences in two screens.

**Data beats `[data] wins`.** A failed refresh never replaces good content
with an error. `AsyncView` encodes this; a screen that hand-rolls its own
three states must obey it too.

**No unbounded queries.** Every list query has a `limit`. A table that grows
with orders will not always be small.

**Money is never retried.** `RetryPolicy.money()` is one attempt. Duplicate
charges are worse than failed ones, and the idempotency key is the real
protection.

**Subscribers cannot throw.** A realtime channel error is a transport
problem, not an application fault. `ResilientSubscription` and
`ResilientFeed` exist so a dropped socket degrades to polling instead of
reaching the zone's unhandled-error path.

**A buyer never sees payment information before the provider has confirmed
availability, and neither side sees the other's phone before the payment is
verified.** The order lifecycle already carries both moments, so this costs
no new status and no second checkout (migration 74):

```
PENDING_PROVIDER       provider-only; accepts (availability confirmed) or rejects
ACCEPTED               payment details become visible
PAYMENT_PENDING        buyer attaches the proof — the existing step, unchanged
PAYMENT_VERIFICATION   admin verifies the proof — the existing step, unchanged
APPROVED               release_order_contact() releases the provider's phone
```

Two flags carry it, both `NOT NULL DEFAULT false`, so nothing that works
today changes until a provider opts in: `products.requires_availability_confirmation`
(per listing, set from the product form) and `orders.requires_availability_confirmation`
(an OR over the cart, snapshotted by `create_order_secure` at order creation).
The order-level copy is the one the screens read, deliberately: re-joining
through `order_items` would let a provider close the payment screen on an
order a buyer has already paid for.

## Where the code actually is today

The target above is the direction. These are the gaps, written down so nobody
rediscovers them.

| Gap | State | Why it is still here |
|-----|-------|----------------------|
| Screens call Supabase directly | **Widespread** | `user_category_screen.dart`, `user_orders_screen.dart`, `user_notifications_screen.dart` and most admin screens all build their own queries. The layering is documented, not enforced. |
| The repository layer | **Deleted** | Was unused; deleting it removed a layer nothing traversed. |
| Polling fallback for realtime | **Built, not yet adopted** | `ResilientFeed` in `safe_realtime.dart` runs a channel and a poller together and emits from whichever works. It is written against `realtime_client` **2.13.0** read from the package source, not from memory — the first draft guessed the API and nine assumptions were wrong. `build/rtc_api_check.py` now verifies every call against the downloaded package, and the run script downloads it on demand. No screen uses it yet: `resilient_subscription.dart` still backs the realtime screens, and adopting the feed is a per-screen change that needs a device. |
| `AsyncView` adoption | **Partial** | The new home screen follows the rule by hand; most existing screens still use `LoadErrorView` / `RetryWidget`. |
| Tests for the new services | **Absent** | `live_map_service.dart`, `city_service.dart` and `geocoding_service.dart` have no unit tests. `location_stream_safety_test.dart` covers the location path only. |

The last three are the ones worth scheduling. The first is a large refactor
and is deliberately not attempted in bulk — the brief scopes this work to the
files it touches.

## What is asserted, and where

Correctness that a reviewer cannot check by reading is asserted somewhere
executable. The split matters: SQL is asserted against the live database,
Dart is asserted against source.

| Property | Where it is pinned |
|----------|-------------------|
| Every fee follows `system_settings`, in whichever direction its switch points | `assert_fees_are_data_driven()` (migration 62, switch-aware since 73) |
| Every fee switch actually switches | `assert_fee_switches_are_wired()` (migration 73) |
| Payment is gated on an availability confirmation, contact on verified payment | `assert_availability_gate_is_wired()` (migration 74, restated by 75) |
| The CEO reports are callable, not merely present | `assert_ceo_reports_are_callable()` (migration 72) |
| The CEO authority itself is intact | `assert_ceo_authority_is_wired()` (migration 69) |
| Live map is actually live | `assert_live_map_is_wired()` (migration 61) |
| Error sink, RLS and hot-path indexes exist | `assert_resilience_is_wired()` (migration 64) |
| Category → tab mapping against real seed rows | `test/category_tabs_test.dart` |
| Retry, backoff and jitter maths | `test/retry_backoff_test.dart` |
| Exception classification and non-leakage | `test/failure_mapper_test.dart` |
| Client never writes a table it must not | `test/client_write_surface_test.dart` |
| A failed realtime subscribe cannot crash | `test/realtime_resilient_subscription_test.dart` |

Migrations run only through **Deploy Supabase**, which is `workflow_dispatch`
and defaults to a dry run. A new migration is not live until a human
dispatches it; the Connectivity CI suite then re-runs automatically on the
deploy's completion, which is the first point the new assertions have anything
to check.
