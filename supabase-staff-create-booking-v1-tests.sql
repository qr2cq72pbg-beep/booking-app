-- =============================================================================
-- Tests for supabase-staff-create-booking-v1.sql (team member creates own appointments)
-- =============================================================================
-- Requires F1 + F3 + F4 + this migration. BEGIN … ROLLBACK, synthetic data only.
-- =============================================================================

BEGIN;

CREATE FUNCTION pg_temp.act_as(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true),
         set_config('request.jwt.claim.role', CASE WHEN p_uid IS NULL THEN 'anon' ELSE 'authenticated' END, true),
         set_config('request.jwt.claims',
           CASE WHEN p_uid IS NULL THEN '{"role":"anon"}'
                ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
$$;
CREATE FUNCTION pg_temp.as_server() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '', true),
         set_config('request.jwt.claim.role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
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
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO PUBLIC;
CREATE TEMP TABLE t (k text PRIMARY KEY, v text);
GRANT SELECT ON t TO PUBLIC;

-- Fixtures (as the server): business A with Mirjana (employee account ea) and Silvana, business B.
DO $$
DECLARE
  a  uuid := 'c5000000-0000-4000-8000-00000000000a';
  b  uuid := 'c5000000-0000-4000-8000-00000000000b';
  ea uuid := 'c5000000-0000-4000-8000-0000000000e1';
  cu uuid := 'c5000000-0000-4000-8000-0000000000c1';
  d  date := current_date + 3;
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
    (a, 'c5-owner-a@test.invalid', '{}'), (b, 'c5-owner-b@test.invalid', '{}'),
    (ea, 'staff-c5@staff.test.invalid', '{"gt_account":"staff"}'), (cu, 'c5-customer@test.invalid', '{}');
  INSERT INTO public.user_profiles (id, email, role) VALUES (cu, 'c5-customer@test.invalid', 'customer');
  INSERT INTO public.business_settings (business_id, business_slug, business_name, timezone, working_days, work_start, work_end, booking_window_weeks)
  VALUES (a, 'c5-test-a', 'C5 Salon', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00', 8),
         (b, 'c5-test-b', 'C5 Other', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00', 8);
  INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
  VALUES (a, 'complimentary', current_date - 1), (b, 'complimentary', current_date - 1);
  INSERT INTO public.services (id, business_id, name, duration, price) VALUES
    ('c5000000-0000-4000-8000-0000000005a1', a, 'Haircut', 30, 500),
    ('c5000000-0000-4000-8000-0000000005b1', b, 'Other', 30, 100);
  INSERT INTO public.staff_members (id, business_id, name, role, active) VALUES
    ('c5000000-0000-4000-8000-00000000000d', a, 'Mirjana', 'Hair', true),
    ('c5000000-0000-4000-8000-00000000000e', a, 'Silvana', 'Hair', true);
  -- Employee account linked by the server (as staff-access does).
  UPDATE public.staff_members SET access_enabled = true, access_user_id = ea, access_scope = 'own'
  WHERE id = 'c5000000-0000-4000-8000-00000000000d';
  INSERT INTO t VALUES ('a', a), ('b', b), ('ea', ea), ('cu', cu), ('day', d::text),
    ('mirjana', 'c5000000-0000-4000-8000-00000000000d'), ('silvana', 'c5000000-0000-4000-8000-00000000000e'),
    ('svc', 'c5000000-0000-4000-8000-0000000005a1'), ('svc_b', 'c5000000-0000-4000-8000-0000000005b1');
END $$;

-- ---------------------------------------------------------------------------
-- Defaults and privileges
-- ---------------------------------------------------------------------------
SELECT pg_temp.ok('existing and new staff: creating appointments is off by default',
  (SELECT bool_and(can_create_bookings = false) FROM public.staff_members WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')));
SELECT pg_temp.ok('anon cannot execute staff_create_booking',
  NOT has_function_privilege('anon', 'public.staff_create_booking(uuid,date,time,text,text,text,text)', 'EXECUTE'));
SELECT pg_temp.ok('authenticated can execute staff_create_booking',
  has_function_privilege('authenticated', 'public.staff_create_booking(uuid,date,time,text,text,text,text)', 'EXECUTE'));

-- ---------------------------------------------------------------------------
-- Permission off → refused
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.expect_error('permission off: team member cannot create',
  format($q$SELECT public.staff_create_booking(%L, %L, '10:00', 'Client One', '+38970100100')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  'not enabled');
SELECT pg_temp.ok('agenda reports the permission as off',
  (public.get_staff_agenda() -> 'staff' ->> 'can_create_bookings')::boolean = false);
-- The team member cannot switch it on for themselves.
UPDATE public.staff_members SET can_create_bookings = true WHERE id = (SELECT v::uuid FROM t WHERE k = 'mirjana');
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('team member cannot grant themselves the permission',
  (SELECT can_create_bookings FROM public.staff_members WHERE id = (SELECT v::uuid FROM t WHERE k = 'mirjana')) = false);

-- ---------------------------------------------------------------------------
-- Owner switches it on (existing RLS path)
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'a'));
UPDATE public.staff_members SET can_create_bookings = true WHERE id = (SELECT v::uuid FROM t WHERE k = 'mirjana');
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('owner switches the permission on',
  (SELECT can_create_bookings FROM public.staff_members WHERE id = (SELECT v::uuid FROM t WHERE k = 'mirjana')));

-- ---------------------------------------------------------------------------
-- Team member creates for themselves
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.ok('agenda reports the permission as on',
  (public.get_staff_agenda() -> 'staff' ->> 'can_create_bookings')::boolean = true);
CREATE TEMP TABLE made AS
  SELECT * FROM public.staff_create_booking((SELECT v::uuid FROM t WHERE k = 'svc'), (SELECT v::date FROM t WHERE k = 'day'),
          '10:00', '  Client One  ', '+38970100100', 'client1@test.invalid', 'Called by phone');
SELECT pg_temp.ok('session identity restored after the call', auth.uid() = (SELECT v::uuid FROM t WHERE k = 'ea'));
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('booking created for this team member, confirmed, in their business',
  (SELECT business_id = (SELECT v::uuid FROM t WHERE k = 'a') AND staff_id = (SELECT v::uuid FROM t WHERE k = 'mirjana')
          AND coalesce(booking_status::text, status::text) = 'Confirmed' AND customer_name = 'Client One' FROM made));
SELECT pg_temp.ok('client registered in the business customer list',
  EXISTS (SELECT 1 FROM public.business_customers bc WHERE bc.business_id = (SELECT v::uuid FROM t WHERE k = 'a')
          AND bc.phone LIKE '%70100100%'));
SELECT pg_temp.ok('no push to the team member about their own new appointment',
  NOT EXISTS (SELECT 1 FROM public.staff_push_events e WHERE e.booking_id = (SELECT id FROM made)
              AND e.staff_id = (SELECT v::uuid FROM t WHERE k = 'mirjana') AND e.event_type = 'new'));

-- Standard booking rules still apply.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.expect_error('same time again → conflict',
  format($q$SELECT public.staff_create_booking(%L, %L, '10:00', 'Client Two')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  '');
SELECT pg_temp.expect_error('service of another business refused',
  format($q$SELECT public.staff_create_booking(%L, %L, '12:00', 'Client Three')$q$,
         (SELECT v FROM t WHERE k = 'svc_b'), (SELECT v FROM t WHERE k = 'day')),
  'Service not found');
SELECT pg_temp.expect_error('past time refused',
  format($q$SELECT public.staff_create_booking(%L, %L, '10:00', 'Client Four')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (current_date - 2)::text),
  '');
SELECT pg_temp.expect_error('empty client name refused',
  format($q$SELECT public.staff_create_booking(%L, %L, '15:00', '   ')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  'client''s name');
-- The old path stays closed for team members.
SELECT pg_temp.expect_error('direct create_booking still refused for a team member',
  format($q$SELECT public.create_booking(%L, %L, %L, '16:00', 'X', '+38970000000', NULL, NULL, %L, NULL, 'Confirmed')$q$,
         (SELECT v FROM t WHERE k = 'a'), (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day'),
         (SELECT v FROM t WHERE k = 'silvana')),
  'requires an account');
-- Editing / cancelling stays owner-only.
UPDATE public.bookings SET booking_status = 'Cancelled' WHERE id = (SELECT id FROM made);
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('team member cannot cancel the appointment',
  (SELECT coalesce(booking_status::text, status::text) FROM public.bookings WHERE id = (SELECT id FROM made)) = 'Confirmed');

-- Not a team member → refused.
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'cu'));
SELECT pg_temp.expect_error('customer account cannot use the team member path',
  format($q$SELECT public.staff_create_booking(%L, %L, '17:00', 'Y')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  'not active');
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'a'));
SELECT pg_temp.expect_error('owner session is not a team member session',
  format($q$SELECT public.staff_create_booking(%L, %L, '17:00', 'Y')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  'not active');

-- Access revoked → refused even with the permission on.
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
UPDATE public.staff_members SET access_enabled = false WHERE id = (SELECT v::uuid FROM t WHERE k = 'mirjana');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.expect_error('revoked access → refused',
  format($q$SELECT public.staff_create_booking(%L, %L, '18:00', 'Z')$q$,
         (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')),
  'not active');
SET LOCAL ROLE postgres;

DO $$ BEGIN RAISE NOTICE 'ALL STAFF CREATE BOOKING TESTS PASSED'; END $$;
ROLLBACK;
