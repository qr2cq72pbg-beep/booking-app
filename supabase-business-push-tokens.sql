-- XBOOK: Business owner device push tokens + exclusive device-token ownership.
-- Run in Supabase Dashboard -> SQL Editor AFTER review.
-- Safe to re-run (idempotent).
--
-- This is the ONE production script for Phase 2 + cross-role token ownership.
-- Do NOT assume an earlier copy of this file was already applied.
--
-- Does NOT:
--   send pushes, create outbox/events, or alter bookings / memberships.
--
-- Owner model: public.business_settings.business_id = auth.users.id.
--
-- Invariant: one physical device_token belongs to exactly one current XBook
-- account (a customer row XOR a business row), never both, never two users.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Existing customer_push_tokens: one physical token → one customer
--    Unique today is (customer_user_id, device_token), so Customer A and
--    Customer C can both hold the same APNs/FCM token.
--
--    Cleanup rule (deterministic, only duplicate tokens):
--    keep the row with latest last_seen_at, then latest created_at, then id.
--    Do not delete a token that appears only once.
-- ---------------------------------------------------------------------------

DELETE FROM public.customer_push_tokens t
USING (
  SELECT id
  FROM (
    SELECT
      id,
      row_number() OVER (
        PARTITION BY device_token
        ORDER BY last_seen_at DESC, created_at DESC, id DESC
      ) AS rn
    FROM public.customer_push_tokens
  ) ranked
  WHERE ranked.rn > 1
) dups
WHERE t.id = dups.id;

CREATE UNIQUE INDEX IF NOT EXISTS customer_push_tokens_device_token_uniq
  ON public.customer_push_tokens (device_token);

-- ---------------------------------------------------------------------------
-- 2) Business owner token table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_push_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  device_token text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('ios', 'android')),
  locale text CHECK (locale IS NULL OR locale IN ('en', 'mk', 'sq')),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_push_tokens_device_token_uniq UNIQUE (device_token)
);

CREATE INDEX IF NOT EXISTS business_push_tokens_business_id_idx
  ON public.business_push_tokens (business_id);

COMMENT ON TABLE public.business_push_tokens IS
  'FCM/APNs device tokens for authenticated business owners. One physical token belongs to at most one owner. Many devices per owner are allowed.';

COMMENT ON COLUMN public.business_push_tokens.business_id IS
  'Owner auth.users.id. Must match business_settings.business_id.';

COMMENT ON COLUMN public.business_push_tokens.locale IS
  'Owner UI language at last registration: en, mk, or sq. Used later for lock-screen copy.';

