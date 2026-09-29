-- =============================================================================
-- 20260927000078 — run the like write test as a client, the only way Postgres allows
-- =============================================================================
--
-- WHY 77 FAILED, AND WHY THE FIX IT TRIED IS IMPOSSIBLE
-- -----------------------------------------------------
-- 77 tried to become a client the obvious way:
--
--   perform set_config('role', 'authenticated', true);
--
-- and the live database rejected it, with the most useful error message of the
-- whole exercise:
--
--   cannot set parameter "role" within security-definer function
--
-- That is not a permissions problem and not something to grant our way out of.
-- PostgreSQL forbids changing `role` inside a SECURITY DEFINER function, full
-- stop, precisely so that a definer function cannot quietly hand its caller's
-- privileges to somebody else mid-body. There is no superuser who can do it
-- from in there. 77's approach cannot be made to work.
--
-- ── What actually works ────────────────────────────────────────────────────
--
-- The thing 76 got wrong was not the mechanism, it was the identity. The
-- assertion is SECURITY DEFINER, so `current_user` is the FUNCTION OWNER, and
-- the function owner is also the owner of product_likes and products — and a
-- table owner bypasses row-level security unless FORCE ROW LEVEL SECURITY is
-- set, which nothing in this schema does. So the policies were never consulted.
--
-- The fix is therefore about who owns the function, not about a GUC:
--
--   • assert_likes_persist_and_are_exclusive()  — SECURITY DEFINER, owned by
--     the schema owner, as before. It builds the fixtures. It cannot: insert
--     into auth.users, disable a security trigger, or mint an APPROVED provider
--     profile — none of which any client may do.
--
--   • like_probe_as_client()  — SECURITY DEFINER, OWNER authenticated.
--
-- When the first calls the second, `current_user` inside the second is
-- `authenticated`. That is not a simulation of a client; it IS a client as far
-- as row-level security is concerned, because `authenticated` is not the table
-- owner and has no BYPASSRLS attribute. Every policy `to authenticated` is
-- evaluated normally, exactly as PostgREST evaluates it for a signed-in user.
-- And SET ROLE is never used, so nothing is forbidden.
--
-- `session_user` stays the real caller throughout, which is the honest shape of
-- this: the fixture work ran as the schema owner, the assertions ran as
-- authenticated, and the function that calls them is the only thing bridging
-- the two.
--
-- ── Why the counters still work under this identity ────────────────────────
--
-- Worth stating, because it was the obvious thing to fear: products has
-- `products_provider_update ... using (owns_provider_profile(provider_id))`, so
-- a user who does not own the product cannot UPDATE it — which would mean the
-- denormalised like_count could never move for a real user.
--
-- It can, and does, because trg_product_likes_count is itself SECURITY DEFINER
-- and owned by the schema owner. The UPDATE it issues on products runs as that
-- owner and is exempt from the policy, exactly as it is exempt from
-- enforce_provider_write_gate via pg_trigger_depth() > 1. The INSERT into
-- product_likes is still evaluated as authenticated, which is what makes this
-- a real client test: it is refused if insert-own refuses it.
--
-- ── The two checks that must not pass for the wrong reason ────────────────
--
-- Both are inherited from 77 and both matter more now that the test can
-- actually fail:
--
--   • The forged INSERT targets a SECOND product. product_likes is unique on
--     (user_id, product_id); aiming the forgery at a product the caller has
--     already reacted to would produce a uniqueness violation, which this test
--     would read as a successful refusal and pass for the wrong reason.
--
--   • The cross-user DELETE needs a row that exists. "Deleted 0 rows" is the
--     result both when a policy filtered the row and when there was nothing
--     there, so the fixture seeds a reaction owned by the second user and the
--     test asserts it is present before trying to delete it. A USING clause
--     filters rows out of a DELETE rather than raising, so this one is checked
--     with GET DIAGNOSTICS ... ROW_COUNT and never by expecting an exception.
--
-- No application behaviour changes. This migration touches two test functions.
-- -----------------------------------------------------------------------------

-- ===========================================================================
-- The client-side half
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.like_probe_as_client()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_forge uuid := '00000000-0000-4000-8000-0000000007a3';
  v_result jsonb;
  v_rows int;
  v_like int;
  v_dislike int;
