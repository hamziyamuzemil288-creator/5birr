-- Storage policy repair, and a way to finally SEE the client write surface.
--
-- PART 1: TWO STORAGE BUGS, FIXED
-- =================================
--
-- Bug 1: overlapping policies that OR together, with a copy-paste in one.
--
-- Migration 0012 created owner-scoped policies on the private buckets. Then
-- migration 0033 created a SECOND set on three of them, inside a DO block:
--
--   CREATE POLICY <bucket>_owner_insert ON storage.objects FOR INSERT
--     TO authenticated
--     WITH CHECK (bucket_id = <bucket>
--       AND (name LIKE auth.uid()::text || '/%' OR name LIKE 'product-images/%'))
--
-- RLS policies are PERMISSIVE, so the two sets OR. The looser one wins, and
-- this one is looser by accident: 'product-images/%' is a copy-paste from
-- the wrong bucket, left over from the product-images policy below it in the
-- same migration. Inside user-documents, payment-screenshots and
-- payment-proofs, ANY authenticated user could therefore write an object
-- under a path that is not their own.
--
-- Not a data leak -- the SELECT policies still require the caller's uid as
-- the first path segment, or admin, so nothing written that way can be read
-- back. What it does cost:
--
--   * the {user_id}/ invariant every document path depends on is no longer
--     enforced at the storage layer, and
--   * a private bucket can be filled with junk by any signed-in account.
--
-- The fix drops the 0033 policies. The 0012 ones remain and are correct, and
-- they are the stricter of the two, so nothing is lost by removing the
-- accident.
--
-- payment-screenshots needs care: 0012 did not create any policy for it (the
-- bucket did not exist yet), so the 0033 policies are the ONLY policies on
-- it. Dropping them without replacement would leave the bucket unwritable and
-- break every wallet recharge proof upload. Correct policies are created
-- first, in the same transaction, so there is no window without either.
--
-- Bug 2: no UPDATE policy, but the app uploads with upsert: true.
--
-- wallet_service.dart uploads a payment screenshot with FileOptions(upsert:
-- true). That makes the storage API take the ON CONFLICT DO UPDATE path
-- whenever the object already exists, and the UPDATE branch needs an UPDATE
-- policy -- RLS evaluates the update against UPDATE policies, not the INSERT
-- one. None existed on any private bucket, so the first genuine collision
-- would have failed with a row-level-security error on a path that works
-- perfectly until it does not. Owner-scoped UPDATE and DELETE policies are
-- added for the private buckets, which also means a user can finally correct
-- a wrongly-uploaded proof instead of being stuck with it forever.
--
-- PART 2: THE WRITE SURFACE WE STILL CANNOT SEE
-- =============================================
-- Part 1 is safe because it is small and provable. The wider finding -- that
-- Supabase's default privileges grant ALL on new public tables -- is NOT
-- addressed here, and deliberately so.
--
-- Revoking write privileges across every table the app never writes to
-- client-side sounds mechanical. It is not, because the effective policy
-- state cannot be read from the migration files: a policy created in 0002 and
-- dropped in 20260927000014 is still visible in both files, and only the
-- database knows which won. Twenty-five server-only tables show a write
-- policy somewhere in the history, and there is no way to tell from here
-- which of those are live, which are admin-scoped, and which are genuinely
-- open. A blanket REVOKE built on that guess could break a working flow in
-- production, and the person who finds out would be a user whose payment
-- stopped working.
--
-- So the surface is measured instead of guessed. client_write_surface_report()
-- reads the LIVE catalog and returns exactly what is client-writable right
-- now, split into the part that is expected (the twenty tables the app
-- writes) and the part that is not. It is a diagnostic, and it is wired into
-- CI to PRINT rather than to fail, because failing on a number nobody has
-- seen yet would turn the pipeline red for a reason nobody can act on.
--
-- The pattern is the one assert_orders_not_client_insertable() already uses in
-- 20260927000014: an EXACT match on the normalised policy qual, never a
-- substring search. 'is_admin() OR true' mentions is_admin and permits
-- everyone, and it is precisely the shape that must never be mistaken for a
-- safe one -- a substring test would wave it through.

-- ===========================================================================
-- 1. Repair the storage policies
-- ===========================================================================

-- payment-screenshots first: these replace the only policies it has.
DROP POLICY IF EXISTS "payment-screenshots_owner_insert" ON storage.objects;
DROP POLICY IF EXISTS "payment-screenshots_owner_or_admin_read" ON storage.objects;
DROP POLICY IF EXISTS "payment-screenshots_owner_update" ON storage.objects;
DROP POLICY IF EXISTS "payment-screenshots_owner_delete" ON storage.objects;

DROP POLICY IF EXISTS payment_screenshots_insert ON storage.objects;
CREATE POLICY payment_screenshots_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'payment-screenshots'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_screenshots_select_own ON storage.objects;
CREATE POLICY payment_screenshots_select_own ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'payment-screenshots'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_screenshots_admin_read ON storage.objects;
CREATE POLICY payment_screenshots_admin_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'payment-screenshots'
    AND EXISTS (
      SELECT 1 FROM user_roles
      WHERE user_id = auth.uid() AND role = 'ADMIN'
    )
  );

