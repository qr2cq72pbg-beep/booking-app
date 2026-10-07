-- =============================================================================
-- XBOOK V1 — Employee / staff time off
-- Run once in Supabase Dashboard → SQL Editor.
-- DO NOT apply automatically.
--
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / idempotent wraps).
--
-- Does NOT:
--   replay historical create_booking / _assert_booking_slot_available bodies
--   change price snapshot, staff assignment, closed days, working-hour
--   overrides, timezone past-slot guard, booking limits, or push/outbox
--   cancel or mutate existing bookings
--   expose note / time_off_type to anon or customers
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_time_off (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.business_settings(business_id) ON DELETE CASCADE,
  staff_id uuid NOT NULL REFERENCES public.staff_members(id) ON DELETE CASCADE,
  date_from date NOT NULL,
  date_to date NOT NULL,
  start_time time without time zone,
  end_time time without time zone,
  time_off_type text NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_time_off_dates_ok CHECK (date_to >= date_from),
  CONSTRAINT staff_time_off_times_pair CHECK (
    (start_time IS NULL AND end_time IS NULL)
    OR (start_time IS NOT NULL AND end_time IS NOT NULL AND end_time > start_time)
  ),
  CONSTRAINT staff_time_off_type_ok CHECK (
    time_off_type IN ('vacation', 'sick', 'personal', 'other')
  )
);

CREATE INDEX IF NOT EXISTS staff_time_off_business_id_idx
  ON public.staff_time_off (business_id);

CREATE INDEX IF NOT EXISTS staff_time_off_staff_dates_idx
  ON public.staff_time_off (staff_id, date_from, date_to);

CREATE INDEX IF NOT EXISTS staff_time_off_business_dates_idx
  ON public.staff_time_off (business_id, date_from, date_to);

COMMENT ON TABLE public.staff_time_off IS
  'Owner-managed per-staff unavailability. V1 writes full civil-date ranges (start_time/end_time NULL). Partial-day times are reserved for a later UI.';

COMMENT ON COLUMN public.staff_time_off.start_time IS
  'NULL with end_time NULL = full days. When set, first-day start for multi-day rows, or single-day start.';

COMMENT ON COLUMN public.staff_time_off.end_time IS
  'NULL with start_time NULL = full days. When set, last-day end for multi-day rows, or single-day end.';

ALTER TABLE public.staff_time_off ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_time_off_owner_select ON public.staff_time_off;
CREATE POLICY staff_time_off_owner_select
  ON public.staff_time_off
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS staff_time_off_owner_insert ON public.staff_time_off;
CREATE POLICY staff_time_off_owner_insert
  ON public.staff_time_off
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS staff_time_off_owner_update ON public.staff_time_off;
CREATE POLICY staff_time_off_owner_update
  ON public.staff_time_off
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS staff_time_off_owner_delete ON public.staff_time_off;
CREATE POLICY staff_time_off_owner_delete
  ON public.staff_time_off
  FOR DELETE
  TO authenticated
  USING (business_id = auth.uid());

REVOKE ALL ON TABLE public.staff_time_off FROM PUBLIC;
REVOKE ALL ON TABLE public.staff_time_off FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.staff_time_off TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.staff_time_off TO service_role;

CREATE OR REPLACE FUNCTION public._staff_time_off_touch_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.updated_at := clock_timestamp();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS staff_time_off_touch_updated_at ON public.staff_time_off;
CREATE TRIGGER staff_time_off_touch_updated_at
  BEFORE UPDATE ON public.staff_time_off
  FOR EACH ROW
  EXECUTE FUNCTION public._staff_time_off_touch_updated_at();

CREATE OR REPLACE FUNCTION public._staff_time_off_assert_staff_tenant()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_staff_business uuid;
BEGIN
  SELECT sm.business_id
    INTO v_staff_business
  FROM public.staff_members sm
  WHERE sm.id = NEW.staff_id;

  IF v_staff_business IS NULL THEN
    RAISE EXCEPTION 'Staff member not found for this business.'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_staff_business IS DISTINCT FROM NEW.business_id THEN
    RAISE EXCEPTION 'Staff member not found for this business.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS staff_time_off_assert_staff_tenant ON public.staff_time_off;
