-- =============================================================================
-- XBOOK Phase 4C — read-only checks AFTER owner-read migration is applied.
-- Does not write production subscription data. Does not grant Angel Touch.
-- =============================================================================

-- 1) New RPC identities exist; booking RPC unchanged
SELECT
  to_regprocedure('public.get_my_business_access()') AS owner_access_rpc,
  to_regprocedure('public.list_active_subscription_packages()') AS owner_catalog_rpc,
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)') AS apply_rpc_access;

-- 2) Client roles still have no table privileges
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

-- 3) Execute privileges
SELECT
  'anon' AS role_name,
  has_function_privilege('anon', 'public.get_my_business_access()', 'EXECUTE') AS owner_access,
  has_function_privilege('anon', 'public.list_active_subscription_packages()', 'EXECUTE') AS owner_catalog,
  has_function_privilege(
    'anon',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  ) AS admin_apply
UNION ALL
SELECT
  'authenticated',
  has_function_privilege('authenticated', 'public.get_my_business_access()', 'EXECUTE'),
  has_function_privilege('authenticated', 'public.list_active_subscription_packages()', 'EXECUTE'),
  has_function_privilege(
    'authenticated',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  )
UNION ALL
SELECT
  'service_role',
  has_function_privilege('service_role', 'public.get_my_business_access()', 'EXECUTE'),
  has_function_privilege('service_role', 'public.list_active_subscription_packages()', 'EXECUTE'),
  has_function_privilege(
    'service_role',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  );
-- Expect:
-- anon: false, false, false
-- authenticated: true, true, false
-- service_role: true/true (default owner) or as granted, apply true

-- 4) No production entitlement rows were created by this migration
SELECT
  (SELECT count(*) FROM public.business_settings) AS businesses,
  (SELECT count(*) FROM public.business_subscriptions) AS subscription_rows,
  (SELECT count(*) FROM public.business_subscription_history) AS history_rows;

SELECT bs.business_slug, sub.business_id IS NOT NULL AS has_subscription_row
FROM public.business_settings bs
LEFT JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
ORDER BY bs.business_slug;
-- Expect angel-touch and gorge123 still without rows until an admin grant.

-- 5) Catalog still FLEX / PLUS / MAX only
SELECT package_id, label, access_months, price_eur, is_best_value, is_active
FROM public.subscription_packages
WHERE is_active
ORDER BY sort_order;
-- Expect flex_monthly, plus_4_months, max_18_months.

-- 6) Functions are SECURITY DEFINER with public search_path
SELECT
  p.proname,
  p.prosecdef AS security_definer,
  pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'get_my_business_access',
    'list_active_subscription_packages'
  )
ORDER BY p.proname;
