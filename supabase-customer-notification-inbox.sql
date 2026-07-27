-- XBOOK: Customer notification inbox — single-RPC read path.
-- Run in Supabase Dashboard -> SQL Editor after supabase-customer-push-notifications.sql.
-- Safe to re-run (idempotent).

BEGIN;

DROP FUNCTION IF EXISTS public.list_customer_notification_inbox();
DROP FUNCTION IF EXISTS public.mark_customer_notification_read(uuid);
DROP FUNCTION IF EXISTS public.count_customer_notification_inbox_unread();

CREATE OR REPLACE FUNCTION public.list_customer_notification_inbox()
RETURNS TABLE (
  recipient_id uuid,
  notification_id uuid,
  business_id uuid,
  business_name text,
  business_logo text,
  title text,
  message text,
  created_at timestamptz,
  read_at timestamptz,
  sent_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    nr.id AS recipient_id,
    n.id AS notification_id,
    n.business_id,
    coalesce(nullif(trim(bs.business_name), ''), 'Business') AS business_name,
    CASE
      WHEN coalesce(bs.public_show_logo, true) = true
        THEN nullif(trim(bs.business_logo_url), '')
      ELSE NULL
    END AS business_logo,
    n.title,
    n.message,
    n.created_at,
    nr.read_at,
    nr.sent_at
  FROM public.notification_recipients nr
  INNER JOIN public.notifications n ON n.id = nr.notification_id
  LEFT JOIN public.business_settings bs ON bs.business_id = n.business_id
  WHERE nr.customer_user_id = auth.uid()
  ORDER BY n.created_at DESC;
$$;

COMMENT ON FUNCTION public.list_customer_notification_inbox() IS
  'Single-query customer inbox: business messages for auth.uid().';

CREATE OR REPLACE FUNCTION public.mark_customer_notification_read(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_updated integer;
BEGIN
  IF v_uid IS NULL OR p_notification_id IS NULL THEN
    RETURN false;
  END IF;

  UPDATE public.notification_recipients
  SET read_at = coalesce(read_at, now())
  WHERE notification_id = p_notification_id
    AND customer_user_id = v_uid;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated > 0;
END;
$$;

COMMENT ON FUNCTION public.mark_customer_notification_read(uuid) IS
  'Marks a business notification read for the logged-in customer.';

CREATE OR REPLACE FUNCTION public.count_customer_notification_inbox_unread()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.notification_recipients nr
  WHERE nr.customer_user_id = auth.uid()
    AND nr.read_at IS NULL;
$$;

COMMENT ON FUNCTION public.count_customer_notification_inbox_unread() IS
  'Unread business notification count for nav badge.';

REVOKE ALL ON FUNCTION public.list_customer_notification_inbox() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_customer_notification_read(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.count_customer_notification_inbox_unread() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_customer_notification_inbox() TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_customer_notification_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_customer_notification_inbox_unread() TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.notification_recipients TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notifications TO service_role;

COMMIT;
