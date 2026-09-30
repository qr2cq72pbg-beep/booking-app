-- =============================================================================
-- XBOOK SECURITY HARDENING — V4-3 ONLY
-- Linked project: sdqothuulzeczcncyfqd
-- Safe to re-run (CREATE OR REPLACE / REVOKE / GRANT).
--
-- Hides bookings.manage_token from direct PostgREST table access.
-- Token access remains via:
--   get_customer_booking_manage_token (customer, uid-owned row)
--   get_business_booking_manage_token (owner, business_id = auth.uid())
--   create_booking / create_recurring_bookings SECURITY DEFINER return
--   get/cancel/reschedule_booking_by_manage_token (existing token model)
--
-- Does NOT change: V1-V4-2 function bodies, booking create/cancel/reschedule
-- rules, token expiry/rotation, Paddle, or RLS policies.
-- =============================================================================

BEGIN;

-- Owner fetches one token for a booking of their own business.
CREATE OR REPLACE FUNCTION public.get_business_booking_manage_token(p_booking_id uuid)
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
    AND b.business_id = v_uid;

  IF v_token IS NULL OR btrim(v_token) = '' THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_token;
END;
$$;

COMMENT ON FUNCTION public.get_business_booking_manage_token(uuid) IS
  'Returns manage_token for one booking owned by the caller business (business_id = auth.uid()). Does not list tokens. Does not match by email or phone.';

REVOKE ALL ON FUNCTION public.get_business_booking_manage_token(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_booking_manage_token(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_business_booking_manage_token(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_booking_manage_token(uuid) TO service_role;

-- Table-level SELECT/INSERT/UPDATE imply every column, including manage_token.
-- Revoke those, then re-grant only non-token columns to authenticated.
-- anon gets no bookings SELECT/INSERT/UPDATE; public manage links stay on token RPCs.
REVOKE SELECT, INSERT, UPDATE ON TABLE public.bookings FROM anon;
REVOKE SELECT, INSERT, UPDATE ON TABLE public.bookings FROM authenticated;
REVOKE SELECT (manage_token), INSERT (manage_token), UPDATE (manage_token) ON TABLE public.bookings FROM anon;
REVOKE SELECT (manage_token), INSERT (manage_token), UPDATE (manage_token) ON TABLE public.bookings FROM authenticated;

GRANT SELECT (
  id,
  user_id,
  service,
  date,
  time,
  created_at,
  name,
  phone,
  business_id,
  staff_id,
  booking_status,
  customer_user_id,
  customer_email,
  customer_name,
  customer_phone,
  duration_minutes,
  notes,
  status,
  service_id,
  service_name,
  staff_name,
  booking_ref,
  recurring_group_id,
  recurring_index,
  recurring_total,
  recurring_rule,
  booking_price
) ON TABLE public.bookings TO authenticated;

GRANT UPDATE (
  booking_status,
  status,
  service_id,
  service_name,
  date,
  time,
  duration_minutes,
  customer_name,
  customer_phone,
  customer_email,
  notes,
  staff_id,
  staff_name
) ON TABLE public.bookings TO authenticated;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.get_business_booking_manage_token(uuid);
-- GRANT SELECT, INSERT, UPDATE ON TABLE public.bookings TO anon;
-- GRANT SELECT, INSERT, UPDATE ON TABLE public.bookings TO authenticated;
-- COMMIT;
