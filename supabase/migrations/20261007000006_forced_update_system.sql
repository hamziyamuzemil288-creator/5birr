-- =============================================================================
-- 20261007000006_forced_update_system.sql
--
-- ITEM I: the forced-update system.
--
--   * app_release_config — one row per platform (android, ios) carrying the
--     latest build, the MINIMUM build the platform still accepts, the store
--     URL/package id, the message in EN/Amharic/Oromo, and the force switch.
--   * app_release_config_for()    — the read the client makes on cold start,
--     on resume and periodically. Granted to anon as well as authenticated,
--     because the update gate shows OVER the login screen: a build too old to
--     sign in must be told to update, not shown a login form that will fail.
--   * client_build_status()       — 'OK' | 'UPDATE_RECOMMENDED' | 'UPDATE_REQUIRED'.
--   * assert_client_build_is_supported() — the guard the order, ride, post and
--     payment writes call. Raises APP_UPDATE_REQUIRED below the minimum.
--   * admin_save_app_release()    — the admin write. Enabling force REQUIRES
--     the explicit confirmation flag, so a build cannot be forced past users
--     without the admin saying it is live on the store.
--   * admin_notify_all_users_of_release() — in-app notification for everyone
--     plus ONE batched, throttled push event carrying the store link, once per
--     release, returning a delivered count.
--   * assert_app_version_gate_is_wired() — the live assertion.
--
-- BEHAVIOUR ON DEPLOY IS "NOBODY IS BLOCKED"
-- -----------------------------------------
-- The seed sets min_required_build = latest_build = 106 (the build in
-- pubspec.yaml today) and force_enabled = false. So the instant this migration
-- lands: no client is below the minimum, the recommended prompt is silent, and
-- every write path accepts every existing build. Only an admin raising the
-- minimum can change that, and the force switch additionally requires the
-- "this build is 100% live on Play Store" confirmation.
--
-- FAIL OPEN ON THE CLIENT, FAIL CLOSED ON THE WRITE
-- -------------------------------------------------
-- The read is public and returns defaults when no row exists, so a network
-- error or a missing row degrades to "no update required" — the client keeps
-- working. The WRITE guard is the opposite: a write that cannot prove its
-- build is acceptable is rejected, because a write from a build the platform
-- no longer supports is exactly what the minimum exists to stop.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The table
-- -----------------------------------------------------------------------------
create table if not exists public.app_release_config (
  platform            text primary key
                        check (platform in ('android', 'ios')),

  -- The newest build that exists on the store.
  latest_build        integer not null default 1 check (latest_build >= 1),

  -- The oldest build the platform still accepts. A client below this is
  -- gated (when force_enabled) and its writes are rejected.
  min_required_build  integer not null default 1 check (min_required_build >= 1),

  -- Where "Update" sends the user, and the package it belongs to.
  store_url           text,
  package_id          text,

  -- The message, per locale. Amharic and Oromo fall back to EN when empty.
  message_en          text not null default 'A new version of Aliob is available.',
  message_am          text,
  message_om          text,

  -- The switch. Off means "prompt, never block": still gated by nothing.
  force_enabled       boolean not null default false,

  -- Notification bookkeeping. notify_release_key is the (min, latest) pair the
  -- last blast was sent for, so "once per release" is a value comparison and
  -- cannot be re-sent by a double tap.
  notify_release_key  text,
  notify_last_sent_at timestamptz,
  notify_delivered    integer not null default 0,

  updated_by          uuid,
  updated_at          timestamptz not null default now(),

  -- A minimum above the latest build would gate every client forever with no
  -- version to update to. Refuse it at the table, not in the UI.
  constraint app_release_min_le_latest
    check (min_required_build <= latest_build)
);

comment on table public.app_release_config is
  'Per-platform release policy: the latest build, the minimum still accepted, '
  'the store link, the per-locale message and the force switch. Read by every '
  'client (including signed-out ones) so the update gate can cover login.';

