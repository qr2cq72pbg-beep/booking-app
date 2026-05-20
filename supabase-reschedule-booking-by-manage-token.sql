-- Phase 2: reschedule_booking_by_manage_token (manage link)
-- Run once in Supabase Dashboard → SQL Editor.
-- Requires public._assert_booking_slot_available (see supabase-fix-reschedule-assert.sql).

DROP FUNCTION IF EXISTS public.reschedule_booking_by_manage_token(text, date, time);

CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date         date,
  p_time         text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token      text := nullif(trim(p_manage_token), '');
  v_time_raw   text := nullif(trim(p_time), '');
  v_time       time;
  v_row        public.bookings%ROWTYPE;
  v_status     text;
  v_duration   integer;
  v_date_text  text;
  v_time_text  text;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;
  IF p_date IS NULL OR v_time_raw IS NULL THEN
    RAISE EXCEPTION 'Date and time are required.' USING ERRCODE = 'P0001';
  END IF;

  BEGIN
    v_time := v_time_raw::time;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE EXCEPTION 'Time is invalid.' USING ERRCODE = 'P0001';
  END;

  v_date_text := to_char(p_date, 'YYYY-MM-DD');
  v_time_text := to_char(v_time, 'HH24:MI');

  SELECT b.* INTO v_row FROM public.bookings b WHERE b.manage_token = v_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  v_status := lower(trim(coalesce(v_row.booking_status::text, v_row.status::text, 'pending')));
  IF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'This booking is cancelled and cannot be rescheduled.' USING ERRCODE = 'P0001';
  END IF;

  PERFORM public._assert_booking_slot_available(
    v_row.business_id, v_row.service_id, p_date, v_time, v_row.staff_id, v_row.id
  );

  SELECT coalesce(nullif(s.duration, 0), 30) INTO v_duration
  FROM public.services s WHERE s.id = v_row.service_id;

  UPDATE public.bookings
  SET date = v_date_text, time = v_time_text, duration_minutes = v_duration
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'business_id', v_row.business_id,
    'service_id', v_row.service_id,
    'staff_id', v_row.staff_id,
    'booking_ref', v_row.booking_ref,
    'booking_status', coalesce(v_row.booking_status::text, 'Pending'),
    'customer_name', v_row.customer_name,
    'service_name', v_row.service_name,
    'date', v_row.date,
    'time', v_row.time,
    'can_manage', true
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) TO anon, authenticated, service_role;