CREATE TRIGGER staff_time_off_assert_staff_tenant
  BEFORE INSERT OR UPDATE OF business_id, staff_id ON public.staff_time_off
  FOR EACH ROW
  EXECUTE FUNCTION public._staff_time_off_assert_staff_tenant();

-- -----------------------------------------------------------------------------
-- 2) Overlap helper — civil date + minute-of-day, same [start,end) as bookings
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_time_off_window_minutes(
  p_row public.staff_time_off,
  p_date date,
  OUT o_start_min integer,
  OUT o_end_min integer
)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_from date := p_row.date_from;
  v_to date := p_row.date_to;
  v_start_min integer;
  v_end_min integer;
BEGIN
  o_start_min := NULL;
  o_end_min := NULL;

  IF p_date IS NULL OR v_from IS NULL OR v_to IS NULL THEN
    RETURN;
  END IF;

  IF p_date < v_from OR p_date > v_to THEN
    RETURN;
  END IF;

  IF p_row.start_time IS NULL OR p_row.end_time IS NULL THEN
    o_start_min := 0;
    o_end_min := 1440;
    RETURN;
  END IF;

  v_start_min := public._time_to_minutes(p_row.start_time);
  v_end_min := public._time_to_minutes(p_row.end_time);
  IF v_start_min IS NULL OR v_end_min IS NULL OR v_end_min <= v_start_min THEN
    o_start_min := 0;
    o_end_min := 1440;
    RETURN;
  END IF;

  IF v_from = v_to THEN
    o_start_min := v_start_min;
    o_end_min := v_end_min;
    RETURN;
  END IF;

  IF p_date = v_from THEN
    o_start_min := v_start_min;
    o_end_min := 1440;
    RETURN;
  END IF;

  IF p_date = v_to THEN
    o_start_min := 0;
    o_end_min := v_end_min;
    RETURN;
  END IF;

  o_start_min := 0;
  o_end_min := 1440;
END;
$$;

COMMENT ON FUNCTION public._staff_time_off_window_minutes(public.staff_time_off, date) IS
  'Civil-date window for one time-off row. Full-day NULL times = 0..1440. Multi-day timed rows: first day from start, middle days full, last day until end.';

