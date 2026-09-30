-- Data Quality exact-record drill-down contract tests.
-- Throwaway prefixed rows only. Does not change aggregate Analytics formulas.

CREATE TEMP TABLE IF NOT EXISTS _xbook_qrec_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_qrec_results;

CREATE OR REPLACE FUNCTION pg_temp._qrec_has_forbidden_key(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_key text;
  v_val jsonb;
  v_forbidden text[] := ARRAY['manage_token'];
BEGIN
  IF p IS NULL THEN
    RETURN false;
  END IF;
  IF jsonb_typeof(p) = 'object' THEN
    FOR v_key, v_val IN SELECT * FROM jsonb_each(p)
    LOOP
      IF lower(v_key) = ANY (v_forbidden) THEN
        RETURN true;
      END IF;
      IF pg_temp._qrec_has_forbidden_key(v_val) THEN
        RETURN true;
      END IF;
    END LOOP;
  ELSIF jsonb_typeof(p) = 'array' THEN
    FOR v_val IN SELECT jsonb_array_elements(p)
    LOOP
      IF pg_temp._qrec_has_forbidden_key(v_val) THEN
        RETURN true;
      END IF;
    END LOOP;
  END IF;
  RETURN false;
END;
$$;

DO $$
DECLARE
  v_biz_a uuid;
  v_biz_b uuid;
  v_tz text;
  v_from date;
  v_to date;
  v_local_now timestamp;
  v_yesterday date;
  v_svc uuid;
  v_staff uuid;
  v_perf jsonb;
  v_ins jsonb;
  v_est jsonb;
  v_una jsonb;
  v_anon_ok boolean := false;
  v_cross_ok boolean := false;
  v_msg text := '';
  v_i int;
BEGIN
  SELECT bs.business_id, bs.timezone
  INTO v_biz_a, v_tz
  FROM public.business_settings bs
  WHERE nullif(trim(bs.timezone), '') IS NOT NULL
    AND coalesce(bs.require_client_approval, false) = false
  ORDER BY (
    SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id
  ) DESC
  LIMIT 1;

  SELECT bs.business_id
  INTO v_biz_b
  FROM public.business_settings bs
  WHERE bs.business_id IS DISTINCT FROM v_biz_a
  LIMIT 1;

  IF v_biz_a IS NULL OR v_biz_b IS NULL THEN
    RAISE EXCEPTION 'Need two businesses for quality-records tests';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := (v_local_now::date - 1);
  v_from := v_yesterday;
  v_to := v_yesterday;

  DELETE FROM public.bookings WHERE customer_name LIKE 'XBOOK_QREC_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_QREC_%';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_QREC_SVC', 30, 500)
  RETURNING id INTO v_svc;

  SELECT sm.id INTO v_staff
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_a
  ORDER BY sm.id
  LIMIT 1;

  FOR v_i IN 1..3 LOOP
    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_a, v_svc, 'XBOOK_QREC_SVC', v_staff,
      to_char(v_yesterday, 'YYYY-MM-DD'), '10:0' || v_i, 30,
      'XBOOK_QREC_EST' || v_i, '+38970007710' || v_i, 'Confirmed', NULL,
      'XQREC-E' || v_i, gen_random_uuid()::text
    );
  END LOOP;

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_QREC_SVC', NULL,
    to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
    'XBOOK_QREC_UNA1', '+389700077201', 'Confirmed', 200,
    'XQREC-U1', gen_random_uuid()::text
  );

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_QREC_SVC', v_staff,
    to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
    'XBOOK_QREC_CAN', '+389700077202', 'Cancelled', NULL,
    'XQREC-C1', gen_random_uuid()::text
  );

  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  BEGIN
    PERFORM public.get_business_analytics_quality_records(v_biz_a, v_from, v_to, 'estimated');
  EXCEPTION WHEN insufficient_privilege THEN
    v_anon_ok := true;
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_anon_ok := v_msg ILIKE '%not authorized%';
  END;
  INSERT INTO _xbook_qrec_results VALUES (
    'unauthenticated_denied',
    v_anon_ok,
    v_msg
  );

  PERFORM set_config('request.jwt.claim.sub', v_biz_b::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_b::text, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    PERFORM public.get_business_analytics_quality_records(v_biz_a, v_from, v_to, 'estimated');
  EXCEPTION WHEN insufficient_privilege THEN
    v_cross_ok := true;
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    v_cross_ok := v_msg ILIKE '%not authorized%';
  END;
  INSERT INTO _xbook_qrec_results VALUES (
    'other_business_denied',
    v_cross_ok,
    v_msg
  );

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_perf := public.get_business_performance_report(v_biz_a, v_from, v_to);
  v_ins := public.get_business_actionable_insights(v_biz_a, v_from, v_to);
  v_est := public.get_business_analytics_quality_records(v_biz_a, v_from, v_to, 'estimated');
  v_una := public.get_business_analytics_quality_records(v_biz_a, v_from, v_to, 'unassigned');

  INSERT INTO _xbook_qrec_results VALUES (
    'estimated_count_matches_performance',
    (v_est->>'count')::bigint = (v_perf->'quality'->>'estimated_price_count')::bigint
      AND (v_est->>'count')::bigint >= 3
      AND jsonb_array_length(v_est->'records') = (v_est->>'count')::int,
    format('detail=%s perf=%s', v_est->>'count', v_perf->'quality'->>'estimated_price_count')
  );

  INSERT INTO _xbook_qrec_results VALUES (
    'estimated_three_exact_records',
    (
      SELECT count(*)
      FROM jsonb_array_elements(v_est->'records') e
      WHERE e->>'customer_name' LIKE 'XBOOK_QREC_EST%'
    ) = 3
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_est->'records') e
      WHERE e->>'customer_name' = 'XBOOK_QREC_CAN'
    ),
    v_est->'records'
  );

  INSERT INTO _xbook_qrec_results VALUES (
    'unassigned_count_matches_insights',
    (v_una->>'count')::bigint = (v_ins->'quality'->>'unassigned_completed_visits')::bigint
      AND (
        SELECT count(*)
        FROM jsonb_array_elements(v_una->'records') e
        WHERE e->>'customer_name' = 'XBOOK_QREC_UNA1'
      ) = 1,
    format('detail=%s insights=%s', v_una->>'count', v_ins->'quality'->>'unassigned_completed_visits')
  );

  INSERT INTO _xbook_qrec_results VALUES (
    'manage_token_absent',
    NOT pg_temp._qrec_has_forbidden_key(v_est)
      AND NOT pg_temp._qrec_has_forbidden_key(v_una),
    'token scan'
  );

  INSERT INTO _xbook_qrec_results VALUES (
    'estimated_uses_catalog_price',
    EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_est->'records') e
      WHERE e->>'customer_name' LIKE 'XBOOK_QREC_EST%'
        AND e->>'price_source' = 'estimated'
        AND (e->>'price')::numeric = 500
    ),
    v_est->'records'
  );

  DELETE FROM public.bookings WHERE customer_name LIKE 'XBOOK_QREC_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_QREC_%';
