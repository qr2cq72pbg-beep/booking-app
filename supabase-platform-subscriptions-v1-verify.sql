-- =============================================================================
-- XBOOK Phase 3 — read-only production verification
-- Run AFTER supabase-platform-subscriptions-v1.sql. Makes no subscription writes.
-- =============================================================================

-- 1) Objects exist
SELECT
  to_regclass('public.subscription_packages') AS packages_table,
  to_regclass('public.business_subscriptions') AS current_table,
  to_regclass('public.business_subscription_history') AS history_table,
  to_regprocedure('public.admin_preview_business_subscription(uuid,text,text,date)') AS preview_rpc,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)') AS apply_rpc;

-- 2) Catalog
SELECT package_id, label, paid_months, bonus_months, access_months, price_eur, is_active
FROM public.subscription_packages
ORDER BY sort_order;

-- 3) Grandfathering: current state and history must be empty
SELECT
  (SELECT count(*) FROM public.business_settings) AS businesses,
  (SELECT count(*) FROM public.business_subscriptions) AS subscription_rows,
  (SELECT count(*) FROM public.business_subscription_history) AS history_rows;

SELECT business_id, business_name, business_slug
FROM public.business_settings
ORDER BY business_slug;

-- 4) RLS
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN (
  'subscription_packages',
  'business_subscriptions',
  'business_subscription_history'
)
ORDER BY relname;

-- 5) Table privileges: anon/authenticated/PUBLIC must have none
SELECT
  grantee,
  table_name,
  string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN (
    'subscription_packages',
    'business_subscriptions',
    'business_subscription_history'
  )
  AND grantee IN ('anon', 'authenticated', 'PUBLIC')
GROUP BY grantee, table_name;

-- 6) Execute privileges on write/preview RPCs
SELECT
  'anon' AS role_name,
  has_function_privilege('anon', 'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)', 'EXECUTE') AS apply_exec,
  has_function_privilege('anon', 'public.admin_preview_business_subscription(uuid,text,text,date)', 'EXECUTE') AS preview_exec
UNION ALL
SELECT
  'authenticated',
  has_function_privilege('authenticated', 'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)', 'EXECUTE'),
  has_function_privilege('authenticated', 'public.admin_preview_business_subscription(uuid,text,text,date)', 'EXECUTE')
UNION ALL
SELECT
  'service_role',
  has_function_privilege('service_role', 'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)', 'EXECUTE'),
  has_function_privilege('service_role', 'public.admin_preview_business_subscription(uuid,text,text,date)', 'EXECUTE');

-- 7) Calendar-month math
SELECT
  public.subscription_add_calendar_months(DATE '2026-01-31', 1) AS jan31_plus_1,
  public.subscription_add_calendar_months(DATE '2026-01-31', 2) AS jan31_plus_2,
  public.subscription_add_calendar_months(DATE '2026-10-09', 1) AS oct9_plus_1,
  public.subscription_add_calendar_months(DATE '2026-10-09', 4) AS oct9_plus_4;

-- 8) Booking RPCs unchanged (names still present)
SELECT
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking;
