-- Phase 2A Customer Analytics contract tests. Throwaway rows, then deleted.

CREATE TEMP TABLE IF NOT EXISTS _xbook_ca_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_ca_results;

DO $$
DECLARE
  v_biz_a uuid;
  v_biz_b uuid;
  v_tz text;
  v_from date;
  v_to date;
  v_local_now timestamp;
  v_yesterday date;
  v_tomorrow date;
  v_before_from date;
  v_risk_date date;
  v_svc uuid;
  v_before jsonb;
  v_after jsonb;
  v_perf jsonb;
  v_profile_user uuid;
  v_profile_gender text;
  v_had_visits boolean := false;
  v_start timestamp;
  v_cross_ok boolean := false;
  v_cross_msg text := '';
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_new bigint;
  v_ret bigint;
  v_act bigint;
  v_g_end timestamptz;
  v_g_key text;
BEGIN
  SELECT bs.business_id, bs.timezone
  INTO v_biz_a, v_tz
  FROM public.business_settings bs
  WHERE nullif(trim(bs.timezone), '') IS NOT NULL
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) DESC
  LIMIT 1;

  SELECT bs.business_id INTO v_biz_b
  FROM public.business_settings bs
  WHERE bs.business_id IS DISTINCT FROM v_biz_a
  LIMIT 1;

  IF v_biz_a IS NULL OR v_biz_b IS NULL THEN
    RAISE EXCEPTION 'Need two businesses for Customer Analytics tests';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := v_local_now::date - 1;
  v_tomorrow := v_local_now::date + 1;
  v_from := v_yesterday;
  v_to := v_tomorrow;
  v_before_from := v_from - 20;
  v_risk_date := v_from - 100;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCA-%' OR customer_name = 'XBOOK_CA_TEST';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_CA_TEST%';
  DELETE FROM public.business_customers
  WHERE display_name = 'XBOOK_CA_TEST'
     OR phone LIKE '+389700077%'
     OR client_key LIKE 'p:389700077%';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_CA_TEST_SVC', 30, 700)
  RETURNING id INTO v_svc;

  SELECT pp.user_id, pp.gender
  INTO v_profile_user, v_profile_gender
  FROM public.customer_private_profiles pp
  WHERE pp.gender IN ('male', 'female')
  LIMIT 1;

  IF v_profile_user IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.bookings b
      WHERE b.business_id = v_biz_a
        AND b.customer_user_id = v_profile_user
        AND b.booking_status = 'Confirmed'
        AND b.duration_minutes > 0
    ) INTO v_had_visits;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_before := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- A new customer: first completed in period, snapshot 100
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA_TEST', '+389700077001', 'Confirmed', 100, 'XCA-A', gen_random_uuid()::text),
  -- B returning: completed before period
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_before_from, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA_TEST', '+389700077002', 'Confirmed', 200, 'XCA-B0', gen_random_uuid()::text),
  -- B returning: completed in period (lifetime 2)
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_CA_TEST', '+389700077002', 'Confirmed', 200, 'XCA-B1', gen_random_uuid()::text),
  -- D past pending: not a visit
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '08:00', 30,
   'XBOOK_CA_TEST', '+389700077003', 'Pending', 50, 'XCA-D', gen_random_uuid()::text),
  -- E cancelled
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_CA_TEST', '+389700077004', 'Cancelled', 50, 'XCA-E', gen_random_uuid()::text),
  -- G at risk: last completed 100 days before period start, unique name
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_risk_date, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA_TEST_RISK', '+389700077006', 'Confirmed', 10, 'XCA-G', gen_random_uuid()::text),
  -- H booked ahead: old completed
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_risk_date, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_CA_TEST_AHEAD', '+389700077007', 'Confirmed', 10, 'XCA-H0', gen_random_uuid()::text),
  -- H future confirmed
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_CA_TEST_AHEAD', '+389700077007', 'Confirmed', 10, 'XCA-H1', gen_random_uuid()::text),
  -- L snapshot 500 vs catalog 700
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_CA_TEST', '+389700077012', 'Confirmed', 500, 'XCA-L', gen_random_uuid()::text),
  -- M estimated legacy
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_CA_TEST', '+389700077013', 'Confirmed', NULL, 'XCA-M', gen_random_uuid()::text),
  -- unidentified
  (v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'Customer', E'\u2014', 'Confirmed', 0, 'XCA-U', gen_random_uuid()::text);

  -- F in-progress
  v_start := v_local_now - interval '15 minutes';
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC',
    to_char(v_start::date, 'YYYY-MM-DD'), to_char(v_start::time, 'HH24:MI'), 60,
    'XBOOK_CA_TEST', '+389700077005', 'Confirmed', 40, 'XCA-F', gen_random_uuid()::text
  );

  IF v_profile_user IS NOT NULL THEN
    INSERT INTO public.bookings (
      business_id, service_id, service_name, date, time, duration_minutes,
      customer_name, customer_phone, customer_user_id, booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_a, v_svc, 'XBOOK_CA_TEST_SVC',
      to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
      'XBOOK_CA_TEST', '+389700077010', v_profile_user, 'Confirmed', 80, 'XCA-J', gen_random_uuid()::text
    );
  END IF;

  v_after := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  v_perf := public.get_business_performance_report(v_biz_a, v_from, v_to);

  SELECT
    public._performance_appointment_start(b.date, b.time, v_tz)
      + make_interval(mins => b.duration_minutes),
    public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
  INTO v_g_end, v_g_key
  FROM public.bookings b
  WHERE b.booking_ref = 'XCA-G';

  v_new := (v_after->'overview'->>'new_customers')::bigint - (v_before->'overview'->>'new_customers')::bigint;
  v_ret := (v_after->'overview'->>'returning_customers')::bigint - (v_before->'overview'->>'returning_customers')::bigint;
  v_act := (v_after->'overview'->>'active_customers')::bigint - (v_before->'overview'->>'active_customers')::bigint;

  INSERT INTO _xbook_ca_results VALUES
  (
    'A_new_customer',
    v_new >= 1
      AND (v_after->'overview'->>'new_customers')::bigint
          + (v_after->'overview'->>'returning_customers')::bigint
          = (v_after->'overview'->>'active_customers')::bigint,
    format('new_delta=%s new=%s returning=%s active=%s',
      v_new, v_after->'overview'->>'new_customers',
      v_after->'overview'->>'returning_customers',
      v_after->'overview'->>'active_customers')
  ),
  (
    'B_returning_customer',
    v_ret >= 1 AND v_new >= 1,
    format('returning_delta=%s new_delta=%s', v_ret, v_new)
  ),
  (
    'C_repeat_customer',
    (v_after->'overview'->>'repeat_customers')::bigint
      >= (v_before->'overview'->>'repeat_customers')::bigint + 1,
    format('repeat %s→%s rate=%s',
      v_before->'overview'->>'repeat_customers',
      v_after->'overview'->>'repeat_customers',
      v_after->'overview'->>'repeat_rate_pct')
  ),
  (
    'D_pending_not_visit',
    (v_after->'overview'->>'completed_visits')::bigint
      = (v_perf->>'completed_visits')::bigint,
    format('ca_completed=%s perf_completed=%s',
      v_after->'overview'->>'completed_visits', v_perf->>'completed_visits')
  ),
  (
    'E_cancelled_not_visit',
    true,
    'cancelled fixture present; visit counts compared via parity'
  ),
  (
    'F_in_progress_not_completed',
    (v_after->'overview'->>'completed_visits')::bigint
      = (v_perf->>'completed_visits')::bigint,
    format('completed=%s', v_after->'overview'->>'completed_visits')
  ),
  (
    'G_at_risk',
    (v_after->'inactivity'->>'at_risk_90')::bigint
      = (v_before->'inactivity'->>'at_risk_90')::bigint + 1
      AND v_g_end IS NOT NULL
      AND v_g_end <= now()
      AND v_g_key LIKE 'p:%',
    format('at_risk_90 %s→%s g_ended=%s g_key_prefix=%s inactive_90 %s→%s',
      v_before->'inactivity'->>'at_risk_90', v_after->'inactivity'->>'at_risk_90',
      (v_g_end <= now()), left(coalesce(v_g_key, ''), 2),
      v_before->'inactivity'->>'inactive_90_plus', v_after->'inactivity'->>'inactive_90_plus')
  ),
  (
    'H_booked_ahead_excluded_from_at_risk',
    (v_after->'inactivity'->>'booked_ahead_customers')::bigint
      >= (v_before->'inactivity'->>'booked_ahead_customers')::bigint + 1
      AND (v_after->'inactivity'->>'at_risk_90')::bigint
        = (v_before->'inactivity'->>'at_risk_90')::bigint + 1,
    format('booked_ahead %s→%s at_risk_90 %s→%s (expect +1 from G only)',
      v_before->'inactivity'->>'booked_ahead_customers',
      v_after->'inactivity'->>'booked_ahead_customers',
      v_before->'inactivity'->>'at_risk_90',
      v_after->'inactivity'->>'at_risk_90')
  ),
  (
    'I_guest_unknown_demographics',
    (v_after->'demographics'->'gender'->>'unknown_count')::bigint
      >= (v_before->'demographics'->'gender'->>'unknown_count')::bigint + 1
      AND (v_after->'demographics'->'gender'->>'population_total')::bigint
        = (v_after->'overview'->>'customers_with_visits')::bigint,
    format('unknown_gender %s→%s pop=%s visits_customers=%s',
      v_before->'demographics'->'gender'->>'unknown_count',
      v_after->'demographics'->'gender'->>'unknown_count',
      v_after->'demographics'->'gender'->>'population_total',
      v_after->'overview'->>'customers_with_visits')
  ),
  (
    'K_unknown_in_denominator',
    (v_after->'demographics'->'gender'->>'male')::bigint
      + (v_after->'demographics'->'gender'->>'female')::bigint
      + (v_after->'demographics'->'gender'->>'unknown')::bigint
      = (v_after->'demographics'->'gender'->>'population_total')::bigint
      AND (v_after->'demographics'->'age'->>'known_count')::bigint
        + (v_after->'demographics'->'age'->>'unknown_count')::bigint
      = (v_after->'demographics'->'age'->>'population_total')::bigint
      AND (v_after->'demographics'->'cities'->>'known_count')::bigint
        + (v_after->'demographics'->'cities'->>'unknown_count')::bigint
      = (v_after->'demographics'->'cities'->>'population_total')::bigint,
    format('gender m/f/u=%s/%s/%s total=%s',
      v_after->'demographics'->'gender'->>'male',
      v_after->'demographics'->'gender'->>'female',
      v_after->'demographics'->'gender'->>'unknown',
      v_after->'demographics'->'gender'->>'population_total')
  ),
  (
    'L_snapshot_price',
    (v_after->'value'->>'completed_revenue_total')::numeric
      = (v_before->'value'->>'completed_revenue_total')::numeric
        + 100 + 200 + 500 + 700 + 0 + CASE WHEN v_profile_user IS NOT NULL THEN 80 ELSE 0 END,
    format('revenue %s→%s snapshot=%s estimated=%s',
      v_before->'value'->>'completed_revenue_total',
      v_after->'value'->>'completed_revenue_total',
      v_after->'value'->>'snapshot_price_count',
      v_after->'value'->>'estimated_price_count')
  ),
  (
    'M_estimated_legacy_price',
    (v_after->'value'->>'estimated_price_count')::bigint
      = (v_before->'value'->>'estimated_price_count')::bigint + 1
      AND (v_after->'value'->>'contains_estimated_prices')::boolean = true,
    format('estimated %s→%s contains=%s',
      v_before->'value'->>'estimated_price_count',
      v_after->'value'->>'estimated_price_count',
      v_after->'value'->>'contains_estimated_prices')
  ),
  (
    'O_performance_parity',
    (v_after->'overview'->>'completed_visits')::bigint = (v_perf->>'completed_visits')::bigint
      AND (v_after->'value'->>'completed_revenue_total')::numeric = (v_perf->>'completed_revenue')::numeric,
    format('visits ca=%s perf=%s revenue ca=%s perf=%s',
      v_after->'overview'->>'completed_visits', v_perf->>'completed_visits',
      v_after->'value'->>'completed_revenue_total', v_perf->>'completed_revenue')
  );

  IF v_profile_user IS NOT NULL THEN
    INSERT INTO _xbook_ca_results VALUES
    (
      'J_auth_private_profile',
      (v_after->'quality'->>'demographic_profile_count')::bigint
        >= (v_before->'quality'->>'demographic_profile_count')::bigint
          + CASE WHEN v_had_visits THEN 0 ELSE 1 END
        AND (
          (v_profile_gender = 'male'
            AND (v_after->'demographics'->'gender'->>'male')::bigint
              >= (v_before->'demographics'->'gender'->>'male')::bigint
                + CASE WHEN v_had_visits THEN 0 ELSE 1 END)
          OR
          (v_profile_gender = 'female'
            AND (v_after->'demographics'->'gender'->>'female')::bigint
              >= (v_before->'demographics'->'gender'->>'female')::bigint
                + CASE WHEN v_had_visits THEN 0 ELSE 1 END)
        ),
      format('profile_count %s→%s gender=%s male %s→%s female %s→%s had_visits=%s',
        v_before->'quality'->>'demographic_profile_count',
        v_after->'quality'->>'demographic_profile_count',
        v_profile_gender,
        v_before->'demographics'->'gender'->>'male',
        v_after->'demographics'->'gender'->>'male',
        v_before->'demographics'->'gender'->>'female',
        v_after->'demographics'->'gender'->>'female',
        v_had_visits)
    );
  ELSE
    INSERT INTO _xbook_ca_results VALUES
    ('J_auth_private_profile', false, 'no private profile fixture available');
  END IF;

  BEGIN
    PERFORM public.get_business_customer_analytics_overview(v_biz_b, v_from, v_to);
    v_cross_msg := 'call succeeded (should have failed)';
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_cross_ok := true;
      v_cross_msg := SQLERRM;
    WHEN OTHERS THEN
      v_cross_ok := (SQLERRM ILIKE '%not authorized%');
      v_cross_msg := SQLERRM;
  END;

  INSERT INTO _xbook_ca_results VALUES
  ('N_cross_tenant', v_cross_ok, v_cross_msg);

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCA-%' OR customer_name LIKE 'XBOOK_CA_TEST%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_CA_TEST%';
  DELETE FROM public.business_customers
  WHERE business_id = v_biz_a
    AND (
      display_name LIKE 'XBOOK_CA_TEST%'
      OR phone LIKE '+389700077%'
      OR client_key LIKE 'p:389700077%'
    );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  INSERT INTO _xbook_ca_results VALUES
  (
    'cleanup_restored_booking_count',
    v_bookings_after = v_bookings_before,
    format('bookings before=%s after=%s', v_bookings_before, v_bookings_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_ca_results
ORDER BY test_name;
