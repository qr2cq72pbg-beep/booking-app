-- XBOOK: Admin notification history RPCs (business owner only).
-- Run in Supabase Dashboard -> SQL Editor after supabase-customer-push-notifications.sql.
-- Safe to re-run (idempotent).

BEGIN;

DROP FUNCTION IF EXISTS public.list_business_notification_history();
DROP FUNCTION IF EXISTS public.get_business_notification_detail(uuid);
DROP FUNCTION IF EXISTS public.delete_business_notification(uuid);
DROP FUNCTION IF EXISTS public.clear_business_notification_history();

CREATE OR REPLACE FUNCTION public.list_business_notification_history()
RETURNS TABLE (
  notification_id uuid,
  title text,
  message text,
  created_at timestamptz,
  recipient_type text,
  total_recipients bigint,
  read_count bigint,
  unread_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    n.id AS notification_id,
    n.title,
    n.message,
    n.created_at,
    n.recipient_type,
    count(nr.id) AS total_recipients,
    count(nr.id) FILTER (WHERE nr.read_at IS NOT NULL) AS read_count,
    count(nr.id) FILTER (WHERE nr.read_at IS NULL) AS unread_count
  FROM public.notifications n
  LEFT JOIN public.notification_recipients nr ON nr.notification_id = n.id
  WHERE n.business_id = auth.uid()
  GROUP BY n.id, n.title, n.message, n.created_at, n.recipient_type
  ORDER BY n.created_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.get_business_notification_detail(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid := auth.uid();
  v_result jsonb;
BEGIN
  IF v_business_id IS NULL OR p_notification_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT jsonb_build_object(
    'notification_id', n.id,
    'title', n.title,
    'message', n.message,
    'created_at', n.created_at,
    'recipient_type', n.recipient_type,
    'total_recipients', stats.total_recipients,
    'read_count', stats.read_count,
    'unread_count', stats.unread_count,
    'recipients', coalesce(recipients.payload, '[]'::jsonb)
  )
  INTO v_result
  FROM public.notifications n
  CROSS JOIN LATERAL (
    SELECT
      count(*) AS total_recipients,
      count(*) FILTER (WHERE nr.read_at IS NOT NULL) AS read_count,
      count(*) FILTER (WHERE nr.read_at IS NULL) AS unread_count
    FROM public.notification_recipients nr
    WHERE nr.notification_id = n.id
  ) stats
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(
      jsonb_build_object(
        'recipient_id', nr.id,
        'customer_user_id', nr.customer_user_id,
        'display_name', coalesce(
          nullif(trim(bc.display_name), ''),
          nullif(trim(up.full_name), ''),
          'Customer'
        ),
        'email', coalesce(
          nullif(trim(u.email), ''),
          nullif(trim(bc.email), ''),
          nullif(trim(up.email), '')
        ),
        'read_at', nr.read_at,
        'is_read', (nr.read_at IS NOT NULL)
      )
      ORDER BY coalesce(nullif(trim(bc.display_name), ''), nullif(trim(up.full_name), ''), u.email)
    ) AS payload
    FROM public.notification_recipients nr
    LEFT JOIN public.business_customers bc
      ON bc.business_id = n.business_id
     AND bc.customer_user_id = nr.customer_user_id
    LEFT JOIN public.user_profiles up ON up.id = nr.customer_user_id
    LEFT JOIN auth.users u ON u.id = nr.customer_user_id
    WHERE nr.notification_id = n.id
  ) recipients ON true
  WHERE n.id = p_notification_id
    AND n.business_id = v_business_id;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.delete_business_notification(p_notification_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid := auth.uid();
  v_deleted integer;
BEGIN
  IF v_business_id IS NULL OR p_notification_id IS NULL THEN
    RETURN false;
  END IF;

  DELETE FROM public.notifications
  WHERE id = p_notification_id
    AND business_id = v_business_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_business_notification_history()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid := auth.uid();
  v_deleted integer;
BEGIN
  IF v_business_id IS NULL THEN
    RETURN 0;
  END IF;

  DELETE FROM public.notifications
  WHERE business_id = v_business_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.list_business_notification_history() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_notification_detail(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_business_notification(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_business_notification_history() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_business_notification_history() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_notification_detail(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_business_notification(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_business_notification_history() TO authenticated;

COMMIT;
