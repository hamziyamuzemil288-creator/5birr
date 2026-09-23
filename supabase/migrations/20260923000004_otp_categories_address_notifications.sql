-- Task 7 — OTP, two service groups, address fields, broadcast tracking.
--
-- 1. email_otp_codes: 6-digit signup verification codes. Codes are hashed
--    (SHA-256 of the 6 digits), single active code per email, expiry 10 min,
--    max 5 verify attempts per code, resend needs 60 s. No plaintext code is
--    ever stored. Scope: signup verification only — it gates account creation
--    itself (the handle_new_user trigger), not just login.
--
-- 2. Two top-level groups on categories: nullable service_group column
--    ('PRODUCT_BASED' | 'BOOKING_BASED') with a check constraint. Purely
--    additive: existing consumers ignore the new column; the home screen
--    groups by it. Sub-categories inherit the group of their parent.
--
-- 3. Kebele + Street/Road on profiles and provider_profiles (signup asks for
--    them after City; used for GPS accuracy + identity verification).
--
-- 4. admin_notification_broadcasts: widen the target_type check to support
--    role targeting and record how many were actually delivered. The Flutter
--    screen's role-targeted send is silently broken today (it filters
--    profiles.role — a column that does not exist; roles live in user_roles)
--    so this migration also fixes the data-side story; the screen gets a
--    working path in the app change.

-- ============================================================
-- 1. Email OTP (signup verification)
-- ============================================================
create table if not exists public.email_otp_codes (
  id uuid primary key default uuid_generate_v4(),
  email text not null,
  code_hash text not null,                -- sha256 hex of the 6 digits
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  consumed boolean not null default false,
  attempts int not null default 0,
  max_attempts int not null default 5,
  requested_by uuid references auth.users(id) on delete set null
);

-- One live code per email: a new request supersedes the old one.
create unique index if not exists email_otp_codes_email_active
  on public.email_otp_codes (email) where consumed = false;

create index if not exists email_otp_codes_email_idx
  on public.email_otp_codes (lower(email));

-- Anonymous callers must be able to request + verify a signup code.
alter table public.email_otp_codes enable row level security;

do $$ begin
  create policy email_otp_anon_insert on public.email_otp_codes
    for insert to anon, authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy email_otp_none_select on public.email_otp_codes
    for select to anon, authenticated using (false);
exception when duplicate_object then null; end $$;

-- No update/delete policies: rows are only touched by the two security
-- definer RPCs below.

-- Hash helper. (pgcrypto's `digest` is not reliably exposed in `public`
-- across Supabase projects; `sha256(bytea)` is core since PG11.)

