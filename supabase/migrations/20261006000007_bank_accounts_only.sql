-- 20261006000007 — bank accounts only, no phone numbers anywhere buyers can read
--
-- THE REPORT (item 5)
-- ------------------
-- Provider payment accounts accepted anything: a free-text "name" (so
-- Telebirr / CBE Birr / "mobile money" rows crept in), no length or prefix
-- rules, no phone-number rejection, no cap, no default, no audit trail —
-- and phone numbers typed into holder names, labels, business names,
-- product titles/descriptions and gallery captions were how buyers and
-- sellers side-channeled contact BEFORE payment, which item 7 forbids.
--
-- WHAT THIS MIGRATION ENFORCES (backend, so no client can bypass)
--   banks         admin-editable table: per-bank digit length + prefix.
--                  Seed: CBE 13 digits starting 1000, eight generic
--                  8-to-16 banks (including "Other bank" for anything
--                  unlisted).
--   text_looks_like_phone()
--                  normalises spaces/dashes/dots/parens, Ethiopic and
--                  Arabic-Indic digits, and +/00 country prefixes, then
--                  matches 09/07 + 8 digits or 2519/2517 + 8 digits —
--                  exactly the shapes in the report.
--   payment accounts: bank-only (bank_id required when active), phone-like
--                  numbers rejected, mobile-money names rejected, at most
--                  3 ACTIVE accounts per provider, exactly one default
--                  (partial unique index + triggers), audit_logs row for
--                  every create/update/delete.
--   text scan      products(name, description), provider_profiles
--                  (business_name), provider_stores(business_name,
--                  description), provider_gallery(caption) refuse values
--                  that ARE a phone number once normalised.
--   cleanup        existing active rows that are phone-like, mobile-money
--                  named, number-less or unbanked are deactivated (made
--                  inactive, never deleted — the report says inactive).
--
-- Client mirrors these rules for fast feedback; the trigger is the rule.

-- ---------------------------------------------------------------------------
-- 1. The normaliser and the phone detector
-- ---------------------------------------------------------------------------

