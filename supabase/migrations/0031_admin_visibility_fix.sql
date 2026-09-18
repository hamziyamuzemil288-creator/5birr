-- 5BIRR — Admin visibility fix: restore PostgREST embedded queries
-- Migration 0031_admin_visibility_fix.sql
--
-- SYMPTOM
--   New pending registrations (USER and PROVIDER) never appear in the admin
--   panel. Dashboard pending counters stay at 0 and no "Requires Attention"
--   cards render — even though signup correctly creates profiles /
--   provider_profiles / approval_requests rows in PENDING_APPROVAL state.
--
-- ROOT CAUSE (verified against live schema snapshot 0021)
--   PostgREST resolves `select('*, child_table(...)')` embedded queries ONLY
--   through declared foreign keys between the two tables. Three such
--   relationships were missing or pointed the wrong way:
--
--   1. user_documents.user_id  -> auth.users(id)   (0001)
--      Admin user screen queries profiles + embedded user_documents —
--      no FK profiles.id -> user_documents.user_id exists → PGRST200,
--      the whole profiles query fails.
--   2. provider_profiles.user_id -> auth.users(id) (line 499 of snapshot)
--      Admin provider screen queries provider_profiles + embedded profiles —
--      no FK provider_profiles.user_id -> profiles.id exists → PGRST200,
--      the whole provider_profiles query fails.
--   3. profiles.id had no FK to auth.users at all, so the chain
--      provider_profiles.user_id -> profiles.id -> auth.users.id could not
--      be declared in a way PostgREST understands.
--
--   The Flutter admin screens swallow every query error (empty catch), so
--   these failures rendered as "No users found" / "No providers found"
--   instead of an error — hiding the disconnect.
--
-- FIX
--   1. Backfill profiles (+ USER role) for any auth.users row missing one.
--   2. Backfill missing PENDING_APPROVAL approval_requests rows for both
--      subject types (heals any registration stuck invisible).
--   3. Add the three FKs above (idempotent, exception-guarded), giving
--      PostgREST the relationships the admin screens embed on:
--        profiles(id)                      -> auth.users(id)
--        provider_profiles.user_id         -> profiles(id)   [second FK; the
--        user_documents.user_id              auth.users FK stays]
--   4. Reload the PostgREST schema cache.

-- =========================================================
-- 1. BACKFILL missing profiles for auth.users rows
-- =========================================================
INSERT INTO public.profiles (id, full_name, email, status)
SELECT
  u.id,
  COALESCE(u.raw_user_meta_data ->> 'full_name', u.email, 'New User'),
  u.email,
  'PENDING_APPROVAL'::account_status
FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id);

INSERT INTO public.user_roles (user_id, role)
SELECT u.id, 'USER'::app_role
FROM auth.users u
WHERE NOT EXISTS (
  SELECT 1 FROM public.user_roles ur WHERE ur.user_id = u.id AND ur.role = 'USER'
);

-- =========================================================
-- 2. BACKFILL missing PENDING_APPROVAL approval_requests rows
--    (heals registrations from the era when reads were broken)
-- =========================================================
INSERT INTO public.approval_requests (subject_type, subject_id, status)
SELECT 'USER', p.id, 'PENDING_APPROVAL'::account_status
FROM public.profiles p
WHERE p.status = 'PENDING_APPROVAL'
  AND NOT EXISTS (
    SELECT 1 FROM public.approval_requests ar
    WHERE ar.subject_type = 'USER' AND ar.subject_id = p.id
  );

INSERT INTO public.approval_requests (subject_type, subject_id, status)
SELECT 'PROVIDER', pp.id, 'PENDING_APPROVAL'::account_status
FROM public.provider_profiles pp
WHERE pp.status = 'PENDING_APPROVAL'
  AND NOT EXISTS (
    SELECT 1 FROM public.approval_requests ar
    WHERE ar.subject_type = 'PROVIDER' AND ar.subject_id = pp.id
  );

-- =========================================================
-- 3. FK relationships for PostgREST embeds (idempotent)
-- =========================================================

-- 3a. profiles.id -> auth.users(id): root of the embed chain.
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'profiles_id_fkey'
      AND conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_id_fkey
      FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'profiles_id_fkey not added: orphan profiles rows exist';
END $$;

-- 3b. provider_profiles.user_id -> profiles(id)
--     (second FK on the column; the auth.users FK is kept untouched)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'provider_profiles_profile_fkey'
      AND conrelid = 'public.provider_profiles'::regclass
  ) THEN
    ALTER TABLE public.provider_profiles
      ADD CONSTRAINT provider_profiles_profile_fkey
      FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'provider_profiles_profile_fkey not added: orphan provider_profiles rows exist';
END $$;

-- 3c. user_documents.user_id -> profiles(id)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'user_documents_profile_fkey'
      AND conrelid = 'public.user_documents'::regclass
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_profile_fkey
      FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'user_documents_profile_fkey not added: orphan user_documents rows exist';
END $$;

-- Supporting indexes for the new FK targets (idempotent)
CREATE INDEX IF NOT EXISTS idx_provider_profiles_user_id ON public.provider_profiles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_documents_profile_id ON public.user_documents(user_id);

-- =========================================================
-- 4. Reload PostgREST schema cache so the new embeds resolve
-- =========================================================
NOTIFY pgrst, 'reload schema';
