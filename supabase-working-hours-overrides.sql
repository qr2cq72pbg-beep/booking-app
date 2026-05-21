-- Phase D: Optional per-weekday working hours overrides (JSON on business_settings).
-- Run once in Supabase Dashboard → SQL Editor after prior booking migration files.
-- Backward compatible: NULL or {} = use work_start / work_end for every working day.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS working_hours_overrides jsonb;

COMMENT ON COLUMN public.business_settings.working_hours_overrides IS
  'Optional per-day window: JSON object keyed by JS weekday 0–6 (Sun–Sat), values like {"start":"10:00","end":"14:00"}. Falls back to work_start/work_end when missing.';

-- Effective [start,end] minute bounds for a calendar date's weekday (0=Sun .. 6=Sat).
CREATE OR REPLACE FUNCTION public._effective_work_bounds_for_dow(
  p_settings public.business_settings,
  p_dow integer
)
RETURNS TABLE(ws integer, we integer)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_base_s integer;
  v_base_e integer;
  v_piece  jsonb;
  v_os     text;
  v_oe     text;
  v_os_m   integer;
  v_oe_m   integer;
BEGIN
  v_base_s :=
    coalesce(public._booking_row_time_to_minutes(p_settings.work_start), public._time_to_minutes(time '09:00'));
  v_base_e :=
    coalesce(public._booking_row_time_to_minutes(p_settings.work_end), public._time_to_minutes(time '17:00'));

  IF p_settings.working_hours_overrides IS NULL OR jsonb_typeof(p_settings.working_hours_overrides) <> 'object' THEN
    ws := v_base_s;
    we := v_base_e;
    RETURN NEXT;
    RETURN;
  END IF;

  v_piece := p_settings.working_hours_overrides -> (p_dow::text);
  IF v_piece IS NULL OR jsonb_typeof(v_piece) <> 'object' THEN
    ws := v_base_s;
    we := v_base_e;
    RETURN NEXT;
    RETURN;
  END IF;

  v_os := nullif(trim(v_piece ->> 'start'), '');
  v_oe := nullif(trim(v_piece ->> 'end'), '');

  IF v_os IS NOT NULL AND v_oe IS NOT NULL THEN
    v_os_m := public._booking_row_time_to_minutes(v_os);
    v_oe_m := public._booking_row_time_to_minutes(v_oe);
    IF v_os_m IS NOT NULL AND v_oe_m IS NOT NULL AND v_oe_m > v_os_m THEN
      ws := v_os_m;
      we := v_oe_m;
      RETURN NEXT;
      RETURN;
    END IF;
  END IF;

  ws := v_base_s;
  we := v_base_e;
  RETURN NEXT;
END;
$$;

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

  SELECT b.ws, b.we INTO v_work_start, v_work_end
  FROM public._effective_work_bounds_for_dow(v_settings, v_dow) AS b(ws, we);

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

