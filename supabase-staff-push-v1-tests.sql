-- =============================================================================
-- Tests for supabase-staff-push-v1.sql (employee push, Phase F4)
-- =============================================================================
-- Requires F1 + F3 + F4 applied. Runs inside BEGIN … ROLLBACK with synthetic
-- data only (inserts test rows into auth.users). Prints "ok - …" per check.
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
GRANT EXECUTE ON FUNCTION pg_temp.act_as(uuid), pg_temp.as_server(), pg_temp.expect_error(text, text, text), pg_temp.ok(text, boolean)
  TO anon, authenticated, service_role;

CREATE TEMP TABLE t (k text PRIMARY KEY, v text);
GRANT SELECT, INSERT ON pg_temp.t TO authenticated, service_role;

-- Events per (staff name, type) for one booking.
CREATE FUNCTION pg_temp.events(p_booking uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(sm.name || ':' || e.event_type, ',' ORDER BY sm.name, e.event_type), '')
  FROM public.staff_push_events e JOIN public.staff_members sm ON sm.id = e.staff_id
  WHERE e.booking_id = p_booking;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures. Business A: Mirjana (own, linked), Silvana (all, linked),
-- Elena (no access), Kiki (own, linked but inactive). Business B: Bob (all).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  a uuid := 'f4000000-0000-4000-8000-00000000000a';
  b uuid := 'f4000000-0000-4000-8000-00000000000b';
  d date := current_date + 5;
