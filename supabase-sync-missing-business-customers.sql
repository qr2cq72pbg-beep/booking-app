-- XBOOK: Recover missing business_customers rows + signup business linking
-- Run once in Supabase Dashboard → SQL Editor AFTER:
--   supabase-business-customers.sql
--   supabase-client-approval.sql
--
-- Fixes: customer auth/profile created without business_customers pending row.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Insert-only membership helper (never overwrites approved/blocked/rejected)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ensure_business_customer_membership(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_approval_status    text DEFAULT NULL
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing public.business_customers%ROWTYPE;
  v_row      public.business_customers%ROWTYPE;
  v_status   text;
  v_require  boolean;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_existing := public._lookup_business_customer_row(
    p_business_id,
    p_customer_user_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name
  );

  IF v_existing.id IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT coalesce(bs.require_client_approval, false)
  INTO v_require
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  v_status := lower(trim(coalesce(p_approval_status, '')));
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    v_status := CASE WHEN coalesce(v_require, false) THEN 'pending' ELSE 'approved' END;
  END IF;

  v_row := public.ensure_business_customer(
    p_business_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name
  );

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.business_customers
  SET
    customer_user_id = coalesce(p_customer_user_id, customer_user_id),
    approval_status = v_status,
    updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) IS
  'Creates business_customers row when missing; never changes existing approval_status.';

