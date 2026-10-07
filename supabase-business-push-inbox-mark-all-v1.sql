-- =============================================================================
-- XBOOK — Business inbox: mark all unread as read
-- NEW additive migration. Run once in Supabase Dashboard → SQL Editor AFTER review.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Does NOT GRANT authenticated SELECT/UPDATE on business_push_events.
-- Owners reach rows only through this SECURITY DEFINER RPC.
-- =============================================================================

BEGIN;

REVOKE ALL ON TABLE public.business_push_events FROM PUBLIC;
REVOKE ALL ON TABLE public.business_push_events FROM anon;
REVOKE ALL ON TABLE public.business_push_events FROM authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.business_push_events TO service_role;

CREATE OR REPLACE FUNCTION public.mark_business_push_inbox_read_all()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_updated integer;
BEGIN
  v_uid := public._assert_business_inbox_owner();

  UPDATE public.business_push_events
  SET read_at = coalesce(read_at, now())
  WHERE business_id = v_uid
    AND event_type IN ('customer_booking', 'customer_join')
    AND read_at IS NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN coalesce(v_updated, 0);
END;
$$;

COMMENT ON FUNCTION public.mark_business_push_inbox_read_all() IS
  'Marks every unread inbox event read for the owning Business user. Other businesses are ignored.';

REVOKE ALL ON FUNCTION public.mark_business_push_inbox_read_all() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_business_push_inbox_read_all() TO authenticated;

COMMIT;
