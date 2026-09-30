-- =============================================================================
-- XBOOK: Manage-token past-appointment guard
-- Apply to linked project after reading LIVE pg_get_functiondef bodies.
-- Safe to re-run (CREATE OR REPLACE). Does not change schema, RLS, grants
-- on existing RPCs, create_booking, or _assert_booking_slot_available.
--
-- Rule: date + time in business_settings.timezone vs now().
-- Past Pending/Confirmed: reject cancel/reschedule; status unchanged; can_manage false.
-- Cancelled: existing behaviour; can_manage false.
-- Unresolvable timezone/datetime: fail closed.
-- =============================================================================

BEGIN;

-- Internal helper. Not granted to PUBLIC / anon / authenticated / service_role.
CREATE OR REPLACE FUNCTION public._manage_booking_appointment_start(
  p_business_id uuid,
  p_date text,
  p_time text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_tz text;
BEGIN
  SELECT nullif(trim(bs.timezone), '')
    INTO v_tz
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  IF v_tz IS NULL THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names tz WHERE tz.name = v_tz) THEN
    RETURN NULL;
  END IF;

  RETURN public._performance_appointment_start(
    nullif(trim(p_date), ''),
    nullif(trim(p_time), ''),
    v_tz
  );
END;
$$;

COMMENT ON FUNCTION public._manage_booking_appointment_start(uuid, text, text) IS
  'Internal: bookings.date + bookings.time as timestamptz in business_settings.timezone. NULL if unresolved. Not for client EXECUTE.';

REVOKE ALL ON FUNCTION public._manage_booking_appointment_start(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._manage_booking_appointment_start(uuid, text, text) FROM anon;
REVOKE ALL ON FUNCTION public._manage_booking_appointment_start(uuid, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public._manage_booking_appointment_start(uuid, text, text) FROM service_role;

-- -----------------------------------------------------------------------------
-- cancel_booking_by_manage_token — live body + past guard only
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_booking_by_manage_token(p_manage_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token text := nullif(trim(p_manage_token), '');
  v_row   public.bookings%ROWTYPE;
  v_status text;
  v_start timestamptz;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.* INTO v_row FROM public.bookings b WHERE b.manage_token = v_token FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001'; END IF;

  v_status := lower(trim(coalesce(v_row.booking_status::text, v_row.status::text, 'pending')));
  IF v_status = 'cancelled' THEN
    RETURN jsonb_build_object('id', v_row.id, 'booking_status', 'Cancelled', 'already_cancelled', true);
  END IF;

  v_start := public._manage_booking_appointment_start(
    v_row.business_id,
    v_row.date::text,
    v_row.time::text
  );
  IF v_start IS NULL OR v_start < now() THEN
    RAISE EXCEPTION 'This appointment is in the past and can no longer be changed.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.bookings SET booking_status = 'Cancelled' WHERE id = v_row.id RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'id', v_row.id,
    'booking_status', 'Cancelled',
    'booking_ref', v_row.booking_ref
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- get_booking_by_manage_token — live body + can_manage past/fail-closed
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_booking_by_manage_token(p_manage_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token text := nullif(trim(p_manage_token), '');
  v_row   public.bookings%ROWTYPE;
  v_staff_name text;
  v_slug text;
  v_start timestamptz;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.* INTO v_row FROM public.bookings b WHERE b.manage_token = v_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Booking not found. Check your manage link.' USING ERRCODE = 'P0001';
  END IF;

  IF v_row.staff_id IS NOT NULL THEN
    SELECT sm.name INTO v_staff_name FROM public.staff_members sm WHERE sm.id = v_row.staff_id;
  END IF;

  SELECT nullif(trim(bs.business_slug), '') INTO v_slug
  FROM public.business_settings bs WHERE bs.business_id = v_row.business_id;

  v_start := public._manage_booking_appointment_start(
    v_row.business_id,
    v_row.date::text,
    v_row.time::text
  );

  RETURN jsonb_build_object(
    'id', v_row.id,
    'business_id', v_row.business_id,
    'booking_ref', v_row.booking_ref,
    'booking_status', coalesce(v_row.booking_status::text, v_row.status::text, 'Pending'),
    'date', v_row.date,
    'time', to_char(v_row.time::time, 'HH24:MI'),
    'duration_minutes', coalesce(v_row.duration_minutes, 30),
    'service_id', v_row.service_id,
    'service_name', v_row.service_name,
    'staff_id', v_row.staff_id,
    'staff_name', v_staff_name,
    'customer_name', v_row.customer_name,
    'notes', v_row.notes,
    'business_slug', v_slug,
    'can_manage', lower(trim(coalesce(v_row.booking_status::text, v_row.status::text, 'pending'))) <> 'cancelled'
      AND v_start IS NOT NULL
      AND v_start >= now()
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- reschedule (text, date, time) — live body + source-past guard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date date,
  p_time time without time zone
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
  v_start      timestamptz;
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

  v_start := public._manage_booking_appointment_start(
    v_row.business_id,
    v_row.date::text,
    v_row.time::text
  );
  IF v_start IS NULL OR v_start < now() THEN
    RAISE EXCEPTION 'This appointment is in the past and can no longer be changed.' USING ERRCODE = 'P0001';
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

-- -----------------------------------------------------------------------------
-- reschedule (text, date, text) — live body + source-past guard
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date date,
  p_time text
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
  v_start      timestamptz;
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

  v_start := public._manage_booking_appointment_start(
    v_row.business_id,
    v_row.date::text,
    v_row.time::text
  );
  IF v_start IS NULL OR v_start < now() THEN
    RAISE EXCEPTION 'This appointment is in the past and can no longer be changed.' USING ERRCODE = 'P0001';
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

-- Preserve existing client EXECUTE on the public manage-token RPCs.
GRANT EXECUTE ON FUNCTION public.cancel_booking_by_manage_token(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_booking_by_manage_token(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) TO anon, authenticated, service_role;

COMMIT;
