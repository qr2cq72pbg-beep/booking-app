-- =============================================================================
-- XBOOK Phase 2C: Tenant-safe Customer Segment / Drill-down RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Requires (already live):
--   public._performance_appointment_start
--   public._booking_client_key
--   public._analytics_customer_key
--
-- Adds:
--   public.get_business_customer_segment(
--     uuid, text, date, date, text, integer, integer
--   ) → jsonb
--
-- Does NOT:
--   change get_business_customer_analytics_overview
--   change get_business_performance_report
--   change RLS, booking create/status/price snapshot, Complete Profile
--   add UI, expose raw DOB, or add speculative indexes
--
-- CRM join (deterministic, no analytics double-count):
--   Analytics identity remains _analytics_customer_key (bookings grouping).
--   Visit segments stay booking-identity-driven; they do not include
--   approved CRM-only members with zero visits.
--   Canonical Total Customers population lives in
--   public._business_analytics_customer_keys (Overview / Detail).
--   Auth identity  → UNIQUE (business_id, customer_user_id), LIMIT 1
--                    ordered by created_at, id. Never match guest CRM by
--                    phone/email (that would auto-merge).
--   Guest identity → UNIQUE (business_id, client_key) exact match, LIMIT 1
--                    ordered by created_at, id.
--   If no CRM row: contact fields come from the most recent booking snapshot
--   that has that field. NULL if unavailable. Display name is never invented.
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_business_customer_segment(uuid, text, date, date, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_business_customer_segment(
  p_business_id uuid,
  p_segment text,
  p_from_date date,
  p_to_date date,
  p_filter_value text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
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
  v_segment text;
  v_filter text;
  v_city_id uuid;
  v_limit integer;
  v_offset integer;
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
$$;

COMMENT ON FUNCTION public.get_business_customer_segment(uuid, text, date, date, text, integer, integer) IS
  'Owner-only Customer Analytics V1 segment drill-down. Allowlisted segments only. Reuses overview identity / completed-visit / timezone / price rules. Returns CRM-safe contact fields; never raw DOB or private profile rows.';

REVOKE ALL ON FUNCTION public.get_business_customer_segment(uuid, text, date, date, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_customer_segment(uuid, text, date, date, text, integer, integer) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_customer_segment(uuid, text, date, date, text, integer, integer) TO authenticated;

COMMIT;
