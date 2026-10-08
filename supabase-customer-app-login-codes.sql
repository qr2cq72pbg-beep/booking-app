-- XBOOK Phase 3: one-time 9-digit customer app login codes.
-- Plaintext codes are NEVER stored. Edge Functions store HMAC only via service_role.
-- Do not grant SELECT/INSERT/UPDATE/DELETE to anon or authenticated.

BEGIN;

CREATE TABLE IF NOT EXISTS public.customer_app_login_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  originating_business_id uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  code_hmac text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz,
  failed_attempts integer NOT NULL DEFAULT 0,
  CONSTRAINT customer_app_login_codes_hmac_key UNIQUE (code_hmac),
  CONSTRAINT customer_app_login_codes_failed_attempts_nonneg CHECK (failed_attempts >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS customer_app_login_codes_user_biz_active_uidx
  ON public.customer_app_login_codes (user_id, originating_business_id)
  WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS customer_app_login_codes_expires_idx
  ON public.customer_app_login_codes (expires_at);

CREATE TABLE IF NOT EXISTS public.customer_app_login_rate_limits (
  ip_hmac text NOT NULL,
  window_start timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (ip_hmac, window_start),
  CONSTRAINT customer_app_login_rate_limits_count_nonneg CHECK (attempt_count >= 0)
);

ALTER TABLE public.customer_app_login_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_app_login_rate_limits ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.customer_app_login_codes FROM PUBLIC;
REVOKE ALL ON TABLE public.customer_app_login_codes FROM anon;
REVOKE ALL ON TABLE public.customer_app_login_codes FROM authenticated;
REVOKE ALL ON TABLE public.customer_app_login_rate_limits FROM PUBLIC;
REVOKE ALL ON TABLE public.customer_app_login_rate_limits FROM anon;
REVOKE ALL ON TABLE public.customer_app_login_rate_limits FROM authenticated;

GRANT ALL ON TABLE public.customer_app_login_codes TO service_role;
GRANT ALL ON TABLE public.customer_app_login_rate_limits TO service_role;

COMMENT ON TABLE public.customer_app_login_codes IS
  'HMAC-only one-time 9-digit customer app login codes. No client access. Issued/redeemed by Edge Functions.';

COMMENT ON TABLE public.customer_app_login_rate_limits IS
  'Hashed-IP redeem attempt windows. No client access.';

CREATE OR REPLACE FUNCTION public.customer_app_login_touch_rate_limit(
  p_ip_hmac text,
  p_window_start timestamptz,
  p_limit integer
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  n integer;
BEGIN
  IF p_ip_hmac IS NULL OR length(p_ip_hmac) < 8 OR p_window_start IS NULL OR p_limit IS NULL OR p_limit < 1 THEN
    RETURN true;
  END IF;
  INSERT INTO public.customer_app_login_rate_limits (ip_hmac, window_start, attempt_count, updated_at)
  VALUES (p_ip_hmac, p_window_start, 1, now())
  ON CONFLICT (ip_hmac, window_start)
  DO UPDATE SET
    attempt_count = public.customer_app_login_rate_limits.attempt_count + 1,
    updated_at = now()
  RETURNING attempt_count INTO n;
  RETURN n > p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.customer_app_login_touch_rate_limit(text, timestamptz, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.customer_app_login_touch_rate_limit(text, timestamptz, integer) FROM anon;
REVOKE ALL ON FUNCTION public.customer_app_login_touch_rate_limit(text, timestamptz, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.customer_app_login_touch_rate_limit(text, timestamptz, integer) TO service_role;

COMMIT;
