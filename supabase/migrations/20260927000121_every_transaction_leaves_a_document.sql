-- 20260927000121 — every transaction leaves a document, for both parties
--
-- WHAT WAS MISSING
-- -----------------
-- `order_status_history` and `ride_status_history` are an AUDIT TRAIL: who
-- moved the row, when, from which status to which. They carry no amount, no
-- counterparty, and no reference to anything a person could hold. There is no
-- receipt table in this schema at all — the full list of tables has no
-- `receipts`, `invoices` or `slips` — so a customer who paid ETB 340 and a
-- provider who shipped it both have a notification and nothing else. If either
-- party disputes what happened, or an admin has to reconcile a month of
-- orders, there is nothing to read.
--
-- WHY A TRIGGER ON THE HISTORY TABLES, NOT A RESTATEMENT OF THE TRANSITIONS
-- -------------------------------------------------------------------------
-- Every status change on both subjects already writes exactly one history row,
-- inside the same transaction as the money movement. That is the seam.
-- Restating `transition_order_status` or `transition_ride_status` to add
-- document writes would mean reproducing every branch of both, and 0088 already
-- records the cost of that approach for the ride chain: a branch that goes
-- missing freezes a ride and no fee is ever charged. One AFTER INSERT trigger
-- per history table covers every scenario that exists today — CREATED,
-- ACCEPTED, PAYMENT_*, STARTED, COMPLETED, CANCELLED, DISPUTED, REFUNDED,
-- REQUESTED, CLAIMED, DRIVER_*, and anything a later migration adds — without
-- touching a single transition function.
--
-- WHY THE PARTIES ARE SNAPSHOTTED, NOT JOINED
-- --------------------------------------------
-- A document that reads its parties through a join changes when the parties
-- change, which defeats the purpose: it must say who the customer WAS at the
-- moment of the transaction. Names and phone numbers are copied at issue time.
-- The ids stay as keys, and are detached rather than cascaded (see below).
--
-- WHY THIS FILE NEVER SAYS `auth.users`
-- ------------------------------------
-- Naming it aborts the push with
--
--   ERROR: relation "auth.users" does not exist (SQLSTATE 42P01)
--
-- because the migration connection's search_path does not resolve the auth
-- schema. Runs 36870164815 and 36873453231 both died that way. The account
-- table is therefore DISCOVERED from the key `profiles.id` already carries, and
-- every reference below is spelled `format('%I.%I', nspname, relname)` from
-- `pg_class`/`pg_namespace`. See 0118 for the same technique and the reasoning.
--
-- WHAT SURVIVES AN ACCOUNT DELETION
-- ---------------------------------
-- A transaction document is evidence about a completed exchange, not personal
-- data belonging to either party, so it survives — with the party ids
-- nulled and the names kept, exactly like the `actor_name` copies 0118 already
-- documents. `account_deletion_blockers()` walks CASCADE, and nothing here
-- cascades, so closing an account still cannot be blocked by this table.

-- ===========================================================================
-- 1. The document
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.transaction_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Human-facing, stable, and unique. `ORD-<8 hex of the order id>-NN`, where
  -- NN is the nth document for that order. A slip number a human reads out
  -- over the phone is the point; a uuid is not that.
  document_number text NOT NULL UNIQUE,

  subject_type text NOT NULL
    CHECK (subject_type IN ('ORDER', 'RIDE')),
  subject_id uuid NOT NULL,

  -- The scenario this document records. Equal to the status that was just
  -- entered, so "every necessary scenario" is not a list somebody maintains
  -- beside the statuses -- it cannot drift from them.
  scenario text NOT NULL,
  from_status text,
  to_status text NOT NULL,

  issued_at timestamptz NOT NULL DEFAULT now(),
  issued_by uuid,

  -- Both parties, as they were when the document was issued.
  customer_user_id uuid,
  customer_name text NOT NULL DEFAULT '',
  customer_phone text NOT NULL DEFAULT '',
  provider_user_id uuid,
  provider_name text NOT NULL DEFAULT '',
  provider_phone text NOT NULL DEFAULT '',

  city text,
  currency text NOT NULL DEFAULT 'ETB',

  -- Money, as charged. `platform_fee` is read from the ledger rather than
  -- recomputed, so the document reports what was actually taken.
  subtotal numeric(12,2) NOT NULL DEFAULT 0,
  platform_fee numeric(12,2) NOT NULL DEFAULT 0,
  total numeric(12,2) NOT NULL DEFAULT 0,

  -- Everything else about the subject at issue time: line items, pickup and
  -- destination, vehicle, fulfilment mode, address, note. A snapshot, so a
  -- later edit to the order cannot rewrite history.
  subject_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,

  -- Where an uploaded slip image lives, in the `transaction-slips` bucket.
  -- NULL is the normal state: most documents are the server's own record and
  -- need no attachment.
  slip_storage_path text,

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_transaction_documents_subject
  ON public.transaction_documents (subject_type, subject_id, issued_at);
