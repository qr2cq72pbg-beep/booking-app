-- =============================================================================
-- XBOOK Phase 3A.1 — ensure_business_customer lockdown tests
-- Throwaway fixtures. Cleans up. Does not change live require_client_approval.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_elock_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_elock_results;

CREATE OR REPLACE FUNCTION public._xbook_elock_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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
  v_biz_daniela uuid;
  v_svc_off uuid;
  v_svc_on uuid;
  v_staff_off uuid;
  v_staff_on uuid;
  v_ws time;
  v_date date;
  v_time time;
  v_dow int;
  v_n int;
  v_instance uuid;
  v_user_join uuid;
  v_user_on uuid;
  v_row public.business_customers%ROWTYPE;
  v_row2 public.business_customers%ROWTYPE;
  v_booking public.bookings%ROWTYPE;
  v_vip jsonb;
  v_note jsonb;
  v_read jsonb;
  v_det jsonb;
  v_det_legacy jsonb;
  v_ok boolean;
  v_msg text;
  v_sqlstate text;
  v_bookings_before bigint;
  v_bookings_after bigint;
  v_links_before bigint;
  v_links_after bigint;
  v_daniela_id uuid;
  v_daniela_vip boolean;
  v_daniela_u text;
  v_daniela_p text;
  v_daniela_visits bigint;
  v_daniela_rev numeric;
  v_guest_key text := 'p:389700076010';
  v_owner_key text := 'p:389700076020';
  v_nested_key text := 'p:389700076030';
