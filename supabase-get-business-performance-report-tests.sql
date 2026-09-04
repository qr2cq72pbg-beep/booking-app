-- Phase 1A Performance RPC tests. Creates throwaway rows, then deletes them.
-- Safe to re-run. Does not backfill or keep production fixtures.

CREATE TEMP TABLE IF NOT EXISTS _xbook_perf_rpc_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_perf_rpc_results;

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
  v_svc uuid;
  v_before jsonb;
  v_after jsonb;
  v_l31 jsonb;
  v_l01 jsonb;
  v_start timestamp;
  v_cross_ok boolean := false;
  v_cross_msg text := '';
  v_bookings_before bigint;
  v_bookings_after bigint;
BEGIN
  SELECT bs.business_id, bs.timezone
  INTO v_biz_a, v_tz
  FROM public.business_settings bs
  WHERE nullif(trim(bs.timezone), '') IS NOT NULL
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
    RAISE EXCEPTION 'Need two businesses for Performance RPC tests';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := (v_local_now::date - 1);
  v_tomorrow := (v_local_now::date + 1);
  v_from := v_yesterday;
  v_to := v_tomorrow;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;

  DELETE FROM public.bookings WHERE customer_name = 'XBOOK_PERF_RPC_TEST';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_PERF_RPC_TEST%';
  DELETE FROM public.business_customers
  WHERE display_name = 'XBOOK_PERF_RPC_TEST'
     OR phone IN (
       '+389700099001','+389700099002','+389700099003','+389700099004','+389700099005',
       '+389700099006','+389700099007','+389700099008','+389700099009','+389700099010',
       '+389700099011'
     );

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_PERF_RPC_TEST_SVC', 30, 700)
  RETURNING id INTO v_svc;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_before := public.get_business_performance_report(v_biz_a, v_from, v_to);

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- A cancelled
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099001', 'Cancelled', 100, 'XPRF-A', gen_random_uuid()::text),
  -- B future confirmed
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099002', 'Confirmed', 200, 'XPRF-B', gen_random_uuid()::text),
  -- C future pending
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_tomorrow, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099003', 'Pending', 50, 'XPRF-C', gen_random_uuid()::text),
  -- D ended confirmed
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099004', 'Confirmed', 300, 'XPRF-D', gen_random_uuid()::text),
  -- E ended pending
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '08:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099005', 'Pending', 80, 'XPRF-E', gen_random_uuid()::text),
  -- G snapshot 500 vs catalog 700
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099007', 'Confirmed', 500, 'XPRF-G', gen_random_uuid()::text),
  -- H legacy estimated 700
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099008', 'Confirmed', NULL, 'XPRF-H', gen_random_uuid()::text),
  -- I free 0
  (v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC', to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099009', 'Confirmed', 0, 'XPRF-I', gen_random_uuid()::text),
  -- J unknown price / missing service
  (v_biz_a, gen_random_uuid(), 'Deleted test service', to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
   'XBOOK_PERF_RPC_TEST', '+389700099010', 'Confirmed', NULL, 'XPRF-J', gen_random_uuid()::text);

  -- F in-progress confirmed (computed local start)
  v_start := v_local_now - interval '15 minutes';
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC',
    to_char(v_start::date, 'YYYY-MM-DD'), to_char(v_start::time, 'HH24:MI'), 60,
    'XBOOK_PERF_RPC_TEST', '+389700099006', 'Confirmed', 40, 'XPRF-F', gen_random_uuid()::text
  );

  -- L timezone civil date (far future so it cannot mix with A–J period)
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_PERF_RPC_TEST_SVC',
    '2099-01-01', '00:30', 30,
    'XBOOK_PERF_RPC_TEST', '+389700099011', 'Confirmed', 15, 'XPRF-L', gen_random_uuid()::text
  );

  v_after := public.get_business_performance_report(v_biz_a, v_from, v_to);
  v_l31 := public.get_business_performance_report(v_biz_a, DATE '2098-12-31', DATE '2098-12-31');
  v_l01 := public.get_business_performance_report(v_biz_a, DATE '2099-01-01', DATE '2099-01-01');

  INSERT INTO _xbook_perf_rpc_results VALUES
  (
    'A_cancelled',
    (v_after->>'cancelled_appointments')::bigint = (v_before->>'cancelled_appointments')::bigint + 1
      AND (v_after->>'scheduled_appointments')::bigint = (v_before->>'scheduled_appointments')::bigint + 9
      AND (v_after->>'completed_visits')::bigint = (v_before->>'completed_visits')::bigint + 5,
    format('cancelled %s→%s scheduled %s→%s completed %s→%s',
      v_before->>'cancelled_appointments', v_after->>'cancelled_appointments',
      v_before->>'scheduled_appointments', v_after->>'scheduled_appointments',
      v_before->>'completed_visits', v_after->>'completed_visits')
  ),
  (
    'B_future_confirmed',
    (v_after->>'upcoming_appointments')::bigint = (v_before->>'upcoming_appointments')::bigint + 2
      AND (v_after->>'upcoming_scheduled_value')::numeric = (v_before->>'upcoming_scheduled_value')::numeric + 250,
    format('upcoming %s→%s upcoming_value %s→%s',
      v_before->>'upcoming_appointments', v_after->>'upcoming_appointments',
      v_before->>'upcoming_scheduled_value', v_after->>'upcoming_scheduled_value')
  ),
  (
    'C_future_pending_not_completed',
    (v_after->>'completed_visits')::bigint = (v_before->>'completed_visits')::bigint + 5,
    format('completed %s→%s', v_before->>'completed_visits', v_after->>'completed_visits')
  ),
  (
    'D_ended_confirmed',
    (v_after->>'completed_revenue')::numeric = (v_before->>'completed_revenue')::numeric + 1500,
    format('completed_revenue %s→%s (expect +1500 = 300+500+700+0)',
      v_before->>'completed_revenue', v_after->>'completed_revenue')
  ),
  (
    'E_ended_pending',
    (v_after->>'elapsed_unconfirmed_count')::bigint = (v_before->>'elapsed_unconfirmed_count')::bigint + 1
      AND (v_after->>'completed_visits')::bigint = (v_before->>'completed_visits')::bigint + 5,
    format('elapsed %s→%s', v_before->>'elapsed_unconfirmed_count', v_after->>'elapsed_unconfirmed_count')
  ),
  (
    'F_in_progress_confirmed',
    (v_after->>'in_progress_confirmed')::bigint = (v_before->>'in_progress_confirmed')::bigint + 1,
    format('in_progress %s→%s', v_before->>'in_progress_confirmed', v_after->>'in_progress_confirmed')
  ),
  (
    'G_snapshot_not_catalog',
    (v_after->>'completed_revenue')::numeric = (v_before->>'completed_revenue')::numeric + 1500
      AND (v_after->>'snapshot_priced_booking_count')::bigint = (v_before->>'snapshot_priced_booking_count')::bigint + 7,
    format('snapshot_count %s→%s revenue %s→%s',
      v_before->>'snapshot_priced_booking_count', v_after->>'snapshot_priced_booking_count',
      v_before->>'completed_revenue', v_after->>'completed_revenue')
  ),
  (
    'H_legacy_estimated',
    (v_after->>'estimated_legacy_booking_count')::bigint = (v_before->>'estimated_legacy_booking_count')::bigint + 1
      AND (v_after->>'contains_estimated_prices')::boolean = true,
    format('estimated %s→%s contains=%s',
      v_before->>'estimated_legacy_booking_count', v_after->>'estimated_legacy_booking_count',
      v_after->>'contains_estimated_prices')
  ),
  (
    'I_free_zero_valid',
    (v_after->>'completed_revenue')::numeric = (v_before->>'completed_revenue')::numeric + 1500
      AND (v_after->>'completed_revenue_known_rows')::bigint = (v_before->>'completed_revenue_known_rows')::bigint + 4
      AND (v_after->>'unknown_price_booking_count')::bigint = (v_before->>'unknown_price_booking_count')::bigint + 1,
    format('known_completed %s→%s unknown_sched %s→%s',
      v_before->>'completed_revenue_known_rows', v_after->>'completed_revenue_known_rows',
      v_before->>'unknown_price_booking_count', v_after->>'unknown_price_booking_count')
  ),
  (
    'J_unknown_price_no_fabricate',
    (v_after->>'scheduled_value_unknown_rows')::bigint = (v_before->>'scheduled_value_unknown_rows')::bigint + 1
      AND (v_after->>'completed_revenue_unknown_rows')::bigint = (v_before->>'completed_revenue_unknown_rows')::bigint + 1,
    format('sched_unknown %s→%s completed_unknown %s→%s',
      v_before->>'scheduled_value_unknown_rows', v_after->>'scheduled_value_unknown_rows',
      v_before->>'completed_revenue_unknown_rows', v_after->>'completed_revenue_unknown_rows')
  );

  BEGIN
    PERFORM public.get_business_performance_report(v_biz_b, v_from, v_to);
    v_cross_msg := 'call succeeded (should have failed)';
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_cross_ok := true;
      v_cross_msg := SQLERRM;
    WHEN OTHERS THEN
      v_cross_ok := (SQLERRM ILIKE '%not authorized%');
      v_cross_msg := SQLERRM;
  END;

  INSERT INTO _xbook_perf_rpc_results VALUES
  (
    'K_cross_tenant',
    v_cross_ok,
    v_cross_msg
  ),
  (
    'L_timezone_civil_date',
    (v_l31->>'scheduled_appointments')::bigint = 0
      AND (v_l01->>'scheduled_appointments')::bigint = 1
      AND (v_l01->>'timezone') = v_tz
      AND (v_l01->>'upcoming_appointments')::bigint = 1,
    format('tz=%s dec31_sched=%s jan1_sched=%s jan1_upcoming=%s',
      v_l01->>'timezone', v_l31->>'scheduled_appointments',
      v_l01->>'scheduled_appointments', v_l01->>'upcoming_appointments')
  );

  DELETE FROM public.bookings WHERE customer_name = 'XBOOK_PERF_RPC_TEST';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_PERF_RPC_TEST%';
  DELETE FROM public.business_customers
  WHERE business_id = v_biz_a
    AND (
      display_name = 'XBOOK_PERF_RPC_TEST'
      OR phone IN (
        '+389700099001','+389700099002','+389700099003','+389700099004','+389700099005',
        '+389700099006','+389700099007','+389700099008','+389700099009','+389700099010',
        '+389700099011'
      )
      OR client_key LIKE 'p:389700099%'
    );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;

  INSERT INTO _xbook_perf_rpc_results VALUES
  (
    'cleanup_restored_booking_count',
    v_bookings_after = v_bookings_before,
    format('bookings before=%s after=%s', v_bookings_before, v_bookings_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_perf_rpc_results
ORDER BY test_name;
