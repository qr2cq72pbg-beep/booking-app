-- XBOOK: Customer leaves one business membership.
-- Unlinks auth.uid() from this business CRM row. Does NOT delete
-- business_customers, bookings, notes, auth user, or other memberships.
-- Does not change approval_status, owner block/reject, or booking rows.

BEGIN;

CREATE OR REPLACE FUNCTION public.leave_customer_business(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_row public.business_customers%ROWTYPE;
  v_now_min integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer memberships only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.customer_user_id = v_uid
  LIMIT 1;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'You are not a member of this business.' USING ERRCODE = 'P0001';
  END IF;

  v_now_min :=
    EXTRACT(HOUR FROM LOCALTIME)::int * 60
    + EXTRACT(MINUTE FROM LOCALTIME)::int;

  IF EXISTS (
    SELECT 1
    FROM public.bookings b
    WHERE b.business_id = p_business_id
      AND b.customer_user_id = v_uid
      AND public._booking_active_status(
        coalesce(b.booking_status::text, b.status::text)
      )
      AND nullif(trim(b.date::text), '') IS NOT NULL
      AND (
        trim(b.date::text)::date > CURRENT_DATE
        OR (
          trim(b.date::text)::date = CURRENT_DATE
          AND coalesce(public._booking_row_time_to_minutes(b.time), 0) >= v_now_min
        )
      )
  ) THEN
    RAISE EXCEPTION
      'You have an upcoming appointment with this business. Cancel it before leaving.'
      USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.business_customers
  SET
    customer_user_id = NULL,
    updated_at = now()
  WHERE id = v_row.id
    AND business_id = p_business_id
    AND customer_user_id = v_uid
  RETURNING * INTO v_row;

  IF v_row.id IS NULL OR v_row.customer_user_id IS NOT NULL THEN
    RAISE EXCEPTION 'You are not a member of this business.' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'business_id', p_business_id
  );
END;
$$;

COMMENT ON FUNCTION public.leave_customer_business(uuid) IS
  'Authenticated customer only. Unlinks auth.uid() from this business CRM row (customer_user_id = NULL). Does not delete the row, bookings, notes, or other memberships. Blocks leave when a future Pending/Confirmed booking exists.';

REVOKE ALL ON FUNCTION public.leave_customer_business(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.leave_customer_business(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.leave_customer_business(uuid) TO authenticated;

COMMIT;