CREATE INDEX IF NOT EXISTS idx_transaction_documents_customer
  ON public.transaction_documents (customer_user_id, issued_at DESC);
CREATE INDEX IF NOT EXISTS idx_transaction_documents_provider
  ON public.transaction_documents (provider_user_id, issued_at DESC);

-- The account-side foreign keys, attached the way 0118 attaches them: the
-- account table is never named, it is read off the constraint `profiles.id`
-- already carries.
DO $$
DECLARE
  v_account text;
  v_name    text;
  v_col     text;
BEGIN
  SELECT format('%I.%I', pn.nspname, pc.relname) INTO v_account
    FROM pg_constraint c
    JOIN pg_class pc     ON pc.oid = c.confrelid
    JOIN pg_namespace pn ON pn.oid = pc.relnamespace
   WHERE c.conrelid = to_regclass('public.profiles')
     AND c.contype  = 'f'
     AND c.conkey   = ARRAY[
           (SELECT a.attnum FROM pg_attribute a
             WHERE a.attrelid = to_regclass('public.profiles')
               AND a.attname  = 'id')];

  -- Guarded, because a database with no profiles table has no account table
  -- to point at either, and a missing constraint is better than a failed push.
  IF v_account IS NULL THEN
    RETURN;
  END IF;

  -- Added only when absent, so re-running this file is a no-op rather than
  -- `ERROR: constraint ... already exists` -- which is how a broken first
  -- attempt would have been unable to be fixed.
  --
  -- `%s` for the reference, NOT `%I`: v_account is ALREADY quoted and
  -- schema-qualified, and `%I` on that text produces `REFERENCES
  -- "public.users"`, a relation that does not exist. See 0118.
  FOREACH v_col IN ARRAY ARRAY['customer_user_id', 'provider_user_id', 'issued_by']
  LOOP
    v_name := 'transaction_documents_' || v_col || '_fkey';
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = v_name) THEN
      EXECUTE format('ALTER TABLE public.transaction_documents '
                     'ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s '
                     'ON DELETE SET NULL', v_name, v_col, v_account);
    END IF;
  END LOOP;
END;
$$;

COMMENT ON TABLE public.transaction_documents IS
  'One row per order or ride status change: the slip. Carries both parties'' '
  'names and phone numbers as they were at the moment of the transaction, the '
  'amount, the platform fee actually charged, and a snapshot of the subject. '
  'Written by a trigger on the status-history tables, so no transition '
  'function has to know documents exist.';
