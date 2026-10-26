-- =============================================================================
-- XBOOK Phase 4F — read-only checks AFTER trial migration is applied.
-- Does not write production subscription data.
-- Does not grant Angel Touch. Does not activate Test Barber.
-- Does not modify create_booking / create_recurring_bookings.
-- =============================================================================

-- 1) Objects exist; booking RPCs still present and unchanged in identity
SELECT
  to_regclass('public.business_trial_eligibility') AS eligibility_table,
  to_regclass('public.business_subscriptions') AS current_table,
  to_regprocedure('public._try_grant_new_business_trial(uuid)') AS grant_fn,
  to_regprocedure('public._business_settings_after_insert_trial()') AS trigger_fn,
  to_regprocedure('public._subscription_entitlement_status(text,date,timestamptz,date,timestamptz)') AS status_fn,
  to_regprocedure('public.get_my_business_access()') AS owner_access_rpc,
  to_regprocedure('public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)') AS apply_rpc,
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking,
  to_regprocedure('public.create_recurring_bookings(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)') AS create_recurring;

-- 2) Trigger is attached to business_settings INSERT only
SELECT tgname, tgenabled, pg_get_triggerdef(oid) AS def
FROM pg_trigger
WHERE tgrelid = 'public.business_settings'::regclass
  AND tgname = 'business_settings_after_insert_trial';
-- Expect one enabled AFTER INSERT row-level trigger.

-- 3) Timestamp columns exist
SELECT table_name, column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
    (table_name = 'business_subscriptions' AND column_name IN ('starts_at', 'expires_at', 'access_kind'))
    OR (table_name = 'business_subscription_history' AND column_name IN ('new_starts_at', 'new_expires_at', 'operation'))
    OR (table_name = 'business_trial_eligibility' AND column_name IN ('owner_user_id', 'consumed_reason', 'trial_starts_at', 'trial_expires_at'))
  )
ORDER BY table_name, column_name;

-- 4) Exactly 336 hours (new trials = 14 days)
SELECT EXTRACT(EPOCH FROM (interval '14 days'))::bigint AS trial_seconds;
-- Expect 1209600

SELECT
  public._subscription_entitlement_status(
    'trial',
    CURRENT_DATE + 7,
    clock_timestamp() + interval '7 days',
    CURRENT_DATE,
    clock_timestamp()
  ) AS trial_active,
  public._subscription_entitlement_status(
    'trial',
    CURRENT_DATE,
    clock_timestamp() - interval '1 second',
    CURRENT_DATE,
    clock_timestamp()
  ) AS trial_expired,
  public._subscription_entitlement_status(
    'complimentary',
    NULL,
    NULL,
    CURRENT_DATE,
    clock_timestamp()
  ) AS complimentary_unlimited_active,
  public._subscription_row_status(CURRENT_DATE, CURRENT_DATE) AS paid_today_still_date_active;
-- Expect active, expired, active, active

-- 5) Client roles cannot read/write subscription or eligibility tables
SELECT
  grantee,
  table_name,
  string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN (
    'subscription_packages',
    'business_subscriptions',
    'business_subscription_history',
    'business_trial_eligibility'
  )
  AND grantee IN ('anon', 'authenticated', 'PUBLIC')
GROUP BY grantee, table_name;
-- Expect 0 rows.

-- 6) Clients cannot self-grant. Admin apply stays service_role only.
SELECT
  'anon' AS role_name,
  has_function_privilege('anon', 'public._try_grant_new_business_trial(uuid)', 'EXECUTE') AS grant_exec,
  has_function_privilege('anon', 'public.get_my_business_access()', 'EXECUTE') AS owner_access,
  has_function_privilege(
    'anon',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  ) AS apply_exec
UNION ALL
SELECT
  'authenticated',
  has_function_privilege('authenticated', 'public._try_grant_new_business_trial(uuid)', 'EXECUTE'),
  has_function_privilege('authenticated', 'public.get_my_business_access()', 'EXECUTE'),
  has_function_privilege(
    'authenticated',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  )
