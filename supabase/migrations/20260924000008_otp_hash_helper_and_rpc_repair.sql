-- OTP hashing repair, final piece.
--
-- Live state after 20260924000007: request_email_otp no longer errors on
-- digest(), but now fails with 'function public.sha256_hex(text) does not
-- exist' — the live database never received the sha256_hex helper (or the
-- matching verify_email_otp body) from 20260923000004/ca162c8. Ship both
-- helpers/RPCs here, idempotently, so the whole pair is consistent.

-- Pure-SQL SHA-256 hex helper (core sha256(bytea), PG11+; no pgcrypto
-- dependency — this project exposes digest() only in the extensions schema).
create or replace function public.sha256_hex(p_text text)
returns text
language sql
immutable
as $$
  select encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;

-- Issue a code: the caller (send-otp Edge Function) generates the 6-digit
-- code; Postgres validates, rate-limits, hashes and stores it.
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

-- Verify a code: single active row per email; a wrong code burns an attempt;
-- exhausting attempts or expiry consumes the row.
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
