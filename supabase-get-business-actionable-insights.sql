-- =============================================================================
-- XBOOK Phase 8B: Canonical Actionable Insights RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public.get_business_actionable_insights(uuid, date, date) → jsonb
--
-- Reuses live (bodies untouched):
--   public._performance_appointment_start
--   public._analytics_customer_key
--   public._resolve_business_analytics_customer_key
--   public._business_analytics_customer_keys
--   public._service_analytics_comparison_windows
--   public._service_analytics_trend
--   Canonical completed-visit / upcoming / price CASE from Performance
--   Canonical service group_key + display_name from Service Analytics
--   Canonical Unassigned grouping + >=10% share from Staff Analytics
--   Canonical CRM VIP attach from Cross Analytics
--
-- Does NOT:
--   call existing JSON analytics RPCs internally
--   change existing analytics formulas or signatures
--   add indexes, UI, AI, campaigns, export, dismiss, or Detail screens
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_business_actionable_insights(
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
      b.staff_id,
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
      ) AS service_group_key,
      (src.staff_id IS NULL) AS is_unassigned
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
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start IS NOT NULL
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
  quality AS (
    SELECT
      (
        SELECT count(*) FILTER (WHERE is_completed_visit)
        FROM flagged
        WHERE is_selected
      )::bigint AS completed_visits,
      (
        SELECT coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)
        FROM flagged
        WHERE is_selected
      )::numeric AS known_completed_revenue,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'snapshot')
        FROM flagged
        WHERE is_selected
      )::bigint AS snapshot_price_count,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'estimated')
        FROM flagged
        WHERE is_selected
      )::bigint AS estimated_price_count,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND price_source = 'unknown')
        FROM flagged
        WHERE is_selected
      )::bigint AS unknown_price_count,
      (
        SELECT count(*) FILTER (WHERE is_completed_visit AND is_unassigned)
        FROM flagged
        WHERE is_selected
      )::bigint AS unassigned_completed_visits,
      (
        SELECT count(*) FILTER (WHERE analytics_customer_key IS NULL)
        FROM classified
      )::bigint AS unidentified_booking_count,
      (
        SELECT count(*) FILTER (WHERE appointment_start IS NULL)
        FROM classified
      )::bigint AS invalid_appointment_time_count,
      (
        SELECT count(*) FILTER (
          WHERE appointment_start IS NOT NULL
            AND (duration_minutes IS NULL OR duration_minutes <= 0)
        )
        FROM classified
      )::bigint AS unknown_duration_count
  ),
  pop AS (
    SELECT *
    FROM public._business_analytics_customer_keys(p_business_id)
  ),
  customer_stats AS (
    SELECT
      analytics_customer_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS lifetime_completed,
      max(appointment_start) FILTER (WHERE is_completed_visit) AS last_completed_visit_at,
      bool_or(is_upcoming) AS has_upcoming
    FROM flagged
    WHERE analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  crm AS (
    SELECT DISTINCT ON (map_key)
      map_key,
      bc.is_vip
    FROM (
      SELECT
        bc.*,
        CASE
          WHEN bc.customer_user_id IS NOT NULL THEN 'u:' || bc.customer_user_id::text
          ELSE public._resolve_business_analytics_customer_key(
            p_business_id,
            nullif(trim(bc.client_key), '')
          )
        END AS map_key
      FROM public.business_customers bc
      WHERE bc.business_id = p_business_id
    ) bc
    WHERE map_key IS NOT NULL
    ORDER BY
      map_key,
      CASE WHEN bc.customer_user_id IS NOT NULL THEN 0 ELSE 1 END,
      bc.created_at ASC,
      bc.id ASC
  ),
  cust AS (
    SELECT
      p.analytics_customer_key,
      coalesce(cs.lifetime_completed, 0)::bigint AS lifetime_completed,
      coalesce(cs.has_upcoming, false) AS has_upcoming,
      CASE
        WHEN cs.last_completed_visit_at IS NULL THEN NULL
        ELSE v_report_now - cs.last_completed_visit_at
      END AS inactive_for,
      coalesce(crm.is_vip, false) AS is_vip
    FROM pop p
    LEFT JOIN customer_stats cs
      ON cs.analytics_customer_key = p.analytics_customer_key
    LEFT JOIN crm
      ON crm.map_key = p.analytics_customer_key
  ),
  customer_counts AS (
    SELECT
      count(*) FILTER (
        WHERE is_vip
          AND lifetime_completed > 0
          AND inactive_for > interval '60 days'
          AND NOT has_upcoming
      )::bigint AS vip_inactive_n,
      count(*) FILTER (
        WHERE lifetime_completed >= 2
          AND inactive_for > interval '60 days'
          AND NOT has_upcoming
      )::bigint AS repeat_inactive_n,
      count(*) FILTER (
        WHERE lifetime_completed >= 2
          AND NOT has_upcoming
      )::bigint AS repeat_no_future_n
    FROM cust
  ),
  current_groups AS (
    SELECT
      f.service_group_key AS group_key,
      (ARRAY_AGG(f.service_id) FILTER (WHERE f.service_id IS NOT NULL))[1] AS service_id,
      coalesce(
        nullif(trim((ARRAY_AGG(f.catalog_service_name ORDER BY f.catalog_service_name) FILTER (WHERE nullif(trim(f.catalog_service_name), '') IS NOT NULL))[1]), ''),
        nullif(trim((ARRAY_AGG(f.service_name ORDER BY length(coalesce(f.service_name, '')) DESC) FILTER (WHERE nullif(trim(f.service_name), '') IS NOT NULL))[1]), ''),
        'Unknown service'
      ) AS display_name,
      count(*) FILTER (WHERE f.is_completed_visit)::bigint AS completed_visits,
      coalesce(sum(f.canonical_price) FILTER (WHERE f.is_completed_visit AND f.canonical_price IS NOT NULL), 0)::numeric AS completed_revenue
    FROM flagged f
    WHERE f.is_selected
      AND (f.is_scheduled OR f.is_completed_visit OR f.is_cancelled)
    GROUP BY f.service_group_key
  ),
  elapsed_groups AS (
    SELECT
      service_group_key AS group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS elapsed_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS elapsed_completed_revenue
    FROM flagged
    WHERE is_comparison_current
    GROUP BY service_group_key
  ),
  previous_groups AS (
    SELECT
      service_group_key AS group_key,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS previous_completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS previous_completed_revenue
    FROM flagged
    WHERE is_previous
    GROUP BY service_group_key
  ),
  totals AS (
    SELECT
      coalesce(sum(completed_visits), 0)::bigint AS tot_visits,
      coalesce(sum(completed_revenue), 0)::numeric AS tot_revenue,
      count(*)::bigint AS services_used
    FROM current_groups
  ),
  ranked_services AS (
    SELECT
      g.group_key,
      g.service_id,
      g.display_name,
      g.completed_visits,
      g.completed_revenue,
      CASE
        WHEN t.tot_revenue > 0
          THEN round(100.0 * g.completed_revenue / t.tot_revenue, 1)
        ELSE NULL
      END AS revenue_share_pct,
      coalesce(e.elapsed_completed_visits, 0)::bigint AS elapsed_completed_visits,
      coalesce(e.elapsed_completed_revenue, 0)::numeric AS elapsed_completed_revenue,
      coalesce(p.previous_completed_visits, 0)::bigint AS previous_completed_visits,
      coalesce(p.previous_completed_revenue, 0)::numeric AS previous_completed_revenue,
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
      ) AS revenue_trend
    FROM current_groups g
    CROSS JOIN totals t
    LEFT JOIN elapsed_groups e ON e.group_key = g.group_key
    LEFT JOIN previous_groups p ON p.group_key = g.group_key
  ),
  concentration_cand AS (
    SELECT r.*
    FROM ranked_services r
    CROSS JOIN totals t
    CROSS JOIN quality q
    WHERE t.tot_revenue > 0
      AND q.completed_visits >= 5
      AND t.services_used >= 2
      AND r.completed_visits >= 3
      AND r.revenue_share_pct IS NOT NULL
      AND r.revenue_share_pct >= 40
    ORDER BY r.revenue_share_pct DESC, r.completed_visits DESC, r.group_key ASC
    LIMIT 1
  ),
  trend_eval AS (
    SELECT
      r.*,
      CASE
        WHEN NOT v_comparable THEN NULL
        WHEN r.previous_completed_visits < 3 THEN NULL
        WHEN r.elapsed_completed_visits < 3 THEN NULL
        WHEN r.revenue_trend->>'status' = 'decrease'
          AND abs(coalesce((r.revenue_trend->>'pct')::numeric, 0)) >= 25
          THEN 'revenue'
        WHEN r.revenue_trend->>'status' = 'not_applicable'
          AND r.visit_trend->>'status' = 'decrease'
          AND abs(coalesce((r.visit_trend->>'pct')::numeric, 0)) >= 25
          THEN 'visits'
        ELSE NULL
      END AS trend_metric
    FROM ranked_services r
  ),
  trend_cand AS (
    SELECT
      t.group_key,
      t.display_name,
      t.trend_metric AS metric,
      CASE
        WHEN t.trend_metric = 'revenue' THEN (t.revenue_trend->>'pct')::numeric
        ELSE (t.visit_trend->>'pct')::numeric
      END AS change_pct,
      CASE
        WHEN t.trend_metric = 'revenue' THEN t.previous_completed_revenue
        ELSE t.previous_completed_visits::numeric
      END AS previous_value,
      CASE
        WHEN t.trend_metric = 'revenue' THEN t.elapsed_completed_revenue
        ELSE t.elapsed_completed_visits::numeric
      END AS current_value,
      t.completed_visits,
      t.elapsed_completed_visits,
      t.elapsed_completed_revenue
    FROM trend_eval t
    WHERE t.trend_metric IS NOT NULL
    ORDER BY
      abs(
        CASE
          WHEN t.trend_metric = 'revenue' THEN (t.revenue_trend->>'pct')::numeric
          ELSE (t.visit_trend->>'pct')::numeric
        END
      ) DESC,
      CASE
        WHEN t.trend_metric = 'revenue' THEN t.elapsed_completed_revenue
        ELSE t.elapsed_completed_visits::numeric
      END DESC,
      t.group_key ASC
    LIMIT 1
  ),
  unassigned_stats AS (
    SELECT
      q.completed_visits,
      q.unassigned_completed_visits,
      CASE
        WHEN q.completed_visits > 0
          THEN round((100.0 * q.unassigned_completed_visits) / q.completed_visits, 1)
        ELSE NULL
      END AS share_pct
    FROM quality q
  ),
  raw_candidates AS (
    SELECT
      'vip_inactive_no_future'::text AS id,
      'attention'::text AS category,
      100 AS priority,
      cc.vip_inactive_n::numeric AS metric_value,
      cc.vip_inactive_n AS count,
      'insightVipInactiveNoFuture'::text AS title_key,
      jsonb_build_object('count', cc.vip_inactive_n, 'days', 60) AS params,
      jsonb_build_object(
        'type', 'cross_analytics',
        'filters', jsonb_build_object(
          'is_vip', true,
          'inactive_days_min', 60,
          'has_future_booking', false
        )
      ) AS action,
      NULL::text AS service_key
    FROM customer_counts cc
    WHERE cc.vip_inactive_n >= 1

    UNION ALL
    SELECT
      'repeat_inactive_no_future',
      'attention',
      90,
      cc.repeat_inactive_n::numeric,
      cc.repeat_inactive_n,
      'insightRepeatInactiveNoFuture',
      jsonb_build_object('count', cc.repeat_inactive_n, 'days', 60),
      jsonb_build_object(
        'type', 'cross_analytics',
        'filters', jsonb_build_object(
          'visit_frequency', 'repeat',
          'inactive_days_min', 60,
          'has_future_booking', false
        )
      ),
      NULL
    FROM customer_counts cc
    WHERE cc.repeat_inactive_n >= 1

    UNION ALL
    SELECT
      'repeat_no_future',
      'opportunity',
      70,
      cc.repeat_no_future_n::numeric,
      cc.repeat_no_future_n,
      'insightRepeatNoFuture',
      jsonb_build_object('count', cc.repeat_no_future_n),
      jsonb_build_object(
        'type', 'cross_analytics',
        'filters', jsonb_build_object(
          'visit_frequency', 'repeat',
          'has_future_booking', false
        )
      ),
      NULL
    FROM customer_counts cc
    WHERE cc.repeat_no_future_n >= 1
      AND cc.repeat_inactive_n = 0

    UNION ALL
    SELECT
      'staff_unassigned_share',
      'quality',
      80,
      u.share_pct,
      u.unassigned_completed_visits,
      'insightStaffUnassignedShare',
      jsonb_build_object(
        'share_pct', u.share_pct,
        'unassigned_visits', u.unassigned_completed_visits,
        'completed_visits', u.completed_visits
      ),
      jsonb_build_object('type', 'staff_analytics'),
      NULL
    FROM unassigned_stats u
    WHERE u.share_pct IS NOT NULL
      AND u.share_pct >= 10
      AND u.unassigned_completed_visits >= 2

    UNION ALL
    SELECT
      'service_negative_trend',
      'performance',
      60,
      abs(t.change_pct),
      t.completed_visits,
      'insightServiceNegativeTrend',
      jsonb_build_object(
        'service_key', t.group_key,
        'service_name', t.display_name,
        'metric', t.metric,
        'change_pct', t.change_pct,
        'previous_value', t.previous_value,
        'current_value', t.current_value
      ),
      jsonb_build_object('type', 'service_analytics'),
      t.group_key
    FROM trend_cand t

    UNION ALL
    SELECT
      'service_revenue_concentration',
      'performance',
      50,
      c.revenue_share_pct,
      c.completed_visits,
      'insightServiceRevenueConcentration',
      jsonb_build_object(
        'service_key', c.group_key,
        'service_name', c.display_name,
        'share_pct', c.revenue_share_pct,
        'completed_visits', c.completed_visits,
        'completed_revenue', c.completed_revenue
      ),
      jsonb_build_object('type', 'service_analytics'),
      c.group_key
    FROM concentration_cand c
    WHERE NOT EXISTS (
      SELECT 1
      FROM trend_cand t
      WHERE t.group_key = c.group_key
    )
  ),
  top3 AS (
    SELECT
      r.id,
      r.category,
      r.priority,
      r.metric_value,
      r.count,
      r.title_key,
      r.params,
      r.action
    FROM raw_candidates r
    ORDER BY r.priority DESC, r.metric_value DESC, r.id ASC
    LIMIT 3
  ),
  insights_json AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', t.id,
          'category', t.category,
          'priority', t.priority,
          'metric_value', t.metric_value,
          'count', t.count,
          'title_key', t.title_key,
          'params', t.params,
          'action', t.action
        )
        ORDER BY t.priority DESC, t.metric_value DESC, t.id ASC
      ),
      '[]'::jsonb
    ) AS payload
    FROM top3 t
  )
  SELECT jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object(
      'from_date', p_from_date,
      'to_date', p_to_date,
      'timezone', v_timezone,
      'report_now', v_report_now
    ),
    'insights', ij.payload,
    'quality', jsonb_build_object(
      'completed_visits', q.completed_visits,
      'known_completed_revenue', q.known_completed_revenue,
      'snapshot_price_count', q.snapshot_price_count,
      'estimated_price_count', q.estimated_price_count,
      'unknown_price_count', q.unknown_price_count,
      'contains_estimated_prices', (q.estimated_price_count > 0),
      'unidentified_booking_count', q.unidentified_booking_count,
      'invalid_appointment_time_count', q.invalid_appointment_time_count,
      'unknown_duration_count', q.unknown_duration_count,
      'unassigned_completed_visits', q.unassigned_completed_visits,
      'services_used', t.services_used
    )
  )
  INTO v_result
  FROM quality q
  CROSS JOIN totals t
  CROSS JOIN insights_json ij;

  RETURN v_result;
END;
$$;

COMMENT ON FUNCTION public.get_business_actionable_insights(uuid, date, date) IS
  'Owner-only Actionable Insights V1. Deterministic max-3 ranked observations from canonical visit/price/identity/Unassigned/trend formulas. Does not call existing analytics JSON RPCs. No localized prose.';

REVOKE ALL ON FUNCTION public.get_business_actionable_insights(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_actionable_insights(uuid, date, date) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_actionable_insights(uuid, date, date) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
