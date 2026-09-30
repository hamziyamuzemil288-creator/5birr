-- 20260927000101_payment_screenshot_limits_match_the_client.sql
--
-- The provider could not attach a payment screenshot.
--
-- THE BUG
-- -------
-- "Payment screenshot is not accepting from provider section."
--
-- `recharge_screen.dart` picked the gallery image at FULL resolution — no
-- maxWidth/maxHeight — while every other bucket upload in the app
-- (document_upload_service, become_partner, vehicle form, gallery, product
-- form) re-encodes to a 1920px JPEG. `payment-screenshots` is capped at 5MB
-- with an image/jpeg|png|webp mime list (20260927000096), so a modern phone
-- photo, or the HEIC an iOS gallery returns, was refused by storage; and
-- because the upload shared a try/catch with the request insert, the provider
-- was told "Could not submit your recharge" and nothing else. It is the only
-- payment upload into that bucket — the buyer's proofs go to payment-proofs
-- with twice the allowance, which is why the report was provider-only.
--
-- The client is fixed (downscale + a specific message). This migration adds
-- the half only a live database can answer, because the number the client
-- now QUOTES to the provider ("the limit is 5 MB") is a promise about the
-- live bucket, and nothing else in the repo checks it:
--
--   * if payment-screenshots loses image/jpeg, every screenshot upload in
--     the app fails — the picker re-encodes to JPEG and nothing else is
--     guaranteed to survive;
--   * if its file_size_limit drops below the downscale's output, uploads
--     start failing again with no code change to point at;
--   * if either bucket becomes public, every payment proof becomes readable
--     by anyone who guesses a path. That is worse than the outage, and it is
--     the same check assert_app_buckets_exist makes — repeated here because
--     these two buckets are the ones carrying money evidence, and a later
--     migration that flips visibility would otherwise pass the older
--     assertion's eyes only if that assertion were never updated.
--
-- Raising a limit is allowed by this assertion (>=, not =); LOWERING one
-- breaks the message the client shows and must come with a deliberate edit
-- of both the bucket and that message.

CREATE OR REPLACE FUNCTION public.assert_payment_screenshot_uploads_are_accepted()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- The two buckets a payment screenshot can land in. Flat list, FOREACH
  -- with a text loop variable: an array-typed loop variable is what raised
  -- 42804 in the notification assertions (migration 95).
  v_buckets text[] := ARRAY['payment-screenshots', 'payment-proofs'];
  -- The floor each must stay at or above, in bytes. payment-screenshots is
  -- 5MB, which is the figure the recharge screen's error message quotes.
  v_floors bigint[] := ARRAY[5242880::bigint, 5242880::bigint];
  v_bucket text;
  v_floor bigint;
  v_limit bigint;
  v_mimes text[];
  v_public boolean;
  v_checked int := 0;
  v_report text := '';
BEGIN
  FOR v_bucket, v_floor IN
    SELECT * FROM unnest(v_buckets, v_floors)
  LOOP
    v_checked := v_checked + 1;

    SELECT b.file_size_limit, b.allowed_mime_types, b.public
      INTO v_limit, v_mimes, v_public
      FROM storage.buckets b
     WHERE b.id = v_bucket;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'SCREENSHOT_BUCKET_MISSING: % does not exist, so every payment screenshot upload fails with "Bucket not found"',
        v_bucket;
    END IF;

    -- JPEG is what every picker in the app produces after its re-encode.
    -- A bucket that stops accepting it refuses every screenshot upload in
    -- the product, so this is checked per bucket rather than once.
    IF v_mimes IS NULL OR NOT ('image/jpeg' = ANY (v_mimes)) THEN
      RAISE EXCEPTION
        'SCREENSHOT_MIME_MISSING: % no longer accepts image/jpeg (it allows %), and every screenshot picker in the app re-encodes to JPEG, so uploads fail on type',
        v_bucket,
        coalesce(array_to_string(v_mimes, ', '), 'nothing');
    END IF;

    -- Lowering the limit below what the client promises is a silent
    -- contract break; raising it is harmless, so this is a floor.
    IF v_limit IS NOT NULL AND v_limit < v_floor THEN
      RAISE EXCEPTION
        'SCREENSHOT_LIMIT_TOO_LOW: % allows % bytes but the client assumes at least %, so a downscaled screenshot can still be refused',
        v_bucket, v_limit, v_floor;
    END IF;

    IF v_public THEN
      RAISE EXCEPTION
        'SCREENSHOT_BUCKET_PUBLIC: % is PUBLIC, so any payment proof is readable by anyone who can guess its path',
        v_bucket;
    END IF;

    v_report := v_report || v_bucket || ': jpeg ok, limit '
                || coalesce((v_limit / 1024)::text || 'KB', 'unlimited')
                || ', private; ';
  END LOOP;

  RETURN 'ok: ' || v_checked::text
         || ' payment-screenshot bucket(s) accept JPEG, keep the size floor '
         || 'the client quotes and stay private (' || rtrim(v_report) || ')';
END;
$$;

COMMENT ON FUNCTION public.assert_payment_screenshot_uploads_are_accepted() IS
  'The buckets a payment screenshot lands in must stay private, must keep '
  'accepting image/jpeg (every picker re-encodes to it) and must not be '
  'lowered below the size the client tells the user. Reads storage.buckets, '
  'which no client role can reach, so it is SECURITY DEFINER and granted to '
  'anon for the connectivity suite.';

-- Same grant shape as every other assertion (migration 91): anon is the role
-- the connectivity suite calls as, and assert_every_assertion_is_reachable()
-- requires every zero-argument assert_* to be executable by it.
REVOKE ALL ON FUNCTION public.assert_payment_screenshot_uploads_are_accepted()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_payment_screenshot_uploads_are_accepted()
  TO anon, authenticated, service_role;

notify pgrst, 'reload schema';
