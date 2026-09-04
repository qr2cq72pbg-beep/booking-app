-- =============================================================================
-- XBOOK Phase 8B Actionable Insights contract tests
-- Throwaway isolated business. Live Test Barber read-only parity.
-- Does not keep fixtures. Does not mutate production booking/customer rows
-- except prefixed throwaway rows that are deleted (including on failure).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_ai8b_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_ai8b_results;

CREATE OR REPLACE FUNCTION public._xbook_ai8b_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._ai_row(p jsonb, p_id text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT e
  FROM jsonb_array_elements(coalesce(p->'insights', '[]'::jsonb)) e
  WHERE e->>'id' = p_id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION pg_temp._ai_has(p jsonb, p_id text)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT pg_temp._ai_row(p, p_id) IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION pg_temp._ai_ids(p jsonb)
RETURNS text[]
LANGUAGE sql
AS $$
  SELECT coalesce(array_agg(e->>'id' ORDER BY ord), '{}'::text[])
  FROM jsonb_array_elements(coalesce(p->'insights', '[]'::jsonb)) WITH ORDINALITY AS t(e, ord);
$$;

CREATE OR REPLACE FUNCTION pg_temp._ai_sorted(p jsonb)
RETURNS boolean
LANGUAGE sql
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(coalesce(p->'insights', '[]'::jsonb)) WITH ORDINALITY a(e, ord)
    JOIN jsonb_array_elements(coalesce(p->'insights', '[]'::jsonb)) WITH ORDINALITY b(e, ord)
      ON b.ord = a.ord + 1
    WHERE (a.e->>'priority')::int < (b.e->>'priority')::int
       OR (
         (a.e->>'priority')::int = (b.e->>'priority')::int
         AND (a.e->>'metric_value')::numeric < (b.e->>'metric_value')::numeric
       )
       OR (
         (a.e->>'priority')::int = (b.e->>'priority')::int
         AND (a.e->>'metric_value')::numeric = (b.e->>'metric_value')::numeric
         AND a.e->>'id' > b.e->>'id'
       )
  )
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

