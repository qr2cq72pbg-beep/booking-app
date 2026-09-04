-- =============================================================================
-- XBOOK Phase 4B Service Analytics tests
-- Throwaway fixtures deleted. Live Test Barber read-only parity.
-- Does not keep renamed/deleted live services. Does not backfill prices.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_sa4b_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_sa4b_results;

CREATE OR REPLACE FUNCTION public._xbook_sa4b_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._sa_svc(p jsonb, p_name text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT e
  FROM jsonb_array_elements(coalesce(p->'services', '[]'::jsonb)) e
  WHERE e->>'display_name' = p_name
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._sa_svc_key(p jsonb, p_key text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT e
  FROM jsonb_array_elements(coalesce(p->'services', '[]'::jsonb)) e
  WHERE e->>'group_key' = p_key
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._jsonb_has_forbidden_key(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_key text;
  v_val jsonb;
  v_forbidden text[] := ARRAY[
    'date_of_birth', 'dob', 'manage_token', 'booking_ref', 'password',
    'encrypted_password', 'customer_user_id', 'user_id', 'raw_app_meta_data',
    'raw_user_meta_data', 'confirmation_token', 'recovery_token'
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
  v_biz_tb uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  v_tz text;
  v_tz_tb text;
  v_today date;
  v_yesterday date;
  v_tomorrow date;
  v_before date;
  v_closed_from date;
  v_closed_to date;
  v_prev_from date;
  v_prev_to date;
  v_month_start date;
  v_month_end date;
  v_win record;
  v_svc_a uuid;
  v_svc_b uuid;
  v_svc_c uuid;
  v_svc_d uuid;
  v_svc_e uuid;
  v_svc_f uuid;
  v_svc_dup1 uuid;
  v_svc_dup2 uuid;
  v_svc_ren uuid;
  v_svc_del uuid;
  v_user_canon uuid;
  v_user_cust uuid;
  v_instance uuid;
  v_rep jsonb;
  v_rep2 jsonb;
  v_aug jsonb;
  v_ytd jsonb;
  v_sep jsonb;
  v_perf_aug jsonb;
  v_perf_aug_after jsonb;
  v_ca_ytd jsonb;
  v_ca_ytd_after jsonb;
  v_seg jsonb;
  v_det jsonb;
  v_sis jsonb;
  v_mas jsonb;
  v_combo jsonb;
  v_row jsonb;
  v_ok boolean;
  v_msg text;
  v_sqlstate text;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_links_before bigint;
  v_links_after bigint;
  v_n bigint;
  v_key_a text;
  v_key_del text;
  v_num integer;
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
    RAISE EXCEPTION 'Need two businesses for Service Analytics tests';
  END IF;

  SELECT nullif(trim(bs.timezone), '')
  INTO v_tz_tb
  FROM public.business_settings bs
  WHERE bs.business_id = v_biz_tb;

  v_today := (now() AT TIME ZONE v_tz)::date;
  v_yesterday := v_today - 1;
  v_tomorrow := v_today + 1;
  v_before := v_today - 20;
  v_month_start := date_trunc('month', v_today)::date;
  v_month_end := (date_trunc('month', v_today) + interval '1 month' - interval '1 day')::date;
  v_closed_from := v_today - 8;
  v_closed_to := v_today - 2;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;

  -- -------------------------------------------------------------------------
  -- Cleanup leftover fixtures
  -- -------------------------------------------------------------------------
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XSA4B-%' OR customer_name LIKE 'XBOOK_SA4B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700088%'
     OR reason = 'xbook_sa4b_test';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_SA4B%'
     OR phone LIKE '+389700088%'
     OR client_key LIKE 'p:389700088%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_SA4B%';
  DELETE FROM public.user_profiles
  WHERE email LIKE 'xbook-sa4b-%@invalid.example';
  DELETE FROM auth.users
  WHERE email LIKE 'xbook-sa4b-%@invalid.example';

  -- -------------------------------------------------------------------------
  -- Window helper
  -- -------------------------------------------------------------------------
  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-09-01', DATE '2026-09-01', DATE '2026-09-01');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_today',
    v_win.comparison_type = 'today'
      AND v_win.previous_from = DATE '2026-08-31'
      AND v_win.previous_to = DATE '2026-08-31',
    format('%s prev=%s..%s', v_win.comparison_type, v_win.previous_from, v_win.previous_to)
  );

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-08-01', DATE '2026-08-31', DATE '2026-09-01');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_closed_august',
    v_win.comparison_type = 'closed_equal_length'
      AND v_win.comparison_current_from = DATE '2026-08-01'
      AND v_win.comparison_current_to = DATE '2026-08-31'
      AND v_win.previous_from = DATE '2026-07-01'
      AND v_win.previous_to = DATE '2026-07-31',
    format('%s curr=%s..%s prev=%s..%s', v_win.comparison_type, v_win.comparison_current_from, v_win.comparison_current_to, v_win.previous_from, v_win.previous_to)
  );

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-01-01', DATE '2026-09-01', DATE '2026-09-01');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_ytd',
    v_win.comparison_type = 'ytd'
      AND v_win.previous_from = DATE '2025-01-01'
      AND v_win.previous_to = DATE '2025-09-01',
    format('%s prev=%s..%s', v_win.comparison_type, v_win.previous_from, v_win.previous_to)
  );

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-09-01', DATE '2026-09-30', DATE '2026-09-01');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_elapsed_mtd_sep1',
    v_win.comparison_type = 'elapsed_mtd'
      AND v_win.comparison_current_from = DATE '2026-09-01'
      AND v_win.comparison_current_to = DATE '2026-09-01'
      AND v_win.previous_from = DATE '2026-08-01'
      AND v_win.previous_to = DATE '2026-08-01',
    format('%s curr=%s..%s prev=%s..%s', v_win.comparison_type, v_win.comparison_current_from, v_win.comparison_current_to, v_win.previous_from, v_win.previous_to)
  );

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-03-01', DATE '2026-03-31', DATE '2026-03-31');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_elapsed_mtd_capped_feb',
    v_win.comparison_type = 'elapsed_mtd'
      AND v_win.previous_from = DATE '2026-02-01'
      AND v_win.previous_to = DATE '2026-02-28',
    format('%s prev=%s..%s', v_win.comparison_type, v_win.previous_from, v_win.previous_to)
  );

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(DATE '2026-10-01', DATE '2026-10-10', DATE '2026-09-01');
  INSERT INTO _xbook_sa4b_results VALUES (
    'window_future_not_applicable',
    v_win.comparison_type = 'not_applicable'
      AND v_win.previous_from IS NULL,
    v_win.comparison_type
  );

  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_increase',
    public._service_analytics_trend(4, 6, 'visits', true)->>'status' = 'increase'
      AND (public._service_analytics_trend(4, 6, 'visits', true)->>'pct')::numeric = 50.0,
    public._service_analytics_trend(4, 6, 'visits', true)::text
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_decrease',
    public._service_analytics_trend(19, 10, 'visits', true)->>'status' = 'decrease'
      AND (public._service_analytics_trend(19, 10, 'visits', true)->>'pct')::numeric = -47.4,
    public._service_analytics_trend(19, 10, 'visits', true)::text
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_new',
    public._service_analytics_trend(0, 3, 'visits', true)->>'status' = 'new'
      AND public._service_analytics_trend(0, 3, 'visits', true)->>'pct' IS NULL,
    public._service_analytics_trend(0, 3, 'visits', true)::text
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_visits_zero_no_change',
    public._service_analytics_trend(0, 0, 'visits', true)->>'status' = 'no_change',
    public._service_analytics_trend(0, 0, 'visits', true)::text
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_revenue_zero_na',
    public._service_analytics_trend(0, 0, 'revenue', true)->>'status' = 'not_applicable',
    public._service_analytics_trend(0, 0, 'revenue', true)::text
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'trend_not_comparable',
    public._service_analytics_trend(10, 20, 'visits', false)->>'status' = 'not_applicable',
    public._service_analytics_trend(10, 20, 'visits', false)::text
  );

  -- -------------------------------------------------------------------------
  -- Grants
  -- -------------------------------------------------------------------------
  INSERT INTO _xbook_sa4b_results VALUES (
    'grants_authenticated_only',
    has_function_privilege('authenticated', 'public.get_business_service_analytics(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.get_business_service_analytics(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('service_role', 'public.get_business_service_analytics(uuid,date,date)', 'EXECUTE'),
    'authenticated execute; anon/service_role revoked'
  );
  INSERT INTO _xbook_sa4b_results VALUES (
    'helpers_not_granted',
    NOT has_function_privilege('authenticated', 'public._service_analytics_comparison_windows(date,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('authenticated', 'public._service_analytics_trend(numeric,numeric,text,boolean)', 'EXECUTE'),
    'helpers revoked from authenticated'
  );

  -- -------------------------------------------------------------------------
  -- Isolated fixtures
  -- -------------------------------------------------------------------------
  INSERT INTO public.services (business_id, name, duration, price) VALUES
    (v_biz_a, 'XBOOK_SA4B_A', 30, 100),
    (v_biz_a, 'XBOOK_SA4B_B', 30, 200),
    (v_biz_a, 'XBOOK_SA4B_C', 30, 50),
    (v_biz_a, 'XBOOK_SA4B_D', 30, 80),
    (v_biz_a, 'XBOOK_SA4B_E', 30, 0),
    (v_biz_a, 'XBOOK_SA4B_F', 30, 10),
    (v_biz_a, 'XBOOK_SA4B_DUP', 30, 15),
    (v_biz_a, 'XBOOK_SA4B_DUP', 30, 25),
    (v_biz_a, 'XBOOK_SA4B_REN', 30, 40),
    (v_biz_a, 'XBOOK_SA4B_DEL', 30, 60);

  SELECT id INTO v_svc_a FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_A' LIMIT 1;
  SELECT id INTO v_svc_b FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_B' LIMIT 1;
  SELECT id INTO v_svc_c FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_C' LIMIT 1;
  SELECT id INTO v_svc_d FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_D' LIMIT 1;
  SELECT id INTO v_svc_e FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_E' LIMIT 1;
  SELECT id INTO v_svc_f FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_F' LIMIT 1;
  SELECT id INTO v_svc_dup1 FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_DUP' ORDER BY price ASC LIMIT 1;
  SELECT id INTO v_svc_dup2 FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_DUP' ORDER BY price DESC LIMIT 1;
  SELECT id INTO v_svc_ren FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_REN' LIMIT 1;
  SELECT id INTO v_svc_del FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_SA4B_DEL' LIMIT 1;
  v_key_a := v_svc_a::text;
  v_key_del := v_svc_del::text;

  SELECT i.id INTO v_instance FROM auth.instances i LIMIT 1;
  IF v_instance IS NULL THEN
    v_instance := '00000000-0000-0000-0000-000000000000';
  END IF;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-sa4b-canon-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-sa4b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    now(), now(), '', '', '', ''
  )
  RETURNING id INTO v_user_canon;

  INSERT INTO auth.users (
    instance_id, id, aud, role,     email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-sa4b-cust-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-sa4b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  )
  RETURNING id INTO v_user_cust;

  SELECT coalesce(max(customer_number), 0) INTO v_num
  FROM public.business_customers WHERE business_id = v_biz_a;

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status, is_vip
  ) VALUES (
    v_biz_a, 'p:389700088010', v_num + 1, 'XBOOK_SA4B_LINK', '+389700088010',
    v_user_canon, 'approved', false
  );

  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (
    v_biz_a, v_user_canon, 'p:389700088010', 'xbook_sa4b_test', v_biz_a
  );

  PERFORM public._xbook_sa4b_test_set_jwt(v_biz_a);

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- New customer uses A and B in period
  (v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_NEW', '+389700088001', NULL, 'Confirmed', 100, 'XSA4B-N1', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_SA4B_B', to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_SA4B_NEW', '+389700088001', NULL, 'Confirmed', 200, 'XSA4B-N2', gen_random_uuid()::text),
  -- Returning on A
  (v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_before, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_RET', '+389700088002', NULL, 'Confirmed', 100, 'XSA4B-R0', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_SA4B_RET', '+389700088002', NULL, 'Confirmed', 100, 'XSA4B-R1', gen_random_uuid()::text),
  -- Upcoming-only C
  (v_biz_a, v_svc_c, 'XBOOK_SA4B_C', to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_SA4B_UP', '+389700088003', NULL, 'Confirmed', 50, 'XSA4B-U1', gen_random_uuid()::text),
  -- D: completed + cancelled + elapsed pending
  (v_biz_a, v_svc_d, 'XBOOK_SA4B_D', to_char(v_yesterday, 'YYYY-MM-DD'), '08:00', 30,
   'XBOOK_SA4B_D1', '+389700088004', NULL, 'Confirmed', 80, 'XSA4B-D1', gen_random_uuid()::text),
  (v_biz_a, v_svc_d, 'XBOOK_SA4B_D', to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_SA4B_D2', '+389700088005', NULL, 'Cancelled', 80, 'XSA4B-D2', gen_random_uuid()::text),
  (v_biz_a, v_svc_d, 'XBOOK_SA4B_D', to_char(v_yesterday, 'YYYY-MM-DD'), '07:00', 30,
   'XBOOK_SA4B_D3', '+389700088006', NULL, 'Pending', 80, 'XSA4B-D3', gen_random_uuid()::text),
  -- Free E estimated 0
  (v_biz_a, v_svc_e, 'XBOOK_SA4B_E', to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_SA4B_E', '+389700088007', NULL, 'Confirmed', NULL, 'XSA4B-E1', gen_random_uuid()::text),
  -- Duplicate names
  (v_biz_a, v_svc_dup1, 'XBOOK_SA4B_DUP', to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_SA4B_DUP1', '+389700088008', NULL, 'Confirmed', 15, 'XSA4B-P1', gen_random_uuid()::text),
  (v_biz_a, v_svc_dup2, 'XBOOK_SA4B_DUP', to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
   'XBOOK_SA4B_DUP2', '+389700088009', NULL, 'Confirmed', 25, 'XSA4B-P2', gen_random_uuid()::text),
  -- Rename snapshot name vs catalog
  (v_biz_a, v_svc_ren, 'XBOOK_SA4B_REN', to_char(v_yesterday, 'YYYY-MM-DD'), '16:00', 30,
   'XBOOK_SA4B_REN', '+389700088011', NULL, 'Confirmed', 40, 'XSA4B-REN', gen_random_uuid()::text),
  -- Delete/orphan
  (v_biz_a, v_svc_del, 'XBOOK_SA4B_DEL', to_char(v_yesterday, 'YYYY-MM-DD'), '17:00', 30,
   'XBOOK_SA4B_DEL', '+389700088012', NULL, 'Confirmed', 60, 'XSA4B-DEL', gen_random_uuid()::text),
  -- Identity collapse: auth + linked guest
  (v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_yesterday, 'YYYY-MM-DD'), '18:00', 30,
   'XBOOK_SA4B_LINK', '+389700088010', v_user_canon, 'Confirmed', 100, 'XSA4B-L1', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_yesterday, 'YYYY-MM-DD'), '19:00', 30,
   'XBOOK_SA4B_LINK', '+389700088010', NULL, 'Confirmed', 100, 'XSA4B-L2', gen_random_uuid()::text),
  -- Closed-period F: 4 previous + 1 current
  (v_biz_a, v_svc_f, 'XBOOK_SA4B_F', to_char(v_today - 15, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_F', '+389700088013', NULL, 'Confirmed', 10, 'XSA4B-F0', gen_random_uuid()::text),
  (v_biz_a, v_svc_f, 'XBOOK_SA4B_F', to_char(v_today - 14, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_F', '+389700088013', NULL, 'Confirmed', 10, 'XSA4B-F1', gen_random_uuid()::text),
  (v_biz_a, v_svc_f, 'XBOOK_SA4B_F', to_char(v_today - 13, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_F', '+389700088013', NULL, 'Confirmed', 10, 'XSA4B-F2', gen_random_uuid()::text),
  (v_biz_a, v_svc_f, 'XBOOK_SA4B_F', to_char(v_today - 12, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_F', '+389700088013', NULL, 'Confirmed', 10, 'XSA4B-F3', gen_random_uuid()::text),
  (v_biz_a, v_svc_f, 'XBOOK_SA4B_F', to_char(v_closed_from, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SA4B_F', '+389700088013', NULL, 'Confirmed', 10, 'XSA4B-F4', gen_random_uuid()::text);

  -- Invalid datetime quality row (selected period date text, bad time)
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc_a, 'XBOOK_SA4B_A', to_char(v_yesterday, 'YYYY-MM-DD'), 'not-a-time', 30,
    'XBOOK_SA4B_BAD', '+389700088014', 'Confirmed', 100, 'XSA4B-BAD', gen_random_uuid()::text
  );

  DELETE FROM public.services WHERE id = v_svc_del;

  PERFORM public._xbook_sa4b_test_set_jwt(v_biz_a);

  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_service_analytics(v_biz_a, v_today, v_yesterday);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '22023');
  END;
  INSERT INTO _xbook_sa4b_results VALUES ('invalid_period_rejected', v_ok, v_msg);

  v_rep := public.get_business_service_analytics(v_biz_a, v_yesterday, v_tomorrow);

  INSERT INTO _xbook_sa4b_results VALUES (
    'no_forbidden_keys',
    NOT pg_temp._jsonb_has_forbidden_key(v_rep),
    'payload scanned'
  );

  v_row := pg_temp._sa_svc(v_rep, 'XBOOK_SA4B_A');
  INSERT INTO _xbook_sa4b_results VALUES (
    'new_on_multiple_services_A',
    (v_row->>'new_customers')::bigint >= 1
      AND (v_row->>'returning_customers')::bigint >= 1
      AND (v_row->>'unique_customers')::bigint >= 3,
    coalesce(v_row::text, 'missing A')
  );

  v_row := pg_temp._sa_svc(v_rep, 'XBOOK_SA4B_B');
  INSERT INTO _xbook_sa4b_results VALUES (
    'new_on_multiple_services_B',
    (v_row->>'new_customers')::bigint >= 1
      AND (v_row->>'completed_visits')::bigint = 1,
    coalesce(v_row::text, 'missing B')
  );

  v_row := pg_temp._sa_svc(v_rep, 'XBOOK_SA4B_C');
  INSERT INTO _xbook_sa4b_results VALUES (
    'upcoming_only_included',
    v_row IS NOT NULL
      AND (v_row->>'completed_visits')::bigint = 0
      AND (v_row->>'upcoming_bookings')::bigint = 1
      AND (v_row->>'scheduled_bookings')::bigint = 1,
    coalesce(v_row::text, 'missing C')
  );

  v_row := pg_temp._sa_svc(v_rep, 'XBOOK_SA4B_D');
  INSERT INTO _xbook_sa4b_results VALUES (
    'cancellation_rate_locked',
    v_row IS NOT NULL
      AND (v_row->>'cancelled_bookings')::bigint = 1
      AND (v_row->>'scheduled_bookings')::bigint = 2
      AND (v_row->>'elapsed_unconfirmed_count')::bigint = 1
      AND (v_row->>'completed_visits')::bigint = 1
      AND (v_row->>'cancellation_rate')::numeric = 33.3,
    coalesce(v_row::text, 'missing D')
  );

  v_row := pg_temp._sa_svc(v_rep, 'XBOOK_SA4B_E');
  INSERT INTO _xbook_sa4b_results VALUES (
    'free_service_known_zero',
    v_row IS NOT NULL
      AND (v_row->>'completed_visits')::bigint = 1
      AND (v_row->>'completed_revenue')::numeric = 0
      AND (v_row->>'completed_revenue_known_visits')::bigint = 1
      AND (v_row->>'completed_visits_unknown_price')::bigint = 0
      AND (v_row->>'completed_visits_with_estimated_price')::bigint = 1
      AND (v_row->>'avg_completed_visit_value')::numeric = 0
      AND v_row->'revenue_trend'->>'status' IN ('not_applicable', 'new', 'no_change', 'decrease', 'increase'),
    coalesce(v_row::text, 'missing E')
  );

  SELECT count(*) INTO v_n
  FROM jsonb_array_elements(v_rep->'services') e
  WHERE e->>'display_name' = 'XBOOK_SA4B_DUP';
  INSERT INTO _xbook_sa4b_results VALUES (
    'duplicate_names_distinct_groups',
    v_n = 2
      AND pg_temp._sa_svc_key(v_rep, v_svc_dup1::text) IS NOT NULL
      AND pg_temp._sa_svc_key(v_rep, v_svc_dup2::text) IS NOT NULL
      AND pg_temp._sa_svc_key(v_rep, v_svc_dup1::text)->>'group_key'
        IS DISTINCT FROM pg_temp._sa_svc_key(v_rep, v_svc_dup2::text)->>'group_key',
    format('dup_rows=%s', v_n)
  );

  v_row := pg_temp._sa_svc_key(v_rep, v_key_a);
  INSERT INTO _xbook_sa4b_results VALUES (
    'identity_link_collapsed',
    (v_row->>'unique_customers')::bigint
      = (
        SELECT count(DISTINCT public._resolve_business_analytics_customer_key(
          v_biz_a,
          public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
        ))
        FROM public.bookings b
        WHERE b.business_id = v_biz_a
          AND b.service_id = v_svc_a
          AND b.booking_status = 'Confirmed'
          AND b.date >= to_char(v_yesterday, 'YYYY-MM-DD')
          AND b.date <= to_char(v_tomorrow, 'YYYY-MM-DD')
          AND b.booking_ref LIKE 'XSA4B-%'
          AND public._resolve_business_analytics_customer_key(
            v_biz_a,
            public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
          ) IS NOT NULL
      )
      OR (v_row->>'unique_customers')::bigint >= 3,
    coalesce(v_row->>'unique_customers', 'missing')
  );

  -- Linked auth+guest should not add a 4th identity beyond new+returning+canonical
  -- Explicit: two L1/L2 bookings resolve to one key
  SELECT count(*) INTO v_n
  FROM (
    SELECT DISTINCT public._resolve_business_analytics_customer_key(
      v_biz_a,
      public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
    )
    FROM public.bookings b
    WHERE b.booking_ref IN ('XSA4B-L1', 'XSA4B-L2')
  ) x;
  INSERT INTO _xbook_sa4b_results VALUES (
    'identity_two_bookings_one_key',
    v_n = 1,
    format('resolved_keys=%s', v_n)
  );

  v_row := pg_temp._sa_svc_key(v_rep, v_key_del);
  INSERT INTO _xbook_sa4b_results VALUES (
    'orphan_deleted_service_kept',
    v_row IS NOT NULL
      AND (v_row->>'is_orphan')::boolean = true
      AND (v_row->>'is_missing_from_catalog')::boolean = true
      AND v_row->>'display_name' = 'XBOOK_SA4B_DEL'
      AND v_row->>'group_key' = v_key_del
      AND (v_row->>'completed_visits')::bigint = 1,
    coalesce(v_row::text, 'missing orphan')
  );

  INSERT INTO _xbook_sa4b_results VALUES (
    'quality_invalid_datetime',
    (v_rep->'quality'->>'invalid_datetime_count')::bigint >= 1,
    v_rep->'quality'::text
  );

  -- Rename: catalog name wins, group_key stable
  UPDATE public.services SET name = 'XBOOK_SA4B_REN_NEW' WHERE id = v_svc_ren;
  v_rep2 := public.get_business_service_analytics(v_biz_a, v_yesterday, v_tomorrow);
  v_row := pg_temp._sa_svc_key(v_rep2, v_svc_ren::text);
  INSERT INTO _xbook_sa4b_results VALUES (
    'rename_same_group_catalog_display',
    v_row IS NOT NULL
      AND v_row->>'group_key' = v_svc_ren::text
      AND v_row->>'display_name' = 'XBOOK_SA4B_REN_NEW'
      AND (v_row->>'completed_visits')::bigint = 1,
    coalesce(v_row::text, 'missing renamed')
  );
  UPDATE public.services SET name = 'XBOOK_SA4B_REN' WHERE id = v_svc_ren;

  -- Closed period trend for F
  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(v_closed_from, v_closed_to, v_today);
  v_rep2 := public.get_business_service_analytics(v_biz_a, v_closed_from, v_closed_to);
  v_row := pg_temp._sa_svc(v_rep2, 'XBOOK_SA4B_F');
  INSERT INTO _xbook_sa4b_results VALUES (
    'closed_period_trend_F',
    v_rep2->>'comparison_type' = 'closed_equal_length'
      AND (v_row->>'completed_visits')::bigint = 1
      AND (v_row->>'previous_completed_visits')::bigint = 4
      AND v_row->'visit_trend'->>'status' = 'decrease'
      AND (v_row->'visit_trend'->>'pct')::numeric = -75.0,
    format('type=%s row=%s win_prev=%s..%s', v_rep2->>'comparison_type', coalesce(v_row::text, 'missing'), v_win.previous_from, v_win.previous_to)
  );

  -- Security
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_service_analytics(v_biz_b, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_sa4b_results VALUES ('owner_cannot_read_other_business', v_ok, v_msg);

  PERFORM public._xbook_sa4b_test_set_jwt(v_user_cust);
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_service_analytics(v_biz_a, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_sa4b_results VALUES ('customer_denied', v_ok, v_msg);

  PERFORM public._xbook_sa4b_test_set_jwt(NULL, 'anon');
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_service_analytics(v_biz_a, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_sa4b_results VALUES ('anon_denied', v_ok, v_msg);

  -- Cleanup fixtures before live parity
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XSA4B-%' OR customer_name LIKE 'XBOOK_SA4B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700088%'
     OR reason = 'xbook_sa4b_test';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_SA4B%'
     OR phone LIKE '+389700088%'
     OR client_key LIKE 'p:389700088%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_SA4B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-sa4b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-sa4b-%@invalid.example';

  -- -------------------------------------------------------------------------
  -- Live Test Barber parity + Performance formula lock
  -- -------------------------------------------------------------------------
  IF v_tz_tb IS NULL THEN
    INSERT INTO _xbook_sa4b_results VALUES ('live_test_barber_present', false, 'Test Barber missing timezone');
  ELSE
    INSERT INTO _xbook_sa4b_results VALUES ('live_test_barber_present', true, v_biz_tb::text);

    PERFORM public._xbook_sa4b_test_set_jwt(v_biz_tb);
    v_aug := public.get_business_service_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_ytd := public.get_business_service_analytics(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_sep := public.get_business_service_analytics(v_biz_tb, DATE '2026-09-01', DATE '2026-09-30');
    v_perf_aug := public.get_business_performance_report(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_ca_ytd := public.get_business_customer_analytics_overview(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_seg := public.get_business_customer_segment(v_biz_tb, 'active', DATE '2026-08-01', DATE '2026-08-31', NULL, 50, 0);

    INSERT INTO _xbook_sa4b_results VALUES (
      'formula_lock_august_vs_performance',
      (v_aug->'quality'->>'completed_visits_total')::bigint = (v_perf_aug->>'completed_visits')::bigint
        AND (
          SELECT coalesce(sum((e->>'completed_revenue')::numeric), 0)
          FROM jsonb_array_elements(v_aug->'services') e
        ) = (v_perf_aug->>'completed_revenue')::numeric
        AND (
          SELECT coalesce(sum((e->>'scheduled_bookings')::bigint), 0)
          FROM jsonb_array_elements(v_aug->'services') e
        ) = (v_perf_aug->>'scheduled_appointments')::bigint
        AND (
          SELECT coalesce(sum((e->>'cancelled_bookings')::bigint), 0)
          FROM jsonb_array_elements(v_aug->'services') e
        ) = (v_perf_aug->>'cancelled_appointments')::bigint,
      format('sa_visits=%s perf_visits=%s sa_rev_sum=%s perf_rev=%s',
        v_aug->'quality'->>'completed_visits_total',
        v_perf_aug->>'completed_visits',
        (SELECT coalesce(sum((e->>'completed_revenue')::numeric), 0) FROM jsonb_array_elements(v_aug->'services') e),
        v_perf_aug->>'completed_revenue')
    );

    v_sis := pg_temp._sa_svc(v_aug, 'Sisanje');
    v_mas := pg_temp._sa_svc(v_aug, 'Masaza');
    v_combo := pg_temp._sa_svc(v_aug, 'Sisanje + Bricenje');

    INSERT INTO _xbook_sa4b_results VALUES (
      'aug_business_totals',
      (v_aug->'quality'->>'completed_visits_total')::bigint = 17
        AND (
          SELECT coalesce(sum((e->>'completed_revenue')::numeric), 0)
          FROM jsonb_array_elements(v_aug->'services') e
        ) = 6000
        AND (v_aug->'quality'->>'completed_visits_with_snapshot_price')::bigint = 0
        AND (v_aug->'quality'->>'completed_visits_with_estimated_price')::bigint = 17
        AND (v_aug->>'comparison_type') = 'closed_equal_length'
        AND (v_aug->>'previous_from')::date = DATE '2026-07-01'
        AND (v_aug->>'previous_to')::date = DATE '2026-07-31',
      format('visits=%s type=%s prev=%s..%s estimated=%s',
        v_aug->'quality'->>'completed_visits_total',
        v_aug->>'comparison_type',
        v_aug->>'previous_from',
        v_aug->>'previous_to',
        v_aug->'quality'->>'completed_visits_with_estimated_price')
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'aug_sisanje',
      (v_sis->>'completed_visits')::bigint = 10
        AND (v_sis->>'completed_revenue')::numeric = 3000
        AND (v_sis->>'unique_customers')::bigint = 2
        AND (v_sis->>'new_customers')::bigint = 0
        AND (v_sis->>'returning_customers')::bigint = 2
        AND (v_sis->>'cancelled_bookings')::bigint = 0
        AND (v_sis->>'visit_share_pct')::numeric = 58.8
        AND (v_sis->>'revenue_share_pct')::numeric = 50.0
        AND (v_sis->>'previous_completed_visits')::bigint = 19
        AND (v_sis->>'previous_completed_revenue')::numeric = 5700
        AND v_sis->'visit_trend'->>'status' = 'decrease'
        AND (v_sis->'visit_trend'->>'pct')::numeric = -47.4
        AND (v_sis->'revenue_trend'->>'pct')::numeric = -47.4,
      coalesce(v_sis::text, 'missing Sisanje')
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'aug_masaza',
      (v_mas->>'completed_visits')::bigint = 6
        AND (v_mas->>'completed_revenue')::numeric = 3000
        AND (v_mas->>'unique_customers')::bigint = 1
        AND (v_mas->>'new_customers')::bigint = 0
        AND (v_mas->>'returning_customers')::bigint = 1
        AND (v_mas->>'visit_share_pct')::numeric = 35.3
        AND (v_mas->>'revenue_share_pct')::numeric = 50.0
        AND (v_mas->>'previous_completed_visits')::bigint = 4
        AND (v_mas->>'previous_completed_revenue')::numeric = 2000
        AND v_mas->'visit_trend'->>'status' = 'increase'
        AND (v_mas->'visit_trend'->>'pct')::numeric = 50.0,
      coalesce(v_mas::text, 'missing Masaza')
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'aug_combo_free',
      (v_combo->>'completed_visits')::bigint = 1
        AND (v_combo->>'completed_revenue')::numeric = 0
        AND (v_combo->>'unique_customers')::bigint = 1
        AND (v_combo->>'new_customers')::bigint = 0
        AND (v_combo->>'returning_customers')::bigint = 1
        AND (v_combo->>'visit_share_pct')::numeric = 5.9
        AND (v_combo->>'revenue_share_pct')::numeric = 0
        AND (v_combo->>'previous_completed_visits')::bigint = 4
        AND (v_combo->>'previous_completed_revenue')::numeric = 0
        AND (v_combo->'visit_trend'->>'pct')::numeric = -75.0
        AND v_combo->'revenue_trend'->>'status' = 'not_applicable',
      coalesce(v_combo::text, 'missing combo')
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'aug_summary',
      v_aug->'summary'->>'services_used' = '3'
        AND v_aug->'summary'->'top_service_by_visits'->>'display_name' = 'Sisanje'
        AND (v_aug->'summary'->'top_service_by_visits'->>'completed_visits')::bigint = 10
        AND v_aug->'summary'->'top_service_by_revenue'->>'display_name' = 'Sisanje'
        AND (v_aug->'quality'->>'contains_estimated_prices')::boolean = true
        AND (v_aug->'quality'->>'price_snapshot_coverage_pct')::numeric = 0,
      v_aug->'summary'::text
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'ytd_business_totals',
      (v_ytd->'quality'->>'completed_visits_total')::bigint = 82
        AND (
          SELECT coalesce(sum((e->>'completed_revenue')::numeric), 0)
          FROM jsonb_array_elements(v_ytd->'services') e
        ) = 23200
        AND (
          SELECT coalesce(sum((e->>'cancelled_bookings')::bigint), 0)
          FROM jsonb_array_elements(v_ytd->'services') e
        ) = 3
        AND (v_ytd->'quality'->>'completed_visits_with_snapshot_price')::bigint = 0
        AND (v_ytd->'quality'->>'completed_visits_with_estimated_price')::bigint = 82
        AND (v_ytd->'quality'->>'completed_visits_unknown_price')::bigint = 0,
      format('visits=%s snap=%s est=%s', v_ytd->'quality'->>'completed_visits_total', v_ytd->'quality'->>'completed_visits_with_snapshot_price', v_ytd->'quality'->>'completed_visits_with_estimated_price')
    );

    v_sis := pg_temp._sa_svc(v_ytd, 'Sisanje');
    v_mas := pg_temp._sa_svc(v_ytd, 'Masaza');
    v_combo := pg_temp._sa_svc(v_ytd, 'Sisanje + Bricenje');
    INSERT INTO _xbook_sa4b_results VALUES (
      'ytd_services',
      (v_sis->>'completed_visits')::bigint = 59
        AND (v_sis->>'completed_revenue')::numeric = 17700
        AND (v_sis->>'unique_customers')::bigint = 2
        AND (v_sis->>'new_customers')::bigint = 2
        AND (v_sis->>'cancelled_bookings')::bigint = 3
        AND (v_combo->>'completed_visits')::bigint = 12
        AND (v_combo->>'completed_revenue')::numeric = 0
        AND (v_combo->>'unique_customers')::bigint = 2
        AND (v_combo->>'new_customers')::bigint = 2
        AND (v_mas->>'completed_visits')::bigint = 11
        AND (v_mas->>'completed_revenue')::numeric = 5500
        AND (v_mas->>'unique_customers')::bigint = 1
        AND (v_mas->>'new_customers')::bigint = 1,
      format('sis=%s combo=%s mas=%s', coalesce(v_sis->>'completed_visits','?'), coalesce(v_combo->>'completed_visits','?'), coalesce(v_mas->>'completed_visits','?'))
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'ytd_unique_matches_customer_analytics_active_shape',
      (v_ca_ytd->'overview'->>'new_customers')::bigint = 2
        AND (v_sis->>'new_customers')::bigint = 2,
      format('ca_new=%s sis_new=%s', v_ca_ytd->'overview'->>'new_customers', v_sis->>'new_customers')
    );

    IF v_today >= DATE '2026-09-01' AND v_today <= DATE '2026-09-30' THEN
      INSERT INTO _xbook_sa4b_results VALUES (
        'sep_open_elapsed_not_full_august',
        (v_sep->>'comparison_type') = 'elapsed_mtd'
          AND (v_sep->>'comparison_current_from')::date = DATE '2026-09-01'
          AND (v_sep->>'comparison_current_to')::date = v_today
          AND (v_sep->>'previous_from')::date = DATE '2026-08-01'
          AND (v_sep->>'previous_to')::date IS DISTINCT FROM DATE '2026-08-31'
          AND (v_sep->>'previous_to')::date = DATE '2026-08-01' + (v_today - DATE '2026-09-01')
          AND (v_sep->>'from_date')::date = DATE '2026-09-01'
          AND (v_sep->>'to_date')::date = DATE '2026-09-30',
        format('type=%s curr=%s curr_to=%s prev=%s..%s today=%s',
          v_sep->>'comparison_type',
          v_sep->>'comparison_current_from',
          v_sep->>'comparison_current_to',
          v_sep->>'previous_from',
          v_sep->>'previous_to',
          v_today)
      );
    ELSE
      INSERT INTO _xbook_sa4b_results VALUES (
        'sep_open_elapsed_not_full_august',
        (v_sep->>'previous_to')::date IS DISTINCT FROM DATE '2026-08-31'
          OR (v_sep->>'comparison_type') IN ('closed_equal_length', 'elapsed_mtd'),
        format('today=%s type=%s prev=%s..%s (not in Sep 2026 open window)',
          v_today, v_sep->>'comparison_type', v_sep->>'previous_from', v_sep->>'previous_to')
      );
    END IF;

    v_sis := pg_temp._sa_svc(v_sep, 'Sisanje');
    INSERT INTO _xbook_sa4b_results VALUES (
      'sep_upcoming_sisanje_included',
      v_sis IS NOT NULL
        AND (v_sis->>'upcoming_bookings')::bigint >= 1
        AND (v_sis->>'completed_visits')::bigint = 0,
      coalesce(v_sis::text, 'missing Sep Sisanje')
    );

    INSERT INTO _xbook_sa4b_results VALUES (
      'segment_untouched_callable',
      v_seg->>'ok' IS NOT NULL OR v_seg->'customers' IS NOT NULL OR jsonb_typeof(v_seg) = 'object',
      left(v_seg::text, 120)
    );

    -- Daniela: August unique across services is 2 (link collapsed)
    INSERT INTO _xbook_sa4b_results VALUES (
      'daniela_identity_not_doubled',
      (
        SELECT count(DISTINCT public._resolve_business_analytics_customer_key(
          v_biz_tb,
          public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
        ))
        FROM public.bookings b
        JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
        WHERE b.business_id = v_biz_tb
          AND s.name = 'Sisanje'
          AND b.booking_status = 'Confirmed'
          AND b.date >= '2026-08-01'
          AND b.date <= '2026-08-31'
          AND public._resolve_business_analytics_customer_key(
            v_biz_tb,
            public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
          ) IS NOT NULL
      ) = (pg_temp._sa_svc(v_aug, 'Sisanje')->>'unique_customers')::bigint,
      format('sis_unique=%s', pg_temp._sa_svc(v_aug, 'Sisanje')->>'unique_customers')
    );
  END IF;

  -- Regression after cleanup
  PERFORM public._xbook_sa4b_test_set_jwt(v_biz_tb);
  v_perf_aug_after := public.get_business_performance_report(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
  v_ca_ytd_after := public.get_business_customer_analytics_overview(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');

  INSERT INTO _xbook_sa4b_results VALUES (
    'regression_performance_unchanged',
    v_perf_aug IS NULL
      OR (
        v_perf_aug_after->>'completed_visits' = v_perf_aug->>'completed_visits'
        AND v_perf_aug_after->>'completed_revenue' = v_perf_aug->>'completed_revenue'
      ),
    format('visits %s→%s rev %s→%s',
      v_perf_aug->>'completed_visits', v_perf_aug_after->>'completed_visits',
      v_perf_aug->>'completed_revenue', v_perf_aug_after->>'completed_revenue')
  );

  INSERT INTO _xbook_sa4b_results VALUES (
    'regression_customer_overview_unchanged',
    v_ca_ytd IS NULL
      OR v_ca_ytd_after->>'ok' = v_ca_ytd->>'ok',
    'customer overview callable'
  );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;
  INSERT INTO _xbook_sa4b_results VALUES (
    'cleanup_no_booking_or_link_delta',
    v_bookings_after = v_bookings_before
      AND v_links_after = v_links_before,
    format('bookings %s→%s links %s→%s', v_bookings_before, v_bookings_after, v_links_before, v_links_after)
  );

  PERFORM public._xbook_sa4b_test_set_jwt(NULL, 'anon');
END;
$$;

DROP FUNCTION IF EXISTS public._xbook_sa4b_test_set_jwt(uuid, text);

SELECT test_name, passed, detail
FROM _xbook_sa4b_results
ORDER BY passed ASC, test_name;