END;
$$;

DO $$
DECLARE
  v_live uuid;
  v_from date := date_trunc('month', now())::date;
  v_to date := (date_trunc('month', now()) + interval '1 month - 1 day')::date;
  v_perf jsonb;
  v_ins jsonb;
  v_est jsonb;
  v_una jsonb;
BEGIN
  SELECT bs.business_id
  INTO v_live
  FROM public.business_settings bs
  WHERE nullif(trim(bs.timezone), '') IS NOT NULL
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) DESC
  LIMIT 1;

  IF v_live IS NULL THEN
    INSERT INTO _xbook_qrec_results VALUES ('live_month_reconciliation', false, 'no live business');
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_live::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_live::text, 'role', 'authenticated')::text,
    true
  );

  v_perf := public.get_business_performance_report(v_live, v_from, v_to);
  v_ins := public.get_business_actionable_insights(v_live, v_from, v_to);
  v_est := public.get_business_analytics_quality_records(v_live, v_from, v_to, 'estimated');
  v_una := public.get_business_analytics_quality_records(v_live, v_from, v_to, 'unassigned');

  INSERT INTO _xbook_qrec_results VALUES (
    'live_month_estimated_reconciles',
    (v_est->>'count')::bigint = (v_perf->'quality'->>'estimated_price_count')::bigint
      AND jsonb_array_length(v_est->'records') = (v_est->>'count')::int
      AND NOT pg_temp._qrec_has_forbidden_key(v_est),
    format('detail=%s perf=%s', v_est->>'count', v_perf->'quality'->>'estimated_price_count')
  );

  INSERT INTO _xbook_qrec_results VALUES (
    'live_month_unassigned_reconciles',
    (v_una->>'count')::bigint = (v_ins->'quality'->>'unassigned_completed_visits')::bigint
      AND jsonb_array_length(v_una->'records') = (v_una->>'count')::int
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_una->'records') e
        WHERE e->>'staff_id' IS NOT NULL
      )
      AND NOT pg_temp._qrec_has_forbidden_key(v_una),
    format('detail=%s insights=%s', v_una->>'count', v_ins->'quality'->>'unassigned_completed_visits')
  );
END;
$$;

SELECT test_name, passed, left(coalesce(detail, ''), 180) AS detail
FROM _xbook_qrec_results
ORDER BY test_name;

SELECT
  CASE WHEN bool_and(passed) THEN 'ALL_QUALITY_RECORDS_TESTS_PASSED'
       ELSE 'QUALITY_RECORDS_TESTS_FAILED'
  END AS summary,
  count(*) FILTER (WHERE passed) AS passed,
  count(*) FILTER (WHERE NOT passed) AS failed
FROM _xbook_qrec_results;