-- ===========================================================================
-- 2. Issuing the document
-- ===========================================================================
-- Two trigger functions, one per history table, because the subjects carry
-- different facts: an order has line items, a fulfilment mode and an address;
-- a ride has a pickup, a destination and a vehicle. Forcing both into one
-- function means a union of nullable columns and a snapshot full of nulls.
--
-- Both are SECURITY DEFINER: the history tables are not writable by the roles
-- that change a status, and these run as part of a write that already
-- succeeded. Neither takes a subject id from the caller — the subject comes
-- from `NEW`, which only a trigger can supply.
CREATE OR REPLACE FUNCTION public.write_order_transaction_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  o                  record;
  v_customer_name    text := '';
  v_customer_phone   text := '';
  v_provider_user    uuid;
  v_provider_name    text := '';
  v_provider_phone   text := '';
  v_fee              numeric(12,2) := 0;
  v_seq              int;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = NEW.order_id;
  IF o.id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(full_name, ''), coalesce(phone, '')
    INTO v_customer_name, v_customer_phone
    FROM public.profiles WHERE id = o.user_id;

  -- The business name is what a customer recognises on a slip; the owner's
  -- personal name is the fallback for a provider row that has not set one.
  SELECT pp.user_id,
         coalesce(nullif(pp.business_name, ''), nullif(pr.full_name, ''), ''),
         coalesce(pr.phone, '')
    INTO v_provider_user, v_provider_name, v_provider_phone
    FROM public.provider_profiles pp
    LEFT JOIN public.profiles pr ON pr.id = pp.user_id
   WHERE pp.id = o.provider_id;

  -- The fee is read from the LEDGER, not recomputed from the resolver. The
  -- resolver is what would be charged now; the ledger is what was taken.
  SELECT coalesce(sum(wt.platform_fee), 0) INTO v_fee
    FROM public.wallet_transactions wt
   WHERE wt.order_id = o.id
     AND wt.transaction_type = 'TRANSACTION_FEE';

  SELECT count(*) + 1 INTO v_seq
    FROM public.transaction_documents
   WHERE subject_type = 'ORDER' AND subject_id = o.id;

  INSERT INTO public.transaction_documents (
    document_number, subject_type, subject_id, scenario, from_status,
    to_status, issued_at, issued_by,
    customer_user_id, customer_name, customer_phone,
    provider_user_id, provider_name, provider_phone,
    city, currency, subtotal, platform_fee, total, subject_snapshot
  ) VALUES (
    'ORD-' || upper(substr(o.id::text, 1, 8)) || '-' || lpad(v_seq::text, 2, '0'),
    'ORDER', o.id, NEW.to_status::text, NEW.from_status::text,
    NEW.to_status::text, coalesce(NEW.created_at, now()), NEW.changed_by,
    o.user_id, v_customer_name, v_customer_phone,
    v_provider_user, v_provider_name, v_provider_phone,
    o.city, o.currency, o.total_amount, v_fee, o.total_amount,
    jsonb_build_object(
      'status', NEW.to_status,
      'from_status', NEW.from_status,
      'note', NEW.note,
      'fulfillment_mode', o.fulfillment_mode,
      'delivery_address', o.delivery_address,
      'requires_payment_proof', o.requires_payment_proof,
      'created_at', o.created_at,
      'items', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'product_id', oi.product_id,
                 'quantity', oi.quantity,
                 'unit_price', oi.unit_price,
                 'subtotal', oi.subtotal)
               ORDER BY oi.id)
          FROM public.order_items oi
         WHERE oi.order_id = o.id), '[]'::jsonb))
  )
  ON CONFLICT (document_number) DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.write_ride_transaction_document()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  r                  record;
  v_customer_name    text := '';
  v_customer_phone   text := '';
  v_provider_user    uuid;
  v_provider_name    text := '';
  v_provider_phone   text := '';
  v_fee              numeric(12,2) := 0;
  v_seq              int;
