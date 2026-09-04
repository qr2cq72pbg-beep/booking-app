-- =============================================================================
-- XBOOK Phase 7B Cross Analytics contract tests
-- Throwaway fixtures deleted. Live Test Barber formula parity (no stale counts).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_ca7b_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_ca7b_results;

CREATE OR REPLACE FUNCTION public._xbook_ca7b_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._xa_cust(p jsonb, p_key text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT c
  FROM jsonb_array_elements(coalesce(p->'customers', '[]'::jsonb)) c
  WHERE c->>'analytics_customer_key' = p_key
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._xa_has(p jsonb, p_key text)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(coalesce(p->'customers', '[]'::jsonb)) c
    WHERE c->>'analytics_customer_key' = p_key
  );
$$;

CREATE OR REPLACE FUNCTION pg_temp._ca7b_coalesce_pass()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.passed := coalesce(NEW.passed, false);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ca7b_coalesce_pass ON _xbook_ca7b_results;
CREATE TRIGGER trg_ca7b_coalesce_pass
BEFORE INSERT ON _xbook_ca7b_results
FOR EACH ROW
EXECUTE FUNCTION pg_temp._ca7b_coalesce_pass();

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
    'internal_notes', 'note', 'business_customer_id'
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

CREATE OR REPLACE FUNCTION pg_temp._xa_find(
  p_business_id uuid,
  p_from date,
  p_to date,
  p_filters jsonb,
  p_key text
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_off integer := 0;
  v_payload jsonb;
  v_row jsonb;
BEGIN
  LOOP
    v_payload := public.get_business_cross_analytics(
      p_business_id, p_from, p_to, p_filters, 'last_visit_desc', 100, v_off
    );
    v_row := pg_temp._xa_cust(v_payload, p_key);
    IF v_row IS NOT NULL THEN
      RETURN v_row;
    END IF;
    IF coalesce((v_payload->'pagination'->>'has_more')::boolean, false) IS NOT TRUE THEN
      RETURN NULL;
    END IF;
    v_off := v_off + 100;
    IF v_off > 20000 THEN
      RETURN NULL;
    END IF;
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp._xa_present(
  p_business_id uuid,
  p_from date,
  p_to date,
  p_filters jsonb,
  p_key text
)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT pg_temp._xa_find(p_business_id, p_from, p_to, p_filters, p_key) IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION pg_temp._xa_catch(
  p_business_id uuid,
  p_from date,
  p_to date,
  p_filters jsonb,
  p_sort text,
  p_limit integer,
  p_offset integer
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_state text;
BEGIN
  BEGIN
    PERFORM public.get_business_cross_analytics(
      p_business_id, p_from, p_to, p_filters, p_sort, p_limit, p_offset
    );
    RETURN NULL;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
      RETURN v_state;
  END;
END;
$$;

DO $$
DECLARE
  v_biz_a uuid;
  v_biz_b uuid;
  v_biz_tb uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  v_tz text;
  v_tz_tb text;
  v_from date;
  v_to date;
  v_today date;
  v_yesterday date;
  v_tomorrow date;
  v_before date;
  v_local_now timestamp;
  v_svc_a uuid;
  v_svc_b uuid;
  v_svc_free uuid;
  v_svc_unk uuid;
  v_svc_del uuid;
  v_svc_b_other uuid;
  v_staff_a uuid;
  v_staff_b uuid;
  v_staff_b_other uuid;
  v_city_strumica uuid;
  v_city_skopje uuid;
  v_instance uuid;
  v_user_female uuid;
  v_user_male uuid;
  v_user_age uuid;
  v_user_link uuid;
  v_user_cust uuid;
  v_num integer;
  v_key_approved text;
  v_key_pending text;
  v_key_rejected text;
  v_key_blocked text;
  v_key_new text;
  v_key_ret text;
  v_key_guest text;
  v_key_zero text;
  v_key_unk text;
  v_key_est text;
  v_key_inprog text;
  v_key_fut text;
  v_key_pend text;
  v_key_can text;
  v_key_candur text;
  v_key_nodur text;
  v_key_futcan text;
  v_key_svc_a text;
  v_key_svc_b text;
  v_key_svc_both text;
  v_key_ua text;
  v_key_link text;
  v_key_link_guest text;
  v_key_fuzzy_auth text;
  v_key_fuzzy_guest text;
  v_key_b_phone text;
  v_key_sort_a text;
  v_key_sort_b text;
  v_key_sort_c text;
  v_key_i31 text;
  v_key_i29 text;
  v_key_i30 text;
  v_key_page1 text;
  v_key_page2 text;
  v_key_page3 text;
  v_rep jsonb;
  v_row jsonb;
  v_det jsonb;
  v_ov jsonb;
  v_perf jsonb;
  v_seg jsonb;
  v_ok boolean;
  v_msg text;
  v_sqlstate text;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_links_before bigint;
  v_links_after bigint;
  v_staff_before bigint;
  v_staff_after bigint;
  v_svc_before bigint;
  v_svc_after bigint;
  v_n bigint;
  v_sum_visits numeric;
  v_sum_rev numeric;
  v_exact30 timestamp;
  v_inprog_ts timestamp;
  v_filters jsonb;
  v_age_to date := DATE '2020-06-15';
  v_age_from date := DATE '2020-06-01';
  v_daniela_uid uuid;
  v_daniela_guest text;
  v_daniela_auth text;
  v_keys bigint;
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
    RAISE EXCEPTION 'Need two businesses for Cross Analytics tests';
  END IF;

  SELECT nullif(trim(bs.timezone), '')
  INTO v_tz_tb
  FROM public.business_settings bs
  WHERE bs.business_id = v_biz_tb;

  SELECT id INTO v_city_strumica FROM public.cities WHERE country_code = 'MK' AND normalized_search = 'strumica' LIMIT 1;
  SELECT id INTO v_city_skopje FROM public.cities WHERE country_code = 'MK' AND normalized_search = 'skopje' LIMIT 1;
  IF v_city_strumica IS NULL OR v_city_skopje IS NULL THEN
    RAISE EXCEPTION 'Need MK Strumica and Skopje city rows';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_today := v_local_now::date;
  v_yesterday := v_today - 1;
  v_tomorrow := v_today + 1;
  v_before := v_today - 20;
  v_from := v_yesterday;
  v_to := v_tomorrow;
  v_exact30 := v_local_now - interval '30 days' + interval '2 minutes';
  v_inprog_ts := v_local_now - interval '10 minutes';

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_before FROM public.staff_members;
  SELECT count(*) INTO v_svc_before FROM public.services;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCA7B-%' OR customer_name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700077%'
     OR reason = 'xbook_ca7b_test';
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (
      bc.display_name LIKE 'XBOOK_CA7B%'
      OR bc.phone LIKE '+389700077%'
      OR bc.client_key LIKE 'p:389700077%'
    );
  DELETE FROM public.customer_private_profiles pp
  USING auth.users u
  WHERE pp.user_id = u.id AND u.email LIKE 'xbook-ca7b-%@invalid.example';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_CA7B%'
     OR phone LIKE '+389700077%'
     OR client_key LIKE 'p:389700077%'
     OR client_key LIKE 'e:xbook-ca7b-%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ca7b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-ca7b-%@invalid.example';

  INSERT INTO _xbook_ca7b_results VALUES (
    'A1_grants_authenticated_only',
    has_function_privilege(
      'authenticated',
      'public.get_business_cross_analytics(uuid,date,date,jsonb,text,integer,integer)',
      'EXECUTE'
    )
      AND NOT has_function_privilege(
        'anon',
        'public.get_business_cross_analytics(uuid,date,date,jsonb,text,integer,integer)',
        'EXECUTE'
      )
      AND NOT has_function_privilege(
        'service_role',
        'public.get_business_cross_analytics(uuid,date,date,jsonb,text,integer,integer)',
        'EXECUTE'
      ),
    'authenticated execute; anon/service_role revoked'
  );

  INSERT INTO public.services (business_id, name, duration, price) VALUES
    (v_biz_a, 'XBOOK_CA7B_A', 30, 700),
    (v_biz_a, 'XBOOK_CA7B_B', 45, 200),
    (v_biz_a, 'XBOOK_CA7B_FREE', 30, 0),
    (v_biz_a, 'XBOOK_CA7B_UNK', 30, NULL),
    (v_biz_a, 'XBOOK_CA7B_DEL', 30, 50),
    (v_biz_b, 'XBOOK_CA7B_OTHER', 30, 50);

  SELECT id INTO v_svc_a FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_CA7B_A';
  SELECT id INTO v_svc_b FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_CA7B_B';
  SELECT id INTO v_svc_free FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_CA7B_FREE';
  SELECT id INTO v_svc_unk FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_CA7B_UNK';
  SELECT id INTO v_svc_del FROM public.services WHERE business_id = v_biz_a AND name = 'XBOOK_CA7B_DEL';
  SELECT id INTO v_svc_b_other FROM public.services WHERE business_id = v_biz_b AND name = 'XBOOK_CA7B_OTHER';

  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_a, 'XBOOK_CA7B_STEFAN', 'Barber', true)
  RETURNING id INTO v_staff_a;
  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_a, 'XBOOK_CA7B_ANA', 'Barber', true)
  RETURNING id INTO v_staff_b;
  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_b, 'XBOOK_CA7B_FOREIGN', 'Barber', true)
  RETURNING id INTO v_staff_b_other;

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
    'xbook-ca7b-female-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ca7b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_female;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-ca7b-male-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ca7b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_male;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-ca7b-age-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ca7b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_age;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-ca7b-link-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ca7b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_link;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-ca7b-cust-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ca7b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_cust;

  INSERT INTO public.customer_private_profiles (user_id, date_of_birth, gender, country_code, city_id)
  VALUES
    (v_user_female, DATE '1995-01-01', 'female', 'MK', v_city_strumica),
    (v_user_male, DATE '1988-01-01', 'male', 'MK', v_city_skopje),
    (v_user_age, DATE '1990-06-16', 'female', 'MK', v_city_strumica);

  SELECT coalesce(max(customer_number), 0) INTO v_num
  FROM public.business_customers WHERE business_id = v_biz_a;

  v_key_approved := 'u:' || v_user_female::text;
  v_key_pending := 'p:389700077002';
  v_key_rejected := 'p:389700077003';
  v_key_blocked := 'p:389700077004';
  v_key_link := 'u:' || v_user_link::text;
  v_key_link_guest := 'p:389700077010';
  v_key_fuzzy_auth := 'u:' || v_user_male::text;

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status, is_vip
  ) VALUES
  (v_biz_a, 'u:' || v_user_female::text, v_num + 1, 'XBOOK_CA7B_APPROVED', '+389700077001',
   v_user_female, 'approved', true),
  (v_biz_a, v_key_pending, v_num + 2, 'XBOOK_CA7B_PENDING', '+389700077002',
   NULL, 'pending', false),
  (v_biz_a, v_key_rejected, v_num + 3, 'XBOOK_CA7B_REJECTED', '+389700077003',
   NULL, 'rejected', false),
  (v_biz_a, v_key_blocked, v_num + 4, 'XBOOK_CA7B_BLOCKED', '+389700077004',
   NULL, 'blocked', false),
  (v_biz_a, v_key_link_guest, v_num + 5, 'XBOOK_CA7B_LINK', '+389700077010',
   v_user_link, 'approved', true),
  (v_biz_a, 'u:' || v_user_male::text, v_num + 6, 'XBOOK_CA7B_MALE', '+389700077030',
   v_user_male, 'approved', false),
  (v_biz_a, 'u:' || v_user_age::text, v_num + 7, 'XBOOK_CA7B_AGE', '+389700077040',
   v_user_age, 'approved', false);

  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (
    v_biz_a, v_user_link, v_key_link_guest, 'xbook_ca7b_test', v_biz_a
  );

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, approval_status, is_vip
  )
  SELECT v_biz_b, 'p:389700077103', coalesce(max(customer_number), 0) + 1,
         'XBOOK_CA7B_BIZB', '+389700077103', 'approved', true
  FROM public.business_customers WHERE business_id = v_biz_b;

  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_a);

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_email, customer_user_id,
    booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- New / single / used A
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA7B_NEW', '+389700077101', NULL, NULL, 'Confirmed', 100, 'XCA7B-NEW', gen_random_uuid()::text),
  -- Returning / repeat
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_before, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA7B_RET', '+389700077102', NULL, NULL, 'Confirmed', 200, 'XCA7B-RET0', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_CA7B_RET', '+389700077102', NULL, NULL, 'Confirmed', 200, 'XCA7B-RET1', gen_random_uuid()::text),
  -- Booking-history-only guest
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_CA7B_GUEST', '+389700077103', NULL, NULL, 'Confirmed', 50, 'XCA7B-GST', gen_random_uuid()::text),
  -- Known zero snapshot
  (v_biz_a, v_svc_free, 'XBOOK_CA7B_FREE', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_CA7B_ZERO', '+389700077104', NULL, NULL, 'Confirmed', 0, 'XCA7B-ZERO', gen_random_uuid()::text),
  -- Unknown price
  (v_biz_a, v_svc_unk, 'XBOOK_CA7B_UNK', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '12:15', 30,
   'XBOOK_CA7B_UNK', '+389700077105', NULL, NULL, 'Confirmed', NULL, 'XCA7B-UNK', gen_random_uuid()::text),
  -- Estimated catalog
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '12:30', 30,
   'XBOOK_CA7B_EST', '+389700077106', NULL, NULL, 'Confirmed', NULL, 'XCA7B-EST', gen_random_uuid()::text),
  -- Future confirmed (not completed)
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_CA7B_FUT', '+389700077107', NULL, NULL, 'Confirmed', 80, 'XCA7B-FUT', gen_random_uuid()::text),
  -- Elapsed pending
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '07:00', 30,
   'XBOOK_CA7B_PEND', '+389700077108', NULL, NULL, 'Pending', 80, 'XCA7B-PEND', gen_random_uuid()::text),
  -- Cancelled elapsed
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '08:00', 30,
   'XBOOK_CA7B_CAN', '+389700077109', NULL, NULL, 'Cancelled', 80, 'XCA7B-CAN', gen_random_uuid()::text),
  -- Unknown duration confirmed elapsed
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 0,
   'XBOOK_CA7B_NODUR', '+389700077110', NULL, NULL, 'Confirmed', 80, 'XCA7B-NODUR', gen_random_uuid()::text),
  -- Cancelled future
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_tomorrow, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_CA7B_FUTCAN', '+389700077111', NULL, NULL, 'Cancelled', 80, 'XCA7B-FUTCAN', gen_random_uuid()::text),
  -- In progress
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_inprog_ts::date, 'YYYY-MM-DD'), to_char(v_inprog_ts, 'HH24:MI:SS'), 120,
   'XBOOK_CA7B_INPROG', '+389700077112', NULL, NULL, 'Confirmed', 80, 'XCA7B-INPROG', gen_random_uuid()::text),
  -- Used A only / used B only / used both
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_CA7B_SVCA', '+389700077120', NULL, NULL, 'Confirmed', 10, 'XCA7B-SA', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '14:15', 45,
   'XBOOK_CA7B_SVCB', '+389700077121', NULL, NULL, 'Confirmed', 20, 'XCA7B-SB', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '14:30', 30,
   'XBOOK_CA7B_BOTH', '+389700077122', NULL, NULL, 'Confirmed', 10, 'XCA7B-BO1', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 45,
   'XBOOK_CA7B_BOTH', '+389700077122', NULL, NULL, 'Confirmed', 20, 'XCA7B-BO2', gen_random_uuid()::text),
  -- Unassigned
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', NULL, to_char(v_yesterday, 'YYYY-MM-DD'), '15:30', 30,
   'XBOOK_CA7B_UA', '+389700077123', NULL, NULL, 'Confirmed', 15, 'XCA7B-UA', gen_random_uuid()::text),
  -- Linked identity: auth booking + guest alias booking
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '16:00', 30,
   'XBOOK_CA7B_LINK', '+389700077010', NULL, v_user_link, 'Confirmed', 30, 'XCA7B-L1', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '16:30', 30,
   'XBOOK_CA7B_LINK', '+389700077010', NULL, NULL, 'Confirmed', 30, 'XCA7B-L2', gen_random_uuid()::text),
  -- Fuzzy: auth male with phone, separate guest same phone
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '17:00', 30,
   'XBOOK_CA7B_MALE', '+389700077030', NULL, v_user_male, 'Confirmed', 40, 'XCA7B-MA', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '17:15', 30,
   'XBOOK_CA7B_SAMEPHONE', '+389700077030', NULL, NULL, 'Confirmed', 40, 'XCA7B-SP', gen_random_uuid()::text),
  -- Inactivity 31 / 29 / exact 30
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char((v_local_now - interval '31 days')::date, 'YYYY-MM-DD'),
   to_char(v_local_now - interval '31 days', 'HH24:MI:SS'), 30,
   'XBOOK_CA7B_I31', '+389700077131', NULL, NULL, 'Confirmed', 11, 'XCA7B-I31', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char((v_local_now - interval '40 days')::date, 'YYYY-MM-DD'),
   to_char(v_local_now - interval '40 days', 'HH24:MI:SS'), 30,
   'XBOOK_CA7B_I31', '+389700077131', NULL, NULL, 'Confirmed', 11, 'XCA7B-I31B', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char((v_local_now - interval '29 days')::date, 'YYYY-MM-DD'),
   to_char(v_local_now - interval '29 days', 'HH24:MI:SS'), 30,
   'XBOOK_CA7B_I29', '+389700077129', NULL, NULL, 'Confirmed', 11, 'XCA7B-I29', gen_random_uuid()::text),
  (v_biz_a, v_svc_a, 'XBOOK_CA7B_A', v_staff_a, to_char(v_exact30::date, 'YYYY-MM-DD'),
   to_char(v_exact30, 'HH24:MI:SS'), 30,
   'XBOOK_CA7B_I30', '+389700077130', NULL, NULL, 'Confirmed', 11, 'XCA7B-I30', gen_random_uuid()::text),
  -- Sort names / pagination
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '18:00', 45,
   'XBOOK_CA7B_AAA', '+389700077201', NULL, NULL, 'Confirmed', 300, 'XCA7B-AAA', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_before, 'YYYY-MM-DD'), '18:00', 45,
   'XBOOK_CA7B_BBB', '+389700077202', NULL, NULL, 'Confirmed', 100, 'XCA7B-BBB', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '18:05', 45,
   'XBOOK_CA7B_CCC', '+389700077203', NULL, NULL, 'Confirmed', 50, 'XCA7B-CCC0', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_tomorrow, 'YYYY-MM-DD'), '09:00', 45,
   'XBOOK_CA7B_CCC', '+389700077203', NULL, NULL, 'Confirmed', 50, 'XCA7B-CCC', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '18:15', 45,
   'XBOOK_CA7B_P1', '+389700077211', NULL, NULL, 'Confirmed', 1, 'XCA7B-P1', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '18:30', 45,
   'XBOOK_CA7B_P2', '+389700077212', NULL, NULL, 'Confirmed', 2, 'XCA7B-P2', gen_random_uuid()::text),
  (v_biz_a, v_svc_b, 'XBOOK_CA7B_B', v_staff_b, to_char(v_yesterday, 'YYYY-MM-DD'), '18:45', 45,
   'XBOOK_CA7B_P3', '+389700077213', NULL, NULL, 'Confirmed', 3, 'XCA7B-P3', gen_random_uuid()::text),
  -- Deleted service history (UUID kept on booking, then catalog row deleted)
  (v_biz_a, v_svc_del, 'XBOOK_CA7B_DEL', v_staff_a, to_char(v_yesterday, 'YYYY-MM-DD'), '19:00', 30,
   'XBOOK_CA7B_DELCUST', '+389700077220', NULL, NULL, 'Confirmed', 50, 'XCA7B-DEL', gen_random_uuid()::text);

  -- Owner JWT is business-scoped; insert the other-tenant row as that owner.
  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_b);
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_email, customer_user_id,
    booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  (v_biz_b, v_svc_b_other, 'XBOOK_CA7B_OTHER', v_staff_b_other, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_CA7B_BIZB', '+389700077103', NULL, NULL, 'Confirmed', 99, 'XCA7B-BIZB', gen_random_uuid()::text);
  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_a);

  -- Female approved zero-booking also needs no extra bookings.

  DELETE FROM public.services WHERE id = v_svc_del;

  v_key_new := public._analytics_customer_key(NULL, '+389700077101', NULL, 'XBOOK_CA7B_NEW');
  v_key_ret := public._analytics_customer_key(NULL, '+389700077102', NULL, 'XBOOK_CA7B_RET');
  v_key_guest := public._analytics_customer_key(NULL, '+389700077103', NULL, 'XBOOK_CA7B_GUEST');
  v_key_zero := public._analytics_customer_key(NULL, '+389700077104', NULL, 'XBOOK_CA7B_ZERO');
  v_key_unk := public._analytics_customer_key(NULL, '+389700077105', NULL, 'XBOOK_CA7B_UNK');
  v_key_est := public._analytics_customer_key(NULL, '+389700077106', NULL, 'XBOOK_CA7B_EST');
  v_key_fut := public._analytics_customer_key(NULL, '+389700077107', NULL, 'XBOOK_CA7B_FUT');
  v_key_pend := public._analytics_customer_key(NULL, '+389700077108', NULL, 'XBOOK_CA7B_PEND');
  v_key_can := public._analytics_customer_key(NULL, '+389700077109', NULL, 'XBOOK_CA7B_CAN');
  v_key_nodur := public._analytics_customer_key(NULL, '+389700077110', NULL, 'XBOOK_CA7B_NODUR');
  v_key_futcan := public._analytics_customer_key(NULL, '+389700077111', NULL, 'XBOOK_CA7B_FUTCAN');
  v_key_inprog := public._analytics_customer_key(NULL, '+389700077112', NULL, 'XBOOK_CA7B_INPROG');
  v_key_svc_a := public._analytics_customer_key(NULL, '+389700077120', NULL, 'XBOOK_CA7B_SVCA');
  v_key_svc_b := public._analytics_customer_key(NULL, '+389700077121', NULL, 'XBOOK_CA7B_SVCB');
  v_key_svc_both := public._analytics_customer_key(NULL, '+389700077122', NULL, 'XBOOK_CA7B_BOTH');
  v_key_ua := public._analytics_customer_key(NULL, '+389700077123', NULL, 'XBOOK_CA7B_UA');
  v_key_fuzzy_guest := public._analytics_customer_key(NULL, '+389700077030', NULL, 'XBOOK_CA7B_SAMEPHONE');
  v_key_b_phone := public._analytics_customer_key(NULL, '+389700077103', NULL, 'XBOOK_CA7B_BIZB');
  v_key_sort_a := public._analytics_customer_key(NULL, '+389700077201', NULL, 'XBOOK_CA7B_AAA');
  v_key_sort_b := public._analytics_customer_key(NULL, '+389700077202', NULL, 'XBOOK_CA7B_BBB');
  v_key_sort_c := public._analytics_customer_key(NULL, '+389700077203', NULL, 'XBOOK_CA7B_CCC');
  v_key_i31 := public._analytics_customer_key(NULL, '+389700077131', NULL, 'XBOOK_CA7B_I31');
  v_key_i29 := public._analytics_customer_key(NULL, '+389700077129', NULL, 'XBOOK_CA7B_I29');
  v_key_i30 := public._analytics_customer_key(NULL, '+389700077130', NULL, 'XBOOK_CA7B_I30');
  v_key_page1 := public._analytics_customer_key(NULL, '+389700077211', NULL, 'XBOOK_CA7B_P1');
  v_key_page2 := public._analytics_customer_key(NULL, '+389700077212', NULL, 'XBOOK_CA7B_P2');
  v_key_page3 := public._analytics_customer_key(NULL, '+389700077213', NULL, 'XBOOK_CA7B_P3');

  -- Security
  INSERT INTO _xbook_ca7b_results VALUES (
    'A2_owner_succeeds',
    (public.get_business_cross_analytics(v_biz_a, v_from, v_to, '{}'::jsonb)->>'ok')::boolean,
    'owner ok'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'A3_wrong_owner_42501',
    pg_temp._xa_catch(v_biz_b, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0) = '42501',
    coalesce(pg_temp._xa_catch(v_biz_b, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0), 'no-throw')
  );

  PERFORM public._xbook_ca7b_test_set_jwt(v_user_cust);
  INSERT INTO _xbook_ca7b_results VALUES (
    'A4_customer_42501',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0) = '42501',
    'customer jwt'
  );
  PERFORM public._xbook_ca7b_test_set_jwt(NULL, 'anon');
  INSERT INTO _xbook_ca7b_results VALUES (
    'A5_anon_42501',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0) = '42501',
    'anon jwt'
  );
  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_a);

  -- Validation
  INSERT INTO _xbook_ca7b_results VALUES (
    'B6_invalid_period',
    pg_temp._xa_catch(v_biz_a, v_to, v_from, '{}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'from>to'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B7_unknown_filter_key',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{"not_a_filter":true}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'unknown key'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B8_invalid_enum',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{"customer_type":"active"}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'bad enum'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B9_invalid_uuid',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{"city_ids":["not-a-uuid"]}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'bad uuid'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B10_foreign_service',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object('service_ids', jsonb_build_array(v_svc_b_other)),
      'last_visit_desc', 50, 0
    ) = '22023',
    'foreign service'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B11_foreign_staff',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object('staff_ids', jsonb_build_array(v_staff_b_other::text)),
      'last_visit_desc', 50, 0
    ) = '22023',
    'foreign staff'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B12_negative_threshold',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{"lifetime_visits_min":-1}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'negative'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B13_min_gt_max',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{"lifetime_visits_min":5,"lifetime_visits_max":1}'::jsonb, 'last_visit_desc', 50, 0) = '22023',
    'min>max'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B14_invalid_sort',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'not_a_sort', 50, 0) = '22023',
    'sort'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B15_limit_0',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 0, 0) = '22023',
    'limit 0'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B16_limit_over_100',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 101, 0) = '22023',
    'limit 101'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B17_negative_offset',
    pg_temp._xa_catch(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, -1) = '22023',
    'offset'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'B18_service_overlap',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object(
        'service_ids', jsonb_build_array(v_svc_a),
        'service_match', 'any',
        'service_ids_none', jsonb_build_array(v_svc_a)
      ),
      'last_visit_desc', 50, 0
    ) = '22023',
    'overlap'
  );

  -- Population
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('is_vip', true, 'lifetime_visits_max', 0),
    'name_asc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'C19_approved_zero_booking_included',
    pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      jsonb_build_object('is_vip', true, 'lifetime_visits_max', 0),
      v_key_approved
    )
      AND EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_approved
          AND k.has_approved_membership AND NOT k.has_booking_history
      ),
    'approved zero-booking CRM'
  );

  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'any'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'C20_booking_history_only_included',
    pg_temp._xa_has(v_rep, v_key_guest),
    'guest history'
  );

  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'C21_pending_crm_only_excluded',
    pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_pending) IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_pending
      ),
    'pending'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'C22_rejected_crm_only_excluded',
    pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_rejected) IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_rejected
      ),
    'rejected'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'C23_blocked_crm_only_excluded',
    pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_blocked) IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public._business_analytics_customer_keys(v_biz_a) k
        WHERE k.analytics_customer_key = v_key_blocked
      ),
    'blocked'
  );

  -- Identity
  v_filters := jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'any');
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'last_visit_desc', 100, 0);
  SELECT count(*) INTO v_keys
  FROM jsonb_array_elements(v_rep->'customers') c
  WHERE c->>'analytics_customer_key' IN (v_key_link, v_key_link_guest);
  INSERT INTO _xbook_ca7b_results VALUES (
    'D24_linked_guest_auth_counts_once',
    pg_temp._xa_has(v_rep, v_key_link)
      AND NOT pg_temp._xa_has(v_rep, v_key_link_guest)
      AND v_keys = 1
      AND (pg_temp._xa_cust(v_rep, v_key_link)->>'completed_visits_lifetime')::bigint = 2,
    format('keys=%s visits=%s', v_keys, pg_temp._xa_cust(v_rep, v_key_link)->>'completed_visits_lifetime')
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'D25_no_fuzzy_contact_merge',
    pg_temp._xa_has(v_rep, v_key_fuzzy_auth)
      AND pg_temp._xa_has(v_rep, v_key_fuzzy_guest)
      AND v_key_fuzzy_auth IS DISTINCT FROM v_key_fuzzy_guest,
    format('auth=%s guest=%s', v_key_fuzzy_auth, v_key_fuzzy_guest)
  );

  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_b);
  v_row := pg_temp._xa_find(v_biz_b, v_from, v_to, '{}'::jsonb, v_key_b_phone);
  INSERT INTO _xbook_ca7b_results VALUES (
    'D26_cross_business_isolated',
    pg_temp._xa_find(v_biz_b, v_from, v_to, '{}'::jsonb, v_key_approved) IS NULL
      AND pg_temp._xa_find(v_biz_b, v_from, v_to, '{}'::jsonb, v_key_link) IS NULL
      AND v_row->>'display_name' = 'XBOOK_CA7B_BIZB'
      AND (v_row->>'is_vip')::boolean = true
      AND (v_row->>'completed_revenue_lifetime')::numeric = 99,
    coalesce(v_row::text, 'missing biz B phone row')
  );
  PERFORM public._xbook_ca7b_test_set_jwt(v_biz_a);

  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, v_filters, v_key_guest);
  v_det := public.get_business_customer_detail(v_biz_a, v_row->>'analytics_customer_key', 25, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'D27_cross_key_opens_customer_detail',
    (v_det->>'ok')::boolean
      AND v_det->'customer'->>'analytics_customer_key' = v_key_guest,
    coalesce(v_det->>'code', v_det->'customer'->>'analytics_customer_key')
  );

  -- Completed visit semantics (zero-completed identities are not in service ANY)
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, v_filters, v_key_new);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E28_confirmed_elapsed_counts',
    (v_row->>'completed_visits_lifetime')::bigint = 1,
    v_row->>'completed_visits_lifetime'
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_fut);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E29_future_confirmed_not_completed',
    v_row IS NOT NULL
      AND coalesce((v_row->>'completed_visits_lifetime')::bigint, 0) = 0
      AND (v_row->>'has_upcoming_appointment')::boolean,
    coalesce(v_row::text, 'missing fut')
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_inprog);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E30_in_progress_not_completed',
    v_row IS NOT NULL
      AND coalesce((v_row->>'completed_visits_lifetime')::bigint, 0) = 0
      AND coalesce((v_row->>'has_upcoming_appointment')::boolean, true) = false,
    coalesce(v_row::text, 'missing inprog')
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_pend);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E31_pending_elapsed_not_completed',
    v_row IS NOT NULL
      AND coalesce((v_row->>'completed_visits_lifetime')::bigint, 0) = 0,
    coalesce(v_row::text, 'missing pend')
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_can);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E32_cancelled_not_visit',
    v_row IS NOT NULL
      AND coalesce((v_row->>'completed_visits_lifetime')::bigint, 0) = 0,
    coalesce(v_row::text, 'missing can')
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_nodur);
  INSERT INTO _xbook_ca7b_results VALUES (
    'E33_unknown_duration_not_completed',
    v_row IS NOT NULL
      AND coalesce((v_row->>'completed_visits_lifetime')::bigint, 0) = 0,
    coalesce(v_row::text, 'missing nodur')
  );

  -- Demographics
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"gender":["female"]}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F34_gender_female',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"gender":["female"]}'::jsonb, v_key_approved)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"gender":["female"]}'::jsonb, v_key_fuzzy_auth)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"gender":["female"]}'::jsonb, v_key_guest),
    'female'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('gender', jsonb_build_array('unknown'), 'service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F35_gender_unknown',
    pg_temp._xa_has(v_rep, v_key_guest) AND NOT pg_temp._xa_has(v_rep, v_key_approved),
    'unknown gender guests'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"gender":["female","unknown"]}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F36_gender_or',
    pg_temp._xa_find(v_biz_a, v_from, v_to, '{"gender":["female","unknown"]}'::jsonb, v_key_approved) IS NOT NULL
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, '{"gender":["female","unknown"]}'::jsonb, v_key_guest) IS NOT NULL,
    'OR gender'
  );

  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_age_from, v_age_to, '{"age_buckets":["25_34"]}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F37_age_bucket',
    pg_temp._xa_present(v_biz_a, v_age_from, v_age_to, '{"age_buckets":["25_34"]}'::jsonb, 'u:' || v_user_age::text)
      AND pg_temp._xa_find(v_biz_a, v_age_from, v_age_to, '{"age_buckets":["25_34"]}'::jsonb, 'u:' || v_user_age::text)->>'age_bucket' = '25_34',
    coalesce(
      pg_temp._xa_find(v_biz_a, v_age_from, v_age_to, '{"age_buckets":["25_34"]}'::jsonb, 'u:' || v_user_age::text)->>'age_bucket',
      'missing'
    )
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('age_buckets', jsonb_build_array('unknown'), 'service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F38_age_unknown',
    pg_temp._xa_has(v_rep, v_key_guest),
    'guest unknown age'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_age_from, v_age_to, '{"age_buckets":["35_44"]}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F39_age_as_of_p_to_date',
    NOT pg_temp._xa_has(v_rep, 'u:' || v_user_age::text),
    'must not be 35_44 as of 2020-06-15'
  );

  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F40_city_uuid',
    pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica::text)),
      v_key_approved
    )
      AND NOT pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica::text)),
        v_key_fuzzy_auth
      ),
    'strumica'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('city_unknown', true, 'service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F41_city_unknown',
    pg_temp._xa_has(v_rep, v_key_guest) AND NOT pg_temp._xa_has(v_rep, v_key_approved),
    'unknown city'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica), 'city_unknown', true),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'F42_city_ids_or_unknown',
    pg_temp._xa_find(v_biz_a, v_from, v_to, jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica), 'city_unknown', true), v_key_approved) IS NOT NULL
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, jsonb_build_object('city_ids', jsonb_build_array(v_city_strumica), 'city_unknown', true), v_key_guest) IS NOT NULL,
    'city OR unknown'
  );

  -- VIP
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'G43_vip_true',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, v_key_approved)
      AND pg_temp._xa_present(v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, v_key_link)
      AND (pg_temp._xa_find(v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, v_key_link)->>'is_vip')::boolean,
    'vip true'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('is_vip', false, 'service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'G44_vip_false',
    pg_temp._xa_has(v_rep, v_key_guest) AND NOT pg_temp._xa_has(v_rep, v_key_link),
    'vip false'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'G45_linked_keeps_canonical_vip',
    (pg_temp._xa_find(v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, v_key_link)->>'is_vip')::boolean
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, '{"is_vip":true}'::jsonb, v_key_link_guest) IS NULL,
    'canonical VIP after link'
  );

  -- Type / frequency
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"customer_type":"new"}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'H46_new',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"customer_type":"new"}'::jsonb, v_key_new)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"customer_type":"new"}'::jsonb, v_key_ret),
    'new'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"customer_type":"returning"}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'H47_returning',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"customer_type":"returning"}'::jsonb, v_key_ret)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"customer_type":"returning"}'::jsonb, v_key_new),
    'returning'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"visit_frequency":"repeat"}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'H48_repeat',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"visit_frequency":"repeat"}'::jsonb, v_key_ret)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"visit_frequency":"repeat"}'::jsonb, v_key_new),
    'repeat'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"visit_frequency":"single"}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'H49_single',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"visit_frequency":"single"}'::jsonb, v_key_new)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"visit_frequency":"single"}'::jsonb, v_key_ret),
    'single'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, jsonb_build_object('visit_frequency', 'single', 'is_vip', true, 'lifetime_visits_max', 0),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'H50_zero_visit_neither_repeat_nor_single',
    NOT pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      jsonb_build_object('visit_frequency', 'single', 'is_vip', true, 'lifetime_visits_max', 0),
      v_key_approved
    )
      AND NOT pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        '{"visit_frequency":"repeat","is_vip":true,"lifetime_visits_max":0}'::jsonb,
        v_key_approved
      ),
    'zero visit'
  );

  -- Inactivity / future
  INSERT INTO _xbook_ca7b_results VALUES (
    'I51_inactivity_30',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i31)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i29),
    format('31=%s 29=%s',
      pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i31),
      pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i29))
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'I52_boundary_gt_not_gte',
    NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i30),
    format('exact30 included=%s days=%s',
      pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_i30),
      pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_i30)->>'days_since_last_visit')
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'I53_zero_visit_not_inactive',
    NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30}'::jsonb, v_key_approved),
    'approved zero-visit'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'I54_has_future_true',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"has_future_booking":true}'::jsonb, v_key_fut)
      AND pg_temp._xa_present(v_biz_a, v_from, v_to, '{"has_future_booking":true}'::jsonb, v_key_sort_c),
    'future true'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'I55_has_future_false',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"has_future_booking":false}'::jsonb, v_key_new)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"has_future_booking":false}'::jsonb, v_key_fut),
    'future false'
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_futcan);
  INSERT INTO _xbook_ca7b_results VALUES (
    'I56_cancelled_future_not_counted',
    v_row IS NOT NULL
      AND coalesce((v_row->>'has_upcoming_appointment')::boolean, false) = false,
    coalesce(v_row::text, 'missing futcan')
  );
  v_row := pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, v_key_inprog);
  INSERT INTO _xbook_ca7b_results VALUES (
    'I57_in_progress_not_future',
    v_row IS NOT NULL
      AND coalesce((v_row->>'has_upcoming_appointment')::boolean, true) = false,
    'in progress'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'I58_inactive_and_no_future_composable',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30,"has_future_booking":false}'::jsonb, v_key_i31)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"inactive_days_min":30,"has_future_booking":false}'::jsonb, v_key_fut),
    'at-risk compose'
  );

  -- Numeric
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"lifetime_visits_min":2}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J59_lifetime_visits_min',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_visits_min":2}'::jsonb, v_key_ret)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_visits_min":2}'::jsonb, v_key_new),
    'visits min 2'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"lifetime_visits_max":1}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J60_lifetime_visits_max',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_visits_max":1}'::jsonb, v_key_new)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_visits_max":1}'::jsonb, v_key_ret),
    'visits max 1'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"period_visits_min":1}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J61_period_visits_min',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"period_visits_min":1}'::jsonb, v_key_new)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"period_visits_min":1}'::jsonb, v_key_i31),
    'period visits'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"lifetime_revenue_min":250}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J62_lifetime_revenue_min',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_min":250}'::jsonb, v_key_sort_a)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_min":250}'::jsonb, v_key_new),
    'rev min'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"period_revenue_min":250}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J63_period_revenue_min',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"period_revenue_min":250}'::jsonb, v_key_sort_a)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"period_revenue_min":250}'::jsonb, v_key_sort_b),
    'period rev'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J64_known_zero_distinct_from_unknown',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_zero)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_unk)
      AND (pg_temp._xa_find(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_zero)->>'completed_revenue_lifetime')::numeric = 0,
    format('zero=%s unk=%s',
      pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_zero),
      pg_temp._xa_present(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_unk))
  );
  v_row := pg_temp._xa_find(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_unk)),
    v_key_unk
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'J65_unknown_revenue_not_zero',
    v_row->>'completed_revenue_lifetime' IS NULL
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, '{"lifetime_revenue_min":0}'::jsonb, v_key_unk) IS NULL
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, '{"lifetime_revenue_max":0}'::jsonb, v_key_unk) IS NULL,
    coalesce(v_row::text, 'missing unk')
  );

  -- Service
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'any', 'service_scope', 'lifetime'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K66_service_any_lifetime',
    pg_temp._xa_has(v_rep, v_key_svc_a) AND pg_temp._xa_has(v_rep, v_key_svc_both) AND NOT pg_temp._xa_has(v_rep, v_key_svc_b),
    'any A lifetime'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'any', 'service_scope', 'period'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K67_service_any_period',
    pg_temp._xa_has(v_rep, v_key_new) AND NOT pg_temp._xa_has(v_rep, v_key_i31),
    'any A period (i31 is before period)'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids_none', jsonb_build_array(v_svc_b), 'service_scope', 'lifetime', 'service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K68_service_none_lifetime',
    pg_temp._xa_has(v_rep, v_key_svc_a) AND NOT pg_temp._xa_has(v_rep, v_key_svc_both) AND NOT pg_temp._xa_has(v_rep, v_key_svc_b),
    'A and not B'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object(
      'service_ids', jsonb_build_array(v_svc_a),
      'service_match', 'none',
      'service_scope', 'period'
    ),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K69_service_none_period_normalized',
    (v_rep->'applied_filters' ? 'service_ids_none')
      AND NOT (v_rep->'applied_filters' ? 'service_ids')
      AND v_rep->'applied_filters'->>'service_scope' = 'period'
      AND pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'none', 'service_scope', 'period'),
        v_key_svc_b
      )
      AND NOT pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'none', 'service_scope', 'period'),
        v_key_svc_a
      )
      AND pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'none', 'service_scope', 'period'),
        v_key_i31
      ),
    (v_rep->'applied_filters')::text
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K70_used_x_not_y',
    pg_temp._xa_has(
      public.get_business_cross_analytics(
        v_biz_a, v_from, v_to,
        jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_ids_none', jsonb_build_array(v_svc_b)),
        'last_visit_desc', 100, 0
      ),
      v_key_svc_a
    )
      AND NOT pg_temp._xa_has(
        public.get_business_cross_analytics(
          v_biz_a, v_from, v_to,
          jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_ids_none', jsonb_build_array(v_svc_b)),
          'last_visit_desc', 100, 0
        ),
        v_key_svc_both
      ),
    'X not Y'
  );

  UPDATE public.services SET name = 'XBOOK_CA7B_A_RENAMED' WHERE id = v_svc_a;
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K71_renamed_service_uuid_matches',
    pg_temp._xa_has(v_rep, v_key_svc_a),
    'rename uuid'
  );
  UPDATE public.services SET name = 'XBOOK_CA7B_A' WHERE id = v_svc_a;

  INSERT INTO _xbook_ca7b_results VALUES (
    'K72_deleted_service_cannot_filter',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object('service_ids', jsonb_build_array(v_svc_del)),
      'last_visit_desc', 50, 0
    ) = '22023'
      AND pg_temp._xa_find(v_biz_a, v_from, v_to, '{}'::jsonb, public._analytics_customer_key(NULL, '+389700077220', NULL, 'XBOOK_CA7B_DELCUST')) IS NOT NULL,
    'orphan uuid rejected as filter; customer retained'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'K73_cross_tenant_service_rejected',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object('service_ids', jsonb_build_array(v_svc_b_other)),
      'last_visit_desc', 50, 0
    ) = '22023',
    'foreign svc'
  );

  -- Staff
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array(v_staff_a::text), 'staff_scope', 'lifetime'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L74_staff_any_lifetime',
    pg_temp._xa_has(v_rep, v_key_svc_a) AND NOT pg_temp._xa_has(v_rep, v_key_ua) AND NOT pg_temp._xa_has(v_rep, v_key_svc_b),
    'stefan lifetime'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array(v_staff_a::text), 'staff_scope', 'period'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L75_staff_any_period',
    pg_temp._xa_has(v_rep, v_key_new) AND NOT pg_temp._xa_has(v_rep, v_key_i31),
    'stefan period'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array('unassigned'), 'staff_scope', 'lifetime'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L76_unassigned_lifetime',
    pg_temp._xa_has(v_rep, v_key_ua) AND NOT pg_temp._xa_has(v_rep, v_key_svc_a),
    'unassigned'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array('unassigned'), 'staff_scope', 'period'),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L77_unassigned_period',
    pg_temp._xa_has(v_rep, v_key_ua),
    'unassigned period'
  );

  UPDATE public.staff_members SET active = false WHERE id = v_staff_a;
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array(v_staff_a::text)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L78_inactive_staff_uuid_matches',
    pg_temp._xa_has(v_rep, v_key_svc_a),
    'inactive staff'
  );
  UPDATE public.staff_members SET active = true WHERE id = v_staff_a;

  UPDATE public.staff_members SET name = 'XBOOK_CA7B_STEFAN_NEW' WHERE id = v_staff_a;
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('staff_ids', jsonb_build_array(v_staff_a::text)),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'L79_renamed_staff_same_uuid',
    pg_temp._xa_has(v_rep, v_key_svc_a),
    'rename staff'
  );
  UPDATE public.staff_members SET name = 'XBOOK_CA7B_STEFAN' WHERE id = v_staff_a;

  INSERT INTO _xbook_ca7b_results VALUES (
    'L80_foreign_staff_rejected',
    pg_temp._xa_catch(
      v_biz_a, v_from, v_to,
      jsonb_build_object('staff_ids', jsonb_build_array(v_staff_b_other::text)),
      'last_visit_desc', 50, 0
    ) = '22023',
    'foreign staff'
  );

  -- Combinations
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object(
      'gender', jsonb_build_array('female'),
      'age_buckets', jsonb_build_array('25_34'),
      'city_ids', jsonb_build_array(v_city_strumica)
    ),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M81_gender_age_city',
    pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      jsonb_build_object(
        'gender', jsonb_build_array('female'),
        'age_buckets', jsonb_build_array('25_34'),
        'city_ids', jsonb_build_array(v_city_strumica::text)
      ),
      v_key_approved
    )
      OR pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        jsonb_build_object(
          'gender', jsonb_build_array('female'),
          'age_buckets', jsonb_build_array('25_34'),
          'city_ids', jsonb_build_array(v_city_strumica::text)
        ),
        'u:' || v_user_age::text
      ),
    'demo AND'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M81b_female_25_34_strumica_includes_approved',
    pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      jsonb_build_object(
        'gender', jsonb_build_array('female'),
        'age_buckets', jsonb_build_array('25_34'),
        'city_ids', jsonb_build_array(v_city_strumica::text)
      ),
      v_key_approved
    ),
    pg_temp._xa_find(
      v_biz_a, v_from, v_to,
      jsonb_build_object(
        'gender', jsonb_build_array('female'),
        'age_buckets', jsonb_build_array('25_34'),
        'city_ids', jsonb_build_array(v_city_strumica::text)
      ),
      v_key_approved
    )->>'age_bucket'
  );

  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to, '{"is_vip":true,"has_future_booking":false}'::jsonb, 'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M82_vip_no_future',
    pg_temp._xa_present(v_biz_a, v_from, v_to, '{"is_vip":true,"has_future_booking":false}'::jsonb, v_key_approved)
      AND NOT pg_temp._xa_present(v_biz_a, v_from, v_to, '{"is_vip":true,"has_future_booking":false}'::jsonb, v_key_fut),
    'vip no future'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object(
      'customer_type', 'returning',
      'service_ids', jsonb_build_array(v_svc_a),
      'service_scope', 'period'
    ),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M83_returning_service_period',
    pg_temp._xa_has(v_rep, v_key_ret) AND NOT pg_temp._xa_has(v_rep, v_key_new),
    'returning + service period'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    '{"visit_frequency":"repeat","inactive_days_min":20,"has_future_booking":false}'::jsonb,
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M84_repeat_inactive_no_future',
    pg_temp._xa_present(
      v_biz_a, v_from, v_to,
      '{"visit_frequency":"repeat","inactive_days_min":20,"has_future_booking":false}'::jsonb,
      v_key_i31
    )
      AND NOT pg_temp._xa_present(
        v_biz_a, v_from, v_to,
        '{"visit_frequency":"repeat","inactive_days_min":20,"has_future_booking":false}'::jsonb,
        v_key_new
      ),
    'repeat+inactive+no future (I31 last visit 31d, lifetime 2)'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object(
      'gender', jsonb_build_array('unknown'),
      'visit_frequency', 'single',
      'service_ids', jsonb_build_array(v_svc_a),
      'staff_ids', jsonb_build_array(v_staff_a::text),
      'has_future_booking', false,
      'lifetime_visits_min', 1
    ),
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'M85_six_filter_combo',
    pg_temp._xa_has(v_rep, v_key_new)
      AND NOT pg_temp._xa_has(v_rep, v_key_ret)
      AND NOT pg_temp._xa_has(v_rep, v_key_fut),
    '6-way AND'
  );

  -- Summary
  v_filters := jsonb_build_object('service_ids', jsonb_build_array(v_svc_b), 'service_match', 'any');
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'last_visit_desc', 100, 0);
  SELECT coalesce(sum((c->>'completed_visits_period')::numeric), 0),
         coalesce(sum((c->>'completed_revenue_period')::numeric), 0)
  INTO v_sum_visits, v_sum_rev
  FROM jsonb_array_elements(v_rep->'customers') c;
  INSERT INTO _xbook_ca7b_results VALUES (
    'N86_matched_customers',
    (v_rep->'summary'->>'matched_customers')::bigint = jsonb_array_length(v_rep->'customers')
      AND (v_rep->'pagination'->>'total')::bigint = (v_rep->'summary'->>'matched_customers')::bigint,
    v_rep->'summary'->>'matched_customers'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'N87_matched_with_visits',
    (v_rep->'summary'->>'matched_with_visits')::bigint = (
      SELECT count(*) FROM jsonb_array_elements(v_rep->'customers') c
      WHERE (c->>'completed_visits_lifetime')::bigint > 0
    ),
    v_rep->'summary'->>'matched_with_visits'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'N88_period_visits_reconcile',
    (v_rep->'summary'->>'period_completed_visits')::numeric = v_sum_visits,
    format('sum=%s summary=%s', v_sum_visits, v_rep->'summary'->>'period_completed_visits')
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'N89_period_revenue_reconcile',
    (v_rep->'summary'->>'period_completed_revenue')::numeric = v_sum_rev,
    format('sum=%s summary=%s', v_sum_rev, v_rep->'summary'->>'period_completed_revenue')
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'N90_future_booking_counts_customers',
    (v_rep->'summary'->>'future_booking_count')::bigint = (
      SELECT count(*) FROM jsonb_array_elements(v_rep->'customers') c
      WHERE (c->>'has_upcoming_appointment')::boolean
    ),
    v_rep->'summary'->>'future_booking_count'
  );
  v_row := pg_temp._xa_cust(v_rep, v_key_est);
  -- EST used service A not B; fetch via A
  v_row := pg_temp._xa_find(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a)),
    v_key_est
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'N91_estimated_flag',
    (v_row->>'revenue_is_estimated')::boolean
      AND (v_row->>'completed_revenue_lifetime')::numeric = 700,
    coalesce(v_row::text, 'missing est')
  );

  -- Sorting / pagination
  v_filters := jsonb_build_object('service_ids', jsonb_build_array(v_svc_b));
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'last_visit_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O92_default_sort_deterministic',
    v_rep->>'sort' = 'last_visit_desc'
      AND (v_rep->'customers'->0->>'analytics_customer_key')
        = (
          SELECT c->>'analytics_customer_key'
          FROM jsonb_array_elements(v_rep->'customers') c
          ORDER BY (c->>'last_completed_visit_at') DESC NULLS LAST, c->>'analytics_customer_key'
          LIMIT 1
        ),
    v_rep->'customers'->0->>'analytics_customer_key'
  );
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'last_visit_asc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O93_last_visit_asc',
    (SELECT c->>'analytics_customer_key' FROM jsonb_array_elements(v_rep->'customers') c
      WHERE c->>'analytics_customer_key' IN (v_key_sort_a, v_key_sort_b, v_key_sort_c)
      ORDER BY (c->>'last_completed_visit_at') ASC NULLS LAST, c->>'analytics_customer_key' LIMIT 1)
      = (v_rep->'customers'->0->>'analytics_customer_key')
      OR pg_temp._xa_has(v_rep, v_key_sort_b),
    v_rep->'customers'->0->>'display_name'
  );
  -- BBB has oldest completed (before period); among A/B/C should be first for asc if all three on page.
  INSERT INTO _xbook_ca7b_results VALUES (
    'O93b_bbb_before_aaa_on_asc',
    (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_b
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_a
    ),
    'BBB older than AAA'
  );

  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'lifetime_revenue_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O94_lifetime_revenue_desc',
    (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_a
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_b
    ),
    'AAA 300 before BBB 100'
  );
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'period_revenue_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O95_period_revenue_desc',
    (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_a
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_b
    ),
    'AAA period 300, BBB period 0'
  );
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a)),
    'lifetime_visits_desc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'O96_lifetime_visits_desc',
    (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_ret
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_new
    ),
    'ret 2 before new 1'
  );
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'name_asc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O97_name_asc',
    (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_a
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_b
    )
      AND (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_b
    ) < (
      SELECT min(ord) FROM (
        SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
        FROM jsonb_array_elements(v_rep->'customers') c
      ) s WHERE k = v_key_sort_c
    ),
    'AAA < BBB < CCC'
  );
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'next_booking_asc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O98_next_booking_asc',
    v_rep->'customers'->0->>'has_upcoming_appointment' = 'true'
      AND pg_temp._xa_cust(v_rep, v_key_sort_c) IS NOT NULL
      AND (
        SELECT min(ord) FROM (
          SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
          FROM jsonb_array_elements(v_rep->'customers') c
        ) s WHERE k = v_key_sort_c
      ) < (
        SELECT min(ord) FROM (
          SELECT row_number() OVER () AS ord, c->>'analytics_customer_key' AS k
          FROM jsonb_array_elements(v_rep->'customers') c
        ) s WHERE k = v_key_sort_a
      ),
    'CCC upcoming first'
  );

  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_b)),
    'name_asc', 100, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'O99_tie_break_analytics_customer_key',
    (SELECT count(DISTINCT c->>'analytics_customer_key') FROM jsonb_array_elements(v_rep->'customers') c)
      = jsonb_array_length(v_rep->'customers'),
    'unique keys'
  );

  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'name_asc', 2, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'O100_limit_offset',
    jsonb_array_length(v_rep->'customers') = 2
      AND (v_rep->'pagination'->>'limit')::int = 2
      AND (v_rep->'pagination'->>'offset')::int = 0,
    'page size 2'
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'O101_has_more',
    (v_rep->'pagination'->>'has_more')::boolean
      AND (v_rep->'pagination'->>'total')::bigint > 2,
    v_rep->'pagination'::text
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'O102_total_present',
    (v_rep->'pagination'->>'total')::bigint = (v_rep->'summary'->>'matched_customers')::bigint,
    v_rep->'pagination'->>'total'
  );

  -- Privacy / applied filters
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, v_filters, 'last_visit_desc', 50, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'P103_no_dob',
    NOT pg_temp._jsonb_has_forbidden_key(v_rep),
    'forbidden scan'
  );
  INSERT INTO _xbook_ca7b_results VALUES ('P104_no_customer_user_id', NOT pg_temp._jsonb_has_forbidden_key(v_rep), 'user id');
  INSERT INTO _xbook_ca7b_results VALUES ('P105_no_auth_user_id', NOT pg_temp._jsonb_has_forbidden_key(v_rep), 'auth');
  INSERT INTO _xbook_ca7b_results VALUES ('P106_no_internal_notes', NOT pg_temp._jsonb_has_forbidden_key(v_rep), 'notes');
  INSERT INTO _xbook_ca7b_results VALUES ('P107_no_private_profile_object', (v_rep->'customers'->0->'private_profile') IS NULL, 'profile');
  v_rep := public.get_business_cross_analytics(
    v_biz_a, v_from, v_to,
    jsonb_build_object('service_ids', jsonb_build_array(v_svc_a), 'service_match', 'none'),
    'last_visit_desc', 10, 0
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'P108_applied_filters_normalized',
    (v_rep->'applied_filters' ? 'service_ids_none')
      AND NOT (v_rep->'applied_filters' ? 'service_ids')
      AND v_rep->'applied_filters'->>'service_scope' = 'lifetime'
      AND v_rep->'applied_filters'->>'service_match' IS NULL,
    v_rep->'applied_filters'::text
  );

  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'empty_filters_echo',
    v_rep->'applied_filters' = '{}'::jsonb,
    v_rep->'applied_filters'::text
  );

  -- Performance identified-customer reconciliation note for no-filter
  v_perf := public.get_business_performance_report(v_biz_a, v_from, v_to);
  v_ov := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  v_rep := public.get_business_cross_analytics(v_biz_a, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 100, 0);
  INSERT INTO _xbook_ca7b_results VALUES (
    'AB_no_filter_period_visits_vs_overview_identified',
    (v_rep->'summary'->>'period_completed_visits')::bigint
      = (v_ov->'overview'->>'completed_visits')::bigint
      OR (v_rep->'summary'->>'period_completed_visits')::bigint
         <= (v_perf->>'completed_visits')::bigint,
    format('cross=%s overview=%s perf=%s unidentified=%s',
      v_rep->'summary'->>'period_completed_visits',
      v_ov->'overview'->>'completed_visits',
      v_perf->>'completed_visits',
      v_ov->'quality'->>'unidentified_booking_count')
  );

  -- Cleanup fixtures
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCA7B-%' OR customer_name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700077%'
     OR reason = 'xbook_ca7b_test';
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (
      bc.display_name LIKE 'XBOOK_CA7B%'
      OR bc.phone LIKE '+389700077%'
      OR bc.client_key LIKE 'p:389700077%'
    );
  DELETE FROM public.customer_private_profiles pp
  USING auth.users u
  WHERE pp.user_id = u.id AND u.email LIKE 'xbook-ca7b-%@invalid.example';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_CA7B%'
     OR phone LIKE '+389700077%'
     OR client_key LIKE 'p:389700077%'
     OR client_key LIKE 'e:xbook-ca7b-%'
     OR client_key LIKE 'u:' || v_user_female::text
     OR client_key LIKE 'u:' || v_user_male::text
     OR client_key LIKE 'u:' || v_user_age::text
     OR client_key LIKE 'u:' || v_user_link::text;
  DELETE FROM public.services WHERE name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_CA7B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ca7b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-ca7b-%@invalid.example';

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_after FROM public.staff_members;
  SELECT count(*) INTO v_svc_after FROM public.services;

  INSERT INTO _xbook_ca7b_results VALUES (
    'cleanup_bookings_unchanged',
    v_bookings_after = v_bookings_before,
    format('%s→%s', v_bookings_before, v_bookings_after)
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'cleanup_links_unchanged',
    v_links_after = v_links_before,
    format('%s→%s', v_links_before, v_links_after)
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'cleanup_staff_unchanged',
    v_staff_after = v_staff_before,
    format('%s→%s', v_staff_before, v_staff_after)
  );
  INSERT INTO _xbook_ca7b_results VALUES (
    'cleanup_services_unchanged',
    v_svc_after = v_svc_before,
    format('%s→%s', v_svc_before, v_svc_after)
  );

  -- Live Test Barber formula parity
  IF v_tz_tb IS NULL THEN
    INSERT INTO _xbook_ca7b_results VALUES ('live_test_barber_present', false, 'missing timezone');
  ELSE
    INSERT INTO _xbook_ca7b_results VALUES ('live_test_barber_present', true, v_biz_tb::text);
    PERFORM public._xbook_ca7b_test_set_jwt(v_biz_tb);
    v_from := DATE '2026-08-01';
    v_to := DATE '2026-08-31';
    v_rep := public.get_business_cross_analytics(v_biz_tb, v_from, v_to, '{}'::jsonb, 'last_visit_desc', 50, 0);
    v_ov := public.get_business_customer_analytics_overview(v_biz_tb, v_from, v_to);
    v_perf := public.get_business_performance_report(v_biz_tb, v_from, v_to);
    v_seg := public.get_business_customer_segment(v_biz_tb, 'repeat', v_from, v_to, NULL, 50, 0);

    INSERT INTO _xbook_ca7b_results VALUES (
      'live_tb_ok_payload',
      (v_rep->>'ok')::boolean
        AND (v_rep->'summary'->>'matched_customers')::bigint
          = (v_ov->'population'->>'total_customers')::bigint,
      format('cross_pop=%s overview_total=%s',
        v_rep->'summary'->>'matched_customers',
        v_ov->'population'->>'total_customers')
    );

    INSERT INTO _xbook_ca7b_results VALUES (
      'live_tb_period_visits_le_performance',
      (v_rep->'summary'->>'period_completed_visits')::bigint
        <= (v_perf->>'completed_visits')::bigint,
      format('cross=%s perf=%s unidentified=%s',
        v_rep->'summary'->>'period_completed_visits',
        v_perf->>'completed_visits',
        v_ov->'quality'->>'unidentified_booking_count')
    );

    SELECT bc.customer_user_id, bc.client_key
    INTO v_daniela_uid, v_daniela_guest
    FROM public.business_customers bc
    WHERE bc.business_id = v_biz_tb
      AND bc.customer_number = 2
      AND bc.customer_user_id IS NOT NULL
    LIMIT 1;

    IF v_daniela_uid IS NOT NULL THEN
      v_daniela_auth := 'u:' || v_daniela_uid::text;
      SELECT count(*) INTO v_n
      FROM public._business_analytics_customer_keys(v_biz_tb) k
      WHERE k.analytics_customer_key IN (v_daniela_auth, v_daniela_guest);
      INSERT INTO _xbook_ca7b_results VALUES (
        'live_tb_daniela_population_once',
        v_n = 1
          AND EXISTS (
            SELECT 1 FROM public._business_analytics_customer_keys(v_biz_tb) k
            WHERE k.analytics_customer_key = v_daniela_auth
          ),
        format('keys=%s auth=%s guest=%s', v_n, v_daniela_auth, v_daniela_guest)
      );
      INSERT INTO _xbook_ca7b_results VALUES (
        'live_tb_daniela_detail',
        (public.get_business_customer_detail(v_biz_tb, v_daniela_auth, 5, 0)->>'ok')::boolean,
        v_daniela_auth
      );
    ELSE
      INSERT INTO _xbook_ca7b_results VALUES ('live_tb_daniela_population_once', false, 'customer #2 missing');
      INSERT INTO _xbook_ca7b_results VALUES ('live_tb_daniela_detail', false, 'customer #2 missing');
    END IF;

    INSERT INTO _xbook_ca7b_results VALUES (
      'live_tb_unassigned_sentinel',
      (public.get_business_cross_analytics(
        v_biz_tb, v_from, v_to,
        '{"staff_ids":["unassigned"]}'::jsonb,
        'last_visit_desc', 10, 0
      )->>'ok')::boolean,
      'unassigned accepted'
    );

    INSERT INTO _xbook_ca7b_results VALUES (
      'live_tb_repeat_segment_subset',
      (public.get_business_cross_analytics(
        v_biz_tb, v_from, v_to, '{"visit_frequency":"repeat"}'::jsonb, 'last_visit_desc', 50, 0
      )->'summary'->>'matched_customers')::bigint
        = (v_ov->'overview'->>'repeat_customers')::bigint,
      format('cross_repeat=%s overview_repeat=%s seg=%s',
        public.get_business_cross_analytics(
          v_biz_tb, v_from, v_to, '{"visit_frequency":"repeat"}'::jsonb, 'last_visit_desc', 50, 0
        )->'summary'->>'matched_customers',
        v_ov->'overview'->>'repeat_customers',
        v_seg->'summary'->>'total_count')
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DELETE FROM public.bookings WHERE booking_ref LIKE 'XCA7B-%' OR customer_name LIKE 'XBOOK_CA7B%';
    DELETE FROM public.business_customer_identity_links
    WHERE legacy_analytics_key LIKE 'p:389700077%'
       OR reason = 'xbook_ca7b_test';
    DELETE FROM public.business_customer_internal_notes n
    USING public.business_customers bc
    WHERE n.business_customer_id = bc.id
      AND (
        bc.display_name LIKE 'XBOOK_CA7B%'
        OR bc.phone LIKE '+389700077%'
        OR bc.client_key LIKE 'p:389700077%'
      );
    DELETE FROM public.customer_private_profiles pp
    USING auth.users u
    WHERE pp.user_id = u.id AND u.email LIKE 'xbook-ca7b-%@invalid.example';
    DELETE FROM public.business_customers
    WHERE display_name LIKE 'XBOOK_CA7B%'
       OR phone LIKE '+389700077%'
       OR client_key LIKE 'p:389700077%'
       OR client_key LIKE 'e:xbook-ca7b-%';
    DELETE FROM public.services WHERE name LIKE 'XBOOK_CA7B%';
    DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_CA7B%';
    DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ca7b-%@invalid.example';
    DELETE FROM auth.users WHERE email LIKE 'xbook-ca7b-%@invalid.example';
    RAISE;
END;
$$;

SELECT test_name, passed, left(coalesce(detail, ''), 400) AS detail
FROM (
  SELECT test_name, passed, detail, 0 AS ord
  FROM _xbook_ca7b_results
  WHERE NOT passed
  UNION ALL
  SELECT 'ZZZ_SUMMARY',
         (count(*) FILTER (WHERE NOT passed) = 0),
         format('total=%s passed=%s failed=%s', count(*), count(*) FILTER (WHERE passed), count(*) FILTER (WHERE NOT passed)),
         1
  FROM _xbook_ca7b_results
) s
ORDER BY ord, test_name;

DROP FUNCTION IF EXISTS public._xbook_ca7b_test_set_jwt(uuid, text);
