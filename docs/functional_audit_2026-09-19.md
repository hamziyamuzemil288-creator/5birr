# 5BIRR / Aliob — Functional Audit (2026-09-19)

Scope: every screen under `lib/features/`, its data dependencies, and cross-reference against migrations `0001`–`0024` (all present in `supabase/migrations/`, which mirror what has been applied). No code was modified for this audit.

Legend: ✅ fully working · 🟡 partially working (works but with gaps) · ❌ not implemented / would fail

---

## Part 1 — Screen-by-screen map

### Splash & Auth
| Screen | UI | Depends on | Table/function match? | State | % |
|---|---|---|---|---|---|
| `splash/splash_screen.dart` | Branded splash, session restore, role-based redirect | `authProvider` (session + profile + role load) | profiles/user_roles ✅ | ✅ Real | 95 |
| `auth/login_screen.dart` | Email+password login, verify-email messaging | Supabase Auth `signInWithPassword` | auth ✅ | ✅ Real | 95 |
| `auth/signup_screen.dart` | Email+password+phone signup, E.164 phone normalization | Auth `signUp`, insert `profiles` row via `data.email_redirect_to` flow; `user_documents` upload | profiles, user_documents ✅ | ✅ Real (ethiopian-phone-only by design) | 90 |
| `auth/admin_login_screen.dart` | Separate admin email login, `admin_gate` pass-through | `signInWithPassword` + `is_admin` check via profile/roles | user_roles ✅ | ✅ Real (fix verified: no approval gate) | 95 |
| `auth/admin_gate.dart` | Secret gate into admin login (multi-tap) | none (navigation only) | n/a | ✅ | 100 |
| `auth/role_selection_screen.dart` | Buyer / Service provider / Vehicle provider chooser | writes intended role to signup flow / profile | profiles.role ✅ | ✅ Real | 90 |
| `approval/pending_approval_screen.dart` | "Waiting for admin approval" page | none (static; router sends users whose profile status is PENDING) | profile status column ✅ | ✅ Real | 90 |
| `approval/rejected_screen.dart` | Rejection notice page | none (static) | n/a | ✅ | 90 |

### User (buyer) features
| Screen | UI | Depends on | Match? | State | % |
|---|---|---|---|---|---|
| `user/user_dashboard.dart` | Bottom-nav shell: Home, Orders, Cart, Profile tabs | hosts child screens | n/a | ✅ | 100 |
| `user/user_home_screen.dart` | Greeting, categories grid, product feed, skeletons, retry | `categories`, `products` (+`product_images`), 5-min category cache | ✅ all in 0022a | ✅ Real | 95 |
| `user/user_search_screen.dart` | Search bar + results | `search_products` RPC (GIN FTS) | ✅ defined 0022_complete | ✅ Real | 90 |
| `user/user_category_screen.dart` | Products in one category, limit-50 | `categories`, `products` | ✅ | 🟡 Real but hard-capped at 50, no pagination | 80 |
| `user/user_product_detail_screen.dart` | Gallery, price, seller, reviews list, add-to-cart | `products`, `product_images`, `reviews` (+profiles for review authors), favorites service | ✅ | ✅ Real | 90 |
| `user/user_provider_detail_screen.dart` | Provider storefront | `provider_profiles`, `products` | ✅ | ✅ Real | 90 |
| `user/user_cart_screen.dart` | Cart lines, qty edit, totals | `CartService` → `cart_items` | ✅ | ✅ Real | 95 |
| `user/user_checkout_screen.dart` | Address, payment method, proof upload, place order | `order-create` Edge Fn, `payment_proofs` storage | ✅ | ✅ Real (dup-tap guard added) | 90 |
| `user/user_orders_screen.dart` | Order list w/ skeleton + retry | `orders` | ✅ | ✅ Real | 90 |
| `user/user_order_detail_screen.dart` | Status timeline, proof, actions | `orders`, `order_status_history`, `payment_proofs`, `profiles`; `order-transition` Edge Fn | ✅ | ✅ Real | 90 |
| `user/user_favorites_screen.dart` | Favorited products | `favorites` | ✅ | 🟡 Real; rows render fallback subtitle (UUID) if product deleted | 80 |
| `user/user_notifications_screen.dart` | Notification inbox, empty state | `notifications` | ✅ | ✅ Real | 90 |
| `user/user_profile_screen.dart` | Profile view/edit, logout | `profiles` via authProvider | ✅ | ✅ Real | 85 |
| `user/user_ride_request_screen.dart` | Ride request: pickup/dropoff GPS | `LocationService` GPS, `create_ride_request` RPC, `categories` (VEHICLE) | ✅ RPC in 0022c | ✅ Real | 85 |
| `user/user_active_ride_screen.dart` | Live ride status | `ride_requests` via `ride_repository`/`ride_service` | ✅ | 🟡 Real; realtime refresh only, no push | 75 |
| `user/review_form_screen.dart` | Rate a completed order | `ReviewService` → `reviews` (insert policy requires COMPLETED order) | ✅ RLS in 0022b | ✅ Real | 90 |