UNION ALL
SELECT
  'service_role',
  has_function_privilege('service_role', 'public._try_grant_new_business_trial(uuid)', 'EXECUTE'),
  has_function_privilege('service_role', 'public.get_my_business_access()', 'EXECUTE'),
  has_function_privilege(
    'service_role',
    'public.admin_apply_business_subscription(uuid,text,text,date,uuid,uuid,text,date)',
    'EXECUTE'
  );
-- Expect:
-- anon: false, false, false
-- authenticated: false, true, false
-- service_role: false/true (owner default), true/true, true

-- 7) Existing LIVE businesses must be unchanged by this migration
SELECT
  bs.business_slug,
  bs.business_name,
  sub.access_kind,
  sub.package_id,
  sub.expires_on,
  sub.expires_at,
  sub.starts_at,
  el.consumed_reason,
  el.trial_starts_at,
  el.trial_expires_at
FROM public.business_settings bs
LEFT JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
LEFT JOIN public.business_trial_eligibility el ON el.owner_user_id = bs.business_id
WHERE bs.business_slug IN ('angel-touch', 'gorge123')
ORDER BY bs.business_slug;
-- Expect:
-- angel-touch: complimentary unchanged, expires_on NULL, no trial timestamps,
--   eligibility consumed_reason=preexisting_owner, no trial window
-- gorge123: still unconfigured (no subscription row),
--   eligibility consumed_reason=preexisting_owner, no trial window

-- 8) Existing businesses were fenced, not given a trial entitlement
SELECT
  count(*) FILTER (WHERE el.consumed_reason = 'preexisting_owner') AS fenced_live,
  count(*) FILTER (WHERE el.consumed_reason = 'automatic_trial') AS automatic_live,
  count(*) FILTER (WHERE sub.access_kind = 'trial') AS trial_entitlements
FROM public.business_settings bs
JOIN public.business_trial_eligibility el ON el.owner_user_id = bs.business_id
LEFT JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
WHERE bs.business_slug IN ('angel-touch', 'gorge123');
-- Expect fenced_live=2, automatic_live=0, trial_entitlements=0

-- 9) Catalog still FLEX / PLUS / MAX only. No trial package. No revenue package for FREE.
SELECT package_id, label, price_eur, is_active
FROM public.subscription_packages
WHERE is_active
   OR package_id ILIKE '%trial%'
   OR label ILIKE '%trial%'
ORDER BY sort_order, package_id;
-- Expect flex_monthly, plus_4_months, max_18_months only among active rows.
-- Expect no trial package_id.

-- 10) History operations include grant_trial
SELECT pg_get_constraintdef(oid) AS history_operations
FROM pg_constraint
WHERE conrelid = 'public.business_subscription_history'::regclass
  AND conname = 'business_subscription_history_operation_ok';
-- Expect grant_trial in the list.

-- 11) RLS forced on eligibility
SELECT relname, relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relname IN (
  'business_trial_eligibility',
  'business_subscriptions',
  'business_subscription_history'
)
ORDER BY relname;
-- Expect rls + force rls true.

-- 12) Booking enforcement is still absent from this phase
-- create_booking / create_recurring_bookings identities exist (query 1).
-- This migration does not wrap or replace those functions.
SELECT
  'Phase 4E booking restrictions are NOT deployed. Expired trial does not block new bookings.'
  AS booking_enforcement_gap;

-- 13) Grant helper source must contain the ownership and trusted-insert gates
SELECT
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%owner_mismatch%' AS has_owner_mismatch_gate,
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%trusted_insert_no_auto_trial%' AS has_trusted_insert_gate,
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%auth.uid()%' AS checks_auth_uid;
-- Expect true, true, true.

-- Live INSERT/UPDATE policy details for business_settings are in
-- supabase-platform-subscriptions-v1-trial-rls-audit.sql (manual, read-only).
