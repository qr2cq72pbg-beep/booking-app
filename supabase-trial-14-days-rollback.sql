-- =============================================================================
-- XBOOK — ROLLBACK of supabase-trial-14-days.sql
-- =============================================================================
-- Restores the 7-day grant for NEW trials. The CHECK constraints intentionally
-- keep accepting 7 OR 14 days: any 14-day trial granted while the migration was
-- live remains valid and is NOT shortened or modified.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._try_grant_new_business_trial(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_uid uuid := auth.uid();
  v_starts_at timestamptz;
  v_expires_at timestamptz;
  v_starts_on date;
  v_expires_on date;
  v_history_id uuid;
  v_claimed boolean := false;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;

  -- SECURITY DEFINER does not change auth.uid(). It still reflects the
  -- invoking session: JWT sub for PostgREST clients, NULL for service_role
  -- and SQL-editor / postgres sessions.
  IF v_uid IS NOT NULL AND v_uid IS DISTINCT FROM p_business_id THEN
    RETURN jsonb_build_object(
      'ok', false,
      'granted', false,
      'error', 'owner_mismatch',
      'reason', 'owner_mismatch'
    );
  END IF;

  -- Trusted administrative insert: no JWT user. Do not mint or consume a trial
  -- for an arbitrary UUID. Admin apply remains the only write path.
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'granted', false,
      'reason', 'trusted_insert_no_auto_trial'
    );
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('xbook-trial-owner'), hashtext(p_business_id::text));

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings s
    WHERE s.business_id = p_business_id
    FOR UPDATE
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  -- Never overwrite a paid, complimentary, trial, or any other existing row.
  IF EXISTS (
    SELECT 1
    FROM public.business_subscriptions sub
    WHERE sub.business_id = p_business_id
    FOR UPDATE
  ) THEN
    RETURN jsonb_build_object('ok', true, 'granted', false, 'reason', 'already_entitled');
  END IF;

  v_starts_at := v_now;
  v_expires_at := v_starts_at + interval '7 days';
  v_starts_on := (v_starts_at AT TIME ZONE 'UTC')::date;
  v_expires_on := (v_expires_at AT TIME ZONE 'UTC')::date;

  BEGIN
    INSERT INTO public.business_trial_eligibility (
      owner_user_id,
      first_business_id,
      granted_at,
      consumed_reason,
      trial_starts_at,
      trial_expires_at
    ) VALUES (
      p_business_id,
      p_business_id,
      v_now,
      'automatic_trial',
      v_starts_at,
      v_expires_at
    );
    v_claimed := true;
  EXCEPTION
    WHEN unique_violation THEN
      RETURN jsonb_build_object('ok', true, 'granted', false, 'reason', 'already_consumed');
  END;

  IF NOT v_claimed THEN
    RETURN jsonb_build_object('ok', true, 'granted', false, 'reason', 'already_consumed');
  END IF;

  INSERT INTO public.business_subscription_history (
    business_id,
    idempotency_key,
    operation,
    package_id,
    access_kind,
    previous_access_kind,
    paid_months,
    bonus_months,
    access_months,
    price_eur,
    requested_starts_on,
    requested_expires_on,
    previous_package_id,
    previous_starts_on,
    previous_expires_on,
    previous_starts_at,
    previous_expires_at,
    new_starts_on,
    new_expires_on,
    new_starts_at,
    new_expires_at,
    actor_user_id,
    note
  ) VALUES (
    p_business_id,
    gen_random_uuid(),
    'grant_trial',
    NULL,
    'trial',
    NULL,
    0,
    0,
    0,
    0,
    v_starts_on,
    v_expires_on,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    v_starts_on,
    v_expires_on,
    v_starts_at,
    v_expires_at,
    p_business_id,
    'Automatic 7-day XBOOK Business trial'
  )
  RETURNING id INTO v_history_id;

  INSERT INTO public.business_subscriptions (
    business_id,
    package_id,
    access_kind,
    starts_on,
    expires_on,
    starts_at,
    expires_at,
    activated_at,
    updated_at,
    updated_by,
    last_history_id
  ) VALUES (
    p_business_id,
    NULL,
    'trial',
    v_starts_on,
    v_expires_on,
    v_starts_at,
    v_expires_at,
    v_now,
    v_now,
    p_business_id,
    v_history_id
  );

  RETURN jsonb_build_object(
    'ok', true,
    'granted', true,
    'reason', 'granted',
    'access_kind', 'trial',
    'is_revenue', false,
    'starts_at', v_starts_at,
    'expires_at', v_expires_at,
    'history_id', v_history_id
  );
END;
$function$;

COMMENT ON FUNCTION public._business_settings_after_insert_trial() IS
  'AFTER INSERT on business_settings. Grants a 7-day trial only when auth.uid() '
  'equals NEW.business_id. Trusted uid-less inserts are created without a trial. '
  'owner_mismatch and unexpected grant failures abort the business insert.';

-- Verification (inside the transaction; aborts on mismatch)
DO $verify$
DECLARE v_def text;
BEGIN
  v_def := pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure);
  IF position('interval ''7 days''' IN v_def) = 0 OR position('interval ''14 days''' IN v_def) > 0 THEN
    RAISE EXCEPTION 'trial function does not use 7 days';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'business_settings_after_insert_trial' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'trial trigger missing';
  END IF;
END
$verify$;

COMMIT;
