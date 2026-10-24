-- =============================================================================
-- XBOOK Phase 4F — READ-ONLY live RLS / grants / trigger audit
-- =============================================================================
-- Run manually in the Supabase SQL Editor.
-- SELECT-only. Makes no writes, grants, policy changes, or inserts.
-- Does not apply the trial migration.
-- Does not modify LIVE data.
-- =============================================================================

-- 1) business_settings RLS enabled / forced
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced,
  pg_get_userbyid(c.relowner) AS table_owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'business_settings';
-- Inspect: rls_enabled and rls_forced should both be true in production.

-- 2) All policies on business_settings (INSERT / UPDATE / others)
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual AS using_expression,
  with_check AS with_check_expression
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'business_settings'
ORDER BY cmd, policyname;
-- Inspect INSERT and UPDATE rows especially.
-- Ordinary owner create should WITH CHECK (business_id = auth.uid()).
-- A missing INSERT policy, or one that allows any UUID, is a live-schema risk
-- even after the trial trigger's owner_mismatch abort.

-- 3) INSERT / UPDATE policies only, with USING and WITH CHECK
SELECT
  policyname,
  permissive,
  roles,
  cmd,
  qual AS using_expression,
  with_check AS with_check_expression
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename = 'business_settings'
  AND cmd IN ('INSERT', 'UPDATE', 'ALL')
ORDER BY cmd, policyname;

-- 4) Table grants on business_settings for anon, authenticated, PUBLIC
SELECT
  grantee,
  table_schema,
  table_name,
  privilege_type,
  is_grantable
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name = 'business_settings'
  AND grantee IN ('anon', 'authenticated', 'PUBLIC')
ORDER BY grantee, privilege_type;
-- Expected shape (verify, do not assume):
--   authenticated: SELECT and possibly INSERT/UPDATE for the owner row
--   anon: SELECT only if public catalog needs it, otherwise none
--   PUBLIC: none preferred

-- 5) Raw ACL on business_settings (includes default privileges)
SELECT
  c.relname AS table_name,
  c.relacl AS raw_acl
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname = 'business_settings';

-- 6) Related subscription / eligibility table RLS + grants
SELECT
  c.relname AS table_name,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND c.relname IN (
    'business_subscriptions',
    'business_subscription_history',
    'business_trial_eligibility',
    'subscription_packages'
  )
ORDER BY c.relname;

SELECT
  grantee,
  table_name,
  string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND table_name IN (
    'business_subscriptions',
    'business_subscription_history',
    'business_trial_eligibility',
    'subscription_packages',
    'business_settings'
  )
  AND grantee IN ('anon', 'authenticated', 'PUBLIC')
GROUP BY grantee, table_name
ORDER BY table_name, grantee;
-- Subscription / eligibility / package tables should have 0 rows
-- for anon, authenticated, and PUBLIC after the trial migration.

-- 7) business_settings triggers (including the trial grant trigger)
SELECT
  t.tgname AS trigger_name,
  CASE t.tgenabled
    WHEN 'O' THEN 'origin'
    WHEN 'D' THEN 'disabled'
    WHEN 'R' THEN 'replica'
    WHEN 'A' THEN 'always'
    ELSE t.tgenabled::text
  END AS enabled,
  pg_get_userbyid(p.proowner) AS function_owner,
  p.prosecdef AS security_definer,
  pg_get_function_identity_arguments(p.oid) AS function_args,
  n.nspname || '.' || p.proname AS function_name,
  pg_get_triggerdef(t.oid) AS trigger_def
FROM pg_trigger t
JOIN pg_proc p ON p.oid = t.tgfoid
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE t.tgrelid = 'public.business_settings'::regclass
  AND NOT t.tgisinternal
ORDER BY t.tgname;
-- Expect business_settings_after_insert_trial: AFTER INSERT, SECURITY DEFINER.

-- 8) Relevant function ownership, SECURITY DEFINER, and EXECUTE privileges
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') AS authenticated_exec,
  has_function_privilege('PUBLIC', p.oid, 'EXECUTE') AS public_exec,
  has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_role_exec
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    '_try_grant_new_business_trial',
    '_business_settings_after_insert_trial',
    'get_my_business_access',
    'admin_apply_business_subscription',
    'admin_preview_business_subscription'
  )
ORDER BY p.proname, args;
-- Expect after trial migration:
--   _try_grant_new_business_trial: authenticated/anon/PUBLIC execute = false
--   _business_settings_after_insert_trial: authenticated/anon/PUBLIC execute = false
--   get_my_business_access: authenticated true, anon/PUBLIC false
--   admin_apply / admin_preview: authenticated/anon/PUBLIC false

-- 9) auth.uid() definition (how the trial gate reads the caller)
SELECT
  n.nspname AS schema_name,
  p.proname AS function_name,
  pg_get_userbyid(p.proowner) AS owner,
  p.prosecdef AS security_definer,
  pg_get_functiondef(p.oid) AS definition
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'auth'
  AND p.proname = 'uid';
-- Confirm it reads the request JWT (request.jwt.claim.sub / request.jwt.claims).
-- service_role and SQL Editor sessions typically have no JWT, so auth.uid() is NULL.

-- 10) Grant-helper source must contain the ownership gates
SELECT
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%owner_mismatch%' AS has_owner_mismatch_gate,
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%trusted_insert_no_auto_trial%' AS has_trusted_insert_gate,
  pg_get_functiondef('public._try_grant_new_business_trial(uuid)'::regprocedure)
    LIKE '%auth.uid()%' AS checks_auth_uid;
-- Expect true, true, true after the local ownership fix is applied.
-- If the function does not exist yet, this query errors: skip until applied.
