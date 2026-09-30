-- =============================================================================
-- XBOOK SECURITY HARDENING — V1 / V2 / V3 ONLY
-- Linked project: sdqothuulzeczcncyfqd
-- Safe to re-run (CREATE OR REPLACE / DROP IF EXISTS).
--
-- Does NOT change: booking create/reschedule/cancel logic, Paddle, V4,
-- owner CRM policies, identity-linking RPCs, handle_new_user_profile,
-- or unrelated grants/policies.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- V1 — get_customer_my_bookings: uid-only, no manage_token, no anon EXECUTE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_customer_my_bookings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_data ORDER BY row_data->>'date', row_data->>'time')
      FROM (
        SELECT jsonb_build_object(
          'id', b.id,
          'date', b.date::text,
          'time', to_char(b.time, 'HH24:MI'),
          'booking_status', coalesce(nullif(trim(b.booking_status), ''), nullif(trim(b.status), ''), 'Pending'),
          'service_id', b.service_id,
          'service_name', coalesce(nullif(trim(b.service_name), ''), s.name),
          'staff_id', b.staff_id,
          'staff_name', st.name,
          'business_id', b.business_id,
          'business_name', bs.business_name,
          'business_slug', bs.business_slug,
          'booking_ref', b.booking_ref
        ) AS row_data
        FROM public.bookings b
        LEFT JOIN public.business_settings bs ON bs.business_id = b.business_id
        LEFT JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
        LEFT JOIN public.staff_members st ON st.id = b.staff_id AND st.business_id = b.business_id
        WHERE b.customer_user_id = v_uid
      ) sub
    ),
    '[]'::jsonb
  );
END;
$$;

COMMENT ON FUNCTION public.get_customer_my_bookings() IS
  'Authenticated customer My Bookings list. Returns only bookings with customer_user_id = auth.uid(). Does not return manage_token. Does not match by email or phone.';

REVOKE ALL ON FUNCTION public.get_customer_my_bookings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_my_bookings() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_customer_my_bookings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_my_bookings() TO service_role;