BEGIN
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
    AND bs.business_id IS DISTINCT FROM v_biz_off
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
    INSERT INTO _xbook_elock_results VALUES ('fixture_businesses', false, 'Need approval-OFF and approval-ON businesses');
    RETURN;
  END IF;

  INSERT INTO _xbook_elock_results VALUES (
    'fixture_businesses', true,
    format('off=%s on=%s b=%s', left(v_biz_off::text, 8), left(v_biz_on::text, 8), left(v_biz_b::text, 8))
  );

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;

  PERFORM public._xbook_elock_test_set_jwt(v_biz_off);

  DELETE FROM public.bookings
  WHERE booking_ref LIKE 'XELOCK-%' OR customer_name LIKE 'XBOOK_ELOCK_%';
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (bc.display_name LIKE 'XBOOK_ELOCK_%' OR bc.client_key LIKE 'p:389700076%' OR bc.phone LIKE '+389700076%');
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_ELOCK_%'
     OR client_key LIKE 'p:389700076%'
     OR phone LIKE '+389700076%';
  DELETE FROM public.services WHERE name = 'XBOOK_ELOCK_SVC';
  DELETE FROM public.user_profiles
  WHERE email LIKE 'xbook-elock-%@invalid.example' OR full_name LIKE 'XBOOK_ELOCK_%';
  DELETE FROM auth.users WHERE email LIKE 'xbook-elock-%@invalid.example';

  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_off, 'XBOOK_ELOCK_SVC', 30, 100)
  RETURNING id INTO v_svc_off;
  INSERT INTO public.services (business_id, name, duration, price)
  VALUES (v_biz_on, 'XBOOK_ELOCK_SVC', 30, 100)
  RETURNING id INTO v_svc_on;

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

  SELECT instance_id INTO v_instance FROM auth.users WHERE instance_id IS NOT NULL LIMIT 1;
  IF v_instance IS NULL THEN
    v_instance := '00000000-0000-0000-0000-000000000000';
  END IF;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-elock-join-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-elock-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer","full_name":"XBOOK_ELOCK_JOIN"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_join;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-elock-on-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-elock-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer","full_name":"XBOOK_ELOCK_ON"}'::jsonb,
    now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_on;

  INSERT INTO public.user_profiles (id, email, role, full_name, phone)
  VALUES
    (v_user_join, 'xbook-elock-join@invalid.example', 'customer', 'XBOOK_ELOCK_JOIN', '+389700076001'),
    (v_user_on, 'xbook-elock-on@invalid.example', 'customer', 'XBOOK_ELOCK_ON', '+389700076002')
  ON CONFLICT (id) DO UPDATE
  SET role = 'customer', full_name = EXCLUDED.full_name, phone = EXCLUDED.phone;

  -- ACL
  INSERT INTO _xbook_elock_results VALUES (
    'anon_direct_ensure_denied',
    NOT has_function_privilege('anon', 'public.ensure_business_customer(uuid,text,text,text)', 'EXECUTE'),
    'anon execute'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'authenticated_direct_ensure_denied',
    NOT has_function_privilege('authenticated', 'public.ensure_business_customer(uuid,text,text,text)', 'EXECUTE'),
    'authenticated execute internal helper'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'owner_direct_internal_helper_denied',
    NOT has_function_privilege('authenticated', 'public.ensure_business_customer(uuid,text,text,text)', 'EXECUTE'),
    'owner also cannot PostgREST the internal helper'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'wrapper_authenticated_execute',
    has_function_privilege('authenticated', 'public.ensure_business_customer_for_owner(uuid,text,text,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.ensure_business_customer_for_owner(uuid,text,text,text)', 'EXECUTE'),
    'wrapper ACL'
  );

  -- Runtime: SET ROLE authenticated cannot execute internal helper
  v_ok := false;
  v_msg := NULL;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    PERFORM public.ensure_business_customer(v_biz_off, '+389700076099', NULL, 'XBOOK_ELOCK_DENIED');
    EXECUTE 'RESET ROLE';
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
      BEGIN EXECUTE 'RESET ROLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := v_sqlstate IN ('42501', '42501');
      BEGIN EXECUTE 'RESET ROLE'; EXCEPTION WHEN OTHERS THEN NULL; END;
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'authenticated_runtime_ensure_denied',
    v_ok OR NOT has_function_privilege('authenticated', 'public.ensure_business_customer(uuid,text,text,text)', 'EXECUTE'),
    coalesce(v_sqlstate || ' ' || v_msg, 'acl/runtime')
  );

  -- Owner wrapper own business
  PERFORM public._xbook_elock_test_set_jwt(v_biz_off);
  v_row := public.ensure_business_customer_for_owner(
    v_biz_off, '+389700076020', NULL, 'XBOOK_ELOCK_OWNER'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'owner_wrapper_own_business',
    v_row.id IS NOT NULL
      AND v_row.business_id = v_biz_off
      AND v_row.customer_user_id IS NULL
      AND v_row.client_key = v_owner_key,
    coalesce(v_row.client_key, 'null')
  );

  -- Owner wrapper other business
  v_ok := false;
  BEGIN
    PERFORM public.ensure_business_customer_for_owner(
      v_biz_on, '+389700076021', NULL, 'XBOOK_ELOCK_CROSS'
    );
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'owner_wrapper_other_business_denied',
    v_ok, coalesce(v_sqlstate, 'ok')
  );

  -- Customer cannot call wrapper for a business they do not own
  PERFORM public._xbook_elock_test_set_jwt(v_user_join);
  v_ok := false;
  BEGIN
    PERFORM public.ensure_business_customer_for_owner(
      v_biz_off, '+389700076022', NULL, 'XBOOK_ELOCK_CUSTWRAP'
    );
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'customer_wrapper_denied',
    v_ok, coalesce(v_sqlstate, 'ok')
  );

  -- Owner Add Booking: wrapper CRM upsert, then create_booking.
  -- create_booking itself does not insert business_customers rows.
  PERFORM public._xbook_elock_test_set_jwt(v_biz_off);
  v_row := public.ensure_business_customer_for_owner(
    v_biz_off, '+389700076010', NULL, 'XBOOK_ELOCK_GUEST'
  );
  v_ok := false;
  v_msg := NULL;
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date, v_time,
      'XBOOK_ELOCK_GUEST', '+389700076010', NULL, NULL, v_staff_off, NULL, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id IS NULL;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      v_ok := false;
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'owner_manual_booking_succeeds',
    v_ok, coalesce(v_msg, v_booking.id::text)
  );
  INSERT INTO _xbook_elock_results VALUES (
    'guest_booking_crm_row',
    v_row.id IS NOT NULL
      AND v_row.customer_user_id IS NULL
      AND v_row.client_key = v_guest_key
      AND v_ok
      AND (
        SELECT count(*) FROM public.business_customers
        WHERE business_id = v_biz_off AND client_key = v_guest_key
      ) = 1,
    format('found=%s uid_null=%s key=%s', v_row.id IS NOT NULL, v_row.customer_user_id IS NULL, v_row.client_key)
  );

  -- Nested SECURITY DEFINER guest path still works after authenticated REVOKE
  v_row2 := public._upsert_business_customer_approval_row(
    v_biz_off, NULL, '+389700076040', NULL, 'XBOOK_ELOCK_NESTED_UPSERT', 'approved'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'nested_definer_guest_upsert',
    v_row2.id IS NOT NULL
      AND v_row2.customer_user_id IS NULL
      AND v_row2.client_key = 'p:389700076040',
    coalesce(v_row2.client_key, 'null')
  );
  v_row2 := public._ensure_business_customer_membership(
    v_biz_off, NULL, '+389700076050', NULL, 'XBOOK_ELOCK_NESTED_MEM', NULL
  );
  INSERT INTO _xbook_elock_results VALUES (
    'nested_definer_guest_membership',
    v_row2.id IS NOT NULL
      AND v_row2.customer_user_id IS NULL
      AND v_row2.client_key = 'p:389700076050',
    coalesce(v_row2.client_key, 'null')
  );

  -- Nested SECURITY DEFINER: VIP write ensure of a new guest key after authenticated revoke
  v_vip := public.set_business_customer_vip(v_biz_off, v_nested_key, true);
  SELECT * INTO v_row2
  FROM public.business_customers
  WHERE business_id = v_biz_off AND client_key = v_nested_key;
  INSERT INTO _xbook_elock_results VALUES (
    'nested_definer_ensure_via_vip',
    (v_vip->>'ok')::boolean IS TRUE
      AND v_row2.id IS NOT NULL
      AND v_row2.customer_user_id IS NULL
      AND v_row2.is_vip = true,
    v_vip::text
  );

  -- Business Code join OFF → approved → booking
  PERFORM public._xbook_elock_test_set_jwt(v_user_join);
  v_row := public.register_customer_business_membership(
    v_biz_off, '+389700076001', NULL, 'XBOOK_ELOCK_JOIN'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'join_off_approved',
    v_row.id IS NOT NULL
      AND v_row.customer_user_id = v_user_join
      AND v_row.approval_status = 'approved',
    coalesce(v_row.approval_status, 'null')
  );

  v_ok := false;
  v_msg := NULL;
  BEGIN
    v_booking := public.create_booking(
      v_biz_off, v_svc_off, v_date + 1, v_time,
      'XBOOK_ELOCK_JOIN', '+389700076001', 'xbook-elock-join@invalid.example',
      NULL, v_staff_off, v_user_join, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id = v_user_join;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      v_ok := false;
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'customer_valid_booking_succeeds',
    v_ok, coalesce(v_msg, 'booked')
  );

  -- Customer without membership on ON business
  v_ok := false;
  BEGIN
    v_booking := public.create_booking(
      v_biz_on, v_svc_on, v_date, v_time,
      'XBOOK_ELOCK_JOIN', '+389700076001', NULL, NULL, v_staff_on, v_user_join, 'Confirmed'
    );
    v_ok := false;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      v_ok := v_msg ILIKE '%join this business%' OR v_msg ILIKE '%account to book%' OR v_msg ILIKE '%not available%' OR v_msg ILIKE '%pending%' OR v_msg ILIKE '%approval%';
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'customer_invalid_membership_denied',
    v_ok, coalesce(v_msg, 'no error')
  );

  -- Join ON → pending → booking denied → approve → booking
  PERFORM public._xbook_elock_test_set_jwt(v_user_on);
  v_row := public.register_customer_business_membership(
    v_biz_on, '+389700076002', NULL, 'XBOOK_ELOCK_ON'
  );
  INSERT INTO _xbook_elock_results VALUES (
    'join_on_pending',
    v_row.id IS NOT NULL
      AND v_row.customer_user_id = v_user_on
      AND v_row.approval_status = 'pending',
    coalesce(v_row.approval_status, 'null')
  );

  v_ok := false;
  BEGIN
    v_booking := public.create_booking(
      v_biz_on, v_svc_on, v_date, v_time,
      'XBOOK_ELOCK_ON', '+389700076002', NULL, NULL, v_staff_on, v_user_on, 'Confirmed'
    );
    v_ok := false;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      v_ok := v_msg ILIKE '%pending%' OR v_msg ILIKE '%not accepting%' OR v_msg ILIKE '%approval%';
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'pending_booking_denied',
    v_ok, coalesce(v_msg, 'no error')
  );

  PERFORM public._xbook_elock_test_set_jwt(v_biz_on);
  v_row2 := public.set_business_customer_approval_status(v_row.client_key, 'approved');
  INSERT INTO _xbook_elock_results VALUES (
    'owner_approve_pending',
    v_row2.id IS NOT NULL AND v_row2.approval_status = 'approved',
    coalesce(v_row2.approval_status, 'null')
  );

  PERFORM public._xbook_elock_test_set_jwt(v_user_on);
  v_ok := false;
  v_msg := NULL;
  BEGIN
    v_booking := public.create_booking(
      v_biz_on, v_svc_on, v_date, v_time,
      'XBOOK_ELOCK_ON', '+389700076002', NULL, NULL, v_staff_on, v_user_on, 'Confirmed'
    );
    v_ok := v_booking.id IS NOT NULL AND v_booking.customer_user_id = v_user_on;
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      v_ok := false;
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'approved_then_booking',
    v_ok, coalesce(v_msg, 'booked')
  );

  -- CRM actions
  PERFORM public._xbook_elock_test_set_jwt(v_biz_off);
  v_vip := public.set_business_customer_vip(v_biz_off, v_owner_key, true);
  v_note := public.update_business_customer_internal_notes(v_biz_off, v_owner_key, 'elock note');
  v_read := public.get_business_customer_internal_notes(v_biz_off, v_owner_key);
  INSERT INTO _xbook_elock_results VALUES (
    'crm_owner_vip_notes',
    (v_vip->>'is_vip')::boolean IS TRUE
      AND v_note->>'note' = 'elock note'
      AND v_read->>'note' = 'elock note',
    'owner crm'
  );

  PERFORM public._xbook_elock_test_set_jwt(v_user_join);
  v_ok := false;
  BEGIN
    PERFORM public.set_business_customer_vip(v_biz_off, v_owner_key, false);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_elock_results VALUES (
    'crm_customer_denied',
    v_ok, coalesce(v_sqlstate, 'ok')
  );

  -- Daniela
  SELECT bc.business_id, bc.id, bc.is_vip, bc.client_key, 'u:' || bc.customer_user_id::text
  INTO v_biz_daniela, v_daniela_id, v_daniela_vip, v_daniela_p, v_daniela_u
  FROM public.business_customers bc
  WHERE bc.customer_number = 2
    AND bc.customer_user_id IS NOT NULL
    AND bc.client_key LIKE 'p:%'
    AND EXISTS (
      SELECT 1 FROM public.business_customer_identity_links l
      WHERE l.business_id = bc.business_id
        AND l.canonical_customer_user_id = bc.customer_user_id
        AND l.legacy_analytics_key = bc.client_key
        AND l.revoked_at IS NULL
    )
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bc.business_id) DESC
  LIMIT 1;

  IF v_daniela_id IS NULL THEN
    INSERT INTO _xbook_elock_results VALUES ('daniela_same_crm_row', false, 'not found');
    INSERT INTO _xbook_elock_results VALUES ('daniela_visits_unchanged', false, 'skip');
    INSERT INTO _xbook_elock_results VALUES ('daniela_revenue_unchanged', false, 'skip');
  ELSE
    PERFORM public._xbook_elock_test_set_jwt(v_biz_daniela);
    v_det := public.get_business_customer_detail(v_biz_daniela, v_daniela_u, 5, 0);
    v_daniela_visits := (v_det->'summary'->>'completed_visits_lifetime')::bigint;
    v_daniela_rev := (v_det->'summary'->>'completed_revenue_lifetime')::numeric;
    v_vip := public.set_business_customer_vip(v_biz_daniela, v_daniela_u, coalesce(v_daniela_vip, false));
    v_read := public.get_business_customer_internal_notes(v_biz_daniela, v_daniela_p);
    v_det_legacy := public.get_business_customer_detail(v_biz_daniela, v_daniela_p, 5, 0);
    INSERT INTO _xbook_elock_results VALUES (
      'daniela_same_crm_row',
      (v_vip->>'business_customer_id')::uuid = v_daniela_id
        AND (v_read->>'business_customer_id')::uuid = v_daniela_id
        AND (v_det->'customer'->>'customer_number') = (v_det_legacy->'customer'->>'customer_number'),
      'u and p'
    );
    v_det := public.get_business_customer_detail(v_biz_daniela, v_daniela_u, 5, 0);
    INSERT INTO _xbook_elock_results VALUES (
      'daniela_visits_unchanged',
      (v_det->'summary'->>'completed_visits_lifetime')::bigint IS NOT DISTINCT FROM v_daniela_visits,
      format('%s', v_daniela_visits)
    );
    INSERT INTO _xbook_elock_results VALUES (
      'daniela_revenue_unchanged',
      (v_det->'summary'->>'completed_revenue_lifetime')::numeric IS NOT DISTINCT FROM v_daniela_rev,
      format('%s', v_daniela_rev)
    );
    UPDATE public.business_customers
    SET is_vip = coalesce(v_daniela_vip, false)
    WHERE id = v_daniela_id;
  END IF;

  -- Cleanup
  PERFORM public._xbook_elock_test_set_jwt(v_biz_off);
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (bc.display_name LIKE 'XBOOK_ELOCK_%' OR bc.client_key LIKE 'p:389700076%' OR bc.customer_user_id IN (v_user_join, v_user_on));
  DELETE FROM public.bookings
  WHERE booking_ref LIKE 'XELOCK-%' OR customer_name LIKE 'XBOOK_ELOCK_%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_ELOCK_%'
     OR client_key LIKE 'p:389700076%'
     OR customer_user_id IN (v_user_join, v_user_on);
  DELETE FROM public.services WHERE name = 'XBOOK_ELOCK_SVC';
  DELETE FROM public.user_profiles WHERE id IN (v_user_join, v_user_on);
  DELETE FROM auth.users WHERE id IN (v_user_join, v_user_on);

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;
  INSERT INTO _xbook_elock_results VALUES (
    'bookings_net_zero',
    v_bookings_after = v_bookings_before,
    format('before=%s after=%s', v_bookings_before, v_bookings_after)
  );
  INSERT INTO _xbook_elock_results VALUES (
    'identity_links_net_zero',
    v_links_after = v_links_before,
    format('before=%s after=%s', v_links_before, v_links_after)
  );
END;
$$;

SELECT test_name, passed, detail
FROM (
  SELECT test_name, passed, detail, 0 AS ord
  FROM _xbook_elock_results
  WHERE NOT passed
  UNION ALL
  SELECT
    'SUMMARY',
    count(*) FILTER (WHERE NOT passed) = 0,
    format('%s passed / %s failed / %s total', count(*) FILTER (WHERE passed), count(*) FILTER (WHERE NOT passed), count(*)),
    1
  FROM _xbook_elock_results
) s
ORDER BY ord, test_name;

DROP FUNCTION IF EXISTS public._xbook_elock_test_set_jwt(uuid, text);
