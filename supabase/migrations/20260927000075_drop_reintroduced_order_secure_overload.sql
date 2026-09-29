-- 20260927000075 — drop the create_order_secure overload 74 brought back
--
-- WHY THIS EXISTS
-- ---------------
-- 20260927000074 restated create_order_secure() in two signatures: the
-- nine-argument form that does the work, and the six-argument form that
-- delegates to it. The six-argument one was written on the assumption --
-- copied forward from 20260927000013's own comment, "the 6-argument
-- overload still exists in the live database" -- that it still existed.
--
-- It did not. 20260927000049 dropped it, and correctly so: its whole point
-- is that a signature which has been superseded must not stay beside its
-- replacement. Two functions with the same name whose parameter names are
-- a strict subset make every call whose argument names fit BOTH fail with
-- 42725 "function is not unique" -- and which callers are hit depends only
-- on which optional parameters they happen to send, so it is invisible to a
-- reviewer and to a compiler. Connectivity CI caught it on the deploy of
-- 74, in the group "no function is shadowed by a superseded overload".
--
-- The short form keeps working without it. The last three parameters of the
-- nine-argument form have defaults, so a call sending six named arguments
-- resolves to that one function. Nothing calls the six-argument form: the
-- order-create Edge Function sends all nine, and it is the only caller.
--
-- So this migration drops the pair, rather than the function. Then it
-- restates assert_availability_gate_is_wired(), whose first version
-- REQUIRED the six-argument form to be present -- an assertion written
-- against the same wrong assumption, which would have failed the moment the
-- drop was right. The restated version asserts the opposite, and better
-- property: create_order_secure has exactly ONE live signature, and it is
-- the nine-argument one. That way the next person who tries to "keep the
-- overload in sync" gets a CI failure on the deploy instead of a 42725 in
-- production.
--
-- Nothing else changes. The nine-argument body is the one 74 wrote, and
-- 74's version stays as the live definition -- this file does not restate
-- it, only drops its neighbour.

drop function if exists public.create_order_secure(
  uuid, uuid, jsonb, numeric, text, text
);

-- PostgREST caches the function signatures it resolves calls against, so
-- without this a caller can keep getting 42725 from the cache after the
-- drop -- the exact failure 49 had to handle the same way.
notify pgrst, 'reload schema';

-- ===========================================================================
-- The restated assertion
-- ===========================================================================
create or replace function public.assert_availability_gate_is_wired()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_problem text[] := '{}';
  v_exists boolean;
  v_default text;
  v_nullable text;
  v_src text;
  v_err text;
  v_raised text;
  v_flagged int := 0;
  v_gated_orders int := 0;
  v_id uuid;
  v_status text;
  v_signatures int := 0;
