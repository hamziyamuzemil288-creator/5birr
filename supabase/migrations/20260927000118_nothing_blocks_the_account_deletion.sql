-- Nothing may block the account deletion. Not the user side, not the business side.
--
-- WHAT 0054 GOT WRONG
-- -------------------
-- 20260927000054 turned eight NOT NULL columns into ON DELETE SET NULL, and
-- said so here:
--
--   "The other eight are NOT NULL with no action [...] Every one of those is a
--    RECORD, not personal data."
--
-- and then, further up:
--
--   "every RLS predicate of the form `user_id = auth.uid()` simply stops
--    matching a NULL, which is the correct outcome for an account that no
--    longer exists."
--
-- Both sentences assume that a NULLABLE column with no ON DELETE action is
-- survivable. It is not. PostgreSQL 18, 5.5.5 Foreign Keys:
--
--   "The default ON DELETE action is ON DELETE NO ACTION [...] the foreign-key
--    constraint is still required to be satisfied, so this operation will
--    usually result in an error."
--
-- and, on nullability, immediately afterwards:
--
--   "Normally, a referencing row need not satisfy the foreign key constraint if
--    any of its referencing columns are null."
--
-- That exemption is about INSERTING and UPDATING a referencing row whose column
-- is already null. It is not a licence to delete a parent while a row still
-- points at it. A nullable `audit_logs.actor_id` is exactly as blocking as a
-- NOT NULL one.
--
-- So 0054 fixed the eight columns that were loud (NOT NULL, therefore obviously
-- wrong) and left the quiet ones, and `delete_user_account` still raises
--
--   ERROR: update or delete on table "audit_logs" violates foreign key
--          constraint "audit_logs_actor_id_fkey" on table "audit_logs"
--
-- for any account that has an audit log row -- which, since 0035 put a trigger
-- on the mutation paths, is every account that has done anything at all. The
-- request screen works, the approval writes APPROVED, the gateway calls the
-- function, and the delete dies. The request then reads APPROVED for an account
-- that still exists, which is the one state the design explicitly tried to
-- avoid.
--
-- THE BUSINESS SIDE WAS NEVER TOUCHED AT ALL
-- -----------------------------------------
-- `provider_profiles` is ON DELETE CASCADE from auth.users, so closing a
-- provider's account deletes the business profile -- and seven columns point
-- into that subtree with no action:
--
--   orders.provider_id               NOT NULL
--   order_items.product_id
--   ride_requests.claimed_by_provider_id
--   ride_requests.claimed_vehicle_id
--   ride_ratings.ratee_provider_id
--   admin_wallet_actions.provider_id NOT NULL
--   admin_wallet_actions.wallet_id   NOT NULL
--
-- `orders.provider_id` is NOT NULL, so this is the loud kind: a shop with a
-- single order could never be closed, and the error names `orders`, which is
-- the last table anybody would go looking at when the person asking to leave is
-- a provider.
--
-- WHY ONE MIGRATION FOR BOTH SIDES
-- ---------------------------------
-- They are the same defect and the same fix, and they fail in the same
-- statement. Fixing only the business side would still leave a customer with an
-- audit log unable to delete their account, which is the case Google Play is
-- actually asking about.
--
-- WHY `provider_profiles.user_id` IS NOT IN THE LIST
-- -------------------------------------------------
-- It is a NO ACTION key onto `profiles`, and it looks like a blocker. It is not:
-- `provider_profiles` is reached only through `auth.users.user_id` ON DELETE
-- CASCADE, so the only rows that can reference the dying profile row are the
-- rows being deleted in the same statement. Relaxing it would drop NOT NULL on
-- the column the whole app finds a provider by (`owns_provider_profile`,
-- every provider dashboard query) to fix a problem that cannot occur.
--
-- WHY DROPPING NOT NULL IS SAFE HERE
-- ----------------------------------
-- Four of these columns are NOT NULL and the constraint has to go with the
-- action, because SET NULL on a NOT NULL column fails at delete time -- the
-- same sentence in the docs: "these do not excuse you from observing any
-- constraints". There is no client INSERT policy on `orders`,
-- `wallet_transactions`, `admin_wallet_actions`, `admin_expenses` or
-- `admin_notification_broadcasts`; they are written only by SECURITY DEFINER
-- functions and Edge Functions, which all pass a real provider id. A nullable
-- column they always fill is not an integrity hole. `ride_requests` and
-- `ride_ratings` are already nullable and the code already guards them
-- (`IF v_ride.claimed_by_provider_id IS NOT NULL`).
--
-- RLS predicates that read these columns -- `owns_provider_profile(o.provider_id)`
-- -- evaluate to false/NULL for a detached row, which is the correct outcome
-- and the same one 0054 relied on.

