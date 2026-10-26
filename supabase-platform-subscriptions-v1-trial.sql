-- =============================================================================
-- XBOOK Phase 4F — Automatic one-time 14-day Business Account trial
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Do NOT run from the XBOOK iOS / Android / web apps.
-- Safe to re-run (IF NOT EXISTS / DROP CONSTRAINT IF EXISTS / CREATE OR REPLACE).
--
-- Requires already-applied:
--   supabase-platform-subscriptions-v1.sql
--   supabase-platform-subscriptions-v1-plans.sql
--   supabase-platform-subscriptions-v1-access.sql
--   supabase-platform-subscriptions-v1-owner-read.sql
--
-- This file does NOT:
--   • enforce expired access on create_booking / create_recurring_bookings
--   • backfill Angel Touch, Test Barber, or any existing business
--   • overwrite paid, complimentary, or manually configured entitlements
--   • create payment, checkout, revenue, or automatic renewal
--   • grant clients INSERT/UPDATE on subscription tables
--   • expose service_role credentials
--   • re-enable Google or Apple Sign In
--
-- Trial starts only when a NEW business_settings row is first inserted
-- by the authenticated owner (NEW.business_id = auth.uid()).
-- Auth signup alone does not start a trial.
-- Completing onboarding is not required.
-- service_role / SQL-editor / other uid-less inserts do not auto-grant.
--
-- Duration: starts_at + interval '14 days' = exactly 336 hours, server clock.
-- (Trials granted before the 14-day change keep their stored 7-day window.)
-- One trial per owner UUID, durable even if business_settings is deleted.
--
-- BOOKING ENFORCEMENT GAP (Phase 4E — not authorized here):
--   Expired trial/subscription does NOT yet block create_booking,
--   create_recurring_bookings, owner create, customer create, or reschedule.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Timestamp-accurate trial window on the current entitlement
--    Paid calendar-month expiry and complimentary unlimited stay date-based.
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_subscriptions
  ADD COLUMN IF NOT EXISTS starts_at timestamptz;

ALTER TABLE public.business_subscriptions
  ADD COLUMN IF NOT EXISTS expires_at timestamptz;

ALTER TABLE public.business_subscriptions
  DROP CONSTRAINT IF EXISTS business_subscriptions_trial_window_ok;

ALTER TABLE public.business_subscriptions
  ADD CONSTRAINT business_subscriptions_trial_window_ok
    CHECK (
      access_kind <> 'trial'
      OR (
        package_id IS NULL
        AND starts_at IS NOT NULL
        AND expires_at IS NOT NULL
        AND expires_on IS NOT NULL
        AND (expires_at = starts_at + interval '7 days' OR expires_at = starts_at + interval '14 days')
      )
    );

COMMENT ON COLUMN public.business_subscriptions.starts_at IS
  'Authoritative start instant for trial rows. Paid and complimentary keep starts_on.';

COMMENT ON COLUMN public.business_subscriptions.expires_at IS
  'Authoritative trial expiry instant (starts_at + 14 days for new trials; '
  'trials granted before this migration keep starts_at + 7 days). '
  'NULL for paid calendar-month and complimentary rows.';

COMMENT ON TABLE public.business_subscriptions IS
  'Current access entitlement. No row = unconfigured, not expired. '
  'access_kind complimentary with expires_on NULL = FREE UNTIL CHANGED. '
  'access_kind trial uses starts_at/expires_at for exact expiry '
  '(14 days for new trials, 7 days for legacy trials). '
  'Phase 4F does not enforce bookings.';

-- -----------------------------------------------------------------------------
-- 2) History: grant_trial + timestamp snapshots
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS new_starts_at timestamptz;

ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS new_expires_at timestamptz;

ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS previous_starts_at timestamptz;

ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS previous_expires_at timestamptz;

ALTER TABLE public.business_subscription_history
  DROP CONSTRAINT IF EXISTS business_subscription_history_operation_ok;

ALTER TABLE public.business_subscription_history
  ADD CONSTRAINT business_subscription_history_operation_ok
    CHECK (operation IN (
      'activate',
      'extend',
      'grant_complimentary',
      'extend_complimentary',
      'replace_complimentary',
      'revoke_complimentary',
      'convert_to_paid',
      'convert_to_complimentary',
      'grant_trial'
    ));