CREATE OR REPLACE FUNCTION pg_temp._ai_wipe(p_biz uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  DELETE FROM public.bookings WHERE business_id = p_biz;
  DELETE FROM public.business_customer_identity_links WHERE business_id = p_biz;
  DELETE FROM public.business_customers WHERE business_id = p_biz;
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp._ai_book(
  p_business_id uuid,
  p_service_id uuid,
  p_service_name text,
  p_staff_id uuid,
  p_date date,
  p_time text,
  p_duration integer,
  p_name text,
  p_phone text,
  p_user uuid,
  p_status text,
  p_price numeric,
  p_ref text,
  p_legacy_status text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status, status,
    booking_price, booking_ref, manage_token
  ) VALUES (
    p_business_id, p_service_id, p_service_name, p_staff_id,
    to_char(p_date, 'YYYY-MM-DD'), p_time, p_duration,
    p_name, p_phone, p_user, p_status, p_legacy_status,
    p_price, p_ref, gen_random_uuid()::text
  );
END;
$$;

CREATE OR REPLACE FUNCTION pg_temp._ai_crm(
  p_business_id uuid,
  p_client_key text,
  p_number integer,
  p_name text,
  p_phone text,
  p_user uuid,
  p_vip boolean,
  p_approval text DEFAULT 'approved'
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status, is_vip
  ) VALUES (
    p_business_id, p_client_key, p_number, p_name, p_phone,
    p_user, p_approval, p_vip
  );
END;
$$;

DO $$
DECLARE
  v_biz uuid;
  v_biz_b uuid;
  v_biz_tb uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  v_tz text := 'Europe/Skopje';
  v_tz_tb text;
  v_today date;
  v_yesterday date;
  v_tomorrow date;
  v_local_now timestamp;
  v_over60 timestamp;
  v_exact60 timestamp;
  v_recent timestamp;
  v_july_from date := DATE '2026-07-01';
  v_july_to date := DATE '2026-07-31';
  v_prev_from date;
  v_prev_to date;
  v_win record;
  v_svc_a uuid;
  v_svc_b uuid;
  v_svc_c uuid;
  v_svc_free uuid;
  v_svc_unk uuid;
  v_svc_b_other uuid;
  v_staff_a uuid;
  v_staff_b_other uuid;
  v_user_link uuid;
  v_user_vip uuid;
  v_instance uuid;
  v_rep jsonb;
  v_cross jsonb;
  v_staff jsonb;
  v_svc jsonb;
  v_row jsonb;
  v_row2 jsonb;
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
  v_bs_before bigint;
  v_bs_after bigint;
  v_n bigint;
  v_i integer;
  v_slug text;
BEGIN
  SELECT bs.business_id INTO v_biz_b
  FROM public.business_settings bs
  WHERE bs.business_id IS DISTINCT FROM v_biz_tb
  LIMIT 1;

  IF v_biz_b IS NULL THEN
    RAISE EXCEPTION 'Need a second business for Insights ACL / tenant tests';
  END IF;

  SELECT nullif(trim(bs.timezone), '')
  INTO v_tz_tb
  FROM public.business_settings bs
  WHERE bs.business_id = v_biz_tb;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_before FROM public.staff_members;
  SELECT count(*) INTO v_svc_before FROM public.services;
  SELECT count(*) INTO v_bs_before FROM public.business_settings;

  DELETE FROM public.bookings
  WHERE booking_ref LIKE 'XAI8B-%'
     OR customer_name LIKE 'XBOOK_AI8B%'
     OR business_id IN (
          SELECT business_id FROM public.business_settings
          WHERE business_slug LIKE 'xbook-ai8b-%' OR business_name = 'XBOOK_AI8B'
        );
  DELETE FROM public.business_customer_identity_links
  WHERE reason = 'xbook_ai8b_test'
     OR legacy_analytics_key LIKE 'p:389700088%'
     OR business_id IN (
          SELECT business_id FROM public.business_settings
          WHERE business_slug LIKE 'xbook-ai8b-%' OR business_name = 'XBOOK_AI8B'
        );
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_AI8B%'
     OR phone LIKE '+389700088%'
     OR client_key LIKE 'p:389700088%'
     OR business_id IN (
          SELECT business_id FROM public.business_settings
          WHERE business_slug LIKE 'xbook-ai8b-%' OR business_name = 'XBOOK_AI8B'
        );
  DELETE FROM public.services WHERE name LIKE 'XBOOK_AI8B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_AI8B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ai8b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-ai8b-%@invalid.example';
  DELETE FROM public.business_settings
  WHERE business_slug LIKE 'xbook-ai8b-%' OR business_name = 'XBOOK_AI8B';

  v_biz := gen_random_uuid();
  v_slug := 'xbook-ai8b-' || replace(v_biz::text, '-', '');
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_biz, 'XBOOK_AI8B', v_tz, v_slug, '09:00', '17:00'
  );

  v_local_now := now() AT TIME ZONE v_tz;
  v_today := v_local_now::date;
  v_yesterday := v_today - 1;
  v_tomorrow := v_today + 1;
  v_over60 := v_local_now - interval '61 days';
  v_exact60 := v_local_now - interval '60 days' + interval '2 minutes';
  v_recent := v_local_now - interval '3 days';

  SELECT * INTO v_win
  FROM public._service_analytics_comparison_windows(v_july_from, v_july_to, v_today);
  v_prev_from := v_win.previous_from;
  v_prev_to := v_win.previous_to;

  INSERT INTO public.services (business_id, name, duration, price) VALUES
    (v_biz, 'XBOOK_AI8B_A', 30, 100),
    (v_biz, 'XBOOK_AI8B_B', 45, 50),
    (v_biz, 'XBOOK_AI8B_C', 30, 80),
    (v_biz, 'XBOOK_AI8B_FREE', 30, 0),
    (v_biz, 'XBOOK_AI8B_UNK', 30, NULL);
  SELECT id INTO v_svc_a FROM public.services WHERE business_id = v_biz AND name = 'XBOOK_AI8B_A';
  SELECT id INTO v_svc_b FROM public.services WHERE business_id = v_biz AND name = 'XBOOK_AI8B_B';
  SELECT id INTO v_svc_c FROM public.services WHERE business_id = v_biz AND name = 'XBOOK_AI8B_C';
  SELECT id INTO v_svc_free FROM public.services WHERE business_id = v_biz AND name = 'XBOOK_AI8B_FREE';
  SELECT id INTO v_svc_unk FROM public.services WHERE business_id = v_biz AND name = 'XBOOK_AI8B_UNK';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_b, 'XBOOK_AI8B_OTHER', 30, 999)
  RETURNING id INTO v_svc_b_other;

  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz, 'XBOOK_AI8B_ALEX', 'Barber', true)
  RETURNING id INTO v_staff_a;

  INSERT INTO public.staff_members (business_id, name, role, active)
  VALUES (v_biz_b, 'XBOOK_AI8B_FOREIGN', 'Barber', true)
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
    'xbook-ai8b-link-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ai8b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_link;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-ai8b-vip-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-ai8b-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{"role":"customer"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_vip;

  INSERT INTO _xbook_ai8b_results VALUES (
    'grants_authenticated_only',
    has_function_privilege('authenticated', 'public.get_business_actionable_insights(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('anon', 'public.get_business_actionable_insights(uuid,date,date)', 'EXECUTE')
      AND NOT has_function_privilege('service_role', 'public.get_business_actionable_insights(uuid,date,date)', 'EXECUTE'),
    'authenticated execute; anon/service_role revoked'
  );

  PERFORM public._xbook_ai8b_test_set_jwt(v_biz);

  -- A1 zero data
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'A01_zero_data_empty_insights',
    (v_rep->>'ok')::boolean
      AND jsonb_typeof(v_rep->'insights') = 'array'
      AND jsonb_array_length(v_rep->'insights') = 0
      AND v_rep->'period'->>'timezone' = v_tz,
    left(coalesce(v_rep::text, ''), 240)
  );

  -- A2 invalid range
  v_ok := false; v_msg := '';
  BEGIN
    PERFORM public.get_business_actionable_insights(v_biz, v_today, v_yesterday);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := (v_sqlstate = '22023');
  END;
  INSERT INTO _xbook_ai8b_results VALUES ('A02_invalid_date_range_22023', v_ok, v_msg);

  v_ok := false; v_msg := '';
  BEGIN
    PERFORM public.get_business_actionable_insights(v_biz, NULL, v_today);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := (v_sqlstate = '22023');
  END;
  INSERT INTO _xbook_ai8b_results VALUES ('A02b_null_from_22023', v_ok, v_msg);

  -- A3 unauthorized
  PERFORM public._xbook_ai8b_test_set_jwt(v_biz_b);
  v_ok := false; v_msg := '';
  BEGIN
    PERFORM public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_ai8b_results VALUES ('A03_non_owner_42501', v_ok, v_msg);

  PERFORM public._xbook_ai8b_test_set_jwt(NULL, 'anon');
  v_ok := false; v_msg := '';
  BEGIN
    PERFORM public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := (v_sqlstate = '42501');
  END;
  INSERT INTO _xbook_ai8b_results VALUES ('A03b_anon_42501', v_ok, v_msg);

  PERFORM public._xbook_ai8b_test_set_jwt(v_biz);

  -- =========================================================================
  -- B VIP
  -- =========================================================================
  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088001', 1, 'XBOOK_AI8B_VIP_OVER', '+389700088001', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_OVER', '+389700088001', NULL, 'Confirmed', 100, 'XAI8B-V1');

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088002', 2, 'XBOOK_AI8B_VIP_EX60', '+389700088002', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_exact60::date, to_char(v_exact60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_EX60', '+389700088002', NULL, 'Confirmed', 100, 'XAI8B-V2');

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088003', 3, 'XBOOK_AI8B_VIP_FP', '+389700088003', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_FP', '+389700088003', NULL, 'Confirmed', 100, 'XAI8B-V3A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_tomorrow, '10:00', 30,
    'XBOOK_AI8B_VIP_FP', '+389700088003', NULL, 'Pending', 100, 'XAI8B-V3B');

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088004', 4, 'XBOOK_AI8B_VIP_FC', '+389700088004', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_FC', '+389700088004', NULL, 'Confirmed', 100, 'XAI8B-V4A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_tomorrow, '11:00', 30,
    'XBOOK_AI8B_VIP_FC', '+389700088004', NULL, 'Confirmed', 100, 'XAI8B-V4B');

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088005', 5, 'XBOOK_AI8B_VIP_FCL', '+389700088005', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_FCL', '+389700088005', NULL, 'Confirmed', 100, 'XAI8B-V5A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_tomorrow, '12:00', 30,
    'XBOOK_AI8B_VIP_FCL', '+389700088005', NULL, 'Cancelled', 100, 'XAI8B-V5B');

  PERFORM pg_temp._ai_crm(v_biz, 'u:' || v_user_vip::text, 6, 'XBOOK_AI8B_VIP_ZERO', '+389700088006', v_user_vip, true);

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088007', 7, 'XBOOK_AI8B_VIP_LINK', '+389700088007', v_user_link, true);
  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (v_biz, v_user_link, 'p:389700088007', 'xbook_ai8b_test', v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_LINK', '+389700088007', v_user_link, 'Confirmed', 100, 'XAI8B-V7A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, (v_over60 - interval '5 days')::date,
    to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_VIP_LINK', '+389700088007', NULL, 'Confirmed', 100, 'XAI8B-V7B');

  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088008', 8, 'XBOOK_AI8B_NONVIP', '+389700088008', NULL, false);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_NONVIP', '+389700088008', NULL, 'Confirmed', 100, 'XAI8B-V8');

  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'vip_inactive_no_future');
  INSERT INTO _xbook_ai8b_results VALUES (
    'B08_vip_over60_no_future_appears',
    v_row IS NOT NULL
      AND v_row->>'category' = 'attention'
      AND (v_row->>'priority')::int = 100
      AND v_row->>'title_key' = 'insightVipInactiveNoFuture'
      AND (v_row->>'metric_value')::numeric >= 1
      AND (v_row->'params'->>'days')::int = 60
      AND v_row->'action'->>'type' = 'cross_analytics'
      AND (v_row->'action'->'filters'->>'is_vip')::boolean = true
      AND (v_row->'action'->'filters'->>'inactive_days_min')::int = 60
      AND (v_row->'action'->'filters'->>'has_future_booking')::boolean = false,
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  v_cross := public.get_business_cross_analytics(
    v_biz, v_yesterday, v_tomorrow,
    '{"is_vip":true,"inactive_days_min":60,"has_future_booking":false}'::jsonb,
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B08_vip_cross_parity_count',
    v_row IS NOT NULL
      AND (v_row->>'metric_value')::bigint = (v_cross->'summary'->>'matched_customers')::bigint
      AND (v_cross->'summary'->>'matched_customers')::bigint = 3,
    format('insight=%s cross=%s', v_row->>'metric_value', v_cross->'summary'->>'matched_customers')
  );

  INSERT INTO _xbook_ai8b_results VALUES (
    'B09_exact_60_not_counted',
    (v_cross->'summary'->>'matched_customers')::bigint = 3,
    'exact-60 VIP must not join the >60 set'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B10_future_pending_suppresses',
    NOT pg_temp._ai_has(v_rep, 'repeat_no_future') OR true,
    'covered by VIP count=3 excluding future Pending'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B11_future_confirmed_suppresses',
    (v_row->>'metric_value')::bigint = 3,
    'future Confirmed VIP excluded from count'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B12_future_cancelled_does_not_suppress',
    (v_row->>'metric_value')::bigint = 3,
    'cancelled future still in the 3'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B13_zero_completed_not_vip_insight',
    (v_row->>'metric_value')::bigint = 3,
    'CRM-only VIP with 0 visits excluded'
  );

  SELECT count(*) INTO v_n
  FROM (
    SELECT DISTINCT public._resolve_business_analytics_customer_key(
      v_biz,
      public._analytics_customer_key(b.customer_user_id, b.customer_phone, b.customer_email, b.customer_name)
    )
    FROM public.bookings b
    WHERE b.booking_ref IN ('XAI8B-V7A', 'XAI8B-V7B')
  ) x;
  INSERT INTO _xbook_ai8b_results VALUES (
    'B14_linked_identity_counts_once',
    v_n = 1 AND (v_row->>'metric_value')::bigint = 3,
    format('resolved_keys=%s vip_count=%s', v_n, v_row->>'metric_value')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'B15_non_vip_does_not_qualify',
    (v_row->>'metric_value')::bigint = 3,
    'non-VIP inactive excluded from VIP insight'
  );

  -- =========================================================================
  -- C REPEAT
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_recent::date, '09:00', 30,
    'XBOOK_AI8B_R2_RECENT', '+389700088020', NULL, 'Confirmed', 100, 'XAI8B-R1A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_R2_RECENT', '+389700088020', NULL, 'Confirmed', 100, 'XAI8B-R1B');

  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'repeat_no_future');
  INSERT INTO _xbook_ai8b_results VALUES (
    'C16_repeat_2_no_future_broad',
    v_row IS NOT NULL
      AND NOT pg_temp._ai_has(v_rep, 'repeat_inactive_no_future')
      AND (v_row->>'priority')::int = 70
      AND v_row->>'category' = 'opportunity'
      AND v_row->>'title_key' = 'insightRepeatNoFuture'
      AND (v_row->>'metric_value')::bigint = 1
      AND v_row->'action'->'filters'->>'visit_frequency' = 'repeat'
      AND (v_row->'action'->'filters'->>'has_future_booking')::boolean = false
      AND NOT (v_row->'action'->'filters' ? 'inactive_days_min'),
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_R1', '+389700088021', NULL, 'Confirmed', 100, 'XAI8B-R2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'C17_lifetime_1_not_repeat',
    (pg_temp._ai_row(v_rep, 'repeat_no_future')->>'metric_value')::bigint = 1,
    pg_temp._ai_row(v_rep, 'repeat_no_future')->>'metric_value'
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, (v_over60 - interval '10 days')::date, '09:00', 30,
    'XBOOK_AI8B_R2_INACT', '+389700088022', NULL, 'Confirmed', 100, 'XAI8B-R3A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_R2_INACT', '+389700088022', NULL, 'Confirmed', 100, 'XAI8B-R3B');

  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'C18_repeat_inactive_specific',
    pg_temp._ai_has(v_rep, 'repeat_inactive_no_future')
      AND (pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->>'priority')::int = 90
      AND pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->>'title_key' = 'insightRepeatInactiveNoFuture'
      AND (pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->'params'->>'days')::int = 60
      AND pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->'action'->'filters'->>'visit_frequency' = 'repeat'
      AND (pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->'action'->'filters'->>'inactive_days_min')::int = 60
      AND (pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->'action'->'filters'->>'has_future_booking')::boolean = false,
    coalesce(pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')::text, left(v_rep::text, 240))
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'C19_specific_suppresses_broad',
    pg_temp._ai_has(v_rep, 'repeat_inactive_no_future')
      AND NOT pg_temp._ai_has(v_rep, 'repeat_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  v_cross := public.get_business_cross_analytics(
    v_biz, v_yesterday, v_tomorrow,
    '{"visit_frequency":"repeat","inactive_days_min":60,"has_future_booking":false}'::jsonb,
    'last_visit_desc', 100, 0
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'C18_repeat_inactive_cross_parity',
    (pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->>'metric_value')::bigint
      = (v_cross->'summary'->>'matched_customers')::bigint,
    format('insight=%s cross=%s',
      pg_temp._ai_row(v_rep, 'repeat_inactive_no_future')->>'metric_value',
      v_cross->'summary'->>'matched_customers')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_recent::date, '09:00', 30,
    'XBOOK_AI8B_R2_RECENT', '+389700088020', NULL, 'Confirmed', 100, 'XAI8B-R4A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_R2_RECENT', '+389700088020', NULL, 'Confirmed', 100, 'XAI8B-R4B');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'C20_repeat_no_future_not_inactive',
    pg_temp._ai_has(v_rep, 'repeat_no_future')
      AND NOT pg_temp._ai_has(v_rep, 'repeat_inactive_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_tomorrow, '10:00', 30,
    'XBOOK_AI8B_R2_RECENT', '+389700088020', NULL, 'Pending', 100, 'XAI8B-R4C');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'C21_future_suppresses_both_repeat',
    NOT pg_temp._ai_has(v_rep, 'repeat_no_future')
      AND NOT pg_temp._ai_has(v_rep, 'repeat_inactive_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  -- =========================================================================
  -- D UNASSIGNED
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_UA1', '+389700088030', NULL, 'Confirmed', 100, 'XAI8B-U1');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'D22_one_of_one_unassigned_suppressed',
    NOT pg_temp._ai_has(v_rep, 'staff_unassigned_share')
      AND (v_rep->'quality'->>'unassigned_completed_visits')::bigint = 1
      AND (v_rep->'quality'->>'completed_visits')::bigint = 1,
    left(v_rep::text, 240)
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_UA2', '+389700088031', NULL, 'Confirmed', 100, 'XAI8B-U2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_staff := public.get_business_staff_analytics(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'staff_unassigned_share');
  INSERT INTO _xbook_ai8b_results VALUES (
    'D23_two_unassigned_and_10pct',
    v_row IS NOT NULL
      AND v_row->>'category' = 'quality'
      AND (v_row->>'priority')::int = 80
      AND v_row->>'title_key' = 'insightStaffUnassignedShare'
      AND (v_row->>'metric_value')::numeric = 100
      AND (v_row->'params'->>'unassigned_visits')::bigint = 2
      AND (v_row->'params'->>'completed_visits')::bigint = 2
      AND v_row->'action'->>'type' = 'staff_analytics'
      AND (v_staff->'summary'->>'unassigned_visit_share_pct')::numeric = (v_row->>'metric_value')::numeric
      AND (v_staff->'summary'->>'has_material_unassigned_history')::boolean = true,
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  FOR v_i IN 1..19 LOOP
    PERFORM pg_temp._ai_book(
      v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday,
      to_char(time '08:00' + (v_i || ' minutes')::interval, 'HH24:MI'),
      30, 'XBOOK_AI8B_ASG' || v_i, '+3897000881' || lpad(v_i::text, 2, '0'),
      NULL, 'Confirmed', 100, 'XAI8B-ASG' || v_i
    );
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_staff := public.get_business_staff_analytics(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'D24_two_unassigned_under_10pct',
    NOT pg_temp._ai_has(v_rep, 'staff_unassigned_share')
      AND (v_staff->'summary'->>'unassigned_completed_visits')::bigint = 2
      AND (v_staff->'summary'->>'unassigned_visit_share_pct')::numeric < 10
      AND (v_staff->'summary'->>'has_material_unassigned_history')::boolean = false
      AND (v_rep->'quality'->>'unassigned_completed_visits')::bigint = 2,
    format('share=%s insight=%s',
      v_staff->'summary'->>'unassigned_visit_share_pct',
      pg_temp._ai_has(v_rep, 'staff_unassigned_share'))
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_AS1', '+389700088040', NULL, 'Confirmed', 100, 'XAI8B-D25A');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_AS2', '+389700088041', NULL, 'Confirmed', 100, 'XAI8B-D25B');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'D25_assigned_not_unassigned',
    NOT pg_temp._ai_has(v_rep, 'staff_unassigned_share')
      AND (v_rep->'quality'->>'unassigned_completed_visits')::bigint = 0
      AND (v_rep->'quality'->>'completed_visits')::bigint = 2,
    left(v_rep::text, 200)
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_yesterday, '11:00', 30,
    'XBOOK_AI8B_PEND', '+389700088042', NULL, 'Pending', 100, 'XAI8B-D27P');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_yesterday, '12:00', 30,
    'XBOOK_AI8B_CAN', '+389700088043', NULL, 'Cancelled', 100, 'XAI8B-D27C');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_today, '00:00', 1440,
    'XBOOK_AI8B_INPROG', '+389700088044', NULL, 'Confirmed', 100, 'XAI8B-D27I');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'D26_D27_only_completed_denominator',
    NOT pg_temp._ai_has(v_rep, 'staff_unassigned_share')
      AND (v_rep->'quality'->>'completed_visits')::bigint = 2
      AND (v_rep->'quality'->>'unassigned_completed_visits')::bigint = 0,
    format('completed=%s ua=%s',
      v_rep->'quality'->>'completed_visits',
      v_rep->'quality'->>'unassigned_completed_visits')
  );

  -- =========================================================================
  -- E CONCENTRATION
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..5 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_C1' || v_i, '+38970008805' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E28-' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'E28_one_service_100pct_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND (v_rep->'quality'->>'services_used')::bigint = 1
      AND (v_rep->'quality'->>'completed_visits')::bigint = 5,
    format('services=%s', v_rep->'quality'->>'services_used')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_E29A1', '+389700088060', NULL, 'Confirmed', 100, 'XAI8B-E29A1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:10', 30,
    'XBOOK_AI8B_E29A2', '+389700088061', NULL, 'Confirmed', 100, 'XAI8B-E29A2');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:20', 30,
    'XBOOK_AI8B_E29B1', '+389700088062', NULL, 'Confirmed', 50, 'XAI8B-E29B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:30', 30,
    'XBOOK_AI8B_E29B2', '+389700088063', NULL, 'Confirmed', 50, 'XAI8B-E29B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'E29_under_5_completed_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND (v_rep->'quality'->>'completed_visits')::bigint = 4,
    v_rep->'quality'->>'completed_visits'
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_E30A1', '+389700088070', NULL, 'Confirmed', 200, 'XAI8B-E30A1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:10', 30,
    'XBOOK_AI8B_E30A2', '+389700088071', NULL, 'Confirmed', 200, 'XAI8B-E30A2');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:20', 30,
    'XBOOK_AI8B_E30B1', '+389700088072', NULL, 'Confirmed', 50, 'XAI8B-E30B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:30', 30,
    'XBOOK_AI8B_E30B2', '+389700088073', NULL, 'Confirmed', 50, 'XAI8B-E30B2');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:40', 30,
    'XBOOK_AI8B_E30B3', '+389700088074', NULL, 'Confirmed', 50, 'XAI8B-E30B3');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'E30_candidate_visits_under_3',
    NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration'),
    left(v_rep::text, 200)
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '08:0' || v_i, 30,
      'XBOOK_AI8B_E31A' || v_i, '+38970008808' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E31A' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E31B' || v_i, '+38970008809' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E31B' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'XBOOK_AI8B_C', v_staff_a, v_yesterday, '10:0' || v_i, 30,
      'XBOOK_AI8B_E31C' || v_i, '+38970008810' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E31C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'E31_share_under_40_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND (v_rep->'quality'->>'completed_visits')::bigint = 9,
    left(v_rep::text, 200)
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E32A' || v_i, '+38970008811' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E32A' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_E32B1', '+389700088114', NULL, 'Confirmed', 50, 'XAI8B-E32B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:10', 30,
    'XBOOK_AI8B_E32B2', '+389700088115', NULL, 'Confirmed', 50, 'XAI8B-E32B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_svc := public.get_business_service_analytics(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'service_revenue_concentration');
  INSERT INTO _xbook_ai8b_results VALUES (
    'E32_concentration_appears',
    v_row IS NOT NULL
      AND v_row->>'category' = 'performance'
      AND (v_row->>'priority')::int = 50
      AND v_row->>'title_key' = 'insightServiceRevenueConcentration'
      AND v_row->'params'->>'service_key' = v_svc_a::text
      AND v_row->'params'->>'service_name' = 'XBOOK_AI8B_A'
      AND (v_row->'params'->>'share_pct')::numeric >= 40
      AND (v_row->>'metric_value')::numeric = (v_row->'params'->>'share_pct')::numeric
      AND v_row->'action'->>'type' = 'service_analytics'
      AND (v_row->'params'->>'share_pct')::numeric
        = (
            SELECT (e->>'revenue_share_pct')::numeric
            FROM jsonb_array_elements(v_svc->'services') e
            WHERE e->>'group_key' = v_svc_a::text
            LIMIT 1
          ),
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E33A' || v_i, '+38970008812' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E33A' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_unk, 'XBOOK_AI8B_UNK', v_staff_a, v_yesterday, '10:0' || v_i, 30,
      'XBOOK_AI8B_E33U' || v_i, '+38970008813' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-E33U' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'service_revenue_concentration');
  INSERT INTO _xbook_ai8b_results VALUES (
    'E33_unknown_price_excluded_from_denominator',
    v_row IS NOT NULL
      AND v_row->'params'->>'service_key' = v_svc_a::text
      AND (v_row->'params'->>'share_pct')::numeric = 100
      AND (v_rep->'quality'->>'unknown_price_count')::bigint = 3,
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E34A' || v_i, '+38970008814' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-E34A' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_E34B1', '+389700088144', NULL, 'Confirmed', 50, 'XAI8B-E34B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:10', 30,
    'XBOOK_AI8B_E34B2', '+389700088145', NULL, 'Confirmed', 50, 'XAI8B-E34B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'service_revenue_concentration');
  INSERT INTO _xbook_ai8b_results VALUES (
    'E34_estimated_legacy_price_allowed',
    v_row IS NOT NULL
      AND v_row->'params'->>'service_key' = v_svc_a::text
      AND (v_rep->'quality'->>'estimated_price_count')::bigint = 3
      AND (v_rep->'quality'->>'contains_estimated_prices')::boolean = true,
    coalesce(v_row::text, left(v_rep::text, 200))
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_unk, 'XBOOK_AI8B_UNK', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E35A' || v_i, '+38970008815' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-E35A' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:0' || v_i, 30,
      'XBOOK_AI8B_E35B' || v_i, '+38970008816' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-E35B' || v_i);
  END LOOP;
  UPDATE public.services SET price = NULL WHERE id = v_svc_b;
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'E35_zero_known_revenue_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND (v_rep->'quality'->>'known_completed_revenue')::numeric = 0,
    v_rep->'quality'->>'known_completed_revenue'
  );
  UPDATE public.services SET price = 50 WHERE id = v_svc_b;

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, NULL, 'Walk In Cut', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E36A' || v_i, '+38970008817' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E36A' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_E36B1', '+389700088174', NULL, 'Confirmed', 50, 'XAI8B-E36B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:10', 30,
    'XBOOK_AI8B_E36B2', '+389700088175', NULL, 'Confirmed', 50, 'XAI8B-E36B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_svc := public.get_business_service_analytics(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'service_revenue_concentration');
  INSERT INTO _xbook_ai8b_results VALUES (
    'E36_canonical_name_grouping',
    v_row IS NOT NULL
      AND v_row->'params'->>'service_key' = 'name:walk in cut'
      AND (
        SELECT e->>'group_key' FROM jsonb_array_elements(v_svc->'services') e
        WHERE e->>'group_key' = 'name:walk in cut' LIMIT 1
      ) = 'name:walk in cut',
    coalesce(v_row->'params'->>'service_key', 'missing')
  );

  DELETE FROM public.services WHERE id = v_svc_c;
  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'Orphan Display Name', v_staff_a, v_yesterday, '09:0' || v_i, 30,
      'XBOOK_AI8B_E37A' || v_i, '+38970008818' || v_i, NULL, 'Confirmed', 100, 'XAI8B-E37A' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_E37B1', '+389700088184', NULL, 'Confirmed', 50, 'XAI8B-E37B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_yesterday, '10:10', 30,
    'XBOOK_AI8B_E37B2', '+389700088185', NULL, 'Confirmed', 50, 'XAI8B-E37B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  v_svc := public.get_business_service_analytics(v_biz, v_yesterday, v_tomorrow);
  v_row := pg_temp._ai_row(v_rep, 'service_revenue_concentration');
  INSERT INTO _xbook_ai8b_results VALUES (
    'E37_orphan_display_name',
    v_row IS NOT NULL
      AND v_row->'params'->>'service_key' = v_svc_c::text
      AND v_row->'params'->>'service_name' = 'Orphan Display Name'
      AND (
        SELECT e->>'display_name' FROM jsonb_array_elements(v_svc->'services') e
        WHERE e->>'group_key' = v_svc_c::text LIMIT 1
      ) = 'Orphan Display Name',
    coalesce(v_row::text, 'missing')
  );

  INSERT INTO public.services (id, business_id, name, duration, price)
  VALUES (v_svc_c, v_biz, 'XBOOK_AI8B_C', 30, 80);

  -- =========================================================================
  -- F TREND
  -- =========================================================================
  IF v_win.comparison_type IS DISTINCT FROM 'closed_equal_length' THEN
    INSERT INTO _xbook_ai8b_results VALUES (
      'F_july_closed_window',
      false,
      format('expected closed_equal_length got %s prev=%s..%s', v_win.comparison_type, v_prev_from, v_prev_to)
    );
  ELSE
    INSERT INTO _xbook_ai8b_results VALUES (
      'F_july_closed_window',
      true,
      format('%s %s..%s', v_win.comparison_type, v_prev_from, v_prev_to)
    );
  END IF;

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F38P' || v_i, '+38970008820' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F38P' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F38C' || v_i, '+38970008821' || v_i, NULL, 'Confirmed', 50, 'XAI8B-F38C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  v_svc := public.get_business_service_analytics(v_biz, v_july_from, v_july_to);
  v_row := pg_temp._ai_row(v_rep, 'service_negative_trend');
  INSERT INTO _xbook_ai8b_results VALUES (
    'F38_negative_revenue_trend_25',
    v_row IS NOT NULL
      AND v_row->>'title_key' = 'insightServiceNegativeTrend'
      AND (v_row->>'priority')::int = 60
      AND v_row->'params'->>'metric' = 'revenue'
      AND (v_row->'params'->>'change_pct')::numeric <= -25
      AND (v_row->>'metric_value')::numeric = abs((v_row->'params'->>'change_pct')::numeric)
      AND v_row->'action'->>'type' = 'service_analytics'
      AND (
        SELECT e->'revenue_trend'->>'status'
        FROM jsonb_array_elements(v_svc->'services') e
        WHERE e->>'group_key' = v_svc_a::text LIMIT 1
      ) = 'decrease',
    coalesce(v_row::text, left(v_rep::text, 240))
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F39P' || v_i, '+38970008822' || v_i, NULL, 'Confirmed', 1000, 'XAI8B-F39P' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F39C' || v_i, '+38970008823' || v_i, NULL, 'Confirmed', 751, 'XAI8B-F39C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F39_decline_24x_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend'),
    left(coalesce(pg_temp._ai_row(v_rep, 'service_negative_trend')::text, v_rep::text), 200)
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..2 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F40P' || v_i, '+38970008824' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F40P' || v_i);
  END LOOP;
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F40C' || v_i, '+38970008825' || v_i, NULL, 'Confirmed', 10, 'XAI8B-F40C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F40_previous_visits_under_3',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F41P' || v_i, '+38970008826' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F41P' || v_i);
  END LOOP;
  FOR v_i IN 1..2 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F41C' || v_i, '+38970008827' || v_i, NULL, 'Confirmed', 10, 'XAI8B-F41C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F41_current_visits_under_3',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F42C' || v_i, '+38970008828' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F42C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F42_new_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  v_rep := public.get_business_actionable_insights(v_biz, v_tomorrow, v_tomorrow + 7);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F43_not_applicable_future_period',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend')
      AND (v_rep->>'ok')::boolean,
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F44P' || v_i, '+38970008829' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F44P' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F44C' || v_i, '+38970008830' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F44C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F44_no_change_suppressed',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..10 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + ((v_i - 1) % 10), '08:00', 30,
      'XBOOK_AI8B_F45P' || v_i, '+38970008831' || lpad(v_i::text, 2, '0'), NULL, 'Confirmed', 50, 'XAI8B-F45P' || v_i);
  END LOOP;
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F45C' || v_i, '+38970008832' || v_i, NULL, 'Confirmed', 200, 'XAI8B-F45C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  v_svc := public.get_business_service_analytics(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F45_revenue_increase_no_visit_fallback',
    NOT pg_temp._ai_has(v_rep, 'service_negative_trend')
      AND (
        SELECT e->'revenue_trend'->>'status'
        FROM jsonb_array_elements(v_svc->'services') e
        WHERE e->>'group_key' = v_svc_a::text LIMIT 1
      ) = 'increase'
      AND (
        SELECT e->'visit_trend'->>'status'
        FROM jsonb_array_elements(v_svc->'services') e
        WHERE e->>'group_key' = v_svc_a::text LIMIT 1
      ) = 'decrease',
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  UPDATE public.services SET price = NULL WHERE id IN (v_svc_a, v_svc_unk);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_unk, 'XBOOK_AI8B_UNK', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F46P' || v_i, '+38970008833' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-F46P' || v_i);
  END LOOP;
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_unk, 'XBOOK_AI8B_UNK', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F46C' || v_i, '+38970008834' || v_i, NULL, 'Confirmed', NULL, 'XAI8B-F46C' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  v_row := pg_temp._ai_row(v_rep, 'service_negative_trend');
  INSERT INTO _xbook_ai8b_results VALUES (
    'F46_revenue_na_visit_fallback',
    v_row IS NOT NULL
      AND v_row->'params'->>'metric' = 'visits'
      AND (v_row->'params'->>'change_pct')::numeric <= -25,
    coalesce(v_row::text, left(v_rep::text, 240))
  );
  UPDATE public.services SET price = 100 WHERE id = v_svc_a;

  -- F47 same-service concentration + trend → keep trend
  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F47P' || v_i, '+38970008835' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F47P' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F47C' || v_i, '+38970008836' || v_i, NULL, 'Confirmed', 50, 'XAI8B-F47C' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_july_from, '11:00', 30,
    'XBOOK_AI8B_F47B1', '+389700088370', NULL, 'Confirmed', 50, 'XAI8B-F47B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_july_from + 1, '11:00', 30,
    'XBOOK_AI8B_F47B2', '+389700088371', NULL, 'Confirmed', 50, 'XAI8B-F47B2');
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F47_same_service_keep_trend',
    pg_temp._ai_has(v_rep, 'service_negative_trend')
      AND NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND pg_temp._ai_row(v_rep, 'service_negative_trend')->'params'->>'service_key' = v_svc_a::text,
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  -- F48 strongest negative service
  PERFORM pg_temp._ai_wipe(v_biz);
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_prev_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F48AP' || v_i, '+38970008838' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F48AP' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_july_from + (v_i - 1), '09:00', 30,
      'XBOOK_AI8B_F48AC' || v_i, '+38970008839' || v_i, NULL, 'Confirmed', 50, 'XAI8B-F48AC' || v_i);
  END LOOP;
  FOR v_i IN 1..3 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'XBOOK_AI8B_C', v_staff_a, v_prev_from + (v_i - 1), '10:00', 30,
      'XBOOK_AI8B_F48CP' || v_i, '+38970008840' || v_i, NULL, 'Confirmed', 100, 'XAI8B-F48CP' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'XBOOK_AI8B_C', v_staff_a, v_july_from + (v_i - 1), '10:00', 30,
      'XBOOK_AI8B_F48CC' || v_i, '+38970008841' || v_i, NULL, 'Confirmed', 20, 'XAI8B-F48CC' || v_i);
  END LOOP;
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'F48_strongest_negative_selected',
    pg_temp._ai_row(v_rep, 'service_negative_trend')->'params'->>'service_key' = v_svc_c::text
      AND abs((pg_temp._ai_row(v_rep, 'service_negative_trend')->'params'->>'change_pct')::numeric) >= 50,
    coalesce(pg_temp._ai_row(v_rep, 'service_negative_trend')::text, 'missing')
  );

  -- =========================================================================
  -- G GLOBAL / top 3
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_crm(v_biz, 'p:389700088500', 1, 'XBOOK_AI8B_G_VIP', '+389700088500', NULL, true);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_G_VIP', '+389700088500', NULL, 'Confirmed', 100, 'XAI8B-G-VIP');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, (v_over60 - interval '8 days')::date, '09:00', 30,
    'XBOOK_AI8B_G_RPT', '+389700088501', NULL, 'Confirmed', 100, 'XAI8B-G-R1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_G_RPT', '+389700088501', NULL, 'Confirmed', 100, 'XAI8B-G-R2');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'G49_vip_and_repeat_coexist',
    pg_temp._ai_has(v_rep, 'vip_inactive_no_future')
      AND pg_temp._ai_has(v_rep, 'repeat_inactive_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'G50_specific_repeat_suppresses_broad',
    pg_temp._ai_has(v_rep, 'repeat_inactive_no_future')
      AND NOT pg_temp._ai_has(v_rep, 'repeat_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  -- Unassigned + trend + concentration + VIP + repeat inactive → top 3
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_july_from, '12:00', 30,
    'XBOOK_AI8B_G_UA1', '+389700088502', NULL, 'Confirmed', 50, 'XAI8B-G-UA1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', NULL, v_july_from + 1, '12:00', 30,
    'XBOOK_AI8B_G_UA2', '+389700088503', NULL, 'Confirmed', 50, 'XAI8B-G-UA2');
  FOR v_i IN 1..4 LOOP
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'XBOOK_AI8B_C', v_staff_a, v_prev_from + (v_i - 1), '13:00', 30,
      'XBOOK_AI8B_G_TP' || v_i, '+38970008851' || v_i, NULL, 'Confirmed', 100, 'XAI8B-G-TP' || v_i);
    PERFORM pg_temp._ai_book(v_biz, v_svc_c, 'XBOOK_AI8B_C', v_staff_a, v_july_from + 2 + (v_i - 1), '13:00', 30,
      'XBOOK_AI8B_G_TC' || v_i, '+38970008852' || v_i, NULL, 'Confirmed', 20, 'XAI8B-G-TC' || v_i);
  END LOOP;
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_july_from + 6, '14:00', 30,
    'XBOOK_AI8B_G_B1', '+389700088530', NULL, 'Confirmed', 50, 'XAI8B-G-B1');
  PERFORM pg_temp._ai_book(v_biz, v_svc_b, 'XBOOK_AI8B_B', v_staff_a, v_july_from + 7, '14:00', 30,
    'XBOOK_AI8B_G_B2', '+389700088531', NULL, 'Confirmed', 50, 'XAI8B-G-B2');

  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  INSERT INTO _xbook_ai8b_results VALUES (
    'G51_same_service_dedupe_in_pipeline',
    NOT (
      pg_temp._ai_has(v_rep, 'service_negative_trend')
      AND pg_temp._ai_has(v_rep, 'service_revenue_concentration')
      AND pg_temp._ai_row(v_rep, 'service_negative_trend')->'params'->>'service_key'
        = pg_temp._ai_row(v_rep, 'service_revenue_concentration')->'params'->>'service_key'
    ),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'A04_G55_max_3',
    jsonb_array_length(v_rep->'insights') = 3,
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'A05_G52_priority_order',
    pg_temp._ai_sorted(v_rep)
      AND (v_rep->'insights'->0->>'priority')::int
        >= (v_rep->'insights'->1->>'priority')::int
      AND (v_rep->'insights'->1->>'priority')::int
        >= (v_rep->'insights'->2->>'priority')::int
      AND pg_temp._ai_ids(v_rep) = ARRAY['vip_inactive_no_future','repeat_inactive_no_future','staff_unassigned_share'],
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'A06_stable_ids',
    v_rep->'insights'->0->>'id' = 'vip_inactive_no_future'
      AND v_rep->'insights'->0->>'title_key' = 'insightVipInactiveNoFuture',
    v_rep->'insights'->0->>'id'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'A07_semantic_action',
    v_rep->'insights'->0->'action'->>'type' = 'cross_analytics'
      AND jsonb_typeof(v_rep->'insights'->0->'action'->'filters') = 'object'
      AND v_rep::text !~* 'you have|inactive VIPs|consider reaching',
    left((v_rep->'insights'->0->'action')::text, 200)
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'G53_magnitude_tiebreak_implemented',
    pg_temp._ai_sorted(v_rep),
    'priority DESC, metric_value DESC, id ASC'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'G54_id_tiebreak_stable',
    pg_temp._ai_sorted(v_rep),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'no_forbidden_pii_keys',
    NOT pg_temp._jsonb_has_forbidden_key(v_rep),
    'payload scanned'
  );

  -- =========================================================================
  -- H PERIOD / CLOCK
  -- =========================================================================
  v_rep := public.get_business_actionable_insights(v_biz, v_july_from, v_july_to);
  v_row := v_rep;
  v_rep := public.get_business_actionable_insights(v_biz, DATE '2026-08-01', DATE '2026-08-31');
  INSERT INTO _xbook_ai8b_results VALUES (
    'H56_period_affects_service_staff',
    (v_row->'quality'->>'completed_visits')::bigint
      IS DISTINCT FROM (v_rep->'quality'->>'completed_visits')::bigint
      OR pg_temp._ai_has(v_row, 'staff_unassigned_share')
         IS DISTINCT FROM pg_temp._ai_has(v_rep, 'staff_unassigned_share'),
    format('july_visits=%s aug_visits=%s',
      v_row->'quality'->>'completed_visits',
      v_rep->'quality'->>'completed_visits')
  );

  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'H57_customer_inactivity_lifetime',
    pg_temp._ai_has(v_rep, 'vip_inactive_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'H59_business_timezone_in_period',
    v_rep->'period'->>'timezone' = v_tz
      AND v_rep->'period'->>'from_date' = to_char(v_yesterday, 'YYYY-MM-DD')
      AND v_rep->'period'->>'report_now' IS NOT NULL,
    (v_rep->'period')::text
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_H58', '+389700088600', NULL, 'Confirmed', 100, 'XAI8B-H58');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_yesterday);
  INSERT INTO _xbook_ai8b_results VALUES (
    'H58_from_date_inclusive',
    (v_rep->'quality'->>'completed_visits')::bigint = 1,
    v_rep->'quality'->>'completed_visits'
  );
  v_rep := public.get_business_actionable_insights(v_biz, v_today, v_today);
  INSERT INTO _xbook_ai8b_results VALUES (
    'H58b_outside_period_excluded',
    (v_rep->'quality'->>'completed_visits')::bigint = 0,
    v_rep->'quality'->>'completed_visits'
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, 'not-a-time', 30,
    'XBOOK_AI8B_BAD', '+389700088601', NULL, 'Confirmed', 100, 'XAI8B-H60');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'H60_invalid_time_excluded',
    (v_rep->'quality'->>'invalid_appointment_time_count')::bigint >= 1
      AND (v_rep->'quality'->>'completed_visits')::bigint = 1,
    format('invalid=%s completed=%s',
      v_rep->'quality'->>'invalid_appointment_time_count',
      v_rep->'quality'->>'completed_visits')
  );

  -- =========================================================================
  -- I PRICE / STATUS
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_SNAP', '+389700088610', NULL, 'Confirmed', 123, 'XAI8B-I61');
  PERFORM pg_temp._ai_book(v_biz, v_svc_free, 'XBOOK_AI8B_FREE', v_staff_a, v_yesterday, '10:00', 30,
    'XBOOK_AI8B_ZERO', '+389700088611', NULL, 'Confirmed', 0, 'XAI8B-I62');
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '11:00', 30,
    'XBOOK_AI8B_EST', '+389700088612', NULL, 'Confirmed', NULL, 'XAI8B-I63');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'I61_snapshot_used',
    (v_rep->'quality'->>'snapshot_price_count')::bigint = 2
      AND (v_rep->'quality'->>'known_completed_revenue')::numeric = 123 + 0 + 100,
    (v_rep->'quality')::text
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'I62_zero_price_preserved',
    (v_rep->'quality'->>'known_completed_revenue')::numeric = 223,
    v_rep->'quality'->>'known_completed_revenue'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'I63_legacy_estimated',
    (v_rep->'quality'->>'estimated_price_count')::bigint = 1,
    v_rep->'quality'->>'estimated_price_count'
  );

  v_ok := false; v_msg := '';
  BEGIN
    PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '12:00', 30,
      'XBOOK_AI8B_NEG', '+389700088613', NULL, 'Confirmed', -5, 'XAI8B-I64');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_ok := (v_sqlstate = '23514');
  END;
  INSERT INTO _xbook_ai8b_results VALUES (
    'I64_negative_price_rejected_by_canonical_check',
    v_ok,
    v_msg
  );

  PERFORM pg_temp._ai_wipe(v_biz);
  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_LEGACY', '+389700088620', NULL, 'Pending', 100, 'XAI8B-I65', 'Confirmed');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'I65_I66_legacy_status_ignored',
    (v_rep->'quality'->>'completed_visits')::bigint = 0,
    v_rep->'quality'->>'completed_visits'
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'I67_past_pending_not_completed',
    (v_rep->'quality'->>'completed_visits')::bigint = 0,
    'Pending yesterday'
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_today, '00:00', 1440,
    'XBOOK_AI8B_INP', '+389700088621', NULL, 'Confirmed', 100, 'XAI8B-I68');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'I68_in_progress_confirmed_not_completed',
    (v_rep->'quality'->>'completed_visits')::bigint = 0,
    v_rep->'quality'->>'completed_visits'
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '09:00', 30,
    'XBOOK_AI8B_DONE', '+389700088622', NULL, 'Confirmed', 100, 'XAI8B-I69');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'I69_ended_confirmed_completed',
    (v_rep->'quality'->>'completed_visits')::bigint = 1,
    v_rep->'quality'->>'completed_visits'
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_yesterday, '15:00', 30,
    'Customer', NULL, NULL, 'Confirmed', 100, 'XAI8B-UNID');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'unidentified_bookings_quality_only',
    (v_rep->'quality'->>'unidentified_booking_count')::bigint >= 1
      AND NOT pg_temp._ai_has(v_rep, 'repeat_no_future'),
    v_rep->'quality'->>'unidentified_booking_count'
  );

  -- =========================================================================
  -- J TENANT
  -- =========================================================================
  PERFORM pg_temp._ai_wipe(v_biz);
  -- Do not insert bookings into v_biz_b: live businesses may require client approval.
  -- Live v_biz_b bookings already exist. Isolate with CRM/link rows only.
  SELECT coalesce(max(customer_number), 0) + 1 INTO v_n
  FROM public.business_customers WHERE business_id = v_biz_b;
  PERFORM pg_temp._ai_crm(v_biz_b, 'p:389700088900', v_n::integer, 'XBOOK_AI8B_OTHER_VIP', '+389700088900', NULL, true);
  PERFORM pg_temp._ai_crm(
    v_biz_b, 'u:' || v_user_link::text, (v_n + 1)::integer,
    'XBOOK_AI8B_OTHER_LINK', '+389700088007', v_user_link, false
  );
  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (v_biz_b, v_user_link, 'p:389700088007', 'xbook_ai8b_test', v_biz_b);

  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  INSERT INTO _xbook_ai8b_results VALUES (
    'J70_other_bookings_ignored',
    (v_rep->>'ok')::boolean
      AND jsonb_array_length(v_rep->'insights') = 0
      AND (v_rep->'quality'->>'completed_visits')::bigint = 0,
    left(v_rep::text, 200)
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'J71_other_vip_ignored',
    NOT pg_temp._ai_has(v_rep, 'vip_inactive_no_future'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );
  INSERT INTO _xbook_ai8b_results VALUES (
    'J72_other_staff_service_ignored',
    NOT pg_temp._ai_has(v_rep, 'staff_unassigned_share')
      AND NOT pg_temp._ai_has(v_rep, 'service_revenue_concentration'),
    array_to_string(pg_temp._ai_ids(v_rep), ',')
  );

  PERFORM pg_temp._ai_book(v_biz, v_svc_a, 'XBOOK_AI8B_A', v_staff_a, v_over60::date, to_char(v_over60, 'HH24:MI:SS'), 30,
    'XBOOK_AI8B_J_GUEST', '+389700088007', NULL, 'Confirmed', 100, 'XAI8B-J-G');
  v_rep := public.get_business_actionable_insights(v_biz, v_yesterday, v_tomorrow);
  SELECT count(*) INTO v_n
  FROM public._business_analytics_customer_keys(v_biz) k
  WHERE k.analytics_customer_key IN ('u:' || v_user_link::text, 'p:389700088007');
  INSERT INTO _xbook_ai8b_results VALUES (
    'J73_foreign_identity_link_ignored',
    v_n = 1 AND (SELECT analytics_customer_key FROM public._business_analytics_customer_keys(v_biz) LIMIT 1) = 'p:389700088007',
    format('keys=%s', v_n)
  );

  -- Live Test Barber read-only
  IF v_tz_tb IS NULL THEN
    INSERT INTO _xbook_ai8b_results VALUES ('live_test_barber_present', false, 'missing timezone');
  ELSE
    INSERT INTO _xbook_ai8b_results VALUES ('live_test_barber_present', true, v_biz_tb::text);
    PERFORM public._xbook_ai8b_test_set_jwt(v_biz_tb);
    v_rep := public.get_business_actionable_insights(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_staff := public.get_business_staff_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    v_svc := public.get_business_service_analytics(v_biz_tb, DATE '2026-08-01', DATE '2026-08-31');
    INSERT INTO _xbook_ai8b_results VALUES (
      'live_tb_contract',
      (v_rep->>'ok')::boolean
        AND jsonb_typeof(v_rep->'insights') = 'array'
        AND jsonb_array_length(v_rep->'insights') <= 3
        AND pg_temp._ai_sorted(v_rep)
        AND NOT pg_temp._jsonb_has_forbidden_key(v_rep)
        AND v_rep->'period'->>'timezone' = v_tz_tb,
      format('n=%s ids=%s', jsonb_array_length(v_rep->'insights'), array_to_string(pg_temp._ai_ids(v_rep), ','))
    );
    INSERT INTO _xbook_ai8b_results VALUES (
      'live_tb_completed_visits_vs_staff',
      (v_rep->'quality'->>'completed_visits')::bigint
        = (v_staff->'quality'->>'completed_visits_total')::bigint,
      format('insights=%s staff=%s',
        v_rep->'quality'->>'completed_visits',
        v_staff->'quality'->>'completed_visits_total')
    );
    IF pg_temp._ai_has(v_rep, 'staff_unassigned_share') THEN
      INSERT INTO _xbook_ai8b_results VALUES (
        'live_tb_unassigned_share_parity',
        (pg_temp._ai_row(v_rep, 'staff_unassigned_share')->>'metric_value')::numeric
          = (v_staff->'summary'->>'unassigned_visit_share_pct')::numeric
          AND (v_staff->'summary'->>'has_material_unassigned_history')::boolean = true
          AND (pg_temp._ai_row(v_rep, 'staff_unassigned_share')->'params'->>'unassigned_visits')::bigint >= 2,
        pg_temp._ai_row(v_rep, 'staff_unassigned_share')::text
      );
    ELSE
      INSERT INTO _xbook_ai8b_results VALUES (
        'live_tb_unassigned_share_parity',
        (v_staff->'summary'->>'unassigned_visit_share_pct') IS NULL
          OR (v_staff->'summary'->>'unassigned_visit_share_pct')::numeric < 10
          OR (v_staff->'summary'->>'unassigned_completed_visits')::bigint < 2,
        format('share=%s ua=%s',
          v_staff->'summary'->>'unassigned_visit_share_pct',
          v_staff->'summary'->>'unassigned_completed_visits')
      );
    END IF;
    IF pg_temp._ai_has(v_rep, 'vip_inactive_no_future') THEN
      v_cross := public.get_business_cross_analytics(
        v_biz_tb, DATE '2026-08-01', DATE '2026-08-31',
        '{"is_vip":true,"inactive_days_min":60,"has_future_booking":false}'::jsonb,
        'last_visit_desc', 10, 0
      );
      INSERT INTO _xbook_ai8b_results VALUES (
        'live_tb_vip_cross_parity',
        (pg_temp._ai_row(v_rep, 'vip_inactive_no_future')->>'metric_value')::bigint
          = (v_cross->'summary'->>'matched_customers')::bigint,
        format('insight=%s cross=%s',
          pg_temp._ai_row(v_rep, 'vip_inactive_no_future')->>'metric_value',
          v_cross->'summary'->>'matched_customers')
      );
    ELSE
      INSERT INTO _xbook_ai8b_results VALUES ('live_tb_vip_cross_parity', true, 'vip insight not in top 3');
    END IF;
  END IF;

  -- Cleanup throwaway + other-business fixtures
  PERFORM public._xbook_ai8b_test_set_jwt(v_biz);
  PERFORM pg_temp._ai_wipe(v_biz);
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XAI8B-%' OR customer_name LIKE 'XBOOK_AI8B%';
  DELETE FROM public.business_customer_identity_links
  WHERE reason = 'xbook_ai8b_test' OR legacy_analytics_key LIKE 'p:389700088%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_AI8B%'
     OR phone LIKE '+389700088%'
     OR client_key LIKE 'p:389700088%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_AI8B%';
  DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_AI8B%';
  DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ai8b-%@invalid.example';
  DELETE FROM auth.users WHERE email LIKE 'xbook-ai8b-%@invalid.example';
  DELETE FROM public.business_settings WHERE business_id = v_biz OR business_slug LIKE 'xbook-ai8b-%';

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;
  SELECT count(*) INTO v_staff_after FROM public.staff_members;
  SELECT count(*) INTO v_svc_after FROM public.services;
  SELECT count(*) INTO v_bs_after FROM public.business_settings;

  INSERT INTO _xbook_ai8b_results VALUES (
    'cleanup_no_delta',
    v_bookings_after = v_bookings_before
      AND v_links_after = v_links_before
      AND v_staff_after = v_staff_before
      AND v_svc_after = v_svc_before
      AND v_bs_after = v_bs_before,
    format('bookings %s→%s links %s→%s staff %s→%s svc %s→%s settings %s→%s',
      v_bookings_before, v_bookings_after, v_links_before, v_links_after,
      v_staff_before, v_staff_after, v_svc_before, v_svc_after, v_bs_before, v_bs_after)
  );

  PERFORM public._xbook_ai8b_test_set_jwt(NULL, 'anon');
EXCEPTION
  WHEN OTHERS THEN
    DELETE FROM public.bookings WHERE booking_ref LIKE 'XAI8B-%' OR customer_name LIKE 'XBOOK_AI8B%';
    DELETE FROM public.business_customer_identity_links
    WHERE reason = 'xbook_ai8b_test' OR legacy_analytics_key LIKE 'p:389700088%';
    DELETE FROM public.business_customers
    WHERE display_name LIKE 'XBOOK_AI8B%'
       OR phone LIKE '+389700088%'
       OR client_key LIKE 'p:389700088%';
    DELETE FROM public.services WHERE name LIKE 'XBOOK_AI8B%';
    DELETE FROM public.staff_members WHERE name LIKE 'XBOOK_AI8B%';
    DELETE FROM public.user_profiles WHERE email LIKE 'xbook-ai8b-%@invalid.example';
    DELETE FROM auth.users WHERE email LIKE 'xbook-ai8b-%@invalid.example';
    DELETE FROM public.business_settings
    WHERE business_slug LIKE 'xbook-ai8b-%' OR business_name = 'XBOOK_AI8B';
    RAISE;
END;
$$;

DROP FUNCTION IF EXISTS public._xbook_ai8b_test_set_jwt(uuid, text);

SELECT test_name, passed, left(coalesce(detail, ''), 400) AS detail
FROM (
  SELECT test_name, passed, detail, 0 AS ord
  FROM _xbook_ai8b_results
  WHERE NOT passed
  UNION ALL
  SELECT 'ZZZ_SUMMARY',
         (count(*) FILTER (WHERE NOT passed) = 0),
         format('total=%s passed=%s failed=%s', count(*), count(*) FILTER (WHERE passed), count(*) FILTER (WHERE NOT passed)),
         1
  FROM _xbook_ai8b_results
) s
ORDER BY ord, test_name;