-- Patch create_booking to use effective per-day bounds (must match assertion RPC).
-- Body aligned with supabase-create-booking-full-fix.sql plus per-day bounds.
CREATE OR REPLACE FUNCTION public.create_booking(
  p_business_id        uuid,
  p_service_id         uuid,
  p_date               date,
  p_time               time,
  p_customer_name      text,
  p_customer_phone     text,
  p_customer_email     text DEFAULT NULL,
  p_notes              text DEFAULT NULL,
  p_staff_id           uuid DEFAULT NULL,
  p_customer_user_id   uuid DEFAULT NULL,
  p_booking_status     text DEFAULT 'Pending'
)
RETURNS public.bookings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_settings       public.business_settings%ROWTYPE;
  v_service        public.services%ROWTYPE;
  v_staff          public.staff_members%ROWTYPE;
  v_booking        public.bookings%ROWTYPE;

  v_duration       integer;
  v_start_min      integer;
  v_end_min        integer;
  v_work_start     integer;
  v_work_end       integer;
  v_break_start    integer;
  v_break_end      integer;
  v_dow            integer;
  v_window_end     date;
  v_status         text;
  v_has_conflict   boolean;
  v_date_text      text;
  v_time_text      text;
  v_manage_token   text;
  v_booking_ref    text;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business ID is required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_service_id IS NULL THEN
    RAISE EXCEPTION 'Service is required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Date is required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_time IS NULL THEN
    RAISE EXCEPTION 'Time is required.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(trim(p_customer_name), '') = '' THEN
    RAISE EXCEPTION 'Customer name is required.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(trim(p_customer_phone), '') = '' THEN
    RAISE EXCEPTION 'Customer phone is required.' USING ERRCODE = 'P0001';
  END IF;

  v_status := initcap(lower(trim(coalesce(p_booking_status, 'Pending'))));
  IF v_status NOT IN ('Pending', 'Confirmed', 'Cancelled') THEN
    RAISE EXCEPTION 'Invalid booking status. Use Pending, Confirmed, or Cancelled.' USING ERRCODE = 'P0001';
  END IF;

  IF p_customer_user_id IS NOT NULL
     AND auth.uid() IS NOT NULL
     AND p_customer_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Customer account does not match the signed-in user.' USING ERRCODE = 'P0001';
  END IF;

  v_date_text := to_char(p_date, 'YYYY-MM-DD');
  v_time_text := to_char(p_time, 'HH24:MI');

  PERFORM pg_advisory_xact_lock(public._booking_day_lock_key(p_business_id, p_date));

  SELECT *
  INTO v_settings
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found. Check the booking link or business ID.' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_service
  FROM public.services s
  WHERE s.id = p_service_id
    AND s.business_id = p_business_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  v_duration := coalesce(nullif(v_service.duration, 0), 30);
  IF v_duration <= 0 THEN
    RAISE EXCEPTION 'Service duration must be greater than 0.' USING ERRCODE = 'P0001';
  END IF;

  v_start_min := public._time_to_minutes(p_time);
  v_end_min   := v_start_min + v_duration;

  IF p_staff_id IS NOT NULL THEN
    SELECT *
    INTO v_staff
    FROM public.staff_members sm
    WHERE sm.id = p_staff_id
      AND sm.business_id = p_business_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
    END IF;

    IF coalesce(v_staff.active, true) = false THEN
      RAISE EXCEPTION 'This staff member is not available for booking.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  IF p_date < CURRENT_DATE THEN
    RAISE EXCEPTION 'This date is in the past.' USING ERRCODE = 'P0001';
  END IF;

  v_window_end := CURRENT_DATE + (coalesce(v_settings.booking_window_weeks, 4) * 7);
  IF p_date > v_window_end THEN
    RAISE EXCEPTION 'This date is outside the booking window.' USING ERRCODE = 'P0001';
  END IF;

  v_dow := EXTRACT(DOW FROM p_date)::int;
  IF NOT public._is_working_day(v_settings.working_days, v_dow) THEN
    RAISE EXCEPTION 'This is not a working day.' USING ERRCODE = 'P0001';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.blocked_days bd
    WHERE bd.business_id = p_business_id
      AND trim(bd.date::text) = v_date_text
  ) THEN
    RAISE EXCEPTION 'This day is blocked and not available for booking.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.ws, b.we INTO v_work_start, v_work_end
  FROM public._effective_work_bounds_for_dow(v_settings, v_dow) AS b(ws, we);

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
      AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
      AND (
        p_staff_id IS NULL
        OR b.staff_id IS NULL
        OR b.staff_id = p_staff_id
      )
      AND public._booking_row_time_to_minutes(b.time) IS NOT NULL
      AND (
        v_start_min < public._booking_row_time_to_minutes(b.time) + coalesce(nullif(b.duration_minutes, 0), 30)
        AND v_end_min > public._booking_row_time_to_minutes(b.time)
      )
  )
  INTO v_has_conflict;

  IF v_has_conflict THEN
    RAISE EXCEPTION 'This slot is not available. Another pending or confirmed booking already exists.' USING ERRCODE = 'P0001';
  END IF;

  v_manage_token := public._generate_manage_token();
  v_booking_ref  := public._generate_booking_ref(p_business_id);

  INSERT INTO public.bookings (
    business_id,
    service_id,
    service_name,
    date,
    time,
    duration_minutes,
    customer_name,
    customer_phone,
    customer_email,
    notes,
    booking_status,
    staff_id,
    customer_user_id,
    manage_token,
    booking_ref
  )
  VALUES (
    p_business_id,
    v_service.id,
    v_service.name,
    v_date_text,
    v_time_text,
    v_duration,
    trim(p_customer_name),
    trim(p_customer_phone),
    nullif(trim(p_customer_email), ''),
    nullif(trim(p_notes), ''),
    v_status,
    p_staff_id,
    p_customer_user_id,
    v_manage_token,
    v_booking_ref
  )
  RETURNING * INTO v_booking;

  RETURN v_booking;
END;
$function$;

REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) TO anon, authenticated, service_role;
