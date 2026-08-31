-- =============================================================================
-- XBOOK Phase 2E: Tenant-safe read-only Customer Detail RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Requires (already live):
--   public._performance_appointment_start
--   public._booking_client_key
--   public._analytics_customer_key
--   public._business_analytics_customer_keys
--
-- Adds:
--   public.get_business_customer_detail(
--     uuid, text, integer, integer
--   ) → jsonb
--
-- Does NOT:
--   change get_business_customer_analytics_overview
--   change get_business_customer_segment
--   change get_business_performance_report visit/revenue math
--   change RLS, booking create/status/price snapshot, Complete Profile
--   add editing, delete, merge, campaigns, or speculative indexes
--
-- Identity / completed visit / price / CRM / demographics:
--   Same canonical rules as Customer Overview + Segment RPCs.
--   Lookup is by analytics_customer_key only, and only if the key is in
--   _business_analytics_customer_keys for this business:
--     approved CRM member (including zero bookings)
--     OR this-business booking identity
--   Rejected/pending/blocked CRM-only with no booking history → not_found.
--   Age is as of the business-local current date (lifetime / current-state).
--   Never returns DOB, customer_user_id, manage_token, or booking_ref.
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_business_customer_detail(uuid, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_business_customer_detail(
  p_business_id uuid,
  p_customer_key text,
  p_history_limit integer DEFAULT 25,
  p_history_offset integer DEFAULT 0
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
  v_age_as_of date;
  v_key text;
  v_profile_user_id uuid;
  v_limit integer;
  v_offset integer;
  v_exists boolean;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
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
$$;

COMMENT ON FUNCTION public.get_business_customer_detail(uuid, text, integer, integer) IS
  'Owner-only read-only Customer Detail. Resolves only canonical analytics keys (approved CRM or this-business booking identity). Rejected/pending/blocked CRM-only with no bookings → not_found.';

REVOKE ALL ON FUNCTION public.get_business_customer_detail(uuid, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_customer_detail(uuid, text, integer, integer) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_customer_detail(uuid, text, integer, integer) TO authenticated;

COMMIT;
