-- =============================================================================
-- XBOOK — LIVE TENANT ISOLATION AUDIT (READ-ONLY)
-- =============================================================================
-- Purpose: inspect production/live Supabase RLS + RPC metadata.
-- Repo SQL does not prove live policies. Run this in the Supabase SQL Editor
-- when you are ready. This file must NEVER be applied as a migration.
--
-- READ-ONLY:
--   SELECT statements only.
--   No DROP / CREATE / ALTER / UPDATE / DELETE / INSERT / GRANT / REVOKE.
--
-- DO NOT RUN FROM THE APP.
-- DO NOT EXECUTE AS PART OF PHASE 2 IMPLEMENTATION.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. RLS enabled status for core tenant tables
-- -----------------------------------------------------------------------------
SELECT
  'A_rls_enabled' AS audit_section,
  n.nspname AS schema_name,
  c.relname AS table_name,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relkind = 'r'
  AND c.relname IN (
    'business_settings',
    'services',
    'staff_members',
    'bookings',
    'blocked_days',
    'business_customers',
    'business_closed_days',
    'business_gallery_images',
    'notifications',
    'notification_recipients'
  )
ORDER BY c.relname;

-- -----------------------------------------------------------------------------
-- B. All policies for those tables
-- -----------------------------------------------------------------------------
SELECT
  'B_policies' AS audit_section,
  schemaname,
  tablename,
  policyname,
  cmd,
  roles,
  qual,
  with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN (
    'business_settings',
    'services',
    'staff_members',
    'bookings',
    'blocked_days',
    'business_customers',
    'business_closed_days',
    'business_gallery_images',
    'notifications',
    'notification_recipients'
  )
ORDER BY tablename, policyname, cmd;

-- -----------------------------------------------------------------------------
-- C. Function signatures + SECURITY DEFINER status
-- -----------------------------------------------------------------------------
SELECT
  'C_functions' AS audit_section,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS arguments,
  p.prosecdef AS security_definer,
  CASE p.provolatile
    WHEN 'i' THEN 'IMMUTABLE'
    WHEN 's' THEN 'STABLE'
    WHEN 'v' THEN 'VOLATILE'
  END AS volatility,
  p.prorettype::regtype AS return_type,
  p.prosecdef AS is_security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'get_public_business_settings',
    'create_booking',
    'create_recurring_bookings',
    'get_business_busy_slots',
    'get_customer_my_bookings',
    'list_customer_notification_inbox',
    'count_customer_notification_inbox_unread',
    'check_client_booking_approval'
  )
ORDER BY p.proname, pg_get_function_identity_arguments(p.oid);

-- -----------------------------------------------------------------------------
-- D. Confirm whether old zero-arg notification inbox/count overloads still exist
--    Expected after supabase-customer-notification-business-scope.sql:
--      list_customer_notification_inbox(uuid)  -- present
--      count_customer_notification_inbox_unread(uuid) -- present
--      list_customer_notification_inbox()      -- MUST NOT exist
--      count_customer_notification_inbox_unread() -- MUST NOT exist
-- -----------------------------------------------------------------------------
SELECT
  'D_notification_inbox_overloads' AS audit_section,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS arguments,
  (pg_get_function_identity_arguments(p.oid) = '') AS is_zero_arg_overload,
  p.prosecdef AS security_definer
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'list_customer_notification_inbox',
    'count_customer_notification_inbox_unread'
  )
ORDER BY p.proname, pg_get_function_identity_arguments(p.oid);

-- -----------------------------------------------------------------------------
-- E. Duplicate business slugs
-- -----------------------------------------------------------------------------
SELECT
  'E_duplicate_business_slugs' AS audit_section,
  lower(trim(business_slug)) AS slug_normalized,
  count(*) AS duplicate_count,
  array_agg(business_id ORDER BY business_id) AS business_ids