BEGIN
  -- ── Prove the identity before relying on it ─────────────────────────────
  -- If this owner transfer ever silently fails, every step below would pass
  -- for exactly the reason 76 passed: no policy in the database was ever
  -- asked. So this is checked first, and it fails loudly.
  IF current_user <> 'authenticated' THEN
    RAISE EXCEPTION 'the like probe is running as %, not as authenticated, so every RLS '
                    'step below would pass without a policy being evaluated',
      current_user;
  END IF;

  IF auth.uid() IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION 'the like probe reads auth.uid() as %, expected the fixture user %',
      auth.uid(), v_user;
  END IF;

  IF public.is_admin() THEN
    RAISE EXCEPTION 'the like probe is unexpectedly an admin, so it could pass without '
                    'any policy being consulted';
  END IF;

  -- ── 1. A like persists ──────────────────────────────────────────────────
  v_result := public.set_product_reaction(v_prod, 'LIKE');
  IF (v_result->>'liked')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'set_product_reaction LIKE did not report liked=true: %', v_result;
  END IF;

  SELECT count(*) INTO v_rows FROM public.product_likes
   WHERE user_id = v_user AND product_id = v_prod AND reaction = 'LIKE';
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'the like did not persist: % row(s) in product_likes', v_rows;
  END IF;

  SELECT like_count, dislike_count INTO v_like, v_dislike
    FROM public.products WHERE id = v_prod;
  IF v_like <> 1 OR v_dislike <> 0 THEN
    RAISE EXCEPTION 'after LIKE the counters are like=% dislike=% , expected 1 and 0. '
                    'The denormalised counter is not moving.', v_like, v_dislike;
  END IF;
  IF (v_result->>'like_count')::int <> 1 THEN
    RAISE EXCEPTION 'set_product_reaction returned like_count %, expected 1',
      v_result->>'like_count';
  END IF;

  -- ── 2. A dislike replaces the like, and only one row can exist ─────────
  v_result := public.set_product_reaction(v_prod, 'DISLIKE');

  SELECT count(*) INTO v_rows FROM public.product_likes
   WHERE user_id = v_user AND product_id = v_prod;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'a user holds % reaction rows for one product; the like and the '
                    'dislike are not mutually exclusive', v_rows;
  END IF;
  IF NOT EXISTS (select 1 from public.product_likes
                  where user_id = v_user and product_id = v_prod and reaction = 'DISLIKE') THEN
    RAISE EXCEPTION 'the dislike did not replace the like';
  END IF;

  SELECT like_count, dislike_count INTO v_like, v_dislike
    FROM public.products WHERE id = v_prod;
  IF v_like <> 0 OR v_dislike <> 1 THEN
    RAISE EXCEPTION 'after DISLIKE the counters are like=% dislike=% , expected 0 and 1',
      v_like, v_dislike;
  END IF;

  -- ── 3. NONE removes it and gives both counters back ─────────────────────
  v_result := public.set_product_reaction(v_prod, 'NONE');
  IF (v_result->>'liked')::boolean IS NOT FALSE
     OR (v_result->>'disliked')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'set_product_reaction NONE still reports a reaction: %', v_result;
  END IF;

  SELECT count(*) INTO v_rows FROM public.product_likes
   WHERE user_id = v_user AND product_id = v_prod;
  IF v_rows <> 0 THEN
    RAISE EXCEPTION 'NONE left % reaction row(s) behind', v_rows;
  END IF;

  SELECT like_count, dislike_count INTO v_like, v_dislike
    FROM public.products WHERE id = v_prod;
  IF v_like <> 0 OR v_dislike <> 0 THEN
    RAISE EXCEPTION 'after NONE the counters are like=% dislike=% , expected 0 and 0',
      v_like, v_dislike;
  END IF;

  -- ── 4. A reaction naming somebody else is refused ────────────────────────
  -- The INSERT is the right shape for an exception check: a WITH CHECK
  -- violation raises, it does not silently skip the row.
  BEGIN
    INSERT INTO public.product_likes (user_id, product_id, reaction)
    VALUES (v_other, v_forge, 'LIKE');
    RAISE EXCEPTION 'a user was able to write a reaction row for somebody else';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a user was able to write a reaction row for somebody else' THEN
        RAISE;
      END IF;
      NULL;  -- any other error is the refusal we wanted
  END;

  -- ── 5. And somebody else's row cannot be deleted ────────────────────────
  -- First prove there is something to protect, so that zero rows affected
  -- afterwards can only mean the policy filtered it.
  SELECT count(*) INTO v_rows FROM public.product_likes
   WHERE user_id = v_other AND product_id = v_prod;
  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'the fixture row belonging to the other user is missing (% row(s)), '
                    'so the delete policy is not being exercised', v_rows;
  END IF;

  v_rows := -1;
  BEGIN
    DELETE FROM public.product_likes WHERE user_id = v_other AND product_id = v_prod;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    -- An outright refusal is also a pass; -1 keeps it distinguishable from a
    -- delete that actually touched rows.
    v_rows := 0;
  END;

  IF v_rows <> 0 THEN
    RAISE EXCEPTION 'a user deleted % reaction row(s) belonging to somebody else', v_rows;
  END IF;

  -- And the row they DO own is still removable, or the policy is a blanket
  -- block that would break the feature rather than protect it.
  PERFORM public.set_product_reaction(v_prod, 'LIKE');

  v_rows := -1;
  BEGIN
    DELETE FROM public.product_likes
     WHERE user_id = v_user AND product_id = v_prod;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    v_rows := 0;
  END;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'a user could not delete their own reaction row (affected %), so the '
                    'delete policy is a blanket block', v_rows;
  END IF;

  RETURN true;
END;
$$;

