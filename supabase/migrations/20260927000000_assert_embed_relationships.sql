-- Assert that every PostgREST relationship the Flutter app embeds actually
-- exists as a foreign key on the live database.
--
-- Why this exists
-- ---------------
-- `supabase_flutter` embeds related rows with PostgREST's `select()` syntax:
--
--   .from('orders').select('id, provider_profiles(profiles(full_name))')
--
-- PostgREST can only resolve such an embed through a real foreign key. It
-- does NOT infer a relationship because two tables happen to point at the
-- same `auth.users` row. If the FK is absent the whole query fails with
-- PGRST201 ("Could not find a relationship...") — the screen errors out and,
-- before load-failure handling existed, silently rendered an empty list.
--
-- Two of these are declared without the FK in the migration set:
--
--   * provider_profiles.user_id  REFERENCES auth.users(id)   -- not profiles
--   * user_documents.user_id     REFERENCES auth.users(id)   -- not profiles
--
-- so `provider_profiles(profiles(...))` and `profiles(user_documents(...))`
-- are the two that most plausibly break. Reading the migrations cannot settle
-- it — the live database is authoritative and may carry constraints added
-- outside this repo. These functions read `pg_constraint` on the live
-- database so CI reports the truth.
--
-- ── Repair ──────────────────────────────────────────────────────────────
-- Where the FK is genuinely absent, add it rather than only complaining.
-- `provider_profiles.user_id` and `user_documents.user_id` both reference
-- `auth.users(id)`, and `profiles.id` is the auth user id as well, so
-- `user_id -> profiles.id` is the correct relationship the embed needs.
--
-- Added NOT VALID on purpose: these constraints are new, and a live table
-- may already contain rows that would violate them. NOT VALID still creates
-- the pg_constraint entry PostgREST reads to detect the relationship, but it
-- does not scan existing rows — so this cannot fail on production data or
-- lock a large table. A later VALIDATE can be done once any orphans are
-- cleared; until then new and updated rows are still checked.
--
-- Read-only apart from the two guarded constraints: the functions read the
-- catalog only, touch no application data, and return relationship NAMES,
-- which are schema, not user data.
--
-- `missing_embed_relationships()` returns the empty array when everything
-- the app embeds is present. `assert_embed_relationships_exist()` is the
-- boolean wrapper the connectivity suite already knows how to call.

DO $$
DECLARE
  has_fk boolean;
BEGIN
  -- provider_profiles.user_id -> profiles.id
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid = 'public.provider_profiles'::regclass
      AND c.confrelid = 'public.profiles'::regclass
  ) INTO has_fk;

  IF NOT has_fk THEN
    BEGIN
      ALTER TABLE public.provider_profiles
        ADD CONSTRAINT provider_profiles_user_id_profiles_fkey
        FOREIGN KEY (user_id) REFERENCES public.profiles(id) NOT VALID;
      RAISE NOTICE 'added provider_profiles.user_id -> profiles(id) (NOT VALID)';
    EXCEPTION WHEN others THEN
      RAISE WARNING 'could not add provider_profiles -> profiles FK: %', SQLERRM;
    END;
  END IF;

  -- user_documents.user_id -> profiles.id
  SELECT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.contype = 'f'
      AND c.conrelid = 'public.user_documents'::regclass
      AND c.confrelid = 'public.profiles'::regclass
  ) INTO has_fk;

  IF NOT has_fk THEN
    BEGIN
      ALTER TABLE public.user_documents
        ADD CONSTRAINT user_documents_user_id_profiles_fkey
        FOREIGN KEY (user_id) REFERENCES public.profiles(id) NOT VALID;
      RAISE NOTICE 'added user_documents.user_id -> profiles(id) (NOT VALID)';
    EXCEPTION WHEN others THEN
      RAISE WARNING 'could not add user_documents -> profiles FK: %', SQLERRM;
    END;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.missing_embed_relationships()
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH required(parent, child) AS (
    VALUES
      -- Cart and catalogue
      ('cart_items',                 'products'),
      ('products',                   'product_images'),
      ('order_items',                'products'),
      -- Order chain (used by checkout, order detail, admin disputes)
      ('orders',                     'provider_profiles'),
      ('orders',                     'order_items'),
      ('order_status_history',       'orders'),
      -- Provider / admin surfaces
      ('provider_profiles',          'profiles'),
      ('profiles',                   'user_documents'),
      ('wallet_recharge_requests',   'provider_profiles'),
      ('wallet_recharge_requests',   'payment_methods'),
      ('wallet_transactions',        'orders'),
      ('wallet_transactions',        'ride_requests')
  ),
  -- Every foreign key present in the live database, in both directions,
  -- because PostgREST embeds along an FK whichever end declares it.
  present AS (
    SELECT c.conrelid::regclass::text   AS parent,
           c.confrelid::regclass::text  AS child
    FROM pg_constraint c
    WHERE c.contype = 'f'
    UNION
    SELECT c.confrelid::regclass::text  AS parent,
           c.conrelid::regclass::text   AS child
    FROM pg_constraint c
    WHERE c.contype = 'f'
  )
  SELECT COALESCE(array_agg(r.parent || ' -> ' || r.child ORDER BY r.parent, r.child), '{}')
  FROM required r
  WHERE NOT EXISTS (
    SELECT 1 FROM present p
    WHERE p.parent = r.parent AND p.child = r.child
  );
$$;

COMMENT ON FUNCTION public.missing_embed_relationships() IS
  'Array of "parent -> child" PostgREST relationships the Flutter app embeds '
  'but which are not backed by a foreign key. Empty array means all present.';

CREATE OR REPLACE FUNCTION public.assert_embed_relationships_exist()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT cardinality(public.missing_embed_relationships()) = 0;
$$;

COMMENT ON FUNCTION public.assert_embed_relationships_exist() IS
  'True when every PostgREST relationship the app embeds is backed by a FK. '
  'Call public.missing_embed_relationships() for the failing pair names.';

-- Callable by the connectivity suite, which authenticates as `authenticated`.
-- Read-only catalog access; no application table is exposed.
GRANT EXECUTE ON FUNCTION public.missing_embed_relationships() TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_embed_relationships_exist() TO authenticated;
