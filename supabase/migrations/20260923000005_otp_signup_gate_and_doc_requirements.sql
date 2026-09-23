-- Task 7 — server-side enforcement for OTP signup + document gates.
--
-- A. OTP-gated signup: handle_new_user refuses to create a profile unless a
--    verified email OTP exists for the signup email (verified within the
--    last 24 h — enough grace for a client retry after a transient signUp
--    failure, short enough to matter). The client flow (request -> verify ->
--    signUp) is never trusted; this trigger is the enforcement point. The
--    true Admin account (registered directly in Supabase, outside the app,
--    without an OTP) is explicitly exempt — without the exemption the gate
--    would break manual admin creation in the Supabase dashboard, which is
--    the documented path for the CEO account.
--
-- B. Per-action document requirements: which document types a provider must
--    have verified (AUTO_APPROVED) or pending review before they may
--    (a) upload a product/vehicle or (b) claim/accept an order. Signup no
--    longer requires documents for providers — the gate moves to the first
--    protected action after wallet recharge.
--
-- C. Broadcasts: backfill target rows for the ROLE type fix.
--
-- ============================================================
-- A. OTP gate on signup
-- ============================================================
create or replace function public.otp_verified_recently(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.email_otp_codes
    where email = lower(btrim(p_email))
      and consumed = true
      and attempts > 0          -- consumed by a successful verify, not superseded
      and attempts <= 2         -- 1 = verified, 2 = verified then row touched again
      and created_at > now() - interval '24 hours'
  );
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin_subject boolean;
begin
  -- Exemption: accounts created in the Supabase dashboard (true Admin /
  -- support-created accounts) have no signup OTP. The dashboard sets
  -- email_confirmed_at directly (the SMTP path would have confirmed it);
  -- app signups never do (email confirmation is disabled in this project).
  v_is_admin_subject := new.email_confirmed_at is not null
                        and new.raw_user_meta_data is null;

  if not v_is_admin_subject
     and not public.otp_verified_recently(new.email) then
    raise exception 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  end if;

  -- 1. Create the profile with the complete signup data (skip if the row
  --    already exists). status is always PENDING_APPROVAL.
  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city, kebele, street_road)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'PENDING_APPROVAL'::account_status,
    COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
    NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
    NULLIF(new.raw_user_meta_data ->> 'street_road', '')
  )
  ON CONFLICT (id) DO NOTHING;

  -- 2. Assign the USER role (skip if already present).
  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 3. Create an approval request so admins can review this user.
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'PENDING_APPROVAL'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  -- 4. Provider signups: create the provider profile from metadata.
  --    trg_provider_profiles_auto_setup then assigns the provider role and
  --    opens the provider approval request, exactly as a client-side
  --    insert would have. Documents are NOT collected at signup anymore
  --    (Task 7): the gate moves to the first protected action.
  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,        COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', '')
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;

  RETURN new;
END;
$$;

-- ============================================================
-- B. Document requirements for protected provider actions
-- ============================================================
-- Providers must have these recorded (row exists; AUTO_APPROVED or still
-- MANUAL_REVIEW counts — SUSPECTED_FRAUD does not) before uploading
-- listings or claiming orders.
create or replace function public.provider_docs_satisfied(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
    from (values ('NATIONAL_ID'), ('DRIVING_LICENSE')) as req(doc_type)
    where not exists (
      select 1 from public.user_documents d
      where d.user_id = p_user_id
        and d.document_type = req.doc_type
        and coalesce(d.verification_status, 'MANUAL_REVIEW') in ('MANUAL_REVIEW', 'AUTO_APPROVED')
    )
  );
$$;

grant execute on function public.provider_docs_satisfied(uuid) to authenticated;

-- ============================================================
-- C. Broadcast bookkeeping backfill (ROLE type support)
-- ============================================================
-- No backfill needed: the table starts empty for ROLE rows. The check
-- constraint widening in 20260923000004 already allows the new value.
