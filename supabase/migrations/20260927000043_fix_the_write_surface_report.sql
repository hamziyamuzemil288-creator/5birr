-- Fix the write-surface report; it never actually reported anything.
--
-- WHAT CI SHOWED
-- -------------
-- The suite passed 35/35 on the run that first shipped it, which is exactly
-- the failure mode this function was built to avoid: a test that cannot fail
-- reports that everything is fine. The test it lives in is print-only and
-- degrades to a printed message, so the build stayed green while the report
-- printed:
--
--   write surface report unavailable:
--     PostgrestException(message: relation "public.objects" does not exist)
--
-- So for one run the entire point of this work produced no output at all, and
-- nothing flagged it except the sentence I wrote to be visible when it failed.
--
-- THE BUG
-- -------
-- The writability test was:
--
--   has_table_privilege('authenticated', format('public.%I', tablename), 'INSERT')
--
-- has_table_privilege takes the table as TEXT and resolves that text as a
-- relation name, not as a schema-qualified reference that %I can safely
-- quote. The %I wrapping produced a name it would not resolve, and the error
-- named public.objects -- a STORAGE policy that had leaked into the candidate
-- set, because the source was pg_policies, which spans every schema. So the
-- function was asking about a storage table it had no business asking about,
-- and asking about it in a way that does not resolve.
--
-- THE FIX
-- -------
-- Two changes, both about not trusting a name that came from somewhere else:
--
--   1. The candidate list now comes from information_schema.tables filtered to
--      BASE TABLE in schema public. That is a closed set of tables that exist
--      and are ordinary tables, so no storage object, view or foreign table
--      can appear in it. Deriving the list from pg_policies -- a catalog view
--      whose rows describe objects in OTHER schemas -- is what let objects in.
--
--   2. has_table_privilege is called with the bare table name, unqualified.
--      The name is now known to be a real table in public, and the function
--      runs with search_path = public, so it resolves. Inheritance is still
--      honoured, which is the reason has_table_privilege was chosen over
--      scraping role_table_grants in the first place.
--
-- AND A RULE FOR NEXT TIME
-- ------------------------
-- A diagnostic that prints cannot fail, and a suite that only prints will go
-- green while the diagnostic is dead. The fix here is that the CALLER now
-- fails when the report fails: a missing or broken report is itself a
-- finding, because the whole reason it exists is to be read. Silence from a
-- safety net should never read as good news.
--
-- Restated verbatim apart from the two changes above; the output contract
-- (kind, tables) is unchanged, so the Dart caller needs no edit.

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
  public_tables AS (
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
  'Diagnostic. Lists the tables a client can write, split into the twenty the '
  'app writes on purpose, the ones it does not, and the ones whose write '
  'policy carries no admin check. Candidate tables come from '
  'information_schema restricted to public BASE TABLEs, not from pg_policies, '
  'because pg_policies spans every schema and once let a storage object into '
  'the set. The caller fails when this fails: a broken report is a finding, '
  'not a reason to report success.';

GRANT EXECUTE ON FUNCTION public.client_write_surface_report()
  TO anon, authenticated;
