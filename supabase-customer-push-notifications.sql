-- XBOOK: Business to Customer push notifications (one-way).
-- Run in Supabase Dashboard -> SQL Editor.
-- Depends on: public.business_settings, public.business_customers.
-- Safe to re-run (idempotent).

BEGIN;

ALTER TABLE public.business_customers
  ADD COLUMN IF NOT EXISTS is_vip boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.business_customers.is_vip IS
  'When true, customer is included in VIP push notification recipient filter.';

CREATE INDEX IF NOT EXISTS business_customers_business_vip_idx
  ON public.business_customers (business_id, is_vip)
  WHERE is_vip = true AND customer_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.customer_push_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  device_token text NOT NULL,
  platform text NOT NULL CHECK (platform IN ('ios', 'android')),
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_push_tokens_user_token_uniq UNIQUE (customer_user_id, device_token)
);

CREATE INDEX IF NOT EXISTS customer_push_tokens_customer_user_id_idx
  ON public.customer_push_tokens (customer_user_id);

COMMENT ON TABLE public.customer_push_tokens IS
  'FCM/APNs device tokens for logged-in customers. Updated on each native app login.';

ALTER TABLE public.customer_push_tokens ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_push_tokens_self_select ON public.customer_push_tokens;
CREATE POLICY customer_push_tokens_self_select
  ON public.customer_push_tokens
  FOR SELECT
  TO authenticated
  USING (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_push_tokens_self_insert ON public.customer_push_tokens;
CREATE POLICY customer_push_tokens_self_insert
  ON public.customer_push_tokens
  FOR INSERT
  TO authenticated
  WITH CHECK (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_push_tokens_self_update ON public.customer_push_tokens;
CREATE POLICY customer_push_tokens_self_update
  ON public.customer_push_tokens
  FOR UPDATE
  TO authenticated
  USING (customer_user_id = auth.uid())
  WITH CHECK (customer_user_id = auth.uid());

DROP POLICY IF EXISTS customer_push_tokens_self_delete ON public.customer_push_tokens;
CREATE POLICY customer_push_tokens_self_delete
  ON public.customer_push_tokens
  FOR DELETE
  TO authenticated
  USING (customer_user_id = auth.uid());

REVOKE ALL ON public.customer_push_tokens FROM PUBLIC;
REVOKE ALL ON public.customer_push_tokens FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_push_tokens TO authenticated;

CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  title text NOT NULL,
  message text NOT NULL,
  recipient_type text NOT NULL
    CHECK (recipient_type IN ('all', 'vip', 'selected')),
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS notifications_business_id_created_at_idx
  ON public.notifications (business_id, created_at DESC);

COMMENT ON TABLE public.notifications IS
  'One-way business notifications to customers. In-app notification center reads from here.';

ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notifications_owner_select ON public.notifications;
CREATE POLICY notifications_owner_select
  ON public.notifications
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS notifications_owner_insert ON public.notifications;
CREATE POLICY notifications_owner_insert
  ON public.notifications
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

REVOKE ALL ON public.notifications FROM PUBLIC;
REVOKE ALL ON public.notifications FROM anon;
GRANT SELECT, INSERT ON public.notifications TO authenticated;

CREATE TABLE IF NOT EXISTS public.notification_recipients (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id uuid NOT NULL
    REFERENCES public.notifications (id) ON DELETE CASCADE,
  customer_user_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  sent_at timestamptz,
  read_at timestamptz,
  CONSTRAINT notification_recipients_notification_customer_uniq
    UNIQUE (notification_id, customer_user_id)
);

CREATE INDEX IF NOT EXISTS notification_recipients_notification_id_idx
  ON public.notification_recipients (notification_id);

CREATE INDEX IF NOT EXISTS notification_recipients_customer_user_id_idx
  ON public.notification_recipients (customer_user_id, sent_at DESC);

COMMENT ON TABLE public.notification_recipients IS
  'Per-customer notification delivery and read state for in-app notification center.';

ALTER TABLE public.notification_recipients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS notification_recipients_owner_select ON public.notification_recipients;
CREATE POLICY notification_recipients_owner_select
  ON public.notification_recipients
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.notifications n
      WHERE n.id = notification_recipients.notification_id
        AND n.business_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS notification_recipients_customer_select ON public.notification_recipients;
CREATE POLICY notification_recipients_customer_select
  ON public.notification_recipients
  FOR SELECT
  TO authenticated
  USING (customer_user_id = auth.uid());

DROP POLICY IF EXISTS notification_recipients_customer_update_read ON public.notification_recipients;
CREATE POLICY notification_recipients_customer_update_read
  ON public.notification_recipients
  FOR UPDATE
  TO authenticated
  USING (customer_user_id = auth.uid())
  WITH CHECK (customer_user_id = auth.uid());

REVOKE ALL ON public.notification_recipients FROM PUBLIC;
REVOKE ALL ON public.notification_recipients FROM anon;
GRANT SELECT, UPDATE ON public.notification_recipients TO authenticated;

DROP POLICY IF EXISTS notifications_customer_select ON public.notifications;
CREATE POLICY notifications_customer_select
  ON public.notifications
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.notification_recipients nr
      WHERE nr.notification_id = notifications.id
        AND nr.customer_user_id = auth.uid()
    )
  );

CREATE OR REPLACE FUNCTION public.upsert_customer_push_token(
  p_device_token text,
  p_platform text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_token text := trim(coalesce(p_device_token, ''));
  v_platform text := lower(trim(coalesce(p_platform, '')));
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF v_token = '' THEN
    RAISE EXCEPTION 'device_token is required';
  END IF;
  IF v_platform NOT IN ('ios', 'android') THEN
    RAISE EXCEPTION 'platform must be ios or android';
  END IF;

  INSERT INTO public.customer_push_tokens (
    customer_user_id,
    device_token,
    platform,
    last_seen_at
  )
  VALUES (v_uid, v_token, v_platform, now())
  ON CONFLICT (customer_user_id, device_token)
  DO UPDATE SET
    platform = EXCLUDED.platform,
    last_seen_at = now();
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_customer_push_token(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_customer_push_token(text, text) TO authenticated;

COMMIT;