-- ---------------------------------------------------------------------------
-- 2) Customer self-register at signup / login (authenticated)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_customer_business_membership(
  p_business_id   uuid,
  p_phone         text DEFAULT '',
  p_email         text DEFAULT NULL,
  p_name          text DEFAULT NULL
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.business_customers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0001';
  END IF;

  v_row := public._ensure_business_customer_membership(
    p_business_id,
    v_uid,
    p_phone,
    coalesce(nullif(trim(p_email), ''), (SELECT u.email FROM auth.users u WHERE u.id = v_uid)),
    p_name,
    NULL
  );

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.register_customer_business_membership(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_customer_business_membership(uuid, text, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) Admin backfill / recovery
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_missing_business_customers(
  p_business_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_slug        text;
  v_created     integer := 0;
  v_row         public.business_customers%ROWTYPE;
  v_before      public.business_customers%ROWTYPE;
  rec           record;
  v_single_approval boolean := false;
BEGIN
  IF v_caller IS NULL OR p_business_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = 'P0001';
  END IF;

  IF v_caller IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Only the business owner may sync customers.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(bs.business_slug, '')))
  INTO v_slug
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  SELECT count(*) = 1
  INTO v_single_approval
  FROM public.business_settings bs
  WHERE coalesce(bs.require_client_approval, false) = true;

  -- A) Bookings-linked customers
  FOR rec IN
    SELECT DISTINCT ON (
      coalesce(b.customer_user_id::text, ''),
      lower(trim(coalesce(b.customer_email, ''))),
      public._normalize_booking_phone(b.customer_phone),
      lower(trim(coalesce(b.customer_name, '')))
    )
      b.customer_user_id,
      b.customer_phone,
      b.customer_email,
      b.customer_name
    FROM public.bookings b
    WHERE b.business_id = p_business_id
    ORDER BY
      coalesce(b.customer_user_id::text, ''),
      lower(trim(coalesce(b.customer_email, ''))),
      public._normalize_booking_phone(b.customer_phone),
      lower(trim(coalesce(b.customer_name, ''))),
      b.created_at DESC NULLS LAST
  LOOP
    v_before := public._lookup_business_customer_row(
      p_business_id,
      rec.customer_user_id,
      rec.customer_phone,
      rec.customer_email,
      rec.customer_name
    );
    IF v_before.id IS NOT NULL THEN
      CONTINUE;
    END IF;

    v_row := public._ensure_business_customer_membership(
      p_business_id,
      rec.customer_user_id,
      rec.customer_phone,
      rec.customer_email,
      rec.customer_name,
      NULL
    );
    IF v_row.id IS NOT NULL THEN
      v_created := v_created + 1;
    END IF;
  END LOOP;

  -- B) Auth metadata business link (signup with business code)
  FOR rec IN
    SELECT
      u.id AS customer_user_id,
      coalesce(nullif(trim(p.phone), ''), nullif(trim(u.raw_user_meta_data->>'phone'), '')) AS phone,
      lower(trim(coalesce(nullif(trim(p.email), ''), u.email))) AS email,
      coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), '')) AS name
    FROM auth.users u
    LEFT JOIN public.user_profiles p ON p.id = u.id
    WHERE lower(trim(coalesce(p.role, u.raw_user_meta_data->>'role', ''))) = 'customer'
      AND (
        nullif(trim(u.raw_user_meta_data->>'business_id'), '')::uuid = p_business_id
        OR (
          v_slug <> ''
          AND lower(trim(coalesce(u.raw_user_meta_data->>'business_slug', ''))) = v_slug
        )
      )
  LOOP
    v_before := public._lookup_business_customer_row(
      p_business_id,
      rec.customer_user_id,
      rec.phone,
      rec.email,
      rec.name
    );
    IF v_before.id IS NOT NULL THEN
      CONTINUE;
    END IF;

    v_row := public._ensure_business_customer_membership(
      p_business_id,
      rec.customer_user_id,
      rec.phone,
      rec.email,
      rec.name,
      NULL
    );
    IF v_row.id IS NOT NULL THEN
      v_created := v_created + 1;
    END IF;
  END LOOP;

  -- C) Orphan recovery: customer profile never linked to any business (single-tenant safe)
  IF v_single_approval THEN
    FOR rec IN
      SELECT
        p.id AS customer_user_id,
        coalesce(nullif(trim(p.phone), ''), '') AS phone,
        lower(trim(coalesce(nullif(trim(p.email), ''), ''))) AS email,
        coalesce(nullif(trim(p.full_name), ''), 'Customer') AS name
      FROM public.user_profiles p
      WHERE lower(trim(coalesce(p.role, ''))) = 'customer'
        AND NOT EXISTS (
          SELECT 1
          FROM public.business_customers bc
          WHERE bc.customer_user_id = p.id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.business_customers bc2
          WHERE bc2.business_id = p_business_id
            AND bc2.customer_user_id = p.id
        )
    LOOP
      v_before := public._lookup_business_customer_row(
        p_business_id,
        rec.customer_user_id,
        rec.phone,
        rec.email,
        rec.name
      );
      IF v_before.id IS NOT NULL THEN
        CONTINUE;
      END IF;

      v_row := public._ensure_business_customer_membership(
        p_business_id,
        rec.customer_user_id,
        rec.phone,
        rec.email,
        rec.name,
        NULL
      );
      IF v_row.id IS NOT NULL THEN
        v_created := v_created + 1;
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'created', v_created,
    'business_id', p_business_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.sync_missing_business_customers(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sync_missing_business_customers(uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Auth trigger: link business_customers on customer signup (email-confirm path)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_new_user_business_customer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
  v_business_slug text;
  v_role text;
  v_name text;
  v_phone text;
  v_email text;
BEGIN
  v_role := lower(trim(coalesce(NEW.raw_user_meta_data->>'role', '')));
  IF v_role <> 'customer' THEN
    RETURN NEW;
  END IF;

  BEGIN
    v_business_id := nullif(trim(NEW.raw_user_meta_data->>'business_id'), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_business_id := NULL;
  END;

  v_business_slug := lower(trim(coalesce(NEW.raw_user_meta_data->>'business_slug', '')));

  IF v_business_id IS NULL AND v_business_slug <> '' THEN
    SELECT bs.business_id
    INTO v_business_id
    FROM public.business_settings bs
    WHERE lower(trim(coalesce(bs.business_slug, ''))) = v_business_slug
    LIMIT 1;
  END IF;

  IF v_business_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_name := nullif(trim(coalesce(NEW.raw_user_meta_data->>'full_name', '')), '');
  v_phone := nullif(trim(coalesce(NEW.raw_user_meta_data->>'phone', '')), '');
  v_email := lower(trim(coalesce(NEW.email, '')));

  PERFORM public._ensure_business_customer_membership(
    v_business_id,
    NEW.id,
    v_phone,
    v_email,
    v_name,
    NULL
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_business_customer ON auth.users;
CREATE TRIGGER on_auth_user_created_business_customer
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_business_customer();

COMMENT ON FUNCTION public.sync_missing_business_customers(uuid) IS
  'Admin-only: backfill missing business_customers from bookings, signup metadata, and orphan profiles.';

COMMIT;