BEGIN
  SELECT * INTO r FROM public.ride_requests WHERE id = NEW.ride_request_id;
  IF r.id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT coalesce(full_name, ''), coalesce(phone, '')
    INTO v_customer_name, v_customer_phone
    FROM public.profiles WHERE id = r.user_id;

  -- A ride that has not been claimed has no provider yet. The document is
  -- still issued, with the provider fields empty — a REQUESTED slip that
  -- later names the provider would be a slip nobody could rely on.
  IF r.claimed_by_provider_id IS NOT NULL THEN
    SELECT pp.user_id,
           coalesce(nullif(pp.business_name, ''), nullif(pr.full_name, ''), ''),
           coalesce(pr.phone, '')
      INTO v_provider_user, v_provider_name, v_provider_phone
      FROM public.provider_profiles pp
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE pp.id = r.claimed_by_provider_id;
  END IF;

  SELECT coalesce(sum(wt.platform_fee), 0) INTO v_fee
    FROM public.wallet_transactions wt
   WHERE wt.ride_request_id = r.id
     AND wt.transaction_type = 'TRANSACTION_FEE';

  SELECT count(*) + 1 INTO v_seq
    FROM public.transaction_documents
   WHERE subject_type = 'RIDE' AND subject_id = r.id;

  INSERT INTO public.transaction_documents (
    document_number, subject_type, subject_id, scenario, from_status,
    to_status, issued_at, issued_by,
    customer_user_id, customer_name, customer_phone,
    provider_user_id, provider_name, provider_phone,
    currency, subtotal, platform_fee, total, subject_snapshot
  ) VALUES (
    'RID-' || upper(substr(r.id::text, 1, 8)) || '-' || lpad(v_seq::text, 2, '0'),
    'RIDE', r.id, NEW.to_status::text, NEW.from_status::text,
    NEW.to_status::text, coalesce(NEW.created_at, now()), NEW.changed_by,
    r.user_id, v_customer_name, v_customer_phone,
    v_provider_user, v_provider_name, v_provider_phone,
    'ETB', coalesce(r.fare_estimate, 0), v_fee, coalesce(r.fare_estimate, 0),
    jsonb_build_object(
      'status', NEW.to_status,
      'from_status', NEW.from_status,
      'pickup_text', r.pickup_text,
      'destination_text', r.destination_text,
      'vehicle_category_id', r.vehicle_category_id,
      'vehicle_category_name',
        (SELECT c.name FROM public.categories c WHERE c.id = r.vehicle_category_id),
      'vehicle_plate',
        (SELECT veh.plate_number FROM public.vehicles veh
          WHERE veh.id = r.claimed_vehicle_id),
      'claimed_at', r.claimed_at,
      'created_at', r.created_at)
  )
  ON CONFLICT (document_number) DO NOTHING;

  RETURN NEW;
END;
$$;

-- AFTER, not BEFORE: the document must record the status the subject has
-- actually reached, and AFTER also runs inside the same transaction, so a
-- transaction that rolls back takes its document with it. A slip for an order
-- that never existed is worse than no slip.
DROP TRIGGER IF EXISTS trg_write_order_transaction_document ON public.order_status_history;
CREATE TRIGGER trg_write_order_transaction_document
  AFTER INSERT ON public.order_status_history
  FOR EACH ROW EXECUTE FUNCTION public.write_order_transaction_document();

DROP TRIGGER IF EXISTS trg_write_ride_transaction_document ON public.ride_status_history;
CREATE TRIGGER trg_write_ride_transaction_document
  AFTER INSERT ON public.ride_status_history
  FOR EACH ROW EXECUTE FUNCTION public.write_ride_transaction_document();

REVOKE ALL ON FUNCTION public.write_order_transaction_document() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.write_ride_transaction_document() FROM PUBLIC, anon, authenticated;

-- ===========================================================================
-- 3. Backfill, so "every transaction" is true of the PAST too
-- ===========================================================================
-- The trigger only sees history rows written from now on. Every order and ride
-- that already happened has a history and no document, and an admin
-- reconciling last month would find the gaps and conclude the feature is
-- broken. Backfilling is the difference between "wired end to end" and "wired
-- end to end going forward".
--
-- Row numbers over the existing history rather than a count, so the numbering
-- matches what the trigger would have produced: document 01 is the first event
-- of the subject, in the order it actually happened.
INSERT INTO public.transaction_documents (
  document_number, subject_type, subject_id, scenario, from_status, to_status,
  issued_at, issued_by, customer_user_id, customer_name, customer_phone,
  provider_user_id, provider_name, provider_phone, city, currency,
  subtotal, platform_fee, total, subject_snapshot)
SELECT
  'ORD-' || upper(substr(o.id::text, 1, 8)) || '-' || lpad(rn::text, 2, '0'),
  'ORDER', o.id, h.to_status::text, h.from_status::text, h.to_status::text,
  coalesce(h.created_at, o.created_at), h.changed_by,
  o.user_id, cp.full_name, coalesce(cp.phone, ''),
  pp.user_id,
  coalesce(nullif(pp.business_name, ''), nullif(ppn.full_name, ''), ''),
  coalesce(ppn.phone, ''),
  o.city, o.currency, o.total_amount,
  coalesce((SELECT sum(wt.platform_fee) FROM public.wallet_transactions wt
             WHERE wt.order_id = o.id AND wt.transaction_type = 'TRANSACTION_FEE'), 0),
  o.total_amount,
  jsonb_build_object('status', h.to_status, 'from_status', h.from_status,
                     'note', h.note, 'backfilled', true,
                     'fulfillment_mode', o.fulfillment_mode,
                     'delivery_address', o.delivery_address)
