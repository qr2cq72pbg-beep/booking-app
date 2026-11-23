-- =============================================================================
-- Tests for supabase-staff-access-v1.sql (employee access, Phase F3)
-- =============================================================================
-- Runs inside BEGIN … ROLLBACK with synthetic data only. Intended for the
-- local / staging copy of the live schema (inserts test rows into auth.users).
-- Every check prints "ok - …"; the first failure aborts with "FAIL - …".
-- =============================================================================

BEGIN;

CREATE FUNCTION pg_temp.act_as(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true),
         set_config('request.jwt.claim.role', CASE WHEN p_uid IS NULL THEN 'anon' ELSE 'authenticated' END, true),
         set_config('request.jwt.claims',
           CASE WHEN p_uid IS NULL THEN '{"role":"anon"}'
                ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
$$;

CREATE FUNCTION pg_temp.expect_error(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(p_expect) IN lower(SQLERRM)) > 0 THEN
      RAISE NOTICE 'ok - %', p_label;
      RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL - % (unexpected error: %)', p_label, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL - % (no error, expected "%")', p_label, p_expect;
END;
$$;

CREATE FUNCTION pg_temp.ok(p_label text, p_cond boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL - %', p_label;
  END IF;
  RAISE NOTICE 'ok - %', p_label;
END;
$$;

GRANT EXECUTE ON FUNCTION pg_temp.act_as(uuid), pg_temp.expect_error(text, text, text), pg_temp.ok(text, boolean)
  TO anon, authenticated, service_role;

CREATE TEMP TABLE t (k text PRIMARY KEY, v text);
GRANT SELECT, INSERT, UPDATE ON pg_temp.t TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Fixtures: business A (Mirjana, Silvana), business B (Bob).
-- Bookings on day D: Mirjana 10:00, Silvana 11:00, legacy without staff 12:00,
-- cancelled Mirjana 13:00. One booking in business B.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  a  uuid := 'f3000000-0000-4000-8000-00000000000a';
  b  uuid := 'f3000000-0000-4000-8000-00000000000b';
  ea uuid := 'f3000000-0000-4000-8000-0000000000e1';   -- Mirjana's employee account
  cu uuid := 'f3000000-0000-4000-8000-0000000000c1';   -- a customer account
  d  date := current_date + 3;
BEGIN
  -- Fixtures are written as the server (passes the existing booking caller check).
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
    (a, 'f3-owner-a@test.invalid', '{}'), (b, 'f3-owner-b@test.invalid', '{}'),
    (ea, 'staff-f3@staff.test.invalid', '{"gt_account":"staff"}'), (cu, 'f3-customer@test.invalid', '{}');
  INSERT INTO public.user_profiles (id, email, role) VALUES (cu, 'f3-customer@test.invalid', 'customer');
  INSERT INTO public.business_settings (business_id, business_slug, business_name, timezone)
  VALUES (a, 'f3-test-a', 'F3 Salon', 'Europe/Skopje'), (b, 'f3-test-b', 'F3 Other', 'Europe/Skopje');
  INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
  VALUES (a, 'complimentary', current_date - 1), (b, 'complimentary', current_date - 1);
  INSERT INTO public.services (id, business_id, name, duration, price) VALUES
    ('f3000000-0000-4000-8000-0000000005a1', a, 'Makeup', 60, 1200),
    ('f3000000-0000-4000-8000-0000000005b1', b, 'Other', 30, 100);
  INSERT INTO public.staff_members (id, business_id, name, role, active) VALUES
    ('f3000000-0000-4000-8000-00000000000d', a, 'Mirjana', 'Makeup', true),
    ('f3000000-0000-4000-8000-00000000000e', a, 'Silvana', 'Massage', true),
    ('f3000000-0000-4000-8000-0000000000b0', b, 'Bob', NULL, true);
  INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, customer_email, notes, booking_status, staff_id, booking_price, manage_token)
  VALUES
    (a, 'f3000000-0000-4000-8000-0000000005a1', 'Makeup', d::text, '10:00', 60, 'Ana', '+38970111111', 'ana@test.invalid',
     'Allergic to latex', 'Confirmed', 'f3000000-0000-4000-8000-00000000000d', 1200, 'tok-1'),
    (a, 'f3000000-0000-4000-8000-0000000005a1', 'Makeup', d::text, '11:00', 60, 'Bea', '+38970222222', NULL,
     NULL, 'Pending', 'f3000000-0000-4000-8000-00000000000e', 1200, 'tok-2'),
    (a, 'f3000000-0000-4000-8000-0000000005a1', 'Makeup', d::text, '12:00', 60, 'Legacy', '+38970333333', NULL,
     NULL, 'Confirmed', NULL, 1200, 'tok-3'),
    (a, 'f3000000-0000-4000-8000-0000000005a1', 'Makeup', d::text, '13:00', 60, 'Cancelled Cleo', '+38970444444', NULL,
     NULL, 'Cancelled', 'f3000000-0000-4000-8000-00000000000d', 1200, 'tok-4'),
    (b, 'f3000000-0000-4000-8000-0000000005b1', 'Other', d::text, '10:00', 30, 'Other biz', '+38970555555', NULL,
     NULL, 'Confirmed', 'f3000000-0000-4000-8000-0000000000b0', 100, 'tok-5');
  INSERT INTO pg_temp.t VALUES ('a', a), ('b', b), ('ea', ea), ('cu', cu), ('day', d::text),
    ('mirjana', 'f3000000-0000-4000-8000-00000000000d'), ('silvana', 'f3000000-0000-4000-8000-00000000000e'),
    ('bob', 'f3000000-0000-4000-8000-0000000000b0');
END $$;

-- ---------------------------------------------------------------------------
-- 1) Existing staff rows are untouched
-- ---------------------------------------------------------------------------
SELECT pg_temp.ok('existing staff: no access, own scope, no account',
  (SELECT bool_and(access_enabled = false AND access_scope = 'own' AND access_user_id IS NULL)
   FROM public.staff_members WHERE business_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'a')));

