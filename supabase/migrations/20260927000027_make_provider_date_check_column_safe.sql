-- Make the provider_profiles date check safe whether or not the column exists.
--
-- The ambiguity
-- -------------
-- The trigger on provider_profiles referenced new.subscription_start_date for
-- years. 0033 removed that comparison, and its header is explicit about why:
--
--   "the trigger references new.subscription_start_date, a column that does
--    not exist on this schema -- a latent crash for any UPDATE that got past
--    the status check."
--
-- But 0021_live_schema_snapshot.sql, taken from the live database, shows
-- approve_provider reading v_provider.subscription_start_date when it seeds
-- the subscriptions row. Both cannot be true, and nothing in the repo settles
-- it. Migration 0001 defines it as:
--
--   subscription_start_date timestamptz
--     GENERATED ALWAYS AS (registration_date + interval '1 month') STORED
--
-- and 20260927000015/16/19 -- mine -- carried the comparison forward from the
-- older bodies without noticing 0033 had dropped it.
--
-- Why this is not merely untidy
-- -----------------------------
-- PL/pgSQL does not resolve column references when a function is created. It
-- parses the statement and defers name resolution to first execution. So a
-- guard naming a column that does not exist compiles cleanly, passes every
-- source-text assertion, deploys without complaint, and then raises
--
--   ERROR: column "subscription_start_date" does not exist
--
-- on the first client UPDATE of provider_profiles. The CI assertions in this
-- repo all read pg_proc.prosrc, so none of them would ever see it. That is
-- the same source-grep blind spot that let several bugs through tonight, one
-- level deeper: the assertion can pass on a trigger that crashes on contact.
--
-- The fix
-- -------
-- Stop naming the column directly. Read the value out of the row as JSONB,
-- where a missing key yields NULL instead of an error, and gate the
-- comparison on the column actually being present:
--
--   to_jsonb(new) ->> 'subscription_start_date'
--
-- That cannot raise for a missing column. The existence test makes the intent
-- explicit and keeps the check doing its job when the column is real.
--
-- If the column turns out to exist, behaviour is identical to the previous
-- version. If it does not, the comparison is skipped instead of crashing, and
-- nothing is lost: a GENERATED ALWAYS column cannot be written directly at
-- all, so the database already refuses a client that tries to set it. The
-- check only ever fired when registration_date changed underneath it.
--
-- The other three checks in this guard are untouched -- status, provider_type
-- and owner_national_id -- and the server exemption is unchanged.
--
-- assert_provider_status_guard_is_client_scoped still passes: it looks for the
-- string 'subscription_start_date', which is present in the new form.

CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
  END IF;

  IF new.provider_type IS DISTINCT FROM old.provider_type THEN
    RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
  END IF;

  -- Read through JSONB rather than naming the column. A GENERATED column
  -- cannot be written directly, so this only fires when registration_date
  -- changes; and if the column is absent in a given schema, a missing JSONB
  -- key is NULL instead of a runtime error, which is what 0033 was guarding
  -- against when it dropped the direct comparison.
  IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name  = 'provider_profiles'
          AND column_name = 'subscription_start_date'
     )
     AND (to_jsonb(new) ->> 'subscription_start_date')
         IS DISTINCT FROM (to_jsonb(old) ->> 'subscription_start_date') THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED';
  END IF;

  IF old.owner_national_id IS NOT NULL
     AND new.owner_national_id IS DISTINCT FROM old.owner_national_id THEN
    RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_provider_self_privilege_escalation() IS
  'Stops a client editing its own provider_profiles.status, provider_type or '
  'owner_national_id, and shifting a subscription_start_date if that column '
  'exists. The date is read through to_jsonb so a schema without the column '
  'cannot turn this trigger into a runtime error on every UPDATE.';
