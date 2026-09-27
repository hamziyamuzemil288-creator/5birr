-- supabase/tests/manual_fee_change_verification.sql
--
-- Proves, against a real database, that changing a fee in the CEO panel
-- changes what the platform charges next — without charging anyone. Every
-- statement runs inside one transaction that is rolled back at the bottom, so
-- production is left exactly as it was found.
--
-- WHY THIS IS MANUAL AND NOT IN CI: `admin_update_setting()` requires a real
-- CEO/admin identity (`auth.uid()` + is_ceo()), and CI has only the anon key.
-- Connectivity CI proves the read side is settings-driven
-- (assert_fees_are_data_driven()); this proves the write side end to end.
--
-- HOW TO RUN
--   Supabase Dashboard → SQL Editor, pasted in full, or
--   `supabase db execute --file supabase/tests/manual_fee_change_verification.sql`
--
--   The SQL editor has no JWT, so step 0 impersonates the CEO for this
--   transaction only. Replace the placeholder with a real admin/CEO user id
--   (select id from auth.users where email = '...').

begin;

-- ── 0. Act as the CEO for this transaction only ──────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'PASTE-A-REAL-CEO-USER-ID-HERE', 'role', 'authenticated')::text,
  true
);

-- ── 1. Baseline: what the platform charges right now ─────────────────────
select public.assert_fees_are_data_driven() as "1. baseline assertion";

select
  public.platform_transaction_fee(1000)    as "1. fee on a 1,000 order",
  public.platform_transaction_fee(100000)  as "1. fee on a 100,000 order";

-- ── 2. Change the commission live, exactly as the CEO screen does ───────
select (public.admin_update_setting('transaction_fee_percent', '2.5'::jsonb) is not null)
  as "2. percent set to 2.5";
select (public.admin_update_setting('transaction_fee_min', '3'::jsonb) is not null)
  as "2. minimum set to 3";

-- ── 3. The NEXT charge uses the new values. No deploy, no restart ────────
-- Expected with percent=2.5, min=3:  1,000 -> 25.00   and   100,000 -> 2,500.00
select
  public.platform_transaction_fee(1000)    as "3. fee on a 1,000 order after",
  public.platform_transaction_fee(100000)  as "3. fee on a 100,000 order after";

-- ── 4. The wallet path agrees: deduct_transaction_fee() debits this number
select public.platform_transaction_fee(1000)
         = greatest(round(1000 * 2.5 / 100, 2), 3)
  as "4. wallet path matches the settings";

-- ── 5. The change is attributable ────────────────────────────────────────
select changed_at as "5. when", key as "5. fee",
       old_value as "5. before", new_value as "5. after", actor_name as "5. who"
  from public.admin_fee_change_history(5);

-- ── 6. Ride pricing follows the same rule ───────────────────────────────
select public.calculate_fare_estimate(9.0108, 38.7613, 9.0300, 38.7900, null)
  as "6. fare before";

select (public.admin_update_setting('ride_per_km', '35'::jsonb) is not null)
  as "6. per-km set to 35";

select public.calculate_fare_estimate(9.0108, 38.7613, 9.0300, 38.7900, null)
  as "6. fare after";

-- ── 7. Bounds are enforced (these must RAISE, not silently store) ───────
-- Uncomment one at a time; each should fail with a named exception.
-- select public.admin_update_setting('transaction_fee_percent', '-1'::jsonb);
--   -> FEE_transaction_fee_percent_CANNOT_BE_NEGATIVE
-- select public.admin_update_setting('transaction_fee_percent', '150'::jsonb);
--   -> FEE_transaction_fee_percent_MUST_BE_AT_MOST_100_PERCENT
-- select public.admin_update_setting('ride_per_km', '"twenty"'::jsonb);
--   -> FEE_ride_per_km_MUST_BE_A_NUMBER

-- ── 8. Nothing above is kept ────────────────────────────────────────────
rollback;
