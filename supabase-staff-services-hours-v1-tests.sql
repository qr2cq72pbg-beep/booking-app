-- =============================================================================
-- Tests for supabase-staff-services-hours-v1.sql
-- =============================================================================
-- Runs entirely inside BEGIN … ROLLBACK with synthetic businesses only.
-- Intended for the local / staging copy of the live schema (it inserts test
-- rows into auth.users). Every check prints "ok - …"; the first failure
-- aborts with "FAIL - …".
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
-- Act as a signed-in user (NULL = anonymous). Sets both the legacy claim keys
-- and request.jwt.claims so it works with Supabase's auth.uid()/auth.jwt().
CREATE FUNCTION pg_temp.act_as(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true),
         set_config('request.jwt.claim.role', CASE WHEN p_uid IS NULL THEN 'anon' ELSE 'authenticated' END, true),
         set_config('request.jwt.claims',
           CASE WHEN p_uid IS NULL THEN '{"role":"anon"}'
                ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
$$;

-- Run SQL and require an error whose message contains p_expect.
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
  TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fixtures (as postgres): business A with 3 staff, business B with 1 staff.
-- Test day = a Monday at least 7 days ahead (business works Mon–Fri 09–17).
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE t (k text PRIMARY KEY, v text);
GRANT SELECT, INSERT ON pg_temp.t TO anon, authenticated;

DO $$
DECLARE
  a uuid := 'f1000000-0000-4000-8000-00000000000a';
  b uuid := 'f1000000-0000-4000-8000-00000000000b';
  d date := current_date + ((8 - EXTRACT(DOW FROM current_date)::int) % 7) + 7;
BEGIN
  INSERT INTO auth.users (id, email) VALUES (a, 'f1-owner-a@test.invalid'), (b, 'f1-owner-b@test.invalid');
  INSERT INTO public.business_settings (business_id, business_slug, business_name, work_start, work_end, working_days, timezone)
  VALUES (a, 'f1-test-a', 'F1 Test A', '09:00', '17:00', ARRAY['1','2','3','4','5'], 'Europe/Skopje'),
         (b, 'f1-test-b', 'F1 Test B', '09:00', '17:00', ARRAY['1','2','3','4','5'], 'Europe/Skopje');
  INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
  VALUES (a, 'complimentary', current_date - 1), (b, 'complimentary', current_date - 1);

  INSERT INTO public.services (id, business_id, name, duration, price) VALUES
    ('f1000000-0000-4000-8000-0000000005a1', a, 'Makeup', 60, 1200),
    ('f1000000-0000-4000-8000-0000000005a2', a, 'Massage', 30, 900),
    ('f1000000-0000-4000-8000-0000000005b1', b, 'Other', 30, 100);

  INSERT INTO public.staff_members (id, business_id, name, active, created_at) VALUES
    ('f1000000-0000-4000-8000-00000000000d', a, 'Mirjana', true, now() - interval '3 days'),
    ('f1000000-0000-4000-8000-00000000000e', a, 'Silvana', true, now() - interval '2 days'),
    ('f1000000-0000-4000-8000-00000000000f', a, 'Elena',   true, now() - interval '1 day'),
    ('f1000000-0000-4000-8000-0000000000b0', b, 'Bob',     true, now());

  INSERT INTO pg_temp.t VALUES
    ('a', a), ('b', b), ('day', d::text), ('tue', (d + 1)::text),
    ('makeup', 'f1000000-0000-4000-8000-0000000005a1'),
    ('massage', 'f1000000-0000-4000-8000-0000000005a2'),
    ('svc_b', 'f1000000-0000-4000-8000-0000000005b1'),
    ('mirjana', 'f1000000-0000-4000-8000-00000000000d'),
    ('silvana', 'f1000000-0000-4000-8000-00000000000e'),
    ('elena', 'f1000000-0000-4000-8000-00000000000f'),
    ('bob', 'f1000000-0000-4000-8000-0000000000b0');
END $$;

-- Book as the owner of A through the unchanged create_booking.
CREATE FUNCTION pg_temp.book(p_service text, p_hhmm text, p_staff text, p_day text DEFAULT 'day') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE r public.bookings;
BEGIN
  SELECT * INTO r FROM public.create_booking(
    (SELECT v::uuid FROM pg_temp.t WHERE k = 'a'),
    (SELECT v::uuid FROM pg_temp.t WHERE k = p_service),
    (SELECT v::date FROM pg_temp.t WHERE k = p_day),
    p_hhmm::time, 'Test Customer', '+38970000000', NULL, NULL,
    (SELECT v::uuid FROM pg_temp.t WHERE k = p_staff), NULL, 'Confirmed');
  RETURN r.id;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.book(text, text, text, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1) Defaults: nothing changes for existing data
-- ---------------------------------------------------------------------------
SELECT pg_temp.ok('existing staff default to all services + business hours',
  (SELECT bool_and(all_services AND uses_business_hours) FROM public.staff_members
   WHERE business_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'a')));

SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));

DO $$ DECLARE id uuid; BEGIN
  id := pg_temp.book('makeup', '09:00', 'mirjana');
  INSERT INTO pg_temp.t VALUES ('bk_m_0900', id::text);
  PERFORM pg_temp.ok('default settings: owner booking works as before', id IS NOT NULL);
END $$;

SELECT pg_temp.expect_error('business hours unchanged: 17:30 still rejected with the old message',
  $q$SELECT pg_temp.book('massage', '17:30', 'elena')$q$, 'outside working hours');

-- ---------------------------------------------------------------------------
-- 2) Service assignment
-- ---------------------------------------------------------------------------
SELECT pg_temp.ok('owner sets Mirjana to Massage only',
  (public.set_staff_services((SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'), false,
     ARRAY[(SELECT v::uuid FROM pg_temp.t WHERE k = 'massage')]) ->> 'ok')::boolean);

SELECT pg_temp.expect_error('Mirjana cannot be booked for Makeup (owner included)',
  $q$SELECT pg_temp.book('makeup', '11:00', 'mirjana')$q$, 'does not perform this service');

DO $$ BEGIN
  PERFORM pg_temp.ok('Mirjana can be booked for Massage', pg_temp.book('massage', '11:00', 'mirjana') IS NOT NULL);
END $$;

SELECT pg_temp.expect_error('empty service list is rejected',
  $q$SELECT public.set_staff_services((SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'), false, '{}')$q$,
  'at least one service');

-- ---------------------------------------------------------------------------
-- 3) Existing bookings are not disturbed (09:00 Makeup with Mirjana is now
--    "grandfathered": Mirjana no longer has Makeup)
-- ---------------------------------------------------------------------------
DO $$ DECLARE bid uuid := (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_m_0900'); BEGIN
  UPDATE public.bookings_api SET notes = 'Allergy note' WHERE id = bid;
  UPDATE public.bookings_api SET booking_status = 'Pending' WHERE id = bid;
  UPDATE public.bookings_api SET customer_name = 'Renamed Customer' WHERE id = bid;
  UPDATE public.bookings_api SET customer_phone = '+38970111222' WHERE id = bid;
  PERFORM pg_temp.ok('unrelated edits (notes, status, name, phone) on a grandfathered booking pass', true);
  PERFORM pg_temp.ok('the grandfathered booking itself is still there, unchanged slot',
    EXISTS (SELECT 1 FROM public.bookings WHERE id = bid AND time = '09:00'
            AND staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')));
END $$;

SELECT pg_temp.expect_error('moving a grandfathered booking must satisfy the current rules',
  $q$UPDATE public.bookings_api SET time = '14:00' WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_m_0900')$q$,
  'does not perform this service');

DO $$ BEGIN
  INSERT INTO pg_temp.t VALUES ('bk_e_1500', pg_temp.book('makeup', '15:00', 'elena')::text);
  UPDATE public.bookings_api SET time = '15:30' WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_e_1500');
  PERFORM pg_temp.ok('moving a booking that fits the current rules works', true);
END $$;
SELECT pg_temp.expect_error('re-assigning a booking to a staff member without that service is blocked',
  $q$UPDATE public.bookings_api SET staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')
     WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_e_1500')$q$,
  'does not perform this service');
DO $$ BEGIN
  DELETE FROM public.bookings_api WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_e_1500');
END $$;

DO $$ DECLARE bid uuid := (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_m_0900'); BEGIN
  UPDATE public.bookings_api SET booking_status = 'Cancelled' WHERE id = bid;
  PERFORM pg_temp.ok('cancelling is never blocked', true);
END $$;

SELECT pg_temp.expect_error('re-activating a cancelled booking runs the full check',
  $q$UPDATE public.bookings_api SET booking_status = 'Confirmed'
     WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_m_0900')$q$,
  'does not perform this service');

-- ---------------------------------------------------------------------------
-- 4) Individual working hours (Silvana: Monday 10–15, break 12:00–12:30)
-- ---------------------------------------------------------------------------
SELECT pg_temp.ok('owner sets Silvana''s weekly hours',
  (public.set_staff_working_hours((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), false,
     '[{"dow":1,"start":"10:00","end":"15:00","break_start":"12:00","break_end":"12:30"}]'::jsonb) ->> 'ok')::boolean);

SELECT pg_temp.expect_error('before Silvana''s start time',
  $q$SELECT pg_temp.book('massage', '09:30', 'silvana')$q$, 'outside this team member''s working hours');
SELECT pg_temp.expect_error('ending after Silvana''s end time',
  $q$SELECT pg_temp.book('makeup', '14:30', 'silvana')$q$, 'outside this team member''s working hours');
SELECT pg_temp.expect_error('during Silvana''s break',
  $q$SELECT pg_temp.book('massage', '12:15', 'silvana')$q$, 'overlaps this team member''s break');
SELECT pg_temp.expect_error('Silvana does not work Tuesday',
  $q$SELECT pg_temp.book('massage', '10:00', 'silvana', 'tue')$q$, 'does not work on this day');

DO $$ DECLARE id uuid; BEGIN
  id := pg_temp.book('massage', '10:00', 'silvana');
  INSERT INTO pg_temp.t VALUES ('bk_s_1000', id::text);
  PERFORM pg_temp.ok('inside Silvana''s hours works', id IS NOT NULL);
END $$;

SELECT pg_temp.expect_error('moving into Silvana''s break is blocked',
  $q$UPDATE public.bookings_api SET time = '12:00' WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_s_1000')$q$,
  'overlaps this team member''s break');

SELECT pg_temp.expect_error('invalid break is rejected',
  $q$SELECT public.set_staff_working_hours((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), false,
     '[{"dow":1,"start":"10:00","end":"15:00","break_start":"16:00","break_end":"16:30"}]')$q$,
  'break must be inside');
SELECT pg_temp.expect_error('no working day is rejected',
  $q$SELECT public.set_staff_working_hours((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), false, '[]')$q$,
  'at least one working day');

-- Conflict list after narrowing the hours (nothing is changed automatically).
SELECT public.set_staff_working_hours((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), false,
  '[{"dow":1,"start":"11:00","end":"15:00"}]'::jsonb);
SELECT pg_temp.ok('narrowing hours keeps the existing booking and reports it as a conflict',
  EXISTS (SELECT 1 FROM public.bookings WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_s_1000'))
  AND (SELECT count(*) FROM public.list_staff_rule_conflicts((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'))
       WHERE booking_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_s_1000')) = 1);

-- ---------------------------------------------------------------------------
-- 5) Every insert path is covered by the trigger (recurring and any future
--    path insert into the same table)
-- ---------------------------------------------------------------------------
RESET ROLE;
SELECT pg_temp.expect_error('direct insert (as used by recurring bookings) is checked too',
  $q$INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes,
       customer_name, customer_phone, booking_status, staff_id)
     VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'makeup'), 'Makeup',
       (SELECT v FROM pg_temp.t WHERE k = 'day'), '13:00', 60, 'X', '+3897', 'Confirmed',
       (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'))$q$,
  'does not perform this service');

-- Legacy booking without staff (16:00) is accepted and never checked.
DO $$ DECLARE v_id uuid; BEGIN
  INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes,
    customer_name, customer_phone, booking_status, staff_id)
  VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'massage'), 'Massage',
    (SELECT v FROM pg_temp.t WHERE k = 'day'), '16:00', 30, 'Legacy', '+3897', 'Confirmed', NULL)
  RETURNING bookings.id INTO v_id;
  INSERT INTO pg_temp.t VALUES ('bk_legacy', v_id::text);
  UPDATE public.bookings SET notes = 'legacy edit' WHERE bookings.id = v_id;
  PERFORM pg_temp.ok('legacy booking without staff: insert and edit unaffected', true);
END $$;

-- Manage-link reschedule (anonymous customer link) uses the same rules.
INSERT INTO pg_temp.t
SELECT 'token_s_1000', manage_token FROM public.bookings WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk_s_1000');
SELECT pg_temp.act_as(NULL);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error('manage-link reschedule respects staff hours',
  $q$SELECT public.reschedule_booking_by_manage_token(
       (SELECT v FROM pg_temp.t WHERE k = 'token_s_1000'),
       (SELECT v::date FROM pg_temp.t WHERE k = 'day'), '15:30')$q$,
  'working hours');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6) "Било кој слободен"
--    Makeup (60 min) at 13:00: Mirjana not qualified, Silvana (11–15) and
--    Elena (business hours) qualified.
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));

CREATE FUNCTION pg_temp.any(p_service text, p_hhmm text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r public.bookings;
BEGIN
  SELECT * INTO r FROM public.create_booking_any_staff(
    (SELECT v::uuid FROM pg_temp.t WHERE k = 'a'),
    (SELECT v::uuid FROM pg_temp.t WHERE k = p_service),
    (SELECT v::date FROM pg_temp.t WHERE k = 'day'),
    p_hhmm::time, 'Any Customer', '+38970000001', NULL, NULL, NULL, 'Confirmed');
  RETURN r.staff_id;
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.any(text, text) TO authenticated;

DO $$ DECLARE s1 uuid; s2 uuid; BEGIN
  s1 := pg_temp.any('makeup', '13:00');
  s2 := pg_temp.any('makeup', '13:00');
  PERFORM pg_temp.ok('any-staff picks two different qualified staff for the same slot',
    s1 IS NOT NULL AND s2 IS NOT NULL AND s1 <> s2
    AND s1 IN ((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'))
    AND s2 IN ((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena')));
END $$;

SELECT pg_temp.expect_error('third request for the same slot finds nobody (no double booking)',
  $q$SELECT pg_temp.any('makeup', '13:00')$q$, 'No team member is available');

SELECT pg_temp.expect_error('legacy staff-less booking at 16:00 still blocks everyone',
  $q$SELECT pg_temp.any('massage', '16:00')$q$, 'No team member is available');

-- Elena on time off 10:00–11:00; Mirjana busy? Massage 10:00: Mirjana qualified and free.
DO $$ BEGIN
  INSERT INTO public.staff_time_off (business_id, staff_id, date_from, date_to, start_time, end_time, time_off_type)
  VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'),
          (SELECT v::date FROM pg_temp.t WHERE k = 'day'), (SELECT v::date FROM pg_temp.t WHERE k = 'day'),
          '10:00', '11:00', 'personal');
  PERFORM pg_temp.ok('any-staff skips staff on time off and outside hours',
    pg_temp.any('massage', '10:00') = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'));
END $$;

-- ---------------------------------------------------------------------------
-- 7) Isolation and permissions
-- ---------------------------------------------------------------------------
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'b'));
SELECT pg_temp.ok('owner B sees none of A''s assignments or hours',
  (SELECT count(*) FROM public.staff_services) = 0 AND (SELECT count(*) FROM public.staff_working_hours) = 0);
SELECT pg_temp.expect_error('owner B cannot change A''s staff via RPC',
  $q$SELECT public.set_staff_services((SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'), true, NULL)$q$,
  'Staff member not found');
SELECT pg_temp.expect_error('owner B cannot insert rows for business A',
  $q$INSERT INTO public.staff_services (business_id, staff_id, service_id) VALUES
     ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'),
      (SELECT v::uuid FROM pg_temp.t WHERE k = 'makeup'))$q$,
  'row-level security');
SELECT pg_temp.expect_error('owner B cannot attach A''s staff under its own business id',
  $q$INSERT INTO public.staff_services (business_id, staff_id, service_id) VALUES
     ((SELECT v::uuid FROM pg_temp.t WHERE k = 'b'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'),
      (SELECT v::uuid FROM pg_temp.t WHERE k = 'svc_b'))$q$,
  'Staff member not found');
SELECT pg_temp.expect_error('owner B cannot use any-staff on business A',
  $q$SELECT pg_temp.any('massage', '09:00')$q$, 'requires an account to book');
SELECT pg_temp.expect_error('signed-in users cannot TRUNCATE the new tables',
  $q$TRUNCATE public.staff_services$q$, 'permission denied');

SELECT pg_temp.act_as(NULL);
SET LOCAL ROLE anon;
SELECT pg_temp.ok('public rules RPC returns A''s rules to anonymous visitors',
  (SELECT count(*) FROM public.get_public_staff_booking_rules((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'))) = 3
  AND (SELECT service_ids = ARRAY[(SELECT v::uuid FROM pg_temp.t WHERE k = 'massage')]
       FROM public.get_public_staff_booking_rules((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'))
       WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'))
  AND (SELECT weekly_hours -> 0 ->> 'start' = '11:00'
       FROM public.get_public_staff_booking_rules((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'))
       WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana')));
SELECT pg_temp.expect_error('anonymous cannot change assignments',
  $q$SELECT public.set_staff_services((SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'), true, NULL)$q$,
  'permission denied');
SELECT pg_temp.expect_error('anonymous cannot call any-staff booking',
  $q$SELECT public.create_booking_any_staff((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'),
       (SELECT v::uuid FROM pg_temp.t WHERE k = 'massage'), (SELECT v::date FROM pg_temp.t WHERE k = 'day'),
       '09:00', 'X', '+3897')$q$, 'permission denied');
SELECT pg_temp.expect_error('anonymous cannot read the new tables',
  $q$SELECT count(*) FROM public.staff_services$q$, 'permission denied');
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 8) Bulk helpers and cleanup on delete
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
CREATE TEMP TABLE r (k text PRIMARY KEY, v jsonb);
GRANT SELECT, INSERT ON pg_temp.r TO authenticated;
INSERT INTO pg_temp.r SELECT 'assign_all', public.assign_service_to_all_staff((SELECT v::uuid FROM pg_temp.t WHERE k = 'makeup'));
SELECT pg_temp.ok('"assign one service to all" extends only restricted staff',
  ((SELECT v FROM pg_temp.r WHERE k = 'assign_all') ->> 'added')::int = 1
  AND EXISTS (SELECT 1 FROM public.staff_services
              WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')
                AND service_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'makeup')));
INSERT INTO pg_temp.r SELECT 'all_services', public.set_staff_services((SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana'), true, NULL);
SELECT pg_temp.ok('"all services" clears the list and flag',
  ((SELECT v FROM pg_temp.r WHERE k = 'all_services') ->> 'all_services')::boolean
  AND NOT EXISTS (SELECT 1 FROM public.staff_services WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'mirjana')));
INSERT INTO pg_temp.r SELECT 'biz_hours', public.set_staff_working_hours((SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana'), true, NULL);
SELECT pg_temp.ok('"business hours" clears individual hours',
  ((SELECT v FROM pg_temp.r WHERE k = 'biz_hours') ->> 'uses_business_hours')::boolean
  AND NOT EXISTS (SELECT 1 FROM public.staff_working_hours WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'silvana')));
RESET ROLE;

DO $$ BEGIN
  PERFORM public._set_staff_services_core((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'),
    (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena'), false, ARRAY[(SELECT v::uuid FROM pg_temp.t WHERE k = 'massage')]);
  DELETE FROM public.staff_members WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena');
  PERFORM pg_temp.ok('deleting a staff member removes its assignments',
    NOT EXISTS (SELECT 1 FROM public.staff_services WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'elena')));
END $$;

SELECT 'ALL TESTS PASSED' AS result;

ROLLBACK;
