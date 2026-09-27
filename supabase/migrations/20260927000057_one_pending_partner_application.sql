-- "Become a Partner": an existing user applies to become a provider.
--
-- WHAT THIS DOES NOT DO
-- ---------------------
-- It does not invent an application pipeline. handle_new_provider_profile()
-- (trg_provider_profiles_auto_setup) already does everything a provider
-- application needs the moment a provider_profiles row appears:
--
--   INSERT INTO user_roles (user_id, role) VALUES (new.user_id, new.provider_type)
--     ON CONFLICT (user_id, role) DO NOTHING;
--   INSERT INTO approval_requests (subject_type, subject_id, status)
--     VALUES ('PROVIDER', new.id, 'PENDING_APPROVAL') ON CONFLICT DO NOTHING;
--
-- So a partner application is an ordinary provider_profiles insert and the
-- existing trigger does the rest. That ON CONFLICT DO NOTHING on user_roles is
-- what answers the founder's question about a user who already holds USER:
-- the row is added alongside, never in place of it, so an existing customer
-- keeps their user access and simply gains provider access on approval. No
-- code change is needed for that, and adding any would risk losing the role.
--
-- WHY A FUNCTION ANYWAY
-- --------------------
-- Two reasons, and both are enforcement that a bare client insert cannot give:
--
--   1. prevent_provider_insert_privilege_escalation() already forces
--      user_id = auth.uid() and status = 'PENDING_APPROVAL', so the interesting
--      fields are already safe. What is NOT enforced anywhere is the one-open-
--      application rule below, and a rule that lives only in the Flutter screen
--      is a rule a second client can ignore.
--   2. It is the same shape request_account_deletion() uses, so both new
--      self-service entry points read alike.
--
-- THE ONE-PENDING RULE
-- --------------------
-- A partial unique index, so it holds in the database and not in the app:

--   * it blocks only WHILE a request is PENDING, so a person whose application
--     was rejected may simply apply again, and an approved provider may add a
--     second provider type;
--   * it is scoped to user_id, so two different people applying at the same
--     moment never collide;
--   * signup is unaffected -- handle_new_user() inserts exactly one row.

CREATE UNIQUE INDEX IF NOT EXISTS uq_provider_profiles_one_pending_per_user
  ON public.provider_profiles(user_id)
  WHERE status = 'PENDING_APPROVAL'::account_status;

COMMENT ON INDEX public.uq_provider_profiles_one_pending_per_user IS
  'One open partner application per person. Partial on PENDING_APPROVAL so a '
  'rejected applicant can try again and an approved provider can add a second '
  'provider type. Enforced here rather than in the app so a second client '
  'cannot spam applications.';

-- A unique-index violation surfaces to the user as a constraint name. This
-- trigger turns it into the same sentence the rest of the app raises, and it
-- is what the Dart layer matches on. The index remains the actual invariant:
-- the trigger only improves the message.
CREATE OR REPLACE FUNCTION public.prevent_duplicate_partner_application()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.provider_profiles p
     WHERE p.user_id = NEW.user_id
       AND p.status = 'PENDING_APPROVAL'::account_status
  ) THEN
    RAISE EXCEPTION 'ALREADY_HAS_PENDING_PARTNER_APPLICATION';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_profiles_one_pending ON public.provider_profiles;
CREATE TRIGGER trg_provider_profiles_one_pending
  BEFORE INSERT ON public.provider_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_duplicate_partner_application();

-- ===========================================================================
-- Submit a partner application
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.submit_partner_application(
  p_provider_type text,
  p_business_name text,
  p_business_description text DEFAULT NULL,
  p_owner_national_id text DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_kebele text DEFAULT NULL,
  p_street_road text DEFAULT NULL
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile public.provider_profiles;
  v_type public.app_role;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_business_name IS NULL OR length(btrim(p_business_name)) < 2 THEN
    RAISE EXCEPTION 'BUSINESS_NAME_REQUIRED';
  END IF;

  -- Validate the TEXT before casting. `some_text::app_role` does not return
  -- NULL for an unknown value, it raises `invalid input value for enum`, so a
  -- cast-first version would surface a driver error instead of the message
  -- this screen knows how to show.
  --
  -- An allowlist, not a denylist: the two self-service provider types are the
  -- only ones that can be applied for. ADMIN is a role a person is granted,
  -- never one a button can request, and staff membership lives in the `staff`
  -- table rather than in app_role at all -- so there is nothing else to
  -- enumerate, and a role added to the enum later is refused by default rather
  -- than silently becoming self-service.
  IF btrim(coalesce(p_provider_type, '')) NOT IN ('SERVICE_PROVIDER', 'VEHICLE_PROVIDER') THEN
    RAISE EXCEPTION 'INVALID_PROVIDER_TYPE';
  END IF;

  v_type := btrim(p_provider_type)::public.app_role;

  INSERT INTO public.provider_profiles
    (user_id, provider_type, business_name, business_description,
     owner_national_id, status, city, kebele, street_road)
  VALUES
    (auth.uid(), v_type, btrim(p_business_name),
     NULLIF(btrim(coalesce(p_business_description, '')), ''),
     NULLIF(btrim(coalesce(p_owner_national_id, '')), ''),
     'PENDING_APPROVAL'::account_status,
     NULLIF(btrim(coalesce(p_city, '')), ''),
     NULLIF(btrim(coalesce(p_kebele, '')), ''),
     NULLIF(btrim(coalesce(p_street_road, '')), ''))
  RETURNING * INTO v_profile;

  -- Deliberately not written here: user_roles and approval_requests. The
  -- trg_provider_profiles_auto_setup trigger fires on this insert and does
  -- both, which is the same path a fresh provider signup takes. Writing them
  -- again here would duplicate the approval request.
  RETURN v_profile;
END;
$$;

COMMENT ON FUNCTION public.submit_partner_application IS
  'Become a Partner. Inserts a PENDING_APPROVAL provider_profiles row and lets '
  'trg_provider_profiles_auto_setup grant the provider role and open the '
  'approval request, exactly as signup does. An existing USER role is kept: the '
  'trigger adds the provider role with ON CONFLICT DO NOTHING.';

REVOKE ALL ON FUNCTION public.prevent_duplicate_partner_application() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_partner_application(text, text, text, text, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.submit_partner_application(text, text, text, text, text, text, text)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