-- ---------------------------------------------------------------------------
-- 2) Owners cannot link accounts themselves; they can only clear them
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.expect_error('owner cannot attach an auth account to a staff row',
  $q$UPDATE public.staff_members SET access_user_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'cu')
     WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')$q$, 'can only be linked by GT Termin');
SELECT pg_temp.expect_error('owner cannot insert a staff row with an account',
  $q$INSERT INTO public.staff_members (business_id, name, access_user_id)
     VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), 'X', (SELECT v::uuid FROM pg_temp.t WHERE k = 'cu'))$q$,
  'can only be linked by GT Termin');
DO $$ BEGIN
  UPDATE public.staff_members SET name = 'Mirjana' WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana');
  PERFORM pg_temp.ok('ordinary staff edits by the owner still work', true);
END $$;
SELECT pg_temp.ok('owner sets Silvana to "all appointments"',
  (public.set_staff_access_scope((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), 'all') ->> 'scope') = 'all');
SELECT pg_temp.expect_error('owner A cannot change B''s staff',
  $q$SELECT public.set_staff_access_scope((SELECT v::uuid FROM pg_temp.t WHERE k = 'bob'), 'all')$q$, 'not found');
SELECT pg_temp.expect_error('invalid scope rejected',
  $q$SELECT public.set_staff_access_scope((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), 'everything')$q$,
  'Invalid access setting');
SELECT pg_temp.expect_error('owner cannot read pairing codes',
  $q$SELECT count(*) FROM public.staff_access_codes$q$, 'permission denied');
SELECT pg_temp.expect_error('owner cannot call server-only helpers',
  $q$SELECT public._staff_access_redeem_begin('x')$q$, 'permission denied');
RESET ROLE;

SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'cu'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_error('a customer cannot change access settings',
  $q$SELECT public.set_staff_access_scope((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), 'own')$q$,
  'Only the business owner');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 3) Pairing code lifecycle (server helpers, as service_role)
