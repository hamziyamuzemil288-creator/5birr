-- =========================================================
-- 0031 FIX VERIFICATION + REPAIR — profiles ↔ user_documents FK
-- Run the WHOLE FILE in Supabase SQL Editor. It is safe to re-run.
-- The final SELECT is the pass/fail signal.
--
-- Background: the admin User Management screen queries
--   profiles select('*, user_documents(...)')
-- PostgREST can only resolve that embed through a declared FK
--   user_documents.user_id -> profiles.id  (public schema)
-- The pre-existing FK goes to auth.users instead, which is NOT
-- exposed to PostgREST, so the embed fails with PGRST200.
-- Migration 0031 (repo: supabase/migrations/0031_admin_visibility_fix.sql)
-- adds the missing FK — but it must be EXECUTED against the live
-- project (SQL Editor) and the schema cache reloaded afterwards.
-- =========================================================

-- ── STEP 1: current state of the three constraints ──────────
select conname, conrelid::regclass as "on table", confrelid::regclass as "references"
from pg_constraint
where conname in (
  'profiles_id_fkey',               -- profiles.id -> auth.users (pre-existing)
  'user_documents_profile_fkey',    -- user_documents.user_id -> profiles  (0031)
  'provider_profiles_profile_fkey'  -- provider_profiles.user_id -> profiles (0031)
)
order by conname;
-- Expect 3 rows. 'user_documents_profile_fkey' missing = 0031 never ran.

-- ── STEP 2: orphan check (must be 0/0 before the FK can be added) ──
select
  (select count(*) from user_documents d
     left join profiles p on p.id = d.user_id where p.id is null) as orphan_docs,
  (select count(*) from provider_profiles pp
     left join profiles p on p.id = pp.user_id where p.id is null) as orphan_providers;
-- If nonzero: paste the output back to me before running STEP 3.

-- ── STEP 3: add the missing FKs (idempotent, exception-guarded) ──
DO $$ BEGIN
  IF NOT EXISTS (
    select 1 from pg_constraint
    where conname = 'profiles_id_fkey'
      and conrelid = 'public.profiles'::regclass
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_id_fkey
      FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'profiles_id_fkey not added: orphan profiles rows exist';
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    select 1 from pg_constraint
    where conname = 'provider_profiles_profile_fkey'
      and conrelid = 'public.provider_profiles'::regclass
  ) THEN
    ALTER TABLE public.provider_profiles
      ADD CONSTRAINT provider_profiles_profile_fkey
      FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'provider_profiles_profile_fkey not added: orphan provider_profiles rows exist';
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    select 1 from pg_constraint
    where conname = 'user_documents_profile_fkey'
      and conrelid = 'public.user_documents'::regclass
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_profile_fkey
      FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
EXCEPTION WHEN foreign_key_violation THEN
  RAISE WARNING 'user_documents_profile_fkey not added: orphan user_documents rows exist';
END $$;

-- Backfill safety net (idempotent): heal any registration missing its
-- profile / role / approval_request rows, per migration 0031.
INSERT INTO public.profiles (id, full_name, email, status)
SELECT u.id,
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

-- ── STEP 4: refresh PostgREST schema cache (CRITICAL — without this
--    the API keeps the old schema even with the FKs in place) ──
NOTIFY pgrst, 'reload schema';

-- ── STEP 5: pass/fail signal ────────────────────────────────
select conname
from pg_constraint
where conname in (
  'profiles_id_fkey',
  'user_documents_profile_fkey',
  'provider_profiles_profile_fkey'
)
order by conname;
-- PASS = exactly 3 rows. Then reopen the admin User Management screen:
-- Pending / Approved / Rejected tabs all load, and 'View National ID'
-- opens the document via a 5-minute signed URL.
-- If the Flutter app still shows PGRST200 after this, wait ~30s
-- (cache propagation) and fully restart the app.
