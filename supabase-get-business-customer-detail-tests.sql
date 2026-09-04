-- Phase 2E Customer Detail contract tests.
-- Throwaway rows, then deleted. Safe to re-run.
-- Do not treat SQL detail columns as a product report: they may contain keys.

CREATE TEMP TABLE IF NOT EXISTS _xbook_det_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_det_results;

CREATE OR REPLACE FUNCTION pg_temp._jsonb_has_forbidden_key(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_key text;
  v_val jsonb;
  v_forbidden text[] := ARRAY[
    'date_of_birth',
    'dob',
    'manage_token',
    'booking_ref',
    'password',
    'encrypted_password',
    'customer_user_id',
    'user_id',
    'raw_app_meta_data',
    'raw_user_meta_data',
    'confirmation_token',
    'recovery_token'
  ];
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
      IF pg_temp._jsonb_has_forbidden_key(v_val) THEN
        RETURN true;
      END IF;
    END LOOP;
  ELSIF jsonb_typeof(p) = 'array' THEN
    FOR v_val IN SELECT jsonb_array_elements(p)
    LOOP
      IF pg_temp._jsonb_has_forbidden_key(v_val) THEN
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
  v_local_now timestamp;
  v_yesterday date;
  v_day_before date;
  v_tomorrow date;
  v_day_after date;
  v_svc uuid;
  v_svc_b uuid;
  v_svc_del uuid;
  v_staff uuid;
  v_staff_name text;
  v_profile_user uuid;
  v_profile_gender text;
  v_key_auth text;
  v_key_guest text;
  v_key_snap text;
  v_key_est text;
  v_key_zero text;
  v_key_unk text;
  v_key_up text;
  v_key_hist text;
  v_key_page text;
  v_key_top text;
  v_key_del text;
  v_auth jsonb;
  v_guest jsonb;
  v_snap jsonb;
  v_est jsonb;
  v_zero jsonb;
  v_unk jsonb;
  v_up jsonb;
  v_hist jsonb;
  v_page1 jsonb;
  v_page2 jsonb;
  v_cap jsonb;
  v_top jsonb;
  v_del jsonb;
  v_missing jsonb;
  v_empty_key jsonb;
  v_cross_ok boolean := false;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_i int;
  v_hist_up jsonb;
  v_hist_past jsonb;
  v_top0 jsonb;
  v_top1 jsonb;
  v_del_name text;
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
    RAISE EXCEPTION 'Need two businesses for Customer Detail tests';
  END IF;

  SELECT sm.id, sm.name
  INTO v_staff, v_staff_name
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_a
  ORDER BY sm.id
  LIMIT 1;

  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'Need a staff member on the busiest business for booking inserts';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := v_local_now::date - 1;
  v_day_before := v_local_now::date - 2;
  v_tomorrow := v_local_now::date + 1;
  v_day_after := v_local_now::date + 2;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XDET-%' OR customer_name LIKE 'XBOOK_DET_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_DET_%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_DET_%'
     OR phone LIKE '+389700089%'
     OR client_key LIKE 'p:389700089%'
     OR client_key LIKE 'e:xdet-%'
     OR client_key LIKE 'n:xbook_det_%';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_DET_TEST_SVC', 30, 700)
  RETURNING id INTO v_svc;

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_DET_TEST_BEARD', 20, 400)
  RETURNING id INTO v_svc_b;

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_DET_TEST_DEL', 30, 500)
  RETURNING id INTO v_svc_del;

  SELECT pp.user_id, pp.gender
  INTO v_profile_user, v_profile_gender
  FROM public.customer_private_profiles pp
  WHERE pp.gender IN ('male', 'female')
  LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  -- Guest: 2 completed (day-before + yesterday), used for first/last/repeat/cadence
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_email, customer_user_id,
    booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_day_before, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_DET_GUEST', '+389700089001', NULL, NULL, 'Confirmed', 100, 'XDET-G1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_DET_GUEST', '+389700089001', NULL, NULL, 'Confirmed', 200, 'XDET-G2', gen_random_uuid()::text),
  -- Snapshot 150 vs catalog 700
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_DET_SNAP', '+389700089030', NULL, NULL, 'Confirmed', 150, 'XDET-SNAP', gen_random_uuid()::text),
  -- Estimated (NULL snapshot → catalog 700)
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '12:30', 30,
   'XBOOK_DET_EST', '+389700089031', NULL, NULL, 'Confirmed', NULL, 'XDET-EST', gen_random_uuid()::text),
  -- Price 0 snapshot
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_DET_ZERO', '+389700089032', NULL, NULL, 'Confirmed', 0, 'XDET-ZERO', gen_random_uuid()::text),
  -- Unknown price: no snapshot, no service_id
  (v_biz_a, NULL, NULL, v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '13:30', 30,
   'XBOOK_DET_UNK', '+389700089033', NULL, NULL, 'Confirmed', NULL, 'XDET-UNK', gen_random_uuid()::text),
  -- Upcoming nearest + cancelled future must not win
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '08:00', 30,
   'XBOOK_DET_UP', '+389700089040', NULL, NULL, 'Confirmed', 50, 'XDET-UP0', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_tomorrow, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_DET_UP', '+389700089040', NULL, NULL, 'Cancelled', 50, 'XDET-UPC', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_tomorrow, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_DET_UP', '+389700089040', NULL, NULL, 'Confirmed', 50, 'XDET-UP1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_day_after, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_DET_UP', '+389700089040', NULL, NULL, 'Pending', 50, 'XDET-UP2', gen_random_uuid()::text),
  -- History ordering: past 09:00, 11:00, 10:00 yesterday; cancelled past
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Confirmed', 10, 'XDET-H09', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Confirmed', 10, 'XDET-H11', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Confirmed', 10, 'XDET-H10', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Cancelled', 10, 'XDET-HC', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_tomorrow, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Confirmed', 10, 'XDET-HU1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_tomorrow, 'YYYY-MM-DD'), '16:00', 30,
   'XBOOK_DET_HIST', '+389700089050', NULL, NULL, 'Pending', 10, 'XDET-HU2', gen_random_uuid()::text),
  -- Top services: haircut 3, beard 2
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_DET_TOP', '+389700089060', NULL, NULL, 'Confirmed', 10, 'XDET-T1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:30', 30,
   'XBOOK_DET_TOP', '+389700089060', NULL, NULL, 'Confirmed', 10, 'XDET-T2', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_DET_TOP', '+389700089060', NULL, NULL, 'Confirmed', 10, 'XDET-T3', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_DET_TEST_BEARD', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:30', 20,
   'XBOOK_DET_TOP', '+389700089060', NULL, NULL, 'Confirmed', 20, 'XDET-T4', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_DET_TEST_BEARD', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 20,
   'XBOOK_DET_TOP', '+389700089060', NULL, NULL, 'Confirmed', 20, 'XDET-T5', gen_random_uuid()::text),
  -- Deleted-service historical fallback
  (v_biz_a, v_svc_del, 'XBOOK_DET_HISTORIC_CUT', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '17:00', 30,
   'XBOOK_DET_DEL', '+389700089070', NULL, NULL, 'Confirmed', 80, 'XDET-DEL', gen_random_uuid()::text);

  -- Pagination extras (12 past completed)
  FOR v_i IN 1..12 LOOP
    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, customer_email, customer_user_id,
      booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff,
      to_char(v_yesterday, 'YYYY-MM-DD'),
      lpad((8 + (v_i / 60))::text, 2, '0') || ':' || lpad((v_i % 60)::text, 2, '0'),
      30,
      'XBOOK_DET_PAGE', '+389700089080', NULL, NULL, 'Confirmed', 5,
      'XDET-P' || v_i::text, gen_random_uuid()::text
    );
  END LOOP;

  IF v_profile_user IS NOT NULL THEN
    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, customer_email, customer_user_id,
      booking_status, booking_price, booking_ref, manage_token
    ) VALUES
    (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_day_before, 'YYYY-MM-DD'), '15:00', 30,
     'XBOOK_DET_AUTH', '+389700089010', 'xdet-auth@example.test', v_profile_user,
     'Confirmed', 80, 'XDET-AU1', gen_random_uuid()::text),
    (v_biz_a, v_svc, 'XBOOK_DET_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '15:30', 30,
     'XBOOK_DET_AUTH', '+389700089011', 'xdet-auth@example.test', v_profile_user,
     'Confirmed', 120, 'XDET-AU2', gen_random_uuid()::text);

    BEGIN
      INSERT INTO public.business_customers (
        business_id, client_key, customer_number, display_name, phone, email, customer_user_id, is_vip
      )
      SELECT v_biz_a, 'u:' || v_profile_user::text, 98701, 'XBOOK_DET_AUTH', '+389700089010',
             'xdet-auth-crm@example.test', v_profile_user, true
      WHERE NOT EXISTS (
        SELECT 1 FROM public.business_customers bc
        WHERE bc.business_id = v_biz_a AND bc.customer_user_id = v_profile_user
      );
    EXCEPTION
      WHEN unique_violation THEN
        NULL;
    END;
  END IF;

  BEGIN
    UPDATE public.bookings SET service_id = NULL WHERE booking_ref = 'XDET-DEL';
    DELETE FROM public.services WHERE id = v_svc_del;
  EXCEPTION
    WHEN OTHERS THEN
      UPDATE public.bookings SET service_id = NULL WHERE booking_ref = 'XDET-DEL';
      DELETE FROM public.services WHERE id = v_svc_del AND NOT EXISTS (
        SELECT 1 FROM public.bookings b WHERE b.service_id = v_svc_del
      );
  END;

  v_key_guest := public._analytics_customer_key(NULL, '+389700089001', NULL, 'XBOOK_DET_GUEST');
  v_key_snap := public._analytics_customer_key(NULL, '+389700089030', NULL, 'XBOOK_DET_SNAP');
  v_key_est := public._analytics_customer_key(NULL, '+389700089031', NULL, 'XBOOK_DET_EST');
  v_key_zero := public._analytics_customer_key(NULL, '+389700089032', NULL, 'XBOOK_DET_ZERO');
  v_key_unk := public._analytics_customer_key(NULL, '+389700089033', NULL, 'XBOOK_DET_UNK');
  v_key_up := public._analytics_customer_key(NULL, '+389700089040', NULL, 'XBOOK_DET_UP');
  v_key_hist := public._analytics_customer_key(NULL, '+389700089050', NULL, 'XBOOK_DET_HIST');
  v_key_page := public._analytics_customer_key(NULL, '+389700089080', NULL, 'XBOOK_DET_PAGE');
  v_key_top := public._analytics_customer_key(NULL, '+389700089060', NULL, 'XBOOK_DET_TOP');
  v_key_del := public._analytics_customer_key(NULL, '+389700089070', NULL, 'XBOOK_DET_DEL');
  IF v_profile_user IS NOT NULL THEN
    v_key_auth := public._analytics_customer_key(v_profile_user, '+389700089010', 'xdet-auth@example.test', 'XBOOK_DET_AUTH');
  END IF;

  IF v_key_auth IS NOT NULL THEN
    v_auth := public.get_business_customer_detail(v_biz_a, v_key_auth, 25, 0);
  END IF;
  v_guest := public.get_business_customer_detail(v_biz_a, v_key_guest, 25, 0);
  v_snap := public.get_business_customer_detail(v_biz_a, v_key_snap, 25, 0);
  v_est := public.get_business_customer_detail(v_biz_a, v_key_est, 25, 0);
  v_zero := public.get_business_customer_detail(v_biz_a, v_key_zero, 25, 0);
  v_unk := public.get_business_customer_detail(v_biz_a, v_key_unk, 25, 0);
  v_up := public.get_business_customer_detail(v_biz_a, v_key_up, 25, 0);
  v_hist := public.get_business_customer_detail(v_biz_a, v_key_hist, 25, 0);
  v_page1 := public.get_business_customer_detail(v_biz_a, v_key_page, 5, 0);
  v_page2 := public.get_business_customer_detail(v_biz_a, v_key_page, 5, 5);
  v_cap := public.get_business_customer_detail(v_biz_a, v_key_page, 200, 0);
  v_top := public.get_business_customer_detail(v_biz_a, v_key_top, 25, 0);
  v_del := public.get_business_customer_detail(v_biz_a, v_key_del, 25, 0);
  v_missing := public.get_business_customer_detail(v_biz_a, 'p:389700089999', 25, 0);
  v_empty_key := public.get_business_customer_detail(v_biz_a, '   ', 25, 0);

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  BEGIN
    PERFORM public.get_business_customer_detail(v_biz_b, v_key_guest, 25, 0);
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_cross_ok := true;
    WHEN OTHERS THEN
      v_cross_ok := (SQLERRM ILIKE '%not authorized%');
  END;

  INSERT INTO _xbook_det_results VALUES
  (
    'A_auth_customer_detail',
    v_key_auth IS NOT NULL
      AND (v_auth->>'ok')::boolean
      AND v_auth->'customer'->>'identity_type' = 'auth'
      AND v_auth->'customer'->>'analytics_customer_key' = v_key_auth
      AND (v_auth->'summary'->>'completed_visits_lifetime')::bigint >= 2,
    CASE WHEN v_key_auth IS NULL THEN 'no private profile user in environment'
         ELSE format('ok=%s visits=%s revenue=%s', v_auth->>'ok', v_auth->'summary'->>'completed_visits_lifetime', v_auth->'summary'->>'completed_revenue_lifetime')
    END
  ),
  (
    'B_guest_customer_detail',
    (v_guest->>'ok')::boolean
      AND v_guest->'customer'->>'identity_type' = 'guest'
      AND v_guest->'customer'->>'analytics_customer_key' = v_key_guest
      AND (v_guest->'summary'->>'completed_visits_lifetime')::bigint = 2
      AND (v_guest->'summary'->>'repeat_customer')::boolean,
    format('ok=%s type=%s visits=%s', v_guest->>'ok', v_guest->'customer'->>'identity_type', v_guest->'summary'->>'completed_visits_lifetime')
  ),
  (
    'C_wrong_business_denied',
    v_cross_ok,
    format('cross_ok=%s', v_cross_ok)
  ),
  (
    'D_unknown_key_not_found',
    v_missing->>'ok' = 'false'
      AND v_missing->>'code' = 'not_found'
      AND v_empty_key->>'code' = 'not_found',
    format('missing=%s empty=%s', v_missing->>'code', v_empty_key->>'code')
  ),
  (
    'E_completed_visit_count',
    (v_guest->'summary'->>'completed_visits_lifetime')::bigint = 2
      AND (v_up->'summary'->>'completed_visits_lifetime')::bigint = 1,
    format('guest=%s up=%s', v_guest->'summary'->>'completed_visits_lifetime', v_up->'summary'->>'completed_visits_lifetime')
  ),
  (
    'F_revenue_snapshot',
    (v_snap->'summary'->>'completed_revenue_lifetime')::numeric = 150
      AND (v_snap->'summary'->>'contains_estimated_prices')::boolean = false,
    format('rev=%s est=%s', v_snap->'summary'->>'completed_revenue_lifetime', v_snap->'summary'->>'contains_estimated_prices')
  ),
  (
    'G_legacy_estimated_flagged',
    (v_est->'summary'->>'completed_revenue_lifetime')::numeric = 700
      AND (v_est->'summary'->>'contains_estimated_prices')::boolean = true,
    format('rev=%s est=%s', v_est->'summary'->>'completed_revenue_lifetime', v_est->'summary'->>'contains_estimated_prices')
  ),
  (
    'H_price_zero_valid',
    (v_zero->'summary'->>'completed_revenue_lifetime')::numeric = 0
      AND v_zero->'summary'->>'average_spend_per_completed_visit' IS NOT NULL
      AND (v_zero->'summary'->>'average_spend_per_completed_visit')::numeric = 0,
    format('rev=%s avg=%s', v_zero->'summary'->>'completed_revenue_lifetime', v_zero->'summary'->>'average_spend_per_completed_visit')
  ),
  (
    'I_upcoming_nearest',
    (v_up->'upcoming'->>'has_upcoming_appointment')::boolean
      AND (v_up->'upcoming'->>'next_appointment_at')::timestamptz
          = public._performance_appointment_start(to_char(v_tomorrow, 'YYYY-MM-DD'), '14:00', v_tz)
      AND coalesce(v_up->'upcoming'->>'staff_name', '') IS NOT DISTINCT FROM coalesce(v_staff_name, ''),
    format('has=%s at=%s', v_up->'upcoming'->>'has_upcoming_appointment', v_up->'upcoming'->>'next_appointment_at')
  ),
  (
    'J_cancelled_not_upcoming',
    (v_up->'upcoming'->>'next_appointment_at')::timestamptz
      IS DISTINCT FROM public._performance_appointment_start(to_char(v_tomorrow, 'YYYY-MM-DD'), '09:00', v_tz)
      AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_up->'history_upcoming') r
        WHERE r->>'booking_status' = 'Cancelled'
      ),
    format('next=%s', v_up->'upcoming'->>'next_appointment_at')
  ),
  (
    'K_first_last_visit',
    (v_guest->'summary'->>'first_completed_visit_at')::timestamptz
      = public._performance_appointment_start(to_char(v_day_before, 'YYYY-MM-DD'), '09:00', v_tz)
      AND (v_guest->'summary'->>'last_completed_visit_at')::timestamptz
      = public._performance_appointment_start(to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', v_tz),
    format('first=%s last=%s', v_guest->'summary'->>'first_completed_visit_at', v_guest->'summary'->>'last_completed_visit_at')
  ),
  (
    'L_avg_spend_null_unpriced',
    v_unk->'summary'->>'average_spend_per_completed_visit' IS NULL
      AND (v_unk->'summary'->>'completed_visits_lifetime')::bigint = 1,
    format('avg=%s visits=%s', v_unk->'summary'->>'average_spend_per_completed_visit', v_unk->'summary'->>'completed_visits_lifetime')
  );

  v_top0 := v_top->'top_services'->0;
  v_top1 := v_top->'top_services'->1;
  v_hist_up := v_hist->'history_upcoming';
  v_hist_past := v_hist->'history';
  v_del_name := coalesce(v_del->'top_services'->0->>'service_name', v_del->'history'->0->>'service_name');

  INSERT INTO _xbook_det_results VALUES
  (
    'M_top_services_counts',
    jsonb_array_length(v_top->'top_services') >= 2
      AND (v_top0->>'completed_visits')::bigint = 3
      AND (v_top1->>'completed_visits')::bigint = 2
      AND (v_top0->>'completed_revenue')::numeric = 30
      AND (v_top1->>'completed_revenue')::numeric = 40,
    format('n=%s v0=%s v1=%s', jsonb_array_length(v_top->'top_services'), v_top0->>'completed_visits', v_top1->>'completed_visits')
  ),
  (
    'N_guest_demographics_unknown',
    v_guest->'customer'->>'gender' = 'unknown'
      AND v_guest->'customer'->>'age_bucket' = 'unknown'
      AND v_guest->'customer'->>'city_id' IS NULL
      AND v_guest->'customer'->>'city_name' IS NULL
      AND v_guest->'customer'->>'country_code' IS NULL,
    format('gender=%s age=%s', v_guest->'customer'->>'gender', v_guest->'customer'->>'age_bucket')
  ),
  (
    'O_auth_demographics_derived',
    v_key_auth IS NULL
      OR (
        v_auth->'customer'->>'gender' IN ('male', 'female', 'unknown')
        AND (v_profile_gender IS NULL OR v_auth->'customer'->>'gender' = v_profile_gender OR v_auth->'customer'->>'gender' = 'unknown')
        AND v_auth->'customer' ? 'age_bucket'
        AND v_auth->'customer' ? 'city_name'
        AND v_auth->'customer' ? 'country_code'
      ),
    CASE WHEN v_key_auth IS NULL THEN 'skipped'
         ELSE format('gender=%s age=%s', v_auth->'customer'->>'gender', v_auth->'customer'->>'age_bucket')
    END
  ),
  (
    'P_no_dob_returned',
    NOT pg_temp._jsonb_has_forbidden_key(v_guest)
      AND NOT pg_temp._jsonb_has_forbidden_key(coalesce(v_auth, '{}'::jsonb))
      AND NOT (v_guest::text ILIKE '%date_of_birth%')
      AND NOT (coalesce(v_auth, '{}'::jsonb)::text ILIKE '%date_of_birth%'),
    format('guest_forbidden=%s', pg_temp._jsonb_has_forbidden_key(v_guest))
  ),
  (
    'Q_no_tokens_returned',
    NOT (v_hist::text ILIKE '%manage_token%')
      AND NOT (v_hist::text ILIKE '%booking_ref%')
      AND NOT pg_temp._jsonb_has_forbidden_key(v_hist)
      AND (v_hist->'history'->0 ? 'booking_id'),
    format('forbidden=%s has_booking_id=%s', pg_temp._jsonb_has_forbidden_key(v_hist), v_hist->'history'->0 ? 'booking_id')
  ),
  (
    'R_history_ordering',
    jsonb_array_length(v_hist_up) = 2
      AND (v_hist_up->0->>'appointment_start')::timestamptz
          = public._performance_appointment_start(to_char(v_tomorrow, 'YYYY-MM-DD'), '11:00', v_tz)
      AND (v_hist_up->1->>'appointment_start')::timestamptz
          = public._performance_appointment_start(to_char(v_tomorrow, 'YYYY-MM-DD'), '16:00', v_tz)
      AND (v_hist_past->0->>'appointment_start')::timestamptz
          = public._performance_appointment_start(to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', v_tz)
      AND v_hist_past->0->>'display_state' = 'cancelled'
      AND (v_hist_past->1->>'appointment_start')::timestamptz
          = public._performance_appointment_start(to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', v_tz)
      AND v_hist_past->1->>'display_state' = 'completed',
    format('up0=%s past0=%s past0state=%s', v_hist_up->0->>'appointment_start', v_hist_past->0->>'appointment_start', v_hist_past->0->>'display_state')
  ),
  (
    'S_history_pagination',
    jsonb_array_length(v_page1->'history') = 5
      AND (v_page1->'pagination'->>'has_more')::boolean
      AND (v_page1->'pagination'->>'total_count')::bigint = 12
      AND jsonb_array_length(v_page2->'history') = 5
      AND (v_page2->'pagination'->>'offset')::int = 5
      AND (v_cap->'pagination'->>'limit')::int = 100
      AND (v_page1->'history'->0->>'booking_id') IS DISTINCT FROM (v_page2->'history'->0->>'booking_id'),
    format('p1=%s more=%s total=%s cap=%s', jsonb_array_length(v_page1->'history'), v_page1->'pagination'->>'has_more', v_page1->'pagination'->>'total_count', v_cap->'pagination'->>'limit')
  ),
  (
    'T_deleted_service_fallback',
    v_del_name = 'XBOOK_DET_HISTORIC_CUT'
      AND (v_del->'summary'->>'completed_visits_lifetime')::bigint = 1,
    format('name=%s visits=%s', v_del_name, v_del->'summary'->>'completed_visits_lifetime')
  ),
  (
    'guest_avg_spend_known',
    (v_guest->'summary'->>'average_spend_per_completed_visit')::numeric = 150
      AND (v_guest->'summary'->>'completed_revenue_lifetime')::numeric = 300,
    format('avg=%s rev=%s', v_guest->'summary'->>'average_spend_per_completed_visit', v_guest->'summary'->>'completed_revenue_lifetime')
  );

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XDET-%' OR customer_name LIKE 'XBOOK_DET_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_DET_%';
  DELETE FROM public.business_customers
  WHERE business_id = v_biz_a
    AND (
      display_name LIKE 'XBOOK_DET_%'
      OR phone LIKE '+389700089%'
      OR client_key LIKE 'p:389700089%'
      OR client_key LIKE 'e:xdet-%'
      OR client_key LIKE 'n:xbook_det_%'
      OR customer_number = 98701
    );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  INSERT INTO _xbook_det_results VALUES
  (
    'cleanup_restored_booking_count',
    v_bookings_after = v_bookings_before,
    format('bookings before=%s after=%s', v_bookings_before, v_bookings_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_det_results
ORDER BY test_name;

SELECT
  count(*) FILTER (WHERE passed) AS passed,
  count(*) FILTER (WHERE NOT passed) AS failed,
  count(*) AS total
FROM _xbook_det_results;