begin
  -- ── 1. Both columns exist, are NOT NULL, and default to false ──
  -- The default is the whole backwards-compatibility argument: a
  -- default of true would gate every existing listing the moment
  -- this deploys, which is the opposite of the requirement that
  -- nothing currently working changes behaviour.
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'requires_availability_confirmation'
  ) into v_exists;
  if not v_exists then
    v_problem := array_append(v_problem,
      'products.requires_availability_confirmation is missing, so a provider cannot opt a listing in and the gate can never open');
  else
    select column_default, is_nullable into v_default, v_nullable
      from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'requires_availability_confirmation';
    if v_default is distinct from 'false' then
      v_problem := array_append(v_problem,
        'products.requires_availability_confirmation defaults to ' || coalesce(v_default, 'NULL') || ', not false -- every existing listing would be gated the moment this deploys');
    end if;
    if v_nullable = 'YES' then
      v_problem := array_append(v_problem,
        'products.requires_availability_confirmation is nullable, so a listing can silently fall back to not-gated');
    end if;
  end if;

  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'orders'
       and column_name = 'requires_availability_confirmation'
  ) into v_exists;
  if not v_exists then
    v_problem := array_append(v_problem,
      'orders.requires_availability_confirmation is missing, so the per-order snapshot is not taken and checkout has nothing to gate on');
  else
    select column_default, is_nullable into v_default, v_nullable
      from information_schema.columns
     where table_schema = 'public' and table_name = 'orders'
       and column_name = 'requires_availability_confirmation';
    if v_default is distinct from 'false' then
      v_problem := array_append(v_problem,
        'orders.requires_availability_confirmation defaults to ' || coalesce(v_default, 'NULL') || ', not false -- every in-flight order would suddenly be gated');
    end if;
    if v_nullable = 'YES' then
      v_problem := array_append(v_problem,
        'orders.requires_availability_confirmation is nullable, so an order with no snapshot reads as not-gated');
    end if;
  end if;

  -- ── 2. create_order_secure has exactly one live signature, and it
  --       reads and writes the snapshot ──
  --
  -- "Exactly one" is the check, not a count of two. A shorter sibling
  -- whose parameter names are a subset makes every call that fits both
  -- fail with 42725, and 20260927000074 shipped exactly that before
  -- 20260927000075 dropped it. Requiring the one form is what stops it
  -- being re-added to "keep the overload in sync".
  select count(*) into v_signatures
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_order_secure';

  if v_signatures <> 1 then
    v_problem := array_append(v_problem,
      'create_order_secure has ' || v_signatures || ' live signatures, expected 1. A second one whose parameter names are a subset of the nine-argument form makes any call that fits both fail with 42725 "is not unique"');
  end if;

  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_order_secure'
   order by p.pronargs desc
   limit 1;
  v_src := regexp_replace(lower(coalesce(v_src, '')), E'\\s+', ' ', 'g');
  if position('requires_availability_confirmation' in v_src) = 0 then
    v_problem := array_append(v_problem,
      'create_order_secure() does not read or write orders.requires_availability_confirmation, so every order is created ungated no matter what the product flag says');
  end if;

  -- ── 3. release_order_contact still refuses below APPROVED ──
  -- Proved by calling it, not by reading its source: the point is
  -- that the gate bites, and a source-pattern check cannot tell a
  -- guard from a comment.
  begin
    perform * from public.release_order_contact(
      '00000000-0000-0000-0000-000000000000'::uuid);
    v_raised := null;
  exception when others then
    v_raised := sqlerrm;
  end;
  if v_raised is null or position('ORDER_NOT_FOUND' in v_raised) = 0 then
    v_problem := array_append(v_problem,
      'release_order_contact() did not raise ORDER_NOT_FOUND for a missing order (got: ' || coalesce(v_raised, 'no error') || '), so the function is not the escrow gate any more');
  end if;

  -- Find any real order that is NOT past approval, and prove the call
  -- is refused. Skipped when every order is already approved, so a
  -- fresh deployment is not reported as broken.
  select id, status::text into v_id, v_status
    from public.orders
   where status not in ('APPROVED','STARTED','COMPLETED')
   order by created_at desc
   limit 1;

  if v_id is not null then
    v_raised := null;
    begin
      -- Called as anon, which has no session at all. It must be refused:
      -- NOT_ORDER_OWNER is the refusal that fires (the NULL-uid guard
      -- comes first), and that is the correct outcome -- the status gate
      -- behind it is checked separately below, because a session-less
      -- caller never reaches it.
      perform * from public.release_order_contact(v_id);
    exception when others then
      v_raised := sqlerrm;
    end;
    if v_raised is null then
      v_problem := array_append(v_problem,
        'release_order_contact() returned a contact for an order in ' || coalesce(v_status, '?') || ' to a caller with no session, so contact is not gated on payment being verified');
    end if;
  end if;

  -- Source-level check of the status list, because the CALL above
  -- cannot reach the status branch as anon (it stops at the ownership
  -- check first). This is the pair that covers the gate from both
  -- sides: the call proves the function runs, the text proves the
  -- branch is the one that exists.
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'release_order_contact'
   order by p.pronargs desc
   limit 1;
  v_src := regexp_replace(lower(coalesce(v_src, '')), E'\\s+', ' ', 'g');
  if position('contact_available_after_approval' in v_src) = 0 then
    v_problem := array_append(v_problem,
      'release_order_contact() no longer raises CONTACT_AVAILABLE_AFTER_APPROVAL, so the escrow gate on contact has been removed');
  end if;
  foreach v_err in array array['approved', 'started', 'completed'] loop
    if position(v_err in v_src) = 0 then
      v_problem := array_append(v_problem,
        'release_order_contact() no longer names ' || v_err || ' as a released status');
    end if;
  end loop;

  -- ── 4. Report what is actually gated, as evidence ──
  -- Not a failure condition: the number is expected to be 0 on the
  -- deploy that introduces the flag, because no listing has opted in
  -- yet. It is printed so a later run shows the gate is in use and not
  -- just present.
  select count(*) into v_flagged
    from public.products where requires_availability_confirmation;
  select count(*) into v_gated_orders
    from public.orders where requires_availability_confirmation;

  if cardinality(v_problem) > 0 then
    return concat('AVAILABILITY_GATE_NOT_WIRED: ', array_to_string(v_problem, '; '));
  end if;

  return format(
    'availability gate wired: products requiring confirmation=%s, gated orders=%s, both default false; create_order_secure snapshots it (1 signature); release_order_contact refuses below APPROVED',
    v_flagged, v_gated_orders);
end;
$$;

comment on function public.assert_availability_gate_is_wired() is
  'Behavioural: checks both availability-confirmation columns exist and default to false, that create_order_secure() has exactly ONE signature and that it snapshots the flag, and that release_order_contact() actually refuses to hand out a contact below APPROVED. Restated by migration 75, which replaced 74''s requirement that a six-argument overload exist with the requirement that it does not. Returns a diagnostic string; never raises.';

grant execute on function public.assert_availability_gate_is_wired()
  to anon, authenticated, service_role;
