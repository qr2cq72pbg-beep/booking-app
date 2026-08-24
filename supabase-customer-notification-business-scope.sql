-- XBOOK: Scope customer notification inbox + unread badge to the active business.
-- Run in Supabase Dashboard -> SQL Editor AFTER:
--   supabase-customer-push-notifications.sql
--   supabase-customer-notification-inbox.sql
-- Safe to re-run (idempotent).
--
-- CRITICAL:
-- Drops the old zero-argument RPCs that returned ALL businesses for a customer.
-- After this migration there must be no callable:
--   list_customer_notification_inbox()
--   count_customer_notification_inbox_unread()
--
-- Do NOT re-run an older copy of supabase-customer-notification-inbox.sql
-- that still defines the zero-argument overloads.

BEGIN;

DROP FUNCTION IF EXISTS public.list_customer_notification_inbox();
DROP FUNCTION IF EXISTS public.list_customer_notification_inbox(uuid);
DROP FUNCTION IF EXISTS public.count_customer_notification_inbox_unread();
DROP FUNCTION IF EXISTS public.count_customer_notification_inbox_unread(uuid);

CREATE OR REPLACE FUNCTION public.list_customer_notification_inbox(p_business_id uuid)
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
  WHERE p_business_id IS NOT NULL
    AND nr.customer_user_id = auth.uid()
    AND n.business_id = p_business_id
  ORDER BY n.created_at DESC;
$$;

COMMENT ON FUNCTION public.list_customer_notification_inbox(uuid) IS
  'Customer inbox for auth.uid() scoped to p_business_id. Empty if caller or business is missing.';

CREATE OR REPLACE FUNCTION public.count_customer_notification_inbox_unread(p_business_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT count(*)::integer
  FROM public.notification_recipients nr
  INNER JOIN public.notifications n ON n.id = nr.notification_id
  WHERE p_business_id IS NOT NULL
    AND nr.customer_user_id = auth.uid()
    AND n.business_id = p_business_id
    AND nr.read_at IS NULL;
$$;

COMMENT ON FUNCTION public.count_customer_notification_inbox_unread(uuid) IS
  'Unread inbox count for auth.uid() scoped to p_business_id. 0 if caller or business is missing.';

REVOKE ALL ON FUNCTION public.list_customer_notification_inbox(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.count_customer_notification_inbox_unread(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_customer_notification_inbox(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.count_customer_notification_inbox_unread(uuid) TO authenticated;

COMMIT;