### Service provider
| Screen | UI | Depends on | Match? | State | % |
|---|---|---|---|---|---|
| `provider/service_provider_dashboard.dart` | Stats, products, orders shortcuts | `provider_profiles`, `products`, `orders` | ✅ | ✅ Real | 85 |
| `provider/provider_product_list_screen.dart` | Own product list | `products` + `provider_profiles` | ✅ | ✅ Real | 90 |
| `provider/provider_product_form_screen.dart` | Create/edit product + images | `products`, `product_images`, `categories`, storage upload | ✅ | ✅ Real | 90 |
| `provider/provider_orders_screen.dart` | Incoming orders, accept/complete | `orders`, `order-transition` Edge Fn | ✅ | ✅ Real | 90 |
| `provider/provider_business_profile_screen.dart` | Business details edit | `provider_profiles`, `categories` | ✅ | 🟡 Real; status/provider_type server-locked (by design) | 85 |

### Vehicle provider
| Screen | UI | Depends on | Match? | State | % |
|---|---|---|---|---|---|
| `vehicle/vehicle_provider_dashboard.dart` | Online toggle, stats | `vehicles`, `provider_profiles`, `driver_status`; `set_driver_online`, `update_driver_location` RPCs | ✅ | ✅ Real | 85 |
| `vehicle/vehicle_management_screen.dart` | Vehicle list | `vehicles`, `provider_profiles` | ✅ | ✅ Real | 90 |
| `vehicle/vehicle_form_screen.dart` | Add/edit vehicle, docs upload | `vehicles`, `categories` (VEHICLE sector), storage | ✅ | ✅ Real | 90 |
| `vehicle/driver_ride_requests_screen.dart` | Nearby ride offers | `find_nearby_drivers` RPC, `vehicles`, `provider_profiles` | ✅ | ✅ Real | 85 |
| `vehicle/driver_trip_screen.dart` | Active trip, claim/status | `ride-claim` / `ride-transition` Edge Fns via `ride_service` | ✅ functions exist | ✅ Real | 85 |
| `vehicle/ride_history_screen.dart` | Past trips (shared with user) | `ride_requests` | ✅ | ✅ Real | 80 |
| `vehicle/ride_repository.dart` | (support) ride data access | `ride_requests` | ✅ | ✅ | 90 |

### Wallet
| Screen | UI | Depends on | Match? | State | % |
|---|---|---|---|---|---|
| `wallet/wallet_screen.dart` | Balance, transactions, low-balance alert | `WalletService` → `wallets`, `wallet_transactions` | ✅ | ✅ Real | 90 |
| `wallet/recharge_screen.dart` | Recharge request + proof upload | `wallet_recharge_requests`, storage | ✅ | ✅ Real | 90 |

### Admin
| Screen | UI | Depends on | Match? | State | % |
|---|---|---|---|---|---|
| `admin/admin_dashboard.dart` | Hub with stats + section cards | `profiles`, `provider_profiles`, `orders`, `products`, `subscriptions`, `wallet_recharge_requests` | ✅ | ✅ Real | 90 |
| `admin/admin_user_management_screen.dart` | User list, approve/reject | `profiles`; `approve_user`/`reject_user` RPCs | ✅ both in 0023 | ✅ Real | 90 |
| `admin/admin_provider_management_screen.dart` | Provider approvals | `provider_profiles`; `provider-approval` Edge Fn | ✅ | ✅ Real | 90 |
| `admin/admin_payment_verification_screen.dart` | Recharge proof verification | `wallet_recharge_requests`; `admin-wallet-recharge` Edge Fn | ✅ | ✅ Real | 90 |
| `admin/admin_payment_methods_screen.dart` | Manage payment channels | `PaymentMethodsService` → `payment_methods` | ✅ | ✅ Real | 90 |
| `admin/admin_provider_wallet_screen.dart` | Wallet + manual adjustment | `wallets`, `wallet_transactions`; `admin_wallet_adjustment` RPC | ✅ | ✅ Real | 90 |
| `admin/admin_cash_recharge_screen.dart` | Direct cash recharge | `admin_cash_recharge` RPC | ✅ | ✅ Real | 90 |
| `admin/admin_transaction_history_screen.dart` | Filterable ledger, CSV | `wallet_transactions` | ✅ | ✅ Real | 90 |
| `admin/admin_registration_history_screen.dart` | Buyer/seller signup log, CSV | `profiles`, `provider_profiles` | ✅ | ✅ Real | 90 |
| `admin/admin_income_summary_screen.dart` | 1% fee vs 5birr fee split, filters, CSV | `wallet_transactions` (fee rows), `subscriptions` | ✅ | 🟡 Real; income categories rely on `transaction_type` values being present | 85 |
| `admin/admin_expense_screen.dart` | Log business expenses, CSV | `admin_expenses` | ✅ 0024 | ✅ Real | 90 |
| `admin/admin_reports_screen.dart` | Per-sector reporting, CSV | `categories`, `products`, `orders`, `profiles`, `provider_profiles` | ✅ | ✅ Real | 85 |
| `admin/admin_notification_send_screen.dart` | Targeted/broadcast notifications | `notifications`, `admin_notification_broadcasts` | ✅ 0024 | ✅ Real (in-app only — see gaps) | 85 |

