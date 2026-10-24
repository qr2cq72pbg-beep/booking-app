-- =============================================================================
-- XBOOK Phase 4A — read-only checks AFTER access migration is applied.
-- Does not write production subscription data. Does not grant Angel Touch.
-- Does not deploy functions.
-- =============================================================================

-- 1) Objects and new RPC identities
SELECT
  to_regclass('public.business_subscriptions') AS current_table,
  to_regprocedure('public._subscription_row_status(date,date)') AS status_helper,
  to_regprocedure('public.admin_preview_business_subscription(uuid,text,text,date)') AS preview_rpc_paid,
  to_regprocedure('public.admin_preview_business_subscription(uuid,text,text,date,date)') AS preview_rpc_access,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text)') AS apply_rpc_paid,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)') AS apply_rpc_access,
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking;

-- 2) No public FREE package
SELECT package_id, label, is_active
FROM public.subscription_packages
WHERE package_id ILIKE '%free%'
   OR package_id ILIKE '%comp%'
   OR label ILIKE '%free%';
-- Expect 0 rows.

-- 3) Catalog still FLEX / PLUS / MAX
SELECT package_id, label, access_months, price_eur, is_active
FROM public.subscription_packages
WHERE is_active
ORDER BY sort_order;
-- Expect flex_monthly, plus_4_months, max_18_months only.

-- 4) Grandfathering: still no entitlement rows
SELECT
  (SELECT count(*) FROM public.business_settings) AS businesses,
  (SELECT count(*) FROM public.business_subscriptions) AS subscription_rows,
  (SELECT count(*) FROM public.business_subscription_history) AS history_rows;
-- Expect 2 / 0 / 0 until an admin later grants access.

SELECT business_slug FROM public.business_settings ORDER BY business_slug;
-- Expect angel-touch, gorge123.

-- 5) Columns exist
SELECT column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'business_subscriptions'
  AND column_name IN ('access_kind', 'package_id', 'expires_on')
ORDER BY column_name;
-- access_kind NO, package_id YES, expires_on YES

-- 6) Client roles still have no table privileges
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

-- 7) Status helper
SELECT
  public._subscription_row_status(NULL, CURRENT_DATE) AS unlimited_is_active,
  public._subscription_row_status(CURRENT_DATE, CURRENT_DATE) AS today_is_active,
  public._subscription_row_status(CURRENT_DATE - 1, CURRENT_DATE) AS yesterday_is_expired;
-- Expect active, active, expired.

-- 8) Paid preview still works on an unconfigured live business (no write)
-- Replace the UUID only when running after approval; this is read-only preview.
-- SELECT public.admin_preview_business_subscription(
--   '4fb21268-7a4d-4c62-8c0a-30f7571eac41',
--   'flex_monthly',
--   'activate',
--   CURRENT_DATE,
--   NULL
-- );
-- Expect ok=true, access_kind=paid, is_revenue=true, new_expires_on = start + 1 month.

-- 9) Complimentary preview (no write)
-- SELECT public.admin_preview_business_subscription(
--   '4fb21268-7a4d-4c62-8c0a-30f7571eac41',
--   NULL,
--   'grant_complimentary',
--   CURRENT_DATE,
--   NULL
-- );
-- Expect ok=true, access_kind=complimentary, is_revenue=false, unlimited=true.

-- 10) Execute privileges: anon/authenticated must not execute apply
SELECT
  'anon' AS role_name,
  has_function_privilege(
    'anon',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  ) AS apply_exec
UNION ALL
SELECT
  'authenticated',
  has_function_privilege(
    'authenticated',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  )
UNION ALL
SELECT
  'service_role',
  has_function_privilege(
    'service_role',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  );
-- Expect false, false, true.
