-- Booking limits per client (day + week).
-- Run once in Supabase Dashboard → SQL Editor AFTER:
--   supabase-auth-required-public-booking.sql
--   supabase-fix-reschedule-assert.sql (or supabase-business-closed-days-fix-rls.sql)
--
-- Adds business_settings columns and enforces limits in create_booking,
-- create_recurring_bookings, and reschedule_booking_by_manage_token.
-- Admin manual bookings (business owner caller) bypass limits.

-- ---------------------------------------------------------------------------
-- 1) Schema
-- ---------------------------------------------------------------------------
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS booking_limits_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS max_bookings_per_day integer NOT NULL DEFAULT 1;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS max_bookings_per_week integer NOT NULL DEFAULT 5;

COMMENT ON COLUMN public.business_settings.booking_limits_enabled IS
  'When true, customers cannot exceed max_bookings_per_day / max_bookings_per_week.';
COMMENT ON COLUMN public.business_settings.max_bookings_per_day IS
  'Max active (non-cancelled) bookings per client per calendar day (1–20).';
COMMENT ON COLUMN public.business_settings.max_bookings_per_week IS
  'Max active (non-cancelled) bookings per client per ISO calendar week (1–100).';

-- ---------------------------------------------------------------------------
-- 2) Client identity match (user id, email, or normalized phone)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._normalize_booking_phone(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(coalesce(trim(p), ''), '[\s\-().]', '', 'g');
$$;

CREATE OR REPLACE FUNCTION public._booking_belongs_to_client(
  b                    public.bookings,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    (p_customer_user_id IS NOT NULL AND b.customer_user_id = p_customer_user_id)
    OR (
      coalesce(nullif(lower(trim(p_customer_email)), ''), '') <> ''
      AND lower(trim(coalesce(b.customer_email, ''))) = lower(trim(p_customer_email))
    )
    OR (
      length(public._normalize_booking_phone(p_customer_phone)) >= 8
      AND public._normalize_booking_phone(b.customer_phone)
        = public._normalize_booking_phone(p_customer_phone)
    );
$$;

-- ---------------------------------------------------------------------------
-- 3) Limit assertion (skips admin owner + service_role; excludes booking on reschedule)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_client_booking_limits(
  p_business_id        uuid,
  p_date               date,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text DEFAULT NULL,
  p_exclude_booking_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings     public.business_settings%ROWTYPE;
  v_day_count    integer;
  v_week_count   integer;
  v_max_day      integer;
  v_max_week     integer;
  v_caller_uid   uuid := auth.uid();
  v_jwt_role     text := coalesce(nullif(auth.jwt() ->> 'role', ''), '');
BEGIN
  IF p_business_id IS NULL OR p_date IS NULL THEN
    RETURN;
  END IF;

  IF v_jwt_role = 'service_role' THEN
    RETURN;
  END IF;

  IF v_caller_uid IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = p_business_id
      AND bs.business_id = v_caller_uid
  ) THEN
    RETURN;
  END IF;

  SELECT * INTO v_settings FROM public.business_settings bs WHERE bs.business_id = p_business_id;
  IF NOT FOUND OR coalesce(v_settings.booking_limits_enabled, false) = false THEN
    RETURN;
  END IF;

  v_max_day := greatest(1, least(20, coalesce(v_settings.max_bookings_per_day, 1)));
  v_max_week := greatest(1, least(100, coalesce(v_settings.max_bookings_per_week, 5)));

  SELECT count(*)::integer
  INTO v_day_count
  FROM public.bookings b
  WHERE b.business_id = p_business_id
    AND trim(b.date::text) = to_char(p_date, 'YYYY-MM-DD')
    AND (p_exclude_booking_id IS NULL OR b.id <> p_exclude_booking_id)
    AND lower(trim(coalesce(b.booking_status::text, b.status::text, ''))) <> 'cancelled'
    AND public._booking_belongs_to_client(b, p_customer_user_id, p_customer_phone, p_customer_email);

  IF v_day_count >= v_max_day THEN
    RAISE EXCEPTION
      'Booking limit reached. You have reached the maximum number of bookings allowed for this day.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*)::integer
  INTO v_week_count
  FROM public.bookings b
  WHERE b.business_id = p_business_id
    AND date_trunc('week', b.date::date) = date_trunc('week', p_date)
    AND (p_exclude_booking_id IS NULL OR b.id <> p_exclude_booking_id)
    AND lower(trim(coalesce(b.booking_status::text, b.status::text, ''))) <> 'cancelled'
    AND public._booking_belongs_to_client(b, p_customer_user_id, p_customer_phone, p_customer_email);

  IF v_week_count >= v_max_week THEN
    RAISE EXCEPTION
      'Booking limit reached. You have reached the maximum number of bookings allowed for this week.'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._assert_client_booking_limits(uuid, date, uuid, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._assert_client_booking_limits(uuid, date, uuid, text, text, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) Patch create_booking — add limit check before insert
-- ---------------------------------------------------------------------------
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

  PERFORM public._assert_create_booking_caller(p_business_id, p_customer_user_id);

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

  IF public._is_business_date_closed(p_business_id, p_date) THEN
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

  PERFORM public._assert_client_booking_limits(
    p_business_id,
    p_date,
    p_customer_user_id,
    p_customer_phone,
    p_customer_email,
    NULL
  );

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

-- ---------------------------------------------------------------------------
-- 5) Patch create_recurring_bookings — limit check per occurrence before insert
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_recurring_bookings(
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
  p_booking_status     text DEFAULT 'Pending',
  p_recurring_rule     text DEFAULT NULL,
  p_recurring_count    integer DEFAULT NULL
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
  v_first_booking  public.bookings%ROWTYPE;

  v_duration       integer;
  v_status         text;
  v_rule           text;
  v_count          integer;
  v_step_days      integer;
  v_group_id       uuid;
  v_i              integer;
  v_occ_date       date;
  v_date_text      text;
  v_time_text      text;
  v_manage_token   text;
  v_booking_ref    text;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business ID is required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_service_id IS NULL OR p_date IS NULL OR p_time IS NULL THEN
    RAISE EXCEPTION 'Service, date and time are required.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(trim(p_customer_name), '') = '' OR coalesce(trim(p_customer_phone), '') = '' THEN
    RAISE EXCEPTION 'Customer name and phone are required.' USING ERRCODE = 'P0001';
  END IF;

  v_rule := lower(trim(coalesce(p_recurring_rule, '')));
  IF v_rule NOT IN ('weekly', 'biweekly') THEN
    RAISE EXCEPTION 'Invalid recurring rule. Use weekly or biweekly.' USING ERRCODE = 'P0001';
  END IF;

  v_count := coalesce(p_recurring_count, 0);
  IF v_count < 2 OR v_count > 6 THEN
    RAISE EXCEPTION 'Recurring count must be between 2 and 6.' USING ERRCODE = 'P0001';
  END IF;

  v_step_days := CASE WHEN v_rule = 'weekly' THEN 7 ELSE 14 END;

  v_status := initcap(lower(trim(coalesce(p_booking_status, 'Pending'))));
  IF v_status NOT IN ('Pending', 'Confirmed', 'Cancelled') THEN
    RAISE EXCEPTION 'Invalid booking status. Use Pending, Confirmed, or Cancelled.' USING ERRCODE = 'P0001';
  END IF;

  PERFORM public._assert_create_booking_caller(p_business_id, p_customer_user_id);

  SELECT * INTO v_settings FROM public.business_settings bs WHERE bs.business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found. Check the booking link or business ID.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(v_settings.allow_recurring_appointments, false) = false THEN
    RAISE EXCEPTION 'Recurring appointments are not enabled for this business.' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_service FROM public.services s
  WHERE s.id = p_service_id AND s.business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  v_duration := coalesce(nullif(v_service.duration, 0), 30);
  IF v_duration <= 0 THEN
    RAISE EXCEPTION 'Service duration must be greater than 0.' USING ERRCODE = 'P0001';
  END IF;

  IF p_staff_id IS NOT NULL THEN
    SELECT * INTO v_staff FROM public.staff_members sm
    WHERE sm.id = p_staff_id AND sm.business_id = p_business_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
    END IF;
    IF coalesce(v_staff.active, true) = false THEN
      RAISE EXCEPTION 'This staff member is not available for booking.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  v_time_text := to_char(p_time, 'HH24:MI');
  v_group_id := gen_random_uuid();

  FOR v_i IN 0..(v_count - 1) LOOP
    v_occ_date := p_date + (v_i * v_step_days);
    BEGIN
      PERFORM public._assert_booking_slot_available(
        p_business_id,
        p_service_id,
        v_occ_date,
        p_time,
        p_staff_id,
        NULL
      );
      PERFORM public._assert_client_booking_limits(
        p_business_id,
        v_occ_date,
        p_customer_user_id,
        p_customer_phone,
        p_customer_email,
        NULL
      );
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'Booking limit reached.%' THEN
          RAISE;
        END IF;
        RAISE EXCEPTION
          'Some repeat dates are unavailable. Please choose another time or reduce repeat count.'
          USING ERRCODE = 'P0001';
    END;
  END LOOP;

  FOR v_i IN 0..(v_count - 1) LOOP
    v_occ_date := p_date + (v_i * v_step_days);
    v_date_text := to_char(v_occ_date, 'YYYY-MM-DD');

    PERFORM pg_advisory_xact_lock(public._booking_day_lock_key(p_business_id, v_occ_date));

    PERFORM public._assert_booking_slot_available(
      p_business_id,
      p_service_id,
      v_occ_date,
      p_time,
      p_staff_id,
      NULL
    );

    PERFORM public._assert_client_booking_limits(
      p_business_id,
      v_occ_date,
      p_customer_user_id,
      p_customer_phone,
      p_customer_email,
      NULL
    );

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
      booking_ref,
      recurring_group_id,
      recurring_index,
      recurring_total,
      recurring_rule
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
      v_booking_ref,
      v_group_id,
      (v_i + 1)::smallint,
      v_count::smallint,
      v_rule
    )
    RETURNING * INTO v_booking;

    IF v_i = 0 THEN
      v_first_booking := v_booking;
    END IF;
  END LOOP;

  RETURN v_first_booking;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 6) Patch reschedule — exclude booking being moved; check limits on target date/week
-- ---------------------------------------------------------------------------
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

  PERFORM public._assert_client_booking_limits(
    v_row.business_id,
    p_date,
    v_row.customer_user_id,
    v_row.customer_phone,
    v_row.customer_email,
    v_row.id
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