FROM public.business_settings
WHERE nullif(trim(business_slug), '') IS NOT NULL
GROUP BY lower(trim(business_slug))
HAVING count(*) > 1
ORDER BY duplicate_count DESC, slug_normalized;

-- -----------------------------------------------------------------------------
-- F. Null business_id rows on tenant-owned tables
-- -----------------------------------------------------------------------------
SELECT
  'F_null_business_id' AS audit_section,
  src.table_name,
  src.null_business_id_rows
FROM (
  SELECT 'business_settings'::text AS table_name,
         (SELECT count(*) FROM public.business_settings WHERE business_id IS NULL) AS null_business_id_rows
  UNION ALL
  SELECT 'services',
         (SELECT count(*) FROM public.services WHERE business_id IS NULL)
  UNION ALL
  SELECT 'staff_members',
         (SELECT count(*) FROM public.staff_members WHERE business_id IS NULL)
  UNION ALL
  SELECT 'bookings',
         (SELECT count(*) FROM public.bookings WHERE business_id IS NULL)
  UNION ALL
  SELECT 'blocked_days',
         (SELECT count(*) FROM public.blocked_days WHERE business_id IS NULL)
  UNION ALL
  SELECT 'business_customers',
         (SELECT count(*) FROM public.business_customers WHERE business_id IS NULL)
  UNION ALL
  SELECT 'business_closed_days',
         (SELECT count(*) FROM public.business_closed_days WHERE business_id IS NULL)
  UNION ALL
  SELECT 'business_gallery_images',
         (SELECT count(*) FROM public.business_gallery_images WHERE business_id IS NULL)
  UNION ALL
  SELECT 'notifications',
         (SELECT count(*) FROM public.notifications WHERE business_id IS NULL)
) src
ORDER BY src.table_name;

-- notification_recipients has no business_id column in repo schema.
-- Confirm live columns so a missing tenant column is visible.
SELECT
  'F_notification_recipients_columns' AS audit_section,
  column_name,
  data_type,
  is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'notification_recipients'
ORDER BY ordinal_position;

-- -----------------------------------------------------------------------------
-- G. Booking / service business mismatches
-- -----------------------------------------------------------------------------
SELECT
  'G_booking_service_business_mismatch' AS audit_section,
  count(*) AS mismatch_count
FROM public.bookings b
JOIN public.services s ON s.id = b.service_id
WHERE b.service_id IS NOT NULL
  AND b.business_id IS DISTINCT FROM s.business_id;

SELECT
  'G_booking_service_mismatch_sample' AS audit_section,
  b.id AS booking_id,
  b.business_id AS booking_business_id,
  s.id AS service_id,
  s.business_id AS service_business_id,
  b.date,
  b.booking_ref
FROM public.bookings b
JOIN public.services s ON s.id = b.service_id
WHERE b.service_id IS NOT NULL
  AND b.business_id IS DISTINCT FROM s.business_id
ORDER BY b.date DESC NULLS LAST
LIMIT 50;

-- -----------------------------------------------------------------------------
-- H. Booking / staff business mismatches
-- -----------------------------------------------------------------------------
SELECT
  'H_booking_staff_business_mismatch' AS audit_section,
  count(*) AS mismatch_count
FROM public.bookings b
JOIN public.staff_members st ON st.id = b.staff_id
WHERE b.staff_id IS NOT NULL
  AND b.business_id IS DISTINCT FROM st.business_id;

SELECT
  'H_booking_staff_mismatch_sample' AS audit_section,
  b.id AS booking_id,
  b.business_id AS booking_business_id,
  st.id AS staff_id,
  st.business_id AS staff_business_id,
  b.date,
  b.booking_ref
FROM public.bookings b
JOIN public.staff_members st ON st.id = b.staff_id
WHERE b.staff_id IS NOT NULL
  AND b.business_id IS DISTINCT FROM st.business_id
ORDER BY b.date DESC NULLS LAST
LIMIT 50;
