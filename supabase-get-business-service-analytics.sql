-- =============================================================================
-- XBOOK Phase 4B: Canonical Service Analytics RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public._service_analytics_comparison_windows(date, date, date)
--   public._service_analytics_trend(numeric, numeric, text, boolean)
--   public.get_business_service_analytics(uuid, date, date) → jsonb
--
-- Reuses live (bodies untouched):
--   public._performance_appointment_start
--   public._analytics_customer_key
--   public._resolve_business_analytics_customer_key
--   Canonical completed-visit / price CASE from Phase 1A Performance
--   Performance Top Services group_key + display_name coalesce
--
-- Does NOT:
--   change get_business_performance_report / customer analytics RPCs
--   backfill booking_price, rewrite bookings, add booking_service_name
--   add indexes, Service Detail, segment filters, or UI
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Deterministic previous-period windows (internal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._service_analytics_comparison_windows(
  p_from_date date,
  p_to_date date,
  p_today date
)
RETURNS TABLE (
  comparison_type text,
  comparison_current_from date,
  comparison_current_to date,
  previous_from date,
  previous_to date
)
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $$
DECLARE
  v_span integer;
  v_cmp_from date;
  v_cmp_to date;
  v_prev_from date;
  v_prev_to date;
  v_month_start date;
  v_month_end date;
  v_prev_month_start date;
  v_prev_month_end date;
  v_ytd_from date;
BEGIN
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_today IS NULL OR p_from_date > p_to_date THEN
    comparison_type := 'not_applicable';
    comparison_current_from := NULL;
    comparison_current_to := NULL;
    previous_from := NULL;
    previous_to := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  -- A. Today
  IF p_from_date = p_today AND p_to_date = p_today THEN
    comparison_type := 'today';
    comparison_current_from := p_today;
    comparison_current_to := p_today;
    previous_from := p_today - 1;
    previous_to := p_today - 1;
    RETURN NEXT;
    RETURN;
  END IF;

  -- C. Closed period
  IF p_to_date < p_today THEN
    v_span := p_to_date - p_from_date;
    comparison_type := 'closed_equal_length';
    comparison_current_from := p_from_date;
    comparison_current_to := p_to_date;
    previous_to := p_from_date - 1;
    previous_from := previous_to - v_span;
    RETURN NEXT;
    RETURN;
  END IF;

  -- B. Open period: from <= today <= to
  IF p_from_date <= p_today AND p_to_date >= p_today THEN
    v_ytd_from := make_date(EXTRACT(YEAR FROM p_today)::integer, 1, 1);
    v_month_start := date_trunc('month', p_today)::date;
    v_month_end := (date_trunc('month', p_today) + interval '1 month' - interval '1 day')::date;

    IF p_from_date = v_ytd_from AND p_to_date = p_today THEN
      comparison_type := 'ytd';
      comparison_current_from := p_from_date;
      comparison_current_to := p_today;
      previous_from := make_date(EXTRACT(YEAR FROM p_today)::integer - 1, 1, 1);
      previous_to := (p_today - interval '1 year')::date;
      RETURN NEXT;
      RETURN;
    END IF;

    IF p_from_date = v_month_start AND p_to_date = v_month_end THEN
      v_prev_month_start := (date_trunc('month', p_today) - interval '1 month')::date;
      v_prev_month_end := (date_trunc('month', p_today) - interval '1 day')::date;
      v_prev_from := v_prev_month_start;
      v_prev_to := v_prev_month_start + (p_today - p_from_date);
      IF v_prev_to > v_prev_month_end THEN
        v_prev_to := v_prev_month_end;
      END IF;
      comparison_type := 'elapsed_mtd';
      comparison_current_from := p_from_date;
      comparison_current_to := p_today;
      previous_from := v_prev_from;
      previous_to := v_prev_to;
      RETURN NEXT;
      RETURN;
    END IF;

    v_cmp_from := p_from_date;
    v_cmp_to := LEAST(p_to_date, p_today);
    v_span := v_cmp_to - v_cmp_from;
    comparison_type := 'open_equal_length';
    comparison_current_from := v_cmp_from;
    comparison_current_to := v_cmp_to;
    previous_to := p_from_date - 1;
    previous_from := previous_to - v_span;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Future-only selected period
  comparison_type := 'not_applicable';
  comparison_current_from := NULL;
  comparison_current_to := NULL;
  previous_from := NULL;
  previous_to := NULL;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public._service_analytics_comparison_windows(date, date, date) IS
  'Internal Service Analytics previous-period windows. Today / YTD / elapsed MTD / equal-length / not_applicable. Not a second visit or revenue definition.';

REVOKE ALL ON FUNCTION public._service_analytics_comparison_windows(date, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._service_analytics_comparison_windows(date, date, date)
  FROM anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2) Trend status helper (internal)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._service_analytics_trend(
  p_previous numeric,
  p_current numeric,
  p_kind text,
  p_comparable boolean
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN NOT coalesce(p_comparable, false) THEN
      jsonb_build_object('status', 'not_applicable', 'pct', NULL)
    WHEN coalesce(p_previous, 0) > 0 THEN
      jsonb_build_object(
        'status',
        CASE
          WHEN round(100.0 * (coalesce(p_current, 0) - p_previous) / p_previous, 1) > 0 THEN 'increase'
          WHEN round(100.0 * (coalesce(p_current, 0) - p_previous) / p_previous, 1) < 0 THEN 'decrease'
          ELSE 'no_change'
        END,
        'pct', round(100.0 * (coalesce(p_current, 0) - p_previous) / p_previous, 1)
      )
    WHEN coalesce(p_previous, 0) = 0 AND coalesce(p_current, 0) > 0 THEN
      jsonb_build_object('status', 'new', 'pct', NULL)
    WHEN p_kind = 'visits' THEN
      jsonb_build_object('status', 'no_change', 'pct', 0)
    ELSE
      jsonb_build_object('status', 'not_applicable', 'pct', NULL)
  END;
$$;

COMMENT ON FUNCTION public._service_analytics_trend(numeric, numeric, text, boolean) IS
  'Internal Service Analytics trend JSON: increase|decrease|new|no_change|not_applicable. Visits 0→0 = no_change. Revenue 0→0 = not_applicable.';

REVOKE ALL ON FUNCTION public._service_analytics_trend(numeric, numeric, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._service_analytics_trend(numeric, numeric, text, boolean)
  FROM anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3) Owner-only canonical Service Analytics
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_service_analytics(
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
  v_today date;
  v_comparison_type text;
  v_cmp_from date;
  v_cmp_to date;
  v_prev_from date;
  v_prev_to date;
  v_comparable boolean;
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
  v_today := (v_report_now AT TIME ZONE v_timezone)::date;

  SELECT
    w.comparison_type,
    w.comparison_current_from,
    w.comparison_current_to,
    w.previous_from,
    w.previous_to
  INTO
    v_comparison_type,
    v_cmp_from,
    v_cmp_to,
    v_prev_from,
    v_prev_to
  FROM public._service_analytics_comparison_windows(p_from_date, p_to_date, v_today) w;

  v_comparable := (v_comparison_type IS DISTINCT FROM 'not_applicable' AND v_cmp_from IS NOT NULL AND v_prev_from IS NOT NULL);

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
      coalesce(
        src.service_id::text,
        'name:' || lower(coalesce(nullif(trim(src.service_name), ''), 'unknown'))
      ) AS group_key
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
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
        appointment_local_date IS NOT NULL
        AND appointment_local_date >= p_from_date
        AND appointment_local_date <= p_to_date
      ) AS is_selected,
      (
        v_cmp_from IS NOT NULL
        AND appointment_local_date IS NOT NULL
        AND appointment_local_date >= v_cmp_from
        AND appointment_local_date <= v_cmp_to
      ) AS is_comparison_current,
      (
        v_prev_from IS NOT NULL
        AND appointment_local_date IS NOT NULL
        AND appointment_local_date >= v_prev_from
        AND appointment_local_date <= v_prev_to
      ) AS is_previous
    FROM classified
    WHERE appointment_start IS NOT NULL
  ),
  first_biz AS (
    SELECT
      analytics_customer_key,
      min(appointment_local_date) AS first_completed_date
    FROM flagged
    WHERE is_completed_visit
      AND analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  current_groups AS (
    SELECT
      f.group_key,
      (ARRAY_AGG(f.service_id) FILTER (WHERE f.service_id IS NOT NULL))[1] AS service_id,
      coalesce(
        nullif(trim((ARRAY_AGG(f.catalog_service_name ORDER BY f.catalog_service_name) FILTER (WHERE nullif(trim(f.catalog_service_name), '') IS NOT NULL))[1]), ''),
        nullif(trim((ARRAY_AGG(f.service_name ORDER BY length(coalesce(f.service_name, '')) DESC) FILTER (WHERE nullif(trim(f.service_name), '') IS NOT NULL))[1]), ''),
        'Unknown service'
      ) AS display_name,
      bool_or(f.service_id IS NOT NULL AND f.catalog_service_name IS NULL) AS is_orphan,
      bool_and(f.catalog_service_name IS NULL) AS is_missing_from_catalog,
      count(*) FILTER (WHERE f.is_completed_visit)::bigint AS completed_visits,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
      count(*) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL)::bigint AS completed_revenue_known_visits,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'snapshot')::bigint AS completed_visits_with_snapshot_price,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'estimated')::bigint AS completed_visits_with_estimated_price,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'unknown')::bigint AS completed_visits_unknown_price,
      count(*) FILTER (WHERE f.is_scheduled)::bigint AS scheduled_bookings,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.is_scheduled AND f.canonical_price IS NOT NULL), 0)::numeric AS scheduled_value,
      count(*) FILTER (WHERE f.is_scheduled AND f.canonical_price IS NOT NULL)::bigint AS scheduled_value_known_bookings,
      count(*) FILTER (WHERE f.is_upcoming)::bigint AS upcoming_bookings,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.is_upcoming AND f.canonical_price IS NOT NULL), 0)::numeric AS upcoming_scheduled_value,
      count(*) FILTER (WHERE f.is_upcoming AND f.canonical_price IS NOT NULL)::bigint AS upcoming_value_known_bookings,
      count(DISTINCT f.analytics_customer_key) FILTER (
        WHERE f.is_completed_visit AND f.analytics_customer_key IS NOT NULL
      )::bigint AS unique_customers,
      count(DISTINCT f.analytics_customer_key) FILTER (
        WHERE f.is_completed_visit
          AND f.analytics_customer_key IS NOT NULL
          AND fb.first_completed_date >= p_from_date
          AND fb.first_completed_date <= p_to_date
      )::bigint AS new_customers,
      count(DISTINCT f.analytics_customer_key) FILTER (
        WHERE f.is_completed_visit
          AND f.analytics_customer_key IS NOT NULL
          AND fb.first_completed_date IS NOT NULL
          AND fb.first_completed_date < p_from_date
      )::bigint AS returning_customers,
      count(*) FILTER (WHERE f.is_cancelled)::bigint AS cancelled_bookings,
      count(*) FILTER (WHERE f.is_elapsed_unconfirmed)::bigint AS elapsed_unconfirmed_count
    FROM flagged f
    LEFT JOIN first_biz fb
      ON fb.analytics_customer_key = f.analytics_customer_key
    WHERE f.is_selected
      AND (f.is_scheduled OR f.is_completed_visit OR f.is_cancelled)
    GROUP BY f.group_key
  ),
  elapsed_groups AS (
    SELECT
      group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS elapsed_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS elapsed_completed_revenue
    FROM flagged
    WHERE is_comparison_current
    GROUP BY group_key
  ),
  previous_groups AS (
    SELECT
      group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS previous_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS previous_completed_revenue,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)::bigint AS previous_completed_revenue_known_visits
    FROM flagged
    WHERE is_previous
    GROUP BY group_key
  ),
  totals AS (
    SELECT
      coalesce(sum(completed_visits), 0)::bigint AS tot_visits,
      coalesce(sum(completed_revenue), 0)::numeric AS tot_revenue
    FROM current_groups
  ),
  quality AS (
    SELECT
      (SELECT count(*) FROM classified WHERE appointment_start IS NULL)::bigint AS invalid_datetime_count,
      (
        SELECT count(*)
        FROM classified
        WHERE appointment_start IS NOT NULL
          AND (duration_minutes IS NULL OR duration_minutes <= 0)
      )::bigint AS unknown_duration_count,
      (
        SELECT count(*)
        FROM flagged
        WHERE is_selected AND service_id IS NULL
      )::bigint AS bookings_missing_service_id,
      (
        SELECT count(DISTINCT service_id)
        FROM flagged
        WHERE is_selected
          AND service_id IS NOT NULL
          AND catalog_service_name IS NULL
      )::bigint AS orphan_service_count,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_total,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_with_known_price,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'snapshot')
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_with_snapshot_price,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'estimated')
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_with_estimated_price,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'unknown')
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_unknown_price,
      (
        SELECT count(*) FILTER (WHERE is_elapsed_unconfirmed)
        FROM flagged
        WHERE is_selected
      )::bigint AS elapsed_unconfirmed_count,
      (
        SELECT count(*) FILTER (WHERE is_scheduled AND price_source = 'estimated')
          + count(*) FILTER (WHERE is_completed_visit AND price_source = 'estimated')
        FROM flagged
        WHERE is_selected
      )::bigint AS estimated_price_signal
  ),
  ranked AS (
    SELECT
      g.*,
      coalesce(e.elapsed_completed_visits, 0)::bigint AS elapsed_completed_visits,
      coalesce(e.elapsed_completed_revenue, 0)::numeric AS elapsed_completed_revenue,
      coalesce(p.previous_completed_visits, 0)::bigint AS previous_completed_visits,
      coalesce(p.previous_completed_revenue, 0)::numeric AS previous_completed_revenue,
      coalesce(p.previous_completed_revenue_known_visits, 0)::bigint AS previous_completed_revenue_known_visits,
      CASE
        WHEN g.completed_revenue_known_visits > 0
          THEN round(g.completed_revenue / g.completed_revenue_known_visits, 2)
        ELSE NULL
      END AS avg_completed_visit_value,
      CASE
        WHEN (g.scheduled_bookings + g.cancelled_bookings) > 0
          THEN round(100.0 * g.cancelled_bookings / (g.scheduled_bookings + g.cancelled_bookings), 1)
        ELSE NULL
      END AS cancellation_rate,
      CASE
        WHEN t.tot_visits > 0
          THEN round(100.0 * g.completed_visits / t.tot_visits, 1)
        ELSE NULL
      END AS visit_share_pct,
      CASE
        WHEN t.tot_revenue > 0
          THEN round(100.0 * g.completed_revenue / t.tot_revenue, 1)
        ELSE NULL
      END AS revenue_share_pct,
      public._service_analytics_trend(
        coalesce(p.previous_completed_visits, 0)::numeric,
        coalesce(e.elapsed_completed_visits, 0)::numeric,
        'visits',
        v_comparable
      ) AS visit_trend,
      public._service_analytics_trend(
        coalesce(p.previous_completed_revenue, 0),
        coalesce(e.elapsed_completed_revenue, 0),
        'revenue',
        v_comparable
      ) AS revenue_trend,
      row_number() OVER (
        ORDER BY g.completed_visits DESC, g.completed_revenue DESC, g.display_name ASC, g.group_key ASC
      ) AS visits_ord,
      row_number() OVER (
        ORDER BY g.completed_revenue DESC, g.completed_visits DESC, g.display_name ASC, g.group_key ASC
      ) AS revenue_ord
    FROM current_groups g
    CROSS JOIN totals t
    LEFT JOIN elapsed_groups e ON e.group_key = g.group_key
    LEFT JOIN previous_groups p ON p.group_key = g.group_key
  ),
  services_json AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'group_key', r.group_key,
          'service_id', r.service_id,
          'display_name', r.display_name,
          'is_orphan', r.is_orphan,
          'is_missing_from_catalog', r.is_missing_from_catalog,
          'completed_visits', r.completed_visits,
          'completed_revenue', r.completed_revenue,
          'completed_revenue_known_visits', r.completed_revenue_known_visits,
          'avg_completed_visit_value', r.avg_completed_visit_value,
          'scheduled_bookings', r.scheduled_bookings,
          'scheduled_value', r.scheduled_value,
          'scheduled_value_known_bookings', r.scheduled_value_known_bookings,
          'upcoming_bookings', r.upcoming_bookings,
          'upcoming_scheduled_value', r.upcoming_scheduled_value,
          'upcoming_value_known_bookings', r.upcoming_value_known_bookings,
          'unique_customers', r.unique_customers,
          'new_customers', r.new_customers,
          'returning_customers', r.returning_customers,
          'cancelled_bookings', r.cancelled_bookings,
          'cancellation_rate', r.cancellation_rate,
          'visit_share_pct', r.visit_share_pct,
          'revenue_share_pct', r.revenue_share_pct,
          'elapsed_unconfirmed_count', r.elapsed_unconfirmed_count,
          'previous_completed_visits', r.previous_completed_visits,
          'previous_completed_revenue', r.previous_completed_revenue,
          'previous_completed_revenue_known_visits', r.previous_completed_revenue_known_visits,
          'visit_trend', r.visit_trend,
          'revenue_trend', r.revenue_trend,
          'completed_visits_with_snapshot_price', r.completed_visits_with_snapshot_price,
          'completed_visits_with_estimated_price', r.completed_visits_with_estimated_price,
          'completed_visits_unknown_price', r.completed_visits_unknown_price
        )
        ORDER BY r.visits_ord
      ),
      '[]'::jsonb
    ) AS payload
    FROM ranked r
  ),
  top_visits AS (
    SELECT jsonb_build_object(
      'group_key', r.group_key,
      'display_name', r.display_name,
      'completed_visits', r.completed_visits
    ) AS payload
    FROM ranked r
    WHERE r.visits_ord = 1
      AND r.completed_visits > 0
  ),
  top_revenue AS (
    SELECT jsonb_build_object(
      'group_key', r.group_key,
      'display_name', r.display_name,
      'completed_revenue', r.completed_revenue
    ) AS payload
    FROM ranked r
    WHERE r.revenue_ord = 1
      AND r.completed_visits > 0
  )
  SELECT jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'timezone', v_timezone,
    'from_date', p_from_date,
    'to_date', p_to_date,
    'report_now', v_report_now,
    'today_local', v_today,
    'comparison_current_from', v_cmp_from,
    'comparison_current_to', v_cmp_to,
    'previous_from', v_prev_from,
    'previous_to', v_prev_to,
    'comparison_type', v_comparison_type,
    'summary', jsonb_build_object(
      'top_service_by_visits', (SELECT payload FROM top_visits),
      'top_service_by_revenue', (SELECT payload FROM top_revenue),
      'services_used', (SELECT count(*) FROM current_groups),
      'contains_estimated_prices', (q.completed_visits_with_estimated_price > 0 OR q.estimated_price_signal > 0),
      'price_snapshot_coverage_pct',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_with_snapshot_price) / q.completed_visits_total, 1)
          ELSE NULL
        END,
      'price_snapshot_coverage_denominator', 'completed_visits_total'
    ),
    'services', sj.payload,
    'quality', jsonb_build_object(
      'completed_visits_total', q.completed_visits_total,
      'completed_visits_with_known_price', q.completed_visits_with_known_price,
      'completed_visits_with_snapshot_price', q.completed_visits_with_snapshot_price,
      'completed_visits_with_estimated_price', q.completed_visits_with_estimated_price,
      'completed_visits_unknown_price', q.completed_visits_unknown_price,
      'price_snapshot_coverage_pct',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_with_snapshot_price) / q.completed_visits_total, 1)
          ELSE NULL
        END,
      'contains_estimated_prices', (q.completed_visits_with_estimated_price > 0 OR q.estimated_price_signal > 0),
      'bookings_missing_service_id', q.bookings_missing_service_id,
      'orphan_service_count', q.orphan_service_count,
      'invalid_datetime_count', q.invalid_datetime_count,
      'unknown_duration_count', q.unknown_duration_count,
      'elapsed_unconfirmed_count', q.elapsed_unconfirmed_count
    )
  )
  INTO v_result
  FROM quality q
  CROSS JOIN services_json sj;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_business_service_analytics(uuid, date, date) IS
  'Owner-only canonical Service Analytics. Full-tenant scan. Completed visit / price / identity match Performance + Customer Analytics. Group key matches Performance Top Services. Previous period computed server-side. cancellation_rate is 0-100 with 1 decimal, null if no Pending+Confirmed+Cancelled in period. Revenue is snapshot-or-estimated; estimated is disclosed, not collected cash.';

REVOKE ALL ON FUNCTION public.get_business_service_analytics(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_service_analytics(uuid, date, date) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_service_analytics(uuid, date, date) TO authenticated;

COMMIT;