REVOKE ALL ON FUNCTION public._staff_time_off_window_minutes(public.staff_time_off, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._staff_time_off_window_minutes(public.staff_time_off, date)
  FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._staff_time_off_overlaps(
  p_business_id uuid,
  p_staff_id uuid,
  p_date date,
  p_start_min integer,
  p_end_min integer
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.staff_time_off%ROWTYPE;
  v_off_start integer;
  v_off_end integer;
  v_start integer := coalesce(p_start_min, 0);
  v_end integer := coalesce(p_end_min, 1440);
BEGIN
  IF p_business_id IS NULL OR p_staff_id IS NULL OR p_date IS NULL THEN
    RETURN false;
  END IF;

  IF v_end <= v_start THEN
    RETURN false;
  END IF;

  FOR v_row IN
    SELECT *
    FROM public.staff_time_off t
    WHERE t.business_id = p_business_id
      AND t.staff_id = p_staff_id
      AND t.date_from <= p_date
      AND t.date_to >= p_date
  LOOP
    SELECT w.o_start_min, w.o_end_min
      INTO v_off_start, v_off_end
    FROM public._staff_time_off_window_minutes(v_row, p_date) AS w;

    IF v_off_start IS NOT NULL
       AND v_off_end IS NOT NULL
       AND v_start < v_off_end
       AND v_end > v_off_start
    THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public._staff_time_off_overlaps(uuid, uuid, date, integer, integer) IS
  'True when [p_start_min, p_end_min) on p_date overlaps a staff_time_off row. Full-day NULL times cover the whole civil date.';

REVOKE ALL ON FUNCTION public._staff_time_off_overlaps(uuid, uuid, date, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._staff_time_off_overlaps(uuid, uuid, date, integer, integer)
  FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._assert_staff_not_on_time_off(
  p_business_id uuid,
  p_service_id uuid,
  p_date date,
  p_time time,
  p_staff_id uuid
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_duration integer;
  v_start_min integer;
  v_end_min integer;
BEGIN
  IF p_staff_id IS NULL OR p_business_id IS NULL OR p_date IS NULL OR p_time IS NULL THEN
    RETURN;
  END IF;

  SELECT coalesce(nullif(s.duration, 0), 30)
    INTO v_duration
  FROM public.services s
  WHERE s.id = p_service_id
    AND s.business_id = p_business_id;

  v_duration := coalesce(v_duration, 30);
  v_start_min := public._time_to_minutes(p_time);
  IF v_start_min IS NULL THEN
    RETURN;
  END IF;
  v_end_min := v_start_min + v_duration;

  IF public._staff_time_off_overlaps(
    p_business_id,
    p_staff_id,
    p_date,
    v_start_min,
    v_end_min
  ) THEN
    RAISE EXCEPTION 'This team member is unavailable at this time.'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

COMMENT ON FUNCTION public._assert_staff_not_on_time_off(uuid, uuid, date, time, uuid) IS
  'Raises P0001 when the proposed booking slot overlaps staff time off. Used by live booking wrappers and does not replace create_booking internals.';

REVOKE ALL ON FUNCTION public._assert_staff_not_on_time_off(uuid, uuid, date, time, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_staff_not_on_time_off(uuid, uuid, date, time, uuid)
  FROM anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3) Wrap LIVE create_booking / _assert without replaying historical bodies
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure(
       'public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._create_booking_pre_time_off(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'
     ) IS NULL
  THEN
    ALTER FUNCTION public.create_booking(
      uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
    ) RENAME TO _create_booking_pre_time_off;
  END IF;
END $$;

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
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public._assert_staff_not_on_time_off(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_staff_id
  );

  RETURN public._create_booking_pre_time_off(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_notes,
    p_staff_id,
    p_customer_user_id,
    p_booking_status
  );
END;
$function$;

COMMENT ON FUNCTION public.create_booking(uuid, uuid, date, time, text, text, text, text, uuid, uuid, text) IS
  'Live create_booking wrapper: staff time-off check, then the previously deployed body (past-guard / price / staff / hours / limits).';

REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public._create_booking_pre_time_off(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._create_booking_pre_time_off(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure(
       'public._assert_booking_slot_available(uuid,uuid,date,time,uuid,uuid)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._assert_booking_slot_available_pre_time_off(uuid,uuid,date,time,uuid,uuid)'
     ) IS NULL
  THEN
    ALTER FUNCTION public._assert_booking_slot_available(
      uuid, uuid, date, time, uuid, uuid
    ) RENAME TO _assert_booking_slot_available_pre_time_off;
  END IF;
END $$;

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
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._assert_staff_not_on_time_off(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_staff_id
  );
  PERFORM public._assert_booking_slot_available_pre_time_off(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_staff_id,
    p_exclude_booking_id
  );
END;
$$;

COMMENT ON FUNCTION public._assert_booking_slot_available(uuid, uuid, date, time, uuid, uuid) IS
  'Live slot assert wrapper: staff time-off check, then the previously deployed validator (past-guard / hours / conflicts).';

REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time, uuid, uuid
) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time, uuid, uuid
) TO service_role;

REVOKE ALL ON FUNCTION public._assert_booking_slot_available_pre_time_off(
  uuid, uuid, date, time, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_booking_slot_available_pre_time_off(
  uuid, uuid, date, time, uuid, uuid
) FROM anon, authenticated;

-- Optional 7-arg overload from strict-staff (p_require_staff). Wrap if present.
DO $$
BEGIN
  IF to_regprocedure(
       'public._assert_booking_slot_available(uuid,uuid,date,time,uuid,uuid,boolean)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._assert_booking_slot_available_pre_time_off(uuid,uuid,date,time,uuid,uuid,boolean)'
     ) IS NULL
  THEN
    ALTER FUNCTION public._assert_booking_slot_available(
      uuid, uuid, date, time, uuid, uuid, boolean
    ) RENAME TO _assert_booking_slot_available_pre_time_off;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
       'public._assert_booking_slot_available_pre_time_off(uuid,uuid,date,time,uuid,uuid,boolean)'
     ) IS NULL
  THEN
    RETURN;
  END IF;

  EXECUTE $fn$
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
    VOLATILE
    SECURITY DEFINER
    SET search_path = public
    AS $body$
    BEGIN
      PERFORM public._assert_staff_not_on_time_off(
        p_business_id,
        p_service_id,
        p_date,
        p_time,
        p_staff_id
      );
      PERFORM public._assert_booking_slot_available_pre_time_off(
        p_business_id,
        p_service_id,
        p_date,
        p_time,
        p_staff_id,
        p_exclude_booking_id,
        p_require_staff
      );
    END;
    $body$;
  $fn$;

  REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
    uuid, uuid, date, time, uuid, uuid, boolean
  ) FROM PUBLIC;
  REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
    uuid, uuid, date, time, uuid, uuid, boolean
  ) FROM anon, authenticated;
  GRANT EXECUTE ON FUNCTION public._assert_booking_slot_available(
    uuid, uuid, date, time, uuid, uuid, boolean
  ) TO service_role;
END $$;

-- -----------------------------------------------------------------------------
-- 4) Bookings trigger — covers saveEditedBooking PostgREST UPDATE
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._enforce_bookings_staff_time_off()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_active boolean;
  v_was_active boolean;
  v_start_min integer;
  v_end_min integer;
  v_duration integer;
  v_date date;
BEGIN
  v_is_active := public._booking_active_status(
    coalesce(NEW.booking_status::text, NEW.status::text)
  );

  IF NOT v_is_active OR NEW.staff_id IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_was_active := public._booking_active_status(
      coalesce(OLD.booking_status::text, OLD.status::text)
    );
    IF v_was_active
       AND NEW.staff_id IS NOT DISTINCT FROM OLD.staff_id
       AND NEW.date IS NOT DISTINCT FROM OLD.date
       AND NEW.time IS NOT DISTINCT FROM OLD.time
       AND NEW.duration_minutes IS NOT DISTINCT FROM OLD.duration_minutes
    THEN
      RETURN NEW;
    END IF;
  END IF;

  BEGIN
    v_date := NEW.date::date;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NEW;
  END;

  v_start_min := public._booking_row_time_to_minutes(NEW.time);
  IF v_start_min IS NULL OR v_date IS NULL THEN
    RETURN NEW;
  END IF;

  v_duration := coalesce(nullif(NEW.duration_minutes, 0), 30);
  v_end_min := v_start_min + v_duration;

  IF public._staff_time_off_overlaps(
    NEW.business_id,
    NEW.staff_id,
    v_date,
    v_start_min,
    v_end_min
  ) THEN
    RAISE EXCEPTION 'This team member is unavailable at this time.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_enforce_staff_time_off ON public.bookings;
CREATE TRIGGER bookings_enforce_staff_time_off
  BEFORE INSERT OR UPDATE OF staff_id, date, time, duration_minutes, booking_status, status
  ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_bookings_staff_time_off();

COMMENT ON FUNCTION public._enforce_bookings_staff_time_off() IS
  'Rejects pending/confirmed bookings whose staff/date/time overlap staff_time_off. Closes the bookings_api edit path that bypasses create_booking.';

-- -----------------------------------------------------------------------------
-- 5) Owner write / read RPCs
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_time_off_require_owner()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN auth.uid();
END;
$$;

