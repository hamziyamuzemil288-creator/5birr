-- OTP RPC repair, shipped as its own version.
--
-- WHY A SECOND TIME: the same repair was appended to
-- 20260924000006_public_provider_view_hardening.sql, but that version had
-- ALREADY been applied to the live database at 17:41 (before the OTP repair
-- was added to the file). db push tracks applied migrations by version
-- string only, so the later edit never re-ran. This new version guarantees
-- execution.
--
-- Live failure being repaired (confirmed by direct RPC probe):
--   request_email_otp -> 'function digest(text, unknown) does not exist'
-- The live body still calls pgcrypto digest(), which this project's pgcrypto
-- exposes only in the extensions schema. Recreate the RPC against the
-- pure-SQL sha256_hex helper (same logic as 20260923000004; ca162c8 fixed
-- verify_email_otp on live but request_email_otp never received the fix).
--
-- Idempotent: safe to re-apply.

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
