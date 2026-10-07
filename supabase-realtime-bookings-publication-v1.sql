-- =============================================================================
-- XBOOK — Realtime publication repair for Business live inbox
-- NEW additive migration. Run once in Supabase Dashboard → SQL Editor AFTER review.
-- Safe to re-run.
--
-- Production diagnosis:
--   public.bookings IS in supabase_realtime, but the published column list
--   includes manage_token. authenticated has column SELECT on every bookings
--   column EXCEPT manage_token, and has_table_privilege SELECT = false.
--   postgres_changes SUBSCRIBED, then silently drops INSERT payloads.
--   public.business_customers has owner/customer RLS + authenticated SELECT
--   but is NOT in the publication.
--
-- This migration does NOT:
--   GRANT table-level SELECT on public.bookings
--   GRANT SELECT (manage_token)
--   change bookings RLS or bookings_api
--   expose business_push_events
--   change replica identity
-- =============================================================================

BEGIN;

-- Recreate the bookings publication without manage_token.
-- SET TABLE would replace the entire publication; DROP + ADD is required.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'bookings'
  ) THEN
    ALTER PUBLICATION supabase_realtime DROP TABLE public.bookings;
  END IF;
END
$$;

ALTER PUBLICATION supabase_realtime ADD TABLE public.bookings (
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
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'business_customers'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.business_customers;
  END IF;
END
$$;

COMMIT;

-- Optional verify (read-only; run separately after apply):
-- SELECT tablename, attnames
-- FROM pg_publication_tables
-- WHERE pubname = 'supabase_realtime'
--   AND schemaname = 'public'
--   AND tablename IN ('bookings', 'business_customers');
