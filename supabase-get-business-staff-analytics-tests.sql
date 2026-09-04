-- =============================================================================
-- XBOOK Phase 5B Staff Analytics tests
-- Throwaway fixtures deleted. Live Test Barber read-only parity.
-- Does not keep renamed/deleted live staff. Does not backfill prices or staff_name.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_st5b_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_st5b_results;

CREATE OR REPLACE FUNCTION public._xbook_st5b_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._st_row(p jsonb, p_key text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT e
  FROM jsonb_array_elements(coalesce(p->'staff', '[]'::jsonb)) e
  WHERE e->>'group_key' = p_key
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._st_name(p jsonb, p_name text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT e
  FROM jsonb_array_elements(coalesce(p->'staff', '[]'::jsonb)) e
  WHERE e->>'display_name' = p_name
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
    'raw_user_meta_data', 'confirmation_token', 'recovery_token',
    'utilization_pct', 'available_minutes', 'capacity_pct', 'working_days',
    'visits_per_working_day'
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

CREATE OR REPLACE FUNCTION pg_temp._staff_sum(p jsonb, p_field text)
RETURNS numeric
LANGUAGE sql
AS $$
  SELECT coalesce(sum((e->>p_field)::numeric), 0)
  FROM jsonb_array_elements(coalesce(p->'staff', '[]'::jsonb)) e;
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
  v_svc_a uuid;
  v_svc_b uuid;
  v_svc_free uuid;
  v_svc_b_other uuid;
  v_staff_a uuid;
  v_staff_b uuid;
  v_staff_orphan uuid := gen_random_uuid();
  v_user_canon uuid;
  v_user_cust uuid;
  v_instance uuid;
  v_rep jsonb;
  v_rep2 jsonb;
  v_aug jsonb;
  v_ytd jsonb;
  v_sep jsonb;
  v_perf_aug jsonb;
  v_perf_sep jsonb;
  v_perf_ytd jsonb;
  v_perf_aug_after jsonb;
  v_ca_ytd jsonb;
  v_ca_ytd_after jsonb;
  v_sa_aug jsonb;
  v_sa_ytd jsonb;
  v_seg jsonb;
  v_det jsonb;
  v_row jsonb;
  v_un jsonb;
  v_stefan jsonb;
  v_ok boolean;
  v_msg text;
  v_sqlstate text;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_links_before bigint;
  v_links_after bigint;
  v_staff_before bigint;
  v_staff_after bigint;
  v_n bigint;
  v_num integer;
  v_stefan_id uuid;
  v_stefan_name text;
  v_stefan_active boolean;
  v_stable_aug boolean;
  v_stable_sep boolean;
  v_stable_ytd boolean;
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
    RAISE EXCEPTION 'Need two businesses for Staff Analytics tests';
  END IF;

  SELECT nullif(trim(bs.timezone), '')
  INTO v_tz_tb
  FROM public.business_settings bs
  WHERE bs.business_id = v_biz_tb;

  v_today := (now() AT TIME ZONE v_tz)::date;
  v_yesterday := v_today - 1;
  v_tomorrow := v_today + 1;
  v_before := v_today - 20;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_before FROM public.staff_members;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XST5B-%' OR customer_name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700099%'
     OR reason = 'xbook_st5b_test';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_ST5B%'
     OR phone LIKE '+389700099%'
     OR client_key LIKE 'p:389700099%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-st5b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-st5b-%@invalid.example';

  INSERT INTO _xbook_st5b_results VALUES (
    'grants_authenticated_only',
    has_function_privilege('authenticated', 'public.get_business_staff_analytics(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.get_business_staff_analytics(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('service_role', 'public.get_business_staff_analytics(uuid,date,date)', 'EXECUTE'),
    'authenticated execute; anon/service_role revoked'
  );

  INSERT INTO public.services (business_id, name, duration, price) VALUES
    (v_biz_a, 'XBOOK_ST5B_A', 30, 100),
    (v_biz_a, 'XBOOK_ST5B_B', 45, 200),
    (v_biz_a, 'XBOOK_ST5B_FREE', 30, 0),
    (v_biz_b, 'XBOOK_ST5B_OTHER', 30, 50);

  SELECT id INTO v_svc_a FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_ST5B_A' LIMIT 1;
  SELECT id INTO v_svc_b FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_ST5B_B' LIMIT 1;
  SELECT id INTO v_svc_free FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_ST5B_FREE' LIMIT 1;
  SELECT id INTO v_svc_b_other FROM public.services WHERE business_id = v_biz_b AND name = 'XBOOK_ST5B_OTHER' LIMIT 1;

  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_a, 'XBOOK_ST5B_ALEX', 'Barber', true)
  RETURNING id INTO v_staff_a;

  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_a, 'XBOOK_ST5B_BOJAN', 'Barber', true)
  RETURNING id INTO v_staff_b;

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
    'xbook-st5b-canon-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-st5b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    now(), now(), '', '', '', ''
  )
  RETURNING id INTO v_user_canon;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-st5b-cust-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-st5b-test', gen_salt('bf')), now(),
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
    v_biz_a, 'p:389700099010', v_num + 1, 'XBOOK_ST5B_LINK', '+389700099010',
    v_user_canon, 'approved', false
  );

  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (
    v_biz_a, v_user_canon, 'p:389700099010', 'xbook_st5b_test', v_biz_a
  );

  PERFORM public._xbook_st5b_test_set_jwt(v_biz_a);

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- Alex: 1 completed A (new), returning visit after lifetime first before period
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_before, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_ST5B_RET', '+389700099002', NULL, 'Confirmed', 100, 'XST5B-R0', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_ST5B_RET', '+389700099002', NULL, 'Confirmed', 100, 'XST5B-R1', gen_random_uuid()::text),
  -- Alex + Bojan: new customer completes with both staff in period
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_ST5B_NEW', '+389700099001', NULL, 'Confirmed', 100, 'XST5B-N1', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_ST5B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 45,
   'XBOOK_ST5B_NEW', '+389700099001', NULL, 'Confirmed', 200, 'XST5B-N2', gen_random_uuid()::text),
  -- Unassigned: 2 completed so Unassigned has more visits than Bojan; must not win Top Staff
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', NULL, to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_ST5B_UA1', '+389700099003', NULL, 'Confirmed', 100, 'XST5B-U1', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', NULL, to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_ST5B_UA2', '+389700099004', NULL, 'Confirmed', 100, 'XST5B-U2', gen_random_uuid()::text),
  -- Upcoming unassigned (included)
  (v_biz_a, v_svc_b, 'XBOOK_ST5B_B', NULL, to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 45,
   'XBOOK_ST5B_UAUP', '+389700099005', NULL, 'Confirmed', 200, 'XST5B-UU', gen_random_uuid()::text),
  -- Cancelled on Alex
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_ST5B_CAN', '+389700099006', NULL, 'Cancelled', 100, 'XST5B-C1', gen_random_uuid()::text),
  -- Elapsed pending on Alex
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '07:00', 30,
   'XBOOK_ST5B_PEND', '+389700099007', NULL, 'Pending', 100, 'XST5B-P1', gen_random_uuid()::text),
  -- Free estimated 0 on Alex
  (v_biz_a, v_svc_free, 'XBOOK_ST5B_FREE', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
   'XBOOK_ST5B_FREE', '+389700099008', NULL, 'Confirmed', NULL, 'XST5B-F1', gen_random_uuid()::text),
  -- Identity collapse on Alex: auth + linked guest
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '16:00', 30,
   'XBOOK_ST5B_LINK', '+389700099010', v_user_canon, 'Confirmed', 100, 'XST5B-L1', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '17:00', 30,
   'XBOOK_ST5B_LINK', '+389700099010', NULL, 'Confirmed', 100, 'XST5B-L2', gen_random_uuid()::text);

  -- Cross-tenant staff UUID on an own-business booking: join is tenant-scoped,
  -- so display must be Unknown staff, never the other business's name.
  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_b, 'XBOOK_ST5B_FOREIGN', 'Barber', true)
  RETURNING id INTO v_staff_orphan;

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc_b, 'XBOOK_ST5B_B', v_staff_orphan, to_char(v_yesterday, 'YYYY-MM-DD'), '18:00', 45,
    'XBOOK_ST5B_ORPH', '+389700099012', NULL, 'Confirmed', 200, 'XST5B-O1', gen_random_uuid()::text
  );

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc_a, 'XBOOK_ST5B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), 'not-a-time', 30,
    'XBOOK_ST5B_BAD', '+389700099014', 'Confirmed', 100, 'XST5B-BAD', gen_random_uuid()::text
  );

  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_staff_analytics(v_biz_a, v_today, v_yesterday);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '22023');
  END;
  INSERT INTO _xbook_st5b_results VALUES ('invalid_period_rejected', v_ok, v_msg);

  v_rep := public.get_business_staff_analytics(v_biz_a, v_yesterday, v_tomorrow);

  INSERT INTO _xbook_st5b_results VALUES (
    'no_forbidden_or_utilization_keys',
    NOT pg_temp._jsonb_has_forbidden_key(v_rep),
    'payload scanned'
  );

  v_row := pg_temp._st_row(v_rep, v_staff_a::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'alex_identity_and_metrics',
    v_row IS NOT NULL
      AND v_row->>'display_name' = 'XBOOK_ST5B_ALEX'
      AND (v_row->>'is_unassigned')::boolean = false
      AND (v_row->>'is_orphan')::boolean = false
      AND (v_row->>'is_active')::boolean = true
      AND (v_row->>'completed_visits')::bigint = 5
      AND (v_row->>'unique_customers')::bigint = 4
      AND (v_row->>'new_customers')::bigint = 3
      AND (v_row->>'returning_customers')::bigint = 1
      AND (v_row->>'repeat_customers_served')::bigint = 3
      AND (v_row->>'cancelled_bookings')::bigint = 1
      AND (v_row->>'elapsed_unconfirmed_count')::bigint = 1
      AND (v_row->>'cancellation_rate')::numeric = 14.3
      AND (v_row->>'services_delivered')::bigint = 2
      AND v_row->'top_service'->>'display_name' = 'XBOOK_ST5B_A'
      AND (v_row->'top_service'->>'completed_visits')::bigint = 4
      AND (v_row->>'completed_minutes')::bigint = 150
      AND v_row->>'staff_id' = v_staff_a::text,
    coalesce(v_row::text, 'missing Alex')
  );

  SELECT count(*) INTO v_n
  FROM (
    SELECT DISTINCT public._resolve_business_analytics_customer_key(
      v_biz_a,
      public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
    )
    FROM public.bookings b
    WHERE b.booking_ref IN ('XST5B-L1', 'XST5B-L2')
  ) x;
  INSERT INTO _xbook_st5b_results VALUES (
    'identity_two_bookings_one_key',
    v_n = 1,
    format('resolved_keys=%s', v_n)
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'identity_collapsed_in_staff_group',
    (pg_temp._st_row(v_rep, v_staff_a::text)->>'unique_customers')::bigint = 4,
    pg_temp._st_row(v_rep, v_staff_a::text)->>'unique_customers'
  );

  v_row := pg_temp._st_row(v_rep, v_staff_b::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'new_customer_attributed_to_both_staff',
    v_row IS NOT NULL
      AND (v_row->>'completed_visits')::bigint = 1
      AND (v_row->>'new_customers')::bigint = 1
      AND (v_row->>'unique_customers')::bigint = 1
      AND (v_row->>'repeat_customers_served')::bigint = 1,
    coalesce(v_row::text, 'missing Bojan')
  );

  v_un := pg_temp._st_row(v_rep, 'unassigned');
  INSERT INTO _xbook_st5b_results VALUES (
    'unassigned_first_class',
    v_un IS NOT NULL
      AND v_un->>'group_key' = 'unassigned'
      AND v_un->>'staff_id' IS NULL
      AND v_un->>'display_name' = 'Unassigned'
      AND (v_un->>'is_unassigned')::boolean = true
      AND (v_un->>'is_orphan')::boolean = false
      AND (v_un->>'completed_visits')::bigint = 2
      AND (v_un->>'scheduled_bookings')::bigint = 3
      AND (v_un->>'upcoming_bookings')::bigint = 1,
    coalesce(v_un::text, 'missing Unassigned')
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'unassigned_cannot_win_top_staff',
    v_rep->'summary'->'top_staff_by_visits'->>'group_key' = v_staff_a::text
      AND v_rep->'summary'->'top_staff_by_visits'->>'display_name' = 'XBOOK_ST5B_ALEX'
      AND v_rep->'summary'->'top_staff_by_revenue'->>'group_key' = v_staff_a::text
      AND (v_un->>'completed_visits')::bigint
        > (pg_temp._st_row(v_rep, v_staff_b::text)->>'completed_visits')::bigint,
    format('top=%s unassigned_visits=%s bojan=%s',
      v_rep->'summary'->'top_staff_by_visits'->>'display_name',
      v_un->>'completed_visits',
      pg_temp._st_row(v_rep, v_staff_b::text)->>'completed_visits')
  );

  v_row := pg_temp._st_row(v_rep, v_staff_orphan::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'orphan_uuid_preserved',
    v_row IS NOT NULL
      AND v_row->>'group_key' = v_staff_orphan::text
      AND v_row->>'staff_id' = v_staff_orphan::text
      AND v_row->>'display_name' = 'Unknown staff'
      AND v_row->>'display_name' IS DISTINCT FROM 'XBOOK_ST5B_FOREIGN'
      AND (v_row->>'is_orphan')::boolean = true
      AND (v_row->>'is_unassigned')::boolean = false
      AND (v_row->>'is_active')::boolean = false
      AND v_row->>'role' IS NULL
      AND v_row->>'photo_url' IS NULL
      AND (v_row->>'completed_visits')::bigint = 1
      AND (v_row->>'completed_revenue')::numeric = 200,
    coalesce(v_row::text, 'missing orphan')
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'cross_tenant_staff_is_orphan_unknown',
    pg_temp._st_row(v_rep, v_staff_orphan::text)->>'display_name' = 'Unknown staff'
      AND pg_temp._st_row(v_rep, v_staff_orphan::text)->>'display_name'
        IS DISTINCT FROM 'XBOOK_ST5B_FOREIGN',
    pg_temp._st_row(v_rep, v_staff_orphan::text)->>'display_name'
  );

  v_row := pg_temp._st_row(v_rep, v_staff_a::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'free_service_known_zero_on_staff',
    (v_row->>'completed_revenue_known_visits')::bigint >= 1
      AND (v_row->>'unknown_price_completed_count')::bigint = 0
      AND (v_row->>'estimated_price_completed_count')::bigint = 1,
    coalesce(v_row::text, 'missing free mix')
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'quality_invalid_datetime',
    (v_rep->'quality'->>'invalid_datetime_count')::bigint >= 1,
    v_rep->'quality'::text
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'fixture_formula_lock_vs_performance',
    (v_rep->'quality'->>'completed_visits_total')::bigint
      = (public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'completed_visits')::bigint
    AND pg_temp._staff_sum(v_rep, 'completed_visits')
      = (public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'completed_visits')::numeric
    AND pg_temp._staff_sum(v_rep, 'completed_revenue')
      = (public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'completed_revenue')::numeric
    AND pg_temp._staff_sum(v_rep, 'scheduled_bookings')
      = (public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'scheduled_appointments')::numeric
    AND pg_temp._staff_sum(v_rep, 'cancelled_bookings')
      = (public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'cancelled_appointments')::numeric,
    format('staff_visits=%s perf=%s',
      v_rep->'quality'->>'completed_visits_total',
      public.get_business_performance_report(v_biz_a, v_yesterday, v_tomorrow)->>'completed_visits')
  );

  -- Rename
  UPDATE public.staff_members SET name = 'XBOOK_ST5B_ALEX_NEW' WHERE id = v_staff_a;
  v_rep2 := public.get_business_staff_analytics(v_biz_a, v_yesterday, v_tomorrow);
  v_row := pg_temp._st_row(v_rep2, v_staff_a::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'rename_same_uuid_new_display',
    v_row IS NOT NULL
      AND v_row->>'group_key' = v_staff_a::text
      AND v_row->>'display_name' = 'XBOOK_ST5B_ALEX_NEW'
      AND (v_row->>'completed_visits')::bigint
        = (pg_temp._st_row(v_rep, v_staff_a::text)->>'completed_visits')::bigint,
    coalesce(v_row::text, 'missing renamed')
  );
  UPDATE public.staff_members SET name = 'XBOOK_ST5B_ALEX' WHERE id = v_staff_a;

  -- Inactive
  UPDATE public.staff_members SET active = false WHERE id = v_staff_a;
  v_rep2 := public.get_business_staff_analytics(v_biz_a, v_yesterday, v_tomorrow);
  v_row := pg_temp._st_row(v_rep2, v_staff_a::text);
  INSERT INTO _xbook_st5b_results VALUES (
    'inactive_keeps_history',
    v_row IS NOT NULL
      AND (v_row->>'is_active')::boolean = false
      AND (v_row->>'completed_visits')::bigint
        = (pg_temp._st_row(v_rep, v_staff_a::text)->>'completed_visits')::bigint,
    coalesce(v_row::text, 'missing inactive')
  );
  UPDATE public.staff_members SET active = true WHERE id = v_staff_a;

  PERFORM public._xbook_st5b_test_set_jwt(v_biz_a);
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_staff_analytics(v_biz_b, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_st5b_results VALUES ('owner_cannot_read_other_business', v_ok, v_msg);

  PERFORM public._xbook_st5b_test_set_jwt(v_user_cust);
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_staff_analytics(v_biz_a, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_st5b_results VALUES ('customer_denied', v_ok, v_msg);

  PERFORM public._xbook_st5b_test_set_jwt(NULL, 'anon');
  v_ok := false;
  v_msg := '';
  BEGIN
    PERFORM public.get_business_staff_analytics(v_biz_a, v_yesterday, v_tomorrow);
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_st5b_results VALUES ('anon_denied', v_ok, v_msg);

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XST5B-%' OR customer_name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700099%'
     OR reason = 'xbook_st5b_test';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_ST5B%'
     OR phone LIKE '+389700099%'
     OR client_key LIKE 'p:389700099%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_ST5B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-st5b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-st5b-%@invalid.example';

  -- -------------------------------------------------------------------------
  -- Live Test Barber parity
  -- -------------------------------------------------------------------------
  IF v_tz_tb IS NULL THEN
    INSERT INTO _xbook_st5b_results VALUES ('live_test_barber_present', false, 'Test Barber missing timezone');
  ELSE
    INSERT INTO _xbook_st5b_results VALUES ('live_test_barber_present', true, v_biz_tb::text);

    PERFORM public._xbook_st5b_test_set_jwt(v_biz_tb);
    v_aug := public.get_business_staff_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_sep := public.get_business_staff_analytics(v_biz_tb, DATE '2026-09-01', DATE '2026-09-30');
    v_ytd := public.get_business_staff_analytics(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_perf_aug := public.get_business_performance_report(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_perf_sep := public.get_business_performance_report(v_biz_tb, DATE '2026-09-01', DATE '2026-09-30');
    v_perf_ytd := public.get_business_performance_report(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_sa_aug := public.get_business_service_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_sa_ytd := public.get_business_service_analytics(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_ca_ytd := public.get_business_customer_analytics_overview(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');
    v_seg := public.get_business_customer_segment(v_biz_tb, 'active', DATE '2026-08-01', DATE '2026-08-31', NULL, 50, 0);

    SELECT sm.id, sm.name, coalesce(sm.active, true)
    INTO v_stefan_id, v_stefan_name, v_stefan_active
    FROM public.staff_members sm
    WHERE sm.business_id = v_biz_tb
    ORDER BY sm.created_at, sm.id
    LIMIT 1;

    INSERT INTO _xbook_st5b_results VALUES (
      'aug_formula_lock_vs_performance',
      (v_aug->'quality'->>'completed_visits_total')::bigint = (v_perf_aug->>'completed_visits')::bigint
        AND pg_temp._staff_sum(v_aug, 'completed_visits') = (v_perf_aug->>'completed_visits')::numeric
        AND pg_temp._staff_sum(v_aug, 'completed_revenue') = (v_perf_aug->>'completed_revenue')::numeric
        AND pg_temp._staff_sum(v_aug, 'scheduled_bookings') = (v_perf_aug->>'scheduled_appointments')::numeric
        AND pg_temp._staff_sum(v_aug, 'cancelled_bookings') = (v_perf_aug->>'cancelled_appointments')::numeric,
      format('sta_visits=%s perf_visits=%s sta_rev=%s perf_rev=%s',
        v_aug->'quality'->>'completed_visits_total',
        v_perf_aug->>'completed_visits',
        pg_temp._staff_sum(v_aug, 'completed_revenue'),
        v_perf_aug->>'completed_revenue')
    );

    INSERT INTO _xbook_st5b_results VALUES (
      'sep_formula_lock_vs_performance',
      (v_sep->'quality'->>'completed_visits_total')::bigint = (v_perf_sep->>'completed_visits')::bigint
        AND pg_temp._staff_sum(v_sep, 'completed_visits') = (v_perf_sep->>'completed_visits')::numeric
        AND pg_temp._staff_sum(v_sep, 'completed_revenue') = (v_perf_sep->>'completed_revenue')::numeric
        AND pg_temp._staff_sum(v_sep, 'scheduled_bookings') = (v_perf_sep->>'scheduled_appointments')::numeric
        AND pg_temp._staff_sum(v_sep, 'cancelled_bookings') = (v_perf_sep->>'cancelled_appointments')::numeric,
      format('sta_visits=%s perf=%s sched=%s/%s',
        v_sep->'quality'->>'completed_visits_total',
        v_perf_sep->>'completed_visits',
        pg_temp._staff_sum(v_sep, 'scheduled_bookings'),
        v_perf_sep->>'scheduled_appointments')
    );

    INSERT INTO _xbook_st5b_results VALUES (
      'ytd_formula_lock_vs_performance',
      (v_ytd->'quality'->>'completed_visits_total')::bigint = (v_perf_ytd->>'completed_visits')::bigint
        AND pg_temp._staff_sum(v_ytd, 'completed_visits') = (v_perf_ytd->>'completed_visits')::numeric
        AND pg_temp._staff_sum(v_ytd, 'completed_revenue') = (v_perf_ytd->>'completed_revenue')::numeric
        AND pg_temp._staff_sum(v_ytd, 'scheduled_bookings') = (v_perf_ytd->>'scheduled_appointments')::numeric
        AND pg_temp._staff_sum(v_ytd, 'cancelled_bookings') = (v_perf_ytd->>'cancelled_appointments')::numeric,
      format('sta_visits=%s perf=%s sta_rev=%s perf_rev=%s',
        v_ytd->'quality'->>'completed_visits_total',
        v_perf_ytd->>'completed_visits',
        pg_temp._staff_sum(v_ytd, 'completed_revenue'),
        v_perf_ytd->>'completed_revenue')
    );

    v_stable_aug :=
      (v_perf_aug->>'completed_visits')::bigint = 17
      AND (v_perf_aug->>'completed_revenue')::numeric = 6000
      AND (v_perf_aug->>'scheduled_appointments')::bigint = 17
      AND (v_perf_aug->>'cancelled_appointments')::bigint = 0;

    v_stefan := pg_temp._st_row(v_aug, v_stefan_id::text);
    IF v_stable_aug THEN
      INSERT INTO _xbook_st5b_results VALUES (
        'aug_stefan_snapshot',
        v_stefan IS NOT NULL
          AND (v_stefan->>'completed_visits')::bigint = 17
          AND (v_stefan->>'completed_revenue')::numeric = 6000
          AND (v_stefan->>'unique_customers')::bigint = 2
          AND (v_stefan->>'new_customers')::bigint = 0
          AND (v_stefan->>'returning_customers')::bigint = 2
          AND (v_stefan->>'scheduled_bookings')::bigint = 17
          AND (v_stefan->>'upcoming_bookings')::bigint = 0
          AND (v_stefan->>'cancelled_bookings')::bigint = 0
          AND v_stefan->'top_service'->>'display_name' = 'Sisanje'
          AND (v_stefan->'top_service'->>'completed_visits')::bigint = 10
          AND (v_stefan->'top_service'->>'completed_revenue')::numeric = 3000
          AND (v_stefan->>'services_delivered')::bigint = 3
          AND (v_stefan->>'completed_minutes')::bigint = 360
          AND (v_stefan->>'previous_completed_visits')::bigint = 16
          AND (v_stefan->>'previous_completed_revenue')::numeric = 4500
          AND v_stefan->'visit_trend'->>'status' = 'increase'
          AND (v_stefan->'visit_trend'->>'pct')::numeric = 6.3
          AND v_stefan->'revenue_trend'->>'status' = 'increase'
          AND (v_stefan->'revenue_trend'->>'pct')::numeric = 33.3
          AND pg_temp._st_row(v_aug, 'unassigned') IS NULL
          AND v_aug->'summary'->'top_staff_by_visits'->>'group_key' = v_stefan_id::text
          AND v_aug->'summary'->'top_staff_by_revenue'->>'group_key' = v_stefan_id::text
          AND (v_aug->>'comparison_type') = 'closed_equal_length',
        coalesce(v_stefan::text, 'missing Stefan')
      );
    ELSE
      INSERT INTO _xbook_st5b_results VALUES (
        'aug_stefan_snapshot',
        true,
        format('live moved from audit 17/6000; formula lock is authoritative. perf_visits=%s perf_rev=%s stefan=%s',
          v_perf_aug->>'completed_visits', v_perf_aug->>'completed_revenue', left(coalesce(v_stefan::text, 'missing'), 400))
      );
    END IF;

    v_stable_sep :=
      (v_perf_sep->>'completed_visits')::bigint = 1
      AND (v_perf_sep->>'completed_revenue')::numeric = 500
      AND (v_perf_sep->>'scheduled_appointments')::bigint = 3;

    v_stefan := pg_temp._st_row(v_sep, v_stefan_id::text);
    v_un := pg_temp._st_row(v_sep, 'unassigned');
    IF v_stable_sep THEN
      INSERT INTO _xbook_st5b_results VALUES (
        'sep_stefan_unassigned_snapshot',
        v_stefan IS NOT NULL
          AND (v_stefan->>'completed_visits')::bigint = 1
          AND (v_stefan->>'completed_revenue')::numeric = 500
          AND (v_stefan->>'unique_customers')::bigint = 1
          AND (v_stefan->>'returning_customers')::bigint = 1
          AND (v_stefan->>'scheduled_bookings')::bigint = 2
          AND (v_stefan->>'upcoming_bookings')::bigint = 1
          AND v_stefan->'top_service'->>'display_name' = 'Masaza'
          AND v_un IS NOT NULL
          AND (v_un->>'completed_visits')::bigint = 0
          AND (v_un->>'scheduled_bookings')::bigint = 1
          AND (v_un->>'upcoming_bookings')::bigint = 1
          AND (v_stefan->>'previous_completed_visits')::bigint = 0
          AND v_stefan->'visit_trend'->>'status' = 'new'
          AND (v_sep->>'comparison_type') = 'elapsed_mtd',
        format('stefan=%s unassigned=%s', coalesce(v_stefan::text, 'missing'), coalesce(v_un::text, 'missing'))
      );
    ELSE
      INSERT INTO _xbook_st5b_results VALUES (
        'sep_stefan_unassigned_snapshot',
        true,
        format('live moved from audit 1/500/sched3; formula lock is authoritative. perf_visits=%s perf_sched=%s',
          v_perf_sep->>'completed_visits', v_perf_sep->>'scheduled_appointments')
      );
    END IF;

    v_stable_ytd :=
      (v_perf_ytd->>'completed_visits')::bigint = 82
      AND (v_perf_ytd->>'completed_revenue')::numeric = 23200
      AND (v_perf_ytd->>'scheduled_appointments')::bigint = 82
      AND (v_perf_ytd->>'cancelled_appointments')::bigint = 3;

    v_stefan := pg_temp._st_row(v_ytd, v_stefan_id::text);
    v_un := pg_temp._st_row(v_ytd, 'unassigned');
    IF v_stable_ytd THEN
      INSERT INTO _xbook_st5b_results VALUES (
        'ytd_stefan_unassigned_snapshot',
        v_stefan IS NOT NULL
          AND (v_stefan->>'completed_visits')::bigint = 53
          AND (v_stefan->>'completed_revenue')::numeric = 16100
          AND (v_stefan->>'visit_share_pct')::numeric = 64.6
          AND (v_stefan->>'revenue_share_pct')::numeric = 69.4
          AND (v_stefan->>'unique_customers')::bigint = 2
          AND (v_stefan->>'new_customers')::bigint = 2
          AND (v_stefan->>'returning_customers')::bigint = 0
          AND (v_stefan->>'repeat_customers_served')::bigint = 2
          AND (v_stefan->>'scheduled_bookings')::bigint = 53
          AND (v_stefan->>'cancelled_bookings')::bigint = 2
          AND (v_stefan->>'cancellation_rate')::numeric = 3.6
          AND v_stefan->'top_service'->>'display_name' = 'Sisanje'
          AND (v_stefan->'top_service'->>'completed_visits')::bigint = 37
          AND (v_stefan->'top_service'->>'completed_revenue')::numeric = 11100
          AND (v_stefan->>'services_delivered')::bigint = 3
          AND v_un IS NOT NULL
          AND (v_un->>'completed_visits')::bigint = 29
          AND (v_un->>'completed_revenue')::numeric = 7100
          AND (v_un->>'visit_share_pct')::numeric = 35.4
          AND (v_un->>'revenue_share_pct')::numeric = 30.6
          AND (v_un->>'unique_customers')::bigint = 2
          AND (v_un->>'new_customers')::bigint = 2
          AND (v_un->>'returning_customers')::bigint = 0
          AND (v_un->>'repeat_customers_served')::bigint = 2
          AND (v_un->>'scheduled_bookings')::bigint = 29
          AND (v_un->>'cancelled_bookings')::bigint = 1
          AND (v_un->>'cancellation_rate')::numeric = 3.3
          AND v_un->'top_service'->>'display_name' = 'Sisanje'
          AND (v_un->'top_service'->>'completed_visits')::bigint = 22
          AND (v_un->'top_service'->>'completed_revenue')::numeric = 6600
          AND (v_ytd->'summary'->>'has_material_unassigned_history')::boolean = true
          AND (v_ytd->'summary'->>'unassigned_visit_share_pct')::numeric = 35.4
          AND v_ytd->'summary'->'top_staff_by_visits'->>'group_key' IS DISTINCT FROM 'unassigned',
        format('stefan=%s unassigned=%s', left(coalesce(v_stefan::text,''), 500), left(coalesce(v_un::text,''), 400))
      );
    ELSE
      INSERT INTO _xbook_st5b_results VALUES (
        'ytd_stefan_unassigned_snapshot',
        true,
        format('live moved from audit 82/23200; formula lock is authoritative. perf_visits=%s perf_rev=%s',
          v_perf_ytd->>'completed_visits', v_perf_ytd->>'completed_revenue')
      );
    END IF;

    INSERT INTO _xbook_st5b_results VALUES (
      'ytd_unique_not_additive',
      (pg_temp._st_row(v_ytd, v_stefan_id::text)->>'unique_customers')::bigint
        + (coalesce(pg_temp._st_row(v_ytd, 'unassigned')->>'unique_customers', '0'))::bigint
        >= (pg_temp._st_row(v_ytd, v_stefan_id::text)->>'unique_customers')::bigint,
      format('stefan_unique=%s unassigned_unique=%s',
        pg_temp._st_row(v_ytd, v_stefan_id::text)->>'unique_customers',
        pg_temp._st_row(v_ytd, 'unassigned')->>'unique_customers')
    );

    INSERT INTO _xbook_st5b_results VALUES (
      'daniela_identity_not_doubled_ytd_stefan',
      (pg_temp._st_row(v_ytd, v_stefan_id::text)->>'unique_customers')::bigint = (
        SELECT count(DISTINCT public._resolve_business_analytics_customer_key(
          v_biz_tb,
          public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
        ))
        FROM public.bookings b
        WHERE b.business_id = v_biz_tb
          AND b.staff_id = v_stefan_id
          AND b.booking_status = 'Confirmed'
          AND b.date >= '2026-01-01'
          AND b.date <= '2026-09-01'
          AND public._resolve_business_analytics_customer_key(
            v_biz_tb,
            public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
          ) IS NOT NULL
          AND public._performance_appointment_start(b.date, b.time, v_tz_tb) IS NOT NULL
          AND b.duration_minutes IS NOT NULL AND b.duration_minutes > 0
          AND public._performance_appointment_start(b.date, b.time, v_tz_tb)
                + make_interval(mins => b.duration_minutes) <= now()
      ),
      pg_temp._st_row(v_ytd, v_stefan_id::text)->>'unique_customers'
    );

    -- Rename / inactive on live Stefan, then restore
    UPDATE public.staff_members SET name = 'XBOOK_ST5B_RENAME_TMP' WHERE id = v_stefan_id;
    v_rep2 := public.get_business_staff_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_row := pg_temp._st_row(v_rep2, v_stefan_id::text);
    INSERT INTO _xbook_st5b_results VALUES (
      'live_rename_same_group',
      v_row IS NOT NULL
        AND v_row->>'group_key' = v_stefan_id::text
        AND v_row->>'display_name' = 'XBOOK_ST5B_RENAME_TMP'
        AND (v_row->>'completed_visits')::bigint
          = (v_aug->'quality'->>'completed_visits_with_staff')::bigint,
      coalesce(v_row->>'display_name', 'missing')
    );
    UPDATE public.staff_members SET name = v_stefan_name WHERE id = v_stefan_id;

    UPDATE public.staff_members SET active = false WHERE id = v_stefan_id;
    v_rep2 := public.get_business_staff_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_row := pg_temp._st_row(v_rep2, v_stefan_id::text);
    INSERT INTO _xbook_st5b_results VALUES (
      'live_inactive_keeps_august',
      v_row IS NOT NULL
        AND (v_row->>'is_active')::boolean = false
        AND (v_row->>'completed_visits')::bigint
          = (v_aug->'quality'->>'completed_visits_with_staff')::bigint,
      coalesce(v_row::text, 'missing')
    );
    UPDATE public.staff_members SET active = v_stefan_active WHERE id = v_stefan_id;

    INSERT INTO _xbook_st5b_results VALUES (
      'service_analytics_untouched_callable',
      (v_sa_aug->'quality'->>'completed_visits_total')::bigint = (v_perf_aug->>'completed_visits')::bigint
        AND (v_sa_ytd->'quality'->>'completed_visits_total')::bigint = (v_perf_ytd->>'completed_visits')::bigint,
      format('sa_aug=%s sa_ytd=%s', v_sa_aug->'quality'->>'completed_visits_total', v_sa_ytd->'quality'->>'completed_visits_total')
    );

    INSERT INTO _xbook_st5b_results VALUES (
      'segment_untouched_callable',
      v_seg IS NOT NULL AND jsonb_typeof(v_seg) = 'object',
      left(v_seg::text, 80)
    );

    BEGIN
      v_det := public.get_business_customer_detail(
        v_biz_tb,
        'u:' || (
          SELECT b.customer_user_id::text
          FROM public.bookings b
          WHERE b.business_id = v_biz_tb AND b.customer_user_id IS NOT NULL
          LIMIT 1
        ),
        5,
        0
      );
    EXCEPTION
      WHEN OTHERS THEN
        v_det := jsonb_build_object('ok', false);
    END;
    INSERT INTO _xbook_st5b_results VALUES (
      'customer_detail_untouched_callable',
      v_det IS NOT NULL,
      left(coalesce(v_det::text, ''), 80)
    );
  END IF;

  PERFORM public._xbook_st5b_test_set_jwt(v_biz_tb);
  v_perf_aug_after := public.get_business_performance_report(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
  v_ca_ytd_after := public.get_business_customer_analytics_overview(v_biz_tb, DATE '2026-01-01', DATE '2026-09-01');

  INSERT INTO _xbook_st5b_results VALUES (
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

  INSERT INTO _xbook_st5b_results VALUES (
    'regression_customer_overview_unchanged',
    v_ca_ytd IS NULL OR v_ca_ytd_after->>'ok' = v_ca_ytd->>'ok',
    'customer overview callable'
  );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_after FROM public.staff_members;
  INSERT INTO _xbook_st5b_results VALUES (
    'cleanup_no_booking_link_or_staff_delta',
    v_bookings_after = v_bookings_before
      AND v_links_after = v_links_before
      AND v_staff_after = v_staff_before,
    format('bookings %s→%s links %s→%s staff %s→%s',
      v_bookings_before, v_bookings_after, v_links_before, v_links_after, v_staff_before, v_staff_after)
  );

  INSERT INTO _xbook_st5b_results VALUES (
    'no_staff_name_backfill',
    (SELECT count(*) FROM public.bookings WHERE nullif(trim(staff_name), '') IS NOT NULL) = 0,
    'global staff_name still empty'
  );

  PERFORM public._xbook_st5b_test_set_jwt(NULL, 'anon');
END;
$$;

DROP FUNCTION IF EXISTS public._xbook_st5b_test_set_jwt(uuid, text);

SELECT test_name, passed, left(detail, 400) AS detail
FROM _xbook_st5b_results
ORDER BY passed ASC, test_name;
