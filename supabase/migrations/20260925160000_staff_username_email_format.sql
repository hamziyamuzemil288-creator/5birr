-- 0045 — accept an email address as a staff username.
--
-- Task: the product's real login identity is an email everywhere else, so a
-- staff username that cannot look like an email is confusing. Accept BOTH
-- shapes rather than replacing the old one: every staff account created
-- before this migration has a bare-name username, and those rows are already
-- in the table. A stricter CHECK here would invalidate them, and the unique
-- index is on lower(username), so the two forms must coexist.
--
-- This constraint is the last line of defence; the gateways re-validate the
-- same rule in _shared/staff_identity.ts. The Dart mirror is
-- kStaffUsernamePattern in lib/core/services/staff_admin_service.dart.
--
-- The companion change (not part of this file) is the synthetic auth email.
-- staff-create-gateway used to build `${username}@staff-gateway.invalid`,
-- which produces a malformed address for an email username, so both
-- gateways now derive the email from the username's SHAPE: a bare name maps
-- to the original synthetic address unchanged, so existing staff keep
-- logging in with no re-key and no password reset; an email maps to a
-- hashed, fixed-shape local part. This migration only widens the CHECK that
-- would otherwise reject the new form.

-- Idempotent: drop the old constraint by name if present, then re-add the
-- widened version. ADD CONSTRAINT IF NOT EXISTS is not supported on
-- PostgreSQL, so the DROP guards the re-run.
ALTER TABLE public.staff_credentials
  DROP CONSTRAINT IF EXISTS staff_credentials_username_check;

ALTER TABLE public.staff_credentials
  ADD CONSTRAINT staff_credentials_username_check
  CHECK (
    -- original form, unchanged, so every existing row stays valid
    username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'
    -- email form: case-insensitive, no spaces, needs a dotted domain
    OR username ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$'
  );

COMMENT ON CONSTRAINT staff_credentials_username_check
  ON public.staff_credentials IS
  'Username is either the original bare form (^[a-z0-9][a-z0-9._-]{2,31}$) or an email address. Both are accepted so staff created before 0045 remain valid.';
