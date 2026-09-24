-- Follow-up to 20260924000004: the hardened public_provider_profiles view must
-- ship as a NEW version because db push tracks applied migrations by version
-- string only — editing 20260924000004 in place left the leaky first revision
-- live. The live view still carries kebele/street_road/business_address, and
-- CREATE OR REPLACE VIEW cannot drop columns (SQLSTATE 42P16), so it must be
-- dropped and recreated.
--
-- Restricted out (verified by the live probe + regression harness):
--   owner_national_id, national_id, user_id, owner_name,
--   kebele, street_road, business_address
--
-- ALSO REPAIRED HERE: request_email_otp's body on the live database still
-- references pgcrypto digest(text, unknown) (live pgcrypto exposes digest
-- only in the extensions schema), so every OTP request failed with 42883 and
-- send-otp returned otp_request_failed. Recreate both OTP RPCs against the
-- pure-SQL sha256_hex helper (same logic as 20260923000004).

DROP VIEW IF EXISTS public.public_provider_profiles;

CREATE VIEW public.public_provider_profiles
WITH (security_barrier = true)
AS
SELECT
  p.id,
  p.business_name,
  p.business_description,
  -- City-level location only: kebele/street_road/business_address are address
  -- data and stay private to the owner and admins.
  p.city AS address_text,
  p.location_lat,
  p.location_lng,
  p.service_category,
  p.price_range,
  p.is_active,
  p.subscription_paid,
  p.subscription_due_date,
  p.provider_type,
  p.status,
  p.category_id,
  p.city,
  p.registration_fee_paid,
  p.created_at
FROM public.provider_profiles AS p
WHERE p.status = 'APPROVED';

GRANT SELECT ON public.public_provider_profiles TO anon, authenticated;

-- ---- OTP RPC repair (digest -> sha256_hex) --------------------------------
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

  update public.email_otp_codes
     set consumed = true
   where email = v_email and consumed = false;

  insert into public.email_otp_codes (email, code_hash)
  values (v_email, public.sha256_hex(v_code));

  return jsonb_build_object('ok', true, 'expires_in_seconds', 600);
end;
$$;

revoke all on function public.request_email_otp(text, text) from public;
grant execute on function public.request_email_otp(text, text) to service_role;
