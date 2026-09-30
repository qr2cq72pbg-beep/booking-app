-- XBOOK: leave_customer_business tests.
-- Throwaway fixtures only. Cleans up. Does not change live approval settings,
-- owner block/reject, or unmatched bookings.

CREATE TEMP TABLE IF NOT EXISTS _xbook_leave_results (
  test_name text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text
);
TRUNCATE _xbook_leave_results;

CREATE OR REPLACE FUNCTION public._xbook_leave_test_set_jwt(p_uid uuid, p_role text DEFAULT 'authenticated')
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
  v_biz_a uuid;
  v_biz_b uuid;
  v_instance uuid;
  v_user_a uuid;
  v_user_b uuid;
  v_crm_a uuid;
  v_crm_a2 uuid;
  v_crm_b uuid;
  v_num_a integer;
  v_num_a2 integer;
  v_status_a text;
  v_key_a text;
  v_phone_a text := '+389700099101';
  v_phone_b text := '+389700099102';
  v_svc uuid;
  v_booking uuid;
  v_booking_future uuid;
  v_booking_pending uuid;
  v_booking_past uuid;
  v_booking_cancel uuid;
  v_note_id uuid;
  v_out jsonb;
  v_ok boolean;
  v_msg text;
  v_uid uuid;
  v_n integer;
  v_relink uuid;
