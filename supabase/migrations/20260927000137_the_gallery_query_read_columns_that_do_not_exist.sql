-- 20260927000137 — the admin image gallery queried columns that do not exist
--
-- THE REPORT
-- ----------
-- "Admin sidebar still can't load public posted images." The panel is
-- Content Control -> Public images, which reads admin_public_image_gallery()
-- (created in 20260927000126). That function cannot run at all, so the panel
-- never receives a single row and can only show its generic load error.
--
-- WHY
-- ---
-- Its vehicle branch selects from public.vehicles with:
--
--     (v.is_active IS TRUE)                       -- last column list
--     coalesce(v.updated_at, v.created_at)        -- ordering
--
-- Neither column exists on `vehicles`. The table — as created in 0022a and as
-- snapshotted FROM THE LIVE DATABASE in 0021 — is:
--
--     id, provider_id, category_id, brand, model, plate_number, color,
--     capacity, current_location, is_available, status, rating,
--     rating_count, created_at
--
-- and a `city text` column added by 20260922000000_multi_city_support. No
-- `is_active`, no `updated_at`, and no migration anywhere adds either (every
-- ALTER on `vehicles` is a primary key, a foreign key or RLS; the only other
-- ADD COLUMN is `city`).
--
-- plpgsql does not validate the SQL inside a function body at CREATE time, so
-- this compiled on deploy and failed on every call with:
--
--     ERROR: 42703: column v.is_active does not exist
--
-- which aborts the whole UNION, not just the vehicle rows.
--
-- Why the previous round of fixes did nothing
-- -------------------------------------------
-- That round made the Dart reads nullable (`row['bucket'] as String?`) and was
-- correct as far as it went — an unchecked `as String` on a RETURNS TABLE
-- column really does throw. But it could not possibly help: the failure was
-- upstream of the client, in the query the client was calling. The client
-- never received a row to mis-cast.
--
-- Why nothing caught it
-- ---------------------
-- image_moderation_signature_report() (0126) checks that the function EXISTS,
-- that its parameter names match what the client sends, and that it is not
-- overloaded. It never calls it, so a body that cannot execute passes. And
-- there is no `assert_*` covering the gallery, so nothing did. This migration
-- adds that instrument (below), which is the half that makes the fix stick.
--
-- THE FIX
-- -------
-- Use the columns the table actually has, and the visibility rule the rest of
-- the schema already uses for a vehicle:
--
--   * `is_active`  -> `v.status = 'APPROVED'`. That is how a vehicle is public
--     everywhere else: the RLS read policy in 0002_rls_policies.sql is
--     `(v.status = 'APPROVED' or owns_provider_profile(v.provider_id) or
--     is_admin())`, and the public search in 0006_search_location.sql filters
--     `and v.status = 'APPROVED'`. The gallery's `is_public` column drives the
--     hide/restore action, so it must mean the same thing it means to a buyer.
--   * `updated_at` -> `created_at`. There is no updated_at to coalesce to.
--     Every other branch orders on a real timestamp; this one does too.
--
-- The product and provider/gallery branches are untouched and unchanged: they
-- reference `products.listing_status`, `products.updated_at`, `products.city`,
-- `provider_gallery.caption` and the `profiles`/`provider_profiles` columns,
-- all of which exist. Only the vehicle branch was wrong.
--
-- Note this is a deliberate CREATE OR REPLACE of a function whose return type
-- does not change; the grants from 0126 (`authenticated`, `service_role`) are
-- re-stated at the bottom so a future edit cannot silently change them.