COMMENT ON TABLE public.business_subscription_history IS
  'Insert-only log of access grants. grant_trial is automatic, price_eur = 0, not revenue. '
  'NULL new_expires_on = FREE UNTIL CHANGED. Idempotency key prevents double-apply.';

-- -----------------------------------------------------------------------------
-- 3) Durable one-trial-per-owner ledger (survives business_settings delete)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_trial_eligibility (
  owner_user_id     uuid PRIMARY KEY,
  first_business_id uuid NOT NULL,
  granted_at        timestamptz NOT NULL DEFAULT now(),
  consumed_reason   text NOT NULL DEFAULT 'automatic_trial',
  trial_starts_at   timestamptz,
  trial_expires_at  timestamptz,
  CONSTRAINT business_trial_eligibility_reason_ok
    CHECK (consumed_reason IN ('automatic_trial', 'preexisting_owner')),
  CONSTRAINT business_trial_eligibility_window_ok
    CHECK (
      (
        consumed_reason = 'automatic_trial'
        AND trial_starts_at IS NOT NULL
        AND trial_expires_at IS NOT NULL
        AND (trial_expires_at = trial_starts_at + interval '7 days' OR trial_expires_at = trial_starts_at + interval '14 days')
      )
      OR (
        consumed_reason = 'preexisting_owner'
        AND trial_starts_at IS NULL
        AND trial_expires_at IS NULL
      )
    )
);

COMMENT ON TABLE public.business_trial_eligibility IS
  'One automatic trial claim per authenticated owner UUID. '
  'No FK to business_settings so delete/recreate cannot mint a second trial. '
  'preexisting_owner fences businesses that already existed when Phase 4F was applied; '
  'it does not create a trial entitlement.';

CREATE INDEX IF NOT EXISTS business_trial_eligibility_granted_idx
  ON public.business_trial_eligibility (granted_at DESC);

-- Block concurrent business_settings writes until COMMIT so the fence and
-- the AFTER INSERT trigger become visible together. SELECT stays allowed.
LOCK TABLE public.business_settings IN SHARE ROW EXCLUSIVE MODE;

-- Fence current businesses so a later delete/recreate cannot mint a trial.
-- Does not insert business_subscriptions rows and does not change Angel Touch / Test Barber entitlements.
INSERT INTO public.business_trial_eligibility (
  owner_user_id,
  first_business_id,
  granted_at,
  consumed_reason,
  trial_starts_at,
  trial_expires_at
)
SELECT
  s.business_id,
  s.business_id,
  now(),
  'preexisting_owner',
  NULL,
  NULL
FROM public.business_settings s
ON CONFLICT (owner_user_id) DO NOTHING;

ALTER TABLE public.business_trial_eligibility ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_trial_eligibility FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.business_trial_eligibility FROM PUBLIC;
REVOKE ALL ON TABLE public.business_trial_eligibility FROM anon;
REVOKE ALL ON TABLE public.business_trial_eligibility FROM authenticated;
GRANT SELECT ON TABLE public.business_trial_eligibility TO service_role;