-- -----------------------------------------------------------------------------
-- 2. The seed — nothing is blocked by deploying this
-- -----------------------------------------------------------------------------
-- min = latest = 106 = the build in pubspec.yaml, force off. An admin can
-- raise the minimum later; deploying changes nothing for anyone today.
insert into public.app_release_config
  (platform, latest_build, min_required_build, store_url, package_id,
   message_en, message_am, message_om, force_enabled)
values
  ('android', 106, 106,
   'https://play.google.com/store/apps/details?id=com.amistbirr.myapp',
   'com.amistbirr.myapp',
   'A new version of Aliob is required to keep using the app. It takes a minute and keeps your data.',
   'የAliob አዲስ ስሪት መጫን ያስፈልጋል። አንድ ደቂቃ ብቻ ይወስዳል፤ ውሂብዎ አይጠፋም።',
   'Aliob versiyoon haaraa fe''uun barbaachisa. Daqiiqaa tokko qofa fudhata; odeeffannoon kee hin bade.',
   false),
  ('ios', 106, 106,
   'https://apps.apple.com/app/id000000000',
   'com.amistbirr.myapp',
   'A new version of Aliob is required to keep using the app. It takes a minute and keeps your data.',
   null, null, false)
on conflict (platform) do nothing;

-- -----------------------------------------------------------------------------
-- 3. RLS — readable by anyone, writable by nobody but the admin RPC
-- -----------------------------------------------------------------------------
alter table public.app_release_config enable row level security;

-- The gate must render before sign-in, so SELECT is granted to anon too. The
-- row holds no personal data: a build number, a store URL and a sentence.
drop policy if exists app_release_config_read_all on public.app_release_config;
create policy app_release_config_read_all on public.app_release_config
  for select to anon, authenticated using (true);