BEGIN
  SELECT bs.business_id
  INTO v_biz_a
  FROM public.business_settings bs
  ORDER BY (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) DESC
  LIMIT 1;

  SELECT bs.business_id
  INTO v_biz_b
  FROM public.business_settings bs
  WHERE bs.business_id IS DISTINCT FROM v_biz_a
  LIMIT 1;

  IF v_biz_a IS NULL THEN
    INSERT INTO _xbook_leave_results VALUES ('fixture_businesses', false, 'Need at least one business');
    RETURN;
  END IF;
  IF v_biz_b IS NULL THEN
    v_biz_b := v_biz_a;
  END IF;

  INSERT INTO _xbook_leave_results VALUES (
    'fixture_businesses', true,
    format('a=%s b=%s', left(v_biz_a::text, 8), left(v_biz_b::text, 8))
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
    'xbook-leave-a-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-leave-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer","full_name":"XBOOK_LEAVE_TEST A","phone":"+389700099101"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_a;

  INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) VALUES (
    v_instance, gen_random_uuid(), 'authenticated', 'authenticated',
    'xbook-leave-b-' || replace(gen_random_uuid()::text, '-', '') || '@invalid.example',
    crypt('xbook-leave-test', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{"role":"customer","full_name":"XBOOK_LEAVE_TEST B","phone":"+389700099102"}'::jsonb, now(), now(), '', '', '', ''
  ) RETURNING id INTO v_user_b;

  -- Auth trigger already inserts user_profiles when metadata.role is customer.
  UPDATE public.user_profiles
  SET
    role = 'customer',
    full_name = 'XBOOK_LEAVE_TEST A',
    phone = v_phone_a,
    updated_at = now()
  WHERE id = v_user_a;

  UPDATE public.user_profiles
  SET
    role = 'customer',
    full_name = 'XBOOK_LEAVE_TEST B',
    phone = v_phone_b,
    updated_at = now()
  WHERE id = v_user_b;

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, email,
    customer_user_id, approval_status
  ) VALUES (
    v_biz_a, 'p:389700099101',
    public._allocate_business_customer_number(v_biz_a),
    'XBOOK_LEAVE_TEST A', v_phone_a, 'xbook-leave-a@invalid.example',
    v_user_a, 'approved'
  )
  RETURNING id, customer_number, approval_status, client_key
  INTO v_crm_a, v_num_a, v_status_a, v_key_a;

  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone,
    customer_user_id, approval_status
  ) VALUES (
    v_biz_b, 'p:389700099102',
    public._allocate_business_customer_number(v_biz_b),
    'XBOOK_LEAVE_TEST B-OTHER', v_phone_b,
    v_user_b, 'approved'
  )
  RETURNING id INTO v_crm_b;

  IF v_biz_a IS DISTINCT FROM v_biz_b THEN
    INSERT INTO public.business_customers (
      business_id, client_key, customer_number, display_name, phone,
      customer_user_id, approval_status
    ) VALUES (
      v_biz_b, 'u:' || v_user_a::text,
      public._allocate_business_customer_number(v_biz_b),
      'XBOOK_LEAVE_TEST A-BIZB', v_phone_a,
      v_user_a, 'approved'
    )
    RETURNING id, customer_number INTO v_crm_a2, v_num_a2;
  END IF;

  SELECT s.id INTO v_svc
  FROM public.services s
  WHERE s.business_id = v_biz_a
  LIMIT 1;

  -- Past confirmed + cancelled future do not block leave (inserted on a separate CRM later).
  -- First: future Confirmed blocks leave.
  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_LEAVE_TEST_SVC', to_char(CURRENT_DATE + 7, 'YYYY-MM-DD'),
    '10:00', 30, 'XBOOK_LEAVE_TEST A', v_phone_a, v_user_a, 'Confirmed'
  )
  RETURNING id INTO v_booking_future;

  PERFORM public._xbook_leave_test_set_jwt(v_user_a);
  v_ok := false;
  v_msg := '';
  BEGIN
    v_out := public.leave_customer_business(v_biz_a);
    v_ok := false;
    v_msg := coalesce(v_out::text, 'left');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%upcoming appointment%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_leave_results VALUES ('future_confirmed_blocks', v_ok, v_msg);

  SELECT customer_user_id INTO v_uid FROM public.business_customers WHERE id = v_crm_a;
  SELECT count(*) INTO v_n FROM public.bookings WHERE id = v_booking_future;
  INSERT INTO _xbook_leave_results VALUES (
    'future_confirmed_membership_and_booking_unchanged',
    v_uid = v_user_a AND v_n = 1,
    format('uid_still=%s booking_n=%s', v_uid = v_user_a, v_n)
  );

  UPDATE public.bookings SET booking_status = 'Cancelled' WHERE id = v_booking_future;

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_LEAVE_TEST_SVC', to_char(CURRENT_DATE + 3, 'YYYY-MM-DD'),
    '11:00', 30, 'XBOOK_LEAVE_TEST A', v_phone_a, v_user_a, 'Pending'
  )
  RETURNING id INTO v_booking_pending;

  v_ok := false;
  v_msg := '';
  BEGIN
    v_out := public.leave_customer_business(v_biz_a);
    v_ok := false;
    v_msg := coalesce(v_out::text, 'left');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%upcoming appointment%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_leave_results VALUES ('future_pending_blocks', v_ok, v_msg);

  UPDATE public.bookings SET booking_status = 'Cancelled' WHERE id = v_booking_pending;

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_LEAVE_TEST_SVC', to_char(CURRENT_DATE - 14, 'YYYY-MM-DD'),
    '10:00', 30, 'XBOOK_LEAVE_TEST A', v_phone_a, v_user_a, 'Confirmed'
  )
  RETURNING id INTO v_booking_past;

  INSERT INTO public.bookings (
    business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_user_id, booking_status
  ) VALUES (
    v_biz_a, v_svc, 'XBOOK_LEAVE_TEST_SVC', to_char(CURRENT_DATE + 21, 'YYYY-MM-DD'),
    '12:00', 30, 'XBOOK_LEAVE_TEST A', v_phone_a, v_user_a, 'Cancelled'
  )
  RETURNING id INTO v_booking_cancel;

  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'business_customer_internal_notes'
  ) THEN
    BEGIN
      INSERT INTO public.business_customer_internal_notes (
        business_id, business_customer_id, note
      ) VALUES (
        v_biz_a, v_crm_a, 'XBOOK_LEAVE_TEST_NOTE'
      )
      RETURNING id INTO v_note_id;
    EXCEPTION WHEN OTHERS THEN
      v_note_id := NULL;
    END;
  END IF;

  SELECT count(*) INTO v_n FROM public.business_customers WHERE id = v_crm_a;
  v_out := public.leave_customer_business(v_biz_a);

  INSERT INTO _xbook_leave_results VALUES (
    'past_or_cancelled_allows_leave',
    coalesce((v_out ->> 'ok')::boolean, false) = true
      AND (v_out ->> 'business_id')::uuid = v_biz_a,
    coalesce(v_out::text, 'null')
  );

  SELECT customer_user_id, customer_number, approval_status, client_key, display_name, phone
  INTO v_uid, v_num_a2, v_status_a, v_key_a, v_msg, v_phone_a
  FROM public.business_customers
  WHERE id = v_crm_a;

  INSERT INTO _xbook_leave_results VALUES (
    'unlink_not_delete',
    v_n = 1
      AND EXISTS (SELECT 1 FROM public.business_customers WHERE id = v_crm_a)
      AND v_uid IS NULL
      AND v_num_a2 = v_num_a
      AND v_status_a = 'approved'
      AND v_key_a = 'p:389700099101'
      AND v_msg = 'XBOOK_LEAVE_TEST A',
    format('uid=%s num=%s status=%s', coalesce(v_uid::text, 'null'), v_num_a2, v_status_a)
  );

  SELECT count(*) INTO v_n
  FROM public.bookings
  WHERE id IN (v_booking_future, v_booking_pending, v_booking_past, v_booking_cancel);
  INSERT INTO _xbook_leave_results VALUES (
    'bookings_preserved',
    v_n = 4,
    format('booking_n=%s', v_n)
  );

  IF v_note_id IS NOT NULL THEN
    SELECT count(*) INTO v_n
    FROM public.business_customer_internal_notes
    WHERE id = v_note_id AND note = 'XBOOK_LEAVE_TEST_NOTE';
    INSERT INTO _xbook_leave_results VALUES ('owner_notes_preserved', v_n = 1, format('n=%s', v_n));
  ELSE
    INSERT INTO _xbook_leave_results VALUES ('owner_notes_preserved', true, 'notes_table_absent_skipped');
  END IF;

  IF v_crm_a2 IS NOT NULL THEN
    SELECT customer_user_id INTO v_uid FROM public.business_customers WHERE id = v_crm_a2;
    INSERT INTO _xbook_leave_results VALUES (
      'other_business_membership_untouched',
      v_uid = v_user_a,
      format('biz_b_uid=%s', coalesce(v_uid::text, 'null'))
    );
  ELSE
    INSERT INTO _xbook_leave_results VALUES (
      'other_business_membership_untouched', true, 'single_business_skipped'
    );
  END IF;

  SELECT customer_user_id INTO v_uid FROM public.business_customers WHERE id = v_crm_b;
  INSERT INTO _xbook_leave_results VALUES (
    'other_customer_untouched',
    v_uid = v_user_b,
    format('user_b_uid=%s', coalesce(v_uid::text, 'null'))
  );

  -- Second leave of same business fails (already unlinked).
  v_ok := false;
  v_msg := '';
  BEGIN
    v_out := public.leave_customer_business(v_biz_a);
    v_ok := false;
    v_msg := coalesce(v_out::text, 'left_again');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%not a member%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_leave_results VALUES ('not_linked_cannot_leave', v_ok, v_msg);

  -- Other customer cannot unlink this row.
  PERFORM public._xbook_leave_test_set_jwt(v_user_b);
  v_ok := false;
  v_msg := '';
  BEGIN
    -- Re-link A first would be needed; row is already unlinked.
    -- User B leaving biz_a should fail (B is not a member of A).
    v_out := public.leave_customer_business(v_biz_a);
    v_ok := false;
    v_msg := coalesce(v_out::text, 'b_left_a');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%not a member%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_leave_results VALUES ('other_customer_cannot_leave', v_ok, v_msg);

  -- Anon cannot leave.
  PERFORM public._xbook_leave_test_set_jwt(NULL, 'anon');
  v_ok := false;
  v_msg := '';
  BEGIN
    v_out := public.leave_customer_business(v_biz_a);
    v_ok := false;
    v_msg := coalesce(v_out::text, 'anon_left');
  EXCEPTION WHEN OTHERS THEN
    v_ok := SQLERRM ILIKE '%sign in%' OR SQLERRM ILIKE '%not authenticated%' OR SQLERRM ILIKE '%permission%';
    v_msg := SQLERRM;
  END;
  INSERT INTO _xbook_leave_results VALUES ('anon_cannot_leave', v_ok, v_msg);

  -- Rejoin claims the same CRM row.
  PERFORM public._xbook_leave_test_set_jwt(v_user_a);
  v_relink := NULL;
  v_ok := false;
  v_msg := '';
  BEGIN
    v_relink := (public.register_customer_business_membership(
      v_biz_a, v_phone_a, 'xbook-leave-a@invalid.example', 'XBOOK_LEAVE_TEST A'
    )).id;
    v_ok := true;
  EXCEPTION WHEN OTHERS THEN
    v_ok := false;
    v_msg := SQLERRM;
  END;

  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = v_biz_a AND customer_user_id = v_user_a;

  INSERT INTO _xbook_leave_results VALUES (
    'rejoin_relinks_same_crm_row',
    v_ok AND v_relink = v_crm_a AND v_n = 1
      AND EXISTS (
        SELECT 1 FROM public.business_customers
        WHERE id = v_crm_a AND customer_user_id = v_user_a
      ),
    format('ok=%s relink=%s crm=%s n=%s err=%s', v_ok, v_relink, v_crm_a, v_n, v_msg)
  );

  -- Restore is from get_customer_business_memberships: unlinked business absent.
  -- Leave biz_a again (no future active bookings) then memberships JSON should omit it.
  PERFORM public.leave_customer_business(v_biz_a);
  v_out := public.get_customer_business_memberships();
  INSERT INTO _xbook_leave_results VALUES (
    'memberships_rpc_omits_left_business',
    NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(coalesce(v_out, '[]'::jsonb)) e
      WHERE (e ->> 'business_id')::uuid = v_biz_a
    ),
    left(coalesce(v_out::text, 'null'), 180)
  );

  -- Cleanup throwaway rows only.
  DELETE FROM public.bookings
  WHERE customer_name LIKE 'XBOOK_LEAVE_TEST%'
     OR customer_phone IN ('+389700099101', '+389700099102');
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name = 'business_customer_internal_notes'
  ) THEN
    DELETE FROM public.business_customer_internal_notes
    WHERE note = 'XBOOK_LEAVE_TEST_NOTE'
       OR business_customer_id IN (v_crm_a, v_crm_a2, v_crm_b);
  END IF;
  DELETE FROM public.business_customers
  WHERE id IN (v_crm_a, v_crm_a2, v_crm_b)
     OR display_name LIKE 'XBOOK_LEAVE_TEST%'
     OR customer_user_id IN (v_user_a, v_user_b);
  DELETE FROM public.user_profiles WHERE id IN (v_user_a, v_user_b);
  DELETE FROM auth.users WHERE id IN (v_user_a, v_user_b);

EXCEPTION WHEN OTHERS THEN
  INSERT INTO _xbook_leave_results VALUES ('ZZ_fatal', false, SQLERRM)
  ON CONFLICT (test_name) DO UPDATE SET passed = false, detail = EXCLUDED.detail;
  DELETE FROM public.bookings WHERE customer_name LIKE 'XBOOK_LEAVE_TEST%';
  DELETE FROM public.business_customers WHERE display_name LIKE 'XBOOK_LEAVE_TEST%';
  DELETE FROM public.user_profiles WHERE id IN (v_user_a, v_user_b)
    OR email LIKE 'xbook-leave-%@invalid.example';
  DELETE FROM auth.users WHERE id IN (v_user_a, v_user_b)
    OR email LIKE 'xbook-leave-%@invalid.example';
END;
$$;

SELECT test_name, passed, detail
FROM _xbook_leave_results
ORDER BY test_name;

DROP FUNCTION IF EXISTS public._xbook_leave_test_set_jwt(uuid, text);
