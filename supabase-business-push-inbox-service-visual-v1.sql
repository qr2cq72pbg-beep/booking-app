-- =============================================================================
-- XBOOK — Business inbox: add service_visual_key to booking events
-- NEW additive migration. Run once in Supabase Dashboard → SQL Editor AFTER review.
-- Safe to re-run (CREATE OR REPLACE / DROP IF EXISTS).
--
-- Does NOT:
--   GRANT authenticated SELECT/UPDATE on business_push_events
--   change unread / mark-read RPCs
--   change join payload
--   change APNs/FCM dispatch
-- =============================================================================

BEGIN;

-- Keep the outbox locked.
REVOKE ALL ON TABLE public.business_push_events FROM PUBLIC;
REVOKE ALL ON TABLE public.business_push_events FROM anon;
REVOKE ALL ON TABLE public.business_push_events FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.business_push_events TO service_role;

CREATE OR REPLACE FUNCTION public._trg_enqueue_customer_booking_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_source_key text;
  v_date text;
  v_time text;
  v_visual text;
BEGIN
  IF v_caller IS NULL THEN
    RETURN NEW;
  END IF;

  IF v_caller = NEW.business_id THEN
    RETURN NEW;
  END IF;

  IF NEW.customer_user_id IS NULL
     OR NEW.customer_user_id IS DISTINCT FROM v_caller THEN
    RETURN NEW;
  END IF;

  IF NEW.recurring_group_id IS NOT NULL THEN
    v_source_key := 'customer_booking:recurring:' || NEW.recurring_group_id::text;
  ELSE
    v_source_key := 'customer_booking:' || NEW.id::text;
  END IF;

  v_date := left(trim(coalesce(NEW.date::text, '')), 10);
  v_time := left(trim(coalesce(NEW.time::text, '')), 5);

  SELECT left(trim(coalesce(s.service_visual_key, '')), 64)
    INTO v_visual
    FROM public.services s
   WHERE s.id = NEW.service_id
     AND s.business_id = NEW.business_id
   LIMIT 1;

  PERFORM public._enqueue_business_push_event(
    NEW.business_id,
    'customer_booking',
    v_source_key,
    CASE
      WHEN NEW.recurring_group_id IS NOT NULL THEN NEW.recurring_group_id
      ELSE NEW.id
    END,
    jsonb_build_object(
      'customer_name', coalesce(nullif(trim(NEW.customer_name), ''), ''),
      'service_name', coalesce(nullif(trim(NEW.service_name), ''), ''),
      'date', v_date,
      'time', v_time,
      'service_visual_key', coalesce(nullif(trim(v_visual), ''), '')
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._trg_enqueue_customer_booking_push() IS
  'After a successful customer booking INSERT: one outbox event. Recurring rows share recurring_group_id so only the first occurrence creates an event. Safe payload includes service_visual_key when the booked service has one.';

DROP FUNCTION IF EXISTS public.list_business_push_inbox();

CREATE OR REPLACE FUNCTION public.list_business_push_inbox()
RETURNS TABLE (
  event_id uuid,
  event_type text,
  customer_name text,
  service_name text,
  event_date text,
  event_time text,
  created_at timestamptz,
  read_at timestamptz,
  service_visual_key text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
BEGIN
  v_uid := public._assert_business_inbox_owner();

  RETURN QUERY
  SELECT
    e.id,
    e.event_type,
    left(coalesce(nullif(trim(e.payload ->> 'customer_name'), ''), ''), 120),
    left(coalesce(nullif(trim(e.payload ->> 'service_name'), ''), ''), 120),
    left(coalesce(nullif(trim(e.payload ->> 'date'), ''), ''), 10),
    left(coalesce(nullif(trim(e.payload ->> 'time'), ''), ''), 5),
    e.created_at,
    e.read_at,
    left(coalesce(nullif(trim(e.payload ->> 'service_visual_key'), ''), ''), 64)
  FROM public.business_push_events e
  WHERE e.business_id = v_uid
    AND e.event_type IN ('customer_booking', 'customer_join')
  ORDER BY e.created_at DESC
  LIMIT 100;
END;
$$;

COMMENT ON FUNCTION public.list_business_push_inbox() IS
  'Owner inbox for auth.uid() business_push_events. Safe payload fields only, including service_visual_key when present. Newest first.';

REVOKE ALL ON FUNCTION public.list_business_push_inbox() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_business_push_inbox() TO authenticated;

COMMIT;
