-- =============================================================================
-- XBOOK Phase 2A: Canonical Customer Analytics overview RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public._analytics_customer_key(uuid, text, text, text)
--   public.get_business_customer_analytics_overview(uuid, date, date) → jsonb
--
-- Reuses live:
--   public._performance_appointment_start
--   public._booking_client_key
--   public._business_analytics_customer_keys
--   Canonical completed-visit / price CASE from Phase 1A Performance
--
-- total_customers = canonical population:
--   approved CRM keys UNION this-business booking keys
--   (rejected/pending/blocked CRM-only with no booking history excluded)
--
-- Does NOT:
--   fuzzy-merge auth and guest identities (explicit identity links only)
--   change get_business_performance_report visit/revenue math
--   change RLS, booking create/status/price snapshot, Complete Profile
--   add UI, expose raw private profiles, or add speculative indexes
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Identity helper (same hierarchy as Performance RPC; Performance body untouched)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._analytics_customer_key(
  p_customer_user_id uuid,
  p_phone text,
  p_email text,
  p_name text
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_customer_user_id IS NOT NULL THEN 'u:' || p_customer_user_id::text
    ELSE public._booking_client_key(p_phone, p_email, p_name)
  END;
$$;

COMMENT ON FUNCTION public._analytics_customer_key(uuid, text, text, text) IS
  'V1 analytics identity: u:{user_id} if authenticated, else _booking_client_key. NULL if unidentified. Does not fuzzy-merge guests into auth users.';

REVOKE ALL ON FUNCTION public._analytics_customer_key(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._analytics_customer_key(uuid, text, text, text) FROM anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Owner-only Customer Analytics overview
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_customer_analytics_overview(
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
$$;

COMMENT ON FUNCTION public.get_business_customer_analytics_overview(uuid, date, date) IS
  'Owner-only Customer Analytics overview. total_customers = approved CRM UNION this-business booking keys via _business_analytics_customer_keys after explicit identity-link resolution. Visit KPIs remain completed-visit based. Aggregate demographics only.';

REVOKE ALL ON FUNCTION public.get_business_customer_analytics_overview(uuid, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_customer_analytics_overview(uuid, date, date) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_customer_analytics_overview(uuid, date, date) TO authenticated;

COMMIT;
