-- =============================================================================
-- XBOOK Phase 4E — Server-side subscription enforcement for bookings
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Do NOT run from the XBOOK iOS / Android / web apps.
-- Safe to re-run (CREATE OR REPLACE / DROP TRIGGER IF EXISTS / rename-once).
--
-- Requires already-applied:
--   supabase-platform-subscriptions-v1.sql
--   supabase-platform-subscriptions-v1-plans.sql
--   supabase-platform-subscriptions-v1-access.sql
--   supabase-platform-subscriptions-v1-owner-read.sql
--   supabase-platform-subscriptions-v1-trial.sql   (LIVE Phase 4F)
--
-- This file does NOT:
--   • change Phase 4F trial grant, eligibility, or fencing
--   • change package pricing or ACC apply/preview
--   • delete, cancel, or rewrite existing bookings
--   • block calendar reads, settings, or support
--   • change booking RLS, membership, conflicts, or slot rules
--   • re-enable Google or Apple Sign In
--
-- A business may accept a new booking only when its current entitlement is
-- active: trial (expires_at), paid (expires_on / starts_on), or complimentary
-- (including FREE UNTIL CHANGED). Unconfigured, expired, and not-yet-started
-- rows are rejected inside the same transaction as the write.
-- =============================================================================

BEGIN;

-- Live already has this helper. Recreate only if a prior booking migration
-- was never applied, so the trigger can classify pending/confirmed rows.
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

-- -----------------------------------------------------------------------------
-- 1) Authoritative entitlement gate
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- 2) Bookings trigger — INSERT plus reschedule / reactivate UPDATE
--    Covers create_booking, create_recurring_bookings, manage-token reschedule,
--    and owner bookings_api UPDATE (saveEditedBooking).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._enforce_bookings_subscription()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_active boolean;
  v_was_active boolean;
BEGIN
  v_is_active := public._booking_active_status(
    coalesce(NEW.booking_status::text, NEW.status::text)
  );

  IF TG_OP = 'INSERT' THEN
    IF v_is_active THEN
      PERFORM public._assert_business_can_accept_bookings(NEW.business_id);
    END IF;
    RETURN NEW;
  END IF;

  v_was_active := public._booking_active_status(
    coalesce(OLD.booking_status::text, OLD.status::text)
  );

  IF v_is_active AND (
       NEW.date IS DISTINCT FROM OLD.date
    OR NEW.time IS DISTINCT FROM OLD.time
    OR NOT v_was_active
  ) THEN
    PERFORM public._assert_business_can_accept_bookings(NEW.business_id);
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._enforce_bookings_subscription() IS
  'Rejects new or rescheduled active bookings when subscription access is not active. '
  'Cancel and non-slot edits of existing rows are allowed.';

REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM anon;
REVOKE ALL ON FUNCTION public._enforce_bookings_subscription() FROM authenticated;

DROP TRIGGER IF EXISTS bookings_enforce_subscription ON public.bookings;
CREATE TRIGGER bookings_enforce_subscription
  BEFORE INSERT OR UPDATE OF date, time, booking_status, status
  ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public._enforce_bookings_subscription();

-- -----------------------------------------------------------------------------
-- 3) RPC wrappers — same signatures, existing bodies preserved
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regprocedure(
       'public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._create_booking_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'
     ) IS NULL
  THEN
    ALTER FUNCTION public.create_booking(
      uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
    ) RENAME TO _create_booking_pre_subscription;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
       'public._create_booking_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Phase 4E: public.create_booking(...) is missing; cannot wrap.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_booking(
  p_business_id        uuid,
  p_service_id         uuid,
  p_date               date,
  p_time               time,
  p_customer_name      text,
  p_customer_phone     text,
  p_customer_email     text DEFAULT NULL,
  p_notes              text DEFAULT NULL,
  p_staff_id           uuid DEFAULT NULL,
  p_customer_user_id   uuid DEFAULT NULL,
  p_booking_status     text DEFAULT 'Pending'
)
RETURNS public.bookings
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public._assert_business_can_accept_bookings(p_business_id);
  RETURN public._create_booking_pre_subscription(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_notes,
    p_staff_id,
    p_customer_user_id,
    p_booking_status
  );
END;
$function$;

COMMENT ON FUNCTION public.create_booking(uuid, uuid, date, time, text, text, text, text, uuid, uuid, text) IS
  'Live create_booking wrapper: subscription gate, then the previously deployed body.';

REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_booking(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public._create_booking_pre_subscription(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._create_booking_pre_subscription(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text
) FROM anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure(
       'public.create_recurring_bookings(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._create_recurring_bookings_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)'
     ) IS NULL
  THEN
    ALTER FUNCTION public.create_recurring_bookings(
      uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
    ) RENAME TO _create_recurring_bookings_pre_subscription;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
       'public._create_recurring_bookings_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Phase 4E: public.create_recurring_bookings(...) is missing; cannot wrap.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.create_recurring_bookings(
  p_business_id        uuid,
  p_service_id         uuid,
  p_date               date,
  p_time               time,
  p_customer_name      text,
  p_customer_phone     text,
  p_customer_email     text DEFAULT NULL,
  p_notes              text DEFAULT NULL,
  p_staff_id           uuid DEFAULT NULL,
  p_customer_user_id   uuid DEFAULT NULL,
  p_booking_status     text DEFAULT 'Pending',
  p_recurring_rule     text DEFAULT NULL,
  p_recurring_count    integer DEFAULT NULL
)
RETURNS public.bookings
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $function$
BEGIN
  PERFORM public._assert_business_can_accept_bookings(p_business_id);
  RETURN public._create_recurring_bookings_pre_subscription(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_notes,
    p_staff_id,
    p_customer_user_id,
    p_booking_status,
    p_recurring_rule,
    p_recurring_count
  );
END;
$function$;

COMMENT ON FUNCTION public.create_recurring_bookings(uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer) IS
  'Live create_recurring_bookings wrapper: subscription gate, then the previously deployed body.';

REVOKE ALL ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_recurring_bookings(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public._create_recurring_bookings_pre_subscription(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._create_recurring_bookings_pre_subscription(
  uuid, uuid, date, time, text, text, text, text, uuid, uuid, text, text, integer
) FROM anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure(
       'public.reschedule_booking_by_manage_token(text,date,time)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._reschedule_booking_by_manage_token_pre_subscription(text,date,time)'
     ) IS NULL
  THEN
    ALTER FUNCTION public.reschedule_booking_by_manage_token(text, date, time)
      RENAME TO _reschedule_booking_by_manage_token_pre_subscription;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
       'public._reschedule_booking_by_manage_token_pre_subscription(text,date,time)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Phase 4E: reschedule_booking_by_manage_token(text,date,time) is missing; cannot wrap.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date date,
  p_time time without time zone
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token text := nullif(trim(p_manage_token), '');
  v_business_id uuid;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.business_id
  INTO v_business_id
  FROM public.bookings b
  WHERE b.manage_token = v_token;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  PERFORM public._assert_business_can_accept_bookings(v_business_id);
  RETURN public._reschedule_booking_by_manage_token_pre_subscription(
    p_manage_token,
    p_date,
    p_time
  );
END;
$$;

COMMENT ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) IS
  'Manage-token reschedule wrapper: subscription gate, then the previously deployed body.';

REVOKE ALL ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time)
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public._reschedule_booking_by_manage_token_pre_subscription(text, date, time)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public._reschedule_booking_by_manage_token_pre_subscription(text, date, time)
  FROM anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure(
       'public.reschedule_booking_by_manage_token(text,date,text)'
     ) IS NOT NULL
     AND to_regprocedure(
       'public._reschedule_booking_by_manage_token_pre_subscription(text,date,text)'
     ) IS NULL
  THEN
    ALTER FUNCTION public.reschedule_booking_by_manage_token(text, date, text)
      RENAME TO _reschedule_booking_by_manage_token_pre_subscription;
  END IF;
END $$;

DO $$
BEGIN
  IF to_regprocedure(
       'public._reschedule_booking_by_manage_token_pre_subscription(text,date,text)'
     ) IS NULL
  THEN
    RAISE EXCEPTION 'Phase 4E: reschedule_booking_by_manage_token(text,date,text) is missing; cannot wrap.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.reschedule_booking_by_manage_token(
  p_manage_token text,
  p_date date,
  p_time text
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_token text := nullif(trim(p_manage_token), '');
  v_business_id uuid;
BEGIN
  IF v_token IS NULL THEN
    RAISE EXCEPTION 'Manage link is invalid.' USING ERRCODE = 'P0001';
  END IF;

  SELECT b.business_id
  INTO v_business_id
  FROM public.bookings b
  WHERE b.manage_token = v_token;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Booking not found.' USING ERRCODE = 'P0001';
  END IF;

  PERFORM public._assert_business_can_accept_bookings(v_business_id);
  RETURN public._reschedule_booking_by_manage_token_pre_subscription(
    p_manage_token,
    p_date,
    p_time
  );
END;
$$;

COMMENT ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) IS
  'Manage-token reschedule (text time) wrapper: subscription gate, then the previously deployed body.';

REVOKE ALL ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text)
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public._reschedule_booking_by_manage_token_pre_subscription(text, date, text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public._reschedule_booking_by_manage_token_pre_subscription(text, date, text)
  FROM anon, authenticated;

COMMIT;