-- -----------------------------------------------------------------------------
-- 4) Status helper: trial uses expires_at; paid/complimentary keep DATE rules
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._subscription_entitlement_status(
  p_access_kind text,
  p_expires_on date,
  p_expires_at timestamptz,
  p_as_of_date date,
  p_as_of_ts timestamptz
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_access_kind = 'trial' AND p_expires_at IS NOT NULL THEN
      CASE
        WHEN p_as_of_ts IS NULL THEN 'expired'
        WHEN p_expires_at > p_as_of_ts THEN 'active'
        ELSE 'expired'
      END
    WHEN p_expires_on IS NULL THEN 'active'
    WHEN p_as_of_date IS NULL THEN 'expired'
    WHEN p_expires_on >= p_as_of_date THEN 'active'
    ELSE 'expired'
  END;
$$;

COMMENT ON FUNCTION public._subscription_entitlement_status(text, date, timestamptz, date, timestamptz) IS
  'Trial status is timestamp-accurate. Paid and complimentary stay DATE-based. '
  'NULL expires_on still means unlimited complimentary.';

REVOKE ALL ON FUNCTION public._subscription_entitlement_status(text, date, timestamptz, date, timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._subscription_entitlement_status(text, date, timestamptz, date, timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public._subscription_entitlement_status(text, date, timestamptz, date, timestamptz) FROM authenticated;

-- -----------------------------------------------------------------------------
-- 5) Atomic grant used by the business_settings INSERT trigger
--    Authenticated: grant only when auth.uid() = p_business_id.
--    uid-less trusted insert: create the business, do not mint or consume a trial.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._try_grant_new_business_trial(p_business_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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
  v_expires_at := v_starts_at + interval '14 days';
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
    'Automatic 14-day XBOOK Business trial'
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
$$;

COMMENT ON FUNCTION public._try_grant_new_business_trial(uuid) IS
  'Internal one-time trial grant. Trigger-only. Requires auth.uid() = business_id. '
  'uid-less trusted inserts do not auto-grant. Never overwrites an existing entitlement.';

REVOKE ALL ON FUNCTION public._try_grant_new_business_trial(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._try_grant_new_business_trial(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._try_grant_new_business_trial(uuid) FROM authenticated;

CREATE OR REPLACE FUNCTION public._business_settings_after_insert_trial()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public._try_grant_new_business_trial(NEW.business_id);
  IF COALESCE(v_result->>'ok', 'false') <> 'true' THEN
    RAISE EXCEPTION 'automatic_trial_failed: %', COALESCE(v_result->>'error', 'unknown')
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._business_settings_after_insert_trial() IS
  'AFTER INSERT on business_settings. Grants a 14-day trial only when auth.uid() '
  'equals NEW.business_id. Trusted uid-less inserts are created without a trial. '
  'owner_mismatch and unexpected grant failures abort the business insert.';

REVOKE ALL ON FUNCTION public._business_settings_after_insert_trial() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._business_settings_after_insert_trial() FROM anon;
REVOKE ALL ON FUNCTION public._business_settings_after_insert_trial() FROM authenticated;

DROP TRIGGER IF EXISTS business_settings_after_insert_trial
  ON public.business_settings;

CREATE TRIGGER business_settings_after_insert_trial
  AFTER INSERT ON public.business_settings
  FOR EACH ROW
  EXECUTE FUNCTION public._business_settings_after_insert_trial();

-- Re-fence under the same table lock in case a row was inserted after the
-- first snapshot and before the trigger existed in this transaction.
INSERT INTO public.business_trial_eligibility (
  owner_user_id,
  first_business_id,
  granted_at,
  consumed_reason,
  trial_starts_at,
  trial_expires_at
)
SELECT
  s.business_id,
  s.business_id,
  now(),
  'preexisting_owner',
  NULL,
  NULL
FROM public.business_settings s
ON CONFLICT (owner_user_id) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6) Owner read RPC — trial timestamps + timestamp-accurate status
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_my_business_access()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_as_of date := CURRENT_DATE;
  v_as_of_ts timestamptz := clock_timestamp();
  v_row public.business_subscriptions%ROWTYPE;
  v_pkg public.subscription_packages%ROWTYPE;
  v_status text;
  v_unlimited boolean := false;
  v_label text := null;
  v_display_code text := 'unconfigured';
  v_remaining bigint := null;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Business owner only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_subscriptions
  WHERE business_id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'as_of_date', v_as_of,
      'as_of_at', v_as_of_ts,
      'business_id', v_uid,
      'configured', false,
      'status', 'unconfigured',
      'access_kind', null,
      'package_id', null,
      'package_label', null,
      'display_code', 'unconfigured',
      'price_eur', null,
      'access_months', null,
      'starts_on', null,
      'expires_on', null,
      'starts_at', null,
      'expires_at', null,
      'remaining_seconds', null,
      'unlimited', false,
      'starts_in_future', false,
      'activated_at', null
    );
  END IF;

  v_status := public._subscription_entitlement_status(
    v_row.access_kind,
    v_row.expires_on,
    v_row.expires_at,
    v_as_of,
    v_as_of_ts
  );
  v_unlimited := (v_row.access_kind = 'complimentary' AND v_row.expires_on IS NULL);

  IF v_row.expires_at IS NOT NULL THEN
    v_remaining := GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (v_row.expires_at - v_as_of_ts))))::bigint;
    IF v_status = 'expired' THEN
      v_remaining := 0;
    END IF;
  END IF;

  IF v_row.package_id IS NOT NULL THEN
    SELECT *
    INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_row.package_id;
  END IF;

  IF v_row.access_kind = 'complimentary' AND v_unlimited THEN
    v_display_code := 'complimentary_unlimited';
    v_label := 'FREE UNTIL CHANGED';
  ELSIF v_row.access_kind = 'complimentary' THEN
    v_display_code := 'complimentary';
    v_label := 'FREE';
  ELSIF v_row.access_kind = 'trial' THEN
    v_display_code := 'trial';
    v_label := 'XBOOK FREE TRIAL';
  ELSIF v_row.package_id IS NOT NULL THEN
    v_display_code := v_row.package_id;
    v_label := COALESCE(v_pkg.label, v_row.package_id);
  ELSE
    v_display_code := 'paid';
    v_label := COALESCE(v_pkg.label, 'XBOOK');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', v_as_of,
    'as_of_at', v_as_of_ts,
    'business_id', v_uid,
    'configured', true,
    'status', v_status,
    'access_kind', v_row.access_kind,
    'package_id', v_row.package_id,
    'package_label', v_label,
    'display_code', v_display_code,
    'price_eur', CASE
      WHEN v_row.access_kind = 'paid' THEN v_pkg.price_eur
      ELSE null
    END,
    'access_months', CASE
      WHEN v_row.access_kind = 'paid' THEN v_pkg.access_months
      ELSE null
    END,
    'starts_on', v_row.starts_on,
    'expires_on', v_row.expires_on,
    'starts_at', v_row.starts_at,
    'expires_at', v_row.expires_at,
    'remaining_seconds', v_remaining,
    'unlimited', v_unlimited,
    'starts_in_future', (v_row.starts_on IS NOT NULL AND v_row.starts_on > v_as_of),
    'activated_at', v_row.activated_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_business_access() IS
  'Owner-only read of the caller''s current subscription entitlement. '
  'Identity is auth.uid(). Trial status uses expires_at. '
  'Does not expose history, admin notes, or write operations.';

