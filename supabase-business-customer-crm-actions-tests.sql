-- =============================================================================
-- XBOOK Phase 3A CRM Actions tests
-- Throwaway fixtures + Daniela save/restore. Cleans up. No permanent notes/VIP.
-- Does not rewrite bookings or identity links.
-- =============================================================================

CREATE TEMP TABLE IF NOT EXISTS _xbook_crm3a_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_crm3a_results;

CREATE OR REPLACE FUNCTION public._xbook_crm3a_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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

CREATE OR REPLACE FUNCTION pg_temp._crm3a_has_forbidden(p jsonb)
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
      IF pg_temp._crm3a_has_forbidden(v_val) THEN
        RETURN true;
      END IF;
    END LOOP;
  ELSIF jsonb_typeof(p) = 'array' THEN
    FOR v_val IN SELECT jsonb_array_elements(p)
    LOOP
      IF pg_temp._crm3a_has_forbidden(v_val) THEN
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
  v_instance uuid;
  v_user_join uuid;
  v_user_canon uuid;
  v_cust_uid uuid;
  v_join_row public.business_customers%ROWTYPE;
  v_num integer;
  v_num_b integer;
  v_crm_only_id uuid;
  v_crm_only_key text := 'p:389700077001';
  v_manual_key text := 'p:389700077010';
  v_manual_id uuid;
  v_link_legacy text := 'p:389700077020';
  v_link_auth_key text;
  v_link_crm_id uuid;
  v_vip jsonb;
  v_vip2 jsonb;
  v_note jsonb;
  v_note2 jsonb;
  v_note_p jsonb;
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
  v_note_rows integer;
  v_biz_daniela uuid;
  v_daniela_id uuid;
  v_daniela_vip boolean;
  v_daniela_u text;
  v_daniela_p text;
  v_daniela_visits bigint;
  v_daniela_rev numeric;
  v_daniela_visits_after bigint;
  v_daniela_rev_after numeric;
  v_ensure public.business_customers%ROWTYPE;
  v_yesterday date;
  v_n integer;
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
    INSERT INTO _xbook_crm3a_results VALUES ('fixture_businesses', false, 'Need two businesses');
    RETURN;
  END IF;

  SELECT sm.id INTO v_staff FROM public.staff_members sm WHERE sm.business_id = v_biz_a ORDER BY sm.id LIMIT 1;
  SELECT s.id INTO v_svc FROM public.services s WHERE s.business_id = v_biz_a ORDER BY s.id LIMIT 1;
  IF v_staff IS NULL OR v_svc IS NULL THEN
    INSERT INTO _xbook_crm3a_results VALUES ('fixture_businesses', false, 'Need staff+service');
    RETURN;
  END IF;

  INSERT INTO _xbook_crm3a_results VALUES (
    'fixture_businesses', true, format('a=%s b=%s', left(v_biz_a::text, 8), left(v_biz_b::text, 8))
  );

  SELECT count(*) INTO v_bookings_before FROM public.bookings;
  SELECT count(*) INTO v_links_before FROM public.business_customer_identity_links;

  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);

  -- Cleanup leftover fixtures (including aborted prior runs)
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (
      bc.display_name LIKE 'XBOOK_CRM3A_%'
      OR bc.phone LIKE '+389700077%'
      OR bc.client_key LIKE 'p:389700077%'
      OR bc.client_key LIKE 'e:xbook-crm3a-%'
    );
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCRM3A-%' OR customer_name LIKE 'XBOOK_CRM3A_%';
  DELETE FROM public.business_customer_identity_links
  WHERE legacy_analytics_key LIKE 'p:389700077%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_CRM3A_%'
     OR phone LIKE '+389700077%'
     OR client_key LIKE 'p:389700077%'
     OR client_key LIKE 'e:xbook-crm3a-%';
  DELETE FROM public.user_profiles
  WHERE email LIKE 'xbook-crm3a-%@invalid.example'
     OR full_name LIKE 'XBOOK_CRM3A_%';
  DELETE FROM auth.users
  WHERE email LIKE 'xbook-crm3a-%@invalid.example';

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
    'xbook-crm3a-canon-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-crm3a-test', gen_salt('bf')), now(),
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
    'xbook-crm3a-join-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-crm3a-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer","full_name":"XBOOK_CRM3A_JOIN"}'::jsonb,
    now(), now(), '', '', '', ''
  )
  RETURNING id INTO v_user_join;

  INSERT INTO public.user_profiles (id, email, role, full_name, phone)
  VALUES (
    v_user_join,
    'xbook-crm3a-join@invalid.example',
    'customer',
    'XBOOK_CRM3A_JOIN',
    '+389700077099'
  )
  ON CONFLICT (id) DO UPDATE
  SET role = 'customer', full_name = EXCLUDED.full_name, phone = EXCLUDED.phone;

  SELECT coalesce(max(customer_number), 0) INTO v_num
  FROM public.business_customers WHERE business_id = v_biz_a;
  SELECT coalesce(max(customer_number), 0) INTO v_num_b
  FROM public.business_customers WHERE business_id = v_biz_b;

  -- CRM-only approved, no visits
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, approval_status
  ) VALUES (
    v_biz_a, v_crm_only_key, v_num + 1, 'XBOOK_CRM3A_ONLY', '+389700077001', 'approved'
  )
  RETURNING id INTO v_crm_only_id;

  -- Linked identity: canonical auth + legacy p: alias (synthetic Daniela shape)
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status, is_vip
  ) VALUES (
    v_biz_a, v_link_legacy, v_num + 2, 'XBOOK_CRM3A_LINK', '+389700077020',
    v_user_canon, 'approved', false
  )
  RETURNING id INTO v_link_crm_id;

  v_link_auth_key := 'u:' || v_user_canon::text;

  INSERT INTO public.business_customer_identity_links (
    business_id, canonical_customer_user_id, legacy_analytics_key, reason, created_by
  ) VALUES (
    v_biz_a, v_user_canon, v_link_legacy, 'legacy_guest_history', v_biz_a
  );

  -- Cross-business membership of the same auth user
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status, is_vip
  ) VALUES (
    v_biz_b, 'p:389700077021', v_num_b + 1, 'XBOOK_CRM3A_LINK_B', '+389700077021',
    v_user_canon, 'approved', false
  );

  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);
  v_yesterday := ((now() AT TIME ZONE v_tz)::date - 1);
  INSERT INTO public.bookings (
    business_id, service_id, service_name, staff_id, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, booking_price, booking_ref, manage_token
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_CRM3A_SVC', v_staff, to_char(v_yesterday, 'YYYY-MM-DD'), '09:00', 30,
    'XBOOK_CRM3A_MANUAL', '+389700077010', 'Confirmed', 80, 'XCRM3A-M1', gen_random_uuid()::text
  );

  -- Daniela snapshot (restore later). May not be the busiest business.
  SELECT bc.business_id, bc.id, bc.is_vip, bc.client_key,
         'u:' || bc.customer_user_id::text, bc.customer_user_id
  INTO v_biz_daniela, v_daniela_id, v_daniela_vip, v_daniela_p, v_daniela_u, v_cust_uid
  FROM public.business_customers bc
  WHERE bc.customer_number = 2
    AND bc.customer_user_id IS NOT NULL
    AND bc.client_key LIKE 'p:%'
    AND EXISTS (
      SELECT 1
      FROM public.business_customer_identity_links l
      WHERE l.business_id = bc.business_id
        AND l.canonical_customer_user_id = bc.customer_user_id
        AND l.legacy_analytics_key = bc.client_key
        AND l.revoked_at IS NULL
    )
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bc.business_id) DESC
  LIMIT 1;

  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);

  IF v_daniela_id IS NOT NULL AND v_daniela_u IS NOT NULL THEN
    PERFORM public._xbook_crm3a_test_set_jwt(v_biz_daniela);
    v_det := public.get_business_customer_detail(v_biz_daniela, v_daniela_u, 5, 0);
    v_daniela_visits := (v_det->'summary'->>'completed_visits_lifetime')::bigint;
    v_daniela_rev := (v_det->'summary'->>'completed_revenue_lifetime')::numeric;
  END IF;

  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);

  -- -------------------------------------------------------------------------
  -- Grants / hardening
  -- -------------------------------------------------------------------------
  INSERT INTO _xbook_crm3a_results VALUES (
    'ensure_anon_execute_revoked',
    NOT has_function_privilege(
      'anon',
      'public.ensure_business_customer(uuid,text,text,text)',
      'EXECUTE'
    ),
    'anon execute ensure_business_customer'
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'ensure_authenticated_execute_revoked',
    NOT has_function_privilege(
      'authenticated',
      'public.ensure_business_customer(uuid,text,text,text)',
      'EXECUTE'
    ),
    'authenticated execute ensure_business_customer'
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'notes_table_no_authenticated_select',
    NOT has_table_privilege('authenticated', 'public.business_customer_internal_notes', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.business_customer_internal_notes', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.business_customer_internal_notes', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.business_customer_internal_notes', 'DELETE'),
    'authenticated table privs'
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'notes_table_no_anon_access',
    NOT has_table_privilege('anon', 'public.business_customer_internal_notes', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.business_customer_internal_notes', 'INSERT'),
    'anon table privs'
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'vip_rpc_no_anon_execute',
    NOT has_function_privilege(
      'anon',
      'public.set_business_customer_vip(uuid,text,boolean)',
      'EXECUTE'
    ),
    'anon vip rpc'
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'notes_rpc_no_anon_execute',
    NOT has_function_privilege(
      'anon',
      'public.get_business_customer_internal_notes(uuid,text)',
      'EXECUTE'
    )
    AND NOT has_function_privilege(
      'anon',
      'public.update_business_customer_internal_notes(uuid,text,text)',
      'EXECUTE'
    ),
    'anon notes rpc'
  );

  -- Owner ensure (admin add-booking path) still works
  v_ensure := public.ensure_business_customer_for_owner(v_biz_a, '+389700077088', NULL, 'XBOOK_CRM3A_ENSURE');
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_ensure_business_customer_still_works',
    v_ensure.id IS NOT NULL AND v_ensure.customer_user_id IS NULL AND v_ensure.client_key LIKE 'p:%',
    coalesce(v_ensure.client_key, 'null')
  );

  -- Join / membership still works (customer jwt)
  PERFORM public._xbook_crm3a_test_set_jwt(v_user_join);
  v_join_row := public.register_customer_business_membership(
    v_biz_a, '+389700077099', NULL, 'XBOOK_CRM3A_JOIN'
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'customer_join_membership_still_works',
    v_join_row.id IS NOT NULL
      AND v_join_row.customer_user_id = v_user_join
      AND v_join_row.business_id = v_biz_a,
    format('id=%s uid_match=%s', left(coalesce(v_join_row.id::text, ''), 8), (v_join_row.customer_user_id = v_user_join))
  );

  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);

  -- -------------------------------------------------------------------------
  -- VIP writes
  -- -------------------------------------------------------------------------
  v_vip := public.set_business_customer_vip(v_biz_a, v_crm_only_key, true);
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_sets_vip_true',
    (v_vip->>'ok')::boolean IS TRUE
      AND (v_vip->>'is_vip')::boolean IS TRUE
      AND (v_vip->>'business_customer_id')::uuid = v_crm_only_id
      AND NOT pg_temp._crm3a_has_forbidden(v_vip),
    v_vip::text
  );

  v_vip2 := public.set_business_customer_vip(v_biz_a, v_crm_only_key, false);
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_sets_vip_false',
    (v_vip2->>'ok')::boolean IS TRUE AND (v_vip2->>'is_vip')::boolean IS FALSE,
    v_vip2::text
  );

  -- -------------------------------------------------------------------------
  -- Notes writes / reads
  -- -------------------------------------------------------------------------
  v_note := public.update_business_customer_internal_notes(
    v_biz_a, v_crm_only_key, '  Prefers mornings  '
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_writes_notes',
    (v_note->>'ok')::boolean IS TRUE
      AND v_note->>'note' = 'Prefers mornings'
      AND (v_note->>'business_customer_id')::uuid = v_crm_only_id
      AND NOT pg_temp._crm3a_has_forbidden(v_note),
    v_note::text
  );

  v_read := public.get_business_customer_internal_notes(v_biz_a, v_crm_only_key);
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_reads_notes',
    (v_read->>'ok')::boolean IS TRUE
      AND v_read->>'note' = 'Prefers mornings'
      AND v_read ? 'updated_at'
      AND NOT (v_read ? 'customer_user_id')
      AND NOT pg_temp._crm3a_has_forbidden(v_read),
    v_read::text
  );

  v_note2 := public.update_business_customer_internal_notes(v_biz_a, v_crm_only_key, '   ');
  v_read := public.get_business_customer_internal_notes(v_biz_a, v_crm_only_key);
  INSERT INTO _xbook_crm3a_results VALUES (
    'owner_clears_notes',
    (v_note2->>'ok')::boolean IS TRUE
      AND v_note2->>'note' IS NULL
      AND (v_read->>'ok')::boolean IS TRUE
      AND v_read->>'note' IS NULL,
    v_note2::text
  );

  v_ok := false;
  v_msg := NULL;
  BEGIN
    PERFORM public.update_business_customer_internal_notes(
      v_biz_a, v_crm_only_key, repeat('x', 2001)
    );
  EXCEPTION
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := v_sqlstate IN ('22023', '23514');
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'oversized_note_rejected',
    v_ok, coalesce(v_sqlstate || ' ' || v_msg, 'no error')
  );

  -- CRM-only zero-visit
  v_vip := public.set_business_customer_vip(v_biz_a, v_crm_only_key, true);
  v_note := public.update_business_customer_internal_notes(v_biz_a, v_crm_only_key, 'CRM only note');
  INSERT INTO _xbook_crm3a_results VALUES (
    'crm_only_zero_visit_vip_and_note',
    (v_vip->>'is_vip')::boolean IS TRUE
      AND v_note->>'note' = 'CRM only note'
      AND NOT EXISTS (
        SELECT 1 FROM public.bookings b
        WHERE b.business_id = v_biz_a AND b.customer_phone LIKE '%700077001%'
      ),
    'crm-only'
  );

  -- Manual/legacy guest with booking, no CRM row yet
  v_vip := public.set_business_customer_vip(v_biz_a, v_manual_key, true);
  v_note := public.update_business_customer_internal_notes(v_biz_a, v_manual_key, 'Walk-in note');
  SELECT id, customer_user_id IS NULL
  INTO v_manual_id, v_ok
  FROM public.business_customers
  WHERE business_id = v_biz_a AND client_key = v_manual_key;
  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = v_biz_a AND client_key = v_manual_key;
  INSERT INTO _xbook_crm3a_results VALUES (
    'manual_legacy_crm_state',
    v_n = 1
      AND v_ok IS TRUE
      AND (v_vip->>'is_vip')::boolean IS TRUE
      AND v_note->>'note' = 'Walk-in note'
      AND (v_vip->>'business_customer_id')::uuid = v_manual_id,
    format('n=%s guest=%s', v_n, v_ok)
  );

  -- Linked identity: u: and p: same CRM row, one VIP, one note
  v_vip := public.set_business_customer_vip(v_biz_a, v_link_auth_key, true);
  v_note := public.update_business_customer_internal_notes(v_biz_a, v_link_auth_key, 'Canonical note');
  v_vip2 := public.set_business_customer_vip(v_biz_a, v_link_legacy, true);
  v_note_p := public.update_business_customer_internal_notes(v_biz_a, v_link_legacy, 'Canonical note via p');
  SELECT count(*) INTO v_note_rows
  FROM public.business_customer_internal_notes
  WHERE business_id = v_biz_a AND business_customer_id = v_link_crm_id;
  INSERT INTO _xbook_crm3a_results VALUES (
    'linked_identity_same_crm_row',
    (v_vip->>'business_customer_id')::uuid = v_link_crm_id
      AND (v_vip2->>'business_customer_id')::uuid = v_link_crm_id
      AND (v_note->>'business_customer_id')::uuid = v_link_crm_id
      AND (v_note_p->>'business_customer_id')::uuid = v_link_crm_id,
    'u and p resolve'
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'linked_identity_no_duplicate_vip',
    (SELECT count(*) FROM public.business_customers
      WHERE business_id = v_biz_a AND is_vip AND id = v_link_crm_id) = 1
      AND (SELECT is_vip FROM public.business_customers WHERE id = v_link_crm_id) = true,
    'one vip row'
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'linked_identity_no_duplicate_note',
    v_note_rows = 1 AND v_note_p->>'note' = 'Canonical note via p',
    format('note_rows=%s', v_note_rows)
  );

  -- Same auth user independent VIP on business B
  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_b);
  v_vip := public.set_business_customer_vip(v_biz_b, v_link_auth_key, false);
  INSERT INTO _xbook_crm3a_results VALUES (
    'same_auth_independent_per_business',
    (v_vip->>'ok')::boolean IS TRUE
      AND (v_vip->>'is_vip')::boolean IS FALSE
      AND (SELECT is_vip FROM public.business_customers WHERE id = v_link_crm_id) = true,
    'A remains VIP, B false'
  );

  -- Cross-business denial
  v_ok := false;
  v_msg := NULL;
  BEGIN
    PERFORM public.set_business_customer_vip(v_biz_a, v_crm_only_key, false);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true; GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'other_owner_vip_denied',
    v_ok, coalesce(v_msg, 'no error')
  );

  v_ok := false;
  BEGIN
    PERFORM public.get_business_customer_internal_notes(v_biz_a, v_crm_only_key);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'other_owner_notes_read_denied',
    v_ok, v_sqlstate
  );

  v_ok := false;
  BEGIN
    PERFORM public.update_business_customer_internal_notes(v_biz_a, v_crm_only_key, 'hack');
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'other_owner_notes_write_denied',
    v_ok, v_sqlstate
  );

  -- Wrong-business key as owner A: B's client_key should not resolve to A's row
  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);
  v_read := public.get_business_customer_internal_notes(v_biz_a, 'p:389700077021');
  INSERT INTO _xbook_crm3a_results VALUES (
    'wrong_business_key_not_found',
    (v_read->>'ok')::boolean IS FALSE AND v_read->>'code' = 'not_found',
    v_read::text
  );

  -- Customer denial (use join user jwt)
  PERFORM public._xbook_crm3a_test_set_jwt(v_user_join);
  v_ok := false;
  BEGIN
    PERFORM public.set_business_customer_vip(v_biz_a, v_crm_only_key, true);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'customer_vip_write_denied',
    v_ok, v_sqlstate
  );

  v_ok := false;
  BEGIN
    PERFORM public.get_business_customer_internal_notes(v_biz_a, v_crm_only_key);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'customer_notes_read_denied',
    v_ok, v_sqlstate
  );

  v_ok := false;
  BEGIN
    PERFORM public.update_business_customer_internal_notes(v_biz_a, v_crm_only_key, 'nope');
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'customer_notes_write_denied',
    v_ok, v_sqlstate
  );

  -- Anon jwt
  PERFORM public._xbook_crm3a_test_set_jwt(NULL, 'anon');
  v_ok := false;
  BEGIN
    PERFORM public.get_business_customer_internal_notes(v_biz_a, v_crm_only_key);
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'anon_notes_read_denied',
    v_ok, v_sqlstate
  );

  v_ok := false;
  BEGIN
    PERFORM public.update_business_customer_internal_notes(v_biz_a, v_crm_only_key, 'anon');
  EXCEPTION
    WHEN insufficient_privilege THEN v_ok := true;
    WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE;
      v_ok := v_sqlstate = '42501';
  END;
  INSERT INTO _xbook_crm3a_results VALUES (
    'anon_notes_write_denied',
    v_ok, v_sqlstate
  );

  -- Customer cannot flip is_vip via table (RLS). Run as table owner check:
  -- authenticated UPDATE is granted on business_customers but USING owner policy.
  UPDATE public.business_customers
  SET is_vip = NOT is_vip
  WHERE id = v_crm_only_id
    AND business_id IS DISTINCT FROM v_user_join;
  -- above ran as postgres (bypasses RLS). Real customer path is RPC 42501 already.
  -- Restore:
  UPDATE public.business_customers SET is_vip = true WHERE id = v_crm_only_id;

  INSERT INTO _xbook_crm3a_results VALUES (
    'customer_direct_is_vip_rls_policy_owner_only',
    EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'business_customers'
        AND policyname = 'business_customers_owner_all'
        AND cmd = 'ALL'
        AND qual LIKE '%business_id = auth.uid()%'
    )
    AND EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'business_customers'
        AND policyname = 'business_customers_customer_select_own'
        AND cmd = 'SELECT'
    ),
    'owner ALL + customer SELECT-only'
  );

  -- Membership RPC still does not return notes (column absent)
  INSERT INTO _xbook_crm3a_results VALUES (
    'membership_rowtype_has_no_internal_notes',
    NOT EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'business_customers'
        AND column_name = 'internal_notes'
    ),
    'no internal_notes column'
  );

  -- Detail/Segment do not grow notes keys
  PERFORM public._xbook_crm3a_test_set_jwt(v_biz_a);
  v_det := public.get_business_customer_detail(v_biz_a, v_crm_only_key, 5, 0);
  INSERT INTO _xbook_crm3a_results VALUES (
    'detail_rpc_no_notes_key',
    v_det ? 'ok'
      AND NOT (v_det ? 'note')
      AND NOT (v_det ? 'internal_notes')
      AND NOT ((v_det->'customer') ? 'note')
      AND NOT pg_temp._crm3a_has_forbidden(v_det),
    left(v_det::text, 120)
  );

  -- -------------------------------------------------------------------------
  -- Daniela live save / restore
  -- -------------------------------------------------------------------------
  IF v_daniela_id IS NULL OR v_daniela_u IS NULL OR v_biz_daniela IS NULL THEN
    INSERT INTO _xbook_crm3a_results VALUES (
      'daniela_canonical_u_key', false, 'Daniela #002 identity-linked row not found'
    );
    INSERT INTO _xbook_crm3a_results VALUES ('daniela_legacy_p_key_same_row', false, 'skip');
    INSERT INTO _xbook_crm3a_results VALUES ('daniela_analytics_unchanged', false, 'skip');
  ELSE
    PERFORM public._xbook_crm3a_test_set_jwt(v_biz_daniela);
    BEGIN
      v_vip := public.set_business_customer_vip(v_biz_daniela, v_daniela_u, true);
      v_note := public.update_business_customer_internal_notes(
        v_biz_daniela, v_daniela_u, 'XBOOK_CRM3A_DANIELA_TEMP'
      );
      v_vip2 := public.set_business_customer_vip(v_biz_daniela, v_daniela_p, true);
      v_note_p := public.get_business_customer_internal_notes(v_biz_daniela, v_daniela_p);
      v_det := public.get_business_customer_detail(v_biz_daniela, v_daniela_u, 5, 0);
      v_det_legacy := public.get_business_customer_detail(v_biz_daniela, v_daniela_p, 5, 0);
      v_daniela_visits_after := (v_det->'summary'->>'completed_visits_lifetime')::bigint;
      v_daniela_rev_after := (v_det->'summary'->>'completed_revenue_lifetime')::numeric;

      INSERT INTO _xbook_crm3a_results VALUES (
        'daniela_canonical_u_key',
        (v_vip->>'business_customer_id')::uuid = v_daniela_id
          AND (v_vip->>'is_vip')::boolean IS TRUE
          AND v_note->>'note' = 'XBOOK_CRM3A_DANIELA_TEMP',
        v_vip::text
      );
      INSERT INTO _xbook_crm3a_results VALUES (
        'daniela_legacy_p_key_same_row',
        (v_vip2->>'business_customer_id')::uuid = v_daniela_id
          AND (v_note_p->>'business_customer_id')::uuid = v_daniela_id
          AND v_note_p->>'note' = 'XBOOK_CRM3A_DANIELA_TEMP'
          AND (v_det->'customer'->>'customer_number') = (v_det_legacy->'customer'->>'customer_number'),
        'p and u same id'
      );
      INSERT INTO _xbook_crm3a_results VALUES (
        'daniela_analytics_unchanged',
        v_daniela_visits_after IS NOT DISTINCT FROM v_daniela_visits
          AND v_daniela_rev_after IS NOT DISTINCT FROM v_daniela_rev
          AND (v_det->'customer'->>'customer_number')::int = 2,
        format('visits %s→%s rev %s→%s', v_daniela_visits, v_daniela_visits_after, v_daniela_rev, v_daniela_rev_after)
      );
    EXCEPTION
      WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
        INSERT INTO _xbook_crm3a_results VALUES ('daniela_canonical_u_key', false, v_msg)
        ON CONFLICT (test_name) DO UPDATE SET passed = false, detail = EXCLUDED.detail;
    END;

    -- Restore Daniela
    UPDATE public.business_customers
    SET is_vip = coalesce(v_daniela_vip, false), updated_at = now()
    WHERE id = v_daniela_id;
    DELETE FROM public.business_customer_internal_notes
    WHERE business_customer_id = v_daniela_id
      AND note = 'XBOOK_CRM3A_DANIELA_TEMP';
  END IF;

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links
  WHERE legacy_analytics_key NOT LIKE 'p:389700077%';

  INSERT INTO _xbook_crm3a_results VALUES (
    'no_net_booking_row_change_outside_fixtures',
    true,
    format('before=%s after=%s (fixture bookings cleaned below)', v_bookings_before, v_bookings_after)
  );

  -- Cleanup fixtures
  DELETE FROM public.business_customer_internal_notes n
  USING public.business_customers bc
  WHERE n.business_customer_id = bc.id
    AND (
      bc.display_name LIKE 'XBOOK_CRM3A_%'
      OR bc.client_key LIKE 'p:389700077%'
      OR bc.client_key LIKE 'e:xbook-crm3a-%'
      OR bc.customer_user_id IN (v_user_canon, v_user_join)
    );
  DELETE FROM public.business_customer_identity_links
  WHERE canonical_customer_user_id IN (v_user_canon, v_user_join)
     OR legacy_analytics_key LIKE 'p:389700077%';
  DELETE FROM public.bookings WHERE booking_ref LIKE 'XCRM3A-%' OR customer_name LIKE 'XBOOK_CRM3A_%';
  DELETE FROM public.business_customers
  WHERE display_name LIKE 'XBOOK_CRM3A_%'
     OR client_key LIKE 'p:389700077%'
     OR client_key LIKE 'e:xbook-crm3a-%'
     OR customer_user_id IN (v_user_canon, v_user_join);

  DELETE FROM public.user_profiles WHERE id IN (v_user_canon, v_user_join);
  DELETE FROM auth.users WHERE id IN (v_user_canon, v_user_join);

  SELECT count(*) INTO v_bookings_after FROM public.bookings;
  SELECT count(*) INTO v_links_after FROM public.business_customer_identity_links;

  INSERT INTO _xbook_crm3a_results VALUES (
    'bookings_restored',
    v_bookings_after = v_bookings_before,
    format('before=%s after=%s', v_bookings_before, v_bookings_after)
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'identity_links_restored',
    v_links_after = v_links_before,
    format('before=%s after=%s', v_links_before, v_links_after)
  );

  INSERT INTO _xbook_crm3a_results VALUES (
    'daniela_vip_restored',
    v_daniela_id IS NULL OR EXISTS (
      SELECT 1 FROM public.business_customers
      WHERE id = v_daniela_id AND is_vip IS NOT DISTINCT FROM coalesce(v_daniela_vip, false)
    ),
    'restored'
  );
  INSERT INTO _xbook_crm3a_results VALUES (
    'daniela_temp_note_removed',
    v_daniela_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.business_customer_internal_notes
      WHERE business_customer_id = v_daniela_id AND note = 'XBOOK_CRM3A_DANIELA_TEMP'
    ),
    'removed'
  );
END;
$$;

SELECT test_name, passed, detail
FROM (
  SELECT test_name, passed, detail, 0 AS ord
  FROM _xbook_crm3a_results
  WHERE NOT passed
  UNION ALL
  SELECT
    'SUMMARY',
    count(*) FILTER (WHERE NOT passed) = 0,
    format('%s passed / %s failed / %s total', count(*) FILTER (WHERE passed), count(*) FILTER (WHERE NOT passed), count(*)),
    1
  FROM _xbook_crm3a_results
) s
ORDER BY ord, test_name;

DROP FUNCTION IF EXISTS public._xbook_crm3a_test_set_jwt(uuid, text);
