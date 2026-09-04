-- =============================================================================
-- XBOOK: Customer membership booking tests
-- Throwaway fixtures only. Cleans up. Does not change live require_client_approval.
-- Does not rewrite historical bookings.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_mem_booking_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_mem_booking_results;

CREATE OR REPLACE FUNCTION public._xbook_mem_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', json_build_object('role', coalesce(p_role, 'anon'))::text, true);
    RETURN;
  END IF;
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', p_uid::text, 'role', coalesce(p_role, 'authenticated'))::text,
    true
  );
END;
$$;

DO $$
DECLARE
  v_biz_off uuid;
  v_biz_on uuid;
  v_biz_b uuid;
  v_owner_off uuid;
  v_owner_on uuid;
  v_svc_off uuid;
  v_svc_on uuid;
  v_svc_b uuid;
  v_staff_off uuid;
  v_staff_on uuid;
  v_user_a uuid;
  v_user_b uuid;
  v_user_c uuid;
  v_instance uuid;
  v_email text;
  v_row public.business_customers%ROWTYPE;
  v_eval jsonb;
  v_booking public.bookings%ROWTYPE;
  v_date date;
  v_time time;
  v_dow int;
  v_ok boolean;
  v_msg text;
  v_status text;
  v_n int;
  v_ws time;
  v_recurring boolean;
  v_id uuid;
