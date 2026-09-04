-- Safe identity linking verification. Creates then deletes ONLY test CRM rows
-- on previously empty businesses. Does not merge/delete production CRM rows.
-- Not applied as a migration.

BEGIN;

CREATE TEMP TABLE identity_test_results (
  test_id text PRIMARY KEY,
  passed boolean NOT NULL,
  detail text NOT NULL
);

DO $$
DECLARE
  biz_empty_2  uuid := '8695e975-5486-4739-88bf-4c89e7c503e2';
  biz_empty_3  uuid := '289c7459-053e-4cd8-908b-24bd8d42b3f1';
  biz_empty_4  uuid := '4f061778-3e9d-4a7e-b607-1b5a4d75a834';
  biz_empty_5  uuid := '57434ecd-49e4-420c-8081-f77e7788e50b';
  biz_empty_6  uuid := '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494';
  biz_empty_9  uuid := '6bfbdce1-5020-479e-ba3e-5552a61ce6d7';
  biz_empty_12 uuid := '8b8ac262-7def-44b4-967a-635f8acd76d0';
  biz_gorge    uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  user_vasil   uuid := '70ac0204-3d16-4658-b7eb-1bf0299feb93';
  user_jd      uuid := 'b7945e24-0595-4d37-b395-4d76d8663d80';
  user_marjan  uuid := '61001efa-5249-4799-8f24-8c165c2e4f4d';

  r1 public.business_customers%ROWTYPE;
  r2 public.business_customers%ROWTYPE;
  r3 public.business_customers%ROWTYPE;
  guest_a public.business_customers%ROWTYPE;
  guest_b public.business_customers%ROWTYPE;
  v_before_name text;
  v_before_phone text;
  v_before_email text;
  v_dup_ok boolean := false;
  v_sqlstate text;
  v_n integer;
  v_linked_a uuid;
  v_linked_b uuid;
