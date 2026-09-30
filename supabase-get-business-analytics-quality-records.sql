-- =============================================================================
-- XBOOK Analytics Data Quality exact-record drill-down
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public.get_business_analytics_quality_records(uuid, date, date, text) → jsonb
--   public.get_business_analytics_quality_records(uuid, date, date, text, text) → jsonb
--
-- Reuses live helpers (bodies untouched):
--   public._performance_appointment_start
--   public._analytics_customer_key
--   public._resolve_business_analytics_customer_key
--   Canonical completed-visit / scheduled / price CASE from Performance
--
-- Does NOT:
--   change existing Analytics aggregate formulas or report RPC signatures
--   expose manage_token
--   GRANT SELECT on public.bookings
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_business_analytics_quality_records(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_quality_type text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_type text;
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

  v_type := lower(trim(coalesce(p_quality_type, '')));
  IF v_type NOT IN (
    'estimated',
    'unknown',
    'invalid_times',
    'missing_durations',
    'unassigned',
    'orphan_staff',
    'unidentified'
  ) THEN
    RAISE EXCEPTION 'Invalid quality type'
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
      b.date AS booking_date,
      b.time AS booking_time,
      b.booking_status,
      b.service_id,
      b.service_name,
      b.customer_name,
      b.duration_minutes,
      b.booking_price,
      b.staff_id,
      st.id AS staff_row_id,
      st.name AS staff_member_name,
      b.staff_name AS booking_staff_name,
      s.name AS catalog_service_name,
      s.price AS catalog_price,
      public._performance_appointment_start(b.date, b.time, v_timezone) AS appointment_start,
      public._resolve_business_analytics_customer_key(
        p_business_id,
        public._analytics_customer_key(
          b.customer_user_id,
          b.customer_phone,
          b.customer_email,
          b.customer_name
        )
      ) AS analytics_customer_key
    FROM public.bookings b
    LEFT JOIN public.services s
      ON s.id = b.service_id
     AND s.business_id = b.business_id
    LEFT JOIN public.staff_members st
      ON st.id = b.staff_id
     AND st.business_id = p_business_id
    WHERE b.business_id = p_business_id
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
      (src.staff_id IS NULL) AS is_unassigned,
      (src.staff_id IS NOT NULL AND src.staff_row_id IS NULL) AS is_orphan
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
      (booking_status IN ('Pending', 'Confirmed')) AS is_scheduled,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        appointment_local_date IS NOT NULL
        AND appointment_local_date >= p_from_date
        AND appointment_local_date <= p_to_date
      ) AS is_selected
    FROM classified
    WHERE appointment_start IS NOT NULL
  ),
  booking_rows AS (
    SELECT
      f.id,
      f.booking_date,
      f.booking_time,
      f.appointment_start,
      f.customer_name,
      f.service_id,
      f.catalog_service_name,
      f.service_name,
      f.staff_id,
      f.staff_member_name,
      f.booking_staff_name,
      f.canonical_price,
      f.price_source,
      f.booking_status,
      f.duration_minutes
    FROM flagged f
    WHERE v_type = 'estimated'
      AND f.booking_date >= v_from_text
      AND f.booking_date <= v_to_text
      AND f.is_selected
      AND f.is_scheduled
      AND f.price_source = 'estimated'
    UNION ALL
    SELECT
      f.id,
      f.booking_date,
      f.booking_time,
      f.appointment_start,
      f.customer_name,
      f.service_id,
      f.catalog_service_name,
      f.service_name,
      f.staff_id,
      f.staff_member_name,
      f.booking_staff_name,
      f.canonical_price,
      f.price_source,
      f.booking_status,
      f.duration_minutes
    FROM flagged f
    WHERE v_type = 'unknown'
      AND f.booking_date >= v_from_text
      AND f.booking_date <= v_to_text
      AND f.is_selected
      AND f.is_scheduled
      AND f.price_source = 'unknown'
    UNION ALL
    SELECT
      c.id,
      c.booking_date,
      c.booking_time,
      c.appointment_start,
      c.customer_name,
      c.service_id,
      c.catalog_service_name,
      c.service_name,
      c.staff_id,
      c.staff_member_name,
      c.booking_staff_name,
      c.canonical_price,
      c.price_source,
      c.booking_status,
      c.duration_minutes
    FROM classified c
    WHERE v_type = 'invalid_times'
      AND c.booking_date >= v_from_text
      AND c.booking_date <= v_to_text
      AND c.appointment_start IS NULL
    UNION ALL
    SELECT
      f.id,
      f.booking_date,
      f.booking_time,
      f.appointment_start,
      f.customer_name,
      f.service_id,
      f.catalog_service_name,
      f.service_name,
      f.staff_id,
      f.staff_member_name,
      f.booking_staff_name,
      f.canonical_price,
      f.price_source,
      f.booking_status,
      f.duration_minutes
    FROM flagged f
    WHERE v_type = 'missing_durations'
      AND f.booking_date >= v_from_text
      AND f.booking_date <= v_to_text
      AND f.is_selected
      AND (f.duration_minutes IS NULL OR f.duration_minutes <= 0)
    UNION ALL
    SELECT
      f.id,
      f.booking_date,
      f.booking_time,
      f.appointment_start,
      f.customer_name,
      f.service_id,
      f.catalog_service_name,
      f.service_name,
      f.staff_id,
      f.staff_member_name,
      f.booking_staff_name,
      f.canonical_price,
      f.price_source,
      f.booking_status,
      f.duration_minutes
    FROM flagged f
    WHERE v_type = 'unassigned'
      AND f.is_selected
      AND f.is_completed_visit
      AND f.is_unassigned
    UNION ALL
    SELECT
      c.id,
      c.booking_date,
      c.booking_time,
      c.appointment_start,
      c.customer_name,
      c.service_id,
      c.catalog_service_name,
      c.service_name,
      c.staff_id,
      c.staff_member_name,
      c.booking_staff_name,
      c.canonical_price,
      c.price_source,
      c.booking_status,
      c.duration_minutes
    FROM classified c
    WHERE v_type = 'unidentified'
      AND c.analytics_customer_key IS NULL
  ),
  orphan_entities AS (
    SELECT
      f.staff_id AS entity_id,
      coalesce(
        nullif(trim((ARRAY_AGG(f.booking_staff_name ORDER BY length(coalesce(f.booking_staff_name, '')) DESC)
          FILTER (WHERE nullif(trim(f.booking_staff_name), '') IS NOT NULL))[1]), ''),
        NULL
      ) AS display_name,
      count(*)::bigint AS booking_count
    FROM flagged f
    WHERE v_type = 'orphan_staff'
      AND f.is_selected
      AND f.is_orphan
    GROUP BY f.staff_id
  )
  SELECT jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'from_date', p_from_date,
    'to_date', p_to_date,
    'timezone', v_timezone,
    'quality_type', v_type,
    'count_semantic', CASE WHEN v_type = 'orphan_staff' THEN 'staff_ids' ELSE 'bookings' END,
    'count',
      CASE
        WHEN v_type = 'orphan_staff' THEN (SELECT count(*) FROM orphan_entities)
        ELSE (SELECT count(*) FROM booking_rows)
      END,
    'records',
      CASE
        WHEN v_type = 'orphan_staff' THEN coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'entity_id', o.entity_id,
              'entity_kind', 'staff',
              'display_name', o.display_name,
              'booking_count', o.booking_count
            )
            ORDER BY o.display_name ASC, o.entity_id ASC
          )
          FROM orphan_entities o
        ), '[]'::jsonb)
        ELSE coalesce((
          SELECT jsonb_agg(
            jsonb_build_object(
              'booking_id', r.id,
              'customer_name', nullif(trim(r.customer_name), ''),
              'service_id', r.service_id,
              'service_name', coalesce(
                nullif(trim(r.catalog_service_name), ''),
                nullif(trim(r.service_name), '')
              ),
              'appointment_date', r.booking_date,
              'appointment_time', r.booking_time,
              'appointment_start', r.appointment_start,
              'staff_id', r.staff_id,
              'staff_name', coalesce(nullif(trim(r.staff_member_name), ''), nullif(trim(r.booking_staff_name), '')),
              'price', r.canonical_price,
              'price_source', r.price_source,
              'booking_status', r.booking_status,
              'duration_minutes', r.duration_minutes
            )
            ORDER BY r.appointment_start DESC NULLS LAST, r.booking_date DESC, r.booking_time DESC, r.id DESC
          )
          FROM booking_rows r
        ), '[]'::jsonb)
      END
  )
  INTO v_result;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) IS
  'Owner-only Data Quality record drill-down. Predicates match existing Analytics quality counts. Never returns manage_token.';

CREATE OR REPLACE FUNCTION public.get_business_analytics_quality_records(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_quality_type text,
  p_period_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('xbook.analytics_period_kind', coalesce(p_period_kind, ''), true);
  RETURN public.get_business_analytics_quality_records(p_business_id, p_from_date, p_to_date, p_quality_type);
END;
$$;

COMMENT ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text, text) IS
  'Owner-only Data Quality records with optional period kind passthrough.';

REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) FROM anon, service_role;
REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text, text) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text, text) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