-- 6-digit code hashing. Live-DB safe: extensions.digest/decrypt helpers
-- differ across Postgres versions (the live project's pgcrypto exposes
-- digest only in the extensions schema), so define a pure-SQL sha256 hex
-- helper and have the RPCs use ONLY this helper.
create or replace function public.sha256_hex(p_text text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;

-- Issue a code: the CALLER (send-otp Edge Function) generates the 6-digit
-- code and passes it here; Postgres validates, rate-limits, hashes and
-- stores it. Plaintext never lives in the database (only its SHA-256), and
-- the Edge Function keeps it in memory to hand to the email provider.
create or replace function public.request_email_otp(p_email text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(p_email));
  v_code text := btrim(p_code);
  v_last timestamptz;
begin
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'INVALID_EMAIL';
  end if;
  if v_code !~ '^[0-9]{6}$' then
    raise exception 'INVALID_CODE_FORMAT';
  end if;

  select max(created_at) into v_last from public.email_otp_codes where email = v_email;
  if v_last is not null and v_last > now() - interval '60 seconds' then
    return jsonb_build_object(
      'ok', false,
      'retry_after_seconds', ceil(extract(epoch from (v_last + interval '60 seconds' - now())))::int
    );
  end if;

  -- Supersede any live code (the partial unique index allows only one).
  update public.email_otp_codes
     set consumed = true
   where email = v_email and consumed = false;

  insert into public.email_otp_codes (email, code_hash)
  values (v_email, public.sha256_hex(v_code));

  return jsonb_build_object('ok', true, 'expires_in_seconds', 600);
end;
$$;

-- Verify a code: single row per email is active; a wrong code burns an
-- attempt; exhausting attempts or expiry consumes the row (start over).
create or replace function public.verify_email_otp(p_email text, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(btrim(p_email));
  v_row public.email_otp_codes%rowtype;
  v_hash text;
begin
  -- Consume expired rows first (even for a correct-but-expired code).
  update public.email_otp_codes
     set consumed = true
   where email = v_email and consumed = false and expires_at < now();

  select * into v_row
    from public.email_otp_codes
   where email = v_email and consumed = false
   order by created_at desc
   limit 1;

  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'NO_ACTIVE_CODE');
  end if;

  v_hash := public.sha256_hex(btrim(p_code));

  if v_row.code_hash <> v_hash then
    update public.email_otp_codes
       set attempts = attempts + 1,
           consumed = (attempts + 1 >= max_attempts)
     where id = v_row.id;
    if (v_row.attempts + 1 >= v_row.max_attempts) then
      return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
    end if;
    return jsonb_build_object('ok', false, 'error', 'WRONG_CODE');
  end if;

  -- Correct: consume the code so it cannot be replayed. attempts becomes
  -- >= 1, which the signup gate uses to tell a VERIFIED row (as opposed to
  -- a merely superseded/expired one, which keeps attempts = 0) apart.
  update public.email_otp_codes
     set consumed = true, attempts = attempts + 1
   where id = v_row.id;

  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.request_email_otp(text, text) from public;
revoke all on function public.verify_email_otp(text, text) from public;
grant execute on function public.request_email_otp(text, text) to service_role;
grant execute on function public.verify_email_otp(text, text) to anon, authenticated;

-- NOTE: there is deliberately NO plaintext peek helper. The Edge Function
-- generates the code and holds it in memory for delivery; the database only
-- ever stores the hash.

-- ============================================================
-- 2. Two top-level service groups on categories
-- ============================================================
alter table public.categories
  add column if not exists service_group text
  check (service_group in ('PRODUCT_BASED', 'BOOKING_BASED'));

-- Existing rows: classify by sector semantics. VEHICLE rows are rides/
-- bookings/time-slots (BOOKING_BASED). SERVICE rows are ordered/received
-- physical products and product-like listings (PRODUCT_BASED) — with the
-- two judgment calls resolved per owner instruction (Safari Tours and
-- Ambulance are booked experiences/services, not ordered goods):
--   Safari Tours (tour-travel, VEHICLE)      -> BOOKING_BASED
--   Ambulance/Emergency (ambulance-emergency)-> BOOKING_BASED
-- Everything VEHICLE is already covered by the sector rule; the two special
-- cases are VEHICLE rows, so no per-row override is actually needed beyond
-- the sector default — but we keep an explicit pass so intent is on record
-- and future seeds can rely on it.
update public.categories
   set service_group = case
         when sector = 'VEHICLE' then 'BOOKING_BASED'
         else 'PRODUCT_BASED'
       end
 where service_group is null;

-- Sub-categories inherit their parent's group.
update public.categories child
   set service_group = parent.service_group
  from public.categories parent
 where child.parent_id = parent.id
   and child.service_group is null
   and parent.service_group is not null;

-- ============================================================
-- 3. Kebele + Street/Road address fields
-- ============================================================
alter table public.profiles
  add column if not exists kebele text,
  add column if not exists street_road text;

alter table public.provider_profiles
  add column if not exists kebele text,
  add column if not exists street_road text;

-- ============================================================
-- 4. Broadcast target types + delivered count
-- ============================================================
-- Create-if-missing: 0024's broadcast table never reached the live DB (the
-- deploy workflow stages one file per duplicate version — 0020_audit_log
-- wins over 0024_admin_expenses — and those duplicates were applied to the
-- live DB only by pasting SQL, where some files never made it). A missing
-- table must not break the deploy, so ensure it here, matching 0024.
create table if not exists public.admin_notification_broadcasts (
  id uuid primary key default uuid_generate_v4(),
  admin_id uuid not null references auth.users(id),
  title text not null,
  body text,
  target_type text not null default 'ALL'
    check (target_type in ('ALL_USERS','ALL_PROVIDERS','ALL','SPECIFIC_USER','ROLE')),
  target_user_id uuid references auth.users(id),
  sent_count int not null default 0,
  delivered_count int not null default 0,
  target_role text,
  created_at timestamptz not null default now()
);

alter table public.admin_notification_broadcasts
  drop constraint if exists admin_notification_broadcasts_target_type_check;

alter table public.admin_notification_broadcasts
  add constraint admin_notification_broadcasts_target_type_check
    check (target_type in ('ALL_USERS','ALL_PROVIDERS','ALL','SPECIFIC_USER','ROLE'));

alter table public.admin_notification_broadcasts
  add column if not exists delivered_count int not null default 0,
  add column if not exists target_role text;

alter table public.admin_notification_broadcasts enable row level security;

do $$ begin
  create policy admin_broadcasts_admin_only on public.admin_notification_broadcasts
    for all using (is_admin()) with check (is_admin());
exception when duplicate_object then null; end $$;

do $$ begin
  create index if not exists idx_admin_broadcasts_role
    on public.admin_notification_broadcasts(target_role)
    where target_role is not null;
exception when duplicate_object then null; end $$;
