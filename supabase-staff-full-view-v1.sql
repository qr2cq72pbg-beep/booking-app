-- =============================================================================
-- GT Termin — "Full Business View" for team members (read-only)
-- =============================================================================
-- Third visibility level next to 'own' and 'all': access_scope = 'full'.
-- A team member with 'full' (active, access on, signed in with their own
-- employee account) may READ the same business data as the owner: bookings,
-- customers, services, team, schedule, analytics and revenue reports.
--
-- Read-only by construction:
--   * only new SELECT policies are added (writes keep the owner-only policies);
--   * the analytics/CRM report functions are STABLE and never write; only their
--     owner check is widened to "owner OR full-view reader of this business";
--   * every write RPC keeps its owner check (unchanged).
-- Not opened: subscriptions/payments, push tokens, owner notifications, account,
-- platform admin data, manage-link tokens.
-- Revocation is immediate: every check reads staff_members live.
-- Existing team members keep their level (no data change). Only the owner
-- (RLS / set_staff_access_scope) or the platform admin can set 'full'.
-- Safe to re-run. Rollback at the end (commented out).
-- =============================================================================

BEGIN;

ALTER TABLE public.staff_members DROP CONSTRAINT IF EXISTS staff_members_access_scope_ok;
ALTER TABLE public.staff_members ADD CONSTRAINT staff_members_access_scope_ok
  CHECK (access_scope = ANY (ARRAY['own'::text, 'all'::text, 'full'::text]));

-- Business whose data the signed-in team member may read in full (NULL if none).
CREATE OR REPLACE FUNCTION public._full_view_business_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT sm.business_id
  FROM public.staff_members sm
  JOIN public.business_settings bs ON bs.business_id = sm.business_id
  WHERE auth.uid() IS NOT NULL
    AND sm.access_user_id = auth.uid()
    AND sm.access_enabled = true
    AND coalesce(sm.active, true) = true
    AND sm.access_scope = 'full'
  LIMIT 1;
$fn$;

-- RLS helper: is the caller a full-view team member of this business?
CREATE OR REPLACE FUNCTION public._is_full_view_reader(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- Never NULL: callers use "IF NOT …", where NULL would skip the refusal.
  SELECT coalesce(p_business_id IS NOT NULL AND p_business_id = public._full_view_business_id(), false);
$fn$;

-- Report functions: owner (as before) or full-view reader.
CREATE OR REPLACE FUNCTION public._can_read_business(p_business_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  -- Never NULL (see above).
  SELECT coalesce(auth.uid() IS NOT NULL AND p_business_id IS NOT NULL
     AND (auth.uid() = p_business_id OR public._is_full_view_reader(p_business_id)), false);
$fn$;

-- Owner's own business, or the business a full-view reader belongs to.
CREATE OR REPLACE FUNCTION public._readable_business_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT coalesce(
    (SELECT bs.business_id FROM public.business_settings bs WHERE bs.business_id = auth.uid()),
    public._full_view_business_id());
$fn$;

REVOKE ALL ON FUNCTION public._full_view_business_id() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._is_full_view_reader(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._can_read_business(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._readable_business_id() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._full_view_business_id() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._is_full_view_reader(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._can_read_business(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._readable_business_id() TO authenticated, service_role;

-- Read-only policies (SELECT only; existing owner policies are untouched).
DROP POLICY IF EXISTS business_settings_full_view_select ON public.business_settings;
CREATE POLICY business_settings_full_view_select ON public.business_settings FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS services_full_view_select ON public.services;
CREATE POLICY services_full_view_select ON public.services FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS staff_members_full_view_select ON public.staff_members;
CREATE POLICY staff_members_full_view_select ON public.staff_members FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS bookings_full_view_select ON public.bookings;
CREATE POLICY bookings_full_view_select ON public.bookings FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS business_customers_full_view_select ON public.business_customers;
CREATE POLICY business_customers_full_view_select ON public.business_customers FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS business_customer_counters_full_view_select ON public.business_customer_counters;
CREATE POLICY business_customer_counters_full_view_select ON public.business_customer_counters FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS blocked_days_full_view_select ON public.blocked_days;
CREATE POLICY blocked_days_full_view_select ON public.blocked_days FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS business_closed_days_full_view_select ON public.business_closed_days;
CREATE POLICY business_closed_days_full_view_select ON public.business_closed_days FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS staff_services_full_view_select ON public.staff_services;
CREATE POLICY staff_services_full_view_select ON public.staff_services FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS staff_working_hours_full_view_select ON public.staff_working_hours;
CREATE POLICY staff_working_hours_full_view_select ON public.staff_working_hours FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));
DROP POLICY IF EXISTS staff_time_off_full_view_select ON public.staff_time_off;
CREATE POLICY staff_time_off_full_view_select ON public.staff_time_off FOR SELECT TO authenticated
  USING (public._is_full_view_reader(business_id));

-- get_business_actionable_insights(uuid,date,date): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_actionable_insights(p_business_id uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
  IF NOT public._can_read_business(p_business_id) THEN
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
  FROM public._service_analytics_comparison_windows(
    p_from_date,
    p_to_date,
    v_today,
    nullif(current_setting('xbook.analytics_period_kind', true), '')
  ) w;

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
$fn$;

-- get_business_analytics_quality_records(uuid,date,date,text): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_analytics_quality_records(p_business_id uuid, p_from_date date, p_to_date date, p_quality_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_type text;
  v_timezone text;
  v_report_now timestamptz;
  v_from_text text;
  v_to_text text;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
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
$fn$;

-- get_business_analytics_trends(uuid,date,date,text): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_analytics_trends(p_business_id uuid, p_from_date date, p_to_date date, p_bucket text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz := now();
  v_bucket text;
  v_step interval;
  v_span integer;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
  IF p_business_id IS NULL OR p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'Invalid report period' USING ERRCODE = '22023';
  END IF;
  v_span := p_to_date - p_from_date + 1;
  IF v_span > 1100 THEN
    RAISE EXCEPTION 'Report period is too long' USING ERRCODE = '22023';
  END IF;

  SELECT nullif(trim(bs.timezone), '') INTO v_timezone
  FROM public.business_settings bs WHERE bs.business_id = p_business_id;
  IF v_timezone IS NULL THEN
    RAISE EXCEPTION 'Business timezone is not configured' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names tz WHERE tz.name = v_timezone) THEN
    RAISE EXCEPTION 'Invalid business timezone: %', v_timezone USING ERRCODE = '22023';
  END IF;

  v_bucket := lower(coalesce(nullif(trim(p_bucket), ''), 'auto'));
  IF v_bucket = 'auto' THEN
    v_bucket := CASE WHEN v_span <= 62 THEN 'day' WHEN v_span <= 200 THEN 'week' ELSE 'month' END;
  END IF;
  IF v_bucket NOT IN ('day', 'week', 'month') THEN
    RAISE EXCEPTION 'Invalid bucket' USING ERRCODE = '22023';
  END IF;
  v_step := CASE v_bucket WHEN 'day' THEN interval '1 day' WHEN 'week' THEN interval '1 week' ELSE interval '1 month' END;

  WITH src AS (
    SELECT
      b.booking_status,
      b.service_id,
      coalesce(nullif(trim(b.service_name), ''), s.name) AS service_name,
      b.staff_id,
      nullif(trim(b.staff_name), '') AS staff_name,
      b.duration_minutes,
      b.booking_price,
      s.price AS catalog_price,
      public._performance_appointment_start(b.date, b.time, v_timezone) AS appointment_start,
      public._resolve_business_analytics_customer_key(
        p_business_id,
        public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
      ) AS analytics_customer_key
    FROM public.bookings b
    LEFT JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
    WHERE b.business_id = p_business_id
  ),
  flagged AS (
    SELECT
      src.*,
      (src.appointment_start AT TIME ZONE v_timezone) AS local_start,
      (src.appointment_start AT TIME ZONE v_timezone)::date AS local_date,
      CASE
        WHEN src.booking_price IS NOT NULL AND src.booking_price >= 0 THEN src.booking_price
        WHEN src.catalog_price IS NOT NULL AND src.catalog_price >= 0 THEN src.catalog_price
        ELSE NULL
      END AS canonical_price,
      (
        src.booking_status = 'Confirmed'
        AND src.duration_minutes IS NOT NULL AND src.duration_minutes > 0
        AND src.appointment_start + make_interval(mins => src.duration_minutes) <= v_report_now
      ) AS is_completed_visit,
      (src.booking_status = 'Cancelled') AS is_cancelled,
      (src.booking_status IN ('Pending', 'Confirmed')) AS is_scheduled
    FROM src
    WHERE src.appointment_start IS NOT NULL
  ),
  in_period AS (
    SELECT * FROM flagged WHERE local_date >= p_from_date AND local_date <= p_to_date
  ),
  first_visit AS (
    SELECT analytics_customer_key, min(local_date) AS first_completed_date
    FROM flagged
    WHERE is_completed_visit AND analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  buckets AS (
    SELECT
      greatest(g::date, p_from_date) AS bucket_start,
      least((g + v_step)::date - 1, p_to_date) AS bucket_end
    FROM generate_series(date_trunc(v_bucket, p_from_date::timestamp), p_to_date::timestamp, v_step) AS g
  ),
  series AS (
    SELECT
      bk.bucket_start,
      bk.bucket_end,
      count(ip.*) FILTER (WHERE ip.is_completed_visit) AS completed_visits,
      coalesce(sum(ip.canonical_price) FILTER (WHERE ip.is_completed_visit AND ip.canonical_price IS NOT NULL), 0) AS completed_value,
      count(ip.*) FILTER (WHERE ip.is_cancelled) AS cancelled,
      count(ip.*) FILTER (WHERE ip.is_scheduled) AS scheduled,
      (
        SELECT count(*) FROM first_visit fv
        WHERE fv.first_completed_date >= bk.bucket_start AND fv.first_completed_date <= bk.bucket_end
      ) AS new_customers
    FROM buckets bk
    LEFT JOIN in_period ip ON ip.local_date >= bk.bucket_start AND ip.local_date <= bk.bucket_end
    GROUP BY bk.bucket_start, bk.bucket_end
  ),
  busy AS (
    SELECT extract(isodow FROM local_start)::int AS dow, extract(hour FROM local_start)::int AS hour, count(*) AS bookings
    FROM in_period
    WHERE is_scheduled
    GROUP BY 1, 2
  ),
  split AS (
    SELECT
      coalesce(service_id::text, 'name:' || lower(coalesce(service_name, ''))) AS service_key,
      max(service_name) AS service_name,
      staff_id,
      max(staff_name) AS staff_name,
      count(*) AS completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE canonical_price IS NOT NULL), 0) AS completed_value
    FROM in_period
    WHERE is_completed_visit
    GROUP BY 1, staff_id
  )
  SELECT jsonb_build_object(
    'ok', true,
    'business_id', p_business_id,
    'timezone', v_timezone,
    'from_date', p_from_date,
    'to_date', p_to_date,
    'report_now', v_report_now,
    'bucket', v_bucket,
    'series', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'bucket_start', s.bucket_start, 'bucket_end', s.bucket_end,
        'completed_visits', s.completed_visits, 'completed_value', s.completed_value,
        'cancelled', s.cancelled, 'scheduled', s.scheduled, 'new_customers', s.new_customers
      ) ORDER BY s.bucket_start) FROM series s), '[]'::jsonb),
    'totals', (
      SELECT jsonb_build_object(
        'completed_visits', coalesce(sum(s.completed_visits), 0),
        'completed_value', coalesce(sum(s.completed_value), 0),
        'cancelled', coalesce(sum(s.cancelled), 0),
        'scheduled', coalesce(sum(s.scheduled), 0),
        'new_customers', coalesce(sum(s.new_customers), 0)
      ) FROM series s),
    'busy_times', coalesce((
      SELECT jsonb_agg(jsonb_build_object('dow', b.dow, 'hour', b.hour, 'bookings', b.bookings) ORDER BY b.dow, b.hour)
      FROM busy b), '[]'::jsonb),
    'service_staff', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'service_key', sp.service_key, 'service_name', sp.service_name,
        'staff_id', sp.staff_id, 'staff_name', sp.staff_name,
        'completed_visits', sp.completed_visits, 'completed_value', sp.completed_value
      ) ORDER BY sp.service_key, sp.completed_visits DESC) FROM split sp), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;