FROM public.order_status_history h
JOIN public.orders o ON o.id = h.order_id
LEFT JOIN public.profiles cp  ON cp.id = o.user_id
LEFT JOIN public.provider_profiles pp ON pp.id = o.provider_id
LEFT JOIN public.profiles ppn ON ppn.id = pp.user_id
CROSS JOIN LATERAL (
  SELECT count(*)::int AS rn
    FROM public.order_status_history h2
   WHERE h2.order_id = h.order_id
     AND (coalesce(h2.created_at, '-infinity'::timestamptz), h2.id)
         <= (coalesce(h.created_at,   '-infinity'::timestamptz), h.id)
) AS x
ON CONFLICT (document_number) DO NOTHING;

INSERT INTO public.transaction_documents (
  document_number, subject_type, subject_id, scenario, from_status, to_status,
  issued_at, issued_by, customer_user_id, customer_name, customer_phone,
  provider_user_id, provider_name, provider_phone, currency,
  subtotal, platform_fee, total, subject_snapshot)
SELECT
  'RID-' || upper(substr(r.id::text, 1, 8)) || '-' || lpad(x.rn::text, 2, '0'),
  'RIDE', r.id, h.to_status::text, h.from_status::text, h.to_status::text,
  coalesce(h.created_at, r.created_at), h.changed_by,
  r.user_id, cp.full_name, coalesce(cp.phone, ''),
  pp.user_id,
  coalesce(nullif(pp.business_name, ''), nullif(ppn.full_name, ''), ''),
  coalesce(ppn.phone, ''),
  'ETB', coalesce(r.fare_estimate, 0),
  coalesce((SELECT sum(wt.platform_fee) FROM public.wallet_transactions wt
             WHERE wt.ride_request_id = r.id AND wt.transaction_type = 'TRANSACTION_FEE'), 0),
  coalesce(r.fare_estimate, 0),
  jsonb_build_object('status', h.to_status, 'from_status', h.from_status,
                     'pickup_text', r.pickup_text,
                     'destination_text', r.destination_text, 'backfilled', true)
FROM public.ride_status_history h
JOIN public.ride_requests r ON r.id = h.ride_request_id
LEFT JOIN public.profiles cp ON cp.id = r.user_id
LEFT JOIN public.provider_profiles pp ON pp.id = r.claimed_by_provider_id
LEFT JOIN public.profiles ppn ON ppn.id = pp.user_id
CROSS JOIN LATERAL (
  SELECT count(*)::int AS rn
    FROM public.ride_status_history h2
   WHERE h2.ride_request_id = h.ride_request_id
     AND (coalesce(h2.created_at, '-infinity'::timestamptz), h2.id)
         <= (coalesce(h.created_at,   '-infinity'::timestamptz), h.id)
) AS x
ON CONFLICT (document_number) DO NOTHING;

-- ===========================================================================
-- 4. Who may read a document
-- ===========================================================================
-- A slip names both parties and their phone numbers. Exactly three people may
-- read one: the customer, the provider, and an administrator. There is no
-- fourth case, so there is no fourth policy.
ALTER TABLE public.transaction_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS transaction_documents_read ON public.transaction_documents;
CREATE POLICY transaction_documents_read ON public.transaction_documents
  FOR SELECT TO authenticated
  USING (
    customer_user_id = (SELECT auth.uid())
    OR provider_user_id = (SELECT auth.uid())
    OR public.is_admin()
  );

REVOKE ALL ON TABLE public.transaction_documents FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.transaction_documents TO authenticated, service_role;

-- No INSERT, UPDATE or DELETE policy at all: documents are written by the
-- trigger and are not editable by anybody, including an admin. A slip that an
-- administrator can quietly edit is not evidence.

