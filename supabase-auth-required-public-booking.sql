-- Auth-required public/customer booking (blocks anonymous create_booking).
-- Run once in Supabase Dashboard → SQL Editor AFTER:
--   supabase-create-booking-full-fix.sql
--   supabase-working-hours-overrides.sql
--   supabase-recurring-bookings-v1.sql (if recurring is enabled)
--
-- What this changes:
--   • Anonymous callers (auth.uid() IS NULL) cannot create bookings.
--   • Customer role must pass p_customer_user_id = auth.uid().
--   • Admin/business owner may still create manual bookings (customer_user_id optional).
--   • Ownership: business_settings.business_id IS the admin auth.users.id (verified in app + RLS).
--   • Existing rows are untouched; only RPC entry is guarded.

-- ---------------------------------------------------------------------------
-- 1) Shared caller guard
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_create_booking_caller(
  p_business_id        uuid,
  p_customer_user_id   uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_uid       uuid := auth.uid();
  v_caller_role      text;
  v_jwt_role         text;
  v_owns_business    boolean;
BEGIN
  v_jwt_role := coalesce(nullif(auth.jwt() ->> 'role', ''), '');

  -- Preserve service_role / backend automation path.
  IF v_jwt_role = 'service_role' THEN
    RETURN;
  END IF;

  IF v_caller_uid IS NULL THEN
    RAISE EXCEPTION 'This business requires an account to book.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(up.role, '')))
  INTO v_caller_role
  FROM public.user_profiles up
  WHERE up.id = v_caller_uid;

  -- XBOOK ownership: business_settings.business_id = admin auth.users.id.
  -- user_profiles is optional for owners (legacy admins may have no profile row).
  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = p_business_id
      AND bs.business_id = v_caller_uid
  )
  INTO v_owns_business;

  -- Business owner manual booking — profile row not required (matches restoreAdminSession).
  IF v_owns_business THEN
    RETURN;
  END IF;

  -- Customer self-booking at another business (public link).
  IF v_caller_role = 'customer' THEN
    IF p_customer_user_id IS NULL OR p_customer_user_id IS DISTINCT FROM v_caller_uid THEN
      RAISE EXCEPTION 'This business requires an account to book.' USING ERRCODE = 'P0001';
    END IF;
    RETURN;
  END IF;

  RAISE EXCEPTION 'This business requires an account to book.' USING ERRCODE = 'P0001';
END;
$$;

REVOKE ALL ON FUNCTION public._assert_create_booking_caller(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._assert_create_booking_caller(uuid, uuid) TO authenticated, service_role;

COMMENT ON FUNCTION public._assert_create_booking_caller(uuid, uuid) IS
  'Enforces auth for create_booking / create_recurring_bookings: customers must self-link; admins may manual-book.';

-- ---------------------------------------------------------------------------
-- 2) create_booking — replace auth block only (body aligned with working-hours patch)
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
) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM anon;

-- ---------------------------------------------------------------------------
-- 3) create_recurring_bookings — same auth guard (public customer flow only)
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
    EXCEPTION
      WHEN OTHERS THEN
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

REVOKE ALL ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) TO authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM anon;

-- =============================================================================
-- ROLLBACK (commented out — uncomment and run only if you need to revert)
-- =============================================================================
-- Step 1: Drop the auth guard helper.
-- DROP FUNCTION IF EXISTS public._assert_create_booking_caller(uuid, uuid);
--
-- Step 2: Restore prior RPC bodies from your repo (run in SQL Editor):
--   • supabase-working-hours-overrides.sql  → create_booking (lines 178–411)
--   • supabase-recurring-bookings-v1.sql    → create_recurring_bookings (lines 22–227)
--
-- Step 3: Re-grant anon execute (restores anonymous RPC access — pre-migration state).
-- GRANT EXECUTE ON FUNCTION public.create_booking(
--   uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
-- ) TO anon, authenticated, service_role;
--
-- GRANT EXECUTE ON FUNCTION public.create_recurring_bookings(
--   uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
-- ) TO anon, authenticated, service_role;