ALTER TABLE public.business_push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_push_tokens_owner_select ON public.business_push_tokens;
CREATE POLICY business_push_tokens_owner_select
  ON public.business_push_tokens
  FOR SELECT
  TO authenticated
  USING (
    business_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.business_settings bs
      WHERE bs.business_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS business_push_tokens_owner_delete ON public.business_push_tokens;
CREATE POLICY business_push_tokens_owner_delete
  ON public.business_push_tokens
  FOR DELETE
  TO authenticated
  USING (
    business_id = auth.uid()
    AND EXISTS (
      SELECT 1
      FROM public.business_settings bs
      WHERE bs.business_id = auth.uid()
    )
  );

REVOKE ALL ON public.business_push_tokens FROM PUBLIC;
REVOKE ALL ON public.business_push_tokens FROM anon;
REVOKE ALL ON public.business_push_tokens FROM authenticated;
GRANT SELECT, DELETE ON public.business_push_tokens TO service_role;

-- customer_push_tokens already exists in production with
-- GRANT SELECT, INSERT, UPDATE, DELETE TO authenticated.
-- Frontend uses RPCs only; lock mutations to those RPCs.
REVOKE ALL ON public.customer_push_tokens FROM PUBLIC;
REVOKE ALL ON public.customer_push_tokens FROM anon;
REVOKE ALL ON public.customer_push_tokens FROM authenticated;
GRANT SELECT, DELETE ON public.customer_push_tokens TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Internal owner assertion (Business)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._assert_business_push_token_owner()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Business owner only.' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_uid;
END;
$$;

COMMENT ON FUNCTION public._assert_business_push_token_owner() IS
  'Returns auth.uid() when the caller owns business_settings.business_id. Internal helper.';

REVOKE ALL ON FUNCTION public._assert_business_push_token_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_business_push_token_owner() FROM anon;
REVOKE ALL ON FUNCTION public._assert_business_push_token_owner() FROM authenticated;

-- ---------------------------------------------------------------------------
-- 4) Customer upsert/delete — exclusive device token + role check
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.upsert_customer_push_token(
  p_device_token text,
  p_platform text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text := trim(coalesce(p_device_token, ''));
  v_platform text := lower(trim(coalesce(p_platform, '')));
  v_role text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer push tokens only.' USING ERRCODE = 'P0001';
  END IF;

  IF v_token = '' THEN
    RAISE EXCEPTION 'device_token is required';
  END IF;
  IF v_platform NOT IN ('ios', 'android') THEN
    RAISE EXCEPTION 'platform must be ios or android';
  END IF;

  -- Same physical token cannot stay on a Business owner.
  DELETE FROM public.business_push_tokens
  WHERE device_token = v_token;

  INSERT INTO public.customer_push_tokens (
    customer_user_id,
    device_token,
    platform,
    last_seen_at
  )
  VALUES (v_uid, v_token, v_platform, now())
  ON CONFLICT (device_token)
  DO UPDATE SET
    customer_user_id = EXCLUDED.customer_user_id,
    platform = EXCLUDED.platform,
    last_seen_at = now();
END;
$$;

COMMENT ON FUNCTION public.upsert_customer_push_token(text, text) IS
  'Registers the caller customer token. Moves the same physical token off any other customer and off business_push_tokens.';

CREATE OR REPLACE FUNCTION public.delete_customer_push_token(
  p_device_token text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text := trim(coalesce(p_device_token, ''));
  v_role text;
  v_deleted integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer push tokens only.' USING ERRCODE = 'P0001';
  END IF;

  IF v_token = '' THEN
    RETURN false;
  END IF;

  DELETE FROM public.customer_push_tokens
  WHERE customer_user_id = v_uid
    AND device_token = v_token;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;

COMMENT ON FUNCTION public.delete_customer_push_token(text) IS
  'Detaches one device token from the authenticated customer. Idempotent. Does not touch other devices or other users.';

REVOKE ALL ON FUNCTION public.upsert_customer_push_token(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_customer_push_token(text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_customer_push_token(text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_customer_push_token(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_customer_push_token(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_customer_push_token(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 5) Business upsert/delete — exclusive device token
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.upsert_business_push_token(
  p_device_token text,
  p_platform text,
  p_locale text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_token text := trim(coalesce(p_device_token, ''));
  v_platform text := lower(trim(coalesce(p_platform, '')));
  v_locale text := lower(trim(coalesce(p_locale, '')));
BEGIN
  v_uid := public._assert_business_push_token_owner();

  IF v_token = '' THEN
    RAISE EXCEPTION 'device_token is required.' USING ERRCODE = 'P0001';
  END IF;

  IF v_platform NOT IN ('ios', 'android') THEN
    RAISE EXCEPTION 'platform must be ios or android.' USING ERRCODE = 'P0001';
  END IF;

  IF v_locale = '' THEN
    v_locale := NULL;
  ELSIF v_locale NOT IN ('en', 'mk', 'sq') THEN
    RAISE EXCEPTION 'locale must be en, mk, or sq.' USING ERRCODE = 'P0001';
  END IF;

  -- Same physical token cannot stay on a Customer account.
  DELETE FROM public.customer_push_tokens
  WHERE device_token = v_token;

  INSERT INTO public.business_push_tokens (
    business_id,
    device_token,
    platform,
    locale,
    last_seen_at
  )
  VALUES (v_uid, v_token, v_platform, v_locale, now())
  ON CONFLICT (device_token)
  DO UPDATE SET
    business_id = EXCLUDED.business_id,
    platform = EXCLUDED.platform,
    locale = EXCLUDED.locale,
    last_seen_at = now();
END;
$$;

COMMENT ON FUNCTION public.upsert_business_push_token(text, text, text) IS
  'Registers the caller owner token. Moves the same physical token off any other owner and off customer_push_tokens.';

CREATE OR REPLACE FUNCTION public.delete_business_push_token(
  p_device_token text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_token text := trim(coalesce(p_device_token, ''));
  v_deleted integer := 0;
BEGIN
  v_uid := public._assert_business_push_token_owner();

  IF v_token = '' THEN
    RETURN false;
  END IF;

  DELETE FROM public.business_push_tokens
  WHERE business_id = v_uid
    AND device_token = v_token;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;

COMMENT ON FUNCTION public.delete_business_push_token(text) IS
  'Detaches one device token from the authenticated business owner. Idempotent. Does not touch other devices or other owners.';

REVOKE ALL ON FUNCTION public.upsert_business_push_token(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_business_push_token(text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_business_push_token(text, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.delete_business_push_token(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_business_push_token(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_business_push_token(text) TO authenticated;

COMMIT;