-- Token is fetched on Manage click, only for a booking the caller owns.
CREATE OR REPLACE FUNCTION public.get_customer_booking_manage_token(p_booking_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_booking_id IS NULL THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.manage_token
    INTO v_token
  FROM public.bookings b
  WHERE b.id = p_booking_id
    AND b.customer_user_id = v_uid;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_token;
END;
$$;

COMMENT ON FUNCTION public.get_customer_booking_manage_token(uuid) IS
  'Returns manage_token for one booking owned by auth.uid(). Does not list tokens. Does not match by email or phone.';

REVOKE ALL ON FUNCTION public.get_customer_booking_manage_token(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_booking_manage_token(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_customer_booking_manage_token(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_customer_booking_manage_token(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- V2 — business_customers customer SELECT: uid-only (owner policy unchanged)
-- Identity linking remains SECURITY DEFINER register_customer_business_membership
-- / _ensure_business_customer_membership — not RLS email dump.
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS business_customers_customer_select_own ON public.business_customers;
CREATE POLICY business_customers_customer_select_own
  ON public.business_customers
  FOR SELECT
  TO authenticated
  USING (customer_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- V3 — prevent role self-escalation via PostgREST UPDATE
-- INSERT (signup / first OAuth write) still sets role.
-- handle_new_user_profile (DEFINER INSERT) is unchanged.
-- Complete Profile RPCs do not write role.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_user_profiles_role_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role THEN
    RAISE EXCEPTION 'Role cannot be changed.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS user_profiles_role_immutable ON public.user_profiles;
CREATE TRIGGER user_profiles_role_immutable
  BEFORE UPDATE ON public.user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_user_profiles_role_immutable();

COMMENT ON FUNCTION public.trg_user_profiles_role_immutable() IS
  'Blocks customer↔admin (and any other role mutation) on UPDATE. First assignment remains INSERT.';

-- Table-level UPDATE grants every column; REVOKE UPDATE(role) alone is a no-op.
-- Re-grant only legitimate editable profile columns. INSERT(role) remains.
REVOKE UPDATE ON TABLE public.user_profiles FROM authenticated;
GRANT UPDATE (
  email,
  full_name,
  phone,
  updated_at,
  first_name,
  last_name
) ON TABLE public.user_profiles TO authenticated;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- CREATE OR REPLACE FUNCTION public.get_customer_my_bookings()
-- RETURNS jsonb
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = public
-- AS $$
-- DECLARE
--   v_uid   uuid := auth.uid();
--   v_email text;
--   v_phone text;
-- BEGIN
--   IF v_uid IS NULL THEN
--     RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
--   END IF;
--   SELECT
--     lower(trim(coalesce(nullif(trim(p.email), ''), nullif(trim(u.email), '')))),
--     nullif(regexp_replace(coalesce(p.phone, ''), '[^0-9+]', '', 'g'), '')
--   INTO v_email, v_phone
--   FROM auth.users u
--   LEFT JOIN public.user_profiles p ON p.id = u.id
--   WHERE u.id = v_uid;
--   RETURN COALESCE(
--     (
--       SELECT jsonb_agg(row_data ORDER BY row_data->>'date', row_data->>'time')
--       FROM (
--         SELECT jsonb_build_object(
--           'id', b.id,
--           'date', b.date::text,
--           'time', to_char(b.time, 'HH24:MI'),
--           'booking_status', coalesce(nullif(trim(b.booking_status), ''), nullif(trim(b.status), ''), 'Pending'),
--           'service_id', b.service_id,
--           'service_name', coalesce(nullif(trim(b.service_name), ''), s.name),
--           'staff_id', b.staff_id,
--           'staff_name', st.name,
--           'business_id', b.business_id,
--           'business_name', bs.business_name,
--           'business_slug', bs.business_slug,
--           'manage_token', b.manage_token,
--           'booking_ref', b.booking_ref
--         ) AS row_data
--         FROM public.bookings b
--         LEFT JOIN public.business_settings bs ON bs.business_id = b.business_id
--         LEFT JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
--         LEFT JOIN public.staff_members st ON st.id = b.staff_id AND st.business_id = b.business_id
--         WHERE
--           b.customer_user_id = v_uid
--           OR (
--             v_email IS NOT NULL AND v_email <> ''
--             AND lower(trim(coalesce(b.customer_email, ''))) = v_email
--           )
--           OR (
--             v_phone IS NOT NULL AND length(v_phone) >= 8
--             AND regexp_replace(coalesce(b.customer_phone, ''), '[^0-9+]', '', 'g') = v_phone
--           )
--       ) sub
--     ),
--     '[]'::jsonb
--   );
-- END;
-- $$;
-- GRANT EXECUTE ON FUNCTION public.get_customer_my_bookings() TO anon, authenticated, service_role;
-- DROP FUNCTION IF EXISTS public.get_customer_booking_manage_token(uuid);
-- DROP POLICY IF EXISTS business_customers_customer_select_own ON public.business_customers;
-- CREATE POLICY business_customers_customer_select_own
--   ON public.business_customers FOR SELECT TO authenticated
--   USING (
--     customer_user_id = auth.uid()
--     OR (
--       customer_user_id IS NULL
--       AND email IS NOT NULL
--       AND TRIM(BOTH FROM email) <> ''
--       AND lower(TRIM(BOTH FROM email)) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), '')))
--     )
--   );
-- DROP TRIGGER IF EXISTS user_profiles_role_immutable ON public.user_profiles;
-- DROP FUNCTION IF EXISTS public.trg_user_profiles_role_immutable();
-- REVOKE UPDATE ON TABLE public.user_profiles FROM authenticated;
-- GRANT UPDATE ON TABLE public.user_profiles TO authenticated;
-- COMMIT;
