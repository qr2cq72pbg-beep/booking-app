-- XBOOK: Per-customer appointment reminder preferences (Client V1).
-- Run in Supabase Dashboard -> SQL Editor.
-- Safe to re-run (idempotent).
--
-- Preferences are owned by auth.uid(). They are not per-business and not
-- per-device. Local OS reminder scheduling stays on the native app.
--
-- 2026-09-30: adds appointment_reminders_enabled (master switch for
-- appointment Local Notifications only). If an earlier version of this
-- file was already applied, re-run this entire script.

BEGIN;

CREATE TABLE IF NOT EXISTS public.customer_notification_preferences (
  customer_user_id uuid PRIMARY KEY
    REFERENCES auth.users (id) ON DELETE CASCADE,
  reminder_1_enabled boolean NOT NULL DEFAULT true,
  reminder_2_enabled boolean NOT NULL DEFAULT true,
  reminder_2_offset_minutes integer NOT NULL DEFAULT 120,
  appointment_reminders_enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_notification_preferences_r2_offset_chk
    CHECK (reminder_2_offset_minutes IN (15, 30, 60, 120, 180, 360, 720))
);

ALTER TABLE public.customer_notification_preferences
  ADD COLUMN IF NOT EXISTS appointment_reminders_enabled boolean NOT NULL DEFAULT true;

COMMENT ON TABLE public.customer_notification_preferences IS
  'Client appointment reminder preferences for auth.uid(). Reminder 1 is always 24h when enabled. Reminder 2 offset cannot equal 24h. appointment_reminders_enabled is the master schedule switch.';

COMMENT ON COLUMN public.customer_notification_preferences.reminder_1_enabled IS
  'When true, schedule a local reminder 24 hours before each upcoming appointment (if the master switch is on).';

COMMENT ON COLUMN public.customer_notification_preferences.reminder_2_enabled IS
  'When true, schedule a second local reminder at reminder_2_offset_minutes before the appointment (if the master switch is on).';

COMMENT ON COLUMN public.customer_notification_preferences.reminder_2_offset_minutes IS
  'Minutes before the appointment for reminder 2. Allowed: 15, 30, 60, 120, 180, 360, 720.';

COMMENT ON COLUMN public.customer_notification_preferences.appointment_reminders_enabled IS
  'Master switch. When false, do not schedule appointment Local Notifications. Reminder 1 / Reminder 2 values are preserved.';

ALTER TABLE public.customer_notification_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_notification_preferences_self_select
  ON public.customer_notification_preferences;
CREATE POLICY customer_notification_preferences_self_select
  ON public.customer_notification_preferences
  FOR SELECT
  TO authenticated
  USING (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_notification_preferences_self_insert
  ON public.customer_notification_preferences;
CREATE POLICY customer_notification_preferences_self_insert
  ON public.customer_notification_preferences
  FOR INSERT
  TO authenticated
  WITH CHECK (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_notification_preferences_self_update
  ON public.customer_notification_preferences;
CREATE POLICY customer_notification_preferences_self_update
  ON public.customer_notification_preferences
  FOR UPDATE
  TO authenticated
  USING (customer_user_id = auth.uid())
  WITH CHECK (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_notification_preferences_self_delete
  ON public.customer_notification_preferences;
CREATE POLICY customer_notification_preferences_self_delete
  ON public.customer_notification_preferences
  FOR DELETE
  TO authenticated
  USING (customer_user_id = auth.uid());

REVOKE ALL ON public.customer_notification_preferences FROM PUBLIC;
REVOKE ALL ON public.customer_notification_preferences FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_notification_preferences TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_notification_preferences TO service_role;

CREATE OR REPLACE FUNCTION public.get_customer_notification_preferences()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_row public.customer_notification_preferences%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer preferences only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_row
  FROM public.customer_notification_preferences
  WHERE customer_user_id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'reminder_1_enabled', true,
      'reminder_2_enabled', true,
      'reminder_2_offset_minutes', 120,
      'appointment_reminders_enabled', true,
      'updated_at', NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'reminder_1_enabled', v_row.reminder_1_enabled,
    'reminder_2_enabled', v_row.reminder_2_enabled,
    'reminder_2_offset_minutes', v_row.reminder_2_offset_minutes,
    'appointment_reminders_enabled', v_row.appointment_reminders_enabled,
    'updated_at', v_row.updated_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_customer_notification_preferences() IS
  'Returns appointment reminder preferences for auth.uid(). Defaults (master on, 24h + 2h on) if no row exists.';

DROP FUNCTION IF EXISTS public.save_customer_notification_preferences(boolean, boolean, integer);

CREATE OR REPLACE FUNCTION public.save_customer_notification_preferences(
  p_reminder_1_enabled boolean,
  p_reminder_2_enabled boolean,
  p_reminder_2_offset_minutes integer,
  p_appointment_reminders_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_offset integer := p_reminder_2_offset_minutes;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer preferences only.' USING ERRCODE = 'P0001';
  END IF;

  IF v_offset IS NULL OR v_offset NOT IN (15, 30, 60, 120, 180, 360, 720) THEN
    RAISE EXCEPTION 'Choose a valid second-reminder interval.' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.customer_notification_preferences (
    customer_user_id,
    reminder_1_enabled,
    reminder_2_enabled,
    reminder_2_offset_minutes,
    appointment_reminders_enabled,
    updated_at
  )
  VALUES (
    v_uid,
    coalesce(p_reminder_1_enabled, true),
    coalesce(p_reminder_2_enabled, true),
    v_offset,
    coalesce(p_appointment_reminders_enabled, true),
    now()
  )
  ON CONFLICT (customer_user_id)
  DO UPDATE SET
    reminder_1_enabled = EXCLUDED.reminder_1_enabled,
    reminder_2_enabled = EXCLUDED.reminder_2_enabled,
    reminder_2_offset_minutes = EXCLUDED.reminder_2_offset_minutes,
    appointment_reminders_enabled = EXCLUDED.appointment_reminders_enabled,
    updated_at = now();

  RETURN public.get_customer_notification_preferences();
END;
$$;

COMMENT ON FUNCTION public.save_customer_notification_preferences(boolean, boolean, integer, boolean) IS
  'Upserts appointment reminder preferences for auth.uid(), including the master appointment_reminders_enabled switch.';

REVOKE ALL ON FUNCTION public.get_customer_notification_preferences() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_notification_preferences() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_customer_notification_preferences() TO authenticated;

REVOKE ALL ON FUNCTION public.save_customer_notification_preferences(boolean, boolean, integer, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_customer_notification_preferences(boolean, boolean, integer, boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_customer_notification_preferences(boolean, boolean, integer, boolean) TO authenticated;

COMMIT;