BEGIN
  PERFORM pg_temp.as_server();
  INSERT INTO auth.users (id, email) VALUES
    (a, 'f4-owner-a@test.invalid'), (b, 'f4-owner-b@test.invalid'),
    ('f4000000-0000-4000-8000-0000000000e1', 'm@staff.test.invalid'), ('f4000000-0000-4000-8000-0000000000e2', 's@staff.test.invalid'),
    ('f4000000-0000-4000-8000-0000000000e4', 'k@staff.test.invalid'), ('f4000000-0000-4000-8000-0000000000e9', 'bob@staff.test.invalid'),
    ('f4000000-0000-4000-8000-0000000000c1', 'cust@test.invalid');
  INSERT INTO public.business_settings (business_id, business_slug, business_name, timezone, working_days, work_start, work_end)
  VALUES (a, 'f4-a', 'F4 A', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00'),
         (b, 'f4-b', 'F4 B', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00');
  INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
  VALUES (a, 'complimentary', current_date - 1), (b, 'complimentary', current_date - 1);
  INSERT INTO public.services (id, business_id, name, duration, price) VALUES
    ('f4000000-0000-4000-8000-0000000005a1', a, 'Makeup', 60, 1200), ('f4000000-0000-4000-8000-0000000005b1', b, 'Other', 30, 100);
  INSERT INTO public.staff_members (id, business_id, name, active, access_enabled, access_scope, access_user_id) VALUES
    ('f4000000-0000-4000-8000-00000000000d', a, 'Mirjana', true, true, 'own', 'f4000000-0000-4000-8000-0000000000e1'),
    ('f4000000-0000-4000-8000-00000000000e', a, 'Silvana', true, true, 'all', 'f4000000-0000-4000-8000-0000000000e2'),
    ('f4000000-0000-4000-8000-00000000000f', a, 'Elena', true, false, 'own', NULL),
    ('f4000000-0000-4000-8000-000000000010', a, 'Kiki', false, true, 'own', 'f4000000-0000-4000-8000-0000000000e4'),
    ('f4000000-0000-4000-8000-0000000000b0', b, 'Bob', true, true, 'all', 'f4000000-0000-4000-8000-0000000000e9');
  INSERT INTO pg_temp.t VALUES ('a', a), ('b', b), ('day', d::text),
    ('m', 'f4000000-0000-4000-8000-00000000000d'), ('s', 'f4000000-0000-4000-8000-00000000000e'),
    ('e', 'f4000000-0000-4000-8000-00000000000f'), ('k', 'f4000000-0000-4000-8000-000000000010'),
    ('um', 'f4000000-0000-4000-8000-0000000000e1'), ('us', 'f4000000-0000-4000-8000-0000000000e2'),
    ('cust', 'f4000000-0000-4000-8000-0000000000c1'), ('svc', 'f4000000-0000-4000-8000-0000000005a1');
END $$;

-- The owner books through the unchanged create_booking (all triggers run).
CREATE FUNCTION pg_temp.book(p_time text, p_staff text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r public.bookings;
BEGIN
  PERFORM pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
  SELECT * INTO r FROM public.create_booking((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'svc'),
    (SELECT v::date FROM pg_temp.t WHERE k = 'day'), p_time::time, 'Ana', '+38970111111', NULL, NULL,
    (SELECT v::uuid FROM pg_temp.t WHERE k = p_staff), NULL, 'Confirmed');
  RETURN r.id;
END $$;

-- ---------------------------------------------------------------------------
-- 1) New booking
-- ---------------------------------------------------------------------------
DO $$ DECLARE v_id uuid; BEGIN
  v_id := pg_temp.book('09:00', 'm');
  INSERT INTO pg_temp.t VALUES ('bk', v_id::text);
  PERFORM pg_temp.ok('new booking for Mirjana → Mirjana (own) + Silvana (all); not Elena, Kiki or other business',
    pg_temp.events(v_id) = 'Mirjana:new,Silvana:new'
    AND NOT EXISTS (SELECT 1 FROM public.staff_push_events WHERE business_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'b')));
  PERFORM pg_temp.ok('payload has date/time/service only, no customer data or price',
    (SELECT bool_and(NOT (payload ? 'customer_name') AND NOT (payload::text ~ 'Ana|38970|1200') AND payload ->> 'time' = '09:00'
                     AND payload ->> 'service' = 'Makeup')
     FROM public.staff_push_events WHERE booking_id = v_id));
END $$;

-- ---------------------------------------------------------------------------
-- 2) Updates
-- ---------------------------------------------------------------------------
DO $$ DECLARE v_id uuid := (SELECT v::uuid FROM pg_temp.t WHERE k = 'bk'); BEGIN
  PERFORM pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
  UPDATE public.bookings_api SET notes = 'x' WHERE bookings_api.id = v_id;
  UPDATE public.bookings_api SET booking_status = 'Pending' WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('notes / status edits send nothing', pg_temp.events(v_id) = 'Mirjana:new,Silvana:new');

  UPDATE public.bookings_api SET time = '11:00' WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('reschedule → Mirjana + Silvana "rescheduled" with old slot',
    pg_temp.events(v_id) = 'Mirjana:new,Mirjana:rescheduled,Silvana:new,Silvana:rescheduled'
    AND (SELECT payload ->> 'old_time' FROM public.staff_push_events WHERE booking_id = v_id AND event_type = 'rescheduled' LIMIT 1) = '09:00');

  UPDATE public.bookings_api SET staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'e') WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('reassign Mirjana → Elena: Mirjana "unassigned", Silvana "reassigned", Elena (no access) nothing',
    (SELECT count(*) FROM public.staff_push_events WHERE booking_id = v_id AND event_type = 'unassigned'
       AND staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm')) = 1
    AND (SELECT count(*) FROM public.staff_push_events WHERE booking_id = v_id AND event_type = 'reassigned') = 1
    AND NOT EXISTS (SELECT 1 FROM public.staff_push_events WHERE staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'e')));

  UPDATE public.bookings_api SET staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm') WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('reassign back to Mirjana: Mirjana "assigned"',
    (SELECT count(*) FROM public.staff_push_events WHERE booking_id = v_id AND event_type = 'assigned'
       AND staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm')) = 1);

  UPDATE public.bookings_api SET booking_status = 'Cancelled' WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('cancel → Mirjana + Silvana "cancelled"',
    (SELECT count(*) FROM public.staff_push_events WHERE booking_id = v_id AND event_type = 'cancelled') = 2);
  UPDATE public.bookings_api SET notes = 'after cancel' WHERE bookings_api.id = v_id;
  PERFORM pg_temp.ok('edits on a cancelled booking send nothing',
    (SELECT count(*) FROM public.staff_push_events WHERE booking_id = v_id) = 10);
END $$;

-- ---------------------------------------------------------------------------
-- 3) Legacy (no staff), recurring series, revoked member, isolation
-- ---------------------------------------------------------------------------
DO $$ DECLARE v_id uuid; g uuid := gen_random_uuid(); n int; BEGIN
  PERFORM pg_temp.as_server();
  INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes, customer_name, customer_phone, booking_status, staff_id)
  VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'svc'), 'Makeup',
          (SELECT v FROM pg_temp.t WHERE k = 'day'), '15:00', 60, 'L', '+3897', 'Confirmed', NULL)
  RETURNING bookings.id INTO v_id;
  PERFORM pg_temp.ok('booking without staff → only "all" members', pg_temp.events(v_id) = 'Silvana:new');

  FOR i IN 1..3 LOOP
    INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes, customer_name, customer_phone,
      booking_status, staff_id, recurring_group_id, recurring_index, recurring_total)
    VALUES ((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'), (SELECT v::uuid FROM pg_temp.t WHERE k = 'svc'), 'Makeup',
            ((SELECT v::date FROM pg_temp.t WHERE k = 'day') + 7 * i)::text, '10:00', 60, 'R', '+3897', 'Confirmed',
            (SELECT v::uuid FROM pg_temp.t WHERE k = 'm'), g, i, 3);
  END LOOP;
  SELECT count(*) INTO n FROM public.staff_push_events e JOIN public.bookings b ON b.id = e.booking_id
  WHERE b.recurring_group_id = g AND e.staff_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm');
  PERFORM pg_temp.ok('recurring series of 3 → one push per recipient', n = 1);
  PERFORM pg_temp.ok('recurring push is marked', (SELECT bool_and((payload ->> 'recurring')::boolean)
    FROM public.staff_push_events e JOIN public.bookings b ON b.id = e.booking_id WHERE b.recurring_group_id = g));

  UPDATE public.staff_members SET access_enabled = false, access_user_id = NULL WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm');
  v_id := pg_temp.book('13:00', 'm');
  PERFORM pg_temp.ok('revoked Mirjana gets nothing, Silvana still does', pg_temp.events(v_id) = 'Silvana:new');
  UPDATE public.staff_members SET access_enabled = true, access_user_id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'um')
  WHERE id = (SELECT v::uuid FROM pg_temp.t WHERE k = 'm');