REVOKE ALL ON FUNCTION public.get_my_business_access() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_business_access() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_business_access() TO authenticated;

-- -----------------------------------------------------------------------------
-- 7) Admin preview/apply — replace an active trial; never auto-grant from here
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_preview_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_expires_on date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_as_of date := CURRENT_DATE;
  v_as_of_ts timestamptz := clock_timestamp();
  v_pkg public.subscription_packages%ROWTYPE;
  v_cur public.business_subscriptions%ROWTYPE;
  v_business_ok boolean;
  v_period record;
  v_current_status text;
  v_operation text := lower(btrim(COALESCE(p_operation, '')));
  v_package_id text := NULLIF(btrim(COALESCE(p_package_id, '')), '');
  v_starts_on date := p_starts_on;
  v_expires_on date := p_expires_on;
  v_new_starts date;
  v_new_expires date;
  v_new_kind text;
  v_is_revenue boolean := true;
  v_label text;
  v_current_is_trial boolean := false;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;
  IF v_operation NOT IN (
    'activate', 'extend',
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_paid', 'convert_to_complimentary'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.business_settings s WHERE s.business_id = p_business_id
  ) INTO v_business_ok;
  IF NOT v_business_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id;

  IF FOUND THEN
    v_current_status := public._subscription_entitlement_status(
      v_cur.access_kind, v_cur.expires_on, v_cur.expires_at, v_as_of, v_as_of_ts
    );
    v_current_is_trial := (v_cur.access_kind = 'trial');
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF v_operation IN ('activate', 'extend', 'convert_to_paid') THEN
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;

    SELECT * INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
    END IF;

    IF v_operation = 'activate' THEN
      IF v_current_status = 'active' AND NOT v_current_is_trial THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
    ELSIF v_operation = 'extend' THEN
      IF v_current_status = 'unconfigured' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
      END IF;
      IF COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_paid_subscription');
      END IF;
    ELSE
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    END IF;

    SELECT * INTO v_period
    FROM public._subscription_compute_period(
      CASE WHEN v_operation = 'extend' THEN 'extend' ELSE 'activate' END,
      v_starts_on,
      v_pkg.access_months,
      v_cur.starts_on,
      v_cur.expires_on,
      v_as_of
    );
    v_new_starts := v_period.new_starts_on;
    v_new_expires := v_period.new_expires_on;
    v_new_kind := 'paid';
    v_is_revenue := true;

    RETURN jsonb_build_object(
      'ok', true,
      'as_of_date', v_as_of,
      'operation', v_operation,
      'access_kind', v_new_kind,
      'previous_access_kind', v_cur.access_kind,
      'is_revenue', v_is_revenue,
      'unlimited', false,
      'package', jsonb_build_object(
        'package_id', v_pkg.package_id,
        'label', v_pkg.label,
        'paid_months', v_pkg.paid_months,
        'bonus_months', v_pkg.bonus_months,
        'access_months', v_pkg.access_months,
        'price_eur', v_pkg.price_eur
      ),
      'current_status', v_current_status,
      'previous_starts_on', v_cur.starts_on,
      'previous_expires_on', v_cur.expires_on,
      'new_starts_on', v_new_starts,
      'new_expires_on', v_new_expires,
      'resulting_status', public._subscription_row_status(v_new_expires, v_as_of),
      'preserves_remaining_access',
        (v_operation = 'extend' AND v_current_status = 'active')
    );
  END IF;

  v_is_revenue := false;
  v_new_kind := 'complimentary';

  IF v_operation = 'revoke_complimentary' THEN
    IF v_current_status = 'unconfigured'
       OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
    END IF;
    IF v_current_status IS DISTINCT FROM 'active' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'already_revoked');
    END IF;
    v_new_expires := v_as_of - 1;
    v_new_starts := LEAST(v_cur.starts_on, v_new_expires);
    v_label := 'FREE';
  ELSIF v_operation = 'extend_complimentary' THEN
    IF v_current_status = 'unconfigured'
       OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
    END IF;
    IF v_current_status IS DISTINCT FROM 'active' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_active_complimentary');
    END IF;
    IF v_cur.expires_on IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'cannot_extend_unlimited');
    END IF;
    IF v_expires_on IS NULL
       OR v_expires_on <= v_cur.expires_on
       OR v_expires_on < DATE '2018-01-01'
       OR v_expires_on > (v_as_of + 7300) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
    END IF;
    v_new_starts := v_cur.starts_on;
    v_new_expires := v_expires_on;
    v_label := 'FREE';
  ELSE
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;
    IF v_expires_on IS NOT NULL
       AND (
         v_expires_on < v_starts_on
         OR v_expires_on < DATE '2018-01-01'
         OR v_expires_on > (v_as_of + 7300)
       ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
    END IF;

    IF v_operation = 'grant_complimentary' THEN
      IF v_current_status = 'active' AND NOT v_current_is_trial THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
    ELSIF v_operation = 'replace_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    ELSE
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_paid_subscription');
      END IF;
    END IF;

    v_new_starts := v_starts_on;
    v_new_expires := v_expires_on;
    v_label := CASE
      WHEN v_new_expires IS NULL THEN 'FREE UNTIL CHANGED'
      ELSE 'FREE'
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', v_as_of,
    'operation', v_operation,
    'access_kind', v_new_kind,
    'previous_access_kind', v_cur.access_kind,
    'is_revenue', v_is_revenue,
    'unlimited', (v_new_expires IS NULL),
    'package', jsonb_build_object(
      'package_id', NULL,
      'label', v_label,
      'paid_months', 0,
      'bonus_months', 0,
      'access_months', 0,
      'price_eur', 0
    ),
    'current_status', v_current_status,
    'previous_starts_on', v_cur.starts_on,
    'previous_expires_on', v_cur.expires_on,
    'new_starts_on', v_new_starts,
    'new_expires_on', to_jsonb(v_new_expires),
    'resulting_status', public._subscription_row_status(v_new_expires, v_as_of),
    'preserves_remaining_access',
      (v_operation = 'extend_complimentary' AND v_current_status = 'active')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_note text,
  p_expires_on date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_as_of date := CURRENT_DATE;
  v_as_of_ts timestamptz := clock_timestamp();
  v_pkg public.subscription_packages%ROWTYPE;
  v_cur public.business_subscriptions%ROWTYPE;
  v_hist public.business_subscription_history%ROWTYPE;
  v_business_ok boolean;
  v_period record;
  v_current_status text;
  v_note text;
  v_history_id uuid;
  v_replay boolean := false;
  v_operation text := lower(btrim(COALESCE(p_operation, '')));
  v_package_id text := NULLIF(btrim(COALESCE(p_package_id, '')), '');
  v_starts_on date := p_starts_on;
  v_expires_on date := p_expires_on;
  v_new_starts date;
  v_new_expires date;
  v_new_kind text;
  v_store_package text;
  v_paid_months integer := 0;
  v_bonus_months integer := 0;
  v_access_months integer := 0;
  v_price numeric(10,2) := 0;
  v_requested_starts date;
  v_requested_expires date := p_expires_on;
  v_idem_package text;
  v_current_is_trial boolean := false;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;
  IF p_idempotency_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_idempotency_key');
  END IF;
  IF p_actor_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_actor');
  END IF;
  IF v_operation NOT IN (
    'activate', 'extend',
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_paid', 'convert_to_complimentary'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_note');
  END IF;

  IF v_operation = 'revoke_complimentary' AND v_starts_on IS NULL THEN
    v_starts_on := v_as_of;
  END IF;
  IF v_operation = 'extend_complimentary' AND v_starts_on IS NULL THEN
    v_starts_on := v_as_of;
  END IF;
  v_requested_starts := v_starts_on;
  IF v_operation IN ('activate', 'extend', 'convert_to_paid', 'revoke_complimentary') THEN
    v_requested_expires := NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-biz'), hashtext(p_business_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-idem'), hashtext(p_idempotency_key::text));

  IF v_operation IN (
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_complimentary'
  ) THEN
    v_idem_package := NULL;
  ELSE
    v_idem_package := v_package_id;
  END IF;

  SELECT * INTO v_hist
  FROM public.business_subscription_history
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_hist.business_id IS DISTINCT FROM p_business_id
       OR v_hist.operation IS DISTINCT FROM v_operation
       OR v_hist.package_id IS DISTINCT FROM v_idem_package
       OR v_hist.requested_starts_on IS DISTINCT FROM v_requested_starts
       OR v_hist.requested_expires_on IS DISTINCT FROM v_requested_expires THEN
      RETURN jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
    END IF;
    v_replay := true;
    SELECT * INTO v_cur
    FROM public.business_subscriptions
    WHERE business_id = p_business_id;

    RETURN jsonb_build_object(
      'ok', true,
      'replayed', true,
      'as_of_date', v_as_of,
      'history_id', v_hist.id,
      'subscription', jsonb_build_object(
        'business_id', p_business_id,
        'access_kind', COALESCE(v_cur.access_kind, v_hist.access_kind),
        'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
        'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
        'expires_on', to_jsonb(COALESCE(v_cur.expires_on, v_hist.new_expires_on)),
        'starts_at', to_jsonb(v_cur.starts_at),
        'expires_at', to_jsonb(v_cur.expires_at),
        'updated_at', v_cur.updated_at,
        'updated_by', v_cur.updated_by,
        'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
      ),
      'history', jsonb_build_object(
        'id', v_hist.id,
        'operation', v_hist.operation,
        'access_kind', v_hist.access_kind,
        'package_id', v_hist.package_id,
        'new_starts_on', v_hist.new_starts_on,
        'new_expires_on', to_jsonb(v_hist.new_expires_on)
      )
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings s
    WHERE s.business_id = p_business_id
    FOR UPDATE
  ) INTO v_business_ok;
  IF NOT v_business_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id
  FOR UPDATE;

  IF FOUND THEN
    v_current_status := public._subscription_entitlement_status(
      v_cur.access_kind, v_cur.expires_on, v_cur.expires_at, v_as_of, v_as_of_ts
    );
    v_current_is_trial := (v_cur.access_kind = 'trial');
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF v_operation IN ('activate', 'extend', 'convert_to_paid') THEN
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;

    SELECT * INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
    END IF;

    IF v_operation = 'activate'
       AND v_current_status = 'active'
       AND NOT v_current_is_trial THEN
      RETURN jsonb_build_object('ok', false, 'error', 'already_active');
    END IF;
    IF v_operation = 'extend' THEN
      IF v_current_status = 'unconfigured' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
      END IF;
      IF COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_paid_subscription');
      END IF;
    END IF;
    IF v_operation = 'convert_to_paid' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    END IF;

    SELECT * INTO v_period
    FROM public._subscription_compute_period(
      CASE WHEN v_operation = 'extend' THEN 'extend' ELSE 'activate' END,
      v_starts_on,
      v_pkg.access_months,
      v_cur.starts_on,
      v_cur.expires_on,
      v_as_of
    );
    v_new_starts := v_period.new_starts_on;
    v_new_expires := v_period.new_expires_on;
    v_new_kind := 'paid';
    v_store_package := v_pkg.package_id;
    v_paid_months := v_pkg.paid_months;
    v_bonus_months := v_pkg.bonus_months;
    v_access_months := v_pkg.access_months;
    v_price := v_pkg.price_eur;
  ELSE
    v_new_kind := 'complimentary';
    v_store_package := NULL;
    v_paid_months := 0;
    v_bonus_months := 0;
    v_access_months := 0;
    v_price := 0;

    IF v_operation = 'revoke_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
      IF v_current_status IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_revoked');
      END IF;
      v_new_expires := v_as_of - 1;
      v_new_starts := LEAST(v_cur.starts_on, v_new_expires);
    ELSIF v_operation = 'extend_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
      IF v_current_status IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_active_complimentary');
      END IF;
      IF v_cur.expires_on IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'cannot_extend_unlimited');
      END IF;
      IF v_expires_on IS NULL
         OR v_expires_on <= v_cur.expires_on
         OR v_expires_on < DATE '2018-01-01'
         OR v_expires_on > (v_as_of + 7300) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
      END IF;
      v_new_starts := v_cur.starts_on;
      v_new_expires := v_expires_on;
    ELSE
      IF v_starts_on IS NULL
         OR v_starts_on < DATE '2018-01-01'
         OR v_starts_on > (v_as_of + 366) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
      END IF;
      IF v_expires_on IS NOT NULL
         AND (
           v_expires_on < v_starts_on
           OR v_expires_on < DATE '2018-01-01'
           OR v_expires_on > (v_as_of + 7300)
         ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
      END IF;

      IF v_operation = 'grant_complimentary'
         AND v_current_status = 'active'
         AND NOT v_current_is_trial THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
      IF v_operation = 'replace_complimentary' THEN
        IF v_current_status = 'unconfigured'
           OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
        END IF;
      END IF;
      IF v_operation = 'convert_to_complimentary' THEN
        IF v_current_status = 'unconfigured'
           OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'no_paid_subscription');
        END IF;
      END IF;

      v_new_starts := v_starts_on;
      v_new_expires := v_expires_on;
    END IF;
  END IF;

  BEGIN
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
      p_idempotency_key,
      v_operation,
      v_store_package,
      v_new_kind,
      v_cur.access_kind,
      v_paid_months,
      v_bonus_months,
      v_access_months,
      v_price,
      v_requested_starts,
      v_requested_expires,
      v_cur.package_id,
      v_cur.starts_on,
      v_cur.expires_on,
      v_cur.starts_at,
      v_cur.expires_at,
      v_new_starts,
      v_new_expires,
      NULL,
      NULL,
      p_actor_user_id,
      v_note
    )
    RETURNING id INTO v_history_id;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT * INTO v_hist
      FROM public.business_subscription_history
      WHERE idempotency_key = p_idempotency_key;
      IF NOT FOUND THEN
        RAISE;
      END IF;
      IF v_hist.business_id IS DISTINCT FROM p_business_id
         OR v_hist.operation IS DISTINCT FROM v_operation THEN
        RETURN jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
      END IF;
      SELECT * INTO v_cur
      FROM public.business_subscriptions
      WHERE business_id = p_business_id;
      RETURN jsonb_build_object(
        'ok', true,
        'replayed', true,
        'as_of_date', v_as_of,
        'history_id', v_hist.id,
        'subscription', jsonb_build_object(
          'business_id', p_business_id,
          'access_kind', COALESCE(v_cur.access_kind, v_hist.access_kind),
          'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
          'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
          'expires_on', to_jsonb(COALESCE(v_cur.expires_on, v_hist.new_expires_on)),
          'starts_at', to_jsonb(v_cur.starts_at),
          'expires_at', to_jsonb(v_cur.expires_at),
          'updated_at', v_cur.updated_at,
          'updated_by', v_cur.updated_by,
          'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
        ),
        'history', jsonb_build_object(
          'id', v_hist.id,
          'operation', v_hist.operation,
          'access_kind', v_hist.access_kind,
          'package_id', v_hist.package_id,
          'new_starts_on', v_hist.new_starts_on,
          'new_expires_on', to_jsonb(v_hist.new_expires_on)
        )
      );
  END;

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
    v_store_package,
    v_new_kind,
    v_new_starts,
    v_new_expires,
    NULL,
    NULL,
    now(),
    now(),
    p_actor_user_id,
    v_history_id
  )
  ON CONFLICT (business_id) DO UPDATE
  SET package_id = EXCLUDED.package_id,
      access_kind = EXCLUDED.access_kind,
      starts_on = EXCLUDED.starts_on,
      expires_on = EXCLUDED.expires_on,
      starts_at = NULL,
      expires_at = NULL,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by,
      last_history_id = EXCLUDED.last_history_id,
      activated_at = CASE
        WHEN public._subscription_entitlement_status(
          public.business_subscriptions.access_kind,
          public.business_subscriptions.expires_on,
          public.business_subscriptions.expires_at,
          v_as_of,
          v_as_of_ts
        ) = 'active'
        AND public.business_subscriptions.access_kind IS NOT DISTINCT FROM EXCLUDED.access_kind
          THEN public.business_subscriptions.activated_at
        ELSE EXCLUDED.activated_at
      END;

  RETURN jsonb_build_object(
    'ok', true,
    'replayed', false,
    'as_of_date', v_as_of,
    'history_id', v_history_id,
    'subscription', jsonb_build_object(
      'business_id', p_business_id,
      'access_kind', v_new_kind,
      'package_id', v_store_package,
      'starts_on', v_new_starts,
      'expires_on', to_jsonb(v_new_expires),
      'starts_at', null,
      'expires_at', null,
      'updated_by', p_actor_user_id,
      'last_history_id', v_history_id
    ),
    'history', jsonb_build_object(
      'id', v_history_id,
      'operation', v_operation,
      'access_kind', v_new_kind,
      'package_id', v_store_package,
      'new_starts_on', v_new_starts,
      'new_expires_on', to_jsonb(v_new_expires)
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_preview_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_preview_business_subscription(
    p_business_id, p_package_id, p_operation, p_starts_on, NULL::date
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_apply_business_subscription(
    p_business_id,
    p_package_id,
    p_operation,
    p_starts_on,
    p_idempotency_key,
    p_actor_user_id,
    p_note,
    NULL::date
  );
$$;

COMMENT ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) IS
  'Privileged Control Center preview. Paid math unchanged. Complimentary is not revenue. '
  'Active trial may be replaced by activate or grant_complimentary.';

COMMENT ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) IS
  'Paid-compatible wrapper. Calls the five-argument preview with p_expires_on NULL.';

COMMENT ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) IS
  'Privileged Control Center RPC. service_role only. Complimentary stores price_eur = 0. '
  'Replaces an automatic trial. Does not auto-grant trials or assign Angel Touch.';

