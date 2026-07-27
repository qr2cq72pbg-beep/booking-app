-- ============================================================================
-- STRICT STAFF ASSIGNMENT ARCHITECTURE
-- ============================================================================
-- Run in Supabase Dashboard → SQL Editor.
--
-- This file is split into clearly-labeled sections:
--   0) DIAGNOSTICS (read-only)   — RUN THIS FIRST, review the output.
--   1) SCHEMA (non-destructive)  — adds a column + index, never removes data.
--   2) ensure_owner_staff_member — idempotent, race-safe RPC used by
--                                  onboarding + the "zero staff" healing path.
--   3) Booking RPC patches       — makes p_staff_id mandatory going forward
--                                  in create_booking / create_recurring_bookings,
--                                  reusing the exact latest bodies from
--                                  supabase-booking-limits.sql /
--                                  supabase-business-closed-days-fix-rls.sql.
--   4) Staff delete/deactivate guard — DB trigger that blocks deleting the
--                                  last staff row, or the row referenced by
--                                  any appointment, or blanking staff_id on
--                                  an existing booking.
--   5) OPTIONAL DATA BACKFILL    — DO NOT RUN until you have reviewed the
--                                  diagnostics output with me. Commented out.
--   6) OPTIONAL NOT-NULL CONSTRAINT — DO NOT RUN until (5) is confirmed safe
--                                  and diagnostics show 0 remaining nulls on
--                                  active/future bookings. Commented out.
--
-- Nothing in sections 0–4 deletes or mutates existing rows. Sections 5 and 6
-- are intentionally commented out and require your explicit go-ahead.
-- ============================================================================


-- ============================================================================
-- 0) DIAGNOSTICS — read-only, safe to run any time, run this first
-- ============================================================================

-- 0a) Current staff_members schema (columns/types/nullability/defaults)
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'staff_members'
ORDER BY ordinal_position;

-- 0b) Current bookings schema (confirms staff_id nullability today)
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'bookings'
ORDER BY ordinal_position;

-- 0c) Businesses with ZERO staff_members rows at all
SELECT bs.business_id, bs.business_name
FROM public.business_settings bs
WHERE NOT EXISTS (
  SELECT 1 FROM public.staff_members sm WHERE sm.business_id = bs.business_id
);

-- 0d) Businesses with staff rows but ZERO active/bookable staff
SELECT bs.business_id, bs.business_name,
       count(sm.id) AS total_staff,
       count(*) FILTER (WHERE coalesce(sm.active, true)) AS active_staff
FROM public.business_settings bs
JOIN public.staff_members sm ON sm.business_id = bs.business_id
GROUP BY bs.business_id, bs.business_name
HAVING count(*) FILTER (WHERE coalesce(sm.active, true)) = 0;

-- 0e) Bookings with NULL staff_id — broken down by status + past/future,
--     and how many DISTINCT active staff each affected business currently has
--     (this tells us which rows are safe to auto-backfill vs. need review).
SELECT
  b.business_id,
  coalesce(b.booking_status::text, b.status::text) AS status,
  (b.date::date >= CURRENT_DATE) AS is_future,
  count(*) AS null_staff_bookings,
  (SELECT count(*) FROM public.staff_members sm
     WHERE sm.business_id = b.business_id AND coalesce(sm.active, true)) AS active_staff_count
FROM public.bookings b
WHERE b.staff_id IS NULL
GROUP BY b.business_id, coalesce(b.booking_status::text, b.status::text), (b.date::date >= CURRENT_DATE), b.business_id
ORDER BY b.business_id, is_future DESC;

-- 0f) Grand totals for a quick read
SELECT
  count(*) AS total_null_staff_bookings,
  count(*) FILTER (WHERE b.date::date >= CURRENT_DATE) AS future_null_staff_bookings,
  count(*) FILTER (
    WHERE b.date::date >= CURRENT_DATE
      AND lower(coalesce(b.booking_status::text, b.status::text)) IN ('pending', 'confirmed')
  ) AS active_future_null_staff_bookings
