-- =============================================================================
-- XBOOK Phase 1A: Canonical Performance RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE).
--
-- Adds:
--   public._performance_appointment_start(text, text, text)
--   public.get_business_performance_report(uuid, date, date) → jsonb
--   INDEX bookings_business_id_date_idx ON public.bookings (business_id, date)
--
-- Does NOT:
--   backfill booking_price, rewrite booking_status, touch historical rows
--   change RLS, booking create/approval/conflict, Complete Profile
--   add Completed / No-show statuses
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Tenant/date index justified by this report (live audit: none existed)
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS bookings_business_id_date_idx
  ON public.bookings (business_id, date);

COMMENT ON INDEX public.bookings_business_id_date_idx IS
  'Phase 1A Performance RPC period filter: tenant + appointment date text.';

-- -----------------------------------------------------------------------------
-- 2) Safe civil-time parse in a named timezone. NULL if date/time/tz invalid.
--    Does not invent midnight.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._performance_appointment_start(
  p_date text,
  p_time text,
  p_timezone text
)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_date_text text;
  v_time_text text;
  v_d date;
  v_t time;
BEGIN
  IF p_date IS NULL OR p_time IS NULL OR p_timezone IS NULL THEN
    RETURN NULL;
  END IF;

  v_date_text := trim(p_date);
  v_time_text := trim(p_time);

  IF v_date_text !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RETURN NULL;
  END IF;

  -- Hours 00-23 only. Do not coerce blank/invalid time to midnight.
  IF v_time_text !~ '^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?(\.\d+)?$' THEN
    RETURN NULL;
  END IF;

  BEGIN
    v_d := v_date_text::date;
    v_t := v_time_text::time;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NULL;
  END;

  IF to_char(v_d, 'YYYY-MM-DD') IS DISTINCT FROM v_date_text THEN
    RETURN NULL;
  END IF;

  RETURN (v_d + v_t) AT TIME ZONE p_timezone;
END;
$$;

COMMENT ON FUNCTION public._performance_appointment_start(text, text, text) IS
  'Parse bookings.date + bookings.time as civil clock in p_timezone. NULL if invalid. Internal Performance helper.';