-- get_business_cross_analytics(uuid,date,date,jsonb,text,integer,integer): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_cross_analytics(p_business_id uuid, p_from_date date, p_to_date date, p_filters jsonb DEFAULT '{}'::jsonb, p_sort text DEFAULT 'last_visit_desc'::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_filters jsonb;
  v_key text;
  v_sort text;
  v_limit integer;
  v_offset integer;
  v_elem text;
  v_elem_json jsonb;
  v_uuid uuid;
  v_num numeric;
  v_text text;
  v_uuid_re text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';

  v_gender text[];
  v_age_buckets text[];
  v_city_ids uuid[];
  v_city_unknown boolean;
  v_city_unknown_set boolean := false;
  v_is_vip boolean;
  v_is_vip_set boolean := false;
  v_customer_type text;
  v_visit_frequency text;
  v_inactive_days_min integer;
  v_inactive_days_max integer;
  v_has_future_booking boolean;
  v_has_future_set boolean := false;
  v_service_ids uuid[] := '{}'::uuid[];
  v_service_ids_none uuid[] := '{}'::uuid[];
  v_service_match text;
  v_service_scope text;
  v_staff_ids_raw text[] := '{}'::text[];
  v_staff_uuids uuid[] := '{}'::uuid[];
  v_staff_unassigned boolean := false;
  v_staff_match text;
  v_staff_scope text;
  v_lifetime_visits_min integer;
  v_lifetime_visits_max integer;
  v_period_visits_min integer;
  v_period_visits_max integer;
  v_lifetime_revenue_min numeric;
  v_lifetime_revenue_max numeric;
  v_period_revenue_min numeric;
  v_period_revenue_max numeric;

  v_has_service_any boolean := false;
  v_has_service_none boolean := false;
  v_service_use_period boolean := false;
  v_has_staff_any boolean := false;
  v_staff_use_period boolean := false;

  v_applied jsonb := '{}'::jsonb;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL OR p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'Invalid report period'
      USING ERRCODE = '22023';
  END IF;

  v_limit := coalesce(p_limit, 50);
  v_offset := coalesce(p_offset, 0);
  IF v_limit < 1 OR v_limit > 100 OR v_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination'
      USING ERRCODE = '22023';
  END IF;

  v_sort := lower(trim(coalesce(p_sort, 'last_visit_desc')));
  IF v_sort NOT IN (
    'last_visit_desc',
    'last_visit_asc',
    'lifetime_revenue_desc',
    'period_revenue_desc',
    'lifetime_visits_desc',
    'name_asc',
    'next_booking_asc'
  ) THEN
    RAISE EXCEPTION 'Invalid sort'
      USING ERRCODE = '22023';
  END IF;

  IF p_filters IS NULL THEN
    v_filters := '{}'::jsonb;
  ELSE
    v_filters := p_filters;
  END IF;

  IF jsonb_typeof(v_filters) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Invalid filters'
      USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(v_filters)
  LOOP
    IF v_key NOT IN (
      'gender',
      'age_buckets',
      'city_ids',
      'city_unknown',
      'is_vip',
      'customer_type',
      'visit_frequency',
      'inactive_days_min',
      'inactive_days_max',
      'has_future_booking',
      'service_ids',
      'service_match',
      'service_scope',
      'service_ids_none',
      'staff_ids',
      'staff_match',
      'staff_scope',
      'lifetime_visits_min',
      'lifetime_visits_max',
      'period_visits_min',
      'period_visits_max',
      'lifetime_revenue_min',
      'lifetime_revenue_max',
      'period_revenue_min',
      'period_revenue_max'
    ) THEN
      RAISE EXCEPTION 'Unknown filter key: %', v_key
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- gender
  IF v_filters ? 'gender' THEN
    IF jsonb_typeof(v_filters->'gender') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid gender filter'
        USING ERRCODE = '22023';
    END IF;
    v_gender := '{}'::text[];
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'gender')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid gender filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := v_elem_json #>> '{}';
      IF v_elem NOT IN ('male', 'female', 'unknown') THEN
        RAISE EXCEPTION 'Invalid gender filter'
          USING ERRCODE = '22023';
      END IF;
      v_gender := array_append(v_gender, v_elem);
    END LOOP;
    IF cardinality(v_gender) = 0 THEN
      v_gender := NULL;
    END IF;
  END IF;

  -- age_buckets
  IF v_filters ? 'age_buckets' THEN
    IF jsonb_typeof(v_filters->'age_buckets') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid age_buckets filter'
        USING ERRCODE = '22023';
    END IF;
    v_age_buckets := '{}'::text[];
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'age_buckets')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid age_buckets filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := v_elem_json #>> '{}';
      IF v_elem NOT IN (
        'under_18', '18_24', '25_34', '35_44', '45_54', '55_64', '65_plus', 'unknown'
      ) THEN
        RAISE EXCEPTION 'Invalid age_buckets filter'
          USING ERRCODE = '22023';
      END IF;
      v_age_buckets := array_append(v_age_buckets, v_elem);
    END LOOP;
    IF cardinality(v_age_buckets) = 0 THEN
      v_age_buckets := NULL;
    END IF;
  END IF;

  -- city_ids
  IF v_filters ? 'city_ids' THEN
    IF jsonb_typeof(v_filters->'city_ids') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid city_ids filter'
        USING ERRCODE = '22023';
    END IF;
    v_city_ids := '{}'::uuid[];
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'city_ids')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid city_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := lower(v_elem_json #>> '{}');
      IF v_elem !~ v_uuid_re THEN
        RAISE EXCEPTION 'Invalid city_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_city_ids := array_append(v_city_ids, v_elem::uuid);
    END LOOP;
    IF cardinality(v_city_ids) = 0 THEN
      v_city_ids := NULL;
    END IF;
  END IF;

  IF v_filters ? 'city_unknown' THEN
    IF jsonb_typeof(v_filters->'city_unknown') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'Invalid city_unknown filter'
        USING ERRCODE = '22023';
    END IF;
    v_city_unknown := (v_filters->>'city_unknown')::boolean;
    v_city_unknown_set := true;
  END IF;

  IF v_filters ? 'is_vip' THEN
    IF jsonb_typeof(v_filters->'is_vip') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'Invalid is_vip filter'
        USING ERRCODE = '22023';
    END IF;
    v_is_vip := (v_filters->>'is_vip')::boolean;
    v_is_vip_set := true;
  END IF;

  IF v_filters ? 'customer_type' THEN
    IF jsonb_typeof(v_filters->'customer_type') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid customer_type filter'
        USING ERRCODE = '22023';
    END IF;
    v_customer_type := v_filters->>'customer_type';
    IF v_customer_type NOT IN ('new', 'returning') THEN
      RAISE EXCEPTION 'Invalid customer_type filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'visit_frequency' THEN
    IF jsonb_typeof(v_filters->'visit_frequency') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid visit_frequency filter'
        USING ERRCODE = '22023';
    END IF;
    v_visit_frequency := v_filters->>'visit_frequency';
    IF v_visit_frequency NOT IN ('repeat', 'single') THEN
      RAISE EXCEPTION 'Invalid visit_frequency filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'inactive_days_min' THEN
    IF jsonb_typeof(v_filters->'inactive_days_min') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid inactive_days_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'inactive_days_min')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid inactive_days_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_inactive_days_min := v_num::integer;
  END IF;

  IF v_filters ? 'inactive_days_max' THEN
    IF jsonb_typeof(v_filters->'inactive_days_max') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid inactive_days_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'inactive_days_max')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid inactive_days_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_inactive_days_max := v_num::integer;
  END IF;

  IF v_inactive_days_min IS NOT NULL AND v_inactive_days_max IS NOT NULL
     AND v_inactive_days_min > v_inactive_days_max THEN
    RAISE EXCEPTION 'Invalid inactivity range'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'has_future_booking' THEN
    IF jsonb_typeof(v_filters->'has_future_booking') IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'Invalid has_future_booking filter'
        USING ERRCODE = '22023';
    END IF;
    v_has_future_booking := (v_filters->>'has_future_booking')::boolean;
    v_has_future_set := true;
  END IF;

  IF v_filters ? 'service_match' THEN
    IF jsonb_typeof(v_filters->'service_match') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid service_match filter'
        USING ERRCODE = '22023';
    END IF;
    v_service_match := v_filters->>'service_match';
    IF v_service_match NOT IN ('any', 'none') THEN
      RAISE EXCEPTION 'Invalid service_match filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'service_scope' THEN
    IF jsonb_typeof(v_filters->'service_scope') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid service_scope filter'
        USING ERRCODE = '22023';
    END IF;
    v_service_scope := v_filters->>'service_scope';
    IF v_service_scope NOT IN ('lifetime', 'period') THEN
      RAISE EXCEPTION 'Invalid service_scope filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'service_ids' THEN
    IF jsonb_typeof(v_filters->'service_ids') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid service_ids filter'
        USING ERRCODE = '22023';
    END IF;
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'service_ids')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid service_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := lower(v_elem_json #>> '{}');
      IF v_elem !~ v_uuid_re THEN
        RAISE EXCEPTION 'Invalid service_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_uuid := v_elem::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.services s
        WHERE s.id = v_uuid AND s.business_id = p_business_id
      ) THEN
        RAISE EXCEPTION 'Invalid service_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_service_ids := array_append(v_service_ids, v_uuid);
    END LOOP;
  END IF;

  IF v_filters ? 'service_ids_none' THEN
    IF jsonb_typeof(v_filters->'service_ids_none') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid service_ids_none filter'
        USING ERRCODE = '22023';
    END IF;
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'service_ids_none')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid service_ids_none filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := lower(v_elem_json #>> '{}');
      IF v_elem !~ v_uuid_re THEN
        RAISE EXCEPTION 'Invalid service_ids_none filter'
          USING ERRCODE = '22023';
      END IF;
      v_uuid := v_elem::uuid;
      IF NOT EXISTS (
        SELECT 1 FROM public.services s
        WHERE s.id = v_uuid AND s.business_id = p_business_id
      ) THEN
        RAISE EXCEPTION 'Invalid service_ids_none filter'
          USING ERRCODE = '22023';
      END IF;
      v_service_ids_none := array_append(v_service_ids_none, v_uuid);
    END LOOP;
  END IF;

  -- Normalize service_match='none' into service_ids_none.
  IF coalesce(v_service_match, 'any') = 'none' THEN
    IF cardinality(v_service_ids) = 0 THEN
      RAISE EXCEPTION 'Invalid service_match filter'
        USING ERRCODE = '22023';
    END IF;
    IF cardinality(v_service_ids_none) > 0 THEN
      -- Dual none-input is allowed only when the two lists are the same set.
      IF EXISTS (
        SELECT 1 FROM unnest(v_service_ids) x WHERE NOT (x = ANY (v_service_ids_none))
      ) OR EXISTS (
        SELECT 1 FROM unnest(v_service_ids_none) y WHERE NOT (y = ANY (v_service_ids))
      ) THEN
        RAISE EXCEPTION 'Contradictory service filters'
          USING ERRCODE = '22023';
      END IF;
      v_service_ids := '{}'::uuid[];
    ELSE
      v_service_ids_none := v_service_ids;
      v_service_ids := '{}'::uuid[];
    END IF;
    v_service_match := NULL;
  END IF;

  IF cardinality(v_service_ids) > 0 AND cardinality(v_service_ids_none) > 0
     AND v_service_ids && v_service_ids_none THEN
    RAISE EXCEPTION 'Contradictory service filters'
      USING ERRCODE = '22023';
  END IF;

  IF cardinality(v_service_ids) > 0 THEN
    v_has_service_any := true;
    v_service_match := 'any';
  END IF;
  IF cardinality(v_service_ids_none) > 0 THEN
    v_has_service_none := true;
  END IF;
  IF v_has_service_any OR v_has_service_none THEN
    v_service_scope := coalesce(v_service_scope, 'lifetime');
    v_service_use_period := (v_service_scope = 'period');
  ELSIF v_service_scope IS NOT NULL OR v_service_match IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid service filter'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'staff_match' THEN
    IF jsonb_typeof(v_filters->'staff_match') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid staff_match filter'
        USING ERRCODE = '22023';
    END IF;
    v_staff_match := v_filters->>'staff_match';
    IF v_staff_match IS DISTINCT FROM 'any' THEN
      RAISE EXCEPTION 'Invalid staff_match filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'staff_scope' THEN
    IF jsonb_typeof(v_filters->'staff_scope') IS DISTINCT FROM 'string' THEN
      RAISE EXCEPTION 'Invalid staff_scope filter'
        USING ERRCODE = '22023';
    END IF;
    v_staff_scope := v_filters->>'staff_scope';
    IF v_staff_scope NOT IN ('lifetime', 'period') THEN
      RAISE EXCEPTION 'Invalid staff_scope filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_filters ? 'staff_ids' THEN
    IF jsonb_typeof(v_filters->'staff_ids') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'Invalid staff_ids filter'
        USING ERRCODE = '22023';
    END IF;
    FOR v_elem_json IN SELECT jsonb_array_elements(v_filters->'staff_ids')
    LOOP
      IF jsonb_typeof(v_elem_json) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'Invalid staff_ids filter'
          USING ERRCODE = '22023';
      END IF;
      v_elem := v_elem_json #>> '{}';
      IF v_elem = 'unassigned' THEN
        v_staff_unassigned := true;
        v_staff_ids_raw := array_append(v_staff_ids_raw, 'unassigned');
      ELSE
        v_text := lower(v_elem);
        IF v_text !~ v_uuid_re THEN
          RAISE EXCEPTION 'Invalid staff_ids filter'
            USING ERRCODE = '22023';
        END IF;
        v_uuid := v_text::uuid;
        IF NOT EXISTS (
          SELECT 1 FROM public.staff_members sm
          WHERE sm.id = v_uuid AND sm.business_id = p_business_id
        ) THEN
          RAISE EXCEPTION 'Invalid staff_ids filter'
            USING ERRCODE = '22023';
        END IF;
        v_staff_uuids := array_append(v_staff_uuids, v_uuid);
        v_staff_ids_raw := array_append(v_staff_ids_raw, v_uuid::text);
      END IF;
    END LOOP;
  END IF;

  IF cardinality(v_staff_uuids) > 0 OR v_staff_unassigned THEN
    v_has_staff_any := true;
    v_staff_match := 'any';
    v_staff_scope := coalesce(v_staff_scope, 'lifetime');
    v_staff_use_period := (v_staff_scope = 'period');
  ELSIF v_staff_scope IS NOT NULL OR v_staff_match IS NOT NULL THEN
    RAISE EXCEPTION 'Invalid staff filter'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'lifetime_visits_min' THEN
    IF jsonb_typeof(v_filters->'lifetime_visits_min') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid lifetime_visits_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'lifetime_visits_min')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid lifetime_visits_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_lifetime_visits_min := v_num::integer;
  END IF;
  IF v_filters ? 'lifetime_visits_max' THEN
    IF jsonb_typeof(v_filters->'lifetime_visits_max') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid lifetime_visits_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'lifetime_visits_max')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid lifetime_visits_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_lifetime_visits_max := v_num::integer;
  END IF;
  IF v_lifetime_visits_min IS NOT NULL AND v_lifetime_visits_max IS NOT NULL
     AND v_lifetime_visits_min > v_lifetime_visits_max THEN
    RAISE EXCEPTION 'Invalid lifetime visits range'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'period_visits_min' THEN
    IF jsonb_typeof(v_filters->'period_visits_min') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid period_visits_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'period_visits_min')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid period_visits_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_period_visits_min := v_num::integer;
  END IF;
  IF v_filters ? 'period_visits_max' THEN
    IF jsonb_typeof(v_filters->'period_visits_max') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid period_visits_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_num := (v_filters->>'period_visits_max')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'Invalid period_visits_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_period_visits_max := v_num::integer;
  END IF;
  IF v_period_visits_min IS NOT NULL AND v_period_visits_max IS NOT NULL
     AND v_period_visits_min > v_period_visits_max THEN
    RAISE EXCEPTION 'Invalid period visits range'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'lifetime_revenue_min' THEN
    IF jsonb_typeof(v_filters->'lifetime_revenue_min') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid lifetime_revenue_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_lifetime_revenue_min := (v_filters->>'lifetime_revenue_min')::numeric;
    IF v_lifetime_revenue_min < 0 THEN
      RAISE EXCEPTION 'Invalid lifetime_revenue_min filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_filters ? 'lifetime_revenue_max' THEN
    IF jsonb_typeof(v_filters->'lifetime_revenue_max') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid lifetime_revenue_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_lifetime_revenue_max := (v_filters->>'lifetime_revenue_max')::numeric;
    IF v_lifetime_revenue_max < 0 THEN
      RAISE EXCEPTION 'Invalid lifetime_revenue_max filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_lifetime_revenue_min IS NOT NULL AND v_lifetime_revenue_max IS NOT NULL
     AND v_lifetime_revenue_min > v_lifetime_revenue_max THEN
    RAISE EXCEPTION 'Invalid lifetime revenue range'
      USING ERRCODE = '22023';
  END IF;

  IF v_filters ? 'period_revenue_min' THEN
    IF jsonb_typeof(v_filters->'period_revenue_min') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid period_revenue_min filter'
        USING ERRCODE = '22023';
    END IF;
    v_period_revenue_min := (v_filters->>'period_revenue_min')::numeric;
    IF v_period_revenue_min < 0 THEN
      RAISE EXCEPTION 'Invalid period_revenue_min filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_filters ? 'period_revenue_max' THEN
    IF jsonb_typeof(v_filters->'period_revenue_max') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Invalid period_revenue_max filter'
        USING ERRCODE = '22023';
    END IF;
    v_period_revenue_max := (v_filters->>'period_revenue_max')::numeric;
    IF v_period_revenue_max < 0 THEN
      RAISE EXCEPTION 'Invalid period_revenue_max filter'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_period_revenue_min IS NOT NULL AND v_period_revenue_max IS NOT NULL
     AND v_period_revenue_min > v_period_revenue_max THEN
    RAISE EXCEPTION 'Invalid period revenue range'
      USING ERRCODE = '22023';
  END IF;

  -- Applied filters (normalized)
  IF v_gender IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('gender', to_jsonb(v_gender));
  END IF;
  IF v_age_buckets IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('age_buckets', to_jsonb(v_age_buckets));
  END IF;
  IF v_city_ids IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('city_ids', to_jsonb(v_city_ids));
  END IF;
  IF coalesce(v_city_unknown, false) THEN
    v_applied := v_applied || jsonb_build_object('city_unknown', true);
  ELSIF v_city_unknown_set AND v_city_ids IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('city_unknown', false);
  END IF;
  IF v_is_vip_set THEN
    v_applied := v_applied || jsonb_build_object('is_vip', v_is_vip);
  END IF;
  IF v_customer_type IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('customer_type', v_customer_type);
  END IF;
  IF v_visit_frequency IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('visit_frequency', v_visit_frequency);
  END IF;
  IF v_inactive_days_min IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('inactive_days_min', v_inactive_days_min);
  END IF;
  IF v_inactive_days_max IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('inactive_days_max', v_inactive_days_max);
  END IF;
  IF v_has_future_set THEN
    v_applied := v_applied || jsonb_build_object('has_future_booking', v_has_future_booking);
  END IF;
  IF v_has_service_any THEN
    v_applied := v_applied || jsonb_build_object(
      'service_ids', to_jsonb(v_service_ids),
      'service_match', 'any'
    );
  END IF;
  IF v_has_service_none THEN
    v_applied := v_applied || jsonb_build_object('service_ids_none', to_jsonb(v_service_ids_none));
  END IF;
  IF v_has_service_any OR v_has_service_none THEN
    v_applied := v_applied || jsonb_build_object('service_scope', v_service_scope);
  END IF;
  IF v_has_staff_any THEN
    v_applied := v_applied || jsonb_build_object(
      'staff_ids', to_jsonb(v_staff_ids_raw),
      'staff_match', 'any',
      'staff_scope', v_staff_scope
    );
  END IF;
  IF v_lifetime_visits_min IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('lifetime_visits_min', v_lifetime_visits_min);
  END IF;
  IF v_lifetime_visits_max IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('lifetime_visits_max', v_lifetime_visits_max);
  END IF;
  IF v_period_visits_min IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('period_visits_min', v_period_visits_min);
  END IF;
  IF v_period_visits_max IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('period_visits_max', v_period_visits_max);
  END IF;
  IF v_lifetime_revenue_min IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('lifetime_revenue_min', v_lifetime_revenue_min);
  END IF;
  IF v_lifetime_revenue_max IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('lifetime_revenue_max', v_lifetime_revenue_max);
  END IF;
  IF v_period_revenue_min IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('period_revenue_min', v_period_revenue_min);
  END IF;
  IF v_period_revenue_max IS NOT NULL THEN
    v_applied := v_applied || jsonb_build_object('period_revenue_max', v_period_revenue_max);
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

  WITH pop AS (
    SELECT *
    FROM public._business_analytics_customer_keys(p_business_id)
  ),
  src AS (
    SELECT
      b.id,
      b.booking_status,
      b.customer_user_id,
      b.customer_name,
      b.customer_phone,
      b.customer_email,
      b.duration_minutes,
      b.booking_price,
      b.service_id,
      b.service_name,
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
      END AS canonical_price
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start IS NOT NULL
        AND appointment_start > v_report_now
      ) AS is_upcoming
    FROM classified
  ),
  period_flagged AS (
    SELECT
      flagged.*,
      (
        is_completed_visit
        AND appointment_local_date >= p_from_date
        AND appointment_local_date <= p_to_date
      ) AS is_period_completed
    FROM flagged
  ),
  quality_source AS (
    SELECT
      count(*) FILTER (WHERE analytics_customer_key IS NULL)::bigint AS unidentified_booking_count,
      count(*) FILTER (WHERE appointment_start IS NULL)::bigint AS invalid_appointment_time_count,
      count(*) FILTER (
        WHERE appointment_start IS NOT NULL
          AND (duration_minutes IS NULL OR duration_minutes <= 0)
      )::bigint AS unknown_duration_count
    FROM period_flagged
  ),
  customer_stats AS (
    SELECT
      analytics_customer_key,
      min(appointment_local_date) FILTER (WHERE is_completed_visit) AS first_completed_date,
      min(appointment_start) FILTER (WHERE is_completed_visit) AS first_completed_visit_at,
      max(appointment_start) FILTER (WHERE is_completed_visit) AS last_completed_visit_at,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS lifetime_completed,
      count(*) FILTER (WHERE is_period_completed)::bigint AS period_completed,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)::bigint AS priced_lifetime,
      count(*) FILTER (WHERE is_period_completed AND canonical_price IS NOT NULL)::bigint AS priced_period,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_lifetime_sum,
      coalesce(sum(canonical_price) FILTER (WHERE is_period_completed AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_period_sum,
      coalesce(bool_or(is_completed_visit AND price_source = 'estimated'), false) AS revenue_is_estimated,
      count(*) FILTER (WHERE is_completed_visit AND price_source = 'snapshot')::bigint AS snapshot_completed,
      count(*) FILTER (WHERE is_completed_visit AND price_source = 'estimated')::bigint AS estimated_completed,
      count(*) FILTER (WHERE is_completed_visit AND price_source = 'unknown')::bigint AS unknown_price_completed,
      bool_or(is_upcoming) AS has_upcoming,
      coalesce(
        array_agg(DISTINCT service_id) FILTER (WHERE is_completed_visit AND service_id IS NOT NULL),
        '{}'::uuid[]
      ) AS lifetime_service_ids,
      coalesce(
        array_agg(DISTINCT service_id) FILTER (WHERE is_period_completed AND service_id IS NOT NULL),
        '{}'::uuid[]
      ) AS period_service_ids,
      coalesce(
        array_agg(DISTINCT staff_id) FILTER (WHERE is_completed_visit AND staff_id IS NOT NULL),
        '{}'::uuid[]
      ) AS lifetime_staff_ids,
      coalesce(
        array_agg(DISTINCT staff_id) FILTER (WHERE is_period_completed AND staff_id IS NOT NULL),
        '{}'::uuid[]
      ) AS period_staff_ids,
      coalesce(bool_or(is_completed_visit AND staff_id IS NULL), false) AS has_unassigned_lifetime,
      coalesce(bool_or(is_period_completed AND staff_id IS NULL), false) AS has_unassigned_period,
      nullif(trim((ARRAY_AGG(customer_name ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_name), '') IS NOT NULL
          AND lower(trim(customer_name)) <> 'customer'
      ))[1]), '') AS booking_display_name,
      nullif(trim((ARRAY_AGG(customer_phone ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_phone), '') IS NOT NULL
      ))[1]), '') AS booking_phone,
      nullif(trim((ARRAY_AGG(customer_email ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_email), '') IS NOT NULL
      ))[1]), '') AS booking_email
    FROM period_flagged
    WHERE analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  next_appt AS (
    SELECT DISTINCT ON (analytics_customer_key)
      analytics_customer_key,
      appointment_start AS next_appointment_at,
      coalesce(
        nullif(trim(catalog_service_name), ''),
        nullif(trim(service_name), '')
      ) AS next_service_name
    FROM period_flagged
    WHERE analytics_customer_key IS NOT NULL
      AND is_upcoming
    ORDER BY analytics_customer_key, appointment_start ASC, id ASC
  ),
  crm AS (
    SELECT DISTINCT ON (map_key)
      map_key,
      bc.customer_number,
      bc.display_name,
      bc.phone,
      bc.email,
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
  enriched AS (
    SELECT
      p.analytics_customer_key,
      p.identity_type,
      coalesce(cs.lifetime_completed, 0)::bigint AS lifetime_completed,
      coalesce(cs.period_completed, 0)::bigint AS period_completed,
      coalesce(cs.priced_lifetime, 0)::bigint AS priced_lifetime,
      coalesce(cs.priced_period, 0)::bigint AS priced_period,
      cs.first_completed_date,
      cs.first_completed_visit_at,
      cs.last_completed_visit_at,
      CASE
        WHEN coalesce(cs.lifetime_completed, 0) = 0 THEN 0::numeric
        WHEN coalesce(cs.priced_lifetime, 0) > 0 THEN cs.completed_revenue_lifetime_sum
        ELSE NULL
      END AS completed_revenue_lifetime,
      CASE
        WHEN coalesce(cs.period_completed, 0) = 0 THEN 0::numeric
        WHEN coalesce(cs.priced_period, 0) > 0 THEN cs.completed_revenue_period_sum
        ELSE NULL
      END AS completed_revenue_period,
      coalesce(cs.revenue_is_estimated, false) AS revenue_is_estimated,
      coalesce(cs.snapshot_completed, 0)::bigint AS snapshot_completed,
      coalesce(cs.estimated_completed, 0)::bigint AS estimated_completed,
      coalesce(cs.unknown_price_completed, 0)::bigint AS unknown_price_completed,
      coalesce(cs.has_upcoming, false) AS has_upcoming,
      CASE
        WHEN cs.last_completed_visit_at IS NULL THEN NULL
        ELSE v_report_now - cs.last_completed_visit_at
      END AS inactive_for,
      CASE
        WHEN cs.last_completed_visit_at IS NULL THEN NULL
        ELSE floor(extract(epoch FROM (v_report_now - cs.last_completed_visit_at)) / 86400)::int
      END AS days_since_last_visit,
      coalesce(cs.lifetime_service_ids, '{}'::uuid[]) AS lifetime_service_ids,
      coalesce(cs.period_service_ids, '{}'::uuid[]) AS period_service_ids,
      coalesce(cs.lifetime_staff_ids, '{}'::uuid[]) AS lifetime_staff_ids,
      coalesce(cs.period_staff_ids, '{}'::uuid[]) AS period_staff_ids,
      coalesce(cs.has_unassigned_lifetime, false) AS has_unassigned_lifetime,
      coalesce(cs.has_unassigned_period, false) AS has_unassigned_period,
      crm.customer_number,
      coalesce(crm.is_vip, false) AS is_vip,
      coalesce(nullif(trim(crm.display_name), ''), cs.booking_display_name) AS display_name,
      coalesce(nullif(trim(crm.phone), ''), cs.booking_phone) AS phone,
      coalesce(nullif(trim(crm.email), ''), cs.booking_email) AS email,
      na.next_appointment_at,
      na.next_service_name,
      CASE
        WHEN p.analytics_customer_key LIKE 'u:%' THEN substr(p.analytics_customer_key, 3)::uuid
        ELSE NULL
      END AS profile_user_id,
      (
        coalesce(cs.period_completed, 0) > 0
        AND cs.first_completed_date >= p_from_date
        AND cs.first_completed_date <= p_to_date
      ) AS is_new,
      (
        coalesce(cs.period_completed, 0) > 0
        AND cs.first_completed_date IS NOT NULL
        AND cs.first_completed_date < p_from_date
      ) AS is_returning
    FROM pop p
    LEFT JOIN customer_stats cs
      ON cs.analytics_customer_key = p.analytics_customer_key
    LEFT JOIN crm
      ON crm.map_key = p.analytics_customer_key
    LEFT JOIN next_appt na
      ON na.analytics_customer_key = p.analytics_customer_key
  ),
  demo AS (
    SELECT
      e.analytics_customer_key,
      CASE
        WHEN pp.gender IN ('male', 'female') THEN pp.gender
        ELSE 'unknown'
      END AS gender,
      CASE
        WHEN pp.date_of_birth IS NULL OR pp.date_of_birth > p_to_date THEN NULL
        ELSE (EXTRACT(YEAR FROM age(p_to_date, pp.date_of_birth)))::int
      END AS age_years,
      pp.city_id,
      ci.name_en AS city_name,
      pp.country_code
    FROM enriched e
    LEFT JOIN public.customer_private_profiles pp
      ON pp.user_id = e.profile_user_id
    LEFT JOIN public.cities ci
      ON ci.id = pp.city_id
  ),
  full_row AS (
    SELECT
      e.*,
      d.gender,
      CASE
        WHEN d.age_years IS NULL THEN 'unknown'
        WHEN d.age_years < 18 THEN 'under_18'
        WHEN d.age_years BETWEEN 18 AND 24 THEN '18_24'
        WHEN d.age_years BETWEEN 25 AND 34 THEN '25_34'
        WHEN d.age_years BETWEEN 35 AND 44 THEN '35_44'
        WHEN d.age_years BETWEEN 45 AND 54 THEN '45_54'
        WHEN d.age_years BETWEEN 55 AND 64 THEN '55_64'
        ELSE '65_plus'
      END AS age_bucket,
      d.city_id,
      d.city_name,
      d.country_code
    FROM enriched e
    LEFT JOIN demo d
      ON d.analytics_customer_key = e.analytics_customer_key
  ),
  filtered AS (
    SELECT *
    FROM full_row r
    WHERE (v_gender IS NULL OR r.gender = ANY (v_gender))
      AND (v_age_buckets IS NULL OR r.age_bucket = ANY (v_age_buckets))
      AND (
        (v_city_ids IS NULL AND NOT coalesce(v_city_unknown, false))
        OR (
          (v_city_ids IS NOT NULL AND r.city_id = ANY (v_city_ids))
          OR (coalesce(v_city_unknown, false) AND r.city_id IS NULL)
        )
      )
      AND (NOT v_is_vip_set OR r.is_vip = v_is_vip)
      AND (
        v_customer_type IS NULL
        OR (v_customer_type = 'new' AND r.is_new)
        OR (v_customer_type = 'returning' AND r.is_returning)
      )
      AND (
        v_visit_frequency IS NULL
        OR (v_visit_frequency = 'repeat' AND r.lifetime_completed >= 2)
        OR (v_visit_frequency = 'single' AND r.lifetime_completed = 1)
      )
      AND (
        v_inactive_days_min IS NULL AND v_inactive_days_max IS NULL
        OR (
          r.lifetime_completed > 0
          AND r.inactive_for IS NOT NULL
          AND (
            v_inactive_days_min IS NULL
            OR r.inactive_for > make_interval(days => v_inactive_days_min)
          )
          AND (
            v_inactive_days_max IS NULL
            OR r.inactive_for <= make_interval(days => v_inactive_days_max)
          )
        )
      )
      AND (NOT v_has_future_set OR r.has_upcoming = v_has_future_booking)
      AND (v_lifetime_visits_min IS NULL OR r.lifetime_completed >= v_lifetime_visits_min)
      AND (v_lifetime_visits_max IS NULL OR r.lifetime_completed <= v_lifetime_visits_max)
      AND (v_period_visits_min IS NULL OR r.period_completed >= v_period_visits_min)
      AND (v_period_visits_max IS NULL OR r.period_completed <= v_period_visits_max)
      AND (
        v_lifetime_revenue_min IS NULL AND v_lifetime_revenue_max IS NULL
        OR (
          r.completed_revenue_lifetime IS NOT NULL
          AND (v_lifetime_revenue_min IS NULL OR r.completed_revenue_lifetime >= v_lifetime_revenue_min)
          AND (v_lifetime_revenue_max IS NULL OR r.completed_revenue_lifetime <= v_lifetime_revenue_max)
        )
      )
      AND (
        v_period_revenue_min IS NULL AND v_period_revenue_max IS NULL
        OR (
          r.completed_revenue_period IS NOT NULL
          AND (v_period_revenue_min IS NULL OR r.completed_revenue_period >= v_period_revenue_min)
          AND (v_period_revenue_max IS NULL OR r.completed_revenue_period <= v_period_revenue_max)
        )
      )
      AND (
        NOT v_has_service_any
        OR CASE
          WHEN v_service_use_period THEN r.period_service_ids && v_service_ids
          ELSE r.lifetime_service_ids && v_service_ids
        END
      )
      AND (
        NOT v_has_service_none
        OR NOT CASE
          WHEN v_service_use_period THEN r.period_service_ids && v_service_ids_none
          ELSE r.lifetime_service_ids && v_service_ids_none
        END
      )
      AND (
        NOT v_has_staff_any
        OR (
          (
            cardinality(v_staff_uuids) > 0
            AND CASE
              WHEN v_staff_use_period THEN r.period_staff_ids && v_staff_uuids
              ELSE r.lifetime_staff_ids && v_staff_uuids
            END
          )
          OR (
            v_staff_unassigned
            AND CASE
              WHEN v_staff_use_period THEN r.has_unassigned_period
              ELSE r.has_unassigned_lifetime
            END
          )
        )
      )
  ),
  summary AS (
    SELECT
      count(*)::bigint AS matched_customers,
      count(*) FILTER (WHERE lifetime_completed > 0)::bigint AS matched_with_visits,
      coalesce(sum(period_completed), 0)::bigint AS period_completed_visits,
      coalesce(sum(completed_revenue_period) FILTER (WHERE completed_revenue_period IS NOT NULL), 0)::numeric AS period_completed_revenue,
      count(*) FILTER (WHERE has_upcoming)::bigint AS future_booking_count,
      coalesce(bool_or(revenue_is_estimated), false) AS contains_estimated_prices,
      coalesce(sum(snapshot_completed), 0)::bigint AS completed_price_snapshot_count,
      coalesce(sum(estimated_completed), 0)::bigint AS completed_price_estimated_count,
      coalesce(sum(unknown_price_completed), 0)::bigint AS completed_price_unknown_count
    FROM filtered
  ),
  ordered AS (
    SELECT
      f.*,
      row_number() OVER (
        ORDER BY
          CASE v_sort
            WHEN 'last_visit_desc' THEN 0
            WHEN 'last_visit_asc' THEN 0
            WHEN 'lifetime_revenue_desc' THEN CASE WHEN f.completed_revenue_lifetime IS NULL THEN 1 ELSE 0 END
            WHEN 'period_revenue_desc' THEN CASE WHEN f.completed_revenue_period IS NULL THEN 1 ELSE 0 END
            WHEN 'lifetime_visits_desc' THEN 0
            WHEN 'name_asc' THEN 0
            WHEN 'next_booking_asc' THEN 0
            ELSE 0
          END ASC,
          CASE v_sort
            WHEN 'last_visit_desc' THEN extract(epoch FROM f.last_completed_visit_at)
            ELSE NULL
          END DESC NULLS LAST,
          CASE v_sort
            WHEN 'last_visit_asc' THEN extract(epoch FROM f.last_completed_visit_at)
            ELSE NULL
          END ASC NULLS LAST,
          CASE v_sort
            WHEN 'lifetime_revenue_desc' THEN f.completed_revenue_lifetime
            ELSE NULL
          END DESC NULLS LAST,
          CASE v_sort
            WHEN 'period_revenue_desc' THEN f.completed_revenue_period
            ELSE NULL
          END DESC NULLS LAST,
          CASE v_sort
            WHEN 'lifetime_visits_desc' THEN f.lifetime_completed
            ELSE NULL
          END DESC,
          CASE v_sort
            WHEN 'name_asc' THEN CASE WHEN f.display_name IS NULL THEN 1 ELSE 0 END
            ELSE 0
          END ASC,
          CASE v_sort
            WHEN 'name_asc' THEN lower(f.display_name)
            ELSE NULL
          END ASC NULLS LAST,
          CASE v_sort
            WHEN 'next_booking_asc' THEN extract(epoch FROM f.next_appointment_at)
            ELSE NULL
          END ASC NULLS LAST,
          f.analytics_customer_key ASC
      ) AS rn
    FROM filtered f
  ),
  paged AS (
    SELECT *
    FROM ordered
    WHERE rn > v_offset
      AND rn <= v_offset + v_limit
  ),
  customer_json AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'analytics_customer_key', p.analytics_customer_key,
          'customer_number', p.customer_number,
          'display_name', p.display_name,
          'phone', p.phone,
          'email', p.email,
          'identity_type', p.identity_type,
          'is_vip', p.is_vip,
          'gender', p.gender,
          'age_bucket', p.age_bucket,
          'city_id', p.city_id,
          'city_name', p.city_name,
          'country_code', p.country_code,
          'completed_visits_lifetime', p.lifetime_completed,
          'completed_visits_period', p.period_completed,
          'completed_revenue_lifetime', p.completed_revenue_lifetime,
          'completed_revenue_period', p.completed_revenue_period,
          'revenue_is_estimated', p.revenue_is_estimated,
          'first_completed_visit_at', p.first_completed_visit_at,
          'last_completed_visit_at', p.last_completed_visit_at,
          'days_since_last_visit', p.days_since_last_visit,
          'has_upcoming_appointment', p.has_upcoming,
          'next_appointment_at', p.next_appointment_at,
          'next_service_name', p.next_service_name
        )
        ORDER BY p.rn
      ),
      '[]'::jsonb
    ) AS customers
    FROM paged p
  )
  SELECT jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object(
      'from_date', p_from_date,
      'to_date', p_to_date,
      'timezone', v_timezone,
      'report_now', v_report_now
    ),
    'applied_filters', v_applied,
    'summary', jsonb_build_object(
      'matched_customers', sm.matched_customers,
      'matched_with_visits', sm.matched_with_visits,
      'period_completed_visits', sm.period_completed_visits,
      'period_completed_revenue', sm.period_completed_revenue,
      'future_booking_count', sm.future_booking_count,
      'contains_estimated_prices', sm.contains_estimated_prices
    ),
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'total', sm.matched_customers,
      'has_more', (v_offset + v_limit) < sm.matched_customers
    ),
    'sort', v_sort,
    'customers', cj.customers,
    'quality', jsonb_build_object(
      'unidentified_booking_count', qs.unidentified_booking_count,
      'invalid_appointment_time_count', qs.invalid_appointment_time_count,
      'unknown_duration_count', qs.unknown_duration_count,
      'contains_estimated_prices', sm.contains_estimated_prices,
      'completed_price_snapshot_count', sm.completed_price_snapshot_count,
      'completed_price_estimated_count', sm.completed_price_estimated_count,
      'completed_price_unknown_count', sm.completed_price_unknown_count,
      'source_scope', 'business_bookings',
      'price_scope', 'matched_customers_completed_visits'
    )
  )
  INTO v_result
  FROM summary sm
  CROSS JOIN customer_json cj
  CROSS JOIN quality_source qs;

  RETURN v_result;
