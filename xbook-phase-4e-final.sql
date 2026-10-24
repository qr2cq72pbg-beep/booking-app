-- =============================================================================
-- XBOOK Phase 4E — Server-side subscription enforcement for bookings
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Do NOT run from the XBOOK iOS / Android / web apps.
-- Safe to re-run (CREATE OR REPLACE / DROP TRIGGER IF EXISTS).
--
-- Requires already-applied Phase 4F:
--   supabase-platform-subscriptions-v1-trial.sql
--   (and its subscription prerequisites)
--
-- This file does NOT:
--   • rename, replace, or wrap create_booking / create_recurring_bookings
--     / reschedule_booking_by_manage_token
--   • change Phase 4F trial grant, eligibility, or fencing
--   • change package pricing, ACC, or existing subscription rows
--   • delete, cancel, or rewrite existing bookings
--   • block calendar reads, settings, history, or cancel
--   • change booking RLS, membership, conflicts, or slot rules
--
-- Enforcement is a BEFORE INSERT/UPDATE trigger on public.bookings.
-- create_booking, create_recurring_bookings, manage-token reschedule, and
-- owner bookings_api UPDATEs all write that table, so they are covered
-- without changing those function bodies.
-- =============================================================================

BEGIN;

-- Live already has this helper. Create only if missing so the trigger can
-- classify pending/confirmed rows the same way as existing booking RPCs.
DO $$
BEGIN
  IF to_regprocedure('public._booking_active_status(text)') IS NULL THEN
    EXECUTE $fn$
      CREATE FUNCTION public._booking_active_status(s text)
      RETURNS boolean
      LANGUAGE sql
      IMMUTABLE
      AS $body$
        SELECT lower(trim(coalesce(s, 'Pending'))) IN ('pending', 'confirmed');
      $body$;
    $fn$;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public._assert_business_can_accept_bookings(p_business_id uuid)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_today date := CURRENT_DATE;
  v_sub public.business_subscriptions%ROWTYPE;
  v_status text;
  v_settings_ok boolean;
BEGIN
  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'subscription_unconfigured' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings s
    WHERE s.business_id = p_business_id
    FOR UPDATE
  ) INTO v_settings_ok;
  IF NOT v_settings_ok THEN
    RAISE EXCEPTION 'subscription_unconfigured' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_sub
  FROM public.business_subscriptions
  WHERE business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'subscription_unconfigured' USING ERRCODE = 'P0001';
  END IF;

  IF v_sub.starts_at IS NOT NULL AND v_sub.starts_at > v_now THEN
    RAISE EXCEPTION 'subscription_not_started' USING ERRCODE = 'P0001';
  END IF;
  IF v_sub.starts_on IS NOT NULL AND v_sub.starts_on > v_today THEN
    RAISE EXCEPTION 'subscription_not_started' USING ERRCODE = 'P0001';
  END IF;

  v_status := public._subscription_entitlement_status(
    v_sub.access_kind,
    v_sub.expires_on,
    v_sub.expires_at,
    v_today,
    v_now
  );
  IF v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'subscription_expired' USING ERRCODE = 'P0001';
  END IF;
END;
$$;

COMMENT ON FUNCTION public._assert_business_can_accept_bookings(uuid) IS
  'Blocks new booking writes unless the business entitlement is active. '
  'Errors: subscription_unconfigured | subscription_expired | subscription_not_started. '
  'Does not expose package, price, or expiry values.';

REVOKE ALL ON FUNCTION public._assert_business_can_accept_bookings(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_business_can_accept_bookings(uuid) FROM anon;
REVOKE ALL ON FUNCTION public._assert_business_can_accept_bookings(uuid) FROM authenticated;

CREATE OR REPLACE FUNCTION public._enforce_bookings_subscription()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_active boolean;
  v_was_active boolean;
  v_needs_check boolean := false;
BEGIN
  v_is_active := public._booking_active_status(
    coalesce(NEW.booking_status::text, NEW.status::text)
  );

  IF TG_OP = 'INSERT' THEN
    v_needs_check := v_is_active;
  ELSE
    v_was_active := public._booking_active_status(
      coalesce(OLD.booking_status::text, OLD.status::text)
    );
    v_needs_check := v_is_active AND (
         NEW.date IS DISTINCT FROM OLD.date
      OR NEW.time IS DISTINCT FROM OLD.time
      OR NEW.business_id IS DISTINCT FROM OLD.business_id
      OR NOT v_was_active
    );
  END IF;

  IF v_needs_check THEN
    PERFORM public._assert_business_can_accept_bookings(NEW.business_id);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._enforce_bookings_subscription() IS
  'Rejects new, rescheduled, reactivated, or reassigned active bookings when '
  'subscription access is not active. Cancel and non-slot edits are allowed.';

REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM anon;
REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM authenticated;

DROP TRIGGER IF EXISTS bookings_enforce_subscription ON public.bookings;
CREATE TRIGGER bookings_enforce_subscription
  BEFORE INSERT OR UPDATE OF date, time, booking_status, status, business_id
  ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_bookings_subscription();

COMMIT;
