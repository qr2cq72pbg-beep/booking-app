-- XBOOK: customer_notification_preferences smoke checks.
-- Run after supabase-customer-notification-preferences.sql while signed in as a customer.
-- Isolation is enforced by RLS: customer_user_id = auth.uid().
-- These RPCs do not accept a client-supplied user id.

BEGIN;

DO $$
DECLARE
  v_uid uuid := auth.uid();
  v_got jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE NOTICE 'Skipped: sign in as a customer before running this check.';
    RETURN;
  END IF;

  v_got := public.get_customer_notification_preferences();
  IF coalesce((v_got->>'reminder_2_offset_minutes')::int, 0) NOT IN (15, 30, 60, 120, 180, 360, 720) THEN
    RAISE EXCEPTION 'get_customer_notification_preferences returned an invalid offset';
  END IF;
  IF (v_got->>'appointment_reminders_enabled') IS NULL THEN
    RAISE EXCEPTION 'get_customer_notification_preferences missing appointment_reminders_enabled';
  END IF;

  v_got := public.save_customer_notification_preferences(true, true, 60, false);
  IF (v_got->>'reminder_1_enabled')::boolean IS NOT TRUE
     OR (v_got->>'reminder_2_enabled')::boolean IS NOT TRUE
     OR (v_got->>'reminder_2_offset_minutes')::int IS DISTINCT FROM 60
     OR (v_got->>'appointment_reminders_enabled')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'save did not persist master-off while keeping reminder 1/2';
  END IF;

  v_got := public.save_customer_notification_preferences(true, true, 120, true);
  IF (v_got->>'reminder_1_enabled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'save_customer_notification_preferences did not persist reminder 1';
  END IF;
  IF (v_got->>'appointment_reminders_enabled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'save_customer_notification_preferences did not restore master on';
  END IF;

  RAISE NOTICE 'customer_notification_preferences smoke check passed for %', v_uid;
END;
$$;

COMMIT;