-- ===========================================================================
-- 1. Detach every key that can still block
-- ===========================================================================
-- Data-driven rather than a CASE per table, because two of these tables carry
-- two blocking columns each and 0054's `c := CASE t` shape silently handles
-- only one.
--
-- The lookup matches on the child's own single-column key and takes the parent
-- from the catalog, which is how 0054 did it and for the same reason: the
-- migration connection's search_path does not resolve the `auth` schema, so
-- naming it -- `'auth.users'::regclass` -- aborts the whole push with
--
--   ERROR: relation "auth.users" does not exist (SQLSTATE 42P01)
--
-- which is exactly what run 36870164815 did. Nothing in this file says
-- `auth.users`; the parent is whatever the existing constraint already points
-- at. `admin_notification_broadcasts` has two keys to it (`admin_id` and
-- `target_user_id`, both NO ACTION until this file touches them) and they are
-- on different columns, so matching on the column still picks exactly one.
--
-- `target_user_id` is the twentieth, and it is the one this file's own header
-- predicts. Nullable, and therefore assumed survivable by everything written
-- before it. It is not. It was also invisible to the static harness, which
-- kept only the strongest action per parent and so reported SET NULL for a
-- table that still carried a NO ACTION column -- the same class of error as
-- 0054, one level up.
--
-- The action filter is part of the lookup rather than a second query after it:
-- 'a' is NO ACTION, 'r' is RESTRICT, 'c' CASCADE, 'n' SET NULL. A key that is
-- already CASCADE or SET NULL yields no row, so the loop leaves the good
-- constraint alone and re-running this file is a no-op.
DO $$
DECLARE
  target record;
  v_fk     text;
  v_parent text;