COMMENT ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) IS
  'Paid-compatible wrapper. Calls the eight-argument apply with p_expires_on NULL.';

REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date)
  TO service_role;

-- Tables stay RPC-only. Reaffirm no client SELECT/INSERT/UPDATE.
REVOKE ALL ON TABLE public.subscription_packages FROM PUBLIC;
REVOKE ALL ON TABLE public.subscription_packages FROM anon;
REVOKE ALL ON TABLE public.subscription_packages FROM authenticated;
REVOKE ALL ON TABLE public.business_subscriptions FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscriptions FROM anon;
REVOKE ALL ON TABLE public.business_subscriptions FROM authenticated;
REVOKE ALL ON TABLE public.business_subscription_history FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscription_history FROM anon;
REVOKE ALL ON TABLE public.business_subscription_history FROM authenticated;
REVOKE ALL ON TABLE public.business_trial_eligibility FROM PUBLIC;
REVOKE ALL ON TABLE public.business_trial_eligibility FROM anon;
REVOKE ALL ON TABLE public.business_trial_eligibility FROM authenticated;

COMMIT;

-- =============================================================================
-- POST-APPLY CHECKS (run separately, read-only)
-- =============================================================================
-- SELECT tgname FROM pg_trigger
-- WHERE tgrelid = 'public.business_settings'::regclass
--   AND tgname = 'business_settings_after_insert_trial';
--
-- SELECT bs.business_slug, sub.access_kind, sub.expires_on, sub.expires_at
-- FROM public.business_settings bs
-- LEFT JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
-- ORDER BY bs.business_slug;
-- Expect angel-touch complimentary unchanged; gorge123 still unconfigured.
-- =============================================================================
