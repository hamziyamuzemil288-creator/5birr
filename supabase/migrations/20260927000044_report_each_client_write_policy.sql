-- Read the actual policy, instead of inferring it from the migration files.
--
-- WHY THIS EXISTS
-- ---------------
-- The first report worked, and immediately showed that its own second bucket
-- was too crude to act on:
--
--   WRITE SURFACE [unguarded] (10): cart_items, chat_logs, driver_status,
--     email_otp_codes, favorites, notification_preferences, order_items,
--     order_messages, product_images, vehicle_images
--
-- "Unguarded" meant "no write policy mentions is_admin()". But for a table a
-- user owns, is_admin() is the WRONG check -- cart_items, favorites and
-- order_messages are correctly scoped to user_id = auth.uid(), and an admin
-- gate there would be a bug, not a fix. So that bucket mixes genuinely wide
-- policies with correctly owner-scoped ones, and nine of the ten are noise.
--
-- The one that matters, email_otp_codes, is WITH CHECK (true) with no SELECT,
-- UPDATE or DELETE -- anonymous signup has to request a code before it has a
-- session, so it is a deliberate decision, not an oversight. Judging that
-- required reading the policy, and reading the policy required the
-- migrations, and the migrations cannot be trusted for this: 20260927000014
-- drops a policy that 0002 created, and only the database knows which won.
--
-- So this stops classifying and starts quoting. It returns the command and the
-- policy expression for every write policy on every client-writable table, so
-- the judgement is made against what the database actually enforces rather
-- than against a guess about it. Guessing is what produced a bucket that was
-- 90% wrong and would have invited revoking a correctly owner-scoped policy.
--
-- Still a diagnostic. It reports; it does not assert, because the judgement
-- about whether a given policy is correct is a product decision, and a
-- machine that second-guesses it is worse than one that shows the text.

CREATE OR REPLACE FUNCTION public.client_write_policy_detail()
RETURNS TABLE (
  table_name text,
  cmd text,
  policy_name text,
  qual text,
  verdict text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH public_tables AS (
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND has_table_privilege('authenticated', t.table_name, 'INSERT')
  ),
  writes AS (
    SELECT p.tablename, p.policyname, p.cmd, p.qual
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND p.tablename IN (SELECT table_name FROM public_tables)
  )
  SELECT
    w.tablename,
    w.cmd,
    w.policyname,
    lower(regexp_replace(replace(coalesce(w.qual, ''), 'public.', ''), '\s+', '', 'g')),
    -- A label to sort by, NOT a verdict. "wide" means the policy does not
    -- mention the caller at all, which is the only case where nothing in it
    -- ties the write to a person or an administrator.
    CASE
      WHEN lower(regexp_replace(replace(coalesce(w.qual, ''), 'public.', ''), '\s+', '', 'g'))
           ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
        THEN 'scoped'
      ELSE 'WIDE'
    END
  FROM writes w
  ORDER BY
    -- widest first: those are the ones a human needs to look at
    (lower(regexp_replace(replace(coalesce(w.qual, ''), 'public.', ''), '\s+', '', 'g'))
       ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)') ASC,
    w.tablename,
    w.cmd;
$$;

COMMENT ON FUNCTION public.client_write_policy_detail() IS
  'Diagnostic. For every write policy on a client-writable public table, the '
  'table, the command, the policy name and the normalised policy expression, '
  'labelled scoped or WIDE. WIDE means the expression never mentions the '
  'caller -- no auth.uid, no is_admin, no ownership helper -- so nothing in it '
  'ties the write to a person. It is a sorting label, not a judgement: whether '
  'a given policy is correct is a product decision, and email_otp_codes is the '
  'standing example of a wide policy that is deliberate and right.';

GRANT EXECUTE ON FUNCTION public.client_write_policy_detail()
  TO anon, authenticated;
