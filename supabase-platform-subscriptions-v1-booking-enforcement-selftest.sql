-- =============================================================================
-- XBOOK Phase 4E — isolated transactional self-test
-- =============================================================================
-- LOCAL / REVIEW ONLY. Do NOT run on production.
-- Creates throwaway xbook-4e-* rows and deletes them before finishing.
-- Does not touch angel-touch or gorge123 live rows.
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.xbook_4e_expect_error(p_sql text, p_code text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  EXECUTE p_sql;
  RAISE EXCEPTION 'expected error % was not raised: %', p_code, p_sql;
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%' || p_code || '%' THEN
      RAISE;
    END IF;
END;
$$;

DO $$
DECLARE
  v_angel uuid := gen_random_uuid();
  v_barber uuid := gen_random_uuid();
  v_trial_ok uuid := gen_random_uuid();
  v_trial_exp uuid := gen_random_uuid();
  v_paid_ok uuid := gen_random_uuid();
  v_paid_exp uuid := gen_random_uuid();
  v_paid_future uuid := gen_random_uuid();
  v_unconf uuid := gen_random_uuid();
  v_actor uuid := gen_random_uuid();
  v_customer uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_booking public.bookings%ROWTYPE;
  v_recurring public.bookings%ROWTYPE;
  v_result jsonb;
  v_count integer;
  v_expired_start timestamptz;
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.business_settings
    WHERE business_slug IN ('angel-touch', 'gorge123')
      AND business_id IN (
        v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok,
        v_paid_exp, v_paid_future, v_unconf
      )
  ) THEN
    RAISE EXCEPTION 'refusing to run: isolated ids collided with live businesses';
  END IF;

  INSERT INTO auth.users (id)
  VALUES
    (v_angel), (v_barber), (v_trial_ok), (v_trial_exp),
    (v_paid_ok), (v_paid_exp), (v_paid_future), (v_unconf),
    (v_actor), (v_customer)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES
    (v_angel, 'XBOOK_4E_ANGEL', 'Europe/Skopje', 'xbook-4e-angel-' || replace(v_angel::text, '-', ''), '09:00', '17:00'),
    (v_barber, 'XBOOK_4E_BARBER', 'Europe/Skopje', 'xbook-4e-barber-' || replace(v_barber::text, '-', ''), '09:00', '17:00'),
    (v_trial_ok, 'XBOOK_4E_TRIAL_OK', 'Europe/Skopje', 'xbook-4e-tok-' || replace(v_trial_ok::text, '-', ''), '09:00', '17:00'),
    (v_trial_exp, 'XBOOK_4E_TRIAL_EXP', 'Europe/Skopje', 'xbook-4e-tex-' || replace(v_trial_exp::text, '-', ''), '09:00', '17:00'),
    (v_paid_ok, 'XBOOK_4E_PAID_OK', 'Europe/Skopje', 'xbook-4e-pok-' || replace(v_paid_ok::text, '-', ''), '09:00', '17:00'),
    (v_paid_exp, 'XBOOK_4E_PAID_EXP', 'Europe/Skopje', 'xbook-4e-pex-' || replace(v_paid_exp::text, '-', ''), '09:00', '17:00'),
    (v_paid_future, 'XBOOK_4E_PAID_FUT', 'Europe/Skopje', 'xbook-4e-pfu-' || replace(v_paid_future::text, '-', ''), '09:00', '17:00'),
    (v_unconf, 'XBOOK_4E_UNCONF', 'Europe/Skopje', 'xbook-4e-unc-' || replace(v_unconf::text, '-', ''), '09:00', '17:00');

  -- Angel Touch-shaped: complimentary unlimited
  PERFORM public.admin_apply_business_subscription(
    v_angel, NULL, 'grant_complimentary', CURRENT_DATE, gen_random_uuid(), v_actor,
    '4e isolated complimentary', NULL
  );

  -- Test Barber-shaped: paid until 2026-11-13
  INSERT INTO public.business_subscriptions (
    business_id, package_id, access_kind, starts_on, expires_on, updated_by
  ) VALUES (
    v_barber, 'flex_monthly', 'paid', DATE '2026-10-14', DATE '2026-11-13', v_actor
  );

  -- Active trial
  INSERT INTO public.business_subscriptions (
    business_id, package_id, access_kind, starts_on, expires_on, starts_at, expires_at, updated_by
  ) VALUES (
    v_trial_ok, NULL, 'trial', CURRENT_DATE, (v_now + interval '7 days')::date,
    v_now, v_now + interval '7 days', v_trial_ok
  );

  -- Expired trial
  v_expired_start := v_now - interval '8 days';
  INSERT INTO public.business_subscriptions (
    business_id, package_id, access_kind, starts_on, expires_on, starts_at, expires_at, updated_by
  ) VALUES (
    v_trial_exp, NULL, 'trial',
    (v_expired_start AT TIME ZONE 'UTC')::date,
    (v_expired_start + interval '7 days')::date,
    v_expired_start, v_expired_start + interval '7 days', v_trial_exp
  );

  INSERT INTO public.business_subscriptions (
    business_id, package_id, access_kind, starts_on, expires_on, updated_by
  ) VALUES
    (v_paid_ok, 'flex_monthly', 'paid', CURRENT_DATE - 1, CURRENT_DATE + 30, v_actor),
    (v_paid_exp, 'flex_monthly', 'paid', CURRENT_DATE - 40, CURRENT_DATE - 1, v_actor),
    (v_paid_future, 'flex_monthly', 'paid', CURRENT_DATE + 3, CURRENT_DATE + 33, v_actor);

  -- 1) Helper: complimentary unlimited and active paid/trial pass
  PERFORM public._assert_business_can_accept_bookings(v_angel);
  PERFORM public._assert_business_can_accept_bookings(v_barber);
  PERFORM public._assert_business_can_accept_bookings(v_trial_ok);
  PERFORM public._assert_business_can_accept_bookings(v_paid_ok);

  -- 2) Helper negatives
  BEGIN
    PERFORM public._assert_business_can_accept_bookings(v_unconf);
    RAISE EXCEPTION 'unconfigured should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_unconfigured%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public._assert_business_can_accept_bookings(v_trial_exp);
    RAISE EXCEPTION 'expired trial should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public._assert_business_can_accept_bookings(v_paid_exp);
    RAISE EXCEPTION 'expired paid should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public._assert_business_can_accept_bookings(v_paid_future);
    RAISE EXCEPTION 'future paid should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_not_started%' THEN RAISE; END IF;
  END;

  -- 3) Owner-style create_booking allowed on active trial / paid / complimentary
  v_booking := public.create_booking(
    v_trial_ok, NULL, CURRENT_DATE + 1, '10:00', 'Owner A', '070000001',
    NULL, NULL, NULL, v_trial_ok, 'Confirmed'
  );
  IF v_booking.business_id IS DISTINCT FROM v_trial_ok THEN
    RAISE EXCEPTION 'active trial create_booking failed';
  END IF;

  v_booking := public.create_booking(
    v_paid_ok, NULL, CURRENT_DATE + 1, '11:00', 'Cust B', '070000002',
    NULL, NULL, NULL, v_customer, 'Pending'
  );
  IF v_booking.id IS NULL THEN
    RAISE EXCEPTION 'customer create_booking on paid failed';
  END IF;

  v_booking := public.create_booking(
    v_angel, NULL, CURRENT_DATE + 1, '12:00', 'Cust Angel', '070000003',
    NULL, NULL, NULL, v_customer, 'Pending'
  );
  v_booking := public.create_booking(
    v_barber, NULL, CURRENT_DATE + 1, '13:00', 'Cust Barber', '070000004',
    NULL, NULL, NULL, v_customer, 'Pending'
  );

  -- 4) Blocked creates
  BEGIN
    PERFORM public.create_booking(
      v_unconf, NULL, CURRENT_DATE + 1, '10:00', 'X', '070000099',
      NULL, NULL, NULL, v_customer, 'Pending'
    );
    RAISE EXCEPTION 'unconfigured create should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_unconfigured%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.create_booking(
      v_trial_exp, NULL, CURRENT_DATE + 1, '10:00', 'X', '070000098',
      NULL, NULL, NULL, v_customer, 'Pending'
    );
    RAISE EXCEPTION 'expired trial create should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.create_booking(
      v_paid_exp, NULL, CURRENT_DATE + 1, '10:00', 'X', '070000097',
      NULL, NULL, NULL, v_trial_ok, 'Confirmed'
    );
    RAISE EXCEPTION 'expired paid owner create should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.create_booking(
      v_paid_future, NULL, CURRENT_DATE + 5, '10:00', 'X', '070000096',
      NULL, NULL, NULL, v_customer, 'Pending'
    );
    RAISE EXCEPTION 'future paid create should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_not_started%' THEN RAISE; END IF;
  END;

  -- 5) Recurring: allowed then blocked
  v_recurring := public.create_recurring_bookings(
    v_paid_ok, NULL, CURRENT_DATE + 2, '09:00', 'Recur', '070000010',
    NULL, NULL, NULL, v_customer, 'Pending', 'weekly', 2
  );
  IF v_recurring.id IS NULL THEN
    RAISE EXCEPTION 'recurring on paid failed';
  END IF;
  BEGIN
    PERFORM public.create_recurring_bookings(
      v_paid_exp, NULL, CURRENT_DATE + 2, '09:00', 'Recur', '070000011',
      NULL, NULL, NULL, v_customer, 'Pending', 'weekly', 2
    );
    RAISE EXCEPTION 'recurring on expired paid should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;

  -- 6) Reschedule allowed while active; blocked when expired
  v_result := public.reschedule_booking_by_manage_token(
    (SELECT manage_token FROM public.bookings WHERE business_id = v_paid_ok ORDER BY created_at LIMIT 1),
    CURRENT_DATE + 4,
    '14:00'::time
  );
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'reschedule on active paid failed';
  END IF;

  INSERT INTO public.bookings (
    business_id, date, time, booking_status, manage_token, customer_name
  ) VALUES (
    v_paid_exp, (CURRENT_DATE + 1)::text, '10:00', 'Cancelled',
    'tok-exp-' || replace(v_paid_exp::text, '-', ''), 'Existing'
  );
  BEGIN
    UPDATE public.bookings
    SET booking_status = 'Pending', date = (CURRENT_DATE + 2)::text
    WHERE business_id = v_paid_exp AND manage_token LIKE 'tok-exp-%';
    RAISE EXCEPTION 'reactivate+reschedule on expired paid should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;
  IF EXISTS (
    SELECT 1 FROM public.bookings
    WHERE business_id = v_paid_exp AND lower(booking_status) IN ('pending', 'confirmed')
  ) THEN
    RAISE EXCEPTION 'expired paid gained an active booking';
  END IF;

  BEGIN
    PERFORM public.reschedule_booking_by_manage_token(
      'tok-exp-' || replace(v_paid_exp::text, '-', ''),
      CURRENT_DATE + 3,
      '15:00'::time
    );
    RAISE EXCEPTION 'reschedule on expired should fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%subscription_expired%' THEN RAISE; END IF;
  END;

  -- 7) Cancel / non-slot update of an existing active booking still allowed after expiry
  -- Seed an active booking on paid_ok, then expire that business, then cancel.
  UPDATE public.business_subscriptions
  SET expires_on = CURRENT_DATE - 1
  WHERE business_id = v_paid_ok AND access_kind = 'paid';
  UPDATE public.bookings
  SET booking_status = 'Cancelled'
  WHERE business_id = v_paid_ok AND lower(coalesce(booking_status, 'pending')) IN ('pending', 'confirmed');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'cancel after expiry failed';
  END IF;
  -- Restore paid_ok for leftover cleanup only
  UPDATE public.business_subscriptions
  SET expires_on = CURRENT_DATE + 30
  WHERE business_id = v_paid_ok AND access_kind = 'paid';

  -- 8) Live-named businesses in this isolated DB were not given extra trials
  IF EXISTS (
    SELECT 1 FROM public.business_settings bs
    JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
    WHERE bs.business_slug IN ('angel-touch', 'gorge123')
      AND sub.access_kind = 'trial'
  ) THEN
    RAISE EXCEPTION 'live-named businesses received a trial during 4E selftest';
  END IF;

  SELECT count(*) INTO v_count
  FROM public.bookings
  WHERE business_id IN (v_unconf, v_trial_exp, v_paid_future);
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'blocked businesses stored new bookings: %', v_count;
  END IF;

  -- Cleanup
  ALTER TABLE public.business_subscription_history
    DISABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.business_subscription_history
  WHERE business_id IN (
    v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok, v_paid_exp, v_paid_future, v_unconf
  );
  ALTER TABLE public.business_subscription_history
    ENABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.bookings
  WHERE business_id IN (
    v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok, v_paid_exp, v_paid_future, v_unconf
  );
  DELETE FROM public.business_subscriptions
  WHERE business_id IN (
    v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok, v_paid_exp, v_paid_future, v_unconf
  );
  DELETE FROM public.business_settings
  WHERE business_id IN (
    v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok, v_paid_exp, v_paid_future, v_unconf
  )
     OR business_slug LIKE 'xbook-4e-%'
     OR business_name LIKE 'XBOOK_4E_%';
  DELETE FROM public.business_trial_eligibility
  WHERE owner_user_id IN (
    v_angel, v_barber, v_trial_ok, v_trial_exp, v_paid_ok, v_paid_exp, v_paid_future, v_unconf
  );

  RAISE NOTICE 'xbook-phase4e-booking-enforcement-selftest: ok';
END;
$$;
