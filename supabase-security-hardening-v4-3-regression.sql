-- =============================================================================
-- XBOOK SECURITY HARDENING — V4-3 REGRESSION FIX
-- Linked project: sdqothuulzeczcncyfqd
--
-- Root cause:
--   V4-3 revoked table-level SELECT on public.bookings and granted column
--   SELECT on every column except manage_token. PostgreSQL allows those
--   explicit column SELECTs, but SELECT * / table.* is denied with:
--     permission denied for table bookings
--   PostgREST wraps table reads/writes as table.*, so loadBookingsFull()
--   (and other .from("bookings") calls) fail even with an explicit column list.
--
-- Fix:
--   security_invoker view without manage_token. GRANT SELECT/UPDATE/DELETE
--   on the VIEW (safe: the view has no token column). Base table privileges
--   and RLS are unchanged. manage_token stays inaccessible on bookings.
--
-- Does NOT: GRANT SELECT ON bookings TO authenticated,
--           expose manage_token, change RLS, change V1-V4-2, Paddle,
--           or booking create/cancel/reschedule rules.
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.__tmp_v43_priv_probe();

CREATE OR REPLACE VIEW public.bookings_api
WITH (security_invoker = true) AS
SELECT
  id,
  user_id,
  service,
  date,
  time,
  created_at,
  name,
  phone,
  business_id,
  staff_id,
  booking_status,
  customer_user_id,
  customer_email,
  customer_name,
  customer_phone,
  duration_minutes,
  notes,
  status,
  service_id,
  service_name,
  staff_name,
  booking_ref,
  recurring_group_id,
  recurring_index,
  recurring_total,
  recurring_rule,
  booking_price
FROM public.bookings;

COMMENT ON VIEW public.bookings_api IS
  'PostgREST-safe bookings surface without manage_token. security_invoker so base-table RLS applies as the caller. Token access remains get_customer_booking_manage_token / get_business_booking_manage_token.';

REVOKE ALL ON TABLE public.bookings_api FROM PUBLIC;
REVOKE ALL ON TABLE public.bookings_api FROM anon;
GRANT SELECT, UPDATE, DELETE ON TABLE public.bookings_api TO authenticated;
GRANT SELECT, UPDATE, DELETE ON TABLE public.bookings_api TO service_role;
-- Default privileges in this project GRANT ALL on new views; bookings are created via RPC.
REVOKE INSERT, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.bookings_api FROM authenticated;
REVOKE INSERT, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.bookings_api FROM anon;

COMMIT;

NOTIFY pgrst, 'reload schema';
