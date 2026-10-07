-- =============================================================================
-- XBOOK — Business push inbox (owner read / unread)
-- NEW additive migration. Run once in Supabase Dashboard → SQL Editor AFTER review.
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / DROP IF EXISTS).
--
-- Does NOT modify:
--   business_push_events outbox emitters, triggers, or delivery columns
--   send-business-event-notification
--   business_push_tokens / customer_push_tokens
--   booking or membership RPCs
--
-- Does NOT GRANT authenticated SELECT/UPDATE on business_push_events.
-- Owners reach inbox rows only through narrow SECURITY DEFINER RPCs.
-- =============================================================================

BEGIN;

ALTER TABLE public.business_push_events
  ADD COLUMN IF NOT EXISTS read_at timestamptz;

COMMENT ON COLUMN public.business_push_events.read_at IS
  'Set when the owning Business user opens this inbox row. Null means unread. Delivery status is unchanged.';

CREATE INDEX IF NOT EXISTS business_push_events_owner_unread_idx
  ON public.business_push_events (business_id, created_at DESC)
  WHERE read_at IS NULL;

-- Keep the outbox locked. Inbox access is RPC-only.
REVOKE ALL ON TABLE public.business_push_events FROM PUBLIC;
REVOKE ALL ON TABLE public.business_push_events FROM anon;
REVOKE ALL ON TABLE public.business_push_events FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.business_push_events TO service_role;

CREATE OR REPLACE FUNCTION public._assert_business_inbox_owner()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
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

  RETURN v_uid;
END;
$$;

COMMENT ON FUNCTION public._assert_business_inbox_owner() IS
  'Returns auth.uid() when the caller owns business_settings.business_id. Internal inbox helper.';

REVOKE ALL ON FUNCTION public._assert_business_inbox_owner() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_business_inbox_owner() FROM anon, authenticated;

DROP FUNCTION IF EXISTS public.list_business_push_inbox();
DROP FUNCTION IF EXISTS public.count_business_push_inbox_unread();
DROP FUNCTION IF EXISTS public.mark_business_push_inbox_read(uuid);

CREATE OR REPLACE FUNCTION public.list_business_push_inbox()
RETURNS TABLE (
  event_id uuid,
  event_type text,
  customer_name text,
  service_name text,
  event_date text,
  event_time text,
  created_at timestamptz,
  read_at timestamptz
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
    e.read_at
  FROM public.business_push_events e
  WHERE e.business_id = v_uid
    AND e.event_type IN ('customer_booking', 'customer_join')
  ORDER BY e.created_at DESC
  LIMIT 100;
END;
$$;

COMMENT ON FUNCTION public.list_business_push_inbox() IS
  'Owner inbox for auth.uid() business_push_events. Safe payload fields only. Newest first.';

CREATE OR REPLACE FUNCTION public.count_business_push_inbox_unread()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_count integer;
BEGIN
  v_uid := public._assert_business_inbox_owner();

  SELECT count(*)::integer
  INTO v_count
  FROM public.business_push_events e
  WHERE e.business_id = v_uid
    AND e.event_type IN ('customer_booking', 'customer_join')
    AND e.read_at IS NULL;

  RETURN coalesce(v_count, 0);
END;
$$;

COMMENT ON FUNCTION public.count_business_push_inbox_unread() IS
  'Unread inbox count for the authenticated Business owner. 0 if none.';

CREATE OR REPLACE FUNCTION public.mark_business_push_inbox_read(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_updated integer;
BEGIN
  v_uid := public._assert_business_inbox_owner();

  IF p_event_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.business_push_events
  SET read_at = coalesce(read_at, now())
  WHERE id = p_event_id
    AND business_id = v_uid;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.mark_business_push_inbox_read(uuid) IS
  'Marks one inbox event read for the owning Business user. Idempotent. Other businesses are ignored.';

REVOKE ALL ON FUNCTION public.list_business_push_inbox() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.count_business_push_inbox_unread() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_business_push_inbox_read(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_business_push_inbox() TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_business_push_inbox_unread() TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_business_push_inbox_read(uuid) TO authenticated;

COMMIT;
