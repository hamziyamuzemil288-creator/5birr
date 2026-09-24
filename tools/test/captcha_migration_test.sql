-- Standalone local test for 20260924000003_captcha_challenges.sql (Task 10).
-- Build a minimal mock schema, apply the migration, and assert challenge and
-- appeal enforcement behavior. Run:
--   sudo -u postgres psql -d captcha_test -f tools/test/captcha_migration_test.sql
-- The test expects the migration copy at /tmp/20260924000003_captcha_challenges.sql.

\set ON_ERROR_STOP on

create schema if not exists public;
create extension if not exists "uuid-ossp";

do $$ begin
  create role anon nologin;
exception when duplicate_object then null; end $$;
do $$ begin
  create role authenticated nologin;
exception when duplicate_object then null; end $$;

create table if not exists public.system_settings (
  key text primary key,
  value jsonb not null,
  description text,
  updated_by uuid,
  updated_at timestamptz not null default now()
);
create or replace function public.is_admin() returns boolean
language sql stable as $$
  select coalesce(current_setting('test.is_admin', true), 'off') = 'on'
$$;
create or replace function public.prevent_system_settings_self_modification()
returns trigger language plpgsql as $$
begin
  if not public.is_admin() then
    raise exception 'SETTINGS_ARE_ADMIN_ONLY';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_system_settings_security on public.system_settings;
create trigger trg_system_settings_security
before insert or update or delete on public.system_settings
for each row execute function public.prevent_system_settings_self_modification();

create or replace function public.get_setting_bool(p_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select value = 'true'::jsonb
       from public.system_settings
      where key = p_key),
    false
  );
$$;

create table if not exists public.appeal_cases (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null,
  photo_path text not null,
  description text not null,
  phone text,
  email text,
  status text not null default 'PENDING',
  created_at timestamptz not null default now()
);

\ir /tmp/20260924000003_captcha_challenges.sql
select set_config('test.is_admin', 'on', false);

create or replace function run_captcha_tests()
returns void
language plpgsql
as $$
declare
  v_pass int := 0;
  v_fail int := 0;
  v_challenge record;
  v_result record;
  v_id uuid;
  v_answer text;
  v_case uuid;
