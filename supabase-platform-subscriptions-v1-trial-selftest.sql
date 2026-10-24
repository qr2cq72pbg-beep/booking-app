-- =============================================================================
-- XBOOK Phase 4F — isolated transactional self-test
-- =============================================================================
-- LOCAL / REVIEW ONLY. Do NOT run on production without explicit approval.
-- Creates throwaway xbook-4f-* rows and deletes them before finishing.
-- Does not touch angel-touch or gorge123.
-- Does not call create_booking / create_recurring_bookings.
--
-- Happy-path inserts set request.jwt.claim.sub / request.jwt.claims so
-- auth.uid() equals the owner (ordinary authenticated onboarding).
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.xbook_4f_set_request_uid(p_uid uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '{}', true);
  ELSE
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', p_uid)::text, true);
  END IF;
END;
$$;

DO $$
DECLARE
  v_owner_a uuid := gen_random_uuid();
  v_owner_b uuid := gen_random_uuid();
  v_owner_c uuid := gen_random_uuid();
  v_owner_d uuid := gen_random_uuid();
  v_owner_e uuid := gen_random_uuid();
  v_victim uuid := gen_random_uuid();
  v_actor uuid := gen_random_uuid();
  v_sub public.business_subscriptions%ROWTYPE;
  v_el public.business_trial_eligibility%ROWTYPE;
  v_hist public.business_subscription_history%ROWTYPE;
  v_result jsonb;
  v_hours numeric;
  v_trial_count integer;
  v_expired_start timestamptz;
  v_insert_blocked boolean;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.business_settings
    WHERE business_slug IN ('angel-touch', 'gorge123')
      AND business_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim)
  ) THEN
    RAISE EXCEPTION 'refusing to run: isolated ids collided with live businesses';
  END IF;

  ALTER TABLE public.business_subscription_history
    DISABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.business_subscription_history
  WHERE business_id IN (
    SELECT business_id FROM public.business_settings
    WHERE business_slug LIKE 'xbook-4f-%' OR business_name LIKE 'XBOOK_4F_%'
  );
  ALTER TABLE public.business_subscription_history
    ENABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.business_settings
  WHERE business_slug LIKE 'xbook-4f-%' OR business_name LIKE 'XBOOK_4F_%';
  DELETE FROM public.business_trial_eligibility
  WHERE first_business_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim)
     OR owner_user_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim);

  -- history.actor_user_id and business_subscriptions.updated_by reference auth.users.
  INSERT INTO auth.users (id)
  VALUES (v_owner_a), (v_owner_b), (v_owner_c), (v_owner_d), (v_owner_e), (v_victim), (v_actor)
  ON CONFLICT (id) DO NOTHING;

  -- 1) New business gets exactly one trial at first authenticated owner insert
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_a);
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_owner_a, 'XBOOK_4F_A', 'Europe/Skopje', 'xbook-4f-a-' || replace(v_owner_a::text, '-', ''),
    '09:00', '17:00'
  );

  SELECT * INTO v_sub FROM public.business_subscriptions WHERE business_id = v_owner_a;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'test 1 failed: new business did not receive a trial';
  END IF;
  IF v_sub.access_kind IS DISTINCT FROM 'trial' THEN
    RAISE EXCEPTION 'test 1 failed: access_kind=%', v_sub.access_kind;
  END IF;
  IF v_sub.package_id IS NOT NULL OR COALESCE(v_sub.starts_at, v_sub.expires_at) IS NULL THEN
    RAISE EXCEPTION 'test 1 failed: trial must have timestamps and no package';
  END IF;

  -- 2 + 3) Starts at insert time and lasts exactly 168 hours
  v_hours := EXTRACT(EPOCH FROM (v_sub.expires_at - v_sub.starts_at)) / 3600.0;
  IF v_hours IS DISTINCT FROM 168 THEN
    RAISE EXCEPTION 'test 3 failed: trial hours=% expected 168', v_hours;
  END IF;
  IF v_sub.expires_at <> v_sub.starts_at + interval '7 days' THEN
    RAISE EXCEPTION 'test 3 failed: expires_at is not starts_at + 7 days';
  END IF;

  SELECT * INTO v_el FROM public.business_trial_eligibility WHERE owner_user_id = v_owner_a;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'test 1 failed: eligibility row missing';
  END IF;
  IF v_el.trial_starts_at IS DISTINCT FROM v_sub.starts_at
     OR v_el.trial_expires_at IS DISTINCT FROM v_sub.expires_at THEN
    RAISE EXCEPTION 'test 1 failed: eligibility window does not match entitlement';
  END IF;

  SELECT * INTO v_hist
  FROM public.business_subscription_history
  WHERE business_id = v_owner_a AND operation = 'grant_trial';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'test 15 failed: grant_trial history missing';
  END IF;
  IF v_hist.price_eur IS DISTINCT FROM 0 OR v_hist.package_id IS NOT NULL THEN
    RAISE EXCEPTION 'test 15 failed: trial history must have no revenue';
  END IF;

  -- 4) Repeated grant does not reset expiry
  v_result := public._try_grant_new_business_trial(v_owner_a);
  IF COALESCE(v_result->>'granted', 'true') = 'true' THEN
    RAISE EXCEPTION 'test 4 failed: repeated grant created another trial: %', v_result;
  END IF;
  IF (SELECT expires_at FROM public.business_subscriptions WHERE business_id = v_owner_a)
     IS DISTINCT FROM v_sub.expires_at THEN
    RAISE EXCEPTION 'test 4 failed: expiry was reset';
  END IF;

  -- 5) Concurrent-safe unique claim: second insert into eligibility must fail
  BEGIN
    INSERT INTO public.business_trial_eligibility (
      owner_user_id, first_business_id, consumed_reason, trial_starts_at, trial_expires_at
    ) VALUES (
      v_owner_a, v_owner_a, 'automatic_trial', clock_timestamp(), clock_timestamp() + interval '7 days'
    );
    RAISE EXCEPTION 'test 5 failed: duplicate eligibility was allowed';
  EXCEPTION
    WHEN unique_violation THEN
      NULL;
  END;

  SELECT count(*) INTO v_trial_count
  FROM public.business_subscriptions
  WHERE business_id = v_owner_a AND access_kind = 'trial';
  IF v_trial_count <> 1 THEN
    RAISE EXCEPTION 'test 5 failed: expected 1 trial row, got %', v_trial_count;
  END IF;

  -- 6) Dropping the current entitlement cannot mint another trial.
  -- business_subscription_history is immutable, so a settings delete that
  -- would cascade into history is rejected. Eligibility has no FK and remains.
  DELETE FROM public.business_subscriptions WHERE business_id = v_owner_a;
  IF NOT EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id = v_owner_a) THEN
    RAISE EXCEPTION 'test 6 failed: eligibility must survive entitlement delete';
  END IF;
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_a);
  v_result := public._try_grant_new_business_trial(v_owner_a);
  IF COALESCE(v_result->>'reason', '') IS DISTINCT FROM 'already_consumed'
     OR COALESCE(v_result->>'granted', 'true') = 'true' THEN
    RAISE EXCEPTION 'test 6 failed: second grant after entitlement delete: %', v_result;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.business_subscriptions WHERE business_id = v_owner_a
  ) THEN
    RAISE EXCEPTION 'test 6 failed: second trial row was created';
  END IF;

  -- 9) Paid entitlement is not overwritten by automatic trial
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_b);
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_owner_b, 'XBOOK_4F_B', 'Europe/Skopje', 'xbook-4f-b-' || replace(v_owner_b::text, '-', ''),
    '09:00', '17:00'
  );
  v_result := public.admin_apply_business_subscription(
    v_owner_b,
    'flex_monthly',
    'activate',
    CURRENT_DATE,
    gen_random_uuid(),
    v_actor,
    'phase4f selftest paid replace',
    NULL
  );
  IF COALESCE(v_result->>'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'test 16 failed: admin could not replace trial with paid: %', v_result;
  END IF;
  SELECT * INTO v_sub FROM public.business_subscriptions WHERE business_id = v_owner_b;
  IF v_sub.access_kind IS DISTINCT FROM 'paid'
     OR v_sub.package_id IS DISTINCT FROM 'flex_monthly'
     OR v_sub.starts_at IS NOT NULL
     OR v_sub.expires_at IS NOT NULL THEN
    RAISE EXCEPTION 'test 9/16 failed: paid replace did not clear trial timestamps';
  END IF;
  v_result := public._try_grant_new_business_trial(v_owner_b);
  IF COALESCE(v_result->>'reason', '') IS DISTINCT FROM 'already_entitled' THEN
    RAISE EXCEPTION 'test 9 failed: paid row was eligible for overwrite: %', v_result;
  END IF;
  IF (SELECT access_kind FROM public.business_subscriptions WHERE business_id = v_owner_b)
     IS DISTINCT FROM 'paid' THEN
    RAISE EXCEPTION 'test 9 failed: paid entitlement was overwritten';
  END IF;

  -- 10) Complimentary entitlement is not overwritten
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_c);
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_owner_c, 'XBOOK_4F_C', 'Europe/Skopje', 'xbook-4f-c-' || replace(v_owner_c::text, '-', ''),
    '09:00', '17:00'
  );
  v_result := public.admin_apply_business_subscription(
    v_owner_c,
    NULL,
    'grant_complimentary',
    CURRENT_DATE,
    gen_random_uuid(),
    v_actor,
    'phase4f selftest complimentary replace',
    NULL
  );
  IF COALESCE(v_result->>'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'test 16 failed: admin could not replace trial with complimentary: %', v_result;
  END IF;
  SELECT * INTO v_sub FROM public.business_subscriptions WHERE business_id = v_owner_c;
  IF v_sub.access_kind IS DISTINCT FROM 'complimentary' OR v_sub.expires_on IS NOT NULL THEN
    RAISE EXCEPTION 'test 10 failed: complimentary unlimited not stored';
  END IF;
  v_result := public._try_grant_new_business_trial(v_owner_c);
  IF COALESCE(v_result->>'reason', '') IS DISTINCT FROM 'already_entitled' THEN
    RAISE EXCEPTION 'test 10 failed: complimentary row was eligible for overwrite: %', v_result;
  END IF;

  -- 11) Trial expires correctly on the timestamp, not the calendar date
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_d);
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_owner_d, 'XBOOK_4F_D', 'Europe/Skopje', 'xbook-4f-d-' || replace(v_owner_d::text, '-', ''),
    '09:00', '17:00'
  );
  v_expired_start := clock_timestamp() - interval '7 days' - interval '2 seconds';
  UPDATE public.business_subscriptions
  SET starts_at = v_expired_start,
      expires_at = v_expired_start + interval '7 days',
      starts_on = (v_expired_start AT TIME ZONE 'UTC')::date,
      expires_on = (v_expired_start + interval '7 days')::date
  WHERE business_id = v_owner_d;

  IF public._subscription_entitlement_status(
       'trial',
       CURRENT_DATE,
       (SELECT expires_at FROM public.business_subscriptions WHERE business_id = v_owner_d),
       CURRENT_DATE,
       clock_timestamp()
     ) IS DISTINCT FROM 'expired' THEN
    RAISE EXCEPTION 'test 11 failed: timestamp-expired trial still active';
  END IF;
  IF public._subscription_row_status(CURRENT_DATE, CURRENT_DATE) IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'test 11 failed: date helper should still treat today as active for paid';
  END IF;

  -- 14) Client cannot execute the grant function
  IF has_function_privilege('authenticated', 'public._try_grant_new_business_trial(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._try_grant_new_business_trial(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'test 14 failed: clients can execute the grant function';
  END IF;

  -- 7 + 8) Live businesses still untouched
  IF EXISTS (
    SELECT 1
    FROM public.business_settings bs
    JOIN public.business_trial_eligibility el ON el.owner_user_id = bs.business_id
    WHERE bs.business_slug IN ('angel-touch', 'gorge123')
      AND (
        el.consumed_reason IS DISTINCT FROM 'preexisting_owner'
        OR el.trial_starts_at IS NOT NULL
        OR el.trial_expires_at IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'test 7/8 failed: live businesses were not left as preexisting_owner fences';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.business_settings bs
    JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
    WHERE bs.business_slug IN ('angel-touch', 'gorge123')
      AND sub.access_kind = 'trial'
  ) THEN
    RAISE EXCEPTION 'test 7/8 failed: a live business received a trial entitlement';
  END IF;

  -- 17) Trusted uid-less insert: business is created, no trial, eligibility unused
  PERFORM pg_temp.xbook_4f_set_request_uid(NULL);
  INSERT INTO public.business_settings (
    business_id, business_name, timezone, business_slug, work_start, work_end
  ) VALUES (
    v_owner_e, 'XBOOK_4F_E_TRUSTED', 'Europe/Skopje',
    'xbook-4f-e-' || replace(v_owner_e::text, '-', ''),
    '09:00', '17:00'
  );
  IF EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id = v_owner_e) THEN
    RAISE EXCEPTION 'test 17 failed: trusted insert received an automatic trial';
  END IF;
  IF EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id = v_owner_e) THEN
    RAISE EXCEPTION 'test 17 failed: trusted insert consumed trial eligibility';
  END IF;
  v_result := public._try_grant_new_business_trial(v_owner_e);
  IF COALESCE(v_result->>'reason', '') IS DISTINCT FROM 'trusted_insert_no_auto_trial'
     OR COALESCE(v_result->>'granted', 'true') = 'true' THEN
    RAISE EXCEPTION 'test 17 failed: uid-less grant helper did not no-op: %', v_result;
  END IF;

  -- 18) Authenticated client cannot insert another owner's business_settings
  --     (defense in depth even if a live INSERT policy is missing or weak).
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_a);
  v_insert_blocked := false;
  BEGIN
    INSERT INTO public.business_settings (
      business_id, business_name, timezone, business_slug, work_start, work_end
    ) VALUES (
      v_victim, 'XBOOK_4F_VICTIM', 'Europe/Skopje',
      'xbook-4f-victim-' || replace(v_victim::text, '-', ''),
      '09:00', '17:00'
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%owner_mismatch%' THEN
        v_insert_blocked := true;
      ELSE
        RAISE;
      END IF;
  END;
  IF NOT v_insert_blocked THEN
    RAISE EXCEPTION 'test 18 failed: cross-owner business_settings insert was allowed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.business_settings WHERE business_id = v_victim) THEN
    RAISE EXCEPTION 'test 18 failed: victim settings row survived owner_mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id = v_victim)
     OR EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id = v_victim) THEN
    RAISE EXCEPTION 'test 18 failed: cross-owner insert consumed or granted a trial';
  END IF;

  -- 19) Direct grant helper rejects a different owner UUID and does not consume
  PERFORM pg_temp.xbook_4f_set_request_uid(v_owner_a);
  v_result := public._try_grant_new_business_trial(v_victim);
  IF COALESCE(v_result->>'error', '') IS DISTINCT FROM 'owner_mismatch'
     OR COALESCE(v_result->>'ok', 'true') = 'true' THEN
    RAISE EXCEPTION 'test 19 failed: grant helper accepted a foreign owner: %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id = v_victim)
     OR EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id = v_victim) THEN
    RAISE EXCEPTION 'test 19 failed: foreign grant consumed eligibility or created a trial';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id = v_owner_a) THEN
    RAISE EXCEPTION 'test 19 failed: attacker eligibility was lost';
  END IF;

  -- Cleanup isolated rows. History is immutable, so disable that trigger only
  -- for throwaway xbook-4f ids, then restore it.
  ALTER TABLE public.business_subscription_history
    DISABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.business_subscription_history
  WHERE business_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim);
  ALTER TABLE public.business_subscription_history
    ENABLE TRIGGER business_subscription_history_no_update;
  DELETE FROM public.business_settings
  WHERE business_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim)
     OR business_slug LIKE 'xbook-4f-%'
     OR business_name LIKE 'XBOOK_4F_%';
  DELETE FROM public.business_trial_eligibility
  WHERE owner_user_id IN (v_owner_a, v_owner_b, v_owner_c, v_owner_d, v_owner_e, v_victim);

  RAISE NOTICE 'xbook-phase4f-trial-selftest: ok';
END;
$$;