END;
$fn$;

-- get_business_customer_analytics_overview(uuid,date,date): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_customer_analytics_overview(p_business_id uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
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

  WITH src AS (
    SELECT
      b.id,
      b.booking_status,
      b.customer_user_id,
      b.customer_name,
      b.customer_phone,
      b.customer_email,
      b.duration_minutes,
      b.booking_price,
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
      END AS canonical_price
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start IS NOT NULL
        AND appointment_start > v_report_now
      ) AS is_upcoming
    FROM classified
  ),
  period_flagged AS (
    SELECT
      flagged.*,
      (
        is_completed_visit
        AND appointment_local_date >= p_from_date
        AND appointment_local_date <= p_to_date
      ) AS is_period_completed
    FROM flagged
  ),
  period_kpis AS (
    SELECT
      count(*) FILTER (WHERE is_period_completed)::bigint AS completed_visits,
      coalesce(sum(canonical_price) FILTER (WHERE is_period_completed AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_total,
      count(*) FILTER (WHERE is_period_completed AND canonical_price IS NOT NULL)::bigint AS completed_revenue_known_rows,
      count(*) FILTER (WHERE is_period_completed AND price_source = 'snapshot')::bigint AS snapshot_price_count,
      count(*) FILTER (WHERE is_period_completed AND price_source = 'estimated')::bigint AS estimated_price_count,
      count(*) FILTER (WHERE is_period_completed AND price_source = 'unknown')::bigint AS unknown_price_count
    FROM period_flagged
  ),
  quality_base AS (
    SELECT
      count(*) FILTER (WHERE analytics_customer_key IS NULL)::bigint AS unidentified_booking_count,
      count(*) FILTER (WHERE appointment_start IS NULL)::bigint AS invalid_appointment_time_count,
      count(*) FILTER (
        WHERE appointment_start IS NOT NULL
          AND (duration_minutes IS NULL OR duration_minutes <= 0)
      )::bigint AS unknown_duration_count
    FROM period_flagged
  ),
  pop_keys AS (
    SELECT *
    FROM public._business_analytics_customer_keys(p_business_id)
  ),
  crm_mapped AS (
    SELECT
      public._resolve_business_analytics_customer_key(
        p_business_id,
        CASE
          WHEN bc.customer_user_id IS NOT NULL THEN 'u:' || bc.customer_user_id::text
          ELSE nullif(trim(bc.client_key), '')
        END
      ) AS analytics_customer_key,
      bc.approval_status
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
  ),
  population_stats AS (
    SELECT
      (SELECT count(*) FROM pop_keys)::bigint AS total_customers,
      (SELECT count(*) FROM pop_keys WHERE has_approved_membership)::bigint AS approved_members,
      (SELECT count(*) FROM pop_keys WHERE has_approved_membership AND NOT has_booking_history)::bigint AS approved_members_without_bookings,
      (SELECT count(*) FROM pop_keys WHERE has_booking_history)::bigint AS booking_customers,
      (SELECT count(*) FROM pop_keys WHERE has_booking_history AND NOT has_approved_membership)::bigint AS booking_only_customers,
      (
        SELECT count(DISTINCT cm.analytics_customer_key)
        FROM crm_mapped cm
        WHERE cm.analytics_customer_key IS NOT NULL
          AND cm.approval_status = 'rejected'
          AND NOT EXISTS (
            SELECT 1 FROM pop_keys p WHERE p.analytics_customer_key = cm.analytics_customer_key
          )
      )::bigint AS excluded_rejected_no_history,
      (
        SELECT count(DISTINCT cm.analytics_customer_key)
        FROM crm_mapped cm
        WHERE cm.analytics_customer_key IS NOT NULL
          AND cm.approval_status = 'pending'
          AND NOT EXISTS (
            SELECT 1 FROM pop_keys p WHERE p.analytics_customer_key = cm.analytics_customer_key
          )
      )::bigint AS excluded_pending_no_history,
      (
        SELECT count(DISTINCT cm.analytics_customer_key)
        FROM crm_mapped cm
        WHERE cm.analytics_customer_key IS NOT NULL
          AND cm.approval_status = 'blocked'
          AND NOT EXISTS (
            SELECT 1 FROM pop_keys p WHERE p.analytics_customer_key = cm.analytics_customer_key
          )
      )::bigint AS excluded_blocked_no_history
  ),
  contact_pairs AS (
    SELECT count(*)::bigint AS auth_guest_same_contact_pairs
    FROM pop_keys g
    WHERE g.identity_type = 'guest'
      AND (
        EXISTS (
          SELECT 1
          FROM public.bookings b
          WHERE b.business_id = p_business_id
            AND b.customer_user_id IS NOT NULL
            AND public._booking_client_key(
              b.customer_phone, b.customer_email, b.customer_name
            ) = g.analytics_customer_key
        )
        OR EXISTS (
          SELECT 1
          FROM public.business_customers bc
          WHERE bc.business_id = p_business_id
            AND bc.customer_user_id IS NOT NULL
            AND bc.client_key = g.analytics_customer_key
        )
      )
  ),
  customer_stats AS (
    SELECT
      analytics_customer_key,
      min(appointment_local_date) FILTER (WHERE is_completed_visit) AS first_completed_date,
      max(appointment_start) FILTER (WHERE is_completed_visit) AS last_completed_at,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS lifetime_completed,
      count(*) FILTER (WHERE is_period_completed)::bigint AS period_completed,
      bool_or(is_upcoming) AS has_upcoming
    FROM period_flagged
    WHERE analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  visitors AS (
    SELECT
      cs.*,
      (cs.lifetime_completed > 0) AS has_visits,
      (cs.period_completed > 0) AS is_active,
      (
        cs.period_completed > 0
        AND cs.first_completed_date >= p_from_date
        AND cs.first_completed_date <= p_to_date
      ) AS is_new,
      (
        cs.period_completed > 0
        AND cs.first_completed_date IS NOT NULL
        AND cs.first_completed_date < p_from_date
      ) AS is_returning,
      CASE
        WHEN cs.last_completed_at IS NULL THEN NULL
        ELSE v_report_now - cs.last_completed_at
      END AS inactive_for,
      CASE
        WHEN cs.analytics_customer_key LIKE 'u:%'
          THEN substr(cs.analytics_customer_key, 3)::uuid
        ELSE NULL
      END AS profile_user_id
    FROM customer_stats cs
  ),
  overview AS (
    SELECT
      (SELECT total_customers FROM population_stats)::bigint AS total_customers,
      count(*) FILTER (WHERE has_visits)::bigint AS customers_with_visits,
      count(*) FILTER (WHERE is_active)::bigint AS active_customers,
      count(*) FILTER (WHERE is_new)::bigint AS new_customers,
      count(*) FILTER (WHERE is_returning)::bigint AS returning_customers,
      count(*) FILTER (WHERE has_visits AND lifetime_completed >= 2)::bigint AS repeat_customers,
      count(*) FILTER (WHERE has_visits AND inactive_for > interval '30 days')::bigint AS inactive_30_plus,
      count(*) FILTER (WHERE has_visits AND inactive_for > interval '60 days')::bigint AS inactive_60_plus,
      count(*) FILTER (WHERE has_visits AND inactive_for > interval '90 days')::bigint AS inactive_90_plus,
      count(*) FILTER (WHERE has_upcoming)::bigint AS booked_ahead_customers,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '30 days'
      )::bigint AS at_risk_30,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '60 days'
      )::bigint AS at_risk_60,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '90 days'
      )::bigint AS at_risk_90,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '30 days'
          AND inactive_for <= interval '60 days'
      )::bigint AS at_risk_30_to_59,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '60 days'
          AND inactive_for <= interval '90 days'
      )::bigint AS at_risk_60_to_89,
      count(*) FILTER (
        WHERE has_visits
          AND NOT has_upcoming
          AND inactive_for > interval '90 days'
      )::bigint AS at_risk_90_plus_exclusive,
      count(*) FILTER (WHERE has_visits AND lifetime_completed = 1)::bigint AS freq_1,
      count(*) FILTER (WHERE has_visits AND lifetime_completed = 2)::bigint AS freq_2,
      count(*) FILTER (WHERE has_visits AND lifetime_completed = 3)::bigint AS freq_3,
      count(*) FILTER (WHERE has_visits AND lifetime_completed BETWEEN 4 AND 5)::bigint AS freq_4_5,
      count(*) FILTER (WHERE has_visits AND lifetime_completed BETWEEN 6 AND 10)::bigint AS freq_6_10,
      count(*) FILTER (WHERE has_visits AND lifetime_completed >= 11)::bigint AS freq_11_plus
    FROM visitors
  ),
  identity_mix AS (
    SELECT
      count(*) FILTER (WHERE analytics_customer_key LIKE 'u:%')::bigint AS customers_from_auth_identity,
      count(*) FILTER (
        WHERE analytics_customer_key NOT LIKE 'u:%'
      )::bigint AS customers_from_guest_identity
    FROM pop_keys
  ),
  demo_src AS (
    SELECT
      v.analytics_customer_key,
      pp.gender,
      pp.date_of_birth,
      pp.country_code,
      pp.city_id,
      ci.name_en AS city_name,
      CASE
        WHEN pp.date_of_birth IS NULL OR pp.date_of_birth > p_to_date THEN NULL
        ELSE (EXTRACT(YEAR FROM age(p_to_date, pp.date_of_birth)))::int
      END AS age_years,
      (pp.user_id IS NOT NULL) AS has_profile
    FROM visitors v
    LEFT JOIN public.customer_private_profiles pp
      ON pp.user_id = v.profile_user_id
    LEFT JOIN public.cities ci
      ON ci.id = pp.city_id
    WHERE v.has_visits
  ),
  demo_gender AS (
    SELECT
      count(*)::bigint AS population_total,
      count(*) FILTER (WHERE gender IN ('male', 'female'))::bigint AS known_count,
      count(*) FILTER (WHERE gender IS NULL OR gender NOT IN ('male', 'female'))::bigint AS unknown_count,
      count(*) FILTER (WHERE gender = 'male')::bigint AS male,
      count(*) FILTER (WHERE gender = 'female')::bigint AS female
    FROM demo_src
  ),
  demo_age AS (
    SELECT
      count(*)::bigint AS population_total,
      count(*) FILTER (WHERE age_years IS NOT NULL)::bigint AS known_count,
      count(*) FILTER (WHERE age_years IS NULL)::bigint AS unknown_count,
      count(*) FILTER (WHERE age_years < 18)::bigint AS under_18,
      count(*) FILTER (WHERE age_years BETWEEN 18 AND 24)::bigint AS age_18_24,
      count(*) FILTER (WHERE age_years BETWEEN 25 AND 34)::bigint AS age_25_34,
      count(*) FILTER (WHERE age_years BETWEEN 35 AND 44)::bigint AS age_35_44,
      count(*) FILTER (WHERE age_years BETWEEN 45 AND 54)::bigint AS age_45_54,
      count(*) FILTER (WHERE age_years BETWEEN 55 AND 64)::bigint AS age_55_64,
      count(*) FILTER (WHERE age_years >= 65)::bigint AS age_65_plus
    FROM demo_src
  ),
  demo_city_groups AS (
    SELECT
      city_id,
      coalesce(nullif(trim(city_name), ''), 'Unknown') AS city_name,
      count(*)::bigint AS count
    FROM demo_src
    WHERE city_id IS NOT NULL
    GROUP BY city_id, coalesce(nullif(trim(city_name), ''), 'Unknown')
  ),
  demo_city AS (
    SELECT
      (SELECT count(*) FROM demo_src)::bigint AS population_total,
      (SELECT coalesce(sum(count), 0) FROM demo_city_groups)::bigint AS known_count,
      (SELECT count(*) FROM demo_src WHERE city_id IS NULL)::bigint AS unknown_count,
      coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'city_id', g.city_id,
              'city_name', g.city_name,
              'count', g.count
            )
            ORDER BY g.count DESC, g.city_name ASC
          )
          FROM demo_city_groups g
        ),
        '[]'::jsonb
      ) AS cities
    FROM (SELECT 1) _x
  ),
  demo_country_groups AS (
    SELECT
      country_code,
      count(*)::bigint AS count
    FROM demo_src
    WHERE country_code IS NOT NULL
    GROUP BY country_code
  ),
  demo_country AS (
    SELECT
      (SELECT count(*) FROM demo_src)::bigint AS population_total,
      (SELECT coalesce(sum(count), 0) FROM demo_country_groups)::bigint AS known_count,
      (SELECT count(*) FROM demo_src WHERE country_code IS NULL)::bigint AS unknown_count,
      coalesce(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'country_code', g.country_code,
              'count', g.count
            )
            ORDER BY g.count DESC, g.country_code ASC
          )
          FROM demo_country_groups g
        ),
        '[]'::jsonb
      ) AS countries
    FROM (SELECT 1) _x
  ),
  demo_quality AS (
    SELECT
      count(*) FILTER (WHERE has_profile)::bigint AS demographic_profile_count,
      count(*) FILTER (
        WHERE gender IN ('male', 'female')
           OR age_years IS NOT NULL
           OR country_code IS NOT NULL
           OR city_id IS NOT NULL
      )::bigint AS demographic_known_customer_count,
      count(*) FILTER (
        WHERE coalesce(gender, '') NOT IN ('male', 'female')
          AND age_years IS NULL
          AND country_code IS NULL
          AND city_id IS NULL
      )::bigint AS demographic_unknown_customer_count
    FROM demo_src
  ),
  age_facts AS (
    SELECT bucket, count
    FROM (
      VALUES
        ('Under 18', (SELECT under_18 FROM demo_age)),
        ('18-24', (SELECT age_18_24 FROM demo_age)),
        ('25-34', (SELECT age_25_34 FROM demo_age)),
        ('35-44', (SELECT age_35_44 FROM demo_age)),
        ('45-54', (SELECT age_45_54 FROM demo_age)),
        ('55-64', (SELECT age_55_64 FROM demo_age)),
        ('65+', (SELECT age_65_plus FROM demo_age))
    ) s(bucket, count)
    WHERE count > 0
    ORDER BY count DESC, bucket ASC
    LIMIT 1
  ),
  city_facts AS (
    SELECT city_name, count
    FROM demo_city_groups
    ORDER BY count DESC, city_name ASC
    LIMIT 1
  )
  SELECT jsonb_build_object(
    'ok', true,
    'period', jsonb_build_object(
      'from_date', p_from_date,
      'to_date', p_to_date,
      'timezone', v_timezone,
      'report_now', v_report_now
    ),
    'overview', jsonb_build_object(
      'total_customers', o.total_customers,
      'customers_with_visits', o.customers_with_visits,
      'active_customers', o.active_customers,
      'new_customers', o.new_customers,
      'returning_customers', o.returning_customers,
      'returning_share_pct',
        CASE
          WHEN o.active_customers > 0
            THEN round((100.0 * o.returning_customers) / o.active_customers, 1)
          ELSE NULL
        END,
      'average_visits_per_customer',
        CASE
          WHEN o.active_customers > 0
            THEN round(pk.completed_visits::numeric / o.active_customers, 2)
          ELSE NULL
        END,
      'repeat_customers', o.repeat_customers,
      'repeat_rate_pct',
        CASE
          WHEN o.customers_with_visits > 0
            THEN round((100.0 * o.repeat_customers) / o.customers_with_visits, 1)
          ELSE NULL
        END,
      'completed_visits', pk.completed_visits
    ),
    'population', jsonb_build_object(
      'total_customers', ps.total_customers,
      'approved_members', ps.approved_members,
      'approved_members_without_bookings', ps.approved_members_without_bookings,
      'booking_customers', ps.booking_customers,
      'booking_only_customers', ps.booking_only_customers,
      'excluded_rejected_no_history', ps.excluded_rejected_no_history,
      'excluded_pending_no_history', ps.excluded_pending_no_history,
      'excluded_blocked_no_history', ps.excluded_blocked_no_history,
      'auth_guest_same_contact_pairs', cp.auth_guest_same_contact_pairs
    ),
    'inactivity', jsonb_build_object(
      'inactive_30_plus', o.inactive_30_plus,
      'inactive_60_plus', o.inactive_60_plus,
      'inactive_90_plus', o.inactive_90_plus,
      'booked_ahead_customers', o.booked_ahead_customers,
      'at_risk_30', o.at_risk_30,
      'at_risk_60', o.at_risk_60,
      'at_risk_90', o.at_risk_90,
      'at_risk_30_to_59', o.at_risk_30_to_59,
      'at_risk_60_to_89', o.at_risk_60_to_89,
      'at_risk_90_plus', o.at_risk_90_plus_exclusive
    ),
    'demographics', jsonb_build_object(
      'population', 'customers_with_visits',
      'gender', jsonb_build_object(
        'population_total', dg.population_total,
        'known_count', dg.known_count,
        'unknown_count', dg.unknown_count,
        'male', dg.male,
        'female', dg.female,
        'unknown', dg.unknown_count,
        'total', dg.population_total
      ),
      'age', jsonb_build_object(
        'as_of_date', p_to_date,
        'population_total', da.population_total,
        'known_count', da.known_count,
        'unknown_count', da.unknown_count,
        'under_18', da.under_18,
        'age_18_24', da.age_18_24,
        'age_25_34', da.age_25_34,
        'age_35_44', da.age_35_44,
        'age_45_54', da.age_45_54,
        'age_55_64', da.age_55_64,
        'age_65_plus', da.age_65_plus,
        'unknown', da.unknown_count
      ),
      'cities', jsonb_build_object(
        'population_total', dc.population_total,
        'known_count', dc.known_count,
        'unknown_count', dc.unknown_count,
        'unknown_city', dc.unknown_count,
        'groups', dc.cities
      ),
      'countries', jsonb_build_object(
        'population_total', dco.population_total,
        'known_count', dco.known_count,
        'unknown_count', dco.unknown_count,
        'unknown', dco.unknown_count,
        'groups', dco.countries
      )
    ),
    'frequency', jsonb_build_object(
      'population', 'customers_with_visits',
      'visits_1', o.freq_1,
      'visits_2', o.freq_2,
      'visits_3', o.freq_3,
      'visits_4_5', o.freq_4_5,
      'visits_6_10', o.freq_6_10,
      'visits_11_plus', o.freq_11_plus,
      'population_total', o.customers_with_visits
    ),
    'value', jsonb_build_object(
      'completed_revenue_total', pk.completed_revenue_total,
      'completed_revenue_per_active_customer',
        CASE
          WHEN o.active_customers > 0
            THEN round(pk.completed_revenue_total / o.active_customers, 2)
          ELSE NULL
        END,
      'average_spend_per_completed_visit',
        CASE
          WHEN pk.completed_revenue_known_rows > 0
            THEN round(pk.completed_revenue_total / pk.completed_revenue_known_rows, 2)
          ELSE NULL
        END,
      'contains_estimated_prices', (pk.estimated_price_count > 0),
      'snapshot_price_count', pk.snapshot_price_count,
      'estimated_price_count', pk.estimated_price_count,
      'unknown_price_count', pk.unknown_price_count
    ),
    'facts', jsonb_build_object(
      'busiest_age_bucket', (SELECT bucket FROM age_facts),
      'top_city', (SELECT city_name FROM city_facts),
      'new_customers', o.new_customers,
      'returning_customers', o.returning_customers,
      'repeat_rate_pct',
        CASE
          WHEN o.customers_with_visits > 0
            THEN round((100.0 * o.repeat_customers) / o.customers_with_visits, 1)
          ELSE NULL
        END,
      'at_risk_90', o.at_risk_90,
      'average_visits_per_customer',
        CASE
          WHEN o.active_customers > 0
            THEN round(pk.completed_visits::numeric / o.active_customers, 2)
          ELSE NULL
        END
    ),
    'quality', jsonb_build_object(
      'unidentified_booking_count', qb.unidentified_booking_count,
      'invalid_appointment_time_count', qb.invalid_appointment_time_count,
      'unknown_duration_count', qb.unknown_duration_count,
      'demographic_profile_count', dq.demographic_profile_count,
      'demographic_known_customer_count', dq.demographic_known_customer_count,
      'demographic_unknown_customer_count', dq.demographic_unknown_customer_count,
      'customers_from_auth_identity', im.customers_from_auth_identity,
      'customers_from_guest_identity', im.customers_from_guest_identity,
      'auth_guest_same_contact_pairs', cp.auth_guest_same_contact_pairs
    )
  )
  INTO v_result
  FROM overview o
  CROSS JOIN period_kpis pk
  CROSS JOIN quality_base qb
  CROSS JOIN demo_gender dg
  CROSS JOIN demo_age da
  CROSS JOIN demo_city dc
  CROSS JOIN demo_country dco
  CROSS JOIN demo_quality dq
  CROSS JOIN identity_mix im
  CROSS JOIN population_stats ps
  CROSS JOIN contact_pairs cp;

  RETURN v_result;
