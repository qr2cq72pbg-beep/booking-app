-- Canonical analytics population contract tests. Throwaway rows, then deleted.

CREATE TEMP TABLE IF NOT EXISTS _xbook_pop_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_pop_results;

DO $$
DECLARE
  v_biz_a uuid;
  v_biz_b uuid;
  v_tz text;
  v_from date;
  v_to date;
  v_local_now timestamp;
  v_yesterday date;
  v_staff uuid;
  v_svc uuid;
  v_num integer;
  v_base jsonb;
  v_crm jsonb;
  v_after jsonb;
  v_b_base jsonb;
  v_b_mid jsonb;
  v_b_w jsonb;
  v_perf jsonb;
  v_det jsonb;
  v_auth uuid;
  v_key_approved text;
  v_key_rejected text;
  v_key_pending text;
  v_key_blocked text;
  v_key_guest text;
  v_key_rej_hist text;
  v_key_auth text;
  v_key_guest_same text;
  v_key_w text;
  v_top jsonb;
  v_found_num integer;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_cross_ok boolean := false;
  v_cross_msg text := '';
  v_staff_b uuid;
  v_svc_b uuid;
  v_det_b jsonb;
  v_a_visits bigint;
  v_b_visits bigint;
  v_perf_u jsonb;
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
    RAISE EXCEPTION 'Need two businesses for population tests';
  END IF;

  SELECT sm.id INTO v_staff
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_a
  ORDER BY sm.id
  LIMIT 1;

  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'Need a staff member on the busiest business';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := v_local_now::date - 1;
  v_from := v_yesterday;
  v_to := v_yesterday;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XPOP-%' OR customer_name LIKE 'XBOOK_POP_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_POP_%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_POP_%'
     OR phone LIKE '+389700066%'
     OR client_key LIKE 'p:389700066%'
     OR client_key LIKE 'e:xpop-%';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_POP_SVC', 30, 700)
  RETURNING id INTO v_svc;

  SELECT coalesce(max(customer_number), 0) INTO v_num
  FROM public.business_customers
  WHERE business_id = v_biz_a;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_base := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);

  PERFORM set_config('request.jwt.claim.sub', v_biz_b::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_b::text, 'role', 'authenticated')::text,
    true
  );
  v_b_base := public.get_business_customer_analytics_overview(v_biz_b, v_from, v_to);

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  v_key_approved := 'p:389700066001';
  v_key_rejected := 'p:389700066002';
  v_key_pending := 'p:389700066003';
  v_key_blocked := 'p:389700066004';

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, approval_status
  ) VALUES
  (v_biz_a, v_key_approved, v_num + 1, 'XBOOK_POP_APPROVED', '+389700066001', 'approved'),
  (v_biz_a, v_key_rejected, v_num + 2, 'XBOOK_POP_REJECTED', '+389700066002', 'rejected'),
  (v_biz_a, v_key_pending, v_num + 3, 'XBOOK_POP_PENDING', '+389700066003', 'pending'),
  (v_biz_a, v_key_blocked, v_num + 4, 'XBOOK_POP_BLOCKED', '+389700066004', 'blocked');

  v_crm := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);

  INSERT INTO _xbook_pop_results VALUES
  (
    'A_approved_crm_only_included',
    (v_crm->'overview'->>'total_customers')::bigint = (v_base->'overview'->>'total_customers')::bigint + 1
      AND EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_approved
          AND k.has_approved_membership
          AND NOT k.has_booking_history
      ),
    format('total %s→%s', v_base->'overview'->>'total_customers', v_crm->'overview'->>'total_customers')
  ),
  (
    'B_rejected_crm_only_excluded',
    (v_crm->'population'->>'excluded_rejected_no_history')::bigint
      = (v_base->'population'->>'excluded_rejected_no_history')::bigint + 1
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_rejected
      ),
    format('excluded_rejected %s→%s',
      v_base->'population'->>'excluded_rejected_no_history',
      v_crm->'population'->>'excluded_rejected_no_history')
  ),
  (
    'C_pending_crm_only_excluded',
    (v_crm->'population'->>'excluded_pending_no_history')::bigint
      = (v_base->'population'->>'excluded_pending_no_history')::bigint + 1
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_pending
      ),
    format('excluded_pending %s→%s',
      v_base->'population'->>'excluded_pending_no_history',
      v_crm->'population'->>'excluded_pending_no_history')
  ),
  (
    'D_blocked_crm_only_excluded',
    (v_crm->'population'->>'excluded_blocked_no_history')::bigint
      = (v_base->'population'->>'excluded_blocked_no_history')::bigint + 1
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_blocked
      ),
    format('excluded_blocked %s→%s',
      v_base->'population'->>'excluded_blocked_no_history',
      v_crm->'population'->>'excluded_blocked_no_history')
  ),
  (
    'J_customers_with_visits_unchanged',
    (v_crm->'overview'->>'customers_with_visits')::bigint
      = (v_base->'overview'->>'customers_with_visits')::bigint,
    format('with_visits %s→%s',
      v_base->'overview'->>'customers_with_visits',
      v_crm->'overview'->>'customers_with_visits')
  ),
  (
    'K_active_unchanged',
    (v_crm->'overview'->>'active_customers')::bigint
      = (v_base->'overview'->>'active_customers')::bigint,
    format('active %s→%s', v_base->'overview'->>'active_customers', v_crm->'overview'->>'active_customers')
  ),
  (
    'L_new_unchanged',
    (v_crm->'overview'->>'new_customers')::bigint
      = (v_base->'overview'->>'new_customers')::bigint,
    format('new %s→%s', v_base->'overview'->>'new_customers', v_crm->'overview'->>'new_customers')
  ),
  (
    'M_returning_unchanged',
    (v_crm->'overview'->>'returning_customers')::bigint
      = (v_base->'overview'->>'returning_customers')::bigint,
    format('returning %s→%s',
      v_base->'overview'->>'returning_customers',
      v_crm->'overview'->>'returning_customers')
  ),
  (
    'N_repeat_unchanged',
    (v_crm->'overview'->>'repeat_customers')::bigint
      = (v_base->'overview'->>'repeat_customers')::bigint
      AND (v_crm->'overview'->>'repeat_rate_pct') IS NOT DISTINCT FROM (v_base->'overview'->>'repeat_rate_pct'),
    format('repeat %s→%s rate %s→%s',
      v_base->'overview'->>'repeat_customers', v_crm->'overview'->>'repeat_customers',
      v_base->'overview'->>'repeat_rate_pct', v_crm->'overview'->>'repeat_rate_pct')
  ),
  (
    'O_at_risk_unchanged',
    (v_crm->'inactivity'->>'at_risk_90')::bigint
      = (v_base->'inactivity'->>'at_risk_90')::bigint
      AND (v_crm->'inactivity'->>'at_risk_30_to_59')::bigint
        = (v_base->'inactivity'->>'at_risk_30_to_59')::bigint,
    format('at_risk_90 %s→%s', v_base->'inactivity'->>'at_risk_90', v_crm->'inactivity'->>'at_risk_90')
  ),
  (
    'P_booked_ahead_unchanged',
    (v_crm->'inactivity'->>'booked_ahead_customers')::bigint
      = (v_base->'inactivity'->>'booked_ahead_customers')::bigint,
    format('booked_ahead %s→%s',
      v_base->'inactivity'->>'booked_ahead_customers',
      v_crm->'inactivity'->>'booked_ahead_customers')
  ),
  (
    'Q_demographics_still_with_visits',
    (v_crm->'demographics'->>'population') = 'customers_with_visits'
      AND (v_crm->'demographics'->'gender'->>'population_total')::bigint
        = (v_crm->'overview'->>'customers_with_visits')::bigint,
    format('demo_pop=%s with_visits=%s',
      v_crm->'demographics'->'gender'->>'population_total',
      v_crm->'overview'->>'customers_with_visits')
  ),
  (
    'X_revenue_unchanged',
    (v_crm->'value'->>'completed_revenue_total')::numeric
      = (v_base->'value'->>'completed_revenue_total')::numeric,
    format('revenue %s→%s',
      v_base->'value'->>'completed_revenue_total',
      v_crm->'value'->>'completed_revenue_total')
  ),
  (
    'Y_price_estimation_unchanged',
    (v_crm->'value'->>'estimated_price_count')::bigint
      = (v_base->'value'->>'estimated_price_count')::bigint
      AND (v_crm->'value'->>'snapshot_price_count')::bigint
        = (v_base->'value'->>'snapshot_price_count')::bigint,
    format('estimated %s→%s snapshot %s→%s',
      v_base->'value'->>'estimated_price_count', v_crm->'value'->>'estimated_price_count',
      v_base->'value'->>'snapshot_price_count', v_crm->'value'->>'snapshot_price_count')
  );

  v_det := public.get_business_customer_detail(v_biz_a, v_key_approved, 25, 0);
  INSERT INTO _xbook_pop_results VALUES
  (
    'R_detail_approved_crm_only_resolves',
    coalesce(v_det->>'ok', '') = 'true'
      AND coalesce((v_det->'summary'->>'completed_visits_lifetime')::bigint, -1) = 0,
    format('ok=%s visits=%s', v_det->>'ok', v_det->'summary'->>'completed_visits_lifetime')
  );

  v_det := public.get_business_customer_detail(v_biz_a, v_key_rejected, 25, 0);
  INSERT INTO _xbook_pop_results VALUES
  (
    'S_detail_rejected_crm_only_not_found',
    coalesce(v_det->>'ok', '') = 'false'
      AND coalesce(v_det->>'code', '') = 'not_found',
    format('ok=%s code=%s', v_det->>'ok', v_det->>'code')
  );

  -- Booking-only guest (owner JWT bypasses approval CRM create)
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_POP_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
    'XBOOK_POP_GUEST', '+389700066010', 'Confirmed', 100, 'XPOP-G', gen_random_uuid()::text
  );
  v_key_guest := public._analytics_customer_key(NULL, '+389700066010', NULL, 'XBOOK_POP_GUEST');

  -- Rejected CRM that also has booking history (same guest key)
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_POP_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:30', 30,
    'XBOOK_POP_REJHIST', '+389700066011', 'Confirmed', 80, 'XPOP-RH', gen_random_uuid()::text
  );
  v_key_rej_hist := public._analytics_customer_key(NULL, '+389700066011', NULL, 'XBOOK_POP_REJHIST');
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, approval_status
  ) VALUES (
    v_biz_a, v_key_rej_hist, v_num + 5, 'XBOOK_POP_REJHIST', '+389700066011', 'rejected'
  );

  SELECT u.id INTO v_auth
  FROM auth.users u
  WHERE NOT EXISTS (
    SELECT 1 FROM public.business_customers bc
    WHERE bc.business_id = v_biz_a AND bc.customer_user_id = u.id
  )
  AND NOT EXISTS (
    SELECT 1 FROM public.business_settings bs WHERE bs.business_id = u.id
  )
  LIMIT 1;

  IF v_auth IS NOT NULL THEN
    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, customer_user_id, booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_a, v_svc, 'XBOOK_POP_SVC', v_staff, '2020-01-15', '10:00', 30,
      'XBOOK_POP_AUTH', '+389700066008', v_auth, 'Confirmed', 90, 'XPOP-AU', gen_random_uuid()::text
    );
    v_key_auth := public._analytics_customer_key(v_auth, '+389700066008', NULL, 'XBOOK_POP_AUTH');

    INSERT INTO public.business_customers (
      business_id, client_key, customer_number, display_name, phone, customer_user_id, approval_status
    ) VALUES (
      v_biz_a, 'p:389700066008', v_num + 6, 'XBOOK_POP_AUTH', '+389700066008', v_auth, 'approved'
    );

    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_a, v_svc, 'XBOOK_POP_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:30', 30,
      'XBOOK_POP_AUTH', '+389700066008', 'Confirmed', 40, 'XPOP-AG', gen_random_uuid()::text
    );
    v_key_guest_same := public._analytics_customer_key(NULL, '+389700066008', NULL, 'XBOOK_POP_AUTH');
  END IF;

  v_after := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  v_perf := public.get_business_performance_report(v_biz_a, v_from, v_to);

  INSERT INTO _xbook_pop_results VALUES
  (
    'E_rejected_with_booking_history_kept',
    EXISTS (
      SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
      WHERE k.analytics_customer_key = v_key_rej_hist
        AND k.has_booking_history
    )
      AND coalesce((public.get_business_customer_detail(v_biz_a, v_key_rej_hist, 25, 0)->>'ok'), '') = 'true',
    format('key_prefix=%s', left(coalesce(v_key_rej_hist, ''), 2))
  ),
  (
    'F_booking_only_guest_included',
    EXISTS (
      SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
      WHERE k.analytics_customer_key = v_key_guest
        AND k.has_booking_history
    ),
    format('guest_key_prefix=%s', left(coalesce(v_key_guest, ''), 2))
  );

  IF v_auth IS NOT NULL THEN
    INSERT INTO _xbook_pop_results VALUES
    (
      'G_auth_booking_customer_included',
      v_key_auth LIKE 'u:%'
        AND EXISTS (
          SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
          WHERE k.analytics_customer_key = v_key_auth
        ),
      format('auth_prefix=%s', left(coalesce(v_key_auth, ''), 2))
    ),
    (
      'H_guest_auth_same_phone_remain_separate',
      v_key_auth IS DISTINCT FROM v_key_guest_same
        AND v_key_guest_same LIKE 'p:%'
        AND EXISTS (
          SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
          WHERE k.analytics_customer_key = v_key_auth
        )
        AND EXISTS (
          SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
          WHERE k.analytics_customer_key = v_key_guest_same
        ),
      format('auth_type=%s guest_type=%s same=%s',
        left(coalesce(v_key_auth, ''), 1),
        left(coalesce(v_key_guest_same, ''), 1),
        (v_key_auth = v_key_guest_same))
    ),
    (
      'I_no_fuzzy_merge',
      (SELECT count(*) FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key IN (v_key_auth, v_key_guest_same)) = 2,
      'auth and guest contact pair counted as two keys'
    );
  ELSE
    INSERT INTO _xbook_pop_results VALUES
    ('G_auth_booking_customer_included', false, 'no free auth.users row'),
    ('H_guest_auth_same_phone_remain_separate', false, 'no free auth.users row'),
    ('I_no_fuzzy_merge', false, 'no free auth.users row');
  END IF;

  v_det := public.get_business_customer_detail(v_biz_a, v_key_guest, 25, 0);
  INSERT INTO _xbook_pop_results VALUES
  (
    'T_detail_booking_only_guest_resolves',
    coalesce(v_det->>'ok', '') = 'true'
      AND coalesce((v_det->'summary'->>'completed_visits_lifetime')::bigint, 0) >= 1,
    format('ok=%s visits=%s', v_det->>'ok', v_det->'summary'->>'completed_visits_lifetime')
  );

  IF v_auth IS NOT NULL THEN
    v_perf_u := public.get_business_performance_report(v_biz_a, DATE '2020-01-15', DATE '2020-01-15');
    SELECT (x->>'customer_number')::integer
    INTO v_found_num
    FROM jsonb_array_elements(v_perf_u->'top_customers') x
    WHERE x->>'analytics_customer_key' = v_key_auth
    LIMIT 1;

    INSERT INTO _xbook_pop_results VALUES
    (
      'U_performance_auth_crm_via_customer_user_id',
      v_found_num = v_num + 6,
      format('expected_number=%s found=%s top_len=%s',
        v_num + 6, v_found_num, jsonb_array_length(v_perf_u->'top_customers'))
    );
  ELSE
    INSERT INTO _xbook_pop_results VALUES
    ('U_performance_auth_crm_via_customer_user_id', false, 'no free auth.users row');
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_biz_b::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_b::text, 'role', 'authenticated')::text,
    true
  );
  v_b_mid := public.get_business_customer_analytics_overview(v_biz_b, v_from, v_to);

  BEGIN
    PERFORM public.get_business_customer_analytics_overview(v_biz_b, v_from, v_to);
    -- already authenticated as B; cross-deny as A:
    PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
      true
    );
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

  INSERT INTO _xbook_pop_results VALUES
  (
    'V_shared_auth_and_cross_business_isolated',
    (v_b_mid->'overview'->>'total_customers')::bigint
      = (v_b_base->'overview'->>'total_customers')::bigint
      AND (v_b_mid->'overview'->>'customers_with_visits')::bigint
        = (v_b_base->'overview'->>'customers_with_visits')::bigint
      AND (v_b_mid->'value'->>'completed_revenue_total')::numeric
        = (v_b_base->'value'->>'completed_revenue_total')::numeric
      AND v_cross_ok,
    format('b_total %s→%s b_visits %s→%s deny=%s %s',
      v_b_base->'overview'->>'total_customers', v_b_mid->'overview'->>'total_customers',
      v_b_base->'overview'->>'customers_with_visits', v_b_mid->'overview'->>'customers_with_visits',
      v_cross_ok, v_cross_msg)
  );

  -- W: same guest client_key on A and B remains isolated
  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_POP_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
    'XBOOK_POP_COLLIDE', '+389700066020', 'Confirmed', 25, 'XPOP-WA', gen_random_uuid()::text
  );
  v_key_w := public._analytics_customer_key(NULL, '+389700066020', NULL, 'XBOOK_POP_COLLIDE');
  v_after := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  v_det := public.get_business_customer_detail(v_biz_a, v_key_w, 25, 0);

  SELECT sm.id INTO v_staff_b
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_b
  ORDER BY sm.id
  LIMIT 1;

  IF v_staff_b IS NOT NULL THEN
    INSERT INTO public.services (business_id, name, duration, price)
    VALUES (v_biz_b, 'XBOOK_POP_SVC_B', 30, 400)
    RETURNING id INTO v_svc_b;

    PERFORM set_config('request.jwt.claim.sub', v_biz_b::text, true);
    PERFORM set_config(
      'request.jwt.claims',
      json_build_object('sub', v_biz_b::text, 'role', 'authenticated')::text,
      true
    );

    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
    ) VALUES (
      v_biz_b, v_svc_b, 'XBOOK_POP_SVC_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
      'XBOOK_POP_COLLIDE', '+389700066020', 'Confirmed', 400, 'XPOP-WB', gen_random_uuid()::text
    );

    v_b_w := public.get_business_customer_analytics_overview(v_biz_b, v_from, v_to);
    v_det_b := public.get_business_customer_detail(v_biz_b, v_key_w, 25, 0);
    v_a_visits := coalesce((v_det->'summary'->>'completed_visits_lifetime')::bigint, 0);
    v_b_visits := coalesce((v_det_b->'summary'->>'completed_visits_lifetime')::bigint, 0);

    INSERT INTO _xbook_pop_results VALUES
    (
      'W_guest_client_key_collision_isolated',
      v_key_w IS NOT NULL
        AND v_a_visits = 1
        AND v_b_visits = 1
        AND (v_b_w->'value'->>'completed_revenue_total')::numeric
          = (v_b_mid->'value'->>'completed_revenue_total')::numeric + 400,
      format('a_visits=%s b_visits=%s', v_a_visits, v_b_visits)
    );
  ELSE
    INSERT INTO _xbook_pop_results VALUES
    ('W_guest_client_key_collision_isolated', false, 'business B has no staff');
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_biz_a::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz_a::text, 'role', 'authenticated')::text,
    true
  );

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XPOP-%' OR customer_name LIKE 'XBOOK_POP_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_POP_%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_POP_%'
     OR phone LIKE '+389700066%'
     OR client_key LIKE 'p:389700066%'
     OR client_key LIKE 'e:xpop-%';

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  INSERT INTO _xbook_pop_results VALUES
  (
    'Z_booking_count_restored',
    v_bookings_after = v_bookings_before,
    format('bookings before=%s after=%s', v_bookings_before, v_bookings_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_pop_results
ORDER BY test_name;