REVOKE ALL ON FUNCTION public._performance_appointment_start(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._performance_appointment_start(text, text, text) FROM anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Owner-only canonical Performance report
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_performance_report(
  p_business_id uuid,
  p_from_date date,
  p_to_date date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_from_text text;
  v_to_text text;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL OR p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'Invalid report period'
      USING ERRCODE = '22023';
  END IF;

  SELECT nullif(trim(bs.timezone), '')
  INTO v_timezone
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  IF v_timezone IS NULL THEN
    RAISE EXCEPTION 'Business timezone is not configured'
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names tz WHERE tz.name = v_timezone) THEN
    RAISE EXCEPTION 'Invalid business timezone: %', v_timezone
      USING ERRCODE = '22023';
  END IF;

  v_report_now := now();
  v_from_text := to_char(p_from_date, 'YYYY-MM-DD');
  v_to_text := to_char(p_to_date, 'YYYY-MM-DD');

  WITH src AS (
    SELECT
      b.id,
      b.booking_status,
      b.service_id,
      b.service_name,
      b.customer_user_id,
      b.customer_name,
      b.customer_phone,
      b.customer_email,
      b.duration_minutes,
      b.booking_price,
      s.name AS catalog_service_name,
      s.price AS catalog_price,
      public._performance_appointment_start(b.date, b.time, v_timezone) AS appointment_start
    FROM public.bookings b
    LEFT JOIN public.services s
      ON s.id = b.service_id
     AND s.business_id = b.business_id
    WHERE b.business_id = p_business_id
      AND b.date >= v_from_text
      AND b.date <= v_to_text
  ),
  classified AS (
    SELECT
      src.*,
      (src.appointment_start AT TIME ZONE v_timezone)::date AS appointment_local_date,
      CASE
        WHEN src.duration_minutes IS NOT NULL AND src.duration_minutes > 0
          THEN src.appointment_start + make_interval(mins => src.duration_minutes)
        ELSE NULL
      END AS appointment_end,
      CASE
        WHEN src.booking_price IS NOT NULL AND src.booking_price >= 0 THEN 'snapshot'
        WHEN src.catalog_price IS NOT NULL AND src.catalog_price >= 0 THEN 'estimated'
        ELSE 'unknown'
      END AS price_source,
      CASE
        WHEN src.booking_price IS NOT NULL AND src.booking_price >= 0 THEN src.booking_price
        WHEN src.catalog_price IS NOT NULL AND src.catalog_price >= 0 THEN src.catalog_price
        ELSE NULL
      END AS canonical_price,
      public._resolve_business_analytics_customer_key(
        p_business_id,
        CASE
          WHEN src.customer_user_id IS NOT NULL THEN 'u:' || src.customer_user_id::text
          ELSE public._booking_client_key(src.customer_phone, src.customer_email, src.customer_name)
        END
      ) AS analytics_customer_key
    FROM src
  ),
  in_period AS (
    SELECT *
    FROM classified
    WHERE appointment_start IS NOT NULL
      AND appointment_local_date >= p_from_date
      AND appointment_local_date <= p_to_date
  ),
  flagged AS (
    SELECT
      in_period.*,
      (booking_status IN ('Pending', 'Confirmed')) AS is_scheduled,
      (booking_status = 'Cancelled') AS is_cancelled,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        booking_status = 'Pending'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_elapsed_unconfirmed,
      (
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start > v_report_now
      ) AS is_upcoming,
      (
        booking_status = 'Confirmed'
        AND appointment_start <= v_report_now
        AND appointment_end IS NOT NULL
        AND appointment_end > v_report_now
      ) AS is_in_progress_confirmed
    FROM in_period
  ),
  kpis AS (
    SELECT
      count(*) FILTER (WHERE is_scheduled)::bigint AS scheduled_appointments,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS completed_visits,
      count(*) FILTER (WHERE is_cancelled)::bigint AS cancelled_appointments,
      count(*) FILTER (WHERE is_elapsed_unconfirmed)::bigint AS elapsed_unconfirmed_count,
      count(*) FILTER (WHERE is_upcoming)::bigint AS upcoming_appointments,
      count(*) FILTER (WHERE is_in_progress_confirmed)::bigint AS in_progress_confirmed,
      coalesce(sum(canonical_price) FILTER (WHERE is_scheduled AND canonical_price IS NOT NULL), 0)::numeric AS scheduled_value,
      count(*) FILTER (WHERE is_scheduled AND canonical_price IS NOT NULL)::bigint AS scheduled_value_known_rows,
      count(*) FILTER (WHERE is_scheduled AND canonical_price IS NULL)::bigint AS scheduled_value_unknown_rows,
      coalesce(sum(canonical_price) FILTER (WHERE is_upcoming AND canonical_price IS NOT NULL), 0)::numeric AS upcoming_scheduled_value,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)::bigint AS completed_revenue_known_rows,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NULL)::bigint AS completed_revenue_unknown_rows,
      count(*) FILTER (WHERE is_scheduled AND price_source = 'snapshot')::bigint AS snapshot_priced_booking_count,
      count(*) FILTER (WHERE is_scheduled AND price_source = 'estimated')::bigint AS estimated_legacy_booking_count,
      count(*) FILTER (WHERE is_scheduled AND price_source = 'unknown')::bigint AS unknown_price_booking_count,
      count(*) FILTER (WHERE duration_minutes IS NULL OR duration_minutes <= 0)::bigint AS unknown_duration_count
    FROM flagged
  ),
  quality AS (
    SELECT
      (SELECT count(*) FROM classified WHERE appointment_start IS NULL)::bigint AS invalid_appointment_time_count
  ),
  top_services AS (
    SELECT
      coalesce(
        jsonb_agg(service_row ORDER BY ord),
        '[]'::jsonb
      ) AS payload
    FROM (
      SELECT
        jsonb_build_object(
          'service_id', grouped.service_id,
          'service_name', grouped.display_name,
          'completed_visits', grouped.completed_visits,
          'completed_revenue', grouped.completed_revenue,
          'scheduled_appointments', grouped.scheduled_appointments,
          'scheduled_value', grouped.scheduled_value
        ) AS service_row,
        row_number() OVER (
          ORDER BY grouped.completed_revenue DESC, grouped.completed_visits DESC, grouped.display_name ASC, grouped.group_key ASC
        ) AS ord
      FROM (
        SELECT
          coalesce(service_id::text, 'name:' || lower(coalesce(nullif(trim(service_name), ''), 'unknown'))) AS group_key,
          (ARRAY_AGG(service_id) FILTER (WHERE service_id IS NOT NULL))[1] AS service_id,
          coalesce(
            nullif(trim((ARRAY_AGG(catalog_service_name ORDER BY catalog_service_name) FILTER (WHERE nullif(trim(catalog_service_name), '') IS NOT NULL))[1]), ''),
            nullif(trim((ARRAY_AGG(service_name ORDER BY length(coalesce(service_name, '')) DESC) FILTER (WHERE nullif(trim(service_name), '') IS NOT NULL))[1]), ''),
            'Unknown service'
          ) AS display_name,
          count(*) FILTER (WHERE is_completed_visit)::bigint AS completed_visits,
          coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
          count(*) FILTER (WHERE is_scheduled)::bigint AS scheduled_appointments,
          coalesce(sum(canonical_price) FILTER (WHERE is_scheduled AND canonical_price IS NOT NULL), 0)::numeric AS scheduled_value
        FROM flagged
        WHERE is_scheduled OR is_completed_visit
        GROUP BY 1
      ) grouped
      WHERE grouped.completed_visits > 0
      ORDER BY grouped.completed_revenue DESC, grouped.completed_visits DESC, grouped.display_name ASC, grouped.group_key ASC
      LIMIT 5
    ) ranked
  ),
  top_customers AS (
    SELECT
      coalesce(
        jsonb_agg(customer_row ORDER BY ord),
        '[]'::jsonb
      ) AS payload
    FROM (
      SELECT
        jsonb_build_object(
          'analytics_customer_key', grouped.analytics_customer_key,
          'display_name', grouped.display_name,
          'customer_number', grouped.customer_number,
          'completed_visits', grouped.completed_visits,
          'completed_revenue', grouped.completed_revenue,
          'scheduled_appointments', grouped.scheduled_appointments,
          'scheduled_value', grouped.scheduled_value
        ) AS customer_row,
        row_number() OVER (
          ORDER BY grouped.completed_revenue DESC, grouped.completed_visits DESC, grouped.analytics_customer_key ASC
        ) AS ord
      FROM (
        SELECT
          f.analytics_customer_key,
          coalesce(
            nullif(trim((ARRAY_AGG(f.customer_name ORDER BY length(coalesce(f.customer_name, '')) DESC) FILTER (WHERE nullif(trim(f.customer_name), '') IS NOT NULL AND lower(trim(f.customer_name)) <> 'customer'))[1]), ''),
            nullif(trim(max(bc.display_name)), ''),
            'Customer'
          ) AS display_name,
          max(bc.customer_number) AS customer_number,
          count(*) FILTER (WHERE f.is_completed_visit)::bigint AS completed_visits,
          coalesce(sum(f.canonical_price) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
          count(*) FILTER (WHERE f.is_scheduled)::bigint AS scheduled_appointments,
          coalesce(sum(f.canonical_price) FILTER (WHERE f.is_scheduled AND f.canonical_price IS NOT NULL), 0)::numeric AS scheduled_value
        FROM flagged f
        LEFT JOIN public.business_customers bc
          ON bc.business_id = p_business_id
         AND (
           (
             f.analytics_customer_key LIKE 'u:%'
             AND bc.customer_user_id IS NOT NULL
             AND f.analytics_customer_key = 'u:' || bc.customer_user_id::text
           )
           OR (
             f.analytics_customer_key IS NOT NULL
             AND f.analytics_customer_key NOT LIKE 'u:%'
             AND bc.client_key = f.analytics_customer_key
           )
         )
        WHERE f.analytics_customer_key IS NOT NULL
          AND (f.is_scheduled OR f.is_completed_visit)
        GROUP BY f.analytics_customer_key
      ) grouped
      WHERE grouped.completed_visits > 0
      ORDER BY grouped.completed_revenue DESC, grouped.completed_visits DESC, grouped.analytics_customer_key ASC
      LIMIT 5
    ) ranked
  )
  SELECT jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'timezone', v_timezone,
    'from_date', p_from_date,
    'to_date', p_to_date,
    'report_now', v_report_now,
    'scheduled_appointments', k.scheduled_appointments,
    'completed_visits', k.completed_visits,
    'cancelled_appointments', k.cancelled_appointments,
    'elapsed_unconfirmed_count', k.elapsed_unconfirmed_count,
    'upcoming_appointments', k.upcoming_appointments,
    'in_progress_confirmed', k.in_progress_confirmed,
    'scheduled_value', k.scheduled_value,
    'scheduled_value_known_rows', k.scheduled_value_known_rows,
    'scheduled_value_unknown_rows', k.scheduled_value_unknown_rows,
    'upcoming_scheduled_value', k.upcoming_scheduled_value,
    'completed_revenue', k.completed_revenue,
    'completed_revenue_known_rows', k.completed_revenue_known_rows,
    'completed_revenue_unknown_rows', k.completed_revenue_unknown_rows,
    'average_completed_visit_value',
      CASE
        WHEN k.completed_revenue_known_rows > 0
          THEN round(k.completed_revenue / k.completed_revenue_known_rows, 2)
        ELSE NULL
      END,
    'snapshot_priced_booking_count', k.snapshot_priced_booking_count,
    'estimated_legacy_booking_count', k.estimated_legacy_booking_count,
    'unknown_price_booking_count', k.unknown_price_booking_count,
    'price_snapshot_coverage_pct',
      CASE
        WHEN k.scheduled_appointments > 0
          THEN round((100.0 * k.snapshot_priced_booking_count) / k.scheduled_appointments, 1)
        ELSE NULL
      END,
    'price_snapshot_coverage_denominator', 'scheduled_appointments',
    'contains_estimated_prices', (k.estimated_legacy_booking_count > 0),
    'quality', jsonb_build_object(
      'invalid_appointment_time_count', q.invalid_appointment_time_count,
      'unknown_duration_count', k.unknown_duration_count,
      'unknown_price_count', k.unknown_price_booking_count,
      'estimated_price_count', k.estimated_legacy_booking_count,
      'snapshot_price_count', k.snapshot_priced_booking_count,
      'contains_estimated_prices', (k.estimated_legacy_booking_count > 0)
    ),
    'top_services', ts.payload,
    'top_customers', tc.payload
  )
  INTO v_result
  FROM kpis k
  CROSS JOIN quality q
  CROSS JOIN top_services ts
  CROSS JOIN top_customers tc;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_business_performance_report(uuid, date, date) IS
  'Owner-only canonical Performance report. Period = appointment local date in business_settings.timezone. V1 completed visit = Confirmed AND appointment_end <= now. Price = booking_price snapshot else estimated services.price.';

REVOKE ALL ON FUNCTION public.get_business_performance_report(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_performance_report(uuid, date, date) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_performance_report(uuid, date, date) TO authenticated;

COMMIT;