BEGIN
  -- Isolate live settings: pick one approval-OFF and one approval-ON business.
  SELECT bs.business_id
  INTO v_biz_off
  FROM public.business_settings bs
  WHERE coalesce(bs.require_client_approval, false) = false
    AND coalesce(bs.accept_new_clients, true) = true
    AND bs.work_start IS NOT NULL
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) DESC
  LIMIT 1;

  SELECT bs.business_id
  INTO v_biz_on
  FROM public.business_settings bs
  WHERE coalesce(bs.require_client_approval, false) = true
  LIMIT 1;

  SELECT bs.business_id
  INTO v_biz_b
  FROM public.business_settings bs
  WHERE bs.business_id IS DISTINCT FROM v_biz_off
    AND bs.business_id IS DISTINCT FROM v_biz_on
  LIMIT 1;
  IF v_biz_b IS NULL THEN
    v_biz_b := v_biz_on;
  END IF;

  IF v_biz_off IS NULL OR v_biz_on IS NULL THEN
    INSERT INTO _xbook_mem_booking_results VALUES (
      'fixture_businesses', false, 'Need one approval-OFF and one approval-ON business'
    );
    RETURN;
  END IF;

  INSERT INTO _xbook_mem_booking_results VALUES (
    'fixture_businesses', true,
    format('off=%s on=%s', left(v_biz_off::text, 8), left(v_biz_on::text, 8))
  );

  v_owner_off := v_biz_off;
  v_owner_on := v_biz_on;

  SELECT instance_id INTO v_instance FROM auth.users WHERE instance_id IS NOT NULL LIMIT 1;
  IF v_instance IS NULL THEN
    v_instance := '00000000-0000-0000-0000-000000000000';
  END IF;

  -- Throwaway customer auth users (no business_id metadata → no auto membership).
  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-mem-a-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-mem-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_a;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-mem-b-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-mem-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_b;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-mem-c-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-mem-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_c;

  INSERT INTO public.user_profiles (id, email, role, full_name, phone)
  VALUES
    (v_user_a, 'xbook-mem-a@invalid.example', 'customer', 'XBOOK_MEM_BOOKING_TEST A', '+389700088001'),
    (v_user_b, 'xbook-mem-b@invalid.example', 'customer', 'XBOOK_MEM_BOOKING_TEST B', '+389700088002'),
    (v_user_c, 'xbook-mem-c@invalid.example', 'customer', 'XBOOK_MEM_BOOKING_TEST C', '+389700088003')
  ON CONFLICT (id) DO UPDATE SET
    role = 'customer',
    full_name = EXCLUDED.full_name,
    phone = EXCLUDED.phone;

  -- Throwaway services
  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_off, 'XBOOK_MEM_BOOKING_TEST_SVC', 30, 100)
  RETURNING id INTO v_svc_off;
  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_on, 'XBOOK_MEM_BOOKING_TEST_SVC', 30, 100)
  RETURNING id INTO v_svc_on;
  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_b, 'XBOOK_MEM_BOOKING_TEST_SVC', 30, 100)
  RETURNING id INTO v_svc_b;

  SELECT sm.id INTO v_staff_off
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_off AND coalesce(sm.active, true) = true
  LIMIT 1;
  SELECT sm.id INTO v_staff_on
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_on AND coalesce(sm.active, true) = true
  LIMIT 1;

  SELECT bs.work_start::time INTO v_ws
  FROM public.business_settings bs WHERE bs.business_id = v_biz_off;
  v_time := coalesce(v_ws, '09:00'::time);

  v_date := CURRENT_DATE + 14;
  FOR v_n IN 0..13 LOOP
    v_dow := EXTRACT(DOW FROM (CURRENT_DATE + 14 + v_n))::int;
    IF public._is_working_day(
      (SELECT working_days FROM public.business_settings WHERE business_id = v_biz_off),
      v_dow
    ) THEN
      v_date := CURRENT_DATE + 14 + v_n;
      EXIT;
    END IF;
  END LOOP;

  -- A. approval OFF join → approved, booking succeeds
  PERFORM public._xbook_mem_test_set_jwt(v_user_a);
  v_row := public._ensure_business_customer_membership(
    v_biz_off, v_user_a, '+389700088001', 'xbook-mem-a@invalid.example', 'XBOOK_MEM_BOOKING_TEST A', NULL
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'A_join_off_approved',
    v_row.id IS NOT NULL AND v_row.approval_status = 'approved' AND v_row.customer_user_id = v_user_a,
    coalesce(v_row.approval_status, 'null')
  );

  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date, v_time,
      'XBOOK_MEM_BOOKING_TEST A', '+389700088001', 'xbook-mem-a@invalid.example',
      NULL, v_staff_off, v_user_a, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id = v_user_a;
    v_msg := coalesce(v_booking.customer_user_id::text, 'null');
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('A_booking_off_succeeds', v_ok, v_msg);

  -- B. approval ON join → pending, booking fails
  PERFORM public._xbook_mem_test_set_jwt(v_user_a);
  v_row := public._ensure_business_customer_membership(
    v_biz_on, v_user_a, '+389700088001', 'xbook-mem-a@invalid.example', 'XBOOK_MEM_BOOKING_TEST A', NULL
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'B_join_on_pending',
    v_row.id IS NOT NULL AND v_row.approval_status = 'pending' AND v_row.customer_user_id = v_user_a,
    coalesce(v_row.approval_status, 'null')
  );

  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_on, v_svc_on, v_date, v_time,
      'XBOOK_MEM_BOOKING_TEST A', '+389700088001', NULL, NULL, v_staff_on, v_user_a, 'Confirmed'
    );
    v_ok := false;
    v_msg := 'booking_created';
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%waiting for approval%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('B_pending_booking_fails', v_ok, v_msg);

  -- C. owner approves → booking succeeds
  PERFORM public._xbook_mem_test_set_jwt(v_owner_on);
  UPDATE public.business_customers
  SET approval_status = 'approved', updated_at = now()
  WHERE business_id = v_biz_on AND customer_user_id = v_user_a
  RETURNING approval_status INTO v_status;

  PERFORM public._xbook_mem_test_set_jwt(v_user_a);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_on, v_svc_on, v_date, v_time,
      'XBOOK_MEM_BOOKING_TEST A', '+389700088001', NULL, NULL, v_staff_on, v_user_a, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id = v_user_a;
    v_msg := coalesce(v_booking.id::text, 'null');
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES (
    'C_approved_then_books',
    v_ok AND v_status = 'approved',
    v_msg
  );

  -- D / E. no membership, both flags, direct create_booking fails
  PERFORM public._xbook_mem_test_set_jwt(v_user_b);
  v_eval := public._evaluate_client_booking_approval(
    v_biz_off, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'D_no_membership_off',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false AND v_eval ->> 'code' = 'no_membership',
    v_eval::text
  );

  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public._assert_client_approval_for_booking(
      v_biz_off, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B'
    );
    v_ok := false;
    v_msg := 'assert_allowed';
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%business code%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('D_no_membership_off_rpc', v_ok, v_msg);

  v_eval := public._evaluate_client_booking_approval(
    v_biz_on, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'E_no_membership_on',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false AND v_eval ->> 'code' = 'no_membership',
    v_eval::text
  );

  -- F. pending + historical bookings still denied, status stays pending
  PERFORM public._xbook_mem_test_set_jwt(v_owner_off);
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status
  ) VALUES (
    v_biz_off, v_svc_off, 'XBOOK_MEM_BOOKING_TEST_SVC', to_char(CURRENT_DATE - 30, 'YYYY-MM-DD'),
    '10:00', 30, 'XBOOK_MEM_BOOKING_TEST B', '+389700088002', v_user_b, 'Confirmed'
  );

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status
  ) VALUES (
    v_biz_off, 'u:' || v_user_b::text,
    public._allocate_business_customer_number(v_biz_off),
    'XBOOK_MEM_BOOKING_TEST B', '+389700088002', v_user_b, 'pending'
  );

  PERFORM public._xbook_mem_test_set_jwt(v_user_b);
  v_eval := public._evaluate_client_booking_approval(
    v_biz_off, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B', false
  );
  SELECT approval_status INTO v_status
  FROM public.business_customers
  WHERE business_id = v_biz_off AND customer_user_id = v_user_b;
  INSERT INTO _xbook_mem_booking_results VALUES (
    'F_pending_history_denied',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false
      AND v_eval ->> 'code' = 'pending'
      AND v_status = 'pending',
    format('eval=%s status=%s', v_eval ->> 'code', v_status)
  );

  -- G. rejected + historical bookings
  UPDATE public.business_customers
  SET approval_status = 'rejected'
  WHERE business_id = v_biz_off AND customer_user_id = v_user_b;
  v_eval := public._evaluate_client_booking_approval(
    v_biz_off, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B', false
  );
  SELECT approval_status INTO v_status
  FROM public.business_customers
  WHERE business_id = v_biz_off AND customer_user_id = v_user_b;
  INSERT INTO _xbook_mem_booking_results VALUES (
    'G_rejected_history_denied',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false
      AND v_eval ->> 'code' = 'rejected'
      AND v_status = 'rejected',
    format('eval=%s status=%s', v_eval ->> 'code', v_status)
  );

  -- H. blocked
  UPDATE public.business_customers
  SET approval_status = 'blocked'
  WHERE business_id = v_biz_off AND customer_user_id = v_user_b;
  v_eval := public._evaluate_client_booking_approval(
    v_biz_off, v_user_b, '+389700088002', NULL, 'XBOOK_MEM_BOOKING_TEST B', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'H_blocked_denied',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false AND v_eval ->> 'code' = 'blocked',
    v_eval::text
  );

  -- I. approved A, pending B
  -- user_a already approved on both after test C; set B (v_biz_b) pending for user_a
  PERFORM public._xbook_mem_test_set_jwt(v_user_a);
  v_row := public._ensure_business_customer_membership(
    v_biz_b, v_user_a, '+389700088001', NULL, 'XBOOK_MEM_BOOKING_TEST A', 'pending'
  );
  -- If ensure returns existing approved (already a member), force pending for isolation test.
  UPDATE public.business_customers
  SET approval_status = 'pending'
  WHERE business_id = v_biz_b AND customer_user_id = v_user_a;

  v_eval := public._evaluate_client_booking_approval(
    v_biz_off, v_user_a, '+389700088001', NULL, 'XBOOK_MEM_BOOKING_TEST A', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'I_business_a_approved',
    coalesce((v_eval ->> 'allowed')::boolean, false) = true,
    v_eval::text
  );
  v_eval := public._evaluate_client_booking_approval(
    v_biz_b, v_user_a, '+389700088001', NULL, 'XBOOK_MEM_BOOKING_TEST A', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'I_business_b_pending',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false AND v_eval ->> 'code' = 'pending',
    v_eval::text
  );

  -- J. spoofed customer_user_id
  PERFORM public._xbook_mem_test_set_jwt(v_user_a);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date, v_time,
      'XBOOK_MEM_BOOKING_TEST A', '+389700088001', NULL, NULL, v_staff_off, v_user_c, 'Confirmed'
    );
    v_ok := false;
    v_msg := 'booking_created';
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%account to book%' OR SQLERRM ILIKE '%requires an account%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('J_spoof_uid_fails', v_ok, v_msg);

  -- K. owner manual NULL customer_user_id
  PERFORM public._xbook_mem_test_set_jwt(v_owner_off);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date + 1, v_time,
      'XBOOK_MEM_BOOKING_TEST WALKIN', '+389700088099', NULL, NULL, v_staff_off, NULL, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id IS NULL;
    v_msg := format('id=%s uid=%s', v_booking.id, coalesce(v_booking.customer_user_id::text, 'null'));
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('K_owner_null_uid', v_ok, v_msg);

  -- L. recurring follows same membership rule
  SELECT coalesce(bs.allow_recurring_appointments, false)
  INTO v_recurring
  FROM public.business_settings bs
  WHERE bs.business_id = v_biz_on;

  PERFORM public._xbook_mem_test_set_jwt(v_user_c);
  v_eval := public._evaluate_client_booking_approval(
    v_biz_on, v_user_c, '+389700088003', NULL, 'XBOOK_MEM_BOOKING_TEST C', false
  );
  INSERT INTO _xbook_mem_booking_results VALUES (
    'L_recurring_no_membership_eval',
    coalesce((v_eval ->> 'allowed')::boolean, true) = false AND v_eval ->> 'code' = 'no_membership',
    v_eval::text
  );

  IF v_recurring THEN
    v_ok := false;
    v_msg := '';
    BEGIN
      PERFORM public._assert_client_approval_for_booking(
        v_biz_on, v_user_c, '+389700088003', NULL, 'XBOOK_MEM_BOOKING_TEST C'
      );
      v_ok := false;
      v_msg := 'assert_allowed';
    EXCEPTION WHEN OTHERS THEN
      v_ok := SQLERRM ILIKE '%business code%' OR SQLERRM ILIKE '%account to book%';
      v_msg := SQLERRM;
    END;
    INSERT INTO _xbook_mem_booking_results VALUES ('L_recurring_rpc_no_membership', v_ok, v_msg);
  ELSE
    INSERT INTO _xbook_mem_booking_results VALUES (
      'L_recurring_rpc_no_membership', true, 'skipped_recurring_disabled_eval_covers_gate'
    );
  END IF;

  -- M. anon caller
  PERFORM public._xbook_mem_test_set_jwt(NULL, 'anon');
  v_ok := false;
  v_msg := '';
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date, v_time,
      'XBOOK_MEM_BOOKING_TEST ANON', '+389700088000', NULL, NULL, v_staff_off, NULL, 'Confirmed'
    );
    v_ok := false;
    v_msg := 'booking_created';
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%account to book%' OR SQLERRM ILIKE '%not authenticated%' OR SQLERRM ILIKE '%permission%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('M_anon_fails', v_ok, v_msg);

  -- N. direct table insert denied by RLS (authenticated non-owner)
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public._xbook_mem_test_set_jwt(v_user_a);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.bookings (
      business_id, service_id, service_name, date, time, duration_minutes,
      customer_name, customer_phone, customer_user_id, booking_status
    ) VALUES (
      v_biz_off, v_svc_off, 'XBOOK_MEM_BOOKING_TEST_SVC', to_char(v_date, 'YYYY-MM-DD'),
      '11:00', 30, 'XBOOK_MEM_BOOKING_TEST RLS', '+389700088001', v_user_a, 'Confirmed'
    )
    RETURNING id INTO v_id;
    EXECUTE 'RESET ROLE';
    v_ok := false;
    v_msg := 'insert_allowed id=' || coalesce(v_id::text, 'null');
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    v_ok := SQLERRM ILIKE '%row-level security%' OR SQLERRM ILIKE '%permission%' OR SQLERRM ILIKE '%policy%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_mem_booking_results VALUES ('N_rls_insert_denied', v_ok, v_msg);

  -- Cleanup throwaway rows (never touch unmatched live bookings).
  DELETE FROM public.bookings
  WHERE customer_name LIKE 'XBOOK_MEM_BOOKING_TEST%'
     OR customer_phone IN ('+389700088001','+389700088002','+389700088003','+389700088099','+389700088000');
  DELETE FROM public.business_customers
  WHERE customer_user_id IN (v_user_a, v_user_b, v_user_c)
     OR display_name LIKE 'XBOOK_MEM_BOOKING_TEST%'
     OR phone IN ('+389700088001','+389700088002','+389700088003');
  DELETE FROM public.services WHERE name = 'XBOOK_MEM_BOOKING_TEST_SVC';
  DELETE FROM public.user_profiles WHERE id IN (v_user_a, v_user_b, v_user_c);
  DELETE FROM auth.users WHERE id IN (v_user_a, v_user_b, v_user_c);

EXCEPTION WHEN OTHERS THEN
  INSERT INTO _xbook_mem_booking_results VALUES ('ZZ_fatal', false, SQLERRM)
  ON CONFLICT (test_name) DO UPDATE SET passed = false, detail = EXCLUDED.detail;
  DELETE FROM public.bookings WHERE customer_name LIKE 'XBOOK_MEM_BOOKING_TEST%';
  DELETE FROM public.services WHERE name = 'XBOOK_MEM_BOOKING_TEST_SVC';
  DELETE FROM public.business_customers WHERE display_name LIKE 'XBOOK_MEM_BOOKING_TEST%';
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_mem_booking_results
ORDER BY test_name;

DROP FUNCTION IF EXISTS public._xbook_mem_test_set_jwt(uuid, text);