END $$;

-- ---------------------------------------------------------------------------
-- 4) A push problem never blocks a booking
-- ---------------------------------------------------------------------------
ALTER TABLE public.staff_push_events ADD CONSTRAINT f4_test_break CHECK (false) NOT VALID;
DO $$ DECLARE v_id uuid; BEGIN
  v_id := pg_temp.book('17:00', 'm');
  PERFORM pg_temp.ok('booking succeeds even when the outbox insert fails', v_id IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.bookings WHERE bookings.id = v_id) AND pg_temp.events(v_id) = '');
END $$;
ALTER TABLE public.staff_push_events DROP CONSTRAINT f4_test_break;

-- ---------------------------------------------------------------------------
-- 5) Device tokens
-- ---------------------------------------------------------------------------
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'um'));
SELECT pg_temp.ok('employee registers a device', public.upsert_staff_push_token(repeat('x', 40), 'ios', 'mk'));
SELECT pg_temp.expect_error('invalid platform rejected', $q$SELECT public.upsert_staff_push_token(repeat('y', 40), 'web', 'mk')$q$, 'Invalid push token');
SELECT pg_temp.expect_error('employee cannot read tokens', $q$SELECT count(*) FROM public.staff_push_tokens$q$, 'permission denied');
SELECT pg_temp.expect_error('employee cannot read the outbox', $q$SELECT count(*) FROM public.staff_push_events$q$, 'permission denied');
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'a'));
SELECT pg_temp.expect_error('an owner cannot register as employee', $q$SELECT public.upsert_staff_push_token(repeat('z', 40), 'ios', 'mk')$q$, 'not active');
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'cust'));
SELECT pg_temp.expect_error('a customer cannot register as employee', $q$SELECT public.upsert_staff_push_token(repeat('z', 40), 'ios', 'mk')$q$, 'not active');
SELECT pg_temp.ok('someone else cannot delete my token', NOT public.delete_staff_push_token(repeat('x', 40)));
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'us'));
SELECT pg_temp.ok('same phone signed in as Silvana: token moves to her', public.upsert_staff_push_token(repeat('x', 40), 'ios', 'en'));
RESET ROLE;
SELECT pg_temp.ok('one row per device, now owned by Silvana',
  (SELECT count(*) FROM public.staff_push_tokens WHERE device_token = repeat('x', 40)) = 1
  AND (SELECT staff_id FROM public.staff_push_tokens WHERE device_token = repeat('x', 40)) = (SELECT v::uuid FROM pg_temp.t WHERE k = 's'));
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM pg_temp.t WHERE k = 'us'));
SELECT pg_temp.ok('owner of the token can delete it on sign-out', public.delete_staff_push_token(repeat('x', 40)));
RESET ROLE;

SELECT pg_temp.ok('webhook trigger is installed on the outbox',
  EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'send-staff-booking-push' AND tgrelid = 'public.staff_push_events'::regclass));

SELECT 'ALL TESTS PASSED' AS result;

ROLLBACK;
