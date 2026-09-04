-- Read-only EXPLAIN / timing for Phase 7B. No schema changes. No leftover rows.
-- Uses live Test Barber owner JWT.

CREATE TEMP TABLE _xbook_ca7b_explain (
  case_name text PRIMARY KEY,
  elapsed_ms numeric,
  matched_customers bigint,
  plan_ms numeric,
  notes text
);

DO $$
DECLARE
  v_biz uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  v_from date := DATE '2026-08-01';
  v_to date := DATE '2026-08-31';
  v_svc uuid;
  v_staff uuid;
  t0 timestamptz;
  t1 timestamptz;
  v_payload jsonb;
  v_plan_ms numeric;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_biz::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz::text, 'role', 'authenticated')::text,
    true
  );

  SELECT s.id INTO v_svc
  FROM public.services s
  WHERE s.business_id = v_biz
  ORDER BY s.id
  LIMIT 1;

  SELECT sm.id INTO v_staff
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz
  ORDER BY sm.id
  LIMIT 1;

  t0 := clock_timestamp();
  v_payload := public.get_business_cross_analytics(v_biz, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0);
  t1 := clock_timestamp();
  INSERT INTO _xbook_ca7b_explain VALUES (
    'empty_filters',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    (v_payload->'summary'->>'matched_customers')::bigint,
    NULL,
    'default last_visit_desc limit 50'
  );

  t0 := clock_timestamp();
  v_payload := public.get_business_cross_analytics(
    v_biz, v_from, v_to,
    '{"is_vip":true,"has_future_booking":false}'::jsonb,
    'last_visit_desc', 50, 0
  );
  t1 := clock_timestamp();
  INSERT INTO _xbook_ca7b_explain VALUES (
    'vip_no_future',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    (v_payload->'summary'->>'matched_customers')::bigint,
    NULL,
    NULL
  );

  IF v_svc IS NOT NULL THEN
    t0 := clock_timestamp();
    v_payload := public.get_business_cross_analytics(
      v_biz, v_from, v_to,
      jsonb_build_object('service_ids', jsonb_build_array(v_svc::text), 'service_match', 'any'),
      'last_visit_desc', 50, 0
    );
    t1 := clock_timestamp();
    INSERT INTO _xbook_ca7b_explain VALUES (
      'service_any',
      round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
      (v_payload->'summary'->>'matched_customers')::bigint,
      NULL,
      v_svc::text
    );

    t0 := clock_timestamp();
    v_payload := public.get_business_cross_analytics(
      v_biz, v_from, v_to,
      jsonb_build_object('service_ids', jsonb_build_array(v_svc::text), 'service_match', 'none'),
      'last_visit_desc', 50, 0
    );
    t1 := clock_timestamp();
    INSERT INTO _xbook_ca7b_explain VALUES (
      'service_none',
      round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
      (v_payload->'summary'->>'matched_customers')::bigint,
      NULL,
      v_svc::text
    );
  END IF;

  IF v_staff IS NOT NULL THEN
    t0 := clock_timestamp();
    v_payload := public.get_business_cross_analytics(
      v_biz, v_from, v_to,
      jsonb_build_object('staff_ids', jsonb_build_array(v_staff::text), 'staff_match', 'any'),
      'last_visit_desc', 50, 0
    );
    t1 := clock_timestamp();
    INSERT INTO _xbook_ca7b_explain VALUES (
      'staff_any',
      round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
      (v_payload->'summary'->>'matched_customers')::bigint,
      NULL,
      v_staff::text
    );
  END IF;

  t0 := clock_timestamp();
  v_payload := public.get_business_cross_analytics(
    v_biz, v_from, v_to,
    jsonb_build_object(
      'gender', jsonb_build_array('unknown'),
      'visit_frequency', 'single',
      'has_future_booking', false,
      'lifetime_visits_min', 1,
      'is_vip', false
    ),
    'last_visit_desc', 50, 0
  );
  t1 := clock_timestamp();
  INSERT INTO _xbook_ca7b_explain VALUES (
    'combined_5_filter',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    (v_payload->'summary'->>'matched_customers')::bigint,
    NULL,
    'gender unknown + single + no future + lifetime_visits_min 1 + not vip'
  );

  t0 := clock_timestamp();
  v_payload := public.get_business_cross_analytics(
    v_biz, v_from, v_to, '{}'::jsonb, 'lifetime_revenue_desc', 50, 0
  );
  t1 := clock_timestamp();
  INSERT INTO _xbook_ca7b_explain VALUES (
    'sort_lifetime_revenue_desc',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    (v_payload->'summary'->>'matched_customers')::bigint,
    NULL,
    NULL
  );
END;
$$;

SELECT case_name, elapsed_ms, matched_customers, notes
FROM _xbook_ca7b_explain
ORDER BY case_name;