-- ---------------------------------------------------------------------------
SET LOCAL ROLE service_role;
SELECT pg_temp.act_as(NULL);
SELECT public._issue_staff_access_code_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'),
  repeat('a', 64), now() + interval '1 day', (SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.ok('issuing a code enables access',
  (SELECT access_enabled FROM public.staff_members WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')));
SELECT public._issue_staff_access_code_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'),
  repeat('b', 64), now() + interval '1 day', (SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.ok('a new code voids the previous one',
  NOT ((public._staff_access_redeem_begin(repeat('a', 64)) ->> 'ok')::boolean));
SELECT pg_temp.ok('unknown code is rejected', NOT ((public._staff_access_redeem_begin(repeat('z', 64)) ->> 'ok')::boolean));
SELECT pg_temp.expect_error('issuing for another business''s staff is rejected',
  $q$SELECT public._issue_staff_access_code_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'),
       (SELECT v::uuid FROM pg_temp.t WHERE k = 'bob'), repeat('c', 64), now() + interval '1 day', NULL)$q$, 'not found');

DO $$ DECLARE r jsonb; l jsonb; BEGIN
  r := public._staff_access_redeem_begin(repeat('b', 64));
  PERFORM pg_temp.ok('valid code returns the staff member', (r ->> 'ok')::boolean
    AND r ->> 'staff_id' = (SELECT v FROM pg_temp.t WHERE k = 'mirjana') AND r ->> 'access_user_id' IS NULL);
  l := public._staff_access_link_user((r ->> 'staff_id')::uuid, (SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
  PERFORM pg_temp.ok('server links the employee account', (l ->> 'linked_new')::boolean);
  l := public._staff_access_link_user((r ->> 'staff_id')::uuid, (SELECT v::uuid FROM pg_temp.t WHERE k = 'cu'));
  PERFORM pg_temp.ok('a second device reuses the same account',
    NOT (l ->> 'linked_new')::boolean AND l ->> 'access_user_id' = (SELECT v FROM pg_temp.t WHERE k = 'ea'));
  PERFORM pg_temp.ok('code is consumed exactly once',
    public._staff_access_redeem_finish((r ->> 'code_id')::uuid) AND NOT public._staff_access_redeem_finish((r ->> 'code_id')::uuid));
  PERFORM pg_temp.ok('a consumed code cannot be reused', NOT (public._staff_access_redeem_begin(repeat('b', 64)) ->> 'ok')::boolean);
END $$;

-- Expired code
SELECT public._issue_staff_access_code_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'),
  repeat('d', 64), now() + interval '1 day', NULL);
UPDATE public.staff_access_codes SET expires_at = now() - interval '1 minute' WHERE code_hmac = repeat('d', 64);
SELECT pg_temp.ok('an expired code is rejected', NOT (public._staff_access_redeem_begin(repeat('d', 64)) ->> 'ok')::boolean);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 4) Employee agenda: own scope (Mirjana)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE agenda (k text PRIMARY KEY, v jsonb);
GRANT SELECT, INSERT ON pg_temp.agenda TO authenticated;
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
INSERT INTO pg_temp.agenda SELECT 'own', public.get_staff_agenda(current_date, current_date + 7);

SELECT pg_temp.ok('own scope: only Mirjana''s appointments (incl. her cancelled one)',
  (SELECT jsonb_array_length(v -> 'bookings') FROM pg_temp.agenda WHERE k = 'own') = 2
  AND (SELECT bool_and(x ->> 'staff_id' = (SELECT v FROM pg_temp.t WHERE k = 'mirjana'))
       FROM pg_temp.agenda, jsonb_array_elements(v -> 'bookings') x WHERE k = 'own'));
SELECT pg_temp.ok('agenda shows time, duration, customer, service, staff, status, notes',
  (SELECT x ->> 'time' = '10:00' AND (x ->> 'duration_minutes')::int = 60 AND x ->> 'customer_name' = 'Ana'
          AND x ->> 'service_name' = 'Makeup' AND x ->> 'staff_name' = 'Mirjana' AND x ->> 'status' = 'Confirmed'
          AND x ->> 'notes' = 'Allergic to latex'
   FROM pg_temp.agenda, jsonb_array_elements(v -> 'bookings') x WHERE k = 'own' AND x ->> 'time' = '10:00'));
SELECT pg_temp.ok('no price, phone, e-mail, manage token or customer id in the response',
  NOT EXISTS (
    SELECT 1 FROM pg_temp.agenda, jsonb_array_elements(v -> 'bookings') x, jsonb_object_keys(x) key
    WHERE k = 'own' AND key IN ('booking_price', 'price', 'customer_phone', 'phone', 'customer_email', 'email',
                                'manage_token', 'customer_user_id', 'booking_ref'))
  AND position('38970' IN (SELECT v::text FROM pg_temp.agenda WHERE k = 'own')) = 0
  AND position('1200' IN (SELECT v::text FROM pg_temp.agenda WHERE k = 'own')) = 0);
SELECT pg_temp.ok('agenda includes business name, timezone and the member',
  (SELECT v -> 'business' ->> 'name' = 'F3 Salon' AND v -> 'business' ->> 'timezone' = 'Europe/Skopje'
          AND v -> 'staff' ->> 'name' = 'Mirjana' AND v ->> 'scope' = 'own' FROM pg_temp.agenda WHERE k = 'own'));

-- Direct table access stays closed for employees.
SELECT pg_temp.ok('employee reads 0 rows from bookings, staff, services, business settings',
  (SELECT count(*) FROM public.bookings_api) = 0 AND (SELECT count(*) FROM public.staff_members) = 0
  AND (SELECT count(*) FROM public.services) = 0 AND (SELECT count(*) FROM public.business_settings) = 0);
SELECT pg_temp.expect_error('employee cannot change access settings',
  $q$SELECT public.set_staff_access_scope((SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'), 'all')$q$, 'Only the business owner');
SELECT pg_temp.expect_error('employee cannot create bookings',
  $q$SELECT public.create_booking((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), 'f3000000-0000-4000-8000-0000000005a1',
       (SELECT v::date FROM pg_temp.t WHERE k = 'day'), '15:00', 'X', '+3897', NULL, NULL,
       (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'))$q$, 'requires an account to book');
SELECT pg_temp.expect_error('employee cannot read pairing codes',
  $q$SELECT count(*) FROM public.staff_access_codes$q$, 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 5) All-appointments scope (owner switches Mirjana to "all")
-- ---------------------------------------------------------------------------
UPDATE public.staff_members SET access_scope = 'all' WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
INSERT INTO pg_temp.agenda SELECT 'all', public.get_staff_agenda(current_date, current_date + 7);
SELECT pg_temp.ok('all scope: every appointment of the business, never another business',
  (SELECT jsonb_array_length(v -> 'bookings') FROM pg_temp.agenda WHERE k = 'all') = 4
  AND position('Other biz' IN (SELECT v::text FROM pg_temp.agenda WHERE k = 'all')) = 0);
SELECT pg_temp.ok('all scope marks which appointments are mine',
  (SELECT count(*) FROM pg_temp.agenda, jsonb_array_elements(v -> 'bookings') x
   WHERE k = 'all' AND (x ->> 'is_mine')::boolean) = 2);
SELECT pg_temp.ok('range is capped at 62 days',
  (SELECT (v ->> 'to')::date - (v ->> 'from')::date FROM (SELECT public.get_staff_agenda(current_date, current_date + 400) AS v) z) = 62);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6) Access ends immediately
-- ---------------------------------------------------------------------------
UPDATE public.staff_members SET active = false WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
SELECT pg_temp.expect_error('deactivated member loses access at once',
  $q$SELECT public.get_staff_agenda()$q$, 'not active');
RESET ROLE;
UPDATE public.staff_members SET active = true WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana');

SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.ok('owner revoke does not reveal the auth account id',
  NOT ((public.revoke_staff_access((SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'))) ? 'previous_user_id'));
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
SELECT pg_temp.expect_error('revoked member loses access at once',
  $q$SELECT public.get_staff_agenda()$q$, 'not active');
RESET ROLE;
SELECT pg_temp.ok('revoke unlinks the account and switches access off',
  (SELECT access_user_id IS NULL AND NOT access_enabled FROM public.staff_members
   WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')));

SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'cu'));
SELECT pg_temp.expect_error('a customer gets no agenda', $q$SELECT public.get_staff_agenda()$q$, 'not active');
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.expect_error('an owner gets no employee agenda', $q$SELECT public.get_staff_agenda()$q$, 'not active');
RESET ROLE;
SELECT pg_temp.act_as(NULL);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error('anonymous cannot call the agenda', $q$SELECT public.get_staff_agenda()$q$, 'permission denied');
RESET ROLE;

-- Revoke core (server) returns the account id so the Edge Function can delete it.
SET LOCAL ROLE service_role;
SELECT public._issue_staff_access_code_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'),
  repeat('e', 64), now() + interval '1 day', NULL);
SELECT public._staff_access_link_user((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'ea'));
SELECT pg_temp.ok('server revoke returns the previous account and voids codes',
  (public._revoke_staff_access_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'))
     ->> 'previous_user_id') = (SELECT v FROM pg_temp.t WHERE k = 'ea'));
SELECT pg_temp.ok('voided code no longer works', NOT (public._staff_access_redeem_begin(repeat('e', 64)) ->> 'ok')::boolean);
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 7) F4 preparation: the visibility rule
-- ---------------------------------------------------------------------------
DO $$ DECLARE s public.staff_members; BEGIN
  SELECT * INTO s FROM public.staff_members WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana');
  s.access_scope := 'own';
  PERFORM pg_temp.ok('own: own booking yes, colleague and legacy no',
    public._staff_can_see_booking(s, s.id) AND NOT public._staff_can_see_booking(s, (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'))
    AND NOT public._staff_can_see_booking(s, NULL));
  s.access_scope := 'all';
  PERFORM pg_temp.ok('all: colleague and legacy yes',
    public._staff_can_see_booking(s, (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana')) AND public._staff_can_see_booking(s, NULL));
END $$;

SELECT 'ALL TESTS PASSED' AS result;

ROLLBACK;