-- No insert/update/delete policy for anon or authenticated: writes go through
-- admin_save_app_release(), which is gated on is_admin(). A client that cannot
-- write cannot quietly force an update on everyone.
revoke all on public.app_release_config from anon, authenticated;
grant select on public.app_release_config to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. The read the client makes
-- -----------------------------------------------------------------------------
-- Returns jsonb and NEVER raises: an unreadable row, an unknown platform or a
-- planted bad value all resolve to the fail-open default ("OK"), because a
-- client that cannot read the policy must not gate itself.
create or replace function public.app_release_config_for(p_platform text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_platform text := lower(btrim(coalesce(p_platform, 'android')));
  v_row public.app_release_config;
begin
  if v_platform not in ('android', 'ios') then
    v_platform := 'android';
  end if;

  select * into v_row from public.app_release_config where platform = v_platform;

  if v_row.platform is null then
    -- No row: the policy is "nothing to do". Defaults keep the client open.
    return jsonb_build_object(
      'platform', v_platform,
      'latest_build', 0,
      'min_required_build', 0,
      'force_enabled', false,
      'store_url', null,
      'package_id', null,
      'message_en', 'A new version of Aliob is available.',
      'message_am', null,
      'message_om', null
    );
  end if;

  return jsonb_build_object(
    'platform', v_row.platform,
    'latest_build', v_row.latest_build,
    'min_required_build', v_row.min_required_build,
    'force_enabled', v_row.force_enabled,
    'store_url', v_row.store_url,
    'package_id', v_row.package_id,
    'message_en', v_row.message_en,
    'message_am', v_row.message_am,
    'message_om', v_row.message_om
  );
end;
$$;

comment on function public.app_release_config_for(text) is
  'The release policy for a platform, as jsonb, never raising. The client '
  'caches this and fails OPEN: an unreadable policy means "no update".';

revoke all on function public.app_release_config_for(text) from public;
grant execute on function public.app_release_config_for(text)
  to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. The verdict, and the guard the writes call
-- -----------------------------------------------------------------------------
create or replace function public.client_build_status(
  p_platform text,
  p_build integer
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb := public.app_release_config_for(p_platform);
  v_min int := coalesce((v ->> 'min_required_build')::int, 0);
  v_latest int := coalesce((v ->> 'latest_build')::int, 0);
  v_force boolean := coalesce((v ->> 'force_enabled')::boolean, false);
  v_build integer := coalesce(p_build, 0);
begin
  if v_build < v_min and v_force then
    return 'UPDATE_REQUIRED';
  end if;
  if v_build < v_latest then
    return 'UPDATE_RECOMMENDED';
  end if;
  return 'OK';
end;
$$;

comment on function public.client_build_status(text, integer) is
  'OK | UPDATE_RECOMMENDED | UPDATE_REQUIRED for a platform and build. '
  'UPDATE_REQUIRED only when the build is below the minimum AND force is on.';

-- The client never has to change an RPC signature to be gated. PostgREST
-- exposes the request headers to SQL, so the app sets two global headers on
-- the Supabase client (x-client-platform, x-client-build) and every guarded
-- write reads them here. An old client that sends no header reads as build 0,
-- which is below every real minimum — omitting the header is not a bypass.
create or replace function public.client_build_from_request()
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_headers jsonb;
begin
  begin
    v_headers := coalesce(current_setting('request.headers', true), '{}')::jsonb;
  exception when others then
    return 0;
  end;
  return coalesce(nullif(btrim(coalesce(v_headers ->> 'x-client-build', '')), '')::int, 0);
end;
$$;

create or replace function public.client_platform_from_request()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_headers jsonb;
  v_platform text;
begin
  begin
    v_headers := coalesce(current_setting('request.headers', true), '{}')::jsonb;
  exception when others then
    return 'android';
  end;
  v_platform := lower(btrim(coalesce(v_headers ->> 'x-client-platform', '')));
  if v_platform not in ('android', 'ios') then
    return 'android';
  end if;
  return v_platform;
end;
$$;

comment on function public.client_build_from_request() is
  'The build number the calling client declared in the x-client-build header, '
  'or 0 when it declared none. Read by the write gate so no RPC signature had '
  'to change to become gated.';

revoke all on function public.client_build_from_request() from public, anon;
grant execute on function public.client_build_from_request()
  to authenticated, service_role;

revoke all on function public.client_platform_from_request() from public, anon;
grant execute on function public.client_platform_from_request()
  to authenticated, service_role;

create or replace function public.assert_client_build_is_supported(
  p_platform text,
  p_build integer
)
returns void
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v jsonb := public.app_release_config_for(p_platform);
  v_min int := coalesce((v ->> 'min_required_build')::int, 0);
  v_force boolean := coalesce((v ->> 'force_enabled')::boolean, false);
begin
  -- A server-side write (an admin action, a scheduled job, an n8n callback) is
  -- not a client with a version: it has already been authorised through its
  -- own path and must never be blocked by a mobile release policy.
  if public.is_server_write() then
    return;
  end if;

  -- A null build is an old client that does not send one: treat it as 0, which
  -- is below every real minimum, so an outdated client cannot bypass the gate
  -- by omitting the header. When force is off nothing is rejected at all.
  if v_force and coalesce(p_build, 0) < v_min then
    raise exception 'APP_UPDATE_REQUIRED';
  end if;
end;
$$;

comment on function public.assert_client_build_is_supported(text, integer) is
  'The guard every order, ride, post and payment write calls. Raises '
  'APP_UPDATE_REQUIRED when force is on and the build is below the minimum; '
  'a null build counts as 0, so an old client cannot bypass it by omission.';

revoke all on function public.client_build_status(text, integer) from public;
grant execute on function public.client_build_status(text, integer)
  to anon, authenticated, service_role;

revoke all on function public.assert_client_build_is_supported(text, integer)
  from public, anon;
grant execute on function public.assert_client_build_is_supported(text, integer)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5b. The gate, wired as a trigger on every guarded write
-- -----------------------------------------------------------------------------
-- Chosen over editing four large RPC bodies: a BEFORE INSERT trigger on the
-- four tables a client writes through is enforced no matter which function
-- (or future function) performs the insert, cannot be bypassed by a code path
-- that forgets the guard, and keeps the diff small enough to review. The four:
--   orders                  — every order/payment a buyer places
--   ride_requests           — every ride request
--   products                — every provider listing
--   wallet_recharge_requests — every payment the provider initiates
create or replace function public.trg_assert_client_build_supported()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.assert_client_build_is_supported(
    public.client_platform_from_request(),
    public.client_build_from_request()
  );
  return new;
end;
$$;

comment on function public.trg_assert_client_build_supported() is
  'BEFORE INSERT gate: rejects a write from a build below the minimum when '
  'the admin has turned force on. Server-side writes pass through.';

do $$
declare
  t text;
begin
  foreach t in array array['orders', 'ride_requests', 'products', 'wallet_recharge_requests']
  loop
    execute format('drop trigger if exists %I on public.%I',
                   t || '_client_build_gate', t);
    execute format(
      'create trigger %I before insert on public.%I '
      'for each row execute function public.trg_assert_client_build_supported()',
      t || '_client_build_gate', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. The admin write — force needs the confirmation
-- -----------------------------------------------------------------------------
create or replace function public.admin_save_app_release(
  p_platform text,
  p_latest_build integer,
  p_min_required_build integer,
  p_store_url text default null,
  p_package_id text default null,
  p_message_en text default null,
  p_message_am text default null,
  p_message_om text default null,
  p_force_enabled boolean default false,
  p_confirm_force boolean default false
)
returns public.app_release_config
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_platform text := lower(btrim(coalesce(p_platform, 'android')));
  v_row public.app_release_config;
begin
  if not public.is_admin() then
    raise exception 'INSUFFICIENT_PERMISSION';
  end if;

  if v_platform not in ('android', 'ios') then
    raise exception 'PLATFORM_MUST_BE_ANDROID_OR_IOS';
  end if;

  if p_latest_build is null or p_latest_build < 1 then
    raise exception 'LATEST_BUILD_MUST_BE_A_POSITIVE_NUMBER';
  end if;
  if p_min_required_build is null or p_min_required_build < 1 then
    raise exception 'MIN_REQUIRED_BUILD_MUST_BE_A_POSITIVE_NUMBER';
  end if;
  if p_min_required_build > p_latest_build then
    raise exception 'MIN_REQUIRED_BUILD_CANNOT_EXCEED_LATEST_BUILD';
  end if;

  -- The confirmation is enforced HERE, not only in the checkbox. Turning force
  -- on past a build that is not really live on the store locks users out of an
  -- app they cannot update, so the server refuses an unconfirmed force rather
  -- than trusting the client to have asked.
  if p_force_enabled and not p_confirm_force then
    raise exception 'FORCE_REQUIRES_THE_STORE_CONFIRMATION';
  end if;

  insert into public.app_release_config (
    platform, latest_build, min_required_build, store_url, package_id,
    message_en, message_am, message_om, force_enabled, updated_by, updated_at
  ) values (
    v_platform, p_latest_build, p_min_required_build,
    nullif(btrim(coalesce(p_store_url, '')), ''),
    nullif(btrim(coalesce(p_package_id, '')), ''),
    coalesce(nullif(btrim(coalesce(p_message_en, '')), ''),
             'A new version of Aliob is available.'),
    nullif(btrim(coalesce(p_message_am, '')), ''),
    nullif(btrim(coalesce(p_message_om, '')), ''),
    coalesce(p_force_enabled, false),
    auth.uid(), now()
  )
  on conflict (platform) do update set
    latest_build = excluded.latest_build,
    min_required_build = excluded.min_required_build,
    store_url = excluded.store_url,
    package_id = excluded.package_id,
    message_en = excluded.message_en,
    message_am = excluded.message_am,
    message_om = excluded.message_om,
    force_enabled = excluded.force_enabled,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning * into v_row;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (auth.uid(), 'APP_RELEASE_SAVED', 'app_release_config', null,
          jsonb_build_object(
            'platform', v_platform,
            'latest_build', p_latest_build,
            'min_required_build', p_min_required_build,
            'force_enabled', coalesce(p_force_enabled, false),
            'force_confirmed', coalesce(p_confirm_force, false)
          ));

  return v_row;
end;
$$;

comment on function public.admin_save_app_release(text, integer, integer, text, text, text, text, text, boolean, boolean) is
  'Admin write for app_release_config. Requires is_admin(); refuses '
  'min_required_build > latest_build; and refuses to enable force without '
  'p_confirm_force ("this build is 100% live on Play Store").';

revoke all on function public.admin_save_app_release(text, integer, integer, text, text, text, text, text, boolean, boolean)
  from public, anon;
grant execute on function public.admin_save_app_release(text, integer, integer, text, text, text, text, text, boolean, boolean)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. Notify all users — in-app + ONE batched, throttled push, once per release
-- -----------------------------------------------------------------------------
create or replace function public.admin_notify_all_users_of_release(
  p_platform text,
  p_batch_size integer default 500
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_platform text := lower(btrim(coalesce(p_platform, 'android')));
  v_row public.app_release_config;
  v_key text;
  v_message text;
  v_link text;
  v_inserted int := 0;
  v_tokens int := 0;
  v_event public.n8n_events;
  v_batch int := greatest(1, least(coalesce(p_batch_size, 500), 5000));
  v_already boolean := false;
begin
  if not public.is_admin() then
    raise exception 'INSUFFICIENT_PERMISSION';
  end if;

  select * into v_row from public.app_release_config where platform = v_platform;
  if v_row.platform is null then
    raise exception 'NO_RELEASE_CONFIGURED_FOR_PLATFORM';
  end if;

  -- The identity of "this release". Both numbers, so changing either one is a
  -- new release and re-sending is intended; sending twice for the SAME pair is
  -- not, and is refused here rather than in the button's disabled state.
  v_key := v_row.min_required_build::text || ':' || v_row.latest_build::text;
  if v_row.notify_release_key = v_key and v_row.notify_last_sent_at is not null then
    return jsonb_build_object(
      'already_notified', true,
      'release_key', v_key,
      'delivered', v_row.notify_delivered
    );
  end if;

  v_message := coalesce(nullif(btrim(coalesce(v_row.message_en, '')), ''),
                       'A new version of Aliob is available.');
  v_link := v_row.store_url;

  -- 1. The in-app notification, for every user who has not already had this
  --    release's notice. data->>'release_key' is the dedupe key, so a re-run
  --    cannot double-notify even if the throttle above is bypassed.
  with targets as (
    select u.id
      from auth.users u
     where not exists (
       select 1 from public.notifications n
        where n.user_id = u.id
          and n.data ->> 'release_key' = v_key
     )
     limit v_batch
  ), ins as (
    insert into public.notifications (user_id, type, title, body, data)
    select t.id, 'ADMIN_MESSAGE'::public.notification_type,
           'Update Aliob',
           v_message,
           jsonb_build_object('release_key', v_key, 'store_url', v_link,
                              'kind', 'APP_UPDATE')
      from targets t
    returning 1
  )
  select count(*) into v_inserted from ins;

  -- 2. The push, in ONE event. Batching is the point: a thousand users is one
  --    orchestration call carrying the tokens, not a thousand calls.
  select count(*) into v_tokens
    from public.fcm_tokens
   where coalesce(is_active, true) = true;

  select * into v_event from public.create_n8n_event(
    p_event_type => 'APP_UPDATE_PUSH',
    p_entity_type => 'app_release_config',
    p_entity_id => null,
    p_payload => jsonb_build_object(
      'platform', v_platform,
      'release_key', v_key,
      'latest_build', v_row.latest_build,
      'min_required_build', v_row.min_required_build,
      'store_url', v_link,
      'package_id', v_row.package_id,
      'title', 'Update Aliob',
      'body', v_message,
      'batched', true,
      'batch_size', v_batch,
      'token_count', v_tokens
    )
  );

  update public.app_release_config
     set notify_release_key = v_key,
         notify_last_sent_at = now(),
         notify_delivered = notify_delivered + v_inserted,
         updated_at = now()
   where platform = v_platform;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (auth.uid(), 'APP_RELEASE_NOTIFY_ALL', 'app_release_config', null,
          jsonb_build_object('platform', v_platform, 'release_key', v_key,
                             'delivered', v_inserted, 'token_count', v_tokens,
                             'n8n_event_id', v_event.id));

  return jsonb_build_object(
    'already_notified', v_already,
    'release_key', v_key,
    'delivered', v_inserted,
    'token_count', v_tokens,
    'n8n_event_id', v_event.id
  );
end;
$$;

comment on function public.admin_notify_all_users_of_release(text, integer) is
  'One in-app notification per user plus ONE batched push event carrying the '
  'store link, once per (min, latest) release key. Returns the delivered count.';

revoke all on function public.admin_notify_all_users_of_release(text, integer)
  from public, anon;
grant execute on function public.admin_notify_all_users_of_release(text, integer)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 8. The live assertion
-- -----------------------------------------------------------------------------
create or replace function public.assert_app_version_gate_is_wired()
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_missing text[] := '{}';
  v_min int;
  v_latest int;
  v_force boolean;
  v_status text;
  v_triggers int;
  -- The tables a client writes through that must carry the gate trigger.
  c_tables constant text[] := array[
    'orders',
    'ride_requests',
    'products',
    'wallet_recharge_requests'
  ];
begin
  -- 1. The seed must not block anyone: min <= latest, and force the seed value
  --    the migration shipped with is off unless an admin has since turned it on.
  select min_required_build, latest_build, force_enabled
    into v_min, v_latest, v_force
    from public.app_release_config where platform = 'android';
  if v_min is null then
    v_missing := v_missing || 'no android row in app_release_config';
  elsif v_min > v_latest then
    v_missing := v_missing || 'min_required_build exceeds latest_build';
  end if;

  -- 2. The verdict must agree with the numbers it is derived from.
  if v_min is not null then
    v_status := public.client_build_status('android', v_min);
    if v_force and v_status <> 'OK' then
      v_missing := v_missing || 'client_build_status(android, min) is '
                   || v_status || ', expected OK at the minimum';
    end if;
    if public.client_build_status('android', greatest(v_latest, 1)) <> 'OK' then
      v_missing := v_missing || 'client_build_status(android, latest) is not OK';
    end if;
  end if;

  -- 3. Every guarded table must carry the BEFORE INSERT gate trigger, enabled.
  --    Read from the catalog, not from this file, so it fails on a deployment
  --    where the trigger was never created or has been disabled.
  select count(*) into v_triggers
    from pg_trigger tg
    join pg_class c on c.oid = tg.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and not tg.tgisinternal
     and tg.tgenabled <> 'D'
     and tg.tgname = c.relname || '_client_build_gate'
     and c.relname = any (c_tables);

  if v_triggers < array_length(c_tables, 1) then
    v_missing := v_missing || ('only ' || coalesce(v_triggers, 0) || ' of '
      || array_length(c_tables, 1) || ' guarded tables carry the gate trigger');
  end if;

  if array_length(v_missing, 1) is not null then
    raise exception 'APP_UPDATE_GATE_NOT_WIRED: %', array_to_string(v_missing, '; ');
  end if;

  return true;
end;
$$;

comment on function public.assert_app_version_gate_is_wired() is
  'Fails when the update gate is not wired: a min above latest, a verdict that '
  'disagrees with its numbers, or a guarded table (orders, ride_requests, '
  'products, wallet_recharge_requests) missing its enabled BEFORE INSERT gate '
  'trigger.';

revoke all on function public.assert_app_version_gate_is_wired() from public, anon;
grant execute on function public.assert_app_version_gate_is_wired()
  to authenticated, service_role;