END;
$fn$;

-- get_business_customer_detail(uuid,text,integer,integer): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_customer_detail(p_business_id uuid, p_customer_key text, p_history_limit integer DEFAULT 25, p_history_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_age_as_of date;
  v_key text;
  v_profile_user_id uuid;
  v_limit integer;
  v_offset integer;
  v_exists boolean;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized'
      USING ERRCODE = '42501';
  END IF;

  v_key := nullif(trim(coalesce(p_customer_key, '')), '');
  IF v_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  v_key := public._resolve_business_analytics_customer_key(p_business_id, v_key);
  IF v_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  v_profile_user_id := NULL;
  IF v_key LIKE 'u:%' THEN
    BEGIN
      v_profile_user_id := substr(v_key, 3)::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found');
    END;
  END IF;

  v_limit := coalesce(p_history_limit, 25);
  v_offset := coalesce(p_history_offset, 0);
  IF v_limit < 1 OR v_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination'
      USING ERRCODE = '22023';
  END IF;
  IF v_limit > 100 THEN
    v_limit := 100;
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
  v_age_as_of := (v_report_now AT TIME ZONE v_timezone)::date;

  SELECT EXISTS (
    SELECT 1
    FROM public._business_analytics_customer_keys(p_business_id) k
    WHERE k.analytics_customer_key = v_key
  )
  INTO v_exists;

  IF NOT coalesce(v_exists, false) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'not_found');
  END IF;

  WITH src AS (
    SELECT
      b.id,
      b.booking_status,
      b.customer_user_id,
      b.customer_name,
      b.customer_phone,
      b.customer_email,
      b.duration_minutes,
      b.booking_price,
      b.service_id,
      b.service_name,
      b.staff_id,
      s.name AS catalog_service_name,
      s.price AS catalog_price,
      st.name AS staff_name,
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
     AND st.business_id = b.business_id
    WHERE b.business_id = p_business_id
      AND public._resolve_business_analytics_customer_key(
        p_business_id,
        public._analytics_customer_key(
          b.customer_user_id,
          b.customer_phone,
          b.customer_email,
          b.customer_name
        )
      ) = v_key
  ),
  classified AS (
    SELECT
      src.*,
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
      END AS canonical_price
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start IS NOT NULL
        AND appointment_start > v_report_now
      ) AS is_upcoming
    FROM classified
  ),
  flagged_state AS (
    SELECT
      flagged.*,
      CASE
        WHEN booking_status = 'Cancelled' THEN 'cancelled'
        WHEN is_upcoming THEN 'upcoming'
        WHEN is_completed_visit THEN 'completed'
        WHEN booking_status = 'Confirmed' THEN 'confirmed'
        WHEN booking_status = 'Pending' THEN 'pending'
        ELSE lower(coalesce(booking_status, ''))
      END AS display_state,
      coalesce(
        nullif(trim(catalog_service_name), ''),
        nullif(trim(service_name), '')
      ) AS resolved_service_name
    FROM flagged
  ),
  stats AS (
    SELECT
      count(*) FILTER (WHERE is_completed_visit)::bigint AS lifetime_completed,
      count(*) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL)::bigint AS priced_completed,
      min(appointment_start) FILTER (WHERE is_completed_visit) AS first_completed_visit_at,
      max(appointment_start) FILTER (WHERE is_completed_visit) AS last_completed_visit_at,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_lifetime,
      coalesce(bool_or(is_completed_visit AND price_source = 'estimated'), false) AS contains_estimated_prices,
      nullif(trim((ARRAY_AGG(customer_name ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_name), '') IS NOT NULL
          AND lower(trim(customer_name)) <> 'customer'
      ))[1]), '') AS booking_display_name,
      nullif(trim((ARRAY_AGG(customer_phone ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_phone), '') IS NOT NULL
      ))[1]), '') AS booking_phone,
      nullif(trim((ARRAY_AGG(customer_email ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_email), '') IS NOT NULL
      ))[1]), '') AS booking_email
    FROM flagged_state
  ),
  cadence AS (
    SELECT
      CASE
        WHEN s.lifetime_completed >= 2
          AND s.first_completed_visit_at IS NOT NULL
          AND s.last_completed_visit_at IS NOT NULL
          THEN round(
            (extract(epoch FROM (s.last_completed_visit_at - s.first_completed_visit_at)) / 86400.0)
            / (s.lifetime_completed - 1)::numeric,
            1
          )
        ELSE NULL
      END AS average_days_between_visits,
      (
        SELECT
          CASE
            WHEN c1.appointment_start IS NULL OR c2.appointment_start IS NULL THEN NULL
            ELSE floor(extract(epoch FROM (c1.appointment_start - c2.appointment_start)) / 86400)::int
          END
        FROM (
          SELECT appointment_start
          FROM flagged_state
          WHERE is_completed_visit
          ORDER BY appointment_start DESC NULLS LAST, id DESC
          LIMIT 1
        ) c1
        LEFT JOIN LATERAL (
          SELECT appointment_start
          FROM flagged_state
          WHERE is_completed_visit
          ORDER BY appointment_start DESC NULLS LAST, id DESC
          OFFSET 1
          LIMIT 1
        ) c2 ON true
      ) AS last_visit_gap_days
    FROM stats s
  ),
  crm AS (
    SELECT DISTINCT ON (map_key)
      map_key,
      bc.customer_number,
      bc.display_name,
      bc.phone,
      bc.email,
      bc.is_vip
    FROM (
      SELECT
        bc.*,
        CASE
          WHEN bc.customer_user_id IS NOT NULL THEN 'u:' || bc.customer_user_id::text
          ELSE bc.client_key
        END AS map_key
      FROM public.business_customers bc
      WHERE bc.business_id = p_business_id
    ) bc
    WHERE map_key = v_key
    ORDER BY map_key, bc.created_at ASC, bc.id ASC
  ),
  demo AS (
    SELECT
      CASE
        WHEN v_profile_user_id IS NULL THEN NULL
        WHEN pp.gender IN ('male', 'female') THEN pp.gender
        ELSE 'unknown'
      END AS gender,
      CASE
        WHEN v_profile_user_id IS NULL THEN NULL
        WHEN pp.date_of_birth IS NULL OR pp.date_of_birth > v_age_as_of THEN NULL
        ELSE (EXTRACT(YEAR FROM age(v_age_as_of, pp.date_of_birth)))::int
      END AS age_years,
      CASE WHEN v_profile_user_id IS NULL THEN NULL ELSE pp.city_id END AS city_id,
      CASE WHEN v_profile_user_id IS NULL THEN NULL ELSE ci.name_en END AS city_name,
      CASE WHEN v_profile_user_id IS NULL THEN NULL ELSE pp.country_code END AS country_code
    FROM (SELECT 1) dummy
    LEFT JOIN public.customer_private_profiles pp
      ON pp.user_id = v_profile_user_id
    LEFT JOIN public.cities ci
      ON ci.id = pp.city_id
  ),
  next_appt AS (
    SELECT
      appointment_start AS next_appointment_at,
      resolved_service_name AS service_name,
      staff_name,
      duration_minutes
    FROM flagged_state
    WHERE is_upcoming
    ORDER BY appointment_start ASC, id ASC
    LIMIT 1
  ),
  top_services AS (
    SELECT coalesce(
      jsonb_agg(row_json ORDER BY completed_visits DESC, completed_revenue DESC, service_name ASC),
      '[]'::jsonb
    ) AS services
    FROM (
      SELECT
        jsonb_build_object(
          'service_id', g.service_id,
          'service_name', g.service_name,
          'completed_visits', g.completed_visits,
          'completed_revenue', g.completed_revenue
        ) AS row_json,
        g.completed_visits,
        g.completed_revenue,
        g.service_name
      FROM (
        SELECT
          service_id,
          coalesce(nullif(trim(resolved_service_name), ''), 'Service') AS service_name,
          count(*)::bigint AS completed_visits,
          coalesce(sum(canonical_price) FILTER (WHERE canonical_price IS NOT NULL), 0)::numeric AS completed_revenue
        FROM flagged_state
        WHERE is_completed_visit
        GROUP BY service_id, coalesce(nullif(trim(resolved_service_name), ''), 'Service')
        ORDER BY count(*) DESC, coalesce(sum(canonical_price) FILTER (WHERE canonical_price IS NOT NULL), 0) DESC
        LIMIT 5
      ) g
    ) ranked
  ),
  upcoming_json AS (
    SELECT coalesce(
      jsonb_agg(row_json ORDER BY appointment_start ASC, id ASC),
      '[]'::jsonb
    ) AS rows
    FROM (
      SELECT
        jsonb_build_object(
          'booking_id', f.id,
          'appointment_start', f.appointment_start,
          'appointment_end', f.appointment_end,
          'service_id', f.service_id,
          'service_name', f.resolved_service_name,
          'staff_name', f.staff_name,
          'booking_status', f.booking_status,
          'display_state', f.display_state,
          'duration_minutes', f.duration_minutes,
          'price', f.canonical_price,
          'price_is_estimated', (f.price_source = 'estimated')
        ) AS row_json,
        f.appointment_start,
        f.id
      FROM flagged_state f
      WHERE f.is_upcoming
      ORDER BY f.appointment_start ASC, f.id ASC
      LIMIT 50
    ) u
  ),
  past_numbered AS (
    SELECT
      f.*,
      row_number() OVER (ORDER BY f.appointment_start DESC NULLS LAST, f.id DESC) AS rn
    FROM flagged_state f
    WHERE NOT f.is_upcoming
  ),
  past_total AS (
    SELECT count(*)::bigint AS total_count
    FROM past_numbered
  ),
  past_json AS (
    SELECT coalesce(
      jsonb_agg(row_json ORDER BY rn),
      '[]'::jsonb
    ) AS rows
    FROM (
      SELECT
        jsonb_build_object(
          'booking_id', p.id,
          'appointment_start', p.appointment_start,
          'appointment_end', p.appointment_end,
          'service_id', p.service_id,
          'service_name', p.resolved_service_name,
          'staff_name', p.staff_name,
          'booking_status', p.booking_status,
          'display_state', p.display_state,
          'duration_minutes', p.duration_minutes,
          'price', p.canonical_price,
          'price_is_estimated', (p.price_source = 'estimated')
        ) AS row_json,
        p.rn
      FROM past_numbered p
      WHERE p.rn > v_offset
        AND p.rn <= v_offset + v_limit
    ) page
  )
  SELECT jsonb_build_object(
    'ok', true,
    'customer', jsonb_build_object(
      'analytics_customer_key', v_key,
      'customer_number', crm.customer_number,
      'display_name', coalesce(nullif(trim(crm.display_name), ''), s.booking_display_name),
      'phone', coalesce(nullif(trim(crm.phone), ''), s.booking_phone),
      'email', coalesce(nullif(trim(crm.email), ''), s.booking_email),
      'identity_type', CASE WHEN v_key LIKE 'u:%' THEN 'auth' ELSE 'guest' END,
      'is_vip', coalesce(crm.is_vip, false),
      'gender', CASE
        WHEN v_key LIKE 'u:%' THEN coalesce(d.gender, 'unknown')
        ELSE 'unknown'
      END,
      'age_bucket', CASE
        WHEN v_key NOT LIKE 'u:%' THEN 'unknown'
        WHEN d.age_years IS NULL THEN 'unknown'
        WHEN d.age_years < 18 THEN 'under_18'
        WHEN d.age_years BETWEEN 18 AND 24 THEN '18_24'
        WHEN d.age_years BETWEEN 25 AND 34 THEN '25_34'
        WHEN d.age_years BETWEEN 35 AND 44 THEN '35_44'
        WHEN d.age_years BETWEEN 45 AND 54 THEN '45_54'
        WHEN d.age_years BETWEEN 55 AND 64 THEN '55_64'
        ELSE '65_plus'
      END,
      'city_id', CASE WHEN v_key LIKE 'u:%' THEN d.city_id ELSE NULL END,
      'city_name', CASE WHEN v_key LIKE 'u:%' THEN d.city_name ELSE NULL END,
      'country_code', CASE WHEN v_key LIKE 'u:%' THEN d.country_code ELSE NULL END
    ),
    'summary', jsonb_build_object(
      'first_completed_visit_at', s.first_completed_visit_at,
      'last_completed_visit_at', s.last_completed_visit_at,
      'completed_visits_lifetime', s.lifetime_completed,
      'completed_revenue_lifetime', s.completed_revenue_lifetime,
      'average_spend_per_completed_visit', CASE
        WHEN s.priced_completed > 0 THEN round(s.completed_revenue_lifetime / s.priced_completed::numeric, 2)
        ELSE NULL
      END,
      'days_since_last_visit', CASE
        WHEN s.last_completed_visit_at IS NULL THEN NULL
        ELSE floor(extract(epoch FROM (v_report_now - s.last_completed_visit_at)) / 86400)::int
      END,
      'repeat_customer', (s.lifetime_completed >= 2),
      'contains_estimated_prices', s.contains_estimated_prices
    ),
    'cadence', jsonb_build_object(
      'average_days_between_visits', cad.average_days_between_visits,
      'last_visit_gap_days', cad.last_visit_gap_days
    ),
    'upcoming', jsonb_build_object(
      'has_upcoming_appointment', (na.next_appointment_at IS NOT NULL),
      'next_appointment_at', na.next_appointment_at,
      'service_name', na.service_name,
      'staff_name', na.staff_name,
      'duration_minutes', na.duration_minutes
    ),
    'top_services', ts.services,
    'history_upcoming', uj.rows,
    'history', pj.rows,
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'total_count', pt.total_count,
      'has_more', (v_offset + v_limit) < pt.total_count
    ),
    'contains_estimated_prices', s.contains_estimated_prices,
    'contact_missing', (
      coalesce(nullif(trim(crm.phone), ''), s.booking_phone) IS NULL
      AND coalesce(nullif(trim(crm.email), ''), s.booking_email) IS NULL
    ),
    'demographics_missing', (
      v_key NOT LIKE 'u:%'
      OR coalesce(d.gender, 'unknown') = 'unknown'
      OR d.age_years IS NULL
      OR d.city_id IS NULL
    )
  )
  INTO v_result
  FROM stats s
  CROSS JOIN cadence cad
  CROSS JOIN top_services ts
  CROSS JOIN upcoming_json uj
  CROSS JOIN past_json pj
  CROSS JOIN past_total pt
  CROSS JOIN demo d
  LEFT JOIN crm ON true
  LEFT JOIN next_appt na ON true;

  RETURN v_result;