begin
  -- The seed must have restored the admin-only settings trigger.
  if not exists (
    select 1
      from pg_trigger
     where tgname = 'trg_system_settings_security'
       and tgenabled = 'O'
  ) then
    v_fail := v_fail + 1;
    raise notice 'FAIL migration left settings trigger disabled';
  else
    v_pass := v_pass + 1;
    raise notice 'ok   T0 migration restores settings trigger';
  end if;

  -- T1: request returns a usable public question but never the answer.
  select * into v_challenge from public.request_captcha();
  if v_challenge.captcha_id is not null
     and v_challenge.question like 'I am not a robot — solve:%' then
    v_pass := v_pass + 1;
    raise notice 'ok   T1 request returns id + public question';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T1 request id=% question=%',
      v_challenge.captcha_id, v_challenge.question;
  end if;

  select answer into v_answer
    from public.captcha_challenges
   where id = v_challenge.captcha_id;
  if v_answer is not null and
     position(v_answer in v_challenge.question) = 0 then
    v_pass := v_pass + 1;
    raise notice 'ok   T2 answer remains server-side';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T2 answer leaked or missing';
  end if;

  -- T3: a wrong answer burns the challenge.
  select * into v_result
    from public.verify_captcha(v_challenge.captcha_id, 'definitely-wrong');
  if not v_result.ok and v_result.error = 'WRONG_ANSWER'
     and not public.captcha_ok(v_challenge.captcha_id) then
    v_pass := v_pass + 1;
    raise notice 'ok   T3 wrong answer burns challenge';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T3 wrong answer ok=% error=%',
      v_result.ok, v_result.error;
  end if;

  -- T4: a correct answer is accepted and visible to captcha_ok.
  select * into v_challenge from public.request_captcha();
  select answer into v_answer
    from public.captcha_challenges
   where id = v_challenge.captcha_id;
  select * into v_result
    from public.verify_captcha(v_challenge.captcha_id, '  ' || v_answer || '  ');
  if v_result.ok and v_result.error is null
     and public.captcha_ok(v_challenge.captcha_id) then
    v_pass := v_pass + 1;
    raise notice 'ok   T4 correct answer verifies';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T4 correct answer ok=% error=%',
      v_result.ok, v_result.error;
  end if;

  -- T5: a solved but expired challenge is rejected.
  update public.captcha_challenges
     set expires_at = now() - interval '1 second'
   where id = v_challenge.captcha_id;
  if not public.captcha_ok(v_challenge.captcha_id) then
    v_pass := v_pass + 1;
    raise notice 'ok   T5 expired challenge rejected';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T5 expired challenge accepted';
  end if;

  -- T6: enforcement defaults on and rejects an appeal with no CAPTCHA.
  if public.captcha_required() then
    begin
      insert into public.appeal_cases
        (user_id, photo_path, description)
      values
        ('00000000-0000-0000-0000-000000000001', 'appeals/test.jpg', 'no captcha');
      v_fail := v_fail + 1;
      raise notice 'FAIL T6 missing captcha was accepted';
    exception when others then
      if sqlerrm = 'CAPTCHA_REQUIRED' then
        v_pass := v_pass + 1;
        raise notice 'ok   T6 missing captcha rejected';
      else
        v_fail := v_fail + 1;
        raise notice 'FAIL T6 wrong error: %', sqlerrm;
      end if;
    end;
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T6 enforcement did not default on';
  end if;

  -- T7: a solved challenge permits the insert and its id is not persisted.
  select * into v_challenge from public.request_captcha();
  select answer into v_answer
    from public.captcha_challenges
   where id = v_challenge.captcha_id;
  perform public.verify_captcha(v_challenge.captcha_id, v_answer);
  insert into public.appeal_cases
    (user_id, photo_path, description, captcha_id)
  values
    ('00000000-0000-0000-0000-000000000001', 'appeals/test.jpg',
     'solved captcha', v_challenge.captcha_id)
  returning id into v_case;
  if v_case is not null and not exists (
    select 1 from public.appeal_cases
     where id = v_case and captcha_id is not null
  ) then
    v_pass := v_pass + 1;
    raise notice 'ok   T7 solved captcha accepted and id nulled';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T7 valid appeal insert/captcha nulling';
  end if;

  -- T8: the owner can disable enforcement without a function redeploy.
  update public.system_settings
     set value = 'false'::jsonb
   where key = 'captcha_enforced';
  if not public.captcha_required() then
    insert into public.appeal_cases
      (user_id, photo_path, description)
    values
      ('00000000-0000-0000-0000-000000000001', 'appeals/test.jpg', 'toggle off');
    v_pass := v_pass + 1;
    raise notice 'ok   T8 enforcement toggle permits insert';
  else
    v_fail := v_fail + 1;
    raise notice 'FAIL T8 enforcement toggle did not disable gate';
  end if;

  -- T9: an unsolved id cannot bypass the enabled trigger.
  update public.system_settings
     set value = 'true'::jsonb
   where key = 'captcha_enforced';
  select * into v_challenge from public.request_captcha();
  begin
    insert into public.appeal_cases
      (user_id, photo_path, description, captcha_id)
    values
      ('00000000-0000-0000-0000-000000000001', 'appeals/test.jpg',
       'unsolved captcha', v_challenge.captcha_id);
    v_fail := v_fail + 1;
    raise notice 'FAIL T9 unsolved captcha accepted';
  exception when others then
    if sqlerrm = 'CAPTCHA_REQUIRED' then
      v_pass := v_pass + 1;
      raise notice 'ok   T9 unsolved captcha rejected';
    else
      v_fail := v_fail + 1;
      raise notice 'FAIL T9 wrong error: %', sqlerrm;
    end if;
  end;

  raise notice 'RESULT: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then
    raise exception 'CAPTCHA TESTS FAILED';
  end if;
end;
$$;

select run_captcha_tests();
