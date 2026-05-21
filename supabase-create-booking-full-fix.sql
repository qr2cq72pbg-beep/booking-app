CREATE OR REPLACE FUNCTION public._time_to_minutes(t time)
RETURNS integer
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT (EXTRACT(HOUR FROM t)::int * 60 + EXTRACT(MINUTE FROM t)::int);
$$;

CREATE OR REPLACE FUNCTION public._booking_row_time_to_minutes(t anyelement)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF t IS NULL THEN
    RETURN NULL;
  END IF;

  IF pg_typeof(t)::text = 'time without time zone' THEN
    RETURN public._time_to_minutes(t::time);
  END IF;

  RETURN public._time_to_minutes(trim(t::text)::time);
EXCEPTION
  WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._booking_active_status(s text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT lower(trim(coalesce(s, 'Pending'))) IN ('pending', 'confirmed');
$$;

CREATE OR REPLACE FUNCTION public._booking_day_lock_key(p_business_id uuid, p_date date)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT (
    ('x' || left(md5(p_business_id::text || '|' || p_date::text), 16))::bit(64)
  )::bigint;
$$;

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

CREATE OR REPLACE FUNCTION public._generate_manage_token()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_token text;
BEGIN
  LOOP
    v_token := encode(gen_random_bytes(32), 'hex');
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.bookings b WHERE b.manage_token = v_token
    );
  END LOOP;
  RETURN v_token;
END;
$$;

CREATE OR REPLACE FUNCTION public._generate_booking_ref(p_business_id uuid)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_ref text;
  v_try integer := 0;
BEGIN
  LOOP
    v_try := v_try + 1;
    v_ref := upper(substr(md5(gen_random_bytes(16)::text), 1, 8));
    EXIT WHEN NOT EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.business_id = p_business_id AND b.booking_ref = v_ref
    );
    IF v_try > 50 THEN
      RAISE EXCEPTION 'Could not generate booking reference.' USING ERRCODE = 'P0001';
    END IF;
  END LOOP;
  RETURN v_ref;
END;
$$;

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

  v_work_start := coalesce(
    public._booking_row_time_to_minutes(v_settings.work_start),
    public._time_to_minutes(time '09:00')
  );
  v_work_end := coalesce(
    public._booking_row_time_to_minutes(v_settings.work_end),
    public._time_to_minutes(time '17:00')
  );

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
    SELECT 1
    FROM public.bookings b
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