END;
$fn$;

-- get_business_customer_segment(uuid,text,date,date,text,integer,integer): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_customer_segment(p_business_id uuid, p_segment text, p_from_date date, p_to_date date, p_filter_value text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_segment text;
  v_filter text;
  v_city_id uuid;
  v_limit integer;
  v_offset integer;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL OR p_from_date IS NULL OR p_to_date IS NULL OR p_from_date > p_to_date THEN
    RAISE EXCEPTION 'Invalid report period'
      USING ERRCODE = '22023';
  END IF;

  v_segment := lower(trim(coalesce(p_segment, '')));
  IF v_segment NOT IN (
    'active',
    'new',
    'returning',
    'repeat',
    'single_visit',
    'at_risk_30_59',
    'at_risk_60_89',
    'at_risk_90_plus',
    'booked_ahead',
    'gender',
    'age_bucket',
    'city'
  ) THEN
    RAISE EXCEPTION 'Invalid segment'
      USING ERRCODE = '22023';
  END IF;

  v_filter := nullif(lower(trim(coalesce(p_filter_value, ''))), '');

  IF v_segment IN ('gender', 'age_bucket', 'city') THEN
    IF v_filter IS NULL THEN
      RAISE EXCEPTION 'filter_value is required for this segment'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF v_segment = 'gender' AND v_filter NOT IN ('male', 'female', 'unknown') THEN
    RAISE EXCEPTION 'Invalid filter_value'
      USING ERRCODE = '22023';
  END IF;

  IF v_segment = 'age_bucket' AND v_filter NOT IN (
    'under_18', '18_24', '25_34', '35_44', '45_54', '55_64', '65_plus', 'unknown'
  ) THEN
    RAISE EXCEPTION 'Invalid filter_value'
      USING ERRCODE = '22023';
  END IF;

  IF v_segment = 'city' THEN
    IF v_filter = 'unknown' THEN
      v_city_id := NULL;
    ELSIF v_filter ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      v_city_id := v_filter::uuid;
    ELSE
      RAISE EXCEPTION 'Invalid filter_value'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  v_limit := coalesce(p_limit, 50);
  v_offset := coalesce(p_offset, 0);
  IF v_limit < 1 OR v_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination'
      USING ERRCODE = '22023';
  END IF;
  IF v_limit > 100 THEN
    v_limit := 100;
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

  WITH src AS (
    SELECT
      b.id,
      b.booking_status,
      b.customer_user_id,
      b.customer_name,
      b.customer_phone,
      b.customer_email,
      b.duration_minutes,
      b.booking_price,
      b.service_name,
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
      END AS canonical_price
    FROM src
  ),
  flagged AS (
    SELECT
      classified.*,
      (
        booking_status = 'Confirmed'
        AND appointment_end IS NOT NULL
        AND appointment_end <= v_report_now
      ) AS is_completed_visit,
      (
        booking_status IN ('Pending', 'Confirmed')
        AND appointment_start IS NOT NULL
        AND appointment_start > v_report_now
      ) AS is_upcoming
    FROM classified
  ),
  period_flagged AS (
    SELECT
      flagged.*,
      (
        is_completed_visit
        AND appointment_local_date >= p_from_date
        AND appointment_local_date <= p_to_date
      ) AS is_period_completed
    FROM flagged
  ),
  customer_stats AS (
    SELECT
      analytics_customer_key,
      min(appointment_local_date) FILTER (WHERE is_completed_visit) AS first_completed_date,
      min(appointment_start) FILTER (WHERE is_completed_visit) AS first_completed_visit_at,
      max(appointment_start) FILTER (WHERE is_completed_visit) AS last_completed_visit_at,
      count(*) FILTER (WHERE is_completed_visit)::bigint AS lifetime_completed,
      count(*) FILTER (WHERE is_period_completed)::bigint AS period_completed,
      coalesce(sum(canonical_price) FILTER (WHERE is_completed_visit AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_lifetime,
      coalesce(sum(canonical_price) FILTER (WHERE is_period_completed AND canonical_price IS NOT NULL), 0)::numeric AS completed_revenue_period,
      coalesce(bool_or(is_completed_visit AND price_source = 'estimated'), false) AS revenue_is_estimated,
      bool_or(is_upcoming) AS has_upcoming,
      CASE
        WHEN analytics_customer_key LIKE 'u:%'
          THEN substr(analytics_customer_key, 3)::uuid
        ELSE NULL
      END AS profile_user_id,
      nullif(trim((ARRAY_AGG(customer_name ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_name), '') IS NOT NULL
          AND lower(trim(customer_name)) <> 'customer'
      ))[1]), '') AS booking_display_name,
      nullif(trim((ARRAY_AGG(customer_phone ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_phone), '') IS NOT NULL
      ))[1]), '') AS booking_phone,
      nullif(trim((ARRAY_AGG(customer_email ORDER BY appointment_start DESC NULLS LAST, id DESC) FILTER (
        WHERE nullif(trim(customer_email), '') IS NOT NULL
      ))[1]), '') AS booking_email
    FROM period_flagged
    WHERE analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  next_appt AS (
    SELECT DISTINCT ON (analytics_customer_key)
      analytics_customer_key,
      appointment_start AS next_appointment_at,
      coalesce(
        nullif(trim(catalog_service_name), ''),
        nullif(trim(service_name), '')
      ) AS next_service_name
    FROM period_flagged
    WHERE analytics_customer_key IS NOT NULL
      AND is_upcoming
    ORDER BY analytics_customer_key, appointment_start ASC, id ASC
  ),
  visitors AS (
    SELECT
      cs.*,
      (cs.lifetime_completed > 0) AS has_visits,
      (cs.period_completed > 0) AS is_active,
      (
        cs.period_completed > 0
        AND cs.first_completed_date >= p_from_date
        AND cs.first_completed_date <= p_to_date
      ) AS is_new,
      (
        cs.period_completed > 0
        AND cs.first_completed_date IS NOT NULL
        AND cs.first_completed_date < p_from_date
      ) AS is_returning,
      CASE
        WHEN cs.last_completed_visit_at IS NULL THEN NULL
        ELSE v_report_now - cs.last_completed_visit_at
      END AS inactive_for
    FROM customer_stats cs
  ),
  crm AS (
    SELECT DISTINCT ON (map_key)
      map_key,
      bc.customer_number,
      bc.display_name,
      bc.phone,
      bc.email,
      bc.is_vip
    FROM (
      SELECT
        bc.*,
        CASE
          WHEN bc.customer_user_id IS NOT NULL THEN 'u:' || bc.customer_user_id::text
          ELSE bc.client_key
        END AS map_key
      FROM public.business_customers bc
      WHERE bc.business_id = p_business_id
    ) bc
    WHERE map_key IS NOT NULL
    ORDER BY map_key, bc.created_at ASC, bc.id ASC
  ),
  demo AS (
    SELECT
      v.analytics_customer_key,
      pp.gender,
      pp.country_code,
      pp.city_id,
      ci.name_en AS city_name,
      CASE
        WHEN pp.date_of_birth IS NULL OR pp.date_of_birth > p_to_date THEN NULL
        ELSE (EXTRACT(YEAR FROM age(p_to_date, pp.date_of_birth)))::int
      END AS age_years
    FROM visitors v
    LEFT JOIN public.customer_private_profiles pp
      ON pp.user_id = v.profile_user_id
    LEFT JOIN public.cities ci
      ON ci.id = pp.city_id
  ),
  enriched AS (
    SELECT
      v.analytics_customer_key,
      v.profile_user_id,
      v.has_visits,
      v.is_active,
      v.is_new,
      v.is_returning,
      v.lifetime_completed,
      v.period_completed,
      v.first_completed_visit_at,
      v.last_completed_visit_at,
      v.completed_revenue_lifetime,
      v.completed_revenue_period,
      v.revenue_is_estimated,
      v.has_upcoming,
      v.inactive_for,
      CASE
        WHEN v.last_completed_visit_at IS NULL THEN NULL
        ELSE floor(extract(epoch FROM (v_report_now - v.last_completed_visit_at)) / 86400)::int
      END AS days_since_last_visit,
      CASE
        WHEN v.analytics_customer_key LIKE 'u:%' THEN 'auth'
        ELSE 'guest'
      END AS identity_type,
      crm.customer_number,
      coalesce(crm.is_vip, false) AS is_vip,
      coalesce(nullif(trim(crm.display_name), ''), v.booking_display_name) AS display_name,
      coalesce(nullif(trim(crm.phone), ''), v.booking_phone) AS phone,
      coalesce(nullif(trim(crm.email), ''), v.booking_email) AS email,
      na.next_appointment_at,
      na.next_service_name,
      CASE
        WHEN d.gender IN ('male', 'female') THEN d.gender
        ELSE 'unknown'
      END AS gender,
      CASE
        WHEN d.age_years IS NULL THEN 'unknown'
        WHEN d.age_years < 18 THEN 'under_18'
        WHEN d.age_years BETWEEN 18 AND 24 THEN '18_24'
        WHEN d.age_years BETWEEN 25 AND 34 THEN '25_34'
        WHEN d.age_years BETWEEN 35 AND 44 THEN '35_44'
        WHEN d.age_years BETWEEN 45 AND 54 THEN '45_54'
        WHEN d.age_years BETWEEN 55 AND 64 THEN '55_64'
        ELSE '65_plus'
      END AS age_bucket,
      d.city_id,
      d.city_name,
      d.country_code
    FROM visitors v
    LEFT JOIN crm
      ON crm.map_key = v.analytics_customer_key
    LEFT JOIN next_appt na
      ON na.analytics_customer_key = v.analytics_customer_key
    LEFT JOIN demo d
      ON d.analytics_customer_key = v.analytics_customer_key
  ),
  segmented AS (
    SELECT *
    FROM enriched e
    WHERE CASE v_segment
      WHEN 'active' THEN e.is_active
      WHEN 'new' THEN e.is_new
      WHEN 'returning' THEN e.is_returning
      WHEN 'repeat' THEN e.has_visits AND e.lifetime_completed >= 2
      WHEN 'single_visit' THEN e.has_visits AND e.lifetime_completed = 1
      WHEN 'at_risk_30_59' THEN
        e.has_visits
        AND NOT coalesce(e.has_upcoming, false)
        AND e.inactive_for > interval '30 days'
        AND e.inactive_for <= interval '60 days'
      WHEN 'at_risk_60_89' THEN
        e.has_visits
        AND NOT coalesce(e.has_upcoming, false)
        AND e.inactive_for > interval '60 days'
        AND e.inactive_for <= interval '90 days'
      WHEN 'at_risk_90_plus' THEN
        e.has_visits
        AND NOT coalesce(e.has_upcoming, false)
        AND e.inactive_for > interval '90 days'
      WHEN 'booked_ahead' THEN coalesce(e.has_upcoming, false)
      WHEN 'gender' THEN
        e.has_visits
        AND (
          (v_filter = 'male' AND e.gender = 'male')
          OR (v_filter = 'female' AND e.gender = 'female')
          OR (v_filter = 'unknown' AND e.gender = 'unknown')
        )
      WHEN 'age_bucket' THEN e.has_visits AND e.age_bucket = v_filter
      WHEN 'city' THEN
        e.has_visits
        AND (
          (v_filter = 'unknown' AND e.city_id IS NULL)
          OR (v_filter <> 'unknown' AND e.city_id IS NOT DISTINCT FROM v_city_id)
        )
      ELSE false
    END
  ),
  summary AS (
    SELECT
      count(*)::bigint AS total_count,
      coalesce(bool_or(revenue_is_estimated), false) AS contains_estimated_prices
    FROM segmented
  ),
  ordered AS (
    SELECT
      s.*,
      row_number() OVER (
        ORDER BY
          CASE
            WHEN v_segment IN ('at_risk_30_59', 'at_risk_60_89', 'at_risk_90_plus')
              THEN extract(epoch FROM s.last_completed_visit_at)
            WHEN v_segment = 'booked_ahead'
              THEN extract(epoch FROM s.next_appointment_at)
            WHEN v_segment = 'repeat'
              THEN (-s.lifetime_completed)::double precision
            ELSE (-extract(epoch FROM s.last_completed_visit_at))
          END ASC NULLS LAST,
          CASE
            WHEN v_segment = 'repeat'
              THEN (-extract(epoch FROM s.last_completed_visit_at))
            ELSE 0::double precision
          END ASC NULLS LAST,
          s.analytics_customer_key ASC
      ) AS rn
    FROM segmented s
  ),
  paged AS (
    SELECT *
    FROM ordered
    WHERE rn > v_offset
      AND rn <= v_offset + v_limit
  ),
  customer_json AS (
    SELECT coalesce(
      jsonb_agg(
        jsonb_build_object(
          'analytics_customer_key', p.analytics_customer_key,
          'customer_number', p.customer_number,
          'display_name', p.display_name,
          'phone', p.phone,
          'email', p.email,
          'identity_type', p.identity_type,
          'is_vip', p.is_vip,
          'first_completed_visit_at', p.first_completed_visit_at,
          'last_completed_visit_at', p.last_completed_visit_at,
          'completed_visits_lifetime', p.lifetime_completed,
          'completed_visits_period', p.period_completed,
          'completed_revenue_lifetime', p.completed_revenue_lifetime,
          'completed_revenue_period', p.completed_revenue_period,
          'revenue_is_estimated', p.revenue_is_estimated,
          'has_upcoming_appointment', coalesce(p.has_upcoming, false),
          'next_appointment_at', p.next_appointment_at,
          'next_service_name', p.next_service_name,
          'days_since_last_visit', p.days_since_last_visit,
          'gender', p.gender,
          'age_bucket', p.age_bucket,
          'city_id', p.city_id,
          'city_name', p.city_name,
          'country_code', p.country_code
        )
        ORDER BY p.rn
      ),
      '[]'::jsonb
    ) AS customers
    FROM paged p
  )
  SELECT jsonb_build_object(
    'ok', true,
    'segment', jsonb_build_object(
      'type', v_segment,
      'filter_value', CASE
        WHEN v_segment IN ('gender', 'age_bucket', 'city') THEN v_filter
        ELSE NULL
      END
    ),
    'period', jsonb_build_object(
      'from_date', p_from_date,
      'to_date', p_to_date,
      'timezone', v_timezone,
      'report_now', v_report_now
    ),
    'summary', jsonb_build_object(
      'total_count', sm.total_count,
      'contains_estimated_prices', sm.contains_estimated_prices
    ),
    'pagination', jsonb_build_object(
      'limit', v_limit,
      'offset', v_offset,
      'has_more', (v_offset + v_limit) < sm.total_count
    ),
    'customers', cj.customers
  )
  INTO v_result
  FROM summary sm
  CROSS JOIN customer_json cj;

  RETURN v_result;
