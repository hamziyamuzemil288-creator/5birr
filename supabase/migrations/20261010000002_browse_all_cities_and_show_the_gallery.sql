-- 20261010000002 — browse every city at once, and let the feed show published
-- gallery photos
-- =============================================================================
--
-- WHY
-- ---
-- Two things the customer could not do:
--
--   1. BROWSE ALL CITIES TOGETHER. The city chip only ever offered a specific
--      city, so there was no "combined" view — the audience that wants to see
--      what is on the platform rather than what is within one town had to pick
--      one. The browse city is now allowed to be EMPTY, meaning "every city",
--      and both city-scoped reads below treat an empty/NULL city as "do not
--      filter". The client already passes NULL for search_products when the
--      browse city is empty (that function's own `p_city IS NULL` arm), so only
--      the two reads here needed the rule.
--
--   2. SEE A PROVIDER'S PUBLISHED GALLERY IN THE FEED. A photo added to
--      `provider_gallery` (add_gallery_image, is_active = true) was only ever
--      visible as one provider tile's image, and only for the providers
--      `ranked_providers` happened to return. A provider outside that rail could
--      upload a photo and have it appear nowhere a buyer browses.
--      `visible_gallery_for_city` is the read the home feed needs: the same
--      published set the RLS policy `provider_gallery_public_read` already
--      defines (is_active AND the owner's account is APPROVED), with the
--      uploader's name and city attached so a tile can say whose it is and the
--      list can be scoped to the browse city.
--
-- Both functions are READ-ONLY and add no write anywhere.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. An empty browse city means every city
-- ---------------------------------------------------------------------------

create or replace function public.visible_products_for_city(
  p_city text,
  p_category_id uuid default null
)
returns setof public.products
language sql
stable
as $$
  select p.*
  from public.products p
  where p.is_active
    -- An EMPTY (or NULL) city is "all cities", not "the city named ''". Every
    -- existing caller passes a real city, so this only widens the call that
    -- asks for the combined view.
    and (coalesce(btrim(p_city), '') = '' or p.city is null or p.city = p_city)
    and (
      p_category_id is null
      or p.category_id = p_category_id
      or p.category_id in (
        select c.id from public.categories c where c.parent_id = p_category_id
      )
    )
  order by p.sales_count desc nulls last, p.created_at desc
  limit 100;
$$;

grant execute on function public.visible_products_for_city(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The published gallery, for the feed
-- ---------------------------------------------------------------------------

create or replace function public.visible_gallery_for_city(
  p_city text default '',
  p_limit integer default 60
)
returns table (
  image_id uuid,
  provider_id uuid,
  storage_path text,
  caption text,
  business_name text,
  city text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select g.id,
         g.provider_id,
         g.storage_path,
         g.caption,
         coalesce(pp.business_name, ''),
         coalesce(pp.city, pr.city, ''),
         g.created_at
    from public.provider_gallery g
    join public.provider_profiles pp on pp.id = g.provider_id
    left join public.profiles pr on pr.id = pp.user_id
   where g.is_active = true
     and pp.status = 'APPROVED'::account_status
     -- Empty/NULL city is "all cities", the same rule the product read uses.
     and (coalesce(btrim(p_city), '') = ''
          or lower(coalesce(pp.city, pr.city, '')) = lower(btrim(p_city)))
   order by g.created_at desc
   limit least(greatest(coalesce(p_limit, 60), 1), 200);
$$;

comment on function public.visible_gallery_for_city(text, integer) is
  'The published provider-gallery photos a buyer may see (is_active and the '
  'owner APPROVED), with the uploader''s name and city, optionally scoped to '
  'one city. Empty/NULL p_city means every city. Read-only.';

revoke all on function public.visible_gallery_for_city(text, integer) from public, anon;
grant execute on function public.visible_gallery_for_city(text, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
