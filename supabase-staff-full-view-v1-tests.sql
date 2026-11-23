-- =============================================================================
-- Tests for supabase-staff-full-view-v1.sql ("Full Business View", read-only)
-- =============================================================================
-- BEGIN … ROLLBACK, synthetic data only. Prints "ok - …"; raises "FAIL - …".
-- Business A: owner a; team members Fiona ('full', account ef), Alex ('all', ea),
-- Olga ('own', eo). Business B: owner b (isolation). Customer cu.
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
-- Runs a write and requires that it changed nothing (RLS: 0 rows) or failed.
CREATE FUNCTION pg_temp.no_write(p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  BEGIN
    EXECUTE p_sql;
    GET DIAGNOSTICS n = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'ok - % (refused: %)', p_label, left(SQLERRM, 60);
    RETURN;
  END;
  IF n = 0 THEN
    RAISE NOTICE 'ok - % (0 rows)', p_label;
    RETURN;
  END IF;
  RAISE EXCEPTION 'FAIL - % (% rows written)', p_label, n;
END;
$$;
-- Calls a function and requires a refusal: an error, NULL, or an {ok:false}/not-authorized answer.
CREATE FUNCTION pg_temp.rpc_refused(p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'ok - % (refused: %)', p_label, left(SQLERRM, 60);
    RETURN;
  END;
  IF v IS NULL OR v ~* '"ok"\s*:\s*false|not.?authori[sz]ed|forbidden' THEN
    RAISE NOTICE 'ok - % (refused answer)', p_label;
    RETURN;
  END IF;
  RAISE EXCEPTION 'FAIL - % (accepted: %)', p_label, left(v, 120);
END;
$$;
-- Read that must give nothing: an error, NULL, 0 or empty.
CREATE FUNCTION pg_temp.closed(p_label text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  BEGIN
    EXECUTE p_sql INTO v;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'ok - % (refused)', p_label;
    RETURN;
  END;
  IF v IS NULL OR v IN ('0', '', '[]', '{}') THEN
    RAISE NOTICE 'ok - % (nothing returned)', p_label;
    RETURN;
  END IF;
  RAISE EXCEPTION 'FAIL - % (returned: %)', p_label, left(v, 120);
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
CREATE TEMP TABLE before_scopes AS SELECT access_scope, count(*) AS n FROM public.staff_members GROUP BY 1;
GRANT SELECT ON before_scopes TO PUBLIC;

DO $$
DECLARE
  a  uuid := 'f7000000-0000-4000-8000-00000000000a';
  b  uuid := 'f7000000-0000-4000-8000-00000000000b';
  ef uuid := 'f7000000-0000-4000-8000-0000000000e1';
  ea uuid := 'f7000000-0000-4000-8000-0000000000e2';
  eo uuid := 'f7000000-0000-4000-8000-0000000000e3';
  cu uuid := 'f7000000-0000-4000-8000-0000000000c1';
  d  date := current_date + 3;
BEGIN
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  INSERT INTO auth.users (id, email, raw_app_meta_data) VALUES
    (a, 'f7-owner-a@test.invalid', '{}'), (b, 'f7-owner-b@test.invalid', '{}'),
    (ef, 'f7-full@staff.test.invalid', '{"gt_account":"staff"}'), (ea, 'f7-all@staff.test.invalid', '{"gt_account":"staff"}'),
    (eo, 'f7-own@staff.test.invalid', '{"gt_account":"staff"}'), (cu, 'f7-customer@test.invalid', '{}');
  INSERT INTO public.user_profiles (id, email, role) VALUES (cu, 'f7-customer@test.invalid', 'customer');
  INSERT INTO public.business_settings (business_id, business_slug, business_name, timezone, working_days, work_start, work_end, booking_window_weeks)
  VALUES (a, 'f7-a', 'F7 Salon', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00', 8),
         (b, 'f7-b', 'F7 Other', 'Europe/Skopje', ARRAY['0','1','2','3','4','5','6'], '08:00', '20:00', 8);
  INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
  VALUES (a, 'complimentary', current_date - 1), (b, 'complimentary', current_date - 1);
  INSERT INTO public.services (id, business_id, name, duration, price) VALUES
    ('f7000000-0000-4000-8000-0000000005a1', a, 'Haircut', 30, 500),
    ('f7000000-0000-4000-8000-0000000005b1', b, 'Other', 30, 100);
  INSERT INTO public.staff_members (id, business_id, name, active) VALUES
    ('f7000000-0000-4000-8000-0000000000f1', a, 'Fiona', true),
    ('f7000000-0000-4000-8000-0000000000f2', a, 'Alex', true),
    ('f7000000-0000-4000-8000-0000000000f3', a, 'Olga', true),
    ('f7000000-0000-4000-8000-0000000000b1', b, 'Bob', true);
  UPDATE public.staff_members SET access_enabled = true, access_user_id = ef, access_scope = 'full' WHERE id = 'f7000000-0000-4000-8000-0000000000f1';
  UPDATE public.staff_members SET access_enabled = true, access_user_id = ea, access_scope = 'all'  WHERE id = 'f7000000-0000-4000-8000-0000000000f2';
  UPDATE public.staff_members SET access_enabled = true, access_user_id = eo, access_scope = 'own'  WHERE id = 'f7000000-0000-4000-8000-0000000000f3';
  INSERT INTO public.bookings (business_id, service_id, service_name, date, time, duration_minutes, customer_name, customer_phone,
    customer_email, booking_status, staff_id, booking_price, customer_user_id)
  VALUES
    (a, 'f7000000-0000-4000-8000-0000000005a1', 'Haircut', d::text, '10:00', 30, 'Ana', '+38970111222', 'ana@test.invalid', 'Confirmed', 'f7000000-0000-4000-8000-0000000000f2', 500, cu),
    (a, 'f7000000-0000-4000-8000-0000000005a1', 'Haircut', d::text, '11:00', 30, 'Bea', '+38970333444', NULL, 'Confirmed', 'f7000000-0000-4000-8000-0000000000f3', 500, NULL),
    (b, 'f7000000-0000-4000-8000-0000000005b1', 'Other', d::text, '10:00', 30, 'Other', '+38970555666', NULL, 'Confirmed', 'f7000000-0000-4000-8000-0000000000b1', 100, NULL);
  INSERT INTO public.business_customers (business_id, client_key, customer_number, display_name, phone, email, customer_user_id)
  VALUES (a, 'phone:+38970111222', 9001, 'Ana', '+38970111222', 'ana@test.invalid', cu),
         (b, 'phone:+38970555666', 9001, 'Other', '+38970555666', NULL, NULL);
  INSERT INTO public.business_customer_internal_notes (business_id, business_customer_id, note)
  SELECT a, bc.id, 'VIP, prefers mornings' FROM public.business_customers bc WHERE bc.business_id = a;
  INSERT INTO public.staff_time_off (business_id, staff_id, date_from, date_to, time_off_type)
  VALUES (a, 'f7000000-0000-4000-8000-0000000000f2', d + 10, d + 11, 'vacation'),
         (b, 'f7000000-0000-4000-8000-0000000000b1', d + 10, d + 11, 'vacation');
  INSERT INTO t VALUES ('a', a), ('b', b), ('ef', ef), ('ea', ea), ('eo', eo), ('cu', cu), ('day', d::text),
    ('fiona', 'f7000000-0000-4000-8000-0000000000f1'), ('alex', 'f7000000-0000-4000-8000-0000000000f2'),
    ('svc', 'f7000000-0000-4000-8000-0000000005a1');
END $$;

-- ---------------------------------------------------------------- 0) setup
SELECT pg_temp.ok('constraint accepts own / all / full',
  (SELECT count(*) FROM public.staff_members WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a') AND access_scope IN ('own','all','full')) = 3);
SELECT pg_temp.expect_error('constraint still rejects unknown levels',
  $q$UPDATE public.staff_members SET access_scope = 'admin' WHERE id = 'f7000000-0000-4000-8000-0000000000f1'$q$, 'staff_members_access_scope_ok');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.ok('helpers never return NULL for a non-reader (regression)',
  public._can_read_business((SELECT v::uuid FROM t WHERE k = 'a')) IS FALSE
  AND public._is_full_view_reader((SELECT v::uuid FROM t WHERE k = 'a')) IS FALSE);
SELECT pg_temp.act_as(NULL);
SELECT pg_temp.ok('helpers return false without a session',
  public._can_read_business((SELECT v::uuid FROM t WHERE k = 'a')) IS FALSE);
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('helpers not executable by anon',
  NOT has_function_privilege('anon', 'public._can_read_business(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public._is_full_view_reader(uuid)', 'EXECUTE'));

-- ---------------------------------------------------------------- 1) Full Business View: reads
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ef'));
SELECT pg_temp.ok('full: reads business settings of own business only',
  (SELECT count(*) FROM public.business_settings WHERE business_id IN ((SELECT v::uuid FROM t WHERE k = 'a'), (SELECT v::uuid FROM t WHERE k = 'b'))) = 1);
SELECT pg_temp.ok('full: reads all bookings of the business (with contact details)',
  (SELECT count(*) FROM public.bookings_api WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 2
  AND (SELECT count(*) FROM public.bookings_api WHERE customer_phone = '+38970333444') = 1);
SELECT pg_temp.ok('full: never sees another business''s bookings',
  (SELECT count(*) FROM public.bookings WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'b')) = 0);
SELECT pg_temp.ok('full: reads customers, services, team, time off',
  (SELECT count(*) FROM public.business_customers WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1
  AND (SELECT count(*) FROM public.services WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1
  AND (SELECT count(*) FROM public.staff_members WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 3
  AND (SELECT count(*) FROM public.staff_time_off WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1);
SELECT pg_temp.ok('full: other business customers / team / time off invisible',
  (SELECT count(*) FROM public.business_customers WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'b')) = 0
  AND (SELECT count(*) FROM public.staff_members WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'b')) = 0
  AND (SELECT count(*) FROM public.staff_time_off WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'b')) = 0);
SELECT pg_temp.ok('full: performance report (revenue) for own business',
  (public.get_business_performance_report((SELECT v::uuid FROM t WHERE k = 'a'), current_date, current_date + 30) ->> 'ok')::boolean IS DISTINCT FROM false);
SELECT pg_temp.expect_error('full: performance report of another business refused',
  format($q$SELECT public.get_business_performance_report(%L, current_date, current_date + 30)$q$, (SELECT v FROM t WHERE k = 'b')), 'Not authorized');
SELECT pg_temp.ok('full: service, staff and customer analytics work',
  public.get_business_service_analytics((SELECT v::uuid FROM t WHERE k = 'a'), current_date, current_date + 30) IS NOT NULL
  AND public.get_business_staff_analytics((SELECT v::uuid FROM t WHERE k = 'a'), current_date, current_date + 30) IS NOT NULL
  AND public.get_business_customer_analytics_overview((SELECT v::uuid FROM t WHERE k = 'a'), current_date - 30, current_date + 30) IS NOT NULL);
SELECT pg_temp.ok('full: customer internal notes readable',
  public.get_business_customer_internal_notes((SELECT v::uuid FROM t WHERE k = 'a'), 'phone:+38970111222') IS NOT NULL);
SELECT pg_temp.ok('full: time-off list is of own business only',
  (SELECT count(*) FROM public.list_staff_time_off(NULL)) = 1
  AND (SELECT bool_and(business_id = (SELECT v::uuid FROM t WHERE k = 'a')) FROM public.list_staff_time_off(NULL)));
SELECT pg_temp.ok('full: agenda shows every appointment (like all)',
  public.get_staff_agenda() ->> 'scope' = 'full' AND jsonb_array_length(public.get_staff_agenda() -> 'bookings') = 2);

-- ---------------------------------------------------------------- 2) Full Business View: no writes
SELECT pg_temp.no_write('full: cannot change business settings',
  format($q$UPDATE public.business_settings SET business_name = 'hacked' WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot add a service',
  format($q$INSERT INTO public.services (business_id, name, duration) VALUES (%L, 'x', 30)$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot change a price',
  format($q$UPDATE public.services SET price = 1 WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot delete a service',
  format($q$DELETE FROM public.services WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot cancel / move a booking',
  format($q$UPDATE public.bookings SET booking_status = 'Cancelled', time = '15:00' WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot delete a booking',
  format($q$DELETE FROM public.bookings WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot insert a booking directly',
  format($q$INSERT INTO public.bookings (business_id, service_id, date, time, customer_name, customer_phone, booking_status) VALUES (%L, %L, %L, '16:00', 'x', '+38970000000', 'Confirmed')$q$,
         (SELECT v FROM t WHERE k = 'a'), (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')));
SELECT pg_temp.no_write('full: cannot change own level (staff_members)',
  format($q$UPDATE public.staff_members SET access_scope = 'full', can_create_bookings = true WHERE id = %L$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.no_write('full: cannot edit customers',
  format($q$UPDATE public.business_customers SET is_vip = true, phone = 'x' WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.no_write('full: cannot delete customers',
  format($q$DELETE FROM public.business_customers WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.expect_error('full: no direct access to the internal-notes table',
  $q$SELECT count(*) FROM public.business_customer_internal_notes$q$, 'permission denied');
SELECT pg_temp.no_write('full: cannot add time off',
  format($q$INSERT INTO public.staff_time_off (business_id, staff_id, date_from, date_to, time_off_type) VALUES (%L, %L, current_date, current_date, 'vacation')$q$,
         (SELECT v FROM t WHERE k = 'a'), (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.no_write('full: cannot change staff services',
  format($q$DELETE FROM public.staff_services WHERE business_id = %L$q$, (SELECT v FROM t WHERE k = 'a')));
-- owner write RPCs keep their owner checks
SELECT pg_temp.rpc_refused('full: set_staff_access_scope refused',
  format($q$SELECT public.set_staff_access_scope(%L, 'full')$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.rpc_refused('full: revoke_staff_access refused',
  format($q$SELECT public.revoke_staff_access(%L)$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.rpc_refused('full: set_staff_services refused',
  format($q$SELECT public.set_staff_services(%L, true, NULL)$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.rpc_refused('full: set_staff_working_hours refused',
  format($q$SELECT public.set_staff_working_hours(%L, true, NULL)$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.rpc_refused('full: assign_service_to_all_staff refused',
  format($q$SELECT public.assign_service_to_all_staff(%L)$q$, (SELECT v FROM t WHERE k = 'svc')));
SELECT pg_temp.rpc_refused('full: set_business_customer_vip refused',
  format($q$SELECT public.set_business_customer_vip(%L, 'phone:+38970111222', true)$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.rpc_refused('full: set_business_customer_approval_status refused',
  $q$SELECT public.set_business_customer_approval_status('phone:+38970111222', 'approved')$q$);
SELECT pg_temp.rpc_refused('full: update_business_customer_internal_notes refused',
  format($q$SELECT public.update_business_customer_internal_notes(%L, 'phone:+38970111222', 'x')$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.rpc_refused('full: upsert_staff_time_off refused',
  format($q$SELECT public.upsert_staff_time_off(%L, current_date, current_date, 'vacation', NULL, NULL, NULL, NULL)$q$, (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.rpc_refused('full: upsert_business_closed_days_manual refused',
  $q$SELECT public.upsert_business_closed_days_manual(ARRAY[current_date + 20], 'x')$q$);
SELECT pg_temp.rpc_refused('full: sync_missing_business_customers refused',
  format($q$SELECT public.sync_missing_business_customers(%L)$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.rpc_refused('full: ensure_business_customer_for_owner refused',
  format($q$SELECT public.ensure_business_customer_for_owner(%L, '+38970999000', '', 'X')$q$, (SELECT v FROM t WHERE k = 'a')));
SELECT pg_temp.rpc_refused('full: create_booking refused (no create permission)',
  format($q$SELECT public.create_booking(%L, %L, %L, '17:00', 'X', '+38970000000', NULL, NULL, %L, NULL, 'Confirmed')$q$,
         (SELECT v FROM t WHERE k = 'a'), (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day'), (SELECT v FROM t WHERE k = 'alex')));
SELECT pg_temp.expect_error('full: staff_create_booking still needs its own permission',
  format($q$SELECT public.staff_create_booking(%L, %L, '17:00', 'X')$q$, (SELECT v FROM t WHERE k = 'svc'), (SELECT v FROM t WHERE k = 'day')), 'not enabled');
-- sensitive data stays closed
SELECT pg_temp.closed('full: manage-link tokens stay owner-only',
  $q$SELECT public.get_business_booking_manage_token((SELECT id FROM public.bookings WHERE customer_name = 'Ana' LIMIT 1))::text$q$);
SELECT pg_temp.closed('full: subscriptions / payments not readable',
  $q$SELECT count(*)::text FROM public.business_subscriptions$q$);
SELECT pg_temp.closed('full: push tokens not readable',
  $q$SELECT count(*)::text FROM public.business_push_tokens$q$);
SELECT pg_temp.closed('full: platform admin data not readable',
  $q$SELECT count(*)::text FROM public.platform_admins$q$);
SELECT pg_temp.closed('full: owner subscription access not returned',
  $q$SELECT public.get_my_business_access()::text$q$);
SELECT pg_temp.closed('full: owner notification inbox closed',
  $q$SELECT count(*)::text FROM public.list_business_push_inbox()$q$);
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('nothing changed by the full-view attempts',
  (SELECT business_name FROM public.business_settings WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 'F7 Salon'
  AND (SELECT count(*) FROM public.bookings WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a') AND booking_status = 'Confirmed') = 2
  AND (SELECT access_scope FROM public.staff_members WHERE id = (SELECT v::uuid FROM t WHERE k = 'alex')) = 'all'
  AND (SELECT count(*) FROM public.services WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1
  AND (SELECT bool_and(NOT is_vip) FROM public.business_customers WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a'))
  AND (SELECT count(*) FROM public.business_customers WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1
  AND (SELECT note FROM public.business_customer_internal_notes WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 'VIP, prefers mornings'
  AND (SELECT count(*) FROM public.staff_time_off WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 1
  AND NOT EXISTS (SELECT 1 FROM public.business_closed_days WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a'))
  AND (SELECT access_enabled FROM public.staff_members WHERE id = (SELECT v::uuid FROM t WHERE k = 'alex')));

-- ---------------------------------------------------------------- 3) 'all' and 'own' unchanged (no owner data)
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ea'));
SELECT pg_temp.ok('all: no direct reads of owner tables',
  (SELECT count(*) FROM public.business_settings) = 0 AND (SELECT count(*) FROM public.bookings_api) = 0
  AND (SELECT count(*) FROM public.business_customers) = 0 AND (SELECT count(*) FROM public.services) = 0);
SELECT pg_temp.expect_error('all: reports refused',
  format($q$SELECT public.get_business_performance_report(%L, current_date, current_date + 30)$q$, (SELECT v FROM t WHERE k = 'a')), 'Not authorized');
SELECT pg_temp.ok('all: agenda shows every appointment', jsonb_array_length(public.get_staff_agenda() -> 'bookings') = 2);
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'eo'));
SELECT pg_temp.ok('own: no direct reads of owner tables',
  (SELECT count(*) FROM public.business_settings) = 0 AND (SELECT count(*) FROM public.bookings_api) = 0);
SELECT pg_temp.expect_error('own: reports refused',
  format($q$SELECT public.get_business_customer_analytics_overview(%L, current_date, current_date + 30)$q$, (SELECT v FROM t WHERE k = 'a')), 'Not authorized');
SELECT pg_temp.ok('own: agenda shows only own appointment', jsonb_array_length(public.get_staff_agenda() -> 'bookings') = 1);

-- ---------------------------------------------------------------- 4) revocation is immediate
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'a'));
SELECT public.set_staff_access_scope((SELECT v::uuid FROM t WHERE k = 'fiona'), 'all');
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ef'));
SELECT pg_temp.ok('downgraded to all: owner data closed at once',
  (SELECT count(*) FROM public.business_settings) = 0 AND (SELECT count(*) FROM public.business_customers) = 0);
SELECT pg_temp.expect_error('downgraded to all: reports refused at once',
  format($q$SELECT public.get_business_performance_report(%L, current_date, current_date + 30)$q$, (SELECT v FROM t WHERE k = 'a')), 'Not authorized');
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'a'));
SELECT public.set_staff_access_scope((SELECT v::uuid FROM t WHERE k = 'fiona'), 'full');
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ef'));
SELECT pg_temp.ok('owner grants full again: readable', (SELECT count(*) FROM public.business_settings) = 1);
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
UPDATE public.staff_members SET access_enabled = false WHERE id = (SELECT v::uuid FROM t WHERE k = 'fiona');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ef'));
SELECT pg_temp.ok('access removed: nothing readable',
  (SELECT count(*) FROM public.business_settings) = 0 AND (SELECT count(*) FROM public.bookings_api) = 0);
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
UPDATE public.staff_members SET access_enabled = true, active = false WHERE id = (SELECT v::uuid FROM t WHERE k = 'fiona');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'ef'));
SELECT pg_temp.ok('deactivated team member: nothing readable', (SELECT count(*) FROM public.business_settings) = 0);

-- ---------------------------------------------------------------- 5) owner and customer regressions
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'a'));
SELECT pg_temp.ok('owner: still reads own data, never business B',
  (SELECT count(*) FROM public.business_settings) = 1 AND (SELECT count(*) FROM public.bookings_api) = 2
  AND (SELECT count(*) FROM public.business_customers) = 1);
SELECT pg_temp.ok('owner: reports still work',
  public.get_business_service_analytics((SELECT v::uuid FROM t WHERE k = 'a'), current_date, current_date + 30) IS NOT NULL);
SELECT pg_temp.ok('owner: time-off list unchanged', (SELECT count(*) FROM public.list_staff_time_off(NULL)) = 1);
UPDATE public.business_settings SET public_tagline = 'Owner edit' WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a');
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('owner: can still write',
  (SELECT public_tagline FROM public.business_settings WHERE business_id = (SELECT v::uuid FROM t WHERE k = 'a')) = 'Owner edit');
SET LOCAL ROLE authenticated;
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'b'));
SELECT pg_temp.expect_error('other owner: business A reports refused',
  format($q$SELECT public.get_business_performance_report(%L, current_date, current_date + 30)$q$, (SELECT v FROM t WHERE k = 'a')), 'Not authorized');
SELECT pg_temp.act_as((SELECT v::uuid FROM t WHERE k = 'cu'));
SELECT pg_temp.ok('customer: sees own booking and own membership only',
  (SELECT count(*) FROM public.bookings) = 1 AND (SELECT count(*) FROM public.business_customers) = 1
  AND (SELECT count(*) FROM public.business_settings) = 0);
SELECT pg_temp.act_as(NULL);
SET LOCAL ROLE anon;
SELECT pg_temp.closed('anon: no bookings', $q$SELECT count(*)::text FROM public.bookings$q$);
SELECT pg_temp.closed('anon: no business settings', $q$SELECT count(*)::text FROM public.business_settings$q$);
SET LOCAL ROLE postgres;

-- ---------------------------------------------------------------- 6) existing levels untouched
SELECT pg_temp.ok('existing team members keep their level (no full created by the migration)',
  NOT EXISTS (SELECT 1 FROM before_scopes WHERE access_scope = 'full'));

DO $$ BEGIN RAISE NOTICE 'ALL FULL BUSINESS VIEW TESTS PASSED'; END $$;
ROLLBACK;
