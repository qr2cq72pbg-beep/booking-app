-- =============================================================================
-- GT Termin — Employee push notifications (Phase F4)
-- =============================================================================
-- Requires supabase-staff-access-v1.sql (F3).
--
-- Adds (no existing function, policy or trigger is changed):
--   1) public.staff_push_tokens  — device tokens of signed-in team members
--   2) upsert_staff_push_token / delete_staff_push_token (employee session)
--   3) public.staff_push_events — outbox, one row per recipient and change,
--      UNIQUE (staff_id, dedupe_key) so the same event is never queued twice
--   4) bookings_enqueue_staff_push — AFTER INSERT/UPDATE trigger on bookings.
--      Wrapped in its own exception block: a push problem can never block or
--      roll back a booking. Recipients follow _staff_can_see_booking (F3).
--   5) send-staff-booking-push webhook (AFTER INSERT on staff_push_events),
--      same pattern as the existing send-customer-booking-push webhook: the
--      function only processes events it loads and claims from the database.
--
-- Events: new · rescheduled · cancelled · assigned (to me) · unassigned (from
-- me) · reassigned (info for "all appointments" members). Recurring series:
-- one push per recipient per transaction, not one per occurrence.
-- Payload: date, time, duration, service, staff name. No customer data, no
-- prices.
--
-- Safe to re-run. Rollback at the end (commented out).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Device tokens of team members
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_push_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id     uuid NOT NULL REFERENCES public.staff_members (id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  business_id  uuid NOT NULL,
  device_token text NOT NULL,
  platform     text NOT NULL,
  locale       text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_push_tokens_device_token_uniq UNIQUE (device_token),
  CONSTRAINT staff_push_tokens_platform_ok CHECK (platform IN ('ios', 'android')),
  CONSTRAINT staff_push_tokens_locale_ok CHECK (locale IS NULL OR locale IN ('en', 'mk', 'sq'))
);
CREATE INDEX IF NOT EXISTS staff_push_tokens_staff_idx ON public.staff_push_tokens (staff_id);

ALTER TABLE public.staff_push_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.staff_push_tokens FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.staff_push_tokens TO service_role;

CREATE OR REPLACE FUNCTION public.upsert_staff_push_token(
  p_device_token text,
  p_platform     text,
  p_locale       text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member   public.staff_members;
  v_token    text := trim(coalesce(p_device_token, ''));
  v_platform text := lower(trim(coalesce(p_platform, '')));
  v_locale   text := nullif(lower(trim(coalesce(p_locale, ''))), '');
BEGIN
  v_member := public._staff_access_member();
  IF v_member.id IS NULL THEN
    RAISE EXCEPTION 'Team member access is not active.' USING ERRCODE = '42501';
  END IF;
  IF length(v_token) < 20 OR length(v_token) > 4096 OR v_platform NOT IN ('ios', 'android') THEN
    RAISE EXCEPTION 'Invalid push token.' USING ERRCODE = 'P0001';
  END IF;
  IF v_locale IS NOT NULL AND v_locale NOT IN ('en', 'mk', 'sq') THEN
    v_locale := NULL;
  END IF;
  -- A physical device belongs to whoever signed in on it last.
  INSERT INTO public.staff_push_tokens (staff_id, user_id, business_id, device_token, platform, locale)
  VALUES (v_member.id, auth.uid(), v_member.business_id, v_token, v_platform, v_locale)
  ON CONFLICT (device_token) DO UPDATE SET
    staff_id = EXCLUDED.staff_id,
    user_id = EXCLUDED.user_id,
    business_id = EXCLUDED.business_id,
    platform = EXCLUDED.platform,
    locale = coalesce(EXCLUDED.locale, public.staff_push_tokens.locale),
    last_seen_at = now();
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_staff_push_token(p_device_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;
  DELETE FROM public.staff_push_tokens
  WHERE device_token = trim(coalesce(p_device_token, '')) AND user_id = auth.uid();
  RETURN FOUND;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2) Outbox
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_push_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL,
  booking_id  uuid NOT NULL,
  staff_id    uuid NOT NULL REFERENCES public.staff_members (id) ON DELETE CASCADE,
  event_type  text NOT NULL,
  dedupe_key  text NOT NULL,
  payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz,
  result      text,
  CONSTRAINT staff_push_events_type_ok CHECK (
    event_type IN ('new', 'rescheduled', 'cancelled', 'assigned', 'unassigned', 'reassigned')
  ),
  CONSTRAINT staff_push_events_dedupe_uniq UNIQUE (staff_id, dedupe_key)
);
CREATE INDEX IF NOT EXISTS staff_push_events_created_idx ON public.staff_push_events (created_at DESC);

ALTER TABLE public.staff_push_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.staff_push_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.staff_push_events TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Enqueue on booking changes (never blocks the booking)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._enqueue_staff_booking_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new_active    boolean;
  v_old_active    boolean := false;
  v_is_new        boolean := false;
  v_cancelled     boolean := false;
  v_staff_changed boolean := false;
  v_moved         boolean := false;
  v_slot_old      text := '';
  v_slot_new      text;
  v_type          text;
  v_key           text;
  v_payload       jsonb;
  v_staff         public.staff_members;