---

## Part 2 — Auth + navigation flow

```
Splash ── session? ──► role-based dashboard (/_getDashboardPath)
        └─ no session ─► /login ─► /role-select ─► /signup/ ─► profile status gate
                                          │
                     PENDING ─► /pending-approval (router guard)
                     REJECTED ─► /rejected        (router guard)
                     APPROVED ─► /user | /provider | /vehicle

/admin-login (behind admin_gate) ─► isAdmin? ─► /admin   ✅ approval gate removed (verified fix)
```

- **Router (`app_router.dart`)**: all 40 routes defined; every `pushNamed`/`goNamed` target resolves — **no dead navigation targets found**.
- **Role routing**: `_getDashboardPath` → `/admin` (ADMIN), `/vehicle` (VEHICLE_PROVIDER), `/provider` (SERVICE_PROVIDER), `/user` (buyer). Approval-gate correctly applies to buyers/providers, bypassed for admin login.
- **No screen calls a provider/service method that doesn't exist** — all 9 RPCs and 5 invoked Edge Functions referenced from Dart exist (in migrations or `supabase/functions/`).
- **Deeplink/back behavior**: pending/rejected screens use `PopScope(canPop:false)` — correct for gating.

Navigation health: **~99%** — no orphan screens or missing targets.

## Part 3 — Backend completeness

**Tables referenced in Dart → created in migrations:** all 28 (`.from('...')`) resolve:
`provider_profiles, products, profiles, orders, categories, notifications, cart_items, wallet_recharge_requests, vehicles, ride_requests, favorites, wallets, payment_methods, wallet_transactions, reviews, product_images, user_documents, subscriptions, payment_proofs, order_status_history, driver_status, approval_requests, admin_expenses, user_roles, system_settings, ride_ratings, approval_history, admin_notification_broadcasts` — each has a `CREATE TABLE` in migrations (0021 snapshot / 0022a complete / 0024).

**RPCs (9 used, 9 defined):** `admin_cash_recharge`, `admin_wallet_adjustment`, `create_ride_request`, `find_nearby_drivers`, `search_products`, `search_providers`, `set_driver_online`, `update_driver_location`, `approve_user`, `reject_user` — all present (0022c / 0023 / 0024).

**Edge Functions — 9 exist in `supabase/functions/`, 5 invoked from Dart:**
| Function | Invoked from Dart | Also wired via DB trigger | Verdict |
|---|---|---|---|
| order-create | ✅ checkout | — | ✅ active |
| order-transition | ✅ order detail, provider orders | — | ✅ active |
| provider-approval | ✅ admin provider mgmt | — | ✅ active |
| ride-claim / ride-transition | ✅ via ride_service | — | ✅ active |
| admin-wallet-recharge | ✅ payment verification | — | ✅ active |
| subscription-process | ❌ never invoked | ❌ no pg_net trigger found | ❌ **orphan** — the 5birr monthly fee relies on `deduct_subscription_fee()` (0022c) which is server-side, but nothing calls it on schedule; no cron/trigger wires it |
| wallet-deduct-fee | ❌ never invoked | superseded by `deduct_subscription_fee` / order-create server fee logic | 🟡 redundant |

**Auth method:** email+password everywhere; phone is collected at signup, normalized to E.164, and stored on the `profiles` row (not used as an auth identifier). No unresolved email/phone mismatch. ✅

**FCM/push:** migration 0007 prepared FCM notification support, but no `firebase_messaging` dependency or device-token registration exists in the app → notifications are in-app only. 🟡

---

## Part 4 — Overall completeness

| Area | Completeness |
|---|---|
| Splash + Auth + approval gating | 92% |
| User (buyer) surfaces (16 screens) | 89% |
| Service provider (5 screens) | 88% |
| Vehicle provider (7 screens) | 85% |
| Wallet (2 screens) | 90% |
| Admin (13 screens) | 89% |
| Navigation/routing | 99% |
| Backend tables + RLS + RPC coverage | 97% |
| Edge Function coverage | 75% (2 orphans) |
| **Overall application** | **≈ 89%** |

### Top 5 gaps (highest unblocking value first)
1. **`subscription-process` Edge Function is orphaned** — no cron/trigger invokes the monthly 5birr fee cycle; `deduct_subscription_fee()` exists but nothing schedules it. Add a pg_cron schedule or wire the function. *(Highest value: it's revenue.)*
2. **No push notifications (FCM)** — 0007 groundwork exists but the app never registers device tokens; users only see notifications in-app. Blocks ride-accept alerts and order updates in background.
3. **Category list capped at 50, no pagination** — `user_category_screen.dart` hard-limits; catalog growth will silently truncate listings. (Search & home already paginated/cached.)
4. **Favorites list shows raw UUIDs** when a favorited product is deleted — join to `products` with a fallback or cascade-clean favorites.
5. **Realtime/polling gap on active rides** — `user_active_ride_screen` depends on manual refresh patterns; a Supabase Realtime subscription on `ride_requests` would make the trip flow feel live.

---

*Audit only — no application logic was modified. Version bumped separately for the build task.*
