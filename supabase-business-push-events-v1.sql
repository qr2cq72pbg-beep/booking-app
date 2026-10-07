-- =============================================================================
-- XBOOK Phase 3 — Business push outbox + authoritative event emitters
-- NEW migration. Run once in Supabase Dashboard → SQL Editor AFTER review.
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS).
--
-- Does NOT modify:
--   business_push_tokens / customer_push_tokens schema or RPCs
--   create_booking / create_recurring_bookings function bodies
--   membership RPC bodies
--
-- Dispatch is NOT performed by the browser.
-- This repo does not prove pg_net or a live Database Webhook is enabled.
-- After this SQL: create ONE Database Webhook (see file footer).
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Outbox
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_push_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  event_type text NOT NULL
    CHECK (event_type IN ('customer_booking', 'customer_join')),
  source_key text NOT NULL,
  source_id uuid,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  attempt_count integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz,
  CONSTRAINT business_push_events_business_type_source_uniq
    UNIQUE (business_id, event_type, source_key),
  CONSTRAINT business_push_events_sent_requires_timestamp
    CHECK (status <> 'sent' OR sent_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS business_push_events_business_created_idx
  ON public.business_push_events (business_id, created_at DESC);

CREATE INDEX IF NOT EXISTS business_push_events_unsent_idx
  ON public.business_push_events (created_at)
  WHERE sent_at IS NULL;

COMMENT ON TABLE public.business_push_events IS
  'Authoritative Business owner push outbox. Events are inserted only by server triggers after a successful customer booking or genuine membership link. Clients have no DML.';

COMMENT ON COLUMN public.business_push_events.source_key IS
  'Server dedupe key. Booking: customer_booking:{booking_id}. Recurring series: customer_booking:recurring:{recurring_group_id}. Join: customer_join:{crm_id}:{customer_user_id}:{xact} so leave→rejoin can emit again.';

COMMENT ON COLUMN public.business_push_events.payload IS
  'Safe copy fields only (customer_name, service_name, date, time). Never phone, email, notes, or manage_token.';

COMMENT ON COLUMN public.business_push_events.sent_at IS
  'Set only after a successful delivery attempt policy (at least one provider success, or zero registered tokens). Provider failures stay unsent.';

ALTER TABLE public.business_push_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_push_events_no_client ON public.business_push_events;

REVOKE ALL ON TABLE public.business_push_events FROM PUBLIC;
REVOKE ALL ON TABLE public.business_push_events FROM anon;
REVOKE ALL ON TABLE public.business_push_events FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.business_push_events TO service_role;

-- ---------------------------------------------------------------------------
-- 2) Internal enqueue (SECURITY DEFINER, not a client RPC)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._enqueue_business_push_event(
  p_business_id uuid,
  p_event_type text,
  p_source_key text,
  p_source_id uuid,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_type text := lower(trim(coalesce(p_event_type, '')));
  v_key text := trim(coalesce(p_source_key, ''));
BEGIN
  IF p_business_id IS NULL OR v_key = '' THEN
    RETURN NULL;
  END IF;

  IF v_type NOT IN ('customer_booking', 'customer_join') THEN
    RETURN NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = p_business_id
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.business_push_events (
    business_id,
    event_type,
    source_key,
    source_id,
    payload
  )
  VALUES (
    p_business_id,
    v_type,
    v_key,
    p_source_id,
    coalesce(p_payload, '{}'::jsonb)
  )
  ON CONFLICT (business_id, event_type, source_key)
  DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public._enqueue_business_push_event(uuid, text, text, uuid, jsonb) IS
  'Internal outbox insert. Idempotent on (business_id, event_type, source_key). Not a PostgREST RPC.';

REVOKE ALL ON FUNCTION public._enqueue_business_push_event(uuid, text, text, uuid, jsonb)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public._enqueue_business_push_event(uuid, text, text, uuid, jsonb)
  FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._enqueue_business_push_event(uuid, text, text, uuid, jsonb)
  TO service_role;

-- ---------------------------------------------------------------------------
-- 3) Customer booking / recurring series — AFTER INSERT on bookings
--    Does not replace create_booking / create_recurring_bookings.
--    Owner manual booking: auth.uid() = business_id → skip.
--    Customer booking: caller is the booked customer_user_id.
-- ---------------------------------------------------------------------------

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
      'time', v_time
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._trg_enqueue_customer_booking_push() IS
  'After a successful customer booking INSERT: one outbox event. Recurring rows share recurring_group_id so only the first occurrence creates an event.';

REVOKE ALL ON FUNCTION public._trg_enqueue_customer_booking_push() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._trg_enqueue_customer_booking_push() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_enqueue_customer_booking_push ON public.bookings;
CREATE TRIGGER trg_enqueue_customer_booking_push
  AFTER INSERT ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public._trg_enqueue_customer_booking_push();

-- ---------------------------------------------------------------------------
-- 4) Genuine customer join / relink — membership state transition only
--    INSERT with customer_user_id, or NULL → auth.uid() UPDATE.
--    Repeated register_customer_business_membership with no change does
--    not write customer_user_id and does not emit.
--    leave_customer_business NULLs customer_user_id; a later relink is new.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._trg_enqueue_customer_join_push()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller uuid := auth.uid();
  v_was_null boolean;
  v_source_key text;
BEGIN
  IF v_caller IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.customer_user_id IS NULL
     OR NEW.customer_user_id IS DISTINCT FROM v_caller THEN
    RETURN NEW;
  END IF;

  IF v_caller = NEW.business_id THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' THEN
    v_was_null := OLD.customer_user_id IS NULL;
    IF NOT v_was_null THEN
      RETURN NEW;
    END IF;
  END IF;

  v_source_key :=
    'customer_join:'
    || NEW.id::text
    || ':'
    || NEW.customer_user_id::text
    || ':'
    || pg_current_xact_id()::text;

  PERFORM public._enqueue_business_push_event(
    NEW.business_id,
    'customer_join',
    v_source_key,
    NEW.id,
    jsonb_build_object(
      'customer_name', coalesce(nullif(trim(NEW.display_name), ''), '')
    )
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._trg_enqueue_customer_join_push() IS
  'Emits customer_join only when the calling customer becomes linked (INSERT or NULL→uid). Same-xact retries share pg_current_xact_id(); a later rejoin is a new xact and a new event.';

REVOKE ALL ON FUNCTION public._trg_enqueue_customer_join_push() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._trg_enqueue_customer_join_push() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_enqueue_customer_join_push ON public.business_customers;
CREATE TRIGGER trg_enqueue_customer_join_push
  AFTER INSERT OR UPDATE OF customer_user_id ON public.business_customers
  FOR EACH ROW
  WHEN (NEW.customer_user_id IS NOT NULL)
  EXECUTE FUNCTION public._trg_enqueue_customer_join_push();

COMMIT;

-- =============================================================================
-- ONE-TIME Dashboard step (not in this SQL — repo cannot prove live config):
--
-- Database → Webhooks → Create a new hook
--   Name: send-business-event-notification
--   Table: public.business_push_events
--   Events: INSERT
--   URL: https://sdqothuulzeczcncyfqd.supabase.co/functions/v1/send-business-event-notification
--   HTTP headers:
--     Content-Type: application/json
--     Authorization: Bearer <service_role key>
--       OR Bearer / x-business-push-secret: <BUSINESS_PUSH_DISPATCH_SECRET>
--
-- Do not enable this webhook until the Edge Function is deployed.
-- =============================================================================
