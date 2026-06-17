-- XBOOK: Fix closed days save (RLS) — run once in Supabase SQL Editor.
-- Source of truth: business_closed_days
-- blocked_days is legacy mirror for create_booking RPC (synced by trigger, not client).

-- 1) Owner RLS on business_closed_days (business_id = admin auth.users.id)
DROP POLICY IF EXISTS business_closed_days_owner_select ON public.business_closed_days;
CREATE POLICY business_closed_days_owner_select
  ON public.business_closed_days
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS business_closed_days_owner_insert ON public.business_closed_days;
CREATE POLICY business_closed_days_owner_insert
  ON public.business_closed_days
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_closed_days_owner_update ON public.business_closed_days;
CREATE POLICY business_closed_days_owner_update
  ON public.business_closed_days
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_closed_days_owner_delete ON public.business_closed_days;
CREATE POLICY business_closed_days_owner_delete
  ON public.business_closed_days
  FOR DELETE
  TO authenticated
  USING (business_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.business_closed_days TO authenticated;

-- 2) Closed-day check for RPCs (reads both tables; SECURITY DEFINER bypasses RLS)
CREATE OR REPLACE FUNCTION public._is_business_date_closed(p_business_id uuid, p_date date)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.business_closed_days bcd
    WHERE bcd.business_id = p_business_id
      AND bcd.date = p_date
  )
  OR EXISTS (
    SELECT 1
    FROM public.blocked_days bd
    WHERE bd.business_id = p_business_id
      AND bd.date::date = p_date
  );
$$;

COMMENT ON FUNCTION public._is_business_date_closed(uuid, date) IS
  'True when date is closed via business_closed_days or legacy blocked_days.';

-- 3) Server-side mirror: business_closed_days → blocked_days (no client RLS on blocked_days)
CREATE OR REPLACE FUNCTION public.sync_business_closed_day_to_blocked_days()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    IF TG_OP = 'DELETE' THEN
      DELETE FROM public.blocked_days
      WHERE business_id = OLD.business_id
        AND blocked_days.date::date = OLD.date;
      RETURN OLD;
    END IF;

    IF TG_OP = 'UPDATE' AND OLD.date IS DISTINCT FROM NEW.date THEN
      DELETE FROM public.blocked_days
      WHERE business_id = OLD.business_id
        AND blocked_days.date::date = OLD.date;
    END IF;

    DELETE FROM public.blocked_days
    WHERE business_id = NEW.business_id
      AND blocked_days.date::date = NEW.date;

    INSERT INTO public.blocked_days (business_id, date, reason)
    VALUES (NEW.business_id, NEW.date, NEW.reason);
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'blocked_days mirror skipped for % on %: %', NEW.business_id, NEW.date, SQLERRM;
  END;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS business_closed_days_sync_blocked_days ON public.business_closed_days;
CREATE TRIGGER business_closed_days_sync_blocked_days
  AFTER INSERT OR UPDATE OR DELETE ON public.business_closed_days
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_business_closed_day_to_blocked_days();

-- 4) Reschedule / shared slot validator — use combined closed-day check
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

-- 5) Backfill mirror for existing business_closed_days rows
INSERT INTO public.blocked_days (business_id, date, reason)
SELECT bcd.business_id, bcd.date, bcd.reason
FROM public.business_closed_days bcd
WHERE NOT EXISTS (
  SELECT 1 FROM public.blocked_days bd
  WHERE bd.business_id = bcd.business_id
    AND bd.date::date = bcd.date
);

-- 6) SECURITY DEFINER batch upsert (admin UI save when RLS policies not yet applied)
CREATE OR REPLACE FUNCTION public.upsert_business_closed_days_manual(
  p_dates date[],
  p_reason text DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid := auth.uid();
  v_date date;
  v_count integer := 0;
  v_reason text := nullif(trim(p_reason), '');
BEGIN
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = 'P0001';
  END IF;
  IF p_dates IS NULL OR array_length(p_dates, 1) IS NULL THEN
    RETURN 0;
  END IF;

  FOREACH v_date IN ARRAY p_dates LOOP
    INSERT INTO public.business_closed_days (business_id, date, reason, source)
    VALUES (v_business_id, v_date, v_reason, 'manual')
    ON CONFLICT (business_id, date)
    DO UPDATE SET
      reason = EXCLUDED.reason,
      source = 'manual';
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_business_closed_days_manual(date[], text) TO authenticated;

COMMENT ON FUNCTION public.upsert_business_closed_days_manual(date[], text) IS
  'Admin UI: upsert manual closed days for auth.uid() business. Mirrors to blocked_days via trigger.';