END;
$fn$;

-- get_business_performance_report(uuid,date,date): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_performance_report(p_business_id uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_timezone text;
  v_report_now timestamptz;
  v_from_text text;
  v_to_text text;
  v_result jsonb;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
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
$fn$;

-- get_business_service_analytics(uuid,date,date): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_service_analytics(p_business_id uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
  IF NOT public._can_read_business(p_business_id) THEN
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
  FROM public._service_analytics_comparison_windows(
    p_from_date,
    p_to_date,
    v_today,
    nullif(current_setting('xbook.analytics_period_kind', true), '')
  ) w;

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
$fn$;

-- get_business_staff_analytics(uuid,date,date): owner check → owner or Full Business View reader (body unchanged)
CREATE OR REPLACE FUNCTION public.get_business_staff_analytics(p_business_id uuid, p_from_date date, p_to_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
  IF NOT public._can_read_business(p_business_id) THEN
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
  FROM public._service_analytics_comparison_windows(
    p_from_date,
    p_to_date,
    v_today,
    nullif(current_setting('xbook.analytics_period_kind', true), '')
  ) w;

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
$fn$;

-- _resolve_business_customer_for_crm_action: owner-only when creating (p_ensure), readers may look up
CREATE OR REPLACE FUNCTION public._resolve_business_customer_for_crm_action(p_business_id uuid, p_customer_key text, p_ensure boolean DEFAULT false)
 RETURNS business_customers
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_raw text := nullif(btrim(coalesce(p_customer_key, '')), '');
  v_resolved text;
  v_uid uuid;
  v_row public.business_customers%ROWTYPE;
BEGIN
  -- Creating a customer row stays owner-only; plain lookups also for Full Business View readers.
  IF coalesce(p_ensure, false) THEN
    PERFORM public._crm_action_require_owner(p_business_id);
  ELSIF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  IF v_raw IS NULL THEN
    RETURN NULL;
  END IF;

  v_resolved := public._resolve_business_analytics_customer_key(p_business_id, v_raw);
  IF v_resolved IS NULL OR btrim(v_resolved) = '' THEN
    RETURN NULL;
  END IF;

  IF left(v_resolved, 2) = 'u:' THEN
    BEGIN
      v_uid := substr(v_resolved, 3)::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RETURN NULL;
    END;

    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = v_uid
    ORDER BY bc.created_at ASC, bc.id ASC
    LIMIT 1;

    -- Never fabricate an auth membership or a u: client_key via guest ensure.
    RETURN v_row;
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.client_key = v_resolved
  ORDER BY bc.created_at ASC, bc.id ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  IF coalesce(p_ensure, false) THEN
    RETURN public._ensure_guest_business_customer_from_key(p_business_id, v_resolved);
  END IF;

  RETURN NULL;
END;
$fn$;

-- get_business_customer_internal_notes(uuid,text): read-only, owner or Full Business View reader
CREATE OR REPLACE FUNCTION public.get_business_customer_internal_notes(p_business_id uuid, p_customer_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_row public.business_customers%ROWTYPE;
  v_note text;
  v_updated_at timestamptz;
BEGIN
  IF NOT public._can_read_business(p_business_id) THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  v_row := public._resolve_business_customer_for_crm_action(
    p_business_id, p_customer_key, false
  );

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'note', NULL,
      'updated_at', NULL
    );
  END IF;

  SELECT n.note, n.updated_at
  INTO v_note, v_updated_at
  FROM public.business_customer_internal_notes n
  WHERE n.business_id = p_business_id
    AND n.business_customer_id = v_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'business_customer_id', v_row.id,
    'note', v_note,
    'updated_at', v_updated_at
  );
END;
$fn$;

-- list_staff_time_off(uuid): owner, or Full Business View reader of their business
CREATE OR REPLACE FUNCTION public.list_staff_time_off(p_staff_id uuid DEFAULT NULL::uuid)
 RETURNS SETOF staff_time_off
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_business_id uuid;
BEGIN
  v_business_id := public._readable_business_id();
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Only the business owner can view time off.' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT t.*
  FROM public.staff_time_off t
  WHERE t.business_id = v_business_id
    AND (p_staff_id IS NULL OR t.staff_id = p_staff_id)
  ORDER BY t.date_from ASC, t.date_to ASC, t.created_at ASC;
END;
$fn$;

-- _staff_can_see_booking: 'full' sees every appointment like 'all'
CREATE OR REPLACE FUNCTION public._staff_can_see_booking(p_staff staff_members, p_booking_staff uuid)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN p_staff.id IS NULL THEN false
    WHEN p_staff.access_scope IN ('all', 'full') THEN true
    ELSE p_booking_staff IS NOT DISTINCT FROM p_staff.id
  END;
$fn$;

-- _enqueue_staff_booking_push: pushes for 'full' as for 'all' (unchanged otherwise)
CREATE OR REPLACE FUNCTION public._enqueue_staff_booking_push()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_new_active    boolean;
  v_old_active    boolean := false;
  v_is_new        boolean := false;
  v_cancelled     boolean := false;
  v_staff_changed boolean := false;
  v_moved         boolean := false;
  v_slot_old      text := '';
  v_slot_new      text;
  v_type          text;
  v_key           text;
  v_payload       jsonb;
  v_staff         public.staff_members;
BEGIN
  BEGIN
    v_new_active := public._booking_active_status(coalesce(NEW.booking_status::text, NEW.status::text));
    IF TG_OP = 'INSERT' THEN
      v_is_new := v_new_active;
    ELSE
      v_old_active := public._booking_active_status(coalesce(OLD.booking_status::text, OLD.status::text));
      v_is_new := v_new_active AND NOT v_old_active;                  -- re-activated
      v_cancelled := v_old_active AND NOT v_new_active;
      v_staff_changed := v_new_active AND v_old_active AND NEW.staff_id IS DISTINCT FROM OLD.staff_id;
      v_moved := v_new_active AND v_old_active AND (
        NEW.date IS DISTINCT FROM OLD.date OR NEW.time IS DISTINCT FROM OLD.time
        OR NEW.duration_minutes IS DISTINCT FROM OLD.duration_minutes);
      v_slot_old := left(trim(OLD.date::text), 10) || 'T' || left(trim(OLD.time::text), 5);
    END IF;

    IF NOT (v_is_new OR v_cancelled OR v_staff_changed OR v_moved) THEN
      RETURN NULL;
    END IF;

    v_slot_new := left(trim(NEW.date::text), 10) || 'T' || left(trim(NEW.time::text), 5);
    v_payload := jsonb_build_object(
      'date', left(trim(NEW.date::text), 10),
      'time', left(trim(NEW.time::text), 5),
      'duration', coalesce(nullif(NEW.duration_minutes, 0), 30),
      'service', coalesce(nullif(trim(NEW.service_name), ''), nullif(trim(NEW.service), ''), ''),
      'staff_name', coalesce((SELECT sm.name FROM public.staff_members sm WHERE sm.id = NEW.staff_id), ''),
      'recurring', NEW.recurring_group_id IS NOT NULL
    );
    IF TG_OP = 'UPDATE' THEN
      v_payload := v_payload || jsonb_build_object(
        'old_date', left(trim(OLD.date::text), 10),
        'old_time', left(trim(OLD.time::text), 5));
    END IF;

    FOR v_staff IN
      SELECT sm.* FROM public.staff_members sm
      WHERE sm.business_id = NEW.business_id
        AND sm.access_enabled = true
        AND sm.access_user_id IS NOT NULL
        AND coalesce(sm.active, true) = true
    LOOP
      v_type := NULL;
      IF v_is_new THEN
        IF public._staff_can_see_booking(v_staff, NEW.staff_id) THEN v_type := 'new'; END IF;
      ELSIF v_cancelled THEN
        IF public._staff_can_see_booking(v_staff, OLD.staff_id) OR public._staff_can_see_booking(v_staff, NEW.staff_id) THEN
          v_type := 'cancelled';
        END IF;
      ELSIF v_staff_changed THEN
        IF v_staff.id = NEW.staff_id THEN v_type := 'assigned';
        ELSIF v_staff.id IS NOT DISTINCT FROM OLD.staff_id THEN v_type := 'unassigned';
        ELSIF v_staff.access_scope IN ('all', 'full') THEN v_type := 'reassigned';
        END IF;
      ELSIF v_moved THEN
        IF public._staff_can_see_booking(v_staff, NEW.staff_id) THEN v_type := 'rescheduled'; END IF;
      END IF;

      CONTINUE WHEN v_type IS NULL;

      -- Recurring series: one push per recipient, type and transaction.
      IF NEW.recurring_group_id IS NOT NULL THEN
        v_key := 'series:' || NEW.recurring_group_id || ':' || v_type || ':tx' || txid_current();
      ELSE
        v_key := 'booking:' || NEW.id || ':' || v_type || ':' || v_slot_old || '>' || v_slot_new
                 || ':' || coalesce(NEW.staff_id::text, '-');
      END IF;

      INSERT INTO public.staff_push_events (business_id, booking_id, staff_id, event_type, dedupe_key, payload)
      VALUES (NEW.business_id, NEW.id, v_staff.id, v_type, v_key, v_payload)
      ON CONFLICT (staff_id, dedupe_key) DO NOTHING;
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'staff push enqueue skipped: %', SQLERRM;
  END;
  RETURN NULL;
END;
$fn$;

-- _set_staff_access_scope_core: accepts 'full' (owner / platform admin only, unchanged callers)
CREATE OR REPLACE FUNCTION public._set_staff_access_scope_core(p_business_id uuid, p_staff_id uuid, p_scope text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
DECLARE
  v_scope text := lower(trim(coalesce(p_scope, '')));
BEGIN
  IF v_scope NOT IN ('own', 'all', 'full') THEN
    RAISE EXCEPTION 'Invalid access setting.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.staff_members SET access_scope = v_scope
  WHERE id = p_staff_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('ok', true, 'scope', v_scope);
END;
$fn$;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- UPDATE public.staff_members SET access_scope = 'all' WHERE access_scope = 'full';
-- -- DROP POLICY IF EXISTS business_settings_full_view_select ON public.business_settings;
-- DROP POLICY IF EXISTS services_full_view_select ON public.services;
-- DROP POLICY IF EXISTS staff_members_full_view_select ON public.staff_members;
-- DROP POLICY IF EXISTS bookings_full_view_select ON public.bookings;
-- DROP POLICY IF EXISTS business_customers_full_view_select ON public.business_customers;
-- DROP POLICY IF EXISTS business_customer_counters_full_view_select ON public.business_customer_counters;
-- DROP POLICY IF EXISTS blocked_days_full_view_select ON public.blocked_days;
-- DROP POLICY IF EXISTS business_closed_days_full_view_select ON public.business_closed_days;
-- DROP POLICY IF EXISTS staff_services_full_view_select ON public.staff_services;
-- DROP POLICY IF EXISTS staff_working_hours_full_view_select ON public.staff_working_hours;
-- DROP POLICY IF EXISTS staff_time_off_full_view_select ON public.staff_time_off;
-- re-apply the previous definitions from backups/<date>-before-staff-full-view/public-schema.sql
-- ALTER TABLE public.staff_members DROP CONSTRAINT IF EXISTS staff_members_access_scope_ok;
-- ALTER TABLE public.staff_members ADD CONSTRAINT staff_members_access_scope_ok CHECK (access_scope = ANY (ARRAY['own','all']));
-- COMMIT;
