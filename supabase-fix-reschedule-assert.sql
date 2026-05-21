-- Minimal fix: reschedule 400 (COALESCE text[] / jsonb on working_days)
-- Run once in Supabase Dashboard → SQL Editor → New query → Run
-- Does NOT replace create_booking.

-- 1) Working-days helper (text[] / jsonb / int[] safe)
CREATE OR REPLACE FUNCTION public._is_working_day(p_working_days anyelement, p_dow integer)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_default int[] := ARRAY[1, 2, 3, 4, 5];
BEGIN
  IF p_dow IS NULL THEN
    RETURN false;
  END IF;

  IF p_working_days IS NULL THEN
    RETURN p_dow = ANY (v_default);
  END IF;

  IF pg_typeof(p_working_days)::text = 'jsonb' THEN
    RETURN (p_working_days::jsonb @> to_jsonb(p_dow))
        OR (p_working_days::jsonb @> to_jsonb(p_dow::text));
  END IF;

  IF pg_typeof(p_working_days)::text = 'text[]' THEN
    RETURN (p_dow::text = ANY (p_working_days::text[]))
        OR EXISTS (
          SELECT 1
          FROM unnest(p_working_days::text[]) AS d(day_val)
          WHERE day_val::int = p_dow
        );
  END IF;

  IF pg_typeof(p_working_days)::text IN ('integer[]', 'smallint[]', 'bigint[]') THEN
    RETURN p_dow = ANY (p_working_days::int[]);
  END IF;

  RETURN to_jsonb(p_working_days) @> to_jsonb(p_dow);
EXCEPTION
  WHEN OTHERS THEN
    RETURN p_dow = ANY (v_default);
END;
$$;

-- 2) Shared slot validator (used by reschedule; excludes current booking)
CREATE OR REPLACE FUNCTION public._assert_booking_slot_available(
  p_business_id        uuid,
  p_service_id         uuid,
  p_date               date,
  p_time               time,
  p_staff_id           uuid DEFAULT NULL,
  p_exclude_booking_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings     public.business_settings%ROWTYPE;
  v_service      public.services%ROWTYPE;
  v_staff        public.staff_members%ROWTYPE;
  v_duration     integer;
  v_start_min    integer;
  v_end_min      integer;
  v_work_start   integer;
  v_work_end     integer;
  v_dow          integer;
  v_window_end   date;
  v_has_conflict boolean;
  v_date_text    text;
  v_break_start  integer;
  v_break_end    integer;
BEGIN
  IF p_business_id IS NULL OR p_service_id IS NULL OR p_date IS NULL OR p_time IS NULL THEN
    RAISE EXCEPTION 'Invalid booking slot parameters.' USING ERRCODE = 'P0001';
  END IF;

  v_date_text := to_char(p_date, 'YYYY-MM-DD');

  PERFORM pg_advisory_xact_lock(public._booking_day_lock_key(p_business_id, p_date));

  SELECT * INTO v_settings FROM public.business_settings bs WHERE bs.business_id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0001'; END IF;

  SELECT * INTO v_service FROM public.services s WHERE s.id = p_service_id AND s.business_id = p_business_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001'; END IF;

  v_duration := coalesce(nullif(v_service.duration, 0), 30);

  IF p_staff_id IS NOT NULL THEN
    SELECT * INTO v_staff FROM public.staff_members sm WHERE sm.id = p_staff_id AND sm.business_id = p_business_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001'; END IF;
    IF coalesce(v_staff.active, true) = false THEN
      RAISE EXCEPTION 'This staff member is not available for booking.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_date < CURRENT_DATE THEN RAISE EXCEPTION 'This date is in the past.' USING ERRCODE = 'P0001'; END IF;

  v_window_end := CURRENT_DATE + (coalesce(v_settings.booking_window_weeks, 4) * 7);
  IF p_date > v_window_end THEN RAISE EXCEPTION 'This date is outside the booking window.' USING ERRCODE = 'P0001'; END IF;

  v_dow := EXTRACT(DOW FROM p_date)::int;
  IF NOT public._is_working_day(v_settings.working_days, v_dow) THEN
    RAISE EXCEPTION 'This is not a working day.' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (SELECT 1 FROM public.blocked_days bd WHERE bd.business_id = p_business_id AND trim(bd.date::text) = v_date_text) THEN
    RAISE EXCEPTION 'This day is blocked and not available for booking.' USING ERRCODE = 'P0001';
  END IF;

  v_start_min := public._time_to_minutes(p_time);
  v_end_min   := v_start_min + v_duration;
  v_work_start := coalesce(public._booking_row_time_to_minutes(v_settings.work_start), public._time_to_minutes(time '09:00'));
  v_work_end   := coalesce(public._booking_row_time_to_minutes(v_settings.work_end), public._time_to_minutes(time '17:00'));

  IF v_start_min < v_work_start OR v_end_min > v_work_end THEN
    RAISE EXCEPTION 'This time is outside working hours.' USING ERRCODE = 'P0001';
  END IF;

  v_break_start := public._booking_row_time_to_minutes(v_settings.break_start);
  v_break_end   := public._booking_row_time_to_minutes(v_settings.break_end);

  IF v_break_start IS NOT NULL AND v_break_end IS NOT NULL THEN
    IF v_start_min < v_break_end AND v_end_min > v_break_start THEN
      RAISE EXCEPTION 'This time overlaps the break period.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.business_id = p_business_id
      AND trim(b.date::text) = v_date_text
      AND (p_exclude_booking_id IS NULL OR b.id <> p_exclude_booking_id)
      AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
      AND (p_staff_id IS NULL OR b.staff_id IS NULL OR b.staff_id = p_staff_id)
      AND public._booking_row_time_to_minutes(b.time) IS NOT NULL
      AND (
        v_start_min < public._booking_row_time_to_minutes(b.time) + coalesce(nullif(b.duration_minutes, 0), 30)
        AND v_end_min > public._booking_row_time_to_minutes(b.time)
      )
  ) INTO v_has_conflict;

  IF v_has_conflict THEN
    RAISE EXCEPTION 'This slot is not available. Another pending or confirmed booking already exists.' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