FROM public.bookings b
WHERE b.staff_id IS NULL;


-- ============================================================================
-- 1) SCHEMA — non-destructive additions only
-- ============================================================================

-- Internal marker used ONLY for duplicate-prevention + integrity rules.
-- Not surfaced in the UI as a special/protected record.
ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS is_owner boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.staff_members.is_owner IS
  'True for the auto-created staff record representing the business owner. '
  'Used only for idempotent-creation checks; not a UI-visible "system record" flag.';

-- At most one owner-marked staff row per business (race-safe with the RPC below).
CREATE UNIQUE INDEX IF NOT EXISTS staff_members_one_owner_per_business
  ON public.staff_members (business_id)
  WHERE is_owner = true;

CREATE INDEX IF NOT EXISTS staff_members_business_id_idx
  ON public.staff_members (business_id);


-- ============================================================================
-- 2) ensure_owner_staff_member — idempotent, concurrency-safe
-- ============================================================================
-- Used by:
--   • Onboarding step 4 (solo owner / first-time setup)
--   • The healing path (existing businesses that currently have 0 staff)
--
-- Safety:
--   • Caller must be the authenticated business owner (auth.uid() = p_business_id).
--   • Advisory lock keyed on business_id serializes concurrent calls so two
--     simultaneous loads (e.g. two browser tabs) cannot both insert.
--   • Re-checks "does this business already have ANY staff row" AFTER taking
--     the lock, so it never creates a second staff member.
CREATE OR REPLACE FUNCTION public.ensure_owner_staff_member(
  p_business_id uuid,
  p_name        text,
  p_role        text DEFAULT NULL,
  p_photo_url   text DEFAULT NULL
)
RETURNS public.staff_members
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_uid uuid := auth.uid();
  v_jwt_role   text := coalesce(nullif(auth.jwt() ->> 'role', ''), '');
  v_existing   public.staff_members%ROWTYPE;
  v_new        public.staff_members%ROWTYPE;
  v_name       text := coalesce(nullif(trim(p_name), ''), 'Owner');
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business ID is required.' USING ERRCODE = 'P0001';
  END IF;

  IF v_jwt_role <> 'service_role' THEN
    IF v_caller_uid IS NULL OR v_caller_uid IS DISTINCT FROM p_business_id THEN
      RAISE EXCEPTION 'Only the business owner can perform this action.' USING ERRCODE = 'P0001';
    END IF;
  END IF;

  -- Serialize concurrent onboarding/healing calls for the same business.
  PERFORM pg_advisory_xact_lock(hashtextextended('ensure_owner_staff_member:' || p_business_id::text, 0));

  SELECT * INTO v_existing
  FROM public.staff_members sm
  WHERE sm.business_id = p_business_id
  ORDER BY sm.created_at ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN v_existing;
  END IF;

  INSERT INTO public.staff_members (business_id, name, role, active, is_owner, photo_url)
  VALUES (p_business_id, v_name, nullif(trim(coalesce(p_role, '')), ''), true, true, nullif(trim(coalesce(p_photo_url, '')), ''))
  RETURNING * INTO v_new;

  RETURN v_new;
