-- =============================================================================
-- 20260927000077 — make the like write test prove the RLS claim it makes
-- =============================================================================
--
-- WHAT THE DEPLOY OF 76 SHOWED
-- -----------------------------
-- Migration 76 applied cleanly and its assertion ran for the first time. It
-- failed with:
--
--   PostgrestException: a user was able to write a reaction row for somebody
--   else (code: P0001)
--
-- which is the assertion's OWN sentinel — it got all the way to its last step.
-- Read in order, that is a good result and one bad test:
--
--   1. a LIKE persisted and products.like_count went to 1   -- PASSED
--   2. a DISLIKE replaced it, both counters correct          -- PASSED
--   3. NONE cleared it, both counters back to 0             -- PASSED
--   4. writing a reaction for another user was refused       -- "FAILED"
--
-- Steps 1-3 are the ones that mattered. They are the live proof that
-- enforce_provider_write_gate no longer refuses the denormalised counter, so
-- the like that used to fill and empty now persists. That is fixed.
--
-- ── Step 4 was a broken test, not a broken policy ─────────────────────────
--
-- It tried to prove the RLS refuses somebody else's row by inserting one
-- with a different user_id. The insert SUCCEEDED — and it succeeded for a
-- reason that has nothing to do with the policy:
--
--   assert_likes_persist_and_are_exclusive() is SECURITY DEFINER, so it runs
--   as the table owner. A table owner BYPASSES row-level security unless
--   FORCE ROW LEVEL SECURITY is set, and nothing in this schema sets it
--   (`select 1 from pg_class where relforcerowsecurity` is empty). The
--   `with check (auth.uid() = user_id)` policy was never evaluated, because
--   RLS is not evaluated at all for the owner.
--
-- The set_config('request.jwt.claim.sub', ...) the fixture uses does not help
-- here, and it is worth being precise about why, because it is the same trick
-- several other assertions in this suite use. Changing that GUC changes what
-- auth.uid() RETURNS — which is what the trigger-based guards read, and is
-- why assert_profile_self_approval_is_refused can prove a guard fires. It does
-- not change `current_user`, and RLS is evaluated against the ROLE. So an
-- assertion written that way can exercise every trigger in the chain and
-- still prove nothing at all about a policy.
--
-- The fix is the thing PostgREST itself does: set the role as well as the
-- claims.
--
--   perform set_config('role', 'authenticated', true);
--
-- ── And steps 1-3 move under the same role switch ─────────────────────────
--
-- They are re-run as `authenticated` rather than left as they were. As the
-- owner they exercised the triggers, which is what caught the original bug,
-- but they ran `set_product_reaction` — a SECURITY INVOKER function — with
-- RLS switched off, which is not the path any real user takes. Running the
-- whole test as a client is both stricter and closer to production: if the
-- policies, the grants or the function's own privilege assumptions were
-- wrong, it now fails here rather than on a device.
--
-- The fixtures stay above the switch, where they must: they create an APPROVED
-- provider, which no client may do, and they are created inside a subtransaction
-- that is rolled back anyway.
--
-- ── Two products, and that is not decoration ───────────────────────────────
--
-- The two "somebody else's row" checks each need a row to exist that the
-- caller does not own, and the same product cannot provide both:
--
--   * the DELETE check needs a real v_other row, or "deleted 0 rows" means
--     "there was nothing to delete" rather than "the policy filtered it";
--   * the forged INSERT must go to a product the caller has NOT already
--     reacted to, because product_likes is unique on (user_id, product_id)
--     and a uniqueness violation would be caught as "the insert was refused"
--     for a reason that has nothing to do with RLS. It would pass, and mean
--     nothing.
--
-- So the fixture creates a second product, used only as the forgery target, and
-- seeds one reaction row belonging to v_other on the first product.
--
-- Nothing in the application's behaviour changes. This migration restates one
-- assertion function and nothing else.
-- -----------------------------------------------------------------------------

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
  v_result jsonb;
  v_rows int;
  v_like int;
  v_dislike int;
  v_orig_role text;