BEGIN
  FOR target IN
    SELECT * FROM (VALUES
      -- ---- the business side: everything under provider_profiles -------
      ('orders',                'provider_id'),
      ('order_items',           'product_id'),
      ('ride_requests',         'claimed_by_provider_id'),
      ('ride_requests',         'claimed_vehicle_id'),
      ('ride_ratings',          'ratee_provider_id'),
      ('admin_wallet_actions',  'provider_id'),
      ('admin_wallet_actions',  'wallet_id'),
      -- ---- the account side 0054 left blocking -------------------------
      ('audit_logs',                        'actor_id'),
      ('admin_history',                     'actor_id'),
      ('approval_history',                  'performed_by'),
      ('order_status_history',              'changed_by'),
      ('ride_status_history',               'changed_by'),
      ('payment_methods',                   'created_by'),
      ('payment_proofs',                    'verified_by'),
      ('admin_expenses',                    'admin_id'),
      ('admin_notification_broadcasts',     'admin_id'),
      ('admin_notification_broadcasts',     'target_user_id'),
      -- ---- keyed on somebody ELSE's record, so the row survives --------
      -- A staff member's deletion leaves the rows they touched behind, and
      -- these three are the ones that would refuse to let them go.
      ('referral_codes',                    'created_by'),
      ('wallet_recharge_requests',          'approved_by'),
      ('staff_task_completions',            'completed_by')
    ) AS v(tbl, col)
  LOOP
    IF to_regclass(format('public.%I', target.tbl)) IS NULL THEN
      -- Dropped since this list was written. Nothing to detach. (This is the
      -- `appeals` lesson from 0054, where a stale name in a regclass cast
      -- aborted the whole push on every attempt.)
      CONTINUE;
    END IF;

    -- The parent is re-quoted here, FROM THE CATALOG, and qualified with its
    -- schema. `%I` on a regclass does NOT work: regclass renders as the string
    -- `auth.users`, and `%I` quotes that whole string as one identifier, giving
    -- REFERENCES "auth.users" -- a relation literally named `auth.users`, which
    -- does not exist. That is the 42P01 that killed run 36873453231 on the
    -- eighth tuple, `audit_logs.actor_id`, and only on the eighth: the seven
    -- business-side parents live in `public`, which the connection's
    -- search_path resolves, so they rendered bare and happened to work. Reading
    -- `pg_namespace.nspname` and `pg_class.relname` is the only spelling that
    -- names the parent without ever writing `auth` in this file.
    SELECT c.conname, format('%I.%I', pn.nspname, pr.relname)
      INTO v_fk, v_parent
      FROM pg_constraint c
      JOIN pg_class pr     ON pr.oid = c.confrelid
      JOIN pg_namespace pn ON pn.oid = pr.relnamespace
     WHERE c.conrelid   = to_regclass(format('public.%I', target.tbl))
       AND c.contype    = 'f'
       AND c.confdeltype IN ('a', 'r')
       AND c.conkey     = ARRAY[
             (SELECT a.attnum FROM pg_attribute a
               WHERE a.attrelid = to_regclass(format('public.%I', target.tbl))
                 AND a.attname  = target.col)];

    IF v_fk IS NULL THEN
      -- No blocking single-column foreign key on that column. Nothing to
      -- detach.
      CONTINUE;
    END IF;

    -- The parent string is already schema-qualified and quoted, so it goes in
    -- with `%s`, not `%I`.
    EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I',
                   target.tbl, v_fk);
    EXECUTE format(
      'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (%I) '
      'REFERENCES %s ON DELETE SET NULL',
      target.tbl, v_fk, target.col, v_parent);

    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN %I DROP NOT NULL',
                   target.tbl, target.col);

    RAISE NOTICE 'detached %.% (was blocking account deletion)',
      target.tbl, target.col;
  END LOOP;
END;
$$;

-- ===========================================================================
-- 2. Prove the loop did what it said
-- ===========================================================================
-- A migration that silently skips is worse than one that fails: this one would
-- have deployed cleanly having fixed nothing, exactly as 0054 did. Every pair
-- named above must now resolve to a SET NULL (or CASCADE) key, or the push
-- aborts with the pairs that are still wrong.
--
-- `target` below is the VALUES alias, not a plpgsql record. This block has no
-- loop, so there is nothing to assign a record variable to, and `target.tbl`
-- written against an unassigned record is
--
--   ERROR: record "target" is not assigned yet (SQLSTATE 42703)
--
-- which is what the local scratch cluster said on the first run of this fix.
DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(format('%I.%I', target.tbl, target.col), ', ')
    INTO v_bad
    FROM (VALUES
      ('orders',                'provider_id'),
      ('order_items',           'product_id'),
      ('ride_requests',         'claimed_by_provider_id'),
      ('ride_requests',         'claimed_vehicle_id'),
      ('ride_ratings',          'ratee_provider_id'),
      ('admin_wallet_actions',  'provider_id'),
      ('admin_wallet_actions',  'wallet_id'),
      ('audit_logs',            'actor_id'),
      ('admin_history',         'actor_id'),
      ('approval_history',      'performed_by'),
      ('order_status_history',  'changed_by'),
      ('ride_status_history',   'changed_by'),
      ('payment_methods',       'created_by'),
      ('payment_proofs',        'verified_by'),
      ('admin_expenses',        'admin_id'),
      ('admin_notification_broadcasts', 'admin_id'),
      ('admin_notification_broadcasts', 'target_user_id'),
      ('referral_codes',        'created_by'),
      ('wallet_recharge_requests',      'approved_by'),
      ('staff_task_completions',        'completed_by')
    ) AS target(tbl, col)
    JOIN pg_constraint c
      ON c.conrelid = to_regclass(format('public.%I', target.tbl))
     AND c.contype  = 'f'
     AND c.conkey   = ARRAY[
           (SELECT a.attnum FROM pg_attribute a
             WHERE a.attrelid = to_regclass(format('public.%I', target.tbl))
               AND a.attname  = target.col)]
   WHERE c.confdeltype NOT IN ('c', 'n')
     AND to_regclass(format('public.%I', target.tbl)) IS NOT NULL;

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'ACCOUNT_DELETION_STILL_BLOCKED: these columns still hold a NO ACTION or '
      'RESTRICT key onto something that dies with the account, so deleting the '
      'account row will fail: %', v_bad;
  END IF;