REVOKE ALL ON FUNCTION public._staff_time_off_require_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._staff_time_off_require_owner()
  FROM anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._staff_time_off_ranges_overlap(
  p_from date,
  p_to date,
  p_start time,
  p_end time,
  p_other public.staff_time_off
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_d date;
  v_a_start integer;
  v_a_end integer;
  v_b_start integer;
  v_b_end integer;
  v_probe public.staff_time_off;
BEGIN
  IF p_from IS NULL OR p_to IS NULL THEN
    RETURN false;
  END IF;
  IF p_to < p_other.date_from OR p_from > p_other.date_to THEN
    RETURN false;
  END IF;

  v_probe := p_other;
  FOR v_d IN SELECT generate_series(p_from, p_to, interval '1 day')::date LOOP
    IF v_d < p_other.date_from OR v_d > p_other.date_to THEN
      CONTINUE;
    END IF;

    v_probe.date_from := p_from;
    v_probe.date_to := p_to;
    v_probe.start_time := p_start;
    v_probe.end_time := p_end;

    SELECT w.o_start_min, w.o_end_min
      INTO v_a_start, v_a_end
    FROM public._staff_time_off_window_minutes(v_probe, v_d) AS w;

    SELECT w.o_start_min, w.o_end_min
      INTO v_b_start, v_b_end
    FROM public._staff_time_off_window_minutes(p_other, v_d) AS w;

    IF v_a_start IS NOT NULL
       AND v_b_start IS NOT NULL
       AND v_a_start < v_b_end
       AND v_a_end > v_b_start
    THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$$;

REVOKE ALL ON FUNCTION public._staff_time_off_ranges_overlap(date, date, time, time, public.staff_time_off)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public._staff_time_off_ranges_overlap(date, date, time, time, public.staff_time_off)
  FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_staff_time_off_conflicts(
  p_staff_id uuid,
  p_date_from date,
  p_date_to date,
  p_start_time time DEFAULT NULL,
  p_end_time time DEFAULT NULL,
  p_exclude_time_off_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
  v_probe public.staff_time_off;
  v_conflicts jsonb := '[]'::jsonb;
BEGIN
  v_business_id := public._staff_time_off_require_owner();

  IF p_staff_id IS NULL OR p_date_from IS NULL OR p_date_to IS NULL THEN
    RAISE EXCEPTION 'Staff and date range are required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_date_to < p_date_from THEN
    RAISE EXCEPTION 'End date must be on or after start date.' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff_members sm
    WHERE sm.id = p_staff_id
      AND sm.business_id = v_business_id
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  v_probe.business_id := v_business_id;
  v_probe.staff_id := p_staff_id;
  v_probe.date_from := p_date_from;
  v_probe.date_to := p_date_to;
  v_probe.start_time := p_start_time;
  v_probe.end_time := p_end_time;
  v_probe.time_off_type := 'other';

  SELECT coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', x.id,
        'date', x.slot_date,
        'time', x.start_time,
        'duration_minutes', x.duration_minutes,
        'service_name', x.service_name,
        'customer_name', x.customer_name,
        'booking_status', x.booking_status
      )
      ORDER BY x.slot_date, x.start_min
    ),
    '[]'::jsonb
  )
  INTO v_conflicts
  FROM (
    SELECT
      b.id,
      b.date::date AS slot_date,
      to_char((TIME '00:00' + (public._booking_row_time_to_minutes(b.time) * INTERVAL '1 minute')), 'HH24:MI') AS start_time,
      public._booking_row_time_to_minutes(b.time) AS start_min,
      coalesce(nullif(b.duration_minutes, 0), 30) AS duration_minutes,
      b.service_name,
      b.customer_name,
      coalesce(b.booking_status::text, b.status::text, 'Pending') AS booking_status
    FROM public.bookings b
    WHERE b.business_id = v_business_id
      AND b.staff_id = p_staff_id
      AND b.date IS NOT NULL
      AND b.date::date >= p_date_from
      AND b.date::date <= p_date_to
      AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
      AND public._booking_row_time_to_minutes(b.time) IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM public._staff_time_off_window_minutes(v_probe, b.date::date) w
        WHERE public._booking_row_time_to_minutes(b.time) < w.o_end_min
          AND public._booking_row_time_to_minutes(b.time)
            + coalesce(nullif(b.duration_minutes, 0), 30) > w.o_start_min
      )
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'conflicts', v_conflicts,
    'exclude_time_off_id', p_exclude_time_off_id
  );