-- ===========================================================================
-- 5. The slip attachment bucket
-- ===========================================================================
-- PRIVATE, unlike every image bucket in this project. A provider photo is
-- meant to be public; a slip carries a delivery address and two phone numbers
-- and is not. Read access therefore goes through a signed URL scoped to the
-- uploader's own folder, plus an administrator.
--
-- A bucket that predates this file (a re-run) is left alone rather than
-- flipped to public: silently widening a private bucket is the one outcome
-- here that cannot be undone by re-running the migration.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('transaction-slips', 'transaction-slips', false, 5242880,
        ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS transaction_slips_insert ON storage.objects;
CREATE POLICY transaction_slips_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'transaction-slips'
    AND (SELECT auth.uid())::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS transaction_slips_read_own ON storage.objects;
CREATE POLICY transaction_slips_read_own ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'transaction-slips'
    AND (SELECT auth.uid())::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS transaction_slips_delete_own ON storage.objects;
CREATE POLICY transaction_slips_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'transaction-slips'
    AND (SELECT auth.uid())::text = (string_to_array(name, '/'))[1]
  );

-- ===========================================================================
-- 6. Reading them
-- ===========================================================================
-- One reader for the parties, one for administrators. Both are SECURITY
-- DEFINER so the RLS policy above and the function's own party check cannot
-- drift into disagreeing: the function is the one place that decides.
CREATE OR REPLACE FUNCTION public.my_transaction_documents(
  p_subject_type text DEFAULT NULL,
  p_subject_id   uuid DEFAULT NULL,
  p_limit        int  DEFAULT 100
)
RETURNS SETOF public.transaction_documents
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN QUERY
  SELECT d.*
    FROM public.transaction_documents d
   WHERE (d.customer_user_id = (SELECT auth.uid())
       OR d.provider_user_id = (SELECT auth.uid()))
     -- Parenthesised as one group. Without it `AND` binds tighter than `OR`,
     -- and this reads `customer = me OR (provider = me AND filters)` -- so a
     -- CUSTOMER's documents ignore the filters entirely and asking for one
     -- order returns every order they have ever placed.
     AND (p_subject_type IS NULL OR d.subject_type = p_subject_type)
     AND (p_subject_id   IS NULL OR d.subject_id   = p_subject_id)
   ORDER BY d.issued_at DESC, d.id
   LIMIT greatest(1, least(coalesce(p_limit, 100), 500));
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_transaction_documents(p_limit int DEFAULT 100)
RETURNS SETOF public.transaction_documents
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  RETURN QUERY
  SELECT d.*
    FROM public.transaction_documents d
   ORDER BY d.issued_at DESC, d.id
   LIMIT greatest(1, least(coalesce(p_limit, 100), 1000));
END;
$$;