-- 3) Reschedule RPC (services.duration + text date/time like create_booking)
CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date         date,
  p_time         time
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token      text := nullif(trim(p_manage_token), '');
  v_row        public.bookings%ROWTYPE;
  v_status     text;
  v_duration   integer;
  v_date_text  text;
  v_time_text  text;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;
  IF p_date IS NULL OR p_time IS NULL THEN
    RAISE EXCEPTION 'Date and time are required.' USING ERRCODE = 'P0001';
  END IF;

  v_date_text := to_char(p_date, 'YYYY-MM-DD');
  v_time_text := to_char(p_time, 'HH24:MI');

  SELECT b.* INTO v_row FROM public.bookings b WHERE b.manage_token = v_token FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  v_status := lower(trim(coalesce(v_row.booking_status::text, v_row.status::text, 'pending')));
  IF v_status = 'cancelled' THEN
    RAISE EXCEPTION 'This booking is cancelled and cannot be rescheduled.' USING ERRCODE = 'P0001';
  END IF;

  PERFORM public._assert_booking_slot_available(
    v_row.business_id, v_row.service_id, p_date, p_time, v_row.staff_id, v_row.id
  );

  SELECT coalesce(nullif(s.duration, 0), 30) INTO v_duration
  FROM public.services s WHERE s.id = v_row.service_id;

  UPDATE public.bookings
  SET date = v_date_text, time = v_time_text, duration_minutes = v_duration
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'booking_ref', v_row.booking_ref,
    'booking_status', coalesce(v_row.booking_status::text, 'Pending'),
    'date', v_row.date,
    'time', v_row.time,
    'service_name', v_row.service_name,
    'can_manage', v_status <> 'cancelled'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) TO anon, authenticated, service_role;