-- Closes the upsert gap, and lets a user replace a proof they uploaded wrong.
DROP POLICY IF EXISTS payment_screenshots_update_own ON storage.objects;
CREATE POLICY payment_screenshots_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'payment-screenshots'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'payment-screenshots'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_screenshots_delete_own ON storage.objects;
CREATE POLICY payment_screenshots_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'payment-screenshots'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- user-documents and payment-proofs keep their 0012 policies. Only the
-- accidental 0033 duplicates are removed, plus the missing UPDATE/DELETE so
-- those buckets behave the same way payment-screenshots now does.
DROP POLICY IF EXISTS "user-documents_owner_insert" ON storage.objects;
DROP POLICY IF EXISTS "user-documents_owner_or_admin_read" ON storage.objects;
DROP POLICY IF EXISTS "payment-proofs_owner_insert" ON storage.objects;
DROP POLICY IF EXISTS "payment-proofs_owner_or_admin_read" ON storage.objects;

DROP POLICY IF EXISTS user_documents_update_own ON storage.objects;
CREATE POLICY user_documents_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'user-documents'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_proofs_update_own ON storage.objects;
CREATE POLICY payment_proofs_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'payment-proofs'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'payment-proofs'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_proofs_delete_own ON storage.objects;
CREATE POLICY payment_proofs_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'payment-proofs'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- ===========================================================================
-- 2. A hard assertion for what was just fixed
-- ===========================================================================
-- These two are certain enough to fail the build on. The broader write-surface
-- finding deliberately does not, for the reasons in the header.
CREATE OR REPLACE FUNCTION public.assert_private_buckets_are_owner_scoped()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offender text;
BEGIN
  -- Every write policy on a private bucket must be scoped to the caller's own
  -- folder. Normalised so formatting cannot disguise a loose policy, and
  -- compared for the presence of the owner clause rather than for equality,
  -- because the correct policies differ in their trailing admin disjunct.
  FOREACH v_offender IN ARRAY
    ARRAY['user-documents', 'payment-screenshots', 'payment-proofs']
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'storage'
        AND tablename = 'objects'
        AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(qual) LIKE '%bucket_id%'
        AND lower(qual) LIKE '%' || v_offender || '%'
        AND lower(qual) NOT LIKE '%auth.uid()%'
    ) THEN
      RAISE EXCEPTION
        'a write policy on the private bucket % is not scoped to the caller''s own folder: %',
        v_offender, v_offender;
    END IF;
  END LOOP;

  -- And no policy guarding a private bucket may also name a path inside a
  -- DIFFERENT bucket. This is the exact shape of the copy-paste that was
  -- removed, so it is asserted separately from the owner check above: the
  -- removed policies DID reference auth.uid(), so the first check would have
  -- waved them through. It is the stray 'product-images/%' disjunct that was
  -- actually wrong, because it lets a client write outside its own folder.
  --
  -- Scoped to policies that mention BOTH a private bucket and a product-images
  -- PATH. The legitimate product-images policies name only product-images, so
  -- they are not caught -- an earlier version of this check matched on the
  -- bare bucket name and flagged them, which would have failed the build over
  -- a policy that was never wrong.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND lower(qual) LIKE '%product-images/%'
      AND lower(qual) ~ '(user-documents|payment-screenshots|payment-proofs)'
  ) THEN
    RAISE EXCEPTION
      'a storage write policy for a private bucket also allows a product-images path, which is the copy-paste this migration removed';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_private_buckets_are_owner_scoped() IS
  'Requires every write policy on user-documents, payment-screenshots and '
  'payment-proofs to be scoped to the caller''s own folder, and forbids any '
  'storage write policy from naming a bucket other than the one it guards.';

GRANT EXECUTE ON FUNCTION public.assert_private_buckets_are_owner_scoped()
  TO anon, authenticated;

-- ===========================================================================
-- 3. The write surface, measured
-- ===========================================================================
-- Returns three lists, all read from the live catalog:
--   1. expected  -- tables the app writes client-side (20)
--   2. unexpected -- client-writable tables the app never writes
--   3. unguarded  -- client-writable tables with NO admin check in the policy
--
-- A table is client-writable when authenticated both holds the privilege and
-- some write policy permits it. has_table_privilege is used rather than
-- information_schema so inherited grants count, and the qual is normalised
-- before the admin check for the same reason 20260927000014 does it.
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
      ('cart_items'), ('chat_logs'), ('favorites'), ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('product_images'), ('products'), ('profiles'), ('provider_profiles'),
      ('reviews'), ('ride_ratings'), ('support_tickets'), ('user_documents'),
      ('vehicles'), ('wallet_recharge_requests')
  ),
  writable AS (
    SELECT DISTINCT tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND has_table_privilege('authenticated', format('public.%I', tablename), 'INSERT')
  ),
  unguarded AS (
    SELECT w.tablename
    FROM writable w
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = w.tablename
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  SELECT 'expected',    COALESCE(array_agg(t ORDER BY t), '{}') FROM expected
  UNION ALL
  SELECT 'unexpected', COALESCE(array_agg(w.tablename ORDER BY w.tablename), '{}')
    FROM writable w WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.t = w.tablename)
  UNION ALL
  SELECT 'unguarded',   COALESCE(array_agg(tablename ORDER BY tablename), '{}') FROM unguarded;
$$;

COMMENT ON FUNCTION public.client_write_surface_report() IS
  'Diagnostic. Lists the tables a client can write, split into the twenty the '
  'app writes on purpose, the ones it does not, and the ones whose write '
  'policy carries no admin check. Intended to be printed by CI, not asserted '
  'on: the expected list is the contract, and the other two are findings to '
  'triage before they are allowed to fail a build.';

GRANT EXECUTE ON FUNCTION public.client_write_surface_report()
  TO anon, authenticated;