-- ===========================================================================
-- 1. The corrected gallery query
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.admin_public_image_gallery(
  p_city text DEFAULT '',
  p_limit integer DEFAULT 120,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  image_id uuid,
  source text,
  bucket text,
  storage_path text,
  caption text,
  is_public boolean,
  uploaded_at timestamptz,
  provider_id uuid,
  provider_name text,
  uploader_user_id uuid,
  uploader_name text,
  city text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city text := lower(btrim(coalesce(p_city, '')));
  v_limit integer := least(greatest(coalesce(p_limit, 120), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  RETURN QUERY
    -- The three image tables this project has, in the same order
    -- admin_moderate_image() tries them, and each guarded on to_regclass so a
    -- table dropped by a later migration narrows the list instead of
    -- failing the whole screen.
    SELECT g.id, 'provider_gallery'::text, 'provider-gallery'::text,
           g.storage_path, g.caption, g.is_active, g.created_at,
           g.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(pp.city, pr.city, '')
      FROM public.provider_gallery g
      JOIN public.provider_profiles pp ON pp.id = g.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE (v_city = '' OR lower(coalesce(pp.city, pr.city, '')) = v_city)

    UNION ALL

    SELECT i.id, 'product_images'::text, 'product-images'::text,
           i.storage_path, NULL::text, (p.listing_status = 'ACTIVE'),
           coalesce(p.updated_at, p.created_at),
           p.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(p.city, pp.city, '')
      FROM public.product_images i
      JOIN public.products p ON p.id = i.product_id
      JOIN public.provider_profiles pp ON pp.id = p.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE to_regclass('public.product_images') IS NOT NULL
       AND (v_city = '' OR lower(coalesce(p.city, pp.city, '')) = v_city)

    UNION ALL

    -- vehicles has NO is_active and NO updated_at. Visibility is `status`,
    -- which is what the table's own read policy and the public search use;
    -- ordering is created_at, because there is nothing else to order by.
    SELECT i.id, 'vehicle_images'::text, 'vehicle-images'::text,
           i.storage_path, NULL::text, (v.status = 'APPROVED'),
           v.created_at,
           v.provider_id, pp.business_name, pp.user_id,
           coalesce(pr.full_name, ''), coalesce(v.city, pp.city, '')
      FROM public.vehicle_images i
      JOIN public.vehicles v ON v.id = i.vehicle_id
      JOIN public.provider_profiles pp ON pp.id = v.provider_id
      LEFT JOIN public.profiles pr ON pr.id = pp.user_id
     WHERE to_regclass('public.vehicle_images') IS NOT NULL
       AND (v_city = '' OR lower(coalesce(v.city, pp.city, '')) = v_city)

    -- Newest first, so the panel opens on what arrived today rather than on
    -- the oldest upload in the system.
    ORDER BY 7 DESC
    LIMIT v_limit OFFSET v_offset;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_public_image_gallery(text, integer, integer)
  TO authenticated, service_role;

-- ===========================================================================
-- 2. The instrument that would have caught it
-- ===========================================================================
-- image_moderation_signature_report() proved the function was REACHABLE. It
-- did not prove it could RUN, and a plpgsql body is not validated at CREATE
-- time -- so "reachable but every call raises 42703" was invisible.
--
-- This report CALLS the RPC as a genuine ADMIN, using the same faked-claims
-- technique 20260927000024 already established for the wallet and order write
-- tests (set_config is_local so it is scoped to this one statement's
-- transaction, which is the boundary PostgREST gives every RPC call). It is
-- read-only: the gallery RPC is STABLE and only SELECTs, so nothing is
-- written and no rollback trick is needed.
--
-- A body that references a column that does not exist now fails this report
-- with the real Postgres error, which the connectivity suite surfaces verbatim
-- instead of "Expected: not null".
--
-- The report does not fail when there is no ADMIN account yet: that is a
-- legitimate state for a fresh project, and inventing an admin fixture would
-- be a write test in a report whose whole value is that it is read-only. It
-- says so instead.

-- VOLATILE, not STABLE: it calls set_config(). 20260927000024's write tests
-- are VOLATILE for the same reason -- a STABLE function is not the right
-- place to change a GUC, even a transaction-local one.
CREATE OR REPLACE FUNCTION public.public_image_gallery_rpc_report()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_admin uuid;
  v_rows integer;
  v_sources text;
BEGIN
  SELECT ur.user_id INTO v_admin
    FROM public.user_roles ur
   WHERE ur.role = 'ADMIN'
   LIMIT 1;

  IF v_admin IS NULL THEN
    RETURN 'ok: no ADMIN account exists yet, so admin_public_image_gallery() '
           || 'has nothing to be driven with (and nothing to show)';
  END IF;

  -- Act as that admin for the duration of this transaction only.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text,
                                       'role', 'authenticated')::text, true);

  -- The call itself is the assertion: if the body references a column that
  -- does not exist, this raises and the report never returns.
  SELECT count(*) INTO v_rows
    FROM public.admin_public_image_gallery('', 200, 0);

  SELECT coalesce(
           string_agg(t.src || '=' || t.n::text, ', ' ORDER BY t.src), 'none')
    INTO v_sources
    FROM (
      SELECT g.source AS src, count(*) AS n
        FROM public.admin_public_image_gallery('', 200, 0) AS g
       GROUP BY g.source
    ) AS t;

  -- Leave no trace of the impersonation, even though is_local already does.
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', '', true);

  RETURN format(
    'ok: admin_public_image_gallery() ran as a real ADMIN and returned %s '
    || 'row(s) -- %s',
    v_rows, v_sources);
END;
$$;

COMMENT ON FUNCTION public.public_image_gallery_rpc_report() IS
  'Calls admin_public_image_gallery() as a real ADMIN (faked request.jwt '
  'claims, scoped to this transaction) and reports what came back. Exists '
  'because a plpgsql body is not validated at CREATE time, so a query that '
  'names a column that does not exist deployed cleanly and then failed on '
  'every call -- which is exactly how the admin image gallery came to show no '
  'images at all.';

REVOKE ALL ON FUNCTION public.public_image_gallery_rpc_report()
  FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_image_gallery_rpc_report()
  TO anon, authenticated, service_role;
