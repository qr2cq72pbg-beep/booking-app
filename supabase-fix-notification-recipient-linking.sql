-- XBOOK: Fix notification recipient linking for in-app customer inbox.
-- Run in Supabase Dashboard -> SQL Editor AFTER:
--   supabase-customer-push-notifications.sql
--   supabase-business-customers.sql
--   supabase-client-approval.sql (for _lookup_business_customer_row / _booking_client_key)
--
-- Safe to re-run (idempotent).
-- Does NOT modify guest bookings (only reads bookings.customer_user_id IS NOT NULL).
-- Does NOT overwrite existing business_customers.customer_user_id values.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1) Link CRM rows: backfill business_customers.customer_user_id from bookings
--    Only where CRM row exists and customer_user_id is still NULL.
-- ---------------------------------------------------------------------------
UPDATE public.business_customers bc
SET
  customer_user_id = sub.customer_user_id,
  updated_at = now()
FROM (
  SELECT DISTINCT ON (
    b.business_id,
    public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name)
  )
    b.business_id,
    public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name) AS client_key,
    b.customer_user_id
  FROM public.bookings b
  WHERE b.customer_user_id IS NOT NULL
    AND public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name) IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM auth.users u
      WHERE u.id = b.customer_user_id
    )
  ORDER BY
    b.business_id,
    public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name),
    b.created_at DESC NULLS LAST
) sub
WHERE bc.business_id = sub.business_id
  AND bc.client_key = sub.client_key
  AND bc.customer_user_id IS NULL;

-- ---------------------------------------------------------------------------
-- 2) Future logins: link auth user on existing CRM membership rows when missing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ensure_business_customer_membership(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_approval_status    text DEFAULT NULL
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_existing public.business_customers%ROWTYPE;
  v_row      public.business_customers%ROWTYPE;
  v_status   text;
  v_require  boolean;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_existing := public._lookup_business_customer_row(
    p_business_id,
    p_customer_user_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name
  );

  IF v_existing.id IS NOT NULL THEN
    IF p_customer_user_id IS NOT NULL AND v_existing.customer_user_id IS NULL THEN
      UPDATE public.business_customers
      SET
        customer_user_id = p_customer_user_id,
        updated_at = now()
      WHERE id = v_existing.id
      RETURNING * INTO v_existing;
    END IF;
    RETURN v_existing;
  END IF;

  SELECT coalesce(bs.require_client_approval, false)
  INTO v_require
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  v_status := lower(trim(coalesce(p_approval_status, '')));
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    v_status := CASE WHEN coalesce(v_require, false) THEN 'pending' ELSE 'approved' END;
  END IF;

  v_row := public.ensure_business_customer(
    p_business_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name
  );

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.business_customers
  SET
    customer_user_id = coalesce(p_customer_user_id, customer_user_id),
    approval_status = v_status,
    updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ---------------------------------------------------------------------------
-- 3) Backfill notification_recipients for existing notifications.
--    Resolves recipients per notification.recipient_type:
--      all      -> CRM linked customers + logged-in booking customers
--      vip      -> CRM linked customers with is_vip = true
--      selected -> cannot be reconstructed (no stored selection list); skipped
--    Only includes customer_user_id that exists in auth.users.
-- ---------------------------------------------------------------------------
INSERT INTO public.notification_recipients (
  notification_id,
  customer_user_id
)
SELECT DISTINCT
  n.id,
  eligible.customer_user_id
FROM public.notifications n
INNER JOIN LATERAL (
  -- CRM: linked customers for this business
  SELECT bc.customer_user_id
  FROM public.business_customers bc
  WHERE bc.business_id = n.business_id
    AND bc.customer_user_id IS NOT NULL
    AND (
      n.recipient_type = 'all'
      OR (n.recipient_type = 'vip' AND bc.is_vip = true)
    )

  UNION

  -- Bookings: logged-in customers (only for "all")
  SELECT b.customer_user_id
  FROM public.bookings b
  WHERE b.business_id = n.business_id
    AND b.customer_user_id IS NOT NULL
    AND n.recipient_type = 'all'
) AS eligible(customer_user_id) ON true
WHERE eligible.customer_user_id IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM auth.users u
    WHERE u.id = eligible.customer_user_id
  )
ON CONFLICT ON CONSTRAINT notification_recipients_notification_customer_uniq
DO NOTHING;

COMMIT;

-- ---------------------------------------------------------------------------
-- Verification (read-only)
-- ---------------------------------------------------------------------------

-- A) Recent notifications
SELECT
  n.id,
  n.business_id,
  n.title,
  n.recipient_type,
  n.created_at,
  (
    SELECT count(*)
    FROM public.notification_recipients nr
    WHERE nr.notification_id = n.id
  ) AS recipient_count
FROM public.notifications n
ORDER BY n.created_at DESC
LIMIT 20;

-- B) Recent notification_recipients rows
SELECT
  nr.id,
  nr.notification_id,
  nr.customer_user_id,
  nr.sent_at,
  nr.read_at,
  n.title,
  n.recipient_type,
  n.created_at AS notification_created_at
FROM public.notification_recipients nr
INNER JOIN public.notifications n ON n.id = nr.notification_id
ORDER BY n.created_at DESC, nr.customer_user_id
LIMIT 50;

-- C) Linked business_customers (CRM rows with auth user)
SELECT
  bc.business_id,
  bc.id AS business_customer_id,
  bc.display_name,
  bc.email,
  bc.customer_user_id,
  bc.is_vip,
  bc.approval_status,
  bc.updated_at
FROM public.business_customers bc
WHERE bc.customer_user_id IS NOT NULL
ORDER BY bc.updated_at DESC NULLS LAST
LIMIT 50;

-- D) Logged-in booking customers per business
SELECT
  b.business_id,
  b.customer_user_id,
  max(b.customer_email) AS customer_email,
  max(b.customer_name) AS customer_name,
  count(*) AS booking_count,
  max(b.created_at) AS latest_booking_at
FROM public.bookings b
WHERE b.customer_user_id IS NOT NULL
GROUP BY b.business_id, b.customer_user_id
ORDER BY latest_booking_at DESC NULLS LAST
LIMIT 50;

-- E) Notifications still missing recipients (should trend toward zero after backfill)
SELECT
  n.id,
  n.business_id,
  n.title,
  n.recipient_type,
  n.created_at
FROM public.notifications n
WHERE NOT EXISTS (
  SELECT 1
  FROM public.notification_recipients nr
  WHERE nr.notification_id = n.id
)
ORDER BY n.created_at DESC
LIMIT 20;
