-- Fix the intermittent login CAPTCHA failure caused by cross-client cleanup.
--
-- verify_captcha() marks a correct answer with BOTH used_at and solved_at.
-- request_captcha() previously deleted every used_at row, so any later
-- challenge request from any user could delete a solved-but-not-yet-consumed
-- login challenge. The green Flutter state then failed at login-gate with
-- captcha_failed.
--
-- Keep solved challenges until their enforcement point consumes them. Wrong
-- answers and already-consumed challenges are still removed opportunistically.

CREATE OR REPLACE FUNCTION public.request_captcha()
RETURNS TABLE (captcha_id uuid, question text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_a int;
  v_b int;
  v_op text;
  v_answer int;
BEGIN
  -- A correct solve also sets used_at, so used_at alone does not mean the
  -- challenge is dead. Preserve solved_at IS NOT NULL / consumed_at IS NULL
  -- rows until expiry, while still pruning wrong and consumed attempts.
  DELETE FROM public.captcha_challenges
    WHERE expires_at < now()
       OR (used_at IS NOT NULL
           AND (solved_at IS NULL OR consumed_at IS NOT NULL));

  v_a := 2 + floor(random() * 9)::int;   -- 2..10
  v_b := 1 + floor(random() * 9)::int;   -- 1..10
  IF random() < 0.5 THEN
    v_op := '+'; v_answer := v_a + v_b;
  ELSE
    v_op := '-';                          -- keep results non-negative
    IF v_b > v_a THEN
      v_op := '+'; v_answer := v_a + v_b;
    ELSE
      v_answer := v_a - v_b;
    END IF;
  END IF;

  INSERT INTO public.captcha_challenges (answer)
  VALUES (v_answer::text)
  RETURNING id INTO v_id;

  RETURN QUERY SELECT v_id,
    'I am not a robot — solve: ' || v_a::text || ' ' || v_op || ' ' || v_b::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_captcha() TO anon, authenticated;