-- Attaching a slip is a write to a row nobody may update, so it is a function
-- with its own party check rather than an UPDATE policy. The path must be in
-- the caller's own folder: the storage policy enforces that too, and this
-- enforces that the caller is actually a party to the document.
CREATE OR REPLACE FUNCTION public.attach_transaction_slip(
  p_document_number text,
  p_path            text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  d record;
BEGIN
  IF p_path IS NULL OR p_path !~ '^[^/]+/.+' THEN
    RAISE EXCEPTION 'SLIP_PATH_MUST_BE_<UID>/...';
  END IF;

  SELECT * INTO d
    FROM public.transaction_documents
   WHERE document_number = p_document_number;

  IF d.id IS NULL THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND';
  END IF;

  IF d.customer_user_id IS DISTINCT FROM (SELECT auth.uid())
     AND d.provider_user_id IS DISTINCT FROM (SELECT auth.uid())
     AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'NOT_A_PARTY_TO_THIS_DOCUMENT';
  END IF;

  IF (split_part(p_path, '/', 1))::uuid IS DISTINCT FROM (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'SLIP_PATH_MUST_BE_IN_YOUR_OWN_FOLDER';
  END IF;

  UPDATE public.transaction_documents
     SET slip_storage_path = p_path
   WHERE id = d.id;

  RETURN 'ok: ' || d.document_number;
END;
$$;

REVOKE ALL ON FUNCTION public.my_transaction_documents(text, uuid, int)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_transaction_documents(text, uuid, int)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_transaction_documents(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_transaction_documents(int)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.attach_transaction_slip(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.attach_transaction_slip(text, text)
  TO authenticated, service_role;

-- ===========================================================================
-- 7. Prove it, on the live database
-- ===========================================================================
-- The static harness can prove the trigger exists and that the histories feed
-- it. Only this can prove the LIVE trigger fires, and a trigger that exists
-- but is not attached produces documents for nothing and passes every other
-- check.
CREATE OR REPLACE FUNCTION public.assert_transaction_documents_are_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text;
  v_docs    bigint;
BEGIN
  SELECT string_agg(t.tbl || '.' || t.trg, ', ') INTO v_missing
    FROM (VALUES
      ('order_status_history', 'trg_write_order_transaction_document'),
      ('ride_status_history',  'trg_write_ride_transaction_document')
    ) AS t(tbl, trg)
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_trigger g
      WHERE g.tgrelid = to_regclass(format('public.%I', t.tbl))
        AND g.tgname  = t.trg
        AND NOT g.tgisinternal);

  IF v_missing IS NOT NULL THEN
    RETURN 'BROKEN: no trigger ' || v_missing
        || ' -- orders and rides change status without leaving a document';
  END IF;

  -- COUNTED PER SUBJECT, not "does a document exist for this subject".
  --
  -- The first version of this check was
  --
  --   SELECT count(*) FROM order_status_history h
  --    WHERE NOT EXISTS (SELECT 1 FROM transaction_documents d
  --                       WHERE d.subject_type='ORDER' AND d.subject_id=h.order_id)
  --
  -- which is a question about the SUBJECT, not the event: three status changes
  -- on one order produce three history rows and three documents, and deleting
  -- any ONE of those documents still leaves two, so every history row still
  -- finds a document and the check reports ok. It was proved by deleting a
  -- document and watching it stay green.
  --
  -- What has to hold is one document per status change, so the counts have to
  -- be EQUAL for every subject. That catches a trigger that did not fire and a
  -- document that went missing, and it is the shape a backfill can be trusted
  -- against.
  SELECT count(*) INTO v_docs
    FROM (SELECT h.order_id AS sid, count(*) AS n
            FROM public.order_status_history h
           GROUP BY h.order_id) hist
    LEFT JOIN (SELECT d.subject_id AS sid, count(*) AS n
                 FROM public.transaction_documents d
                WHERE d.subject_type = 'ORDER'
                GROUP BY d.subject_id) doc
      ON doc.sid = hist.sid
   WHERE coalesce(doc.n, 0) <> hist.n;

  IF v_docs > 0 THEN
    RETURN 'BROKEN: ' || v_docs
        || ' order(s) have a document count that does not match their '
           'status-change count, so at least one event left no slip';
  END IF;

  SELECT count(*) INTO v_docs
    FROM (SELECT h.ride_request_id AS sid, count(*) AS n
            FROM public.ride_status_history h
           GROUP BY h.ride_request_id) hist
    LEFT JOIN (SELECT d.subject_id AS sid, count(*) AS n
                 FROM public.transaction_documents d
                WHERE d.subject_type = 'RIDE'
                GROUP BY d.subject_id) doc
      ON doc.sid = hist.sid
   WHERE coalesce(doc.n, 0) <> hist.n;

  IF v_docs > 0 THEN
    RETURN 'BROKEN: ' || v_docs
        || ' ride(s) have a document count that does not match their '
           'status-change count, so at least one event left no slip';
  END IF;

  RETURN 'ok: every order and ride status change left a document, and both '
         'triggers are attached';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_transaction_documents_are_wired() FROM PUBLIC;
-- anon is granted for the same reason `assert_ceo_delete_is_wired` has it:
-- the connectivity suite runs as anon, and a diagnostic the reading role
-- cannot call answers PGRST202, which is indistinguishable from a migration
-- that was never applied.
GRANT EXECUTE ON FUNCTION public.assert_transaction_documents_are_wired()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
