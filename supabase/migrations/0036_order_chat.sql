-- 0036_order_chat.sql
--
-- Minimal in-order chat between buyer and provider, plus location sharing
-- that respects the existing escrow reveal rules.
--
-- Design notes:
--  * New table only — orders and all fee/escrow logic are untouched.
--  * TEXT messages are available as soon as the order exists so the two
--    sides can coordinate ("is my order ready?"). They carry no location
--    or contact data, so nothing escrow-protected is exposed early.
--  * LOCATION messages are gated to the exact same reveal statuses as the
--    existing buyer GPS share (set_order_delivery_location in migration
--    0032): payment verified (APPROVED) or delivery in progress (STARTED).
--    The gate is enforced server-side in a BEFORE INSERT trigger, so a
--    modified client cannot pre-share.
--  * Messages are immutable: no UPDATE/DELETE policies exist.
--  * The table is added to the supabase_realtime publication so clients
--    can stream new messages with supabase_flutter's .stream().

create table if not exists order_messages (
  id uuid primary key default uuid_generate_v4(),
  order_id uuid not null references orders(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'TEXT' check (kind in ('TEXT', 'LOCATION')),
  body text,
  location geography(Point, 4326),
  location_label text,
  created_at timestamptz not null default now(),
  constraint chk_chat_content check (
    (kind = 'TEXT' and body is not null and length(btrim(body)) > 0)
    or (kind = 'LOCATION' and location is not null)
  )
);

create index if not exists idx_order_messages_order
  on order_messages(order_id, created_at);

alter table order_messages enable row level security;

-- Participants can read the conversation; admins can moderate.
create policy order_messages_participant_read on order_messages
  for select using (
    exists (
      select 1 from orders o
      where o.id = order_id
        and (o.user_id = auth.uid() or owns_provider_profile(o.provider_id))
    )
    or is_admin()
  );

-- Only participants can send, and only as themselves.
create policy order_messages_participant_insert on order_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from orders o
      where o.id = order_id
        and (o.user_id = auth.uid() or owns_provider_profile(o.provider_id))
    )
  );

-- Server-side escrow gate: LOCATION messages only after payment is
-- verified (APPROVED) or delivery is in progress (STARTED) — identical to
-- the buyer GPS share gate from migration 0032.
create or replace function enforce_order_chat_location_gate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_participant boolean;
begin
  if new.kind = 'LOCATION' then
    select o.status::text into v_status
    from orders o where o.id = new.order_id;
    if v_status is null then
      raise exception 'ORDER_NOT_FOUND';
    end if;
    if v_status not in ('APPROVED', 'STARTED') then
      raise exception 'LOCATION_NOT_REVEALED';
    end if;
  end if;

  -- Defense in depth: the RLS insert policy already restricts senders to
  -- participants; re-verify here so the gate holds even if policies change.
  select exists (
    select 1 from orders o
    where o.id = new.order_id
      and (o.user_id = new.sender_id or owns_provider_profile(o.provider_id))
  ) into v_participant;
  if not v_participant then
    raise exception 'NOT_YOUR_ORDER';
  end if;

  return new;
end;
$$;

create trigger trg_order_chat_location_gate
  before insert on order_messages
  for each row execute function enforce_order_chat_location_gate();

-- Enable realtime streaming for the chat UI.
do $$
begin
  begin
    alter publication supabase_realtime add table order_messages;
  exception when duplicate_object then null; -- already in publication
  when undefined_object then null; -- publication not present on this project
  end;
end $$;
