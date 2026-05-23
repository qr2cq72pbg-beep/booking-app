-- Recurring bookings V1 (weekly / every 2 weeks, max 6 occurrences).
-- Run once in Supabase Dashboard → SQL Editor after supabase-working-hours-overrides.sql.
-- Does not replace create_booking; adds create_recurring_bookings for series only.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS allow_recurring_appointments boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.business_settings.allow_recurring_appointments IS
  'When true, public booking may offer weekly or biweekly repeat (V1, max 6 total).';

ALTER TABLE public.bookings
  ADD COLUMN IF NOT EXISTS recurring_group_id uuid,
  ADD COLUMN IF NOT EXISTS recurring_index smallint,
  ADD COLUMN IF NOT EXISTS recurring_total smallint,
  ADD COLUMN IF NOT EXISTS recurring_rule text;

COMMENT ON COLUMN public.bookings.recurring_group_id IS 'Shared UUID for a recurring series (V1).';
COMMENT ON COLUMN public.bookings.recurring_index IS '1-based index within the series.';
COMMENT ON COLUMN public.bookings.recurring_total IS 'Total appointments in the series.';
COMMENT ON COLUMN public.bookings.recurring_rule IS 'weekly or biweekly (V1).';

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

  IF p_customer_user_id IS NOT NULL
     AND auth.uid() IS NOT NULL
     AND p_customer_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Customer account does not match the signed-in user.' USING ERRCODE = 'P0001';
  END IF;

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
) TO anon, authenticated, service_role;