END;
$$;

-- ===========================================================================
-- 3. Ask the live database, not the migrations
-- ===========================================================================
-- The static harness derives the same answer from the migration history, and
-- the two can disagree: a constraint added by hand in the Supabase dashboard
-- never appears in a file. This walks the live catalog, and the connectivity
-- suite asserts it returns `ok`, which is the only thing that can actually
-- prove the account-deletion path is unblocked.
--
-- Read-only, and it reveals schema shape rather than data: it returns table and
-- column names, never row contents.
CREATE OR REPLACE FUNCTION public.account_deletion_blockers()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rows text;
BEGIN
  WITH RECURSIVE gone(rel) AS (
      -- The account table is never named. It is discovered from the key
      -- `profiles.id` already carries, because a migration/function that says
      -- 'auth.users' fails on a connection whose search_path does not include
      -- the auth schema -- which is how run 36870164815 died on 0118.
      SELECT c.confrelid::regclass
        FROM pg_constraint c
       WHERE c.conrelid = to_regclass('public.profiles')
         AND c.contype  = 'f'
         AND c.conkey   = ARRAY[
               (SELECT a.attnum FROM pg_attribute a
                 WHERE a.attrelid = to_regclass('public.profiles')
                   AND a.attname  = 'id')]

      UNION

      -- The cascade arm. A recursive CTE may reference itself in a JOIN, but
      -- NOT inside a subquery, so the "(SELECT rel FROM gone LIMIT 1)" shape
      -- this used to have is
      --
      --   ERROR: recursive reference to query "gone" must not appear within a
      --          subquery
      --
      -- It was also redundant with this arm, which walks the same edge.
      SELECT c.conrelid::regclass
        FROM pg_constraint c
        JOIN gone g ON c.confrelid = g.rel
       WHERE c.contype = 'f'
         AND c.confdeltype = 'c'
  )
  SELECT string_agg(
           format('%I.%I -> %I',
                  c.conrelid::regclass::text,
                  (SELECT a.attname FROM pg_attribute a
                    WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[1]),
                  c.confrelid::regclass::text),
           ', ' ORDER BY c.conrelid::regclass::text, c.conkey[1])
    INTO v_rows
    FROM pg_constraint c
   WHERE c.contype = 'f'
     AND c.confdeltype IN ('a', 'r')
     AND c.confrelid IN (SELECT rel FROM gone)
     -- A row that is itself being deleted in the same statement cannot block:
     -- the check runs at the end of the statement and finds nothing left.
     AND c.conrelid NOT IN (SELECT rel FROM gone);

  IF v_rows IS NULL THEN
    RETURN 'ok: nothing in the live schema blocks deleting an account';
  END IF;

  RETURN 'BLOCKED: ' || v_rows;
END;
$$;

COMMENT ON FUNCTION public.account_deletion_blockers() IS
  'Live diagnostic. Lists every foreign key that would still raise 23503 on '
  'DELETE FROM auth.users, i.e. every column that has to be detached before an '
  'account can actually be closed. Returns ok when the path is clear.';

REVOKE ALL ON FUNCTION public.account_deletion_blockers() FROM PUBLIC;
-- anon is here for the same reason `assert_ceo_delete_is_wired` has it: the
-- connectivity suite runs as the anon role, and a diagnostic that is not
-- reachable by the role that has to read it reports PGRST202, which looks
-- exactly like a migration that was never applied. It returns table and column
-- NAMES and no row contents, so it exposes schema shape that is already in
-- every migration in this repository.
GRANT EXECUTE ON FUNCTION public.account_deletion_blockers()
  TO anon, authenticated, service_role;

-- PostgREST caches the relation metadata.
NOTIFY pgrst, 'reload schema';
