-- Stop clients holding write privileges on tables that are server-write-only.
--
-- WHAT CI SHOWED
-- -------------
-- 20260927000040 replaced the broken warnings assertion with one that checks
-- the real protection, and it fired immediately:
--
--   authenticated holds INSERT on public.staff_warnings, so a staff member
--   can write a warning row directly
--
-- WHICH IS TRUE, AND WAS NOT SUPPOSED TO BE
-- ------------------------------------------
-- 20260927000033 said what it meant:
--
--   REVOKE ALL ON public.staff_warnings FROM anon;
--   GRANT SELECT ON public.staff_warnings TO authenticated;
--
-- "authenticated may SELECT" reads as a complete statement about what
-- authenticated may do. It is not. Supabase puts default privileges on the
-- public schema that grant ALL on new tables to anon, authenticated and
-- service_role, so by the time that GRANT ran the table already carried
-- INSERT, UPDATE and DELETE for authenticated. Granting SELECT on top of an
-- existing ALL grant adds nothing and removes nothing.
--
-- The REVOKE for anon worked, which is why this stayed invisible: anon was
-- cleaned up and authenticated was not.
--
-- IS ANYBODY ACTUALLY EXPLOITABLE?
-- --------------------------------
-- No, and this is not an active hole. RLS is enabled on these tables and
-- there is no write policy, so a client INSERT is refused by RLS even
-- though it holds the privilege. The write is stopped one layer further out
-- than intended.
--
-- But that is exactly the condition worth fixing. A single missing RLS
-- policy -- one migration that adds a FOR ALL policy "just to fix a bug",
-- one careless GRANT -- turns a currently-unreachable privilege into a live
-- one, with no other layer in the way. Defence in depth is the whole reason
-- the table grant exists at all; leaving it broad means the RLS policy is
-- the only thing standing between a staff member and the warnings table.
--
-- The explicit REVOKE also makes the schema state match the comment that has
-- always described it, so the next reader is not misled a second time.
--
-- NOT REACHED, ON PURPOSE
-- -----------------------
-- Verified before writing this: no client code inserts, updates or deletes
-- any of these tables. Every write goes through a SECURITY DEFINER RPC
-- (warn_staff, acknowledge_staff_warning, set_staff_jobs, and the gateway
-- RPCs), and a definer function runs as the owner, so it is unaffected by
-- these revokes. Reads are untouched -- SELECT is deliberately preserved,
-- because the staff dashboard reads staff_warnings directly and the auth
-- provider reads staff_credentials directly.
--
-- service_role is NOT revoked from. It bypasses RLS by design and is used by
-- the Edge Functions; narrowing it is a separate decision with its own risk.

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.staff_warnings FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.staff_job_assignments FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.staff_activity_log FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.staff_credentials FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.staff_task_completions FROM anon, authenticated;

COMMENT ON TABLE public.staff_warnings IS
  'Warnings between a manager and a staff member. Read directly by the '
  'subject (SELECT is granted to authenticated); written only through '
  'warn_staff() and acknowledge_staff_warning(). The explicit REVOKE of '
  'write privileges is deliberate and load-bearing: Supabase default '
  'privileges grant ALL on new public tables, so "GRANT SELECT" alone leaves '
  'authenticated holding INSERT. RLS is the only remaining barrier, and this '
  'table is one careless policy away from a staff member writing their own '
  'warnings.';

-- Kept deliberately narrow rather than expressed as a loop over every table
-- in the schema: this is the set whose writers are all server-side, and it
-- has been checked against the client code. Widening it to "every table
-- Supabase granted by default" would be a much larger change to the live
-- database than this finding justifies, and it is recorded as a follow-up
-- rather than smuggled in here.
