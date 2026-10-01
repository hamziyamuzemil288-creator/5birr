# Delete Your 5birr Account

**The public page for this is [`docs/delete-account.html`](docs/delete-account.html)**
— publish it and submit that URL in Google Play Console under
**Data safety → Account deletion**. This file is the repository's copy of the
same information; it is not what a Play reviewer can load.

## How deletion actually works

Deletion is a **request that a person decides**, not an instant self-service
wipe. Email is no longer the route.

1. Sign in to the app and open **Profile**.
2. Tap **Delete Account** (last item in the account menu).
3. Enter a reason in **"Why are you leaving? (required)"** (at least 10
   characters) and optionally add detail in **"Anything else we should know?
   (optional)"**.
4. Tap **SUBMIT REQUEST**.

Nothing is deleted on submit — the account keeps working until a staff member
with the `account_deletion` job approves. The status, and any note back from
the team, appears on the same screen and in an in-app notification.

- Client: `lib/features/settings/account_deletion_screen.dart`, routed at
  `/account/deletion` and reached from `lib/features/user/user_profile_screen.dart`.
- Server: `request_account_deletion` / `my_account_deletion_requests` in
  `supabase/migrations/20260927000054_account_deletion_requests.sql`; the
  approval cascade is `delete_user_account`, called by the
  `account-deletion-gateway` Edge Function with the service role.
- The cascade only actually runs once **20260927000118** is deployed: before it,
  a nullable `NO ACTION` key such as `audit_logs.actor_id` still raises 23503 on
  `DELETE FROM auth.users`, so the delete dies after the request has already been
  marked APPROVED. `check_account_deletion_is_unblocked()` and the live
  `account_deletion_blockers()` RPC both report on that.

## What is deleted, and what is kept

The authoritative, machine-checked list is the appendix in
`docs/delete-account.html`, and it is derived from the foreign keys by
`check_account_deletion_page_is_public_and_true()`. In short:

- **Deleted:** the sign-in account, the profile, roles, uploaded documents,
  notifications, favourites, likes, cart, chat, appeals, one-time codes — and,
  for a business or driver, the business profile, listings, gallery, vehicles,
  subscription, staff records and the provider wallet with its ledger.
- **Kept, with the link to the account removed:** orders, ride requests,
  reviews, ratings, support tickets, payment agreements, wallet recharge
  requests, and the audit trail. These are money that has already moved and the
  platform's own record; the account reference is set to NULL so they cannot be
  traced back to a login. The same applies on the business side: `orders.provider_id`
  and the rest of the provider-facing keys are detached too, so a shop, a service
  provider and a driver are closed by the same request, with no manual step.
- **Kept as text on a surviving record:** the delivery address on an order, the
  pickup and destination on a ride, the `reporter_phone` on a support ticket,
  and the name written on staff audit lines. 20260927000054 nulls the *link*,
  not these copies.
- **Depends on the account type:** `wallet_recharge_requests` and four staff
  tables are deleted for the account that owns them and retained for everyone
  else.

## Email

If you cannot sign in, email **muktarbiya329@gmail.com** from the address on the
account with the subject "Delete my account". We process email requests within 7
business days. We cannot delete an account from an email address alone if we
cannot verify it belongs to the account holder.