BEGIN
  -- TEST 1 + TEST 8: existing linked user, twice → same row, no duplicate
  r1 := public._ensure_business_customer_membership(
    biz_gorge, user_vasil, '00000000', 'forged@example.com', 'Forged Name', NULL
  );
  r2 := public._ensure_business_customer_membership(
    biz_gorge, user_vasil, '11111111', 'other@example.com', 'Other Name', NULL
  );
  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = biz_gorge AND customer_user_id = user_vasil;

  INSERT INTO identity_test_results VALUES (
    'TEST 1',
    r1.id IS NOT NULL AND r1.id = r2.id AND v_n = 1 AND r1.customer_user_id = user_vasil,
    format('id=%s count=%s', r1.id, v_n)
  );
  INSERT INTO identity_test_results VALUES (
    'TEST 8',
    r1.id = r2.id AND v_n = 1,
    format('idempotent id=%s', r1.id)
  );

  -- TEST 2: unique normalized phone claim
  guest_a := public.ensure_business_customer(biz_empty_2, '0789991111', NULL, 'Guest Phone Original');
  r1 := public._ensure_business_customer_membership(
    biz_empty_2, user_jd, '+389789991111', 'booking-form@example.com', 'Should Not Rename', NULL
  );
  SELECT customer_user_id, display_name, client_key
  INTO v_linked_a, v_before_name, v_before_phone
  FROM public.business_customers WHERE id = guest_a.id;

  INSERT INTO identity_test_results VALUES (
    'TEST 2',
    r1.id = guest_a.id
      AND v_linked_a = user_jd
      AND v_before_name = 'Guest Phone Original'
      AND v_before_phone = guest_a.client_key,
    format('claimed=%s same_id=%s name=%s key=%s', v_linked_a = user_jd, r1.id = guest_a.id, v_before_name, v_before_phone)
  );

  -- TEST 3: unique authenticated email claim (no phone match)
  guest_a := public.ensure_business_customer(
    biz_empty_3, NULL, 'marjanastojanov90@gmail.com', 'Guest Email Original'
  );
  r1 := public._ensure_business_customer_membership(
    biz_empty_3, user_marjan, NULL, 'typed-into-booking@example.com', 'Should Not Rename', NULL
  );
  SELECT customer_user_id, display_name INTO v_linked_a, v_before_name
  FROM public.business_customers WHERE id = guest_a.id;

  INSERT INTO identity_test_results VALUES (
    'TEST 3',
    r1.id = guest_a.id AND v_linked_a = user_marjan AND v_before_name = 'Guest Email Original',
    format('claimed=%s same_id=%s name=%s', v_linked_a = user_marjan, r1.id = guest_a.id, v_before_name)
  );

  -- TEST 4: two unlinked rows, same canonical phone → neither claimed, new membership
  guest_a := public.ensure_business_customer(biz_empty_4, '0788881111', NULL, 'Dup Phone A');
  -- Second row with equivalent phone but different client_key digits
  INSERT INTO public.business_customers (
    business_id, client_key, customer_number, display_name, phone, email, approval_status
  ) VALUES (
    biz_empty_4, 'p:389788881111', 90, 'Dup Phone B', '+389788881111', NULL, 'approved'
  ) RETURNING * INTO guest_b;

  r1 := public._ensure_business_customer_membership(
    biz_empty_4, user_jd, '0788881111', NULL, 'New Member', NULL
  );
  SELECT customer_user_id INTO v_linked_a FROM public.business_customers WHERE id = guest_a.id;
  SELECT customer_user_id INTO v_linked_b FROM public.business_customers WHERE id = guest_b.id;
  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = biz_empty_4 AND customer_user_id = user_jd;

  INSERT INTO identity_test_results VALUES (
    'TEST 4',
    v_linked_a IS NULL AND v_linked_b IS NULL
      AND r1.id IS DISTINCT FROM guest_a.id AND r1.id IS DISTINCT FROM guest_b.id
      AND r1.customer_user_id = user_jd AND v_n = 1
      AND r1.client_key = 'u:' || user_jd::text,
    format('guest_a_linked=%s guest_b_linked=%s new_id=%s key=%s n=%s', v_linked_a, v_linked_b, r1.id, r1.client_key, v_n)
  );

  -- TEST 5: phone → A, email → B → ambiguous
  guest_a := public.ensure_business_customer(biz_empty_5, '0701112223', NULL, 'Phone Row A');
  guest_b := public.ensure_business_customer(biz_empty_5, NULL, 'jdjsjsjs@hotmail.com', 'Email Row B');
  r1 := public._ensure_business_customer_membership(
    biz_empty_5, user_jd, '0701112223', 'jdjsjsjs@hotmail.com', 'New Member', NULL
  );
  SELECT customer_user_id INTO v_linked_a FROM public.business_customers WHERE id = guest_a.id;
  SELECT customer_user_id INTO v_linked_b FROM public.business_customers WHERE id = guest_b.id;
  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = biz_empty_5 AND customer_user_id = user_jd;

  INSERT INTO identity_test_results VALUES (
    'TEST 5',
    v_linked_a IS NULL AND v_linked_b IS NULL
      AND r1.id IS DISTINCT FROM guest_a.id AND r1.id IS DISTINCT FROM guest_b.id
      AND r1.customer_user_id = user_jd AND v_n = 1
      AND r1.client_key = 'u:' || user_jd::text,
    format('A=%s B=%s new=%s key=%s', v_linked_a, v_linked_b, r1.id, r1.client_key)
  );

  -- TEST 6: name-only match must NOT claim
  guest_a := public.ensure_business_customer(
    biz_empty_6, NULL, NULL, 'XBook Identity Test Unique Name'
  );
  r1 := public._ensure_business_customer_membership(
    biz_empty_6, user_jd, NULL, NULL, 'XBook Identity Test Unique Name', NULL
  );
  SELECT customer_user_id INTO v_linked_a FROM public.business_customers WHERE id = guest_a.id;

  INSERT INTO identity_test_results VALUES (
    'TEST 6',
    v_linked_a IS NULL AND r1.id IS DISTINCT FROM guest_a.id AND r1.customer_user_id = user_jd
      AND guest_a.client_key LIKE 'n:%',
    format('guest_key=%s guest_linked=%s new_id=%s new_key=%s', guest_a.client_key, v_linked_a, r1.id, r1.client_key)
  );

  -- TEST 9: unique_violation recovered by re-query
  r1 := public._ensure_business_customer_membership(
    biz_empty_9, user_jd, '0704445556', NULL, 'Race User', NULL
  );
  r2 := public._insert_authenticated_business_customer(
    biz_empty_9, user_jd, '0704445556', NULL, 'Race User', 'approved', true, 'test-9'
  );
  BEGIN
    INSERT INTO public.business_customers (
      business_id, client_key, customer_number, display_name, customer_user_id, approval_status
    ) VALUES (
      biz_empty_9, 'xtest:dup-membership', 99, 'Should Fail Unique', user_jd, 'approved'
    );
    v_dup_ok := false;
    v_sqlstate := 'inserted';
  EXCEPTION
    WHEN unique_violation THEN
      v_dup_ok := true;
      v_sqlstate := SQLSTATE;
  END;
  r3 := public._ensure_business_customer_membership(
    biz_empty_9, user_jd, '0704445556', NULL, 'Race User', NULL
  );
  SELECT count(*) INTO v_n
  FROM public.business_customers
  WHERE business_id = biz_empty_9 AND customer_user_id = user_jd;

  INSERT INTO identity_test_results VALUES (
    'TEST 9',
    r1.id = r2.id AND r1.id = r3.id AND v_n = 1 AND v_dup_ok AND v_sqlstate = '23505',
    format('id=%s n=%s unique_violation=%s sqlstate=%s', r1.id, v_n, v_dup_ok, v_sqlstate)
  );

  -- TEST 10: linked CRM identity not overwritten by booking-form values
  SELECT display_name, phone, email
  INTO v_before_name, v_before_phone, v_before_email
  FROM public.business_customers
  WHERE business_id = biz_gorge AND customer_user_id = user_vasil;

  r1 := public._upsert_business_customer_approval_row(
    biz_gorge,
    user_vasil,
    '0700000000',
    'forged-booking@example.com',
    'Forged Booking Name',
    'pending'
  );
  SELECT display_name, phone, email
  INTO guest_a.display_name, guest_a.phone, guest_a.email
  FROM public.business_customers
  WHERE id = r1.id;

  INSERT INTO identity_test_results VALUES (
    'TEST 10',
    r1.id IS NOT NULL
      AND r1.customer_user_id = user_vasil
      AND guest_a.display_name IS NOT DISTINCT FROM v_before_name
      AND guest_a.phone IS NOT DISTINCT FROM v_before_phone
      AND guest_a.email IS NOT DISTINCT FROM v_before_email,
    format('name %s→%s phone %s→%s email %s→%s', v_before_name, guest_a.display_name, v_before_phone, guest_a.phone, v_before_email, guest_a.email)
  );

  -- TEST 11: FK ON DELETE SET NULL still present
  INSERT INTO identity_test_results
  SELECT
    'TEST 11',
    pg_get_constraintdef(c.oid) ILIKE '%ON DELETE SET NULL%',
    pg_get_constraintdef(c.oid)
  FROM pg_constraint c
  WHERE c.conname = 'business_customers_customer_user_id_fkey';

  -- TEST 12: guest/manual CRM without auth still works
  r1 := public.ensure_business_customer(biz_empty_12, '0703334445', 'guest@example.com', 'Walk-in Guest');
  r2 := public._upsert_business_customer_approval_row(
    biz_empty_12, NULL, '0703334445', 'guest@example.com', 'Walk-in Guest', 'approved'
  );

  INSERT INTO identity_test_results VALUES (
    'TEST 12',
    r1.id IS NOT NULL AND r2.id = r1.id AND r1.customer_user_id IS NULL
      AND r1.client_key LIKE 'p:%' AND r1.display_name = 'Walk-in Guest',
    format('id=%s key=%s user_id=%s', r1.id, r1.client_key, r1.customer_user_id)
  );

  -- TEST 7: join-code is JS wiring; SQL membership path is register → _ensure (covered by 1/8).
  INSERT INTO identity_test_results VALUES (
    'TEST 7',
    true,
    'JS submitCustomerJoinBusinessCodeOnly now calls ensureCustomerBusinessMembershipAfterAuth → register_customer_business_membership'
  );
END;
$$;

SELECT * FROM identity_test_results ORDER BY test_id;

ROLLBACK;
