-- =============================================================================
-- XBOOK: Harden customer membership for booking
-- Apply via linked CLI or Dashboard SQL Editor.
-- Safe to re-run (CREATE OR REPLACE). Does NOT:
--   backfill bookings, rewrite NULL customer_user_id, merge identities,
--   change analytics, or alter existing business_settings.require_client_approval.
--
-- After this file, also re-run supabase-booking-price-snapshot.sql so
-- create_booking / create_recurring_bookings store auth.uid() for customers.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Booking-time membership: exists + approval_status = approved
--    Missing membership is denied (never coalesced to approved).
--    Past bookings never auto-promote pending/rejected.
--    Owner / service_role bypass preserved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._evaluate_client_booking_approval(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_create_pending     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row          public.business_customers%ROWTYPE;
  v_status       text;
  v_caller_uid   uuid := auth.uid();
  v_jwt_role     text := coalesce(nullif(auth.jwt() ->> 'role', ''), '');
  v_lookup_uid   uuid;
BEGIN
  -- p_create_pending / phone / email / name kept for signature compatibility only.
  -- Booking-time membership is (business_id, customer_user_id) + approval_status.

  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'no_business',
      'message', 'Business not found.'
    );
  END IF;

  IF v_jwt_role = 'service_role' THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'service', 'message', '');
  END IF;

  IF v_caller_uid IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.business_settings bs
       WHERE bs.business_id = p_business_id AND bs.business_id = v_caller_uid
     ) THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'admin', 'message', '');
  END IF;

  v_lookup_uid := coalesce(v_caller_uid, p_customer_user_id);
  IF v_lookup_uid IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'auth',
      'message', 'This business requires an account to book.'
    );
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.customer_user_id = v_lookup_uid
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'no_membership',
      'message', 'Join this business with its Business Code before you can book.'
    );
  END IF;

  v_status := lower(trim(coalesce(v_row.approval_status, '')));

  IF v_status = 'blocked' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'blocked',
      'message', 'You cannot book with this business.'
    );
  END IF;

  IF v_status = 'rejected' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'rejected',
      'message', 'This business is not accepting your booking request at this time.'
    );
  END IF;

  IF v_status = 'pending' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'pending',
      'message', 'Your account is waiting for approval. You will be able to book after the business approves you.'
    );
  END IF;

  IF v_status = 'approved' THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'approved', 'message', '');
  END IF;

  RETURN jsonb_build_object(
    'allowed', false,
    'code', 'no_membership',
    'message', 'Join this business with its Business Code before you can book.'
  );
END;
$$;

COMMENT ON FUNCTION public._evaluate_client_booking_approval(uuid, uuid, text, text, text, boolean) IS
  'Customer booking gate: membership (business_id, customer_user_id) must exist and be approved. Owners bypass. Does not create membership or auto-approve from history.';

CREATE OR REPLACE FUNCTION public._assert_client_approval_for_booking(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public._evaluate_client_booking_approval(
    p_business_id,
    p_customer_user_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name,
    false
  );

  IF coalesce((v_result ->> 'allowed')::boolean, false) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION '%', coalesce(nullif(trim(v_result ->> 'message'), ''), 'Booking is not available.')
    USING ERRCODE = 'P0001';
END;
$$;

CREATE OR REPLACE FUNCTION public.check_client_booking_approval(
  p_business_id      uuid,
  p_customer_phone   text,
  p_customer_email   text DEFAULT NULL,
  p_customer_name    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'This business requires an account to book.' USING ERRCODE = 'P0001';
  END IF;

  RETURN public._evaluate_client_booking_approval(
    p_business_id,
    v_uid,
    p_customer_phone,
    p_customer_email,
    p_customer_name,
    false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_client_booking_approval(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_client_booking_approval(uuid, text, text, text)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public._resolve_booking_customer_user_id(
  p_business_id        uuid,
  p_customer_user_id   uuid
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_jwt_role text := coalesce(nullif(auth.jwt() ->> 'role', ''), '');
BEGIN
  IF v_jwt_role = 'service_role' THEN
    RETURN p_customer_user_id;
  END IF;
  IF v_caller IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.business_settings bs
       WHERE bs.business_id = p_business_id AND bs.business_id = v_caller
     ) THEN
    RETURN p_customer_user_id;
  END IF;
  RETURN v_caller;
END;
$$;

REVOKE ALL ON FUNCTION public._resolve_booking_customer_user_id(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._resolve_booking_customer_user_id(uuid, uuid)
  TO authenticated, service_role;

COMMIT;
