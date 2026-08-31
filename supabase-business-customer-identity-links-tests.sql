-- =============================================================================
-- XBOOK: Business-scoped identity link tests
-- Throwaway fixtures only. Cleans up. Does not rewrite bookings for Daniela.
-- Does not insert the live Daniela link (separate apply file).
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_idlink_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_idlink_results;

CREATE OR REPLACE FUNCTION public._xbook_idlink_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._idlink_has_forbidden(p jsonb)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_key text;
  v_val jsonb;
  v_forbidden text[] := ARRAY[
    'date_of_birth', 'dob', 'manage_token', 'booking_ref', 'password',
    'encrypted_password', 'customer_user_id', 'raw_app_meta_data',
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
      IF pg_temp._idlink_has_forbidden(v_val) THEN
        RETURN true;
      END IF;
    END LOOP;
  ELSIF jsonb_typeof(p) = 'array' THEN
    FOR v_val IN SELECT jsonb_array_elements(p)
    LOOP
      IF pg_temp._idlink_has_forbidden(v_val) THEN
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
  v_staff uuid;
  v_svc uuid;
  v_staff_b uuid;
  v_svc_b uuid;
  v_instance uuid;
  v_user_canon uuid;
  v_user_other uuid;
  v_user_b uuid;
  v_cust_caller uuid;
  v_num integer;
  v_num_b integer;
  v_legacy_key text := 'p:389700055001';
  v_legacy_other text := 'p:389700055002';
  v_email_typo_a text := 'e:xbook-idlink-a@invalid.example';
  v_email_typo_b text := 'e:xbook-idlink-aa@invalid.example';
  v_link jsonb;
  v_unlink jsonb;
  v_resolved text;
  v_ok boolean;
  v_msg text;
  v_id uuid;
  v_id2 uuid;
  v_from date;
  v_to date;
  v_yesterday date;
  v_overview_before jsonb;
  v_overview_after jsonb;
  v_seg jsonb;
  v_det jsonb;
  v_det_legacy jsonb;
  v_perf jsonb;
  v_pop integer;
  v_auth_key text;
  v_n integer;
  v_visits bigint;
  v_rev numeric;
  v_top_keys text[];
  v_seg_keys text[];
  v_bookings_before bigint;
  v_bookings_after bigint;
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
    INSERT INTO _xbook_idlink_results VALUES ('fixture_businesses', false, 'Need two businesses');
    RETURN;
  END IF;

  SELECT sm.id INTO v_staff FROM public.staff_members sm WHERE sm.business_id = v_biz_a ORDER BY sm.id LIMIT 1;
  SELECT s.id INTO v_svc FROM public.services s WHERE s.business_id = v_biz_a ORDER BY s.id LIMIT 1;
  SELECT sm.id INTO v_staff_b FROM public.staff_members sm WHERE sm.business_id = v_biz_b ORDER BY sm.id LIMIT 1;
  SELECT s.id INTO v_svc_b FROM public.services s WHERE s.business_id = v_biz_b ORDER BY s.id LIMIT 1;

  IF v_staff IS NULL OR v_svc IS NULL THEN
    INSERT INTO _xbook_idlink_results VALUES ('fixture_businesses', false, 'Need staff+service on busiest business');
    RETURN;
  END IF;

  INSERT INTO _xbook_idlink_results VALUES (
    'fixture_businesses', true, format('a=%s b=%s', left(v_biz_a::text, 8), left(v_biz_b::text, 8))
  );

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
    'xbook-idlink-canon-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-idlink-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_canon;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-idlink-other-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-idlink-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_other;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-idlink-bmem-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-idlink-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_b;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-idlink-caller-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-idlink-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_cust_caller;

  SELECT coalesce(max(customer_number), 0) INTO v_num
  FROM public.business_customers WHERE business_id = v_biz_a;
  SELECT coalesce(max(customer_number), 0) INTO v_num_b
  FROM public.business_customers WHERE business_id = v_biz_b;

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, email,
    customer_user_id, approval_status
  ) VALUES (
    v_biz_a, 'p:389700055010', v_num + 1, 'XBOOK_IDLINK_CANON', '+389700055010',
    'xbook-idlink-canon@invalid.example', v_user_canon, 'approved'
  );

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status
  ) VALUES (
    v_biz_a, 'p:389700055011', v_num + 2, 'XBOOK_IDLINK_OTHER', '+389700055011',
    v_user_other, 'approved'
  );

  IF v_svc_b IS NOT NULL THEN
    INSERT INTO public.business_customers (
      business_id, client_key, customer_number, display_name, phone,
      customer_user_id, approval_status
    ) VALUES (
      v_biz_b, 'p:389700055020', v_num_b + 1, 'XBOOK_IDLINK_B', '+389700055020',
      v_user_b, 'approved'
    );
    -- Same auth user also a member of B (cross-business isolation).
    INSERT INTO public.business_customers (
      business_id, client_key, customer_number, display_name, phone,
      customer_user_id, approval_status
    ) VALUES (
      v_biz_b, 'p:389700055021', v_num_b + 2, 'XBOOK_IDLINK_CANON_B', '+389700055021',
      v_user_canon, 'approved'
    );
  END IF;

  v_auth_key := 'u:' || v_user_canon::text;
  v_yesterday := ((now() AT TIME ZONE v_tz)::date - 1);
  v_from := date_trunc('month', v_yesterday)::date;
  v_to := (v_from + interval '1 month' - interval '1 day')::date;

  PERFORM public._xbook_idlink_test_set_jwt(v_biz_a);

  -- Auth completed visit + matching-phone guest visit (no link yet).
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status, booking_price,
    booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_IDLINK_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
    'XBOOK_IDLINK_CANON', '+389700055001', v_user_canon, 'Confirmed', 100,
    'XIDL-A1', gen_random_uuid()::text
  );
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_IDLINK_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '10:00', 30,
    'XBOOK_IDLINK_CANON', '+389700055001', 'Confirmed', 50, 'XIDL-G1', gen_random_uuid()::text
  );

  PERFORM public._xbook_idlink_test_set_jwt(v_biz_a);

  -- Shared phone, no explicit link: must remain two identities.
  v_resolved := public._resolve_business_analytics_customer_key(v_biz_a, v_legacy_key);
  SELECT count(*) INTO v_pop
  FROM public._business_analytics_customer_keys(v_biz_a) k
  WHERE k.analytics_customer_key IN (v_auth_key, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'shared_phone_no_auto_link',
    v_resolved = v_legacy_key AND v_pop = 2,
    format('resolve=%s pop=%s', left(coalesce(v_resolved, ''), 8), v_pop)
  );

  -- Email typo keys: resolver does not merge.
  v_resolved := public._resolve_business_analytics_customer_key(v_biz_a, v_email_typo_b);
  INSERT INTO _xbook_idlink_results VALUES (
    'email_typo_no_auto_link',
    v_resolved = v_email_typo_b,
    left(coalesce(v_resolved, ''), 20)
  );

  -- H: u: cannot be legacy
  v_ok := false;
  v_msg := '';
  BEGIN
    v_link := public.link_business_customer_identity(
      v_biz_a, v_user_canon, v_auth_key, 'legacy_guest_history'
    );
    v_msg := 'call succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      v_ok := (SQLERRM ILIKE '%authenticated customer key%' OR SQLERRM ILIKE '%legacy%');
      v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_idlink_results VALUES ('H_u_key_rejected_as_legacy', v_ok, v_msg);

  -- A: owner can create valid link
  v_link := public.link_business_customer_identity(
    v_biz_a, v_user_canon, v_legacy_key, 'legacy_guest_history'
  );
  INSERT INTO _xbook_idlink_results VALUES (
    'A_owner_can_link',
    coalesce((v_link->>'ok')::boolean, false) = true AND v_link ? 'id',
    coalesce(v_link->>'id', 'null')
  );
  v_id := (v_link->>'id')::uuid;

  v_resolved := public._resolve_business_analytics_customer_key(v_biz_a, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'A_resolver_maps_to_canonical',
    v_resolved = v_auth_key,
    left(coalesce(v_resolved, ''), 12)
  );

  -- Idempotent relink same pair
  v_link := public.link_business_customer_identity(
    v_biz_a, v_user_canon, v_legacy_key, 'legacy_guest_history'
  );
  INSERT INTO _xbook_idlink_results VALUES (
    'A_idempotent_same_link',
    coalesce((v_link->>'already_linked')::boolean, false) = true,
    v_link::text
  );

  -- E: same legacy key cannot map to two active canonicals
  v_ok := false;
  v_msg := '';
  BEGIN
    v_link := public.link_business_customer_identity(
      v_biz_a, v_user_other, v_legacy_key, 'legacy_guest_history'
    );
    v_msg := 'call succeeded';
  EXCEPTION
    WHEN unique_violation THEN
      v_ok := true;
      v_msg := SQLERRM;
    WHEN OTHERS THEN
      v_ok := (SQLERRM ILIKE '%already linked%');
      v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_idlink_results VALUES ('E_duplicate_active_rejected', v_ok, v_msg);

  -- B: customer cannot create link
  PERFORM public._xbook_idlink_test_set_jwt(v_cust_caller);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_link := public.link_business_customer_identity(
      v_biz_a, v_user_canon, v_legacy_other, 'legacy_guest_history'
    );
    v_msg := 'call succeeded';
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_ok := true;
      v_msg := SQLERRM;
    WHEN OTHERS THEN
      v_ok := (SQLERRM ILIKE '%not authorized%');
      v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_idlink_results VALUES ('B_customer_cannot_link', v_ok, v_msg);

  -- Direct table insert as authenticated customer denied by RLS
  v_ok := false;
  v_msg := '';
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO public.business_customer_identity_links (
      business_id, canonical_customer_user_id, legacy_analytics_key, reason
    ) VALUES (
      v_biz_a, v_user_canon, v_legacy_other, 'legacy_guest_history'
    );
    v_msg := 'insert succeeded';
    EXECUTE 'RESET ROLE';
  EXCEPTION
    WHEN insufficient_privilege THEN
      EXECUTE 'RESET ROLE';
      v_ok := true;
      v_msg := SQLERRM;
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      v_ok := (
        SQLERRM ILIKE '%row-level security%'
        OR SQLERRM ILIKE '%not authorized%'
        OR SQLERRM ILIKE '%permission denied%'
        OR SQLERRM ILIKE '%not a member%'
      );
      v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_idlink_results VALUES ('B_customer_rls_insert_denied', v_ok, v_msg);

  -- C: owner A cannot link canonical who is only a member of B
  PERFORM public._xbook_idlink_test_set_jwt(v_biz_a);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_link := public.link_business_customer_identity(
      v_biz_a, v_user_b, 'p:389700055099', 'legacy_guest_history'
    );
    v_msg := 'call succeeded';
  EXCEPTION
    WHEN OTHERS THEN
      v_ok := (SQLERRM ILIKE '%not a member%');
      v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_idlink_results VALUES ('C_wrong_business_canonical_rejected', v_ok, v_msg);

  -- D: link in A does not resolve in B
  v_resolved := public._resolve_business_analytics_customer_key(v_biz_b, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'D_wrong_business_alias_unresolved',
    v_resolved = v_legacy_key,
    left(coalesce(v_resolved, ''), 12)
  );

  -- Analytics after link: one identity, combined visits
  v_overview_after := public.get_business_customer_analytics_overview(v_biz_a, v_from, v_to);
  SELECT count(*) INTO v_pop
  FROM public._business_analytics_customer_keys(v_biz_a) k
  WHERE k.analytics_customer_key IN (v_auth_key, v_legacy_key);

  v_det := public.get_business_customer_detail(v_biz_a, v_auth_key, 25, 0);
  v_det_legacy := public.get_business_customer_detail(v_biz_a, v_legacy_key, 25, 0);
  v_seg := public.get_business_customer_segment(v_biz_a, 'active', v_from, v_to, NULL, 100, 0);
  v_perf := public.get_business_performance_report(v_biz_a, v_from, v_to);

  INSERT INTO _xbook_idlink_results VALUES (
    'pop_linked_alias_not_separate',
    v_pop = 1,
    format('pop=%s', v_pop)
  );

  INSERT INTO _xbook_idlink_results VALUES (
    'detail_canonical_combines_visits',
    coalesce(v_det->>'ok', '') = 'true'
      AND coalesce((v_det->'summary'->>'completed_visits_lifetime')::bigint, 0) >= 2
      AND coalesce((v_det->'summary'->>'completed_revenue_lifetime')::numeric, 0) >= 150
      AND coalesce(v_det->'customer'->>'analytics_customer_key', '') = v_auth_key,
    format('visits=%s rev=%s key=%s',
      v_det->'summary'->>'completed_visits_lifetime',
      v_det->'summary'->>'completed_revenue_lifetime',
      left(coalesce(v_det->'customer'->>'analytics_customer_key', ''), 12))
  );

  INSERT INTO _xbook_idlink_results VALUES (
    'detail_legacy_key_redirects',
    coalesce(v_det_legacy->>'ok', '') = 'true'
      AND coalesce(v_det_legacy->'customer'->>'analytics_customer_key', '') = v_auth_key
      AND coalesce((v_det_legacy->'summary'->>'completed_visits_lifetime')::bigint, 0)
        = coalesce((v_det->'summary'->>'completed_visits_lifetime')::bigint, -1),
    format('ok=%s key=%s', v_det_legacy->>'ok', left(coalesce(v_det_legacy->'customer'->>'analytics_customer_key', ''), 12))
  );

  INSERT INTO _xbook_idlink_results VALUES (
    'I_no_private_profile_in_detail',
    NOT pg_temp._idlink_has_forbidden(v_det)
      AND NOT pg_temp._idlink_has_forbidden(v_seg)
      AND NOT pg_temp._idlink_has_forbidden(v_overview_after),
    'scanned detail/segment/overview'
  );

  SELECT coalesce(array_agg(c->>'analytics_customer_key'), '{}')
  INTO v_seg_keys
  FROM jsonb_array_elements(coalesce(v_seg->'customers', '[]'::jsonb)) c
  WHERE c->>'analytics_customer_key' IN (v_auth_key, v_legacy_key);

  INSERT INTO _xbook_idlink_results VALUES (
    'segment_one_canonical',
    coalesce(array_length(v_seg_keys, 1), 0) <= 1
      AND (v_legacy_key <> ALL (v_seg_keys) OR array_length(v_seg_keys, 1) IS NULL)
      AND (v_auth_key = ANY (v_seg_keys) OR coalesce(array_length(v_seg_keys, 1), 0) = 0),
    format('n=%s', coalesce(array_length(v_seg_keys, 1), 0))
  );

  SELECT coalesce(array_agg(c->>'analytics_customer_key'), '{}')
  INTO v_top_keys
  FROM jsonb_array_elements(coalesce(v_perf->'top_customers', '[]'::jsonb)) c
  WHERE c->>'analytics_customer_key' IN (v_auth_key, v_legacy_key);

  INSERT INTO _xbook_idlink_results VALUES (
    'performance_one_canonical',
    NOT (v_legacy_key = ANY (v_top_keys)),
    format('n=%s', coalesce(array_length(v_top_keys, 1), 0))
  );

  -- Cross-business: B overview unchanged by A's link (capture B after vs no extra keys)
  IF v_svc_b IS NOT NULL THEN
    PERFORM public._xbook_idlink_test_set_jwt(v_biz_b);
    v_resolved := public._resolve_business_analytics_customer_key(v_biz_b, v_legacy_key);
    SELECT count(*) INTO v_n
    FROM public._business_analytics_customer_keys(v_biz_b) k
    WHERE k.analytics_customer_key = v_legacy_key;
    INSERT INTO _xbook_idlink_results VALUES (
      'cross_business_isolation',
      v_resolved = v_legacy_key,
      format('b_resolve_unchanged pop_legacy=%s', v_n)
    );
    PERFORM public._xbook_idlink_test_set_jwt(v_biz_a);
  ELSE
    INSERT INTO _xbook_idlink_results VALUES ('cross_business_isolation', true, 'skipped_no_b_service');
  END IF;

  -- F / G / 28: revoke then relink
  v_unlink := public.unlink_business_customer_identity(v_biz_a, v_legacy_key);
  v_resolved := public._resolve_business_analytics_customer_key(v_biz_a, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'F_revoked_no_longer_resolves',
    coalesce((v_unlink->>'revoked')::boolean, false) = true
      AND v_resolved = v_legacy_key,
    format('revoked=%s resolve=%s', v_unlink->>'revoked', left(coalesce(v_resolved, ''), 8))
  );

  SELECT count(*) INTO v_pop
  FROM public._business_analytics_customer_keys(v_biz_a) k
  WHERE k.analytics_customer_key IN (v_auth_key, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'rollback_split_restored',
    v_pop = 2,
    format('pop=%s', v_pop)
  );

  v_link := public.link_business_customer_identity(
    v_biz_a, v_user_canon, v_legacy_key, 'legacy_guest_history'
  );
  v_resolved := public._resolve_business_analytics_customer_key(v_biz_a, v_legacy_key);
  INSERT INTO _xbook_idlink_results VALUES (
    'G_relink_after_revoke',
    coalesce((v_link->>'ok')::boolean, false) = true
      AND coalesce((v_link->>'already_linked')::boolean, true) = false
      AND v_resolved = v_auth_key,
    coalesce(v_link->>'id', 'null')
  );

  -- Booking rows for fixtures unchanged by revoke/relink (count only)
  SELECT count(*) INTO v_bookings_after
  FROM public.bookings
  WHERE booking_ref IN ('XIDL-A1', 'XIDL-G1');
  INSERT INTO _xbook_idlink_results VALUES (
    'fixture_bookings_preserved',
    v_bookings_after = 2,
    format('n=%s', v_bookings_after)
  );

  -- Cleanup fixture (not Daniela)
  DELETE FROM public.business_customer_identity_links
  WHERE business_id IN (v_biz_a, v_biz_b)
    AND (
      legacy_analytics_key LIKE 'p:389700055%'
      OR legacy_analytics_key LIKE 'e:xbook-idlink-%'
    );
  DELETE FROM public.bookings
  WHERE business_id IN (v_biz_a, v_biz_b)
    AND (
      booking_ref LIKE 'XIDL-%'
      OR customer_name LIKE 'XBOOK_IDLINK%'
    );
  DELETE FROM public.business_customers
  WHERE business_id IN (v_biz_a, v_biz_b)
    AND display_name LIKE 'XBOOK_IDLINK%';
  DELETE FROM auth.users
  WHERE id IN (v_user_canon, v_user_other, v_user_b, v_cust_caller);

  PERFORM public._xbook_idlink_test_set_jwt(NULL, 'anon');
EXCEPTION
  WHEN OTHERS THEN
    INSERT INTO _xbook_idlink_results VALUES (
      'FATAL', false, SQLERRM
    )
    ON CONFLICT (test_name) DO UPDATE SET passed = false, detail = EXCLUDED.detail;
    BEGIN
      DELETE FROM public.business_customer_identity_links
      WHERE legacy_analytics_key LIKE 'p:389700055%'
         OR legacy_analytics_key LIKE 'e:xbook-idlink-%';
      DELETE FROM public.bookings WHERE customer_name LIKE 'XBOOK_IDLINK%' OR booking_ref LIKE 'XIDL-%';
      DELETE FROM public.business_customers WHERE display_name LIKE 'XBOOK_IDLINK%';
      DELETE FROM auth.users WHERE email LIKE 'xbook-idlink-%@invalid.example';
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;
END;
$$;

DROP FUNCTION IF EXISTS public._xbook_idlink_test_set_jwt(uuid, text);

SELECT test_name, passed, detail
FROM _xbook_idlink_results
ORDER BY test_name;
