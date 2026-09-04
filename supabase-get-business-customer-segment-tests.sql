-- Phase 2C Customer Segment drill-down contract tests.
-- Throwaway rows, then deleted. Safe to re-run.
-- Do not treat SQL detail columns as a product report: they may contain keys.

CREATE TEMP TABLE IF NOT EXISTS _xbook_seg_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_seg_results;

CREATE OR REPLACE FUNCTION pg_temp._seg_customer(p_payload jsonb, p_key text)
RETURNS jsonb
LANGUAGE sql
AS $$
  SELECT c
  FROM jsonb_array_elements(coalesce(p_payload->'customers', '[]'::jsonb)) c
  WHERE c->>'analytics_customer_key' = p_key
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
  v_from date;
  v_to date;
  v_local_now timestamp;
  v_yesterday date;
  v_tomorrow date;
  v_before_from date;
  v_risk_45 date;
  v_risk_75 date;
  v_risk_120 date;
  v_svc uuid;
  v_staff uuid;
  v_ov jsonb;
  v_active jsonb;
  v_new jsonb;
  v_ret jsonb;
  v_repeat jsonb;
  v_single jsonb;
  v_r30 jsonb;
  v_r60 jsonb;
  v_r90 jsonb;
  v_ahead jsonb;
  v_g_male jsonb;
  v_g_female jsonb;
  v_g_unknown jsonb;
  v_age jsonb;
  v_city jsonb;
  v_page1 jsonb;
  v_page2 jsonb;
  v_cap jsonb;
  v_snapshot jsonb;
  v_estimated jsonb;
  v_auth_row jsonb;
  v_guest_row jsonb;
  v_email_guest jsonb;
  v_name_a jsonb;
  v_name_b jsonb;
  v_profile_user uuid;
  v_profile_gender text;
  v_city_id text;
  v_city_count bigint;
  v_age_filter text;
  v_age_count bigint;
  v_cross_ok boolean := false;
  v_cross_msg text := '';
  v_invalid_ok boolean := false;
  v_filter_ok boolean := false;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_key_new text;
  v_key_ret text;
  v_key_guest_dup text;
  v_key_snap text;
  v_key_est text;
  v_key_email_guest text;
  v_key_name_a text;
  v_key_name_b text;
  v_key_auth text;
  v_keys text[];
  v_live_city jsonb;
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
    RAISE EXCEPTION 'Need two businesses for Customer Segment tests';
  END IF;

  SELECT sm.id
  INTO v_staff
  FROM public.staff_members sm
  WHERE sm.business_id = v_biz_a
  ORDER BY sm.id
  LIMIT 1;

  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'Need a staff member on the busiest business for booking inserts';
  END IF;

  v_local_now := now() AT TIME ZONE v_tz;
  v_yesterday := v_local_now::date - 1;
  v_tomorrow := v_local_now::date + 1;
  v_from := v_yesterday;
  v_to := v_tomorrow;
  v_before_from := v_from - 20;
  v_risk_45 := (v_local_now - interval '45 days')::date;
  v_risk_75 := (v_local_now - interval '75 days')::date;
  v_risk_120 := (v_local_now - interval '120 days')::date;

  SELECT count(*) INTO v_bookings_before FROM public.bookings;

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XSEG-%' OR customer_name LIKE 'XBOOK_SEG_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_SEG_TEST%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_SEG_%'
     OR phone LIKE '+389700088%'
     OR client_key LIKE 'p:389700088%'
     OR client_key LIKE 'e:xseg-%'
     OR client_key LIKE 'n:xbook_seg_%';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_a, 'XBOOK_SEG_TEST_SVC', 30, 700)
  RETURNING id INTO v_svc;

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

  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_email, customer_user_id,
    booking_status, booking_price, booking_ref, manage_token
  ) VALUES
  -- New (period first visit)
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SEG_NEW', '+389700088001', NULL, NULL, 'Confirmed', 100, 'XSEG-NEW', gen_random_uuid()::text),
  -- Returning: visit before period
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_before_from, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SEG_RET', '+389700088002', NULL, NULL, 'Confirmed', 200, 'XSEG-RET0', gen_random_uuid()::text),
  -- Returning: visit in period (lifetime 2 → also repeat)
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_SEG_RET', '+389700088002', NULL, NULL, 'Confirmed', 200, 'XSEG-RET1', gen_random_uuid()::text),
  -- Guest identity dedupe: two completed visits, same phone
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:00', 30,
   'XBOOK_SEG_GDUP', '+389700088020', NULL, NULL, 'Confirmed', 40, 'XSEG-GD1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '11:30', 30,
   'XBOOK_SEG_GDUP', '+389700088020', NULL, NULL, 'Confirmed', 60, 'XSEG-GD2', gen_random_uuid()::text),
  -- Snapshot price 150 vs catalog 700
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '12:00', 30,
   'XBOOK_SEG_SNAP', '+389700088030', NULL, NULL, 'Confirmed', 150, 'XSEG-SNAP', gen_random_uuid()::text),
  -- Estimated legacy (NULL snapshot)
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '12:30', 30,
   'XBOOK_SEG_EST', '+389700088031', NULL, NULL, 'Confirmed', NULL, 'XSEG-EST', gen_random_uuid()::text),
  -- At risk 30-59
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_risk_45, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SEG_R45', '+389700088045', NULL, NULL, 'Confirmed', 10, 'XSEG-R45', gen_random_uuid()::text),
  -- At risk 60-89
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_risk_75, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SEG_R75', '+389700088075', NULL, NULL, 'Confirmed', 10, 'XSEG-R75', gen_random_uuid()::text),
  -- At risk 90+
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_risk_120, 'YYYY-MM-DD'), '09:00', 30,
   'XBOOK_SEG_R120', '+389700088120', NULL, NULL, 'Confirmed', 10, 'XSEG-R120', gen_random_uuid()::text),
  -- Booked ahead: old completed + future confirmed
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_risk_120, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_SEG_AHEAD', '+389700088200', NULL, NULL, 'Confirmed', 10, 'XSEG-AH0', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_tomorrow, 'YYYY-MM-DD'), '10:00', 30,
   'XBOOK_SEG_AHEAD', '+389700088200', NULL, NULL, 'Confirmed', 10, 'XSEG-AH1', gen_random_uuid()::text),
  -- Similar names, name-only identity (must not fuzzy-merge)
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '13:00', 30,
   'XBOOK_SEG_MARIA PETROVA', NULL, NULL, NULL, 'Confirmed', 15, 'XSEG-NA', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '13:15', 30,
   'XBOOK_SEG_MARIA P', NULL, NULL, NULL, 'Confirmed', 15, 'XSEG-NB', gen_random_uuid()::text),
  -- Pagination extras (unique new guests)
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '14:00', 30,
   'XBOOK_SEG_P1', '+389700088301', NULL, NULL, 'Confirmed', 11, 'XSEG-P1', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '14:15', 30,
   'XBOOK_SEG_P2', '+389700088302', NULL, NULL, 'Confirmed', 12, 'XSEG-P2', gen_random_uuid()::text),
  (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '14:30', 30,
   'XBOOK_SEG_P3', '+389700088303', NULL, NULL, 'Confirmed', 13, 'XSEG-P3', gen_random_uuid()::text);

  -- Auth identity dedupe: two phones, same user
  IF v_profile_user IS NOT NULL THEN
    INSERT INTO public.bookings (
      business_id, service_id, service_name, staff_id, date, time, duration_minutes,
      customer_name, customer_phone, customer_email, customer_user_id,
      booking_status, booking_price, booking_ref, manage_token
    ) VALUES
    (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '15:00', 30,
     'XBOOK_SEG_AUTH', '+389700088010', 'xseg-auth-guest@example.test', v_profile_user,
     'Confirmed', 80, 'XSEG-AU1', gen_random_uuid()::text),
    (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '15:30', 30,
     'XBOOK_SEG_AUTH', '+389700088011', 'xseg-auth-guest@example.test', v_profile_user,
     'Confirmed', 80, 'XSEG-AU2', gen_random_uuid()::text),
    -- Guest with same email, no auth id — must stay a separate identity
    (v_biz_a, v_svc, 'XBOOK_SEG_TEST_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '16:00', 30,
     'XBOOK_SEG_EMAILGUEST', NULL, 'xseg-auth-guest@example.test', NULL,
     'Confirmed', 25, 'XSEG-EG', gen_random_uuid()::text);
  END IF;

  v_ov := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  v_active := public.get_business_customer_segment(v_biz_a, 'active', v_from, v_to, NULL, 100, 0);
  v_new := public.get_business_customer_segment(v_biz_a, 'new', v_from, v_to, NULL, 100, 0);
  v_ret := public.get_business_customer_segment(v_biz_a, 'returning', v_from, v_to, NULL, 100, 0);
  v_repeat := public.get_business_customer_segment(v_biz_a, 'repeat', v_from, v_to, NULL, 100, 0);
  v_single := public.get_business_customer_segment(v_biz_a, 'single_visit', v_from, v_to, NULL, 100, 0);
  v_r30 := public.get_business_customer_segment(v_biz_a, 'at_risk_30_59', v_from, v_to, NULL, 100, 0);
  v_r60 := public.get_business_customer_segment(v_biz_a, 'at_risk_60_89', v_from, v_to, NULL, 100, 0);
  v_r90 := public.get_business_customer_segment(v_biz_a, 'at_risk_90_plus', v_from, v_to, NULL, 100, 0);
  v_ahead := public.get_business_customer_segment(v_biz_a, 'booked_ahead', v_from, v_to, NULL, 100, 0);
  v_g_male := public.get_business_customer_segment(v_biz_a, 'gender', v_from, v_to, 'male', 100, 0);
  v_g_female := public.get_business_customer_segment(v_biz_a, 'gender', v_from, v_to, 'female', 100, 0);
  v_g_unknown := public.get_business_customer_segment(v_biz_a, 'gender', v_from, v_to, 'unknown', 100, 0);

  v_key_new := public._analytics_customer_key(NULL, '+389700088001', NULL, 'XBOOK_SEG_NEW');
  v_key_ret := public._analytics_customer_key(NULL, '+389700088002', NULL, 'XBOOK_SEG_RET');
  v_key_guest_dup := public._analytics_customer_key(NULL, '+389700088020', NULL, 'XBOOK_SEG_GDUP');
  v_key_snap := public._analytics_customer_key(NULL, '+389700088030', NULL, 'XBOOK_SEG_SNAP');
  v_key_est := public._analytics_customer_key(NULL, '+389700088031', NULL, 'XBOOK_SEG_EST');
  v_key_name_a := public._analytics_customer_key(NULL, NULL, NULL, 'XBOOK_SEG_MARIA PETROVA');
  v_key_name_b := public._analytics_customer_key(NULL, NULL, NULL, 'XBOOK_SEG_MARIA P');
  v_key_email_guest := public._analytics_customer_key(NULL, NULL, 'xseg-auth-guest@example.test', 'XBOOK_SEG_EMAILGUEST');
  IF v_profile_user IS NOT NULL THEN
    v_key_auth := 'u:' || v_profile_user::text;
  END IF;

  v_snapshot := pg_temp._seg_customer(v_active, v_key_snap);
  v_estimated := pg_temp._seg_customer(v_active, v_key_est);
  v_guest_row := pg_temp._seg_customer(v_active, v_key_guest_dup);
  v_name_a := pg_temp._seg_customer(v_active, v_key_name_a);
  v_name_b := pg_temp._seg_customer(v_active, v_key_name_b);
  v_auth_row := pg_temp._seg_customer(v_active, v_key_auth);
  v_email_guest := pg_temp._seg_customer(v_active, v_key_email_guest);

  INSERT INTO _xbook_seg_results VALUES
  (
    'A_active_parity',
    (v_active->'summary'->>'total_count')::bigint = (v_ov->'overview'->>'active_customers')::bigint
      AND pg_temp._seg_customer(v_active, v_key_new) IS NOT NULL
      AND pg_temp._seg_customer(v_active, v_key_ret) IS NOT NULL,
    format('seg=%s ov=%s', v_active->'summary'->>'total_count', v_ov->'overview'->>'active_customers')
  ),
  (
    'B_new_parity',
    (v_new->'summary'->>'total_count')::bigint = (v_ov->'overview'->>'new_customers')::bigint
      AND pg_temp._seg_customer(v_new, v_key_new) IS NOT NULL
      AND pg_temp._seg_customer(v_new, v_key_ret) IS NULL,
    format('seg=%s ov=%s', v_new->'summary'->>'total_count', v_ov->'overview'->>'new_customers')
  ),
  (
    'C_returning_parity',
    (v_ret->'summary'->>'total_count')::bigint = (v_ov->'overview'->>'returning_customers')::bigint
      AND pg_temp._seg_customer(v_ret, v_key_ret) IS NOT NULL
      AND pg_temp._seg_customer(v_ret, v_key_new) IS NULL,
    format('seg=%s ov=%s', v_ret->'summary'->>'total_count', v_ov->'overview'->>'returning_customers')
  ),
  (
    'D_repeat_parity',
    (v_repeat->'summary'->>'total_count')::bigint = (v_ov->'overview'->>'repeat_customers')::bigint
      AND pg_temp._seg_customer(v_repeat, v_key_ret) IS NOT NULL
      AND pg_temp._seg_customer(v_repeat, v_key_guest_dup) IS NOT NULL,
    format('seg=%s ov=%s', v_repeat->'summary'->>'total_count', v_ov->'overview'->>'repeat_customers')
  ),
  (
    'E_single_visit',
    (v_single->'summary'->>'total_count')::bigint = (v_ov->'frequency'->>'visits_1')::bigint
      AND pg_temp._seg_customer(v_single, v_key_new) IS NOT NULL
      AND pg_temp._seg_customer(v_single, v_key_ret) IS NULL,
    format('seg=%s ov=%s', v_single->'summary'->>'total_count', v_ov->'frequency'->>'visits_1')
  ),
  (
    'F_at_risk_30_59',
    (v_r30->'summary'->>'total_count')::bigint = (v_ov->'inactivity'->>'at_risk_30_to_59')::bigint
      AND pg_temp._seg_customer(v_r30, public._analytics_customer_key(NULL, '+389700088045', NULL, 'XBOOK_SEG_R45')) IS NOT NULL,
    format('seg=%s ov=%s', v_r30->'summary'->>'total_count', v_ov->'inactivity'->>'at_risk_30_to_59')
  ),
  (
    'G_at_risk_60_89',
    (v_r60->'summary'->>'total_count')::bigint = (v_ov->'inactivity'->>'at_risk_60_to_89')::bigint
      AND pg_temp._seg_customer(v_r60, public._analytics_customer_key(NULL, '+389700088075', NULL, 'XBOOK_SEG_R75')) IS NOT NULL,
    format('seg=%s ov=%s', v_r60->'summary'->>'total_count', v_ov->'inactivity'->>'at_risk_60_to_89')
  ),
  (
    'H_at_risk_90_plus',
    (v_r90->'summary'->>'total_count')::bigint = (v_ov->'inactivity'->>'at_risk_90_plus')::bigint
      AND pg_temp._seg_customer(v_r90, public._analytics_customer_key(NULL, '+389700088120', NULL, 'XBOOK_SEG_R120')) IS NOT NULL
      AND pg_temp._seg_customer(v_r90, public._analytics_customer_key(NULL, '+389700088200', NULL, 'XBOOK_SEG_AHEAD')) IS NULL,
    format('seg=%s ov=%s', v_r90->'summary'->>'total_count', v_ov->'inactivity'->>'at_risk_90_plus')
  ),
  (
    'I_booked_ahead',
    (v_ahead->'summary'->>'total_count')::bigint = (v_ov->'inactivity'->>'booked_ahead_customers')::bigint
      AND pg_temp._seg_customer(v_ahead, public._analytics_customer_key(NULL, '+389700088200', NULL, 'XBOOK_SEG_AHEAD')) IS NOT NULL
      AND (pg_temp._seg_customer(v_ahead, public._analytics_customer_key(NULL, '+389700088200', NULL, 'XBOOK_SEG_AHEAD'))->>'has_upcoming_appointment')::boolean = true,
    format('seg=%s ov=%s', v_ahead->'summary'->>'total_count', v_ov->'inactivity'->>'booked_ahead_customers')
  ),
  (
    'J_gender_known',
    (v_g_male->'summary'->>'total_count')::bigint = (v_ov->'demographics'->'gender'->>'male')::bigint
      AND (v_g_female->'summary'->>'total_count')::bigint = (v_ov->'demographics'->'gender'->>'female')::bigint,
    format('male seg=%s ov=%s female seg=%s ov=%s profile=%s',
      v_g_male->'summary'->>'total_count', v_ov->'demographics'->'gender'->>'male',
      v_g_female->'summary'->>'total_count', v_ov->'demographics'->'gender'->>'female',
      (v_profile_user IS NOT NULL))
  ),
  (
    'K_gender_unknown',
    (v_g_unknown->'summary'->>'total_count')::bigint = (v_ov->'demographics'->'gender'->>'unknown')::bigint
      AND (v_g_male->'summary'->>'total_count')::bigint
        + (v_g_female->'summary'->>'total_count')::bigint
        + (v_g_unknown->'summary'->>'total_count')::bigint
        = (v_ov->'demographics'->'gender'->>'population_total')::bigint
      AND pg_temp._seg_customer(v_g_unknown, v_key_new) IS NOT NULL,
    format('unknown seg=%s ov=%s', v_g_unknown->'summary'->>'total_count', v_ov->'demographics'->'gender'->>'unknown')
  );

  -- Age bucket: unknown always; first non-zero known bucket if present
  v_age := public.get_business_customer_segment(v_biz_a, 'age_bucket', v_from, v_to, 'unknown', 100, 0);
  v_age_filter := NULL;
  v_age_count := 0;
  IF (v_ov->'demographics'->'age'->>'under_18')::bigint > 0 THEN
    v_age_filter := 'under_18'; v_age_count := (v_ov->'demographics'->'age'->>'under_18')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_18_24')::bigint > 0 THEN
    v_age_filter := '18_24'; v_age_count := (v_ov->'demographics'->'age'->>'age_18_24')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_25_34')::bigint > 0 THEN
    v_age_filter := '25_34'; v_age_count := (v_ov->'demographics'->'age'->>'age_25_34')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_35_44')::bigint > 0 THEN
    v_age_filter := '35_44'; v_age_count := (v_ov->'demographics'->'age'->>'age_35_44')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_45_54')::bigint > 0 THEN
    v_age_filter := '45_54'; v_age_count := (v_ov->'demographics'->'age'->>'age_45_54')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_55_64')::bigint > 0 THEN
    v_age_filter := '55_64'; v_age_count := (v_ov->'demographics'->'age'->>'age_55_64')::bigint;
  ELSIF (v_ov->'demographics'->'age'->>'age_65_plus')::bigint > 0 THEN
    v_age_filter := '65_plus'; v_age_count := (v_ov->'demographics'->'age'->>'age_65_plus')::bigint;
  END IF;

  INSERT INTO _xbook_seg_results VALUES
  (
    'L_age_bucket',
    (v_age->'summary'->>'total_count')::bigint = (v_ov->'demographics'->'age'->>'unknown')::bigint
      AND (
        v_age_filter IS NULL
        OR (
          public.get_business_customer_segment(v_biz_a, 'age_bucket', v_from, v_to, v_age_filter, 100, 0)
            ->'summary'->>'total_count'
        )::bigint = v_age_count
      ),
    format('unknown seg=%s ov=%s known_filter=%s',
      v_age->'summary'->>'total_count', v_ov->'demographics'->'age'->>'unknown', v_age_filter)
  );

  v_city := public.get_business_customer_segment(v_biz_a, 'city', v_from, v_to, 'unknown', 100, 0);
  v_live_city := (v_ov->'demographics'->'cities'->'groups')->0;
  v_city_id := v_live_city->>'city_id';
  v_city_count := coalesce((v_live_city->>'count')::bigint, 0);

  INSERT INTO _xbook_seg_results VALUES
  (
    'M_city_filter',
    (v_city->'summary'->>'total_count')::bigint = (v_ov->'demographics'->'cities'->>'unknown_count')::bigint
      AND (
        v_city_id IS NULL
        OR (
          public.get_business_customer_segment(v_biz_a, 'city', v_from, v_to, v_city_id, 100, 0)
            ->'summary'->>'total_count'
        )::bigint = v_city_count
      ),
    format('unknown seg=%s ov=%s known_city=%s',
      v_city->'summary'->>'total_count',
      v_ov->'demographics'->'cities'->>'unknown_count',
      (v_city_id IS NOT NULL))
  ),
  (
    'N_auth_identity_dedupe',
    CASE
      WHEN v_profile_user IS NULL THEN false
      ELSE
        v_auth_row IS NOT NULL
        AND (v_auth_row->>'identity_type') = 'auth'
        AND (v_auth_row->>'completed_visits_period')::bigint >= 2
        AND (
          SELECT count(*)
          FROM jsonb_array_elements(v_active->'customers') c
          WHERE c->>'analytics_customer_key' = v_key_auth
        ) = 1
    END,
    format('profile=%s found=%s visits=%s',
      (v_profile_user IS NOT NULL),
      (v_auth_row IS NOT NULL),
      v_auth_row->>'completed_visits_period')
  ),
  (
    'O_guest_identity_dedupe',
    v_guest_row IS NOT NULL
      AND (v_guest_row->>'identity_type') = 'guest'
      AND (v_guest_row->>'completed_visits_period')::bigint = 2
      AND (v_guest_row->>'completed_visits_lifetime')::bigint = 2
      AND (
        SELECT count(*)
        FROM jsonb_array_elements(v_active->'customers') c
        WHERE c->>'analytics_customer_key' = v_key_guest_dup
      ) = 1,
    format('found=%s visits=%s', (v_guest_row IS NOT NULL), v_guest_row->>'completed_visits_period')
  ),
  (
    'P_auth_guest_not_merged',
    CASE
      WHEN v_profile_user IS NULL THEN false
      ELSE
        v_auth_row IS NOT NULL
        AND v_email_guest IS NOT NULL
        AND (v_auth_row->>'analytics_customer_key') IS DISTINCT FROM (v_email_guest->>'analytics_customer_key')
        AND (v_auth_row->>'identity_type') = 'auth'
        AND (v_email_guest->>'identity_type') = 'guest'
        AND v_key_name_a IS DISTINCT FROM v_key_name_b
        AND v_name_a IS NOT NULL
        AND v_name_b IS NOT NULL
    END,
    format('profile=%s auth_found=%s guest_found=%s names_distinct=%s',
      (v_profile_user IS NOT NULL),
      (v_auth_row IS NOT NULL),
      (v_email_guest IS NOT NULL),
      (v_key_name_a IS DISTINCT FROM v_key_name_b))
  ),
  (
    'Q_revenue_snapshot',
    v_snapshot IS NOT NULL
      AND (v_snapshot->>'completed_revenue_period')::numeric = 150
      AND (v_snapshot->>'revenue_is_estimated')::boolean = false,
    format('found=%s period_rev=%s estimated=%s',
      (v_snapshot IS NOT NULL),
      v_snapshot->>'completed_revenue_period',
      v_snapshot->>'revenue_is_estimated')
  ),
  (
    'R_revenue_estimated_legacy',
    v_estimated IS NOT NULL
      AND (v_estimated->>'completed_revenue_period')::numeric = 700
      AND (v_estimated->>'revenue_is_estimated')::boolean = true
      AND (v_active->'summary'->>'contains_estimated_prices')::boolean = true,
    format('found=%s period_rev=%s estimated=%s summary_flag=%s',
      (v_estimated IS NOT NULL),
      v_estimated->>'completed_revenue_period',
      v_estimated->>'revenue_is_estimated',
      v_active->'summary'->>'contains_estimated_prices')
  );

  v_page1 := public.get_business_customer_segment(v_biz_a, 'new', v_from, v_to, NULL, 2, 0);
  v_page2 := public.get_business_customer_segment(v_biz_a, 'new', v_from, v_to, NULL, 2, 2);
  v_cap := public.get_business_customer_segment(v_biz_a, 'new', v_from, v_to, NULL, 500, 0);

  INSERT INTO _xbook_seg_results VALUES
  (
    'S_pagination',
    (v_page1->'pagination'->>'limit')::int = 2
      AND (v_page1->'pagination'->>'offset')::int = 0
      AND jsonb_array_length(v_page1->'customers') = 2
      AND (v_page1->'summary'->>'total_count')::bigint = (v_new->'summary'->>'total_count')::bigint
      AND (v_page1->'pagination'->>'has_more')::boolean
        = ((v_page1->'summary'->>'total_count')::bigint > 2)
      AND (v_page2->'pagination'->>'offset')::int = 2
      AND jsonb_array_length(v_page2->'customers')
        = least(2, greatest((v_new->'summary'->>'total_count')::int - 2, 0))
      AND (
        SELECT count(*) FROM (
          SELECT jsonb_array_elements(v_page1->'customers')->>'analytics_customer_key'
          INTERSECT
          SELECT jsonb_array_elements(v_page2->'customers')->>'analytics_customer_key'
        ) overlap
      ) = 0
      AND (v_cap->'pagination'->>'limit')::int = 100,
    format('total=%s p1=%s p2=%s cap_limit=%s',
      v_new->'summary'->>'total_count',
      jsonb_array_length(v_page1->'customers'),
      jsonb_array_length(v_page2->'customers'),
      v_cap->'pagination'->>'limit')
  );

  BEGIN
    PERFORM public.get_business_customer_segment(v_biz_b, 'active', v_from, v_to, NULL, 50, 0);
    v_cross_msg := 'call succeeded (should have failed)';
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_cross_ok := true;
      v_cross_msg := SQLERRM;
    WHEN OTHERS THEN
      v_cross_ok := (SQLERRM ILIKE '%not authorized%');
      v_cross_msg := SQLERRM;
  END;

  BEGIN
    PERFORM public.get_business_customer_segment(v_biz_a, 'not_a_segment', v_from, v_to, NULL, 50, 0);
  EXCEPTION
    WHEN OTHERS THEN
      v_invalid_ok := (SQLERRM ILIKE '%invalid segment%');
  END;

  BEGIN
    PERFORM public.get_business_customer_segment(v_biz_a, 'gender', v_from, v_to, NULL, 50, 0);
  EXCEPTION
    WHEN OTHERS THEN
      v_filter_ok := (SQLERRM ILIKE '%filter_value%');
  END;

  INSERT INTO _xbook_seg_results VALUES
  (
    'T_cross_tenant',
    v_cross_ok AND v_invalid_ok AND v_filter_ok,
    format('cross=%s invalid_segment=%s filter_required=%s', v_cross_ok, v_invalid_ok, v_filter_ok)
  ),
  (
    'U_no_dob_or_private_raw',
    NOT pg_temp._jsonb_has_forbidden_key(v_active)
      AND NOT pg_temp._jsonb_has_forbidden_key(v_g_unknown)
      AND NOT pg_temp._jsonb_has_forbidden_key(v_age)
      AND v_snapshot ? 'analytics_customer_key'
      AND NOT (v_snapshot ? 'date_of_birth')
      AND NOT (v_snapshot ? 'customer_user_id')
      AND NOT (v_snapshot ? 'manage_token')
      AND NOT (v_snapshot ? 'booking_ref')
      AND (v_g_unknown->'customers'->0->>'gender') IS DISTINCT FROM NULL
      AND (v_g_unknown->'customers'->0->>'age_bucket') IS NOT NULL,
    format('forbidden=%s gender_field=%s age_field=%s',
      pg_temp._jsonb_has_forbidden_key(v_active),
      v_g_unknown->'customers'->0 ? 'gender',
      v_g_unknown->'customers'->0 ? 'age_bucket')
  );

  DELETE FROM public.bookings WHERE booking_ref LIKE 'XSEG-%' OR customer_name LIKE 'XBOOK_SEG_%';
  DELETE FROM public.services WHERE name LIKE 'XBOOK_SEG_TEST%';
  DELETE FROM public.business_customers
  WHERE business_id = v_biz_a
    AND (
      display_name LIKE 'XBOOK_SEG_%'
      OR phone LIKE '+389700088%'
      OR client_key LIKE 'p:389700088%'
      OR client_key LIKE 'e:xseg-%'
      OR client_key LIKE 'n:xbook_seg_%'
    );

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  INSERT INTO _xbook_seg_results VALUES
  (
    'cleanup_restored_booking_count',
    v_bookings_after = v_bookings_before,
    format('bookings before=%s after=%s', v_bookings_before, v_bookings_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_seg_results
ORDER BY test_name;
