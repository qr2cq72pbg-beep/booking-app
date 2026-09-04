-- =============================================================================
-- XBOOK Phase 5B: Canonical Staff Analytics RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public.get_business_staff_analytics(uuid, date, date) → jsonb
--
-- Reuses live (bodies untouched):
--   public._performance_appointment_start
--   public._analytics_customer_key
--   public._resolve_business_analytics_customer_key
--   public._service_analytics_comparison_windows
--   public._service_analytics_trend
--   Canonical completed-visit / price CASE from Phase 1A Performance
--   Canonical service group_key + display_name coalesce from Performance / Service Analytics
--
-- Does NOT:
--   change get_business_performance_report / customer / service analytics RPCs
--   backfill booking_price or bookings.staff_name
--   rewrite historical bookings or staff assignment
--   add indexes, Staff Detail, utilization, or UI
--
-- Display limitation (V1):
--   Rename keeps group_key = staff_id and follows current staff_members.name.
--   Deleted/orphan UUID history is kept as 'Unknown staff'.
--   bookings.staff_name exists but is unused; this RPC does not write it.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_business_staff_analytics(
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
  v_active_team_size bigint;
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

  SELECT count(*) FILTER (WHERE coalesce(sm.active, true))
  INTO v_active_team_size
  FROM public.staff_members sm
  WHERE sm.business_id = p_business_id;

  v_active_team_size := coalesce(v_active_team_size, 0);

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
      b.staff_id,
      st.id AS staff_row_id,
      st.name AS staff_name,
      st.role AS staff_role,
      st.active AS staff_active,
      st.photo_url AS staff_photo_url,
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
      CASE
        WHEN src.staff_id IS NOT NULL THEN src.staff_id::text
        ELSE 'unassigned'
      END AS staff_group_key,
      (src.staff_id IS NULL) AS is_unassigned,
      (src.staff_id IS NOT NULL AND src.staff_row_id IS NULL) AS is_orphan,
      coalesce(
        src.service_id::text,
        'name:' || lower(coalesce(nullif(trim(src.service_name), ''), 'unknown'))
      ) AS service_group_key
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
      min(appointment_local_date) AS first_completed_date,
      count(*)::bigint AS lifetime_completed
    FROM flagged
    WHERE is_completed_visit
      AND analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  current_groups AS (
    SELECT
      f.staff_group_key AS group_key,
      (ARRAY_AGG(f.staff_id) FILTER (WHERE f.staff_id IS NOT NULL))[1] AS staff_id,
      CASE
        WHEN bool_or(f.is_unassigned) THEN 'Unassigned'
        WHEN bool_or(f.is_orphan) THEN 'Unknown staff'
        ELSE coalesce(
          nullif(trim((ARRAY_AGG(f.staff_name ORDER BY length(coalesce(f.staff_name, '')) DESC)
            FILTER (WHERE nullif(trim(f.staff_name), '') IS NOT NULL))[1]), ''),
          'Unknown staff'
        )
      END AS display_name,
      CASE
        WHEN bool_or(f.is_unassigned) OR bool_or(f.is_orphan) THEN NULL
        ELSE nullif(trim((ARRAY_AGG(f.staff_role ORDER BY length(coalesce(f.staff_role, '')) DESC)
          FILTER (WHERE nullif(trim(f.staff_role), '') IS NOT NULL))[1]), '')
      END AS role,
      CASE
        WHEN bool_or(f.is_unassigned) OR bool_or(f.is_orphan) THEN NULL
        ELSE nullif(trim((ARRAY_AGG(f.staff_photo_url)
          FILTER (WHERE nullif(trim(f.staff_photo_url), '') IS NOT NULL))[1]), '')
      END AS photo_url,
      CASE
        WHEN bool_or(f.is_unassigned) OR bool_or(f.is_orphan) THEN false
        ELSE bool_and(coalesce(f.staff_active, true))
      END AS is_active,
      bool_or(f.is_unassigned) AS is_unassigned,
      bool_or(f.is_orphan) AS is_orphan,
      count(*) FILTER (WHERE f.is_completed_visit)::bigint AS completed_visits,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
      count(*) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL)::bigint AS completed_revenue_known_visits,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'snapshot')::bigint AS snapshot_price_completed_count,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'estimated')::bigint AS estimated_price_completed_count,
      count(*) FILTER (WHERE f.is_completed_visit AND f.price_source = 'unknown')::bigint AS unknown_price_completed_count,
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
      count(DISTINCT f.analytics_customer_key) FILTER (
        WHERE f.is_completed_visit
          AND f.analytics_customer_key IS NOT NULL
          AND fb.lifetime_completed >= 2
      )::bigint AS repeat_customers_served,
      count(*) FILTER (WHERE f.is_cancelled)::bigint AS cancelled_bookings,
      count(*) FILTER (WHERE f.is_elapsed_unconfirmed)::bigint AS elapsed_unconfirmed_count,
      coalesce(sum(f.duration_minutes) FILTER (
        WHERE f.is_completed_visit AND f.duration_minutes IS NOT NULL AND f.duration_minutes > 0
      ), 0)::bigint AS completed_minutes,
      coalesce(sum(f.duration_minutes) FILTER (
        WHERE f.is_scheduled AND f.duration_minutes IS NOT NULL AND f.duration_minutes > 0
      ), 0)::bigint AS scheduled_minutes,
      coalesce(sum(f.duration_minutes) FILTER (
        WHERE f.is_upcoming AND f.duration_minutes IS NOT NULL AND f.duration_minutes > 0
      ), 0)::bigint AS upcoming_minutes,
      count(*) FILTER (WHERE f.duration_minutes IS NULL OR f.duration_minutes <= 0)::bigint AS unknown_duration_count,
      count(DISTINCT f.service_group_key) FILTER (WHERE f.is_completed_visit)::bigint AS services_delivered
    FROM flagged f
    LEFT JOIN first_biz fb
      ON fb.analytics_customer_key = f.analytics_customer_key
    WHERE f.is_selected
      AND (f.is_scheduled OR f.is_completed_visit OR f.is_cancelled)
    GROUP BY f.staff_group_key
  ),
  top_service_ranked AS (
    SELECT
      f.staff_group_key,
      f.service_group_key,
      (ARRAY_AGG(f.service_id) FILTER (WHERE f.service_id IS NOT NULL))[1] AS service_id,
      coalesce(
        nullif(trim((ARRAY_AGG(f.catalog_service_name ORDER BY f.catalog_service_name)
          FILTER (WHERE nullif(trim(f.catalog_service_name), '') IS NOT NULL))[1]), ''),
        nullif(trim((ARRAY_AGG(f.service_name ORDER BY length(coalesce(f.service_name, '')) DESC)
          FILTER (WHERE nullif(trim(f.service_name), '') IS NOT NULL))[1]), ''),
        'Unknown service'
      ) AS display_name,
      count(*)::bigint AS completed_visits,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.canonical_price IS NOT NULL), 0)::numeric AS completed_revenue,
      row_number() OVER (
        PARTITION BY f.staff_group_key
        ORDER BY
          count(*) DESC,
          coalesce(sum(f.canonical_price) FILTER (WHERE f.canonical_price IS NOT NULL), 0) DESC,
          f.service_group_key ASC
      ) AS rn
    FROM flagged f
    WHERE f.is_selected
      AND f.is_completed_visit
    GROUP BY f.staff_group_key, f.service_group_key
  ),
  elapsed_groups AS (
    SELECT
      staff_group_key AS group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS elapsed_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS elapsed_completed_revenue
    FROM flagged
    WHERE is_comparison_current
    GROUP BY staff_group_key
  ),
  previous_groups AS (
    SELECT
      staff_group_key AS group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS previous_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS previous_completed_revenue,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)::bigint AS previous_completed_revenue_known_visits
    FROM flagged
    WHERE is_previous
    GROUP BY staff_group_key
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
        WHERE is_selected AND staff_id IS NULL
      )::bigint AS bookings_missing_staff_id,
      (
        SELECT count(DISTINCT staff_id)
        FROM flagged
        WHERE is_selected
          AND staff_id IS NOT NULL
          AND staff_row_id IS NULL
      )::bigint AS orphan_staff_count,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_total,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND staff_id IS NOT NULL)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_with_staff,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND staff_id IS NULL)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits_unassigned,
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
      ts.service_group_key AS top_service_group_key,
      ts.service_id AS top_service_id,
      ts.display_name AS top_service_display_name,
      ts.completed_visits AS top_service_completed_visits,
      ts.completed_revenue AS top_service_completed_revenue,
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
      ) AS revenue_ord,
      row_number() OVER (
        PARTITION BY (NOT g.is_unassigned)
        ORDER BY g.completed_visits DESC, g.completed_revenue DESC, g.display_name ASC, g.group_key ASC
      ) AS real_visits_ord,
      row_number() OVER (
        PARTITION BY (NOT g.is_unassigned)
        ORDER BY g.completed_revenue DESC, g.completed_visits DESC, g.display_name ASC, g.group_key ASC
      ) AS real_revenue_ord
    FROM current_groups g
    CROSS JOIN totals t
    LEFT JOIN elapsed_groups e ON e.group_key = g.group_key
    LEFT JOIN previous_groups p ON p.group_key = g.group_key
    LEFT JOIN top_service_ranked ts
      ON ts.staff_group_key = g.group_key
     AND ts.rn = 1
  ),
  staff_json AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'group_key', r.group_key,
          'staff_id', r.staff_id,
          'display_name', r.display_name,
          'role', r.role,
          'photo_url', r.photo_url,
          'is_active', r.is_active,
          'is_unassigned', r.is_unassigned,
          'is_orphan', r.is_orphan,
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
          'repeat_customers_served', r.repeat_customers_served,
          'cancelled_bookings', r.cancelled_bookings,
          'cancellation_rate', r.cancellation_rate,
          'visit_share_pct', r.visit_share_pct,
          'revenue_share_pct', r.revenue_share_pct,
          'previous_completed_visits', r.previous_completed_visits,
          'previous_completed_revenue', r.previous_completed_revenue,
          'previous_completed_revenue_known_visits', r.previous_completed_revenue_known_visits,
          'visit_trend', r.visit_trend,
          'revenue_trend', r.revenue_trend,
          'services_delivered', r.services_delivered,
          'top_service',
            CASE
              WHEN r.top_service_group_key IS NULL THEN NULL
              ELSE jsonb_build_object(
                'group_key', r.top_service_group_key,
                'service_id', r.top_service_id,
                'display_name', r.top_service_display_name,
                'completed_visits', r.top_service_completed_visits,
                'completed_revenue', r.top_service_completed_revenue
              )
            END,
          'completed_minutes', r.completed_minutes,
          'scheduled_minutes', r.scheduled_minutes,
          'upcoming_minutes', r.upcoming_minutes,
          'unknown_duration_count', r.unknown_duration_count,
          'elapsed_unconfirmed_count', r.elapsed_unconfirmed_count,
          'snapshot_price_completed_count', r.snapshot_price_completed_count,
          'estimated_price_completed_count', r.estimated_price_completed_count,
          'unknown_price_completed_count', r.unknown_price_completed_count
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
      'staff_id', r.staff_id,
      'display_name', r.display_name,
      'completed_visits', r.completed_visits
    ) AS payload
    FROM ranked r
    WHERE NOT r.is_unassigned
      AND r.completed_visits > 0
      AND r.real_visits_ord = 1
  ),
  top_revenue AS (
    SELECT jsonb_build_object(
      'group_key', r.group_key,
      'staff_id', r.staff_id,
      'display_name', r.display_name,
      'completed_revenue', r.completed_revenue
    ) AS payload
    FROM ranked r
    WHERE NOT r.is_unassigned
      AND r.completed_visits > 0
      AND r.real_revenue_ord = 1
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
      'top_staff_by_visits', (SELECT payload FROM top_visits),
      'top_staff_by_revenue', (SELECT payload FROM top_revenue),
      'staff_with_period_activity', (
        SELECT count(*)::bigint FROM current_groups WHERE NOT is_unassigned
      ),
      'active_team_size', v_active_team_size,
      'unassigned_completed_visits', q.completed_visits_unassigned,
      'unassigned_visit_share_pct',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_unassigned) / q.completed_visits_total, 1)
          ELSE NULL
        END,
      'has_material_unassigned_history',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_unassigned) / q.completed_visits_total, 1) >= 10
          ELSE false
        END,
      'contains_estimated_prices', (q.completed_visits_with_estimated_price > 0 OR q.estimated_price_signal > 0),
      'price_snapshot_coverage_pct',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_with_snapshot_price) / q.completed_visits_total, 1)
          ELSE NULL
        END,
      'price_snapshot_coverage_denominator', 'completed_visits_total'
    ),
    'staff', sj.payload,
    'quality', jsonb_build_object(
      'completed_visits_total', q.completed_visits_total,
      'completed_visits_with_staff', q.completed_visits_with_staff,
      'completed_visits_unassigned', q.completed_visits_unassigned,
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
      'bookings_missing_staff_id', q.bookings_missing_staff_id,
      'orphan_staff_count', q.orphan_staff_count,
      'invalid_datetime_count', q.invalid_datetime_count,
      'unknown_duration_count', q.unknown_duration_count,
      'elapsed_unconfirmed_count', q.elapsed_unconfirmed_count,
      'unassigned_visit_share_pct',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_unassigned) / q.completed_visits_total, 1)
          ELSE NULL
        END,
      'has_material_unassigned_history',
        CASE
          WHEN q.completed_visits_total > 0
            THEN round((100.0 * q.completed_visits_unassigned) / q.completed_visits_total, 1) >= 10
          ELSE false
        END
    )
  )
  INTO v_result
  FROM quality q
  CROSS JOIN staff_json sj;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_business_staff_analytics(uuid, date, date) IS
  'Owner-only canonical Staff Analytics. Group key = staff_id or unassigned. Completed visit / price / identity / comparison match Performance + Service Analytics. Unassigned is first-class and cannot win Top Staff. Rename follows live staff_members.name. Orphan UUID history kept as Unknown staff. No utilization. Does not write bookings.staff_name.';

REVOKE ALL ON FUNCTION public.get_business_staff_analytics(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_staff_analytics(uuid, date, date) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_staff_analytics(uuid, date, date) TO authenticated;

COMMIT;