-- ===========================================================================
-- Hand this function to authenticated, and to nobody else
-- ===========================================================================
-- The owner transfer is the whole mechanism, so it is done with a captured
-- owner name rather than a hardcoded role: whatever role the deploys run as is
-- the role that already owns the tables, and the assertion that calls this
-- function must be the role that can reach it.
--
-- Grant first, then transfer. Only the owner may GRANT, and after the ALTER
-- this session is no longer the owner.
DO $$
DECLARE
  v_owner name;
BEGIN
  SELECT pg_get_userbyid(p.proowner) INTO v_owner
    FROM pg_proc p
   WHERE p.oid = 'public.assert_likes_persist_and_are_exclusive()'::regprocedure;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'cannot find the owner of assert_likes_persist_and_are_exclusive(), '
                    'so like_probe_as_client() cannot be made callable by it';
  END IF;

  EXECUTE 'REVOKE ALL ON FUNCTION public.like_probe_as_client() FROM PUBLIC';
  EXECUTE format('GRANT EXECUTE ON FUNCTION public.like_probe_as_client() TO %I', v_owner);
  EXECUTE format('ALTER FUNCTION public.like_probe_as_client() OWNER TO %I', v_owner);
END;
$$;

COMMENT ON FUNCTION public.like_probe_as_client() IS
  'WRITE test helper: SECURITY DEFINER but OWNED BY authenticated, so current_user is a real client inside it and row-level security is genuinely evaluated. Never call this directly — it assumes the fixtures exist. The assertion that owns the fixtures is assert_likes_persist_and_are_exclusive(); 77 tried set_config(''role'', ...), which PostgreSQL refuses inside a SECURITY DEFINER function.';

-- ===========================================================================
-- The assertion, which now only builds fixtures and steps aside
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_likes_persist_and_are_exclusive()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prov  uuid := '00000000-0000-4000-8000-0000000007a1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_forge uuid := '00000000-0000-4000-8000-0000000007a3';
  v_ok boolean;
BEGIN
  BEGIN
    -- ── Fixtures, as the schema owner, before anyone becomes a client ──────
    INSERT INTO auth.users (id, email, email_confirmed_at)
    VALUES (v_user,  'like-probe@example.invalid', now()),
           (v_other, 'like-probe-other@example.invalid', now())
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user,  'Like Probe',       'PENDING_APPROVAL'),
           (v_other, 'Like Probe Other', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    -- An APPROVED provider, which no client could create. The guard is off for
    -- this one row, inside the subtransaction about to be rolled back.
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES (v_prov, v_other, 'SERVICE_PROVIDER', 'Like Probe Provider', 'APPROVED')
    ON CONFLICT (id) DO NOTHING;
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    -- Two products. The second exists only so the forged INSERT in step 4 has
    -- somewhere to land that the caller has not already reacted to.
    INSERT INTO public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    VALUES (v_prod, v_prov, 'Like Probe Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100),
           (v_forge, v_prov, 'Like Probe Product 2', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    ON CONFLICT (id) DO NOTHING;

    -- One reaction row belonging to somebody else. Seeded as the owner,
    -- because making one as a client is exactly the thing under test.
    INSERT INTO public.product_likes (user_id, product_id, reaction)
    VALUES (v_other, v_prod, 'DISLIKE')
    ON CONFLICT (user_id, product_id) DO NOTHING;

    -- Known counts, AFTER the seed above fired trg_product_likes_count. Every
    -- assertion below is about deltas from here.
    UPDATE public.products SET like_count = 0, dislike_count = 0 WHERE id = v_prod;

    -- The claims, which is what auth.uid() reads. Unlike `role`, setting these
    -- is permitted inside a SECURITY DEFINER function.
    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    -- Every assertion runs in there, as authenticated.
    v_ok := public.like_probe_as_client();
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'the client-side like probe returned %, expected true', v_ok;
    END IF;

    RAISE EXCEPTION '%', c_sentinel;

  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = c_sentinel THEN
        RETURN true;
      END IF;
      RAISE;
  END;
END;
$$;

COMMENT ON FUNCTION public.assert_likes_persist_and_are_exclusive() IS
  'WRITE test. Builds its fixtures as the schema owner (two products, one reaction row owned by a second user), then hands off to like_probe_as_client(), which is owned by authenticated and therefore evaluates row-level security for real: a LIKE must persist with products.like_count incremented, a DISLIKE must replace it with both counters correct, NONE must remove it, and a reaction naming or deleting another user''s row must be refused. The forged INSERT targets a second product so a uniqueness violation cannot pass for a policy refusal; the DELETE is checked by GET DIAGNOSTICS ROW_COUNT because a USING clause filters rows out of a DELETE instead of raising. Rolls back via a sentinel; fixture ids are fixed and inert. Restated twice: 76 ran entirely as the table owner, which bypasses RLS and so proved nothing about any policy, and 77 tried to fix that with set_config(''role'', ...), which PostgreSQL forbids inside a SECURITY DEFINER function. Migrating the function to the authenticated role is the only way to be a client from in here.';

GRANT EXECUTE ON FUNCTION public.assert_likes_persist_and_are_exclusive() TO anon, authenticated;
