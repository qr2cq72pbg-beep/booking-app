-- =============================================================================
-- XBook STEP 3A: get_business_busy_slots
-- Non-PII busy intervals for ONE business + bounded date range.
--
-- Run once in Supabase Dashboard → SQL Editor.
-- DO NOT drop public_can_read_bookings in this step.
-- DO NOT change bookings RLS policies in this step.
-- Does not modify create_booking / recurring / cancel / reschedule RPCs.
--
-- Schema verification (from repo SQL / INSERT paths — confirm live with query below):
--   bookings.id                 → uuid (PK; used as p_exclude_booking_id)
--   bookings.business_id        → uuid (= business_settings.business_id / owner auth.uid())
--   bookings.date               → text 'YYYY-MM-DD' OR date
--                                 (create_booking inserts v_date_text text;
--                                  RPCs compare via trim(b.date::text) / b.date::date)
--   bookings.time               → text 'HH24:MI' OR time
--                                 (create_booking inserts v_time_text text;
--                                  RPCs use _booking_row_time_to_minutes(b.time))
--   bookings.duration_minutes   → integer (conflict uses coalesce(nullif(...,0), 30))
--   bookings.staff_id           → uuid NULL
--   bookings.booking_status     → text-like (cast ::text in RPCs)
--   bookings.status             → legacy text-like fallback (cast ::text)
--   business_settings.business_id → uuid PK
--   _booking_active_status(s text) → boolean
--     lower(trim(coalesce(s,'Pending'))) IN ('pending','confirmed')
-- =============================================================================

-- Optional live type check (read-only; run separately if desired):
-- SELECT column_name, data_type, udt_name
-- FROM information_schema.columns
-- WHERE table_schema = 'public' AND table_name = 'bookings'
--   AND column_name IN (
--     'id','business_id','date','time','duration_minutes','staff_id',
--     'booking_status','status'
--   )
-- ORDER BY column_name;

BEGIN;

CREATE OR REPLACE FUNCTION public.get_business_busy_slots(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_exclude_booking_id uuid DEFAULT NULL
)
RETURNS TABLE (
  slot_date date,
  start_time time,
  duration_minutes integer,
  staff_id uuid
)
LANGUAGE plpgsql
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

  -- Inclusive span: from..to of 93 calendar days = 92 day difference.
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
    b.date::date AS slot_date,
    (TIME '00:00' + (public._booking_row_time_to_minutes(b.time) * INTERVAL '1 minute'))::time
      AS start_time,
    coalesce(nullif(b.duration_minutes, 0), 30)::integer AS duration_minutes,
    b.staff_id
  FROM public.bookings b
  WHERE b.business_id = p_business_id
    AND b.date IS NOT NULL
    AND b.date::date >= p_from_date
    AND b.date::date <= p_to_date
    AND (p_exclude_booking_id IS NULL OR b.id IS DISTINCT FROM p_exclude_booking_id)
    AND public._booking_active_status(
      coalesce(b.booking_status::text, b.status::text)
    )
    AND public._booking_row_time_to_minutes(b.time) IS NOT NULL
  ORDER BY 1, 2, 4 NULLS FIRST;
END;
$$;

COMMENT ON FUNCTION public.get_business_busy_slots(uuid, date, date, uuid) IS
  'Public/customer busy-slot map for one business and bounded date range. Returns non-PII occupied intervals only (date, start time, duration, staff_id). Cancelled rows excluded via _booking_active_status.';

REVOKE ALL ON FUNCTION public.get_business_busy_slots(uuid, date, date, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_business_busy_slots(uuid, date, date, uuid)
  TO anon, authenticated;

COMMIT;