-- Digits only: converts Arabic-Indic (٠-٩), Extended (۰-۹) and Ethiopic
-- (፩-፱ => 1-9) numerals to ASCII, then drops every non-digit.
CREATE OR REPLACE FUNCTION public.normalize_digits(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(
    translate(
      coalesce(p_text, ''),
      '٠١٢٣٤٥٦٧٨٩' || '۰۱۲۳۴۵۶۷۸۹' || '፩፪፫፬፭፮፯፰፱',
      '0123456789' || '0123456789' || '123456789'),
    '[^0-9]', '', 'g');
$$;

COMMENT ON FUNCTION public.normalize_digits(text) IS
  'Digits only: Ethiopic / Arabic-Indic numerals converted, all other '
  'characters dropped. The shared normaliser behind the phone scan and the '
  'bank length/prefix rules.';

-- True when the text IS an Ethiopian mobile number once normalised:
-- 09XXXXXXXX or 07XXXXXXXX (10 digits), 2519/2517 + 8 digits (11), with
-- optional + or 00 in front. The WHOLE normalised value must match, so a
-- product description that merely CONTAINS other digits never trips it.
CREATE OR REPLACE FUNCTION public.text_looks_like_phone(p_text text)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v text;
BEGIN
  IF p_text IS NULL THEN
    RETURN false;
  END IF;
  v := public.normalize_digits(p_text);
  IF v ~ '^00' THEN
    v := substr(v, 3);
  END IF;
  RETURN v ~ '^0(9|7)[0-9]{8}$' OR v ~ '^251(9|7)[0-9]{8}$';
END;
$$;

COMMENT ON FUNCTION public.text_looks_like_phone(text) IS
  'True when the text normalises to exactly an Ethiopian mobile number '
  '(09/07 + 8 digits or 2519/2517 + 8 digits, +/-00 tolerant): the shape '
  'item 5 forbids in account numbers and in any text a buyer can read.';

GRANT EXECUTE ON FUNCTION public.normalize_digits(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.text_looks_like_phone(text) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The banks table (admin-editable, client-readable)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.banks (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL UNIQUE,
  digit_min  int NOT NULL DEFAULT 8 CHECK (digit_min >= 4),
  digit_max  int NOT NULL DEFAULT 16 CHECK (digit_max >= digit_min),
  prefix     text,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.banks (name, digit_min, digit_max, prefix) VALUES
  ('Commercial Bank of Ethiopia', 13, 13, '1000'),
  ('Awash Bank',        8, 16, NULL),
  ('Dashen Bank',       8, 16, NULL),
  ('Bank of Abyssinia', 8, 16, NULL),
  ('Wegagen Bank',      8, 16, NULL),
  ('Lion Bank',         8, 16, NULL),
  ('Zemen Bank',        8, 16, NULL),
  ('Other bank',        8, 16, NULL)
ON CONFLICT (name) DO NOTHING;

ALTER TABLE public.banks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS banks_read ON public.banks;
CREATE POLICY banks_read ON public.banks
  FOR SELECT TO authenticated
  USING (true);
DROP POLICY IF EXISTS banks_admin_all ON public.banks;
CREATE POLICY banks_admin_all ON public.banks
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

REVOKE ALL ON public.banks FROM anon;
GRANT SELECT ON public.banks TO authenticated;
GRANT ALL ON public.banks TO service_role;

DROP TRIGGER IF EXISTS trg_banks_updated ON public.banks;
CREATE TRIGGER trg_banks_updated
  BEFORE UPDATE ON public.banks FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. New columns on provider_payment_methods
-- ---------------------------------------------------------------------------

ALTER TABLE public.provider_payment_methods
  ADD COLUMN IF NOT EXISTS bank_id uuid REFERENCES public.banks(id),
  ADD COLUMN IF NOT EXISTS is_default boolean NOT NULL DEFAULT false;

-- At most ONE default per provider, structurally — the trigger keeps it
-- consistent, this index makes it impossible to violate.
CREATE UNIQUE INDEX IF NOT EXISTS uq_payment_account_one_default
  ON public.provider_payment_methods (provider_id)
  WHERE is_default;

CREATE INDEX IF NOT EXISTS idx_payment_accounts_bank
  ON public.provider_payment_methods (bank_id);

-- ---------------------------------------------------------------------------
-- 4. Migrate the existing rows: bank backfill, deactivate the bad ones,
--    pick a default
-- ---------------------------------------------------------------------------

-- 4a. Mobile-money named, phone-like, or number-less active rows go inactive
--     (kept as history; never deleted).
UPDATE public.provider_payment_methods
   SET is_active = false,
       is_default = false,
       updated_at = now()
 WHERE is_active
   AND (
     account_number IS NULL
     OR btrim(account_number) = ''
     OR public.text_looks_like_phone(account_number)
     OR name ~* '(telebirr|cbe[[:space:]-]+birr|mobile[[:space:]]+money|birr[[:space:]-]+pay|amole|mpesa|m-pesa|chapa|ethio[[:space:]]+telecom)'
   );

-- 4b. Every surviving ACTIVE row gets a bank: name-guess where possible,
--     "Other bank" otherwise (so the bank_id NOT NULL-by-trigger rule holds
--     the moment this migration commits).
UPDATE public.provider_payment_methods m
   SET bank_id = b.id
  FROM public.banks b
 WHERE m.bank_id IS NULL
   AND m.is_active
   AND b.name = 'Commercial Bank of Ethiopia'
   AND m.name ~* 'commercial bank|(^|[^a-z])cbe([^a-z]|$)'
   AND m.name !~* 'birr';

UPDATE public.provider_payment_methods m
   SET bank_id = b.id
  FROM public.banks b
 WHERE m.bank_id IS NULL
   AND m.is_active
   AND b.name = 'Other bank';

-- 4c. Inactive rows may not carry the default (the partial unique index
--     counts them), then the oldest ACTIVE row per provider becomes default.
UPDATE public.provider_payment_methods
   SET is_default = false
 WHERE is_default AND NOT is_active;

WITH ranked AS (
  SELECT id,
         row_number() OVER (
           PARTITION BY provider_id ORDER BY sort_order, created_at
         ) AS rn,
         bool_or(is_default) OVER (PARTITION BY provider_id) AS has_default
    FROM public.provider_payment_methods
   WHERE is_active
)
UPDATE public.provider_payment_methods p
   SET is_default = true
  FROM ranked r
 WHERE p.id = r.id
   AND r.rn = 1
   AND NOT r.has_default;

-- ---------------------------------------------------------------------------
-- 5. The validation trigger: the rule for every write path
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.enforce_payment_account_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bank public.banks%ROWTYPE;
  v_num  text;
  v_cnt  int;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.updated_at := now();
  END IF;

  NEW.account_number := nullif(btrim(coalesce(NEW.account_number, '')), '');
  NEW.account_name   := nullif(btrim(coalesce(NEW.account_name, '')), '');
  NEW.instructions   := nullif(btrim(coalesce(NEW.instructions, '')), '');
  NEW.name           := btrim(coalesce(NEW.name, ''));

  -- Mobile money is not a bank account.
  IF NEW.name ~* '(telebirr|cbe[[:space:]-]+birr|mobile[[:space:]]+money|birr[[:space:]-]+pay|amole|mpesa|m-pesa|chapa|ethio[[:space:]]+telecom)' THEN
    RAISE EXCEPTION 'MOBILE_MONEY_NOT_ALLOWED';
  END IF;

  -- An inactive row is history: it keeps no default and skips the rules
  -- that would refuse to store it in the first place.
  IF NOT NEW.is_active THEN
    NEW.is_default := false;
    RETURN NEW;
  END IF;

  IF NEW.account_number IS NULL THEN
    RAISE EXCEPTION 'ACCOUNT_NUMBER_REQUIRED';
  END IF;
  IF public.text_looks_like_phone(NEW.account_number) THEN
    RAISE EXCEPTION 'PHONE_LIKE_NUMBER_NOT_ALLOWED';
  END IF;
  IF public.text_looks_like_phone(NEW.name)
     OR public.text_looks_like_phone(NEW.account_name)
     OR public.text_looks_like_phone(NEW.instructions) THEN
    RAISE EXCEPTION 'PHONE_LIKE_TEXT_NOT_ALLOWED: provider_payment_methods';
  END IF;

  IF NEW.bank_id IS NULL THEN
    RAISE EXCEPTION 'BANK_REQUIRED';
  END IF;
  SELECT * INTO v_bank FROM public.banks
   WHERE id = NEW.bank_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'BANK_NOT_FOUND';
  END IF;

  v_num := public.normalize_digits(NEW.account_number);
  IF length(v_num) < v_bank.digit_min OR length(v_num) > v_bank.digit_max THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_LENGTH_INVALID: % expects %-% digits, got %',
      v_bank.name, v_bank.digit_min, v_bank.digit_max, length(v_num);
  END IF;
  IF v_bank.prefix IS NOT NULL
     AND v_bank.prefix <> ''
     AND left(v_num, length(v_bank.prefix)) <> v_bank.prefix THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_PREFIX_INVALID: % accounts must start with %',
      v_bank.name, v_bank.prefix;
  END IF;

  -- Up to 3 ACTIVE accounts — this one plus however many already exist.
  SELECT count(*) INTO v_cnt
    FROM public.provider_payment_methods
   WHERE provider_id = NEW.provider_id
     AND is_active
     AND id IS DISTINCT FROM NEW.id;
  IF v_cnt >= 3 THEN
    RAISE EXCEPTION 'ACCOUNT_LIMIT_REACHED: 3 active payment accounts';
  END IF;

  -- Exactly one default: making this the default clears the others BEFORE
  -- the row lands, so the partial unique index never trips.
  IF NEW.is_default THEN
    UPDATE public.provider_payment_methods
       SET is_default = false,
           updated_at = now()
     WHERE provider_id = NEW.provider_id
       AND id IS DISTINCT FROM NEW.id
       AND is_default;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_payment_account_rules() IS
  'Bank-only payment accounts: phone-like numbers and mobile-money names '
  'refused, bank length/prefix checked, at most 3 active, one default.';

DROP TRIGGER IF EXISTS trg_payment_account_rules ON public.provider_payment_methods;
CREATE TRIGGER trg_payment_account_rules
  BEFORE INSERT OR UPDATE ON public.provider_payment_methods
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_payment_account_rules();

-- ---------------------------------------------------------------------------
-- 6. Keep the default singular, and audit every change
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.payment_account_after_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.provider_payment_methods%ROWTYPE;
BEGIN
  IF TG_OP <> 'DELETE' AND NEW.is_active THEN
    -- A row that just became (or stayed) active and is not the default
    -- needs a default to exist: promote the oldest active one.
    SELECT * INTO v_row
      FROM public.provider_payment_methods
     WHERE provider_id = NEW.provider_id
       AND is_active
       AND is_default
     LIMIT 1;
    IF NOT FOUND THEN
      SELECT * INTO v_row
        FROM public.provider_payment_methods
       WHERE provider_id = NEW.provider_id
         AND is_active
       ORDER BY sort_order, created_at
       LIMIT 1;
      IF FOUND THEN
        UPDATE public.provider_payment_methods
           SET is_default = true
         WHERE id = v_row.id;
      END IF;
    END IF;
  END IF;

  INSERT INTO public.audit_logs
    (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES
    (auth.uid(),
     'payment_account_' || CASE WHEN TG_OP = 'DELETE' THEN 'deleted'
                                ELSE lower(TG_OP) END,
     'provider_payment_methods',
     CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
     jsonb_build_object(
       'provider_id', CASE WHEN TG_OP = 'DELETE' THEN OLD.provider_id ELSE NEW.provider_id END,
       'name',        CASE WHEN TG_OP = 'DELETE' THEN OLD.name ELSE NEW.name END,
       'is_active',   CASE WHEN TG_OP = 'DELETE' THEN OLD.is_active ELSE NEW.is_active END,
       'is_default',  CASE WHEN TG_OP = 'DELETE' THEN OLD.is_default ELSE NEW.is_default END,
       'bank_id',     CASE WHEN TG_OP = 'DELETE' THEN OLD.bank_id ELSE NEW.bank_id END,
       'op',          TG_OP));

  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END;
$$;

DROP TRIGGER IF EXISTS trg_payment_account_audit ON public.provider_payment_methods;
CREATE TRIGGER trg_payment_account_audit
  AFTER INSERT OR UPDATE OR DELETE ON public.provider_payment_methods
  FOR EACH ROW
  EXECUTE FUNCTION public.payment_account_after_change();

-- Admins can disable an account (the owner policy already covers owners).
DROP POLICY IF EXISTS provider_payment_methods_admin_write ON public.provider_payment_methods;
CREATE POLICY provider_payment_methods_admin_write ON public.provider_payment_methods
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------------
-- 7. The phone scan on every text a buyer can read
--    (one function, the columns passed as trigger arguments)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.reject_phone_like_text()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  i int;
  v text;
BEGIN
  FOR i IN 0 .. TG_NARGS - 1 LOOP
    v := to_jsonb(NEW) ->> TG_ARGV[i];
    IF public.text_looks_like_phone(v) THEN
      RAISE EXCEPTION 'PHONE_LIKE_TEXT_NOT_ALLOWED: %.%',
        TG_TABLE_NAME, TG_ARGV[i];
    END IF;
  END LOOP;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.reject_phone_like_text() IS
  'Refuses an INSERT/UPDATE whose scanned column IS a phone number once '
  'normalised — the pre-payment contact channel item 7 closes.';

DROP TRIGGER IF EXISTS trg_products_no_phone ON public.products;
CREATE TRIGGER trg_products_no_phone
  BEFORE INSERT OR UPDATE OF name, description ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_phone_like_text('name', 'description');

DROP TRIGGER IF EXISTS trg_provider_profiles_no_phone ON public.provider_profiles;
CREATE TRIGGER trg_provider_profiles_no_phone
  BEFORE INSERT OR UPDATE OF business_name ON public.provider_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_phone_like_text('business_name');

DROP TRIGGER IF EXISTS trg_provider_stores_no_phone ON public.provider_stores;
CREATE TRIGGER trg_provider_stores_no_phone
  BEFORE INSERT OR UPDATE OF business_name, description ON public.provider_stores
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_phone_like_text('business_name', 'description');

DROP TRIGGER IF EXISTS trg_provider_gallery_no_phone ON public.provider_gallery;
CREATE TRIGGER trg_provider_gallery_no_phone
  BEFORE INSERT OR UPDATE OF caption ON public.provider_gallery
  FOR EACH ROW
  EXECUTE FUNCTION public.reject_phone_like_text('caption');

-- ---------------------------------------------------------------------------
-- 8. The client write-surface expected list, restated with `banks`
-- ---------------------------------------------------------------------------
-- The admin Banks screen writes the banks table directly under the
-- is_admin() policy (the same shape as provider_payment_methods). The
-- expected list is hand-transcribed inside this function because a
-- migration cannot read a Dart file; both halves (this and
-- expectedClientWrites in client_write_surface_test.dart) move together —
-- the drift test pins the count.

CREATE OR REPLACE FUNCTION public.client_write_surface_report()
RETURNS TABLE (
  kind text,
  tables text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH expected(t) AS (
    VALUES
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('banks'),
      ('cart_items'), ('chat_logs'), ('client_error_logs'), ('favorites'),
      ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('provider_payment_methods'),
      ('product_images'), ('product_likes'), ('products'), ('profiles'), ('provider_profiles'),
      ('reviews'), ('ride_ratings'), ('support_tickets'), ('user_documents'),
      ('vehicles'), ('wallet_recharge_requests')
  ),
  public_tables AS (
    -- The existence guard, restored. has_table_privilege() resolves a text
    -- argument as a relation name and raises 42P01 when it does not resolve,
    -- so every name handed to it below must come from a relation that is
    -- known to exist. Enumerating pg_policies instead does not guarantee
    -- that, which is how this function ended up throwing on a relation named
    -- "job" that no migration creates.
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
  ),
  writable AS (
    SELECT pt.table_name
    FROM public_tables pt
    WHERE has_table_privilege('authenticated', pt.table_name, 'INSERT')
      AND EXISTS (
        SELECT 1 FROM pg_policies p
        WHERE p.schemaname = 'public'
          AND p.tablename = pt.table_name
          AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      )
  ),
  unguarded AS (
    SELECT w.table_name
    FROM writable w
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = w.table_name
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  SELECT 'expected', COALESCE(array_agg(t ORDER BY t), '{}') FROM expected
  UNION ALL
  SELECT 'unexpected', COALESCE(array_agg(w.table_name ORDER BY w.table_name), '{}')
    FROM writable w
    WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.t = w.table_name)
  UNION ALL
  SELECT 'unguarded', COALESCE(array_agg(table_name ORDER BY table_name), '{}')
    FROM unguarded;
$$;

COMMENT ON FUNCTION public.client_write_surface_report() IS
  'Compares the tables the app is expected to write against the ones it can. client_error_logs, product_likes, provider_payment_methods and banks are expected: an app that is failing must be able to record why, a like is written directly under RLS by design, a provider manages their own payment methods from their dashboard, and the admin Banks screen edits the account-number rules under is_admin().';