END;
$$;

COMMENT ON FUNCTION public.get_staff_time_off_conflicts(uuid, date, date, time, time, uuid) IS
  'Owner-only. Returns pending/confirmed bookings that would overlap the proposed staff time-off window.';

CREATE OR REPLACE FUNCTION public.list_staff_time_off(p_staff_id uuid DEFAULT NULL)
RETURNS SETOF public.staff_time_off
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
BEGIN
  v_business_id := public._staff_time_off_require_owner();

  RETURN QUERY
  SELECT t.*
  FROM public.staff_time_off t
  WHERE t.business_id = v_business_id
    AND (p_staff_id IS NULL OR t.staff_id = p_staff_id)
  ORDER BY t.date_from ASC, t.date_to ASC, t.created_at ASC;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_staff_time_off(
  p_staff_id uuid,
  p_date_from date,
  p_date_to date,
  p_time_off_type text,
  p_note text DEFAULT NULL,
  p_id uuid DEFAULT NULL,
  p_start_time time DEFAULT NULL,
  p_end_time time DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
  v_type text;
  v_note text;
  v_other public.staff_time_off%ROWTYPE;
  v_conflicts jsonb := '[]'::jsonb;
  v_row public.staff_time_off%ROWTYPE;
  v_d date;
  v_conflict_result jsonb;
BEGIN
  v_business_id := public._staff_time_off_require_owner();

  IF p_staff_id IS NULL OR p_date_from IS NULL OR p_date_to IS NULL THEN
    RAISE EXCEPTION 'Staff and date range are required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_date_to < p_date_from THEN
    RAISE EXCEPTION 'End date must be on or after start date.' USING ERRCODE = 'P0001';
  END IF;

  IF (p_start_time IS NULL) <> (p_end_time IS NULL) THEN
    RAISE EXCEPTION 'Start time and end time must both be set or both empty.'
      USING ERRCODE = 'P0001';
  END IF;

  IF p_start_time IS NOT NULL AND p_end_time IS NOT NULL AND p_end_time <= p_start_time THEN
    RAISE EXCEPTION 'End time must be after start time.' USING ERRCODE = 'P0001';
  END IF;

  v_type := lower(trim(coalesce(p_time_off_type, '')));
  IF v_type NOT IN ('vacation', 'sick', 'personal', 'other') THEN
    RAISE EXCEPTION 'Invalid time off type.' USING ERRCODE = 'P0001';
  END IF;

  v_note := nullif(trim(coalesce(p_note, '')), '');

  IF NOT EXISTS (
    SELECT 1
    FROM public.staff_members sm
    WHERE sm.id = p_staff_id
      AND sm.business_id = v_business_id
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  IF p_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.staff_time_off t
    WHERE t.id = p_id
      AND t.business_id = v_business_id
      AND t.staff_id = p_staff_id
  ) THEN
    RAISE EXCEPTION 'Time off not found.' USING ERRCODE = 'P0001';
  END IF;

  FOR v_d IN SELECT generate_series(p_date_from, p_date_to, interval '1 day')::date LOOP
    PERFORM pg_advisory_xact_lock(public._booking_day_lock_key(v_business_id, v_d));
  END LOOP;

  FOR v_other IN
    SELECT *
    FROM public.staff_time_off t
    WHERE t.business_id = v_business_id
      AND t.staff_id = p_staff_id
      AND (p_id IS NULL OR t.id <> p_id)
      AND t.date_from <= p_date_to
      AND t.date_to >= p_date_from
  LOOP
    IF public._staff_time_off_ranges_overlap(
      p_date_from,
      p_date_to,
      p_start_time,
      p_end_time,
      v_other
    ) THEN
      RAISE EXCEPTION 'This overlaps another time-off period for this team member.'
        USING ERRCODE = 'P0001';
    END IF;
  END LOOP;

  v_conflict_result := public.get_staff_time_off_conflicts(
    p_staff_id,
    p_date_from,
    p_date_to,
    p_start_time,
    p_end_time,
    p_id
  );
  v_conflicts := coalesce(v_conflict_result -> 'conflicts', '[]'::jsonb);

  IF jsonb_typeof(v_conflicts) = 'array' AND jsonb_array_length(v_conflicts) > 0 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'booking_conflict',
      'conflicts', v_conflicts
    );
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.staff_time_off (
      business_id,
      staff_id,
      date_from,
      date_to,
      start_time,
      end_time,
      time_off_type,
      note
    )
    VALUES (
      v_business_id,
      p_staff_id,
      p_date_from,
      p_date_to,
      p_start_time,
      p_end_time,
      v_type,
      v_note
    )
    RETURNING * INTO v_row;
  ELSE
    UPDATE public.staff_time_off t
    SET
      date_from = p_date_from,
      date_to = p_date_to,
      start_time = p_start_time,
      end_time = p_end_time,
      time_off_type = v_type,
      note = v_note
    WHERE t.id = p_id
      AND t.business_id = v_business_id
    RETURNING * INTO v_row;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'code', 'saved',
    'time_off', to_jsonb(v_row)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_staff_time_off(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid;
  v_deleted integer := 0;
BEGIN
  v_business_id := public._staff_time_off_require_owner();

  IF p_id IS NULL THEN
    RAISE EXCEPTION 'Time off is required.' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.staff_time_off t
  WHERE t.id = p_id
    AND t.business_id = v_business_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF v_deleted < 1 THEN
    RAISE EXCEPTION 'Time off not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN jsonb_build_object('ok', true, 'code', 'deleted');
END;
$$;

REVOKE ALL ON FUNCTION public.get_staff_time_off_conflicts(uuid, date, date, time, time, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_staff_time_off(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_staff_time_off(uuid, date, date, text, text, uuid, time, time) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_staff_time_off(uuid) FROM PUBLIC;

REVOKE ALL ON FUNCTION public.get_staff_time_off_conflicts(uuid, date, date, time, time, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.list_staff_time_off(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.upsert_staff_time_off(uuid, date, date, text, text, uuid, time, time) FROM anon;
REVOKE ALL ON FUNCTION public.delete_staff_time_off(uuid) FROM anon;

GRANT EXECUTE ON FUNCTION public.get_staff_time_off_conflicts(uuid, date, date, time, time, uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_staff_time_off(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_staff_time_off(uuid, date, date, text, text, uuid, time, time)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_staff_time_off(uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6) Public anonymous unavailability (no note / type)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_staff_unavailability(
  p_business_id uuid,
  p_from_date date,
  p_to_date date
)
RETURNS TABLE (
  staff_id uuid,
  slot_date date,
  start_time time,
  end_time time
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_exists boolean;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business ID is required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_from_date IS NULL OR p_to_date IS NULL THEN
    RAISE EXCEPTION 'from_date and to_date are required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_to_date < p_from_date THEN
    RAISE EXCEPTION 'to_date must be on or after from_date.' USING ERRCODE = 'P0001';
  END IF;

  IF (p_to_date - p_from_date) > 92 THEN
    RAISE EXCEPTION 'Date range too large (maximum 92 days).' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = p_business_id
  )
  INTO v_exists;

  IF NOT v_exists THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN QUERY
  SELECT
    t.staff_id,
    d::date AS slot_date,
    CASE
      WHEN w.o_start_min <= 0 THEN NULL
      ELSE (TIME '00:00' + (w.o_start_min * INTERVAL '1 minute'))::time
    END AS start_time,
    CASE
      WHEN w.o_end_min >= 1440 THEN NULL
      ELSE (TIME '00:00' + (w.o_end_min * INTERVAL '1 minute'))::time
    END AS end_time
  FROM public.staff_time_off t
  JOIN LATERAL generate_series(
    GREATEST(t.date_from, p_from_date),
    LEAST(t.date_to, p_to_date),
    interval '1 day'
  ) AS d ON true
  JOIN LATERAL public._staff_time_off_window_minutes(t, d::date) AS w ON true
  WHERE t.business_id = p_business_id
    AND t.date_to >= p_from_date
    AND t.date_from <= p_to_date
    AND w.o_start_min IS NOT NULL
    AND w.o_end_min IS NOT NULL
  ORDER BY 2, 1, 3 NULLS FIRST;
END;
$$;

COMMENT ON FUNCTION public.get_public_staff_unavailability(uuid, date, date) IS
  'Anonymous staff-unavailable intervals for slot calculation. No note, type, or owner details. Full-day rows return NULL start/end times.';

REVOKE ALL ON FUNCTION public.get_public_staff_unavailability(uuid, date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_staff_unavailability(uuid, date, date)
  TO anon, authenticated, service_role;

COMMIT;