BEGIN
  BEGIN
    -- ── Fixtures, as the table owner, before any role switch ──
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

    INSERT INTO public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    VALUES (v_prod, v_prov, 'Like Probe Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100),
           (v_forge, v_prov, 'Like Probe Product 2', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    ON CONFLICT (id) DO NOTHING;

    -- One reaction row that belongs to somebody else. Seeded as the owner
    -- because that is the only way to make one: as a client, insert-own is
    -- exactly the policy under test.
    INSERT INTO public.product_likes (user_id, product_id, reaction)
    VALUES (v_other, v_prod, 'DISLIKE')
    ON CONFLICT (user_id, product_id) DO NOTHING;

    -- Start from known counts, AFTER seeding: the seed above fired
    -- trg_product_likes_count, and everything below is about deltas. The
    -- fixture row may already exist because of ON CONFLICT DO NOTHING.
    UPDATE public.products SET like_count = 0, dislike_count = 0 WHERE id = v_prod;

    -- ── Become a client, the way PostgREST does ──
    -- Claims first, then role: the claims are what auth.uid() reads and the
    -- role is what RLS is evaluated against, and neither substitutes for the
    -- other. 76 set only the claims, which is why its RLS step could not fail.
    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);
    -- current_setting(..., true) returns NULL if the GUC was never set, and
    -- set_config rejects a NULL value, so remember the role only if there is
    -- one to remember.
    v_orig_role := current_setting('role', true);
    IF v_orig_role IS NOT NULL THEN
      BEGIN
        PERFORM set_config('role', 'authenticated', true);
      EXCEPTION WHEN OTHERS THEN
        -- You can only SET ROLE to a role you are a member of, and the owner
        -- of this function is not guaranteed to be. If that is the case the
        -- whole RLS half of this test is impossible and it should say so in
        -- those words, rather than failing three steps later on a
        -- permission error that looks like a broken policy.
        RAISE EXCEPTION 'this probe runs as %, which is not allowed to assume the '
                        'authenticated role (%), so it cannot exercise RLS at all: %',
          v_orig_role, 'authenticated', SQLERRM;
      END;
    END IF;

    -- If the role switch silently did not take, the RLS step below would pass
    -- for the same wrong reason 76 gave. Prove we are actually a client before
    -- relying on that.
    IF current_user <> 'authenticated' THEN
      RAISE EXCEPTION 'the like probe is still running as %, not as authenticated, so the RLS half of this test would prove nothing',
        current_user;
    END IF;

    IF public.is_admin() THEN
      RAISE EXCEPTION 'the like probe is unexpectedly an admin, so this test cannot prove anything';
    END IF;

    -- ── 1. A like persists ──
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
                      'This is the regression: the counter UPDATE on products is being '
                      'refused by enforce_provider_write_gate.', v_like, v_dislike;
    END IF;
    IF (v_result->>'like_count')::int <> 1 THEN
      RAISE EXCEPTION 'set_product_reaction returned like_count %, expected 1', v_result->>'like_count';
    END IF;

    -- ── 2. A dislike replaces the like, and only one row can exist ──
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
      RAISE EXCEPTION 'after DISLIKE the counters are like=% dislike=% , expected 0 and 1', v_like, v_dislike;
    END IF;

    -- ── 3. NONE removes it and gives both counters back ──
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
      RAISE EXCEPTION 'after NONE the counters are like=% dislike=% , expected 0 and 0', v_like, v_dislike;
    END IF;

    -- ── 4. The RLS bites: somebody else's reaction is refused ──
    -- This is the step that 76 could not make fail. It runs as
    -- `authenticated` now, so the policy is genuinely evaluated, and a user who
    -- could write a row naming somebody else could forge a reaction in their
    -- name.
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

    -- And the matching half: a user may not delete somebody else's row either.
    -- insert-own alone is not "you manage only your own row".
    --
    -- This one is checked by COUNT, not by expecting an exception, and the
    -- difference matters. An RLS USING clause on DELETE filters rows out of
    -- the statement rather than refusing it, so a cross-user delete returns
    -- "DELETE 0" and looks exactly like a successful one. An assertion that
    -- waited for an error here would fail forever; one that counts rows asks
    -- the right question, which is whether anything was actually deleted.
    --
    -- First prove there is something there to protect, so a row count of 0
    -- afterwards can only mean the policy filtered it.
    SELECT count(*) INTO v_rows FROM public.product_likes
     WHERE user_id = v_other AND product_id = v_prod;
    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'the fixture row belonging to the other user is missing (% '
                      'row(s)), so the delete policy is not being exercised',
        v_rows;
    END IF;

    v_rows := -1;
    BEGIN
      DELETE FROM public.product_likes WHERE user_id = v_other AND product_id = v_prod;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
      -- An outright refusal is also a pass; -1 keeps it distinguishable from
      -- a delete that touched rows.
      v_rows := 0;
    END;

    IF v_rows <> 0 THEN
      RAISE EXCEPTION 'a user deleted % reaction row(s) belonging to somebody else', v_rows;
    END IF;

    -- And the row they DO own is still removable, or the policy is a blanket
    -- block that would break the feature rather than protect it.
    v_rows := -1;
    BEGIN
      DELETE FROM public.product_likes
       WHERE user_id = v_user AND product_id = v_prod;
      GET DIAGNOSTICS v_rows = ROW_COUNT;
    EXCEPTION WHEN OTHERS THEN
      v_rows := 0;
    END;

    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'a user could not delete their own reaction row (affected %), so the delete policy is a blanket block',
        v_rows;
    END IF;

    -- Back to nothing, so the fixture product is left tidy even though the
    -- whole subtransaction is rolled back a moment later.
    PERFORM set_product_reaction(v_prod, 'NONE');

    -- Hand the role back before the sentinel, so the rollback below does not
    -- have to be relied on to restore it.
    IF v_orig_role IS NOT NULL THEN
      PERFORM set_config('role', v_orig_role, true);
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
  'WRITE test, run as the `authenticated` role: creates its fixtures as the owner (two products, plus one reaction row owned by a second user), then switches to a real client (set_config for the JWT claims AND for `role`, the thing 76 omitted) and requires a LIKE to persist with products.like_count incremented, a DISLIKE to replace it with both counters correct, NONE to remove it, and writes naming or deleting another user''s row to be refused. Checks current_user before relying on the RLS step, so a silently-failed role switch cannot make it pass. The forged INSERT goes to a product the caller has not reacted to, so a uniqueness violation cannot be mistaken for a policy refusal; the DELETE is checked by GET DIAGNOSTICS ROW_COUNT rather than by expecting an error, because a USING clause filters rows out of a DELETE instead of raising. Rolls back via a sentinel; fixture ids are fixed and inert. Restated by migration 77: 76 ran entirely as the table owner, which bypasses RLS, so its last step proved nothing -- and it said so by failing.';

GRANT EXECUTE ON FUNCTION public.assert_likes_persist_and_are_exclusive() TO anon, authenticated;
