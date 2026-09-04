-- =============================================================================
-- XBOOK Phase 7B: Canonical Cross Analytics RPC
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (DROP IF EXISTS + CREATE OR REPLACE).
--
-- Adds:
--   public.get_business_cross_analytics(
--     uuid, date, date, jsonb, text, integer, integer
--   ) → jsonb
--
-- Reuses live (bodies untouched):
--   public._performance_appointment_start
--   public._analytics_customer_key
--   public._resolve_business_analytics_customer_key
--   public._business_analytics_customer_keys
--   Canonical completed-visit / price CASE from Phase 1A Performance
--   Canonical service group_key from Performance / Service Analytics
--   CRM attach semantics of _resolve_business_customer_for_crm_action
--     (resolve key, then auth row by customer_user_id else guest client_key;
--      prefer auth membership when a linked guest CRM row collapses to u:{uid})
--
-- Does NOT:
--   change existing analytics RPCs or formulas
--   add indexes, matviews, saved segments, campaigns, or UI
--   fuzzy-merge identities
--   expose DOB / private-profile rows / auth user ids
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_business_cross_analytics(uuid, date, date, jsonb, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_business_cross_analytics(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_filters jsonb DEFAULT '{}'::jsonb,
  p_sort text DEFAULT 'last_visit_desc',
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
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
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
$$;

COMMENT ON FUNCTION public.get_business_cross_analytics(uuid, date, date, jsonb, text, integer, integer) IS
  'Owner-only Cross Analytics V1. Canonical population via _business_analytics_customer_keys. Whitelisted jsonb filters, AND across dimensions / OR within multi-select. Completed visit / price / identity / timezone match existing analytics. CRM attach follows identity-link resolution (auth membership preferred).';

REVOKE ALL ON FUNCTION public.get_business_cross_analytics(uuid, date, date, jsonb, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_cross_analytics(uuid, date, date, jsonb, text, integer, integer) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_cross_analytics(uuid, date, date, jsonb, text, integer, integer) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