BEGIN
  BEGIN
    v_new_active := public._booking_active_status(coalesce(NEW.booking_status::text, NEW.status::text));
    IF TG_OP = 'INSERT' THEN
      v_is_new := v_new_active;
    ELSE
      v_old_active := public._booking_active_status(coalesce(OLD.booking_status::text, OLD.status::text));
      v_is_new := v_new_active AND NOT v_old_active;                  -- re-activated
      v_cancelled := v_old_active AND NOT v_new_active;
      v_staff_changed := v_new_active AND v_old_active AND NEW.staff_id IS DISTINCT FROM OLD.staff_id;
      v_moved := v_new_active AND v_old_active AND (
        NEW.date IS DISTINCT FROM OLD.date OR NEW.time IS DISTINCT FROM OLD.time
        OR NEW.duration_minutes IS DISTINCT FROM OLD.duration_minutes);
      v_slot_old := left(trim(OLD.date::text), 10) || 'T' || left(trim(OLD.time::text), 5);
    END IF;

    IF NOT (v_is_new OR v_cancelled OR v_staff_changed OR v_moved) THEN
      RETURN NULL;
    END IF;

    v_slot_new := left(trim(NEW.date::text), 10) || 'T' || left(trim(NEW.time::text), 5);
    v_payload := jsonb_build_object(
      'date', left(trim(NEW.date::text), 10),
      'time', left(trim(NEW.time::text), 5),
      'duration', coalesce(nullif(NEW.duration_minutes, 0), 30),
      'service', coalesce(nullif(trim(NEW.service_name), ''), nullif(trim(NEW.service), ''), ''),
      'staff_name', coalesce((SELECT sm.name FROM public.staff_members sm WHERE sm.id = NEW.staff_id), ''),
      'recurring', NEW.recurring_group_id IS NOT NULL
    );
    IF TG_OP = 'UPDATE' THEN
      v_payload := v_payload || jsonb_build_object(
        'old_date', left(trim(OLD.date::text), 10),
        'old_time', left(trim(OLD.time::text), 5));
    END IF;

    FOR v_staff IN
      SELECT sm.* FROM public.staff_members sm
      WHERE sm.business_id = NEW.business_id
        AND sm.access_enabled = true
        AND sm.access_user_id IS NOT NULL
        AND coalesce(sm.active, true) = true
    LOOP
      v_type := NULL;
      IF v_is_new THEN
        IF public._staff_can_see_booking(v_staff, NEW.staff_id) THEN v_type := 'new'; END IF;
      ELSIF v_cancelled THEN
        IF public._staff_can_see_booking(v_staff, OLD.staff_id) OR public._staff_can_see_booking(v_staff, NEW.staff_id) THEN
          v_type := 'cancelled';
        END IF;
      ELSIF v_staff_changed THEN
        IF v_staff.id = NEW.staff_id THEN v_type := 'assigned';
        ELSIF v_staff.id IS NOT DISTINCT FROM OLD.staff_id THEN v_type := 'unassigned';
        ELSIF v_staff.access_scope = 'all' THEN v_type := 'reassigned';
        END IF;
      ELSIF v_moved THEN
        IF public._staff_can_see_booking(v_staff, NEW.staff_id) THEN v_type := 'rescheduled'; END IF;
      END IF;

      CONTINUE WHEN v_type IS NULL;

      -- Recurring series: one push per recipient, type and transaction.
      IF NEW.recurring_group_id IS NOT NULL THEN
        v_key := 'series:' || NEW.recurring_group_id || ':' || v_type || ':tx' || txid_current();
      ELSE
        v_key := 'booking:' || NEW.id || ':' || v_type || ':' || v_slot_old || '>' || v_slot_new
                 || ':' || coalesce(NEW.staff_id::text, '-');
      END IF;

      INSERT INTO public.staff_push_events (business_id, booking_id, staff_id, event_type, dedupe_key, payload)
      VALUES (NEW.business_id, NEW.id, v_staff.id, v_type, v_key, v_payload)
      ON CONFLICT (staff_id, dedupe_key) DO NOTHING;
    END LOOP;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'staff push enqueue skipped: %', SQLERRM;
  END;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS bookings_enqueue_staff_push ON public.bookings;
CREATE TRIGGER bookings_enqueue_staff_push
  AFTER INSERT OR UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public._enqueue_staff_booking_push();

-- -----------------------------------------------------------------------------
-- 4) Webhook → send-staff-booking-push (same pattern as send-customer-booking-push)
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS "send-staff-booking-push" ON public.staff_push_events;
CREATE TRIGGER "send-staff-booking-push"
  AFTER INSERT ON public.staff_push_events
  FOR EACH ROW EXECUTE FUNCTION supabase_functions.http_request(
    'https://sdqothuulzeczcncyfqd.supabase.co/functions/v1/send-staff-booking-push',
    'POST', '{"Content-type":"application/json"}', '{}', '5000');

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._enqueue_staff_booking_push() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.upsert_staff_push_token(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_staff_push_token(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_staff_push_token(text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_staff_push_token(text) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS "send-staff-booking-push" ON public.staff_push_events;
-- DROP TRIGGER IF EXISTS bookings_enqueue_staff_push ON public.bookings;
-- DROP FUNCTION IF EXISTS public._enqueue_staff_booking_push();
-- DROP TABLE IF EXISTS public.staff_push_events;
-- DROP FUNCTION IF EXISTS public.delete_staff_push_token(text);
-- DROP FUNCTION IF EXISTS public.upsert_staff_push_token(text, text, text);
-- DROP TABLE IF EXISTS public.staff_push_tokens;
-- COMMIT;