EXCEPTION
  WHEN unique_violation THEN
    -- Another concurrent call won the race despite the advisory lock (e.g. lock
    -- key hash collision or manual insert) — return the row that exists now.
    SELECT * INTO v_existing
    FROM public.staff_members sm
    WHERE sm.business_id = p_business_id
    ORDER BY sm.created_at ASC
    LIMIT 1;
    RETURN v_existing;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_owner_staff_member(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_owner_staff_member(uuid, text, text, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.ensure_owner_staff_member(uuid, text, text, text) IS
  'Idempotent: creates exactly one owner staff row if (and only if) the business '
  'currently has zero staff_members rows. Safe to call on every load.';


-- ============================================================================
-- 3) Booking RPC patches — p_staff_id becomes mandatory for NEW bookings
-- ============================================================================
-- These CREATE OR REPLACE statements are the exact latest bodies from
-- supabase-booking-limits.sql / supabase-business-closed-days-fix-rls.sql,
-- with one addition: a staff-is-required check before the existing
-- staff-exists/active validation. Reschedule (which only moves date/time,
-- never assigns staff) is intentionally NOT changed here — it keeps
-- validating whatever staff_id already exists on the row, so historical
-- null-staff bookings can still be rescheduled by their owner. See sections
-- 5 and 6 below (in this same file) for the discussion on backfilling those
-- historical rows.

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

  -- STRICT STAFF ASSIGNMENT: every business must have >=1 active staff member
  -- (see ensure_owner_staff_member / healing path), so a staff selection is
  -- now mandatory for every new booking.
  IF p_staff_id IS NULL THEN
    RAISE EXCEPTION 'Please choose a team member for this booking.' USING ERRCODE = 'P0001';
  END IF;

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

  -- Overlap check is scoped to this exact staff member (plus any legacy
  -- null-staff rows, which still block everyone as before) — Staff A being
  -- booked never blocks the same time for Staff B.
  SELECT EXISTS (
    SELECT 1 FROM public.bookings b
    WHERE b.business_id = p_business_id
      AND trim(b.date::text) = v_date_text
      AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
      AND (
        b.staff_id IS NULL
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

  -- STRICT STAFF ASSIGNMENT: mandatory staff for every occurrence in the series.
  IF p_staff_id IS NULL THEN
    RAISE EXCEPTION 'Please choose a team member for this booking.' USING ERRCODE = 'P0001';
  END IF;

  SELECT * INTO v_staff FROM public.staff_members sm
  WHERE sm.id = p_staff_id AND sm.business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  IF coalesce(v_staff.active, true) = false THEN
    RAISE EXCEPTION 'This staff member is not available for booking.' USING ERRCODE = 'P0001';
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

-- _assert_booking_slot_available: adds an optional p_require_staff flag
-- (defaults to true = mandatory) so recurring-booking creation enforces the
-- new rule, while reschedule (below) explicitly opts out so historical
-- null-staff bookings can still be rescheduled without inventing a staff pick.
CREATE OR REPLACE FUNCTION public._assert_booking_slot_available(
  p_business_id        uuid,
  p_service_id         uuid,
  p_date               date,
  p_time               time,
  p_staff_id           uuid DEFAULT NULL,
  p_exclude_booking_id uuid DEFAULT NULL,
  p_require_staff      boolean DEFAULT true
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

  IF p_require_staff AND p_staff_id IS NULL THEN
    RAISE EXCEPTION 'Please choose a team member for this booking.' USING ERRCODE = 'P0001';
  END IF;

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

  IF public._is_business_date_closed(p_business_id, p_date) THEN
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

-- reschedule_booking_by_manage_token: unchanged behaviour, but now calls
-- _assert_booking_slot_available with p_require_staff := false so a
-- historical null-staff booking can still be rescheduled by its own
-- customer without us inventing a staff pick on their behalf. Staff-active
-- revalidation for bookings that DO have a staff_id still happens exactly
-- as before (inside the shared assert function).
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
    v_row.business_id, v_row.service_id, p_date, p_time, v_row.staff_id, v_row.id, false
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


-- ============================================================================
-- 4) Staff delete/deactivate integrity guard
-- ============================================================================
-- Blocks, at the database layer (defense in depth beneath the app-layer
-- checks), the two ways a business could accidentally end up with zero
-- staff capable of receiving bookings:
--   a) deleting the last remaining staff_members row for a business
--   b) hard-deleting a staff member that is referenced by any booking
-- Deactivating (active = false) is intentionally NOT blocked here — that is
-- a soft, reversible action gated by an app-layer confirmation dialog per
-- spec section 7 ("...unless the owner explicitly confirms").
CREATE OR REPLACE FUNCTION public._guard_staff_member_delete()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_other_staff_count integer;
  v_booking_ref_count  integer;
BEGIN
  SELECT count(*) INTO v_other_staff_count
  FROM public.staff_members sm
  WHERE sm.business_id = OLD.business_id AND sm.id <> OLD.id;

  IF v_other_staff_count = 0 THEN
    RAISE EXCEPTION 'Your business must have at least one team member to receive bookings.'
      USING ERRCODE = 'P0001';
  END IF;

  SELECT count(*) INTO v_booking_ref_count
  FROM public.bookings b
  WHERE b.staff_id = OLD.id;

  IF v_booking_ref_count > 0 THEN
    RAISE EXCEPTION 'This team member has booking history and cannot be deleted. Deactivate them instead.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS staff_members_guard_delete ON public.staff_members;
CREATE TRIGGER staff_members_guard_delete
  BEFORE DELETE ON public.staff_members
  FOR EACH ROW
  EXECUTE FUNCTION public._guard_staff_member_delete();


-- ============================================================================
-- Bookings staff_id integrity guard (defense in depth beneath the RPCs above)
-- ============================================================================
-- • New rows always require a staff_id (all current insert paths are the
--   RPCs above, which already enforce this — this trigger protects against
--   any other/future insert path, e.g. a direct PostgREST insert).
-- • Existing rows can never have their staff_id blanked back to NULL by an
--   update (this stops an accidental admin edit from erasing an assignment);
--   rows that are ALREADY null (historical data) are left alone so unrelated
--   updates (status changes, etc.) keep working.
CREATE OR REPLACE FUNCTION public._enforce_bookings_staff_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.staff_id IS NULL THEN
      RAISE EXCEPTION 'A team member must be selected for this booking.' USING ERRCODE = 'P0001';
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF OLD.staff_id IS NOT NULL AND NEW.staff_id IS NULL THEN
      RAISE EXCEPTION 'A team member must remain assigned to this booking.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_enforce_staff_id ON public.bookings;
CREATE TRIGGER bookings_enforce_staff_id
  BEFORE INSERT OR UPDATE ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_bookings_staff_id();


-- ============================================================================
-- 5) OPTIONAL DATA BACKFILL — DO NOT RUN YET
-- ============================================================================
-- Only backfills ACTIVE/FUTURE bookings (pending/confirmed, date >= today)
-- whose business currently has EXACTLY ONE active staff member — i.e. the
-- only case where assignment is unambiguous. Everything else (multiple
-- possible staff, past bookings, cancelled bookings) is intentionally left
-- untouched for manual owner review.
--
-- Uncomment and run only after reviewing the diagnostics in section 0 with
-- me and confirming the row counts look right for your data.
--
-- WITH single_staff_business AS (
--   SELECT sm.business_id, min(sm.id) AS only_staff_id
--   FROM public.staff_members sm
--   WHERE coalesce(sm.active, true)
--   GROUP BY sm.business_id
--   HAVING count(*) = 1
-- )
-- UPDATE public.bookings b
-- SET staff_id = ssb.only_staff_id
-- FROM single_staff_business ssb
-- WHERE b.staff_id IS NULL
--   AND b.business_id = ssb.business_id
--   AND b.date::date >= CURRENT_DATE
--   AND lower(coalesce(b.booking_status::text, b.status::text)) IN ('pending', 'confirmed');


-- ============================================================================
-- 6) OPTIONAL NOT NULL CONSTRAINT — DO NOT RUN YET
-- ============================================================================
-- Only safe once diagnostics (section 0e/0f) show zero remaining NULL
-- staff_id rows among active/future bookings (after section 5, if applicable).
-- Historical/cancelled rows with NULL staff_id are expected to remain and
-- this constraint would fail with them in place — do NOT force it through
-- by touching historical data. Enforcement already happens at the RPC layer
-- (section 3) and the trigger layer (section 4) without needing this.
--
-- ALTER TABLE public.bookings
--   ALTER COLUMN staff_id SET NOT NULL; -- will fail if ANY row (incl. historical) is NULL
