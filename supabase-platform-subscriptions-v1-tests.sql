-- =============================================================================
-- XBOOK Admin Control Center — Phase 3
-- Read-only checks AFTER supabase-platform-subscriptions-v1.sql is applied.
-- Does not write production subscription data. Does not deploy functions.
-- =============================================================================

-- Objects exist
SELECT
  to_regclass('public.subscription_packages') AS packages_table,
  to_regclass('public.business_subscriptions') AS current_table,
  to_regclass('public.business_subscription_history') AS history_table,
  to_regprocedure('public.subscription_add_calendar_months(date,integer)') AS add_months,
  to_regprocedure('public.admin_preview_business_subscription(uuid,text,text,date)') AS preview_rpc,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)') AS apply_rpc;

-- Catalog matches product pricing
SELECT package_id, label, paid_months, bonus_months, access_months, price_eur, is_active
FROM public.subscription_packages
ORDER BY sort_order;
-- Expect:
-- month_1  / 1 / 0 / 1  / 39.99
-- pack_3_1 / 3 / 1 / 4  / 119.97
-- pack_6_2 / 6 / 2 / 8  / 239.94
-- pack_9_3 / 9 / 3 / 12 / 359.91

-- Grandfathering: no automatic activations
SELECT count(*) AS subscription_rows FROM public.business_subscriptions;
-- Expect 0 after first apply.

SELECT count(*) AS history_rows FROM public.business_subscription_history;
-- Expect 0 after first apply.

-- RLS + FORCE
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN (
  'subscription_packages',
  'business_subscriptions',
  'business_subscription_history'
)
ORDER BY relname;

-- Client roles must have no table privileges
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
-- Expect 0 rows.

-- Calendar-month examples (read-only)
SELECT
  public.subscription_add_calendar_months(DATE '2026-01-31', 1) AS jan31_plus_1,
  public.subscription_add_calendar_months(DATE '2026-01-31', 2) AS jan31_plus_2,
  public.subscription_add_calendar_months(DATE '2026-10-09', 1) AS oct9_plus_1,
  public.subscription_add_calendar_months(DATE '2026-10-09', 4) AS oct9_plus_4;
-- Expect 2026-02-28, 2026-03-31, 2026-11-09, 2027-02-09.

-- History immutability trigger
SELECT tgname
FROM pg_trigger
WHERE tgrelid = 'public.business_subscription_history'::regclass
  AND tgname = 'business_subscription_history_no_update';
