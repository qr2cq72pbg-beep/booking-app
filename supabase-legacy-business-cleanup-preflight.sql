-- =============================================================================
-- XBOOK — LEGACY BUSINESS CLEANUP PREFLIGHT (READ-ONLY)
-- =============================================================================
-- SELECT / catalog inspection only.
-- Do NOT run DELETE / TRUNCATE / DROP / UPDATE / ALTER / GRANT.
-- Safe for the SQL Editor. Re-run immediately before any approved cleanup.
-- Customer names, phones, and emails are NOT selected.
-- Project: sdqothuulzeczcncyfqd
-- =============================================================================

-- Shared allowlists (must match the approved candidate list exactly)
-- RETAIN:
--   bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb  Angel Touch Beauty & Care Studio
--   4fb21268-7a4d-4c62-8c0a-30f7571eac41  Test Barber (slug gorge123)
-- =============================================================================

WITH retained AS (
  SELECT unnest(ARRAY[
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  ]) AS business_id
),
candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0'::uuid,
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6'::uuid,
    '41784a40-40e5-418d-9435-49ebab176196'::uuid,
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb'::uuid,
    'cc26d880-893c-4738-9d26-f9a0e15a03a6'::uuid,
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2'::uuid,
    '289c7459-053e-4cd8-908b-24bd8d42b3f1'::uuid,
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
    '8695e975-5486-4739-88bf-4c89e7c503e2'::uuid,
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834'::uuid,
    '57434ecd-49e4-420c-8081-f77e7788e50b'::uuid,
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid,
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7'::uuid,
    '6dc7ca3a-30be-4254-ba43-190644314b65'::uuid,
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd'::uuid,
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'::uuid
  ]) AS business_id
)
SELECT
  'A_allowlist_validation' AS section,
  (SELECT count(*) FROM public.business_settings) AS live_business_count,
  (SELECT count(*) FROM retained r JOIN public.business_settings bs ON bs.business_id = r.business_id) AS retained_found,
  (SELECT count(*) FROM candidates c JOIN public.business_settings bs ON bs.business_id = c.business_id) AS candidates_found,
  (SELECT count(*) FROM candidates c WHERE c.business_id IN (SELECT business_id FROM retained)) AS overlap_retained_and_candidates,
  (SELECT count(*) FROM public.business_settings bs
     WHERE bs.business_id NOT IN (SELECT business_id FROM retained)
       AND bs.business_id NOT IN (SELECT business_id FROM candidates)) AS live_businesses_not_on_either_list,
  (SELECT count(*) FROM candidates c
     WHERE NOT EXISTS (SELECT 1 FROM public.business_settings bs WHERE bs.business_id = c.business_id)) AS missing_candidates,
  (SELECT count(*) FROM retained r
     WHERE NOT EXISTS (SELECT 1 FROM public.business_settings bs WHERE bs.business_id = r.business_id)) AS missing_retained;

-- B. Live identity of retained + candidates (no customer PII)
WITH retained AS (
  SELECT unnest(ARRAY[
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  ]) AS business_id
),
candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0'::uuid,
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6'::uuid,
    '41784a40-40e5-418d-9435-49ebab176196'::uuid,
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb'::uuid,
    'cc26d880-893c-4738-9d26-f9a0e15a03a6'::uuid,
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2'::uuid,
    '289c7459-053e-4cd8-908b-24bd8d42b3f1'::uuid,
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
    '8695e975-5486-4739-88bf-4c89e7c503e2'::uuid,
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834'::uuid,
    '57434ecd-49e4-420c-8081-f77e7788e50b'::uuid,
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid,
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7'::uuid,
    '6dc7ca3a-30be-4254-ba43-190644314b65'::uuid,
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd'::uuid,
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'::uuid
  ]) AS business_id
)
SELECT
  'B_business_identity' AS section,
  CASE
    WHEN bs.business_id IN (SELECT business_id FROM retained) THEN 'RETAIN'
    ELSE 'CANDIDATE'
  END AS disposition,
  bs.business_id,
  bs.business_name,
  bs.business_slug,
  up.email AS owner_profile_email,
  au.email AS auth_email,
  (au.id IS NOT NULL) AS has_auth_user,
  au.last_sign_in_at AS owner_last_sign_in_at,
  (SELECT count(*) FROM public.business_customers bc WHERE bc.business_id = bs.business_id) AS crm_rows,
  (SELECT count(*) FROM public.business_customers bc WHERE bc.business_id = bs.business_id AND bc.customer_user_id IS NOT NULL) AS linked_members,
  (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) AS bookings,
  (SELECT count(*) FROM public.services s WHERE s.business_id = bs.business_id) AS services,
  (SELECT count(*) FROM public.staff_members st WHERE st.business_id = bs.business_id) AS staff
FROM public.business_settings bs
LEFT JOIN public.user_profiles up ON up.id = bs.business_id
LEFT JOIN auth.users au ON au.id = bs.business_id
WHERE bs.business_id IN (SELECT business_id FROM retained)
   OR bs.business_id IN (SELECT business_id FROM candidates)
ORDER BY disposition DESC, bs.business_name, bs.business_slug;

-- C. FKs pointing at business_settings
SELECT
  'C_fks_to_business_settings' AS section,
  n.nspname AS table_schema,
  rel.relname AS table_name,
  pg_get_constraintdef(c.oid) AS constraint_def
FROM pg_constraint c
JOIN pg_class rel ON rel.oid = c.conrelid
JOIN pg_namespace n ON n.oid = rel.relnamespace
JOIN pg_class frel ON frel.oid = c.confrelid
JOIN pg_namespace fn ON fn.oid = frel.relnamespace
WHERE c.contype = 'f'
  AND fn.nspname = 'public'
  AND frel.relname = 'business_settings'
ORDER BY rel.relname;

-- D. All public/storage columns named business_id or originating_business_id
SELECT
  'D_columns_named_business_id' AS section,
  n.nspname AS table_schema,
  c.relname AS table_name,
  a.attname AS column_name
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.attnum > 0
  AND NOT a.attisdropped
  AND c.relkind = 'r'
  AND n.nspname IN ('public', 'storage')
  AND a.attname IN ('business_id', 'originating_business_id')
ORDER BY n.nspname, c.relname, a.attname;

-- E. FKs on core non-CASCADE tenant tables
SELECT
  'E_fks_on_core_tables' AS section,
  conrelid::regclass::text AS tbl,
  confrelid::regclass::text AS refs,
  pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE contype = 'f'
  AND conrelid::regclass::text IN (
    'bookings', 'services', 'staff_members', 'blocked_days',
    'business_push_tokens', 'business_client_notes',
    'notification_recipients', 'customer_push_tokens',
    'customer_notification_preferences', 'customer_private_profiles',
    'user_profiles', 'platform_admin_audit_log'
  )
ORDER BY 1, 2;

-- F. Triggers that fire on tenant tables (names only)
SELECT
  'F_triggers' AS section,
  event_object_schema,
  event_object_table,
  trigger_name,
  action_timing,
  event_manipulation,
  action_statement
FROM information_schema.triggers
WHERE event_object_schema = 'public'
  AND event_object_table IN (
    'business_settings', 'bookings', 'services', 'staff_members',
    'blocked_days', 'business_customers', 'business_closed_days',
    'business_gallery_images', 'notifications', 'staff_time_off',
    'business_push_events'
  )
ORDER BY event_object_table, trigger_name, event_manipulation;

-- G. Per-table deletion vs remaining counts
WITH candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0'::uuid,
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6'::uuid,
    '41784a40-40e5-418d-9435-49ebab176196'::uuid,
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb'::uuid,
    'cc26d880-893c-4738-9d26-f9a0e15a03a6'::uuid,
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2'::uuid,
    '289c7459-053e-4cd8-908b-24bd8d42b3f1'::uuid,
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
    '8695e975-5486-4739-88bf-4c89e7c503e2'::uuid,
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834'::uuid,
    '57434ecd-49e4-420c-8081-f77e7788e50b'::uuid,
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid,
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7'::uuid,
    '6dc7ca3a-30be-4254-ba43-190644314b65'::uuid,
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd'::uuid,
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'::uuid
  ]) AS business_id
)
SELECT * FROM (
  SELECT 'G_counts' AS section, 'business_settings' AS table_name,
    (SELECT count(*) FROM public.business_settings WHERE business_id IN (SELECT business_id FROM candidates)) AS delete_count,
    (SELECT count(*) FROM public.business_settings WHERE business_id NOT IN (SELECT business_id FROM candidates)) AS remain_count,
    (SELECT count(*) FROM public.business_settings) AS live_total
  UNION ALL
  SELECT 'G_counts', 'bookings',
    (SELECT count(*) FROM public.bookings WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.bookings WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.bookings)
  UNION ALL
  SELECT 'G_counts', 'services',
    (SELECT count(*) FROM public.services WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.services WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.services)
  UNION ALL
  SELECT 'G_counts', 'staff_members',
    (SELECT count(*) FROM public.staff_members WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.staff_members WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.staff_members)
  UNION ALL
  SELECT 'G_counts', 'blocked_days',
    (SELECT count(*) FROM public.blocked_days WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.blocked_days WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.blocked_days)
  UNION ALL
  SELECT 'G_counts', 'business_closed_days',
    (SELECT count(*) FROM public.business_closed_days WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_closed_days WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_closed_days)
  UNION ALL
  SELECT 'G_counts', 'business_customers',
    (SELECT count(*) FROM public.business_customers WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customers WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customers)
  UNION ALL
  SELECT 'G_counts', 'business_customer_counters',
    (SELECT count(*) FROM public.business_customer_counters WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_counters WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_counters)
  UNION ALL
  SELECT 'G_counts', 'business_customer_identity_links',
    (SELECT count(*) FROM public.business_customer_identity_links WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_identity_links WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_identity_links)
  UNION ALL
  SELECT 'G_counts', 'business_customer_internal_notes',
    (SELECT count(*) FROM public.business_customer_internal_notes WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_internal_notes WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_customer_internal_notes)
  UNION ALL
  SELECT 'G_counts', 'business_gallery_images',
    (SELECT count(*) FROM public.business_gallery_images WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_gallery_images WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_gallery_images)
  UNION ALL
  SELECT 'G_counts', 'notifications',
    (SELECT count(*) FROM public.notifications WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.notifications WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.notifications)
  UNION ALL
  SELECT 'G_counts', 'notification_recipients_via_legacy_notifications',
    (SELECT count(*) FROM public.notification_recipients nr
       JOIN public.notifications n ON n.id = nr.notification_id
       WHERE n.business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.notification_recipients nr
       JOIN public.notifications n ON n.id = nr.notification_id
       WHERE n.business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.notification_recipients)
  UNION ALL
  SELECT 'G_counts', 'staff_time_off',
    (SELECT count(*) FROM public.staff_time_off WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.staff_time_off WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.staff_time_off)
  UNION ALL
  SELECT 'G_counts', 'business_push_events',
    (SELECT count(*) FROM public.business_push_events WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_push_events WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_push_events)
  UNION ALL
  SELECT 'G_counts', 'customer_app_login_codes',
    (SELECT count(*) FROM public.customer_app_login_codes WHERE originating_business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.customer_app_login_codes WHERE originating_business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.customer_app_login_codes)
  UNION ALL
  SELECT 'G_counts', 'business_push_tokens',
    (SELECT count(*) FROM public.business_push_tokens WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_push_tokens WHERE business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.business_push_tokens)
  UNION ALL
  SELECT 'G_counts', 'platform_admin_audit_log',
    (SELECT count(*) FROM public.platform_admin_audit_log WHERE business_id IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.platform_admin_audit_log WHERE business_id IS NULL OR business_id NOT IN (SELECT business_id FROM candidates)),
    (SELECT count(*) FROM public.platform_admin_audit_log)
) t
ORDER BY table_name;

-- business_client_notes is not present on this live project (to_regclass was null).
-- public.staff exists (0 rows) and is included in the cleanup script.

-- H. Cross-business customer overlap (counts only, no PII)
WITH retained AS (
  SELECT unnest(ARRAY[
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  ]) AS business_id
),
candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0'::uuid,
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6'::uuid,
    '41784a40-40e5-418d-9435-49ebab176196'::uuid,
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb'::uuid,
    'cc26d880-893c-4738-9d26-f9a0e15a03a6'::uuid,
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2'::uuid,
    '289c7459-053e-4cd8-908b-24bd8d42b3f1'::uuid,
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
    '8695e975-5486-4739-88bf-4c89e7c503e2'::uuid,
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834'::uuid,
    '57434ecd-49e4-420c-8081-f77e7788e50b'::uuid,
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid,
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7'::uuid,
    '6dc7ca3a-30be-4254-ba43-190644314b65'::uuid,
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd'::uuid,
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'::uuid
  ]) AS business_id
)
SELECT 'H1_multi_business_linked_customers' AS section, count(*)::int AS n
FROM (
  SELECT customer_user_id
  FROM public.business_customers
  WHERE customer_user_id IS NOT NULL
  GROUP BY customer_user_id
  HAVING count(DISTINCT business_id) > 1
) x
UNION ALL
SELECT 'H2_linked_on_retained_and_candidate', count(*)::int
FROM (
  SELECT customer_user_id
  FROM public.business_customers
  WHERE customer_user_id IS NOT NULL
  GROUP BY customer_user_id
  HAVING bool_or(business_id IN (SELECT business_id FROM retained))
     AND bool_or(business_id IN (SELECT business_id FROM candidates))
) x
UNION ALL
SELECT 'H3_linked_on_both_retained', count(*)::int
FROM (
  SELECT customer_user_id
  FROM public.business_customers
  WHERE customer_user_id IS NOT NULL
    AND business_id IN (SELECT business_id FROM retained)
  GROUP BY customer_user_id
  HAVING count(DISTINCT business_id) > 1
) x
UNION ALL
SELECT 'H4_legacy_owners_who_are_retained_customers', count(*)::int
FROM public.business_settings bs
WHERE bs.business_id IN (SELECT business_id FROM candidates)
  AND EXISTS (
    SELECT 1 FROM public.business_customers bc
    WHERE bc.customer_user_id = bs.business_id
      AND bc.business_id IN (SELECT business_id FROM retained)
  )
UNION ALL
SELECT 'H5_retained_crm_rows', count(*)::int
FROM public.business_customers
WHERE business_id IN (SELECT business_id FROM retained)
UNION ALL
SELECT 'H6_retained_linked_members', count(*)::int
FROM public.business_customers
WHERE business_id IN (SELECT business_id FROM retained)
  AND customer_user_id IS NOT NULL
UNION ALL
SELECT 'H7_candidate_linked_members', count(*)::int
FROM public.business_customers
WHERE business_id IN (SELECT business_id FROM candidates)
  AND customer_user_id IS NOT NULL
UNION ALL
SELECT 'H8_candidate_linked_also_on_retained', count(*)::int
FROM public.business_customers bc
WHERE bc.business_id IN (SELECT business_id FROM candidates)
  AND bc.customer_user_id IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.business_customers r
    WHERE r.customer_user_id = bc.customer_user_id
      AND r.business_id IN (SELECT business_id FROM retained)
  );

-- I. Candidate Auth owners (owner emails only — these are business owners, not customers)
WITH candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0'::uuid,
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6'::uuid,
    '41784a40-40e5-418d-9435-49ebab176196'::uuid,
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb'::uuid,
    'cc26d880-893c-4738-9d26-f9a0e15a03a6'::uuid,
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2'::uuid,
    '289c7459-053e-4cd8-908b-24bd8d42b3f1'::uuid,
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
    '8695e975-5486-4739-88bf-4c89e7c503e2'::uuid,
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834'::uuid,
    '57434ecd-49e4-420c-8081-f77e7788e50b'::uuid,
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid,
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7'::uuid,
    '6dc7ca3a-30be-4254-ba43-190644314b65'::uuid,
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd'::uuid,
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'::uuid
  ]) AS business_id
)
SELECT
  'I_candidate_auth_owners' AS section,
  bs.business_id,
  bs.business_name,
  bs.business_slug,
  au.email AS auth_email,
  au.last_sign_in_at,
  up.role AS profile_role,
  (SELECT count(*) FROM public.business_customers bc
     WHERE bc.customer_user_id = bs.business_id) AS owner_is_customer_elsewhere_count
FROM public.business_settings bs
JOIN auth.users au ON au.id = bs.business_id
LEFT JOIN public.user_profiles up ON up.id = bs.business_id
WHERE bs.business_id IN (SELECT business_id FROM candidates)
ORDER BY au.email;

-- J. Storage object counts by folder (UUID prefix)
WITH candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0',
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6',
    '41784a40-40e5-418d-9435-49ebab176196',
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb',
    'cc26d880-893c-4738-9d26-f9a0e15a03a6',
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2',
    '289c7459-053e-4cd8-908b-24bd8d42b3f1',
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685',
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7',
    '8695e975-5486-4739-88bf-4c89e7c503e2',
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834',
    '57434ecd-49e4-420c-8081-f77e7788e50b',
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494',
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7',
    '6dc7ca3a-30be-4254-ba43-190644314b65',
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd',
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'
  ]) AS folder
),
retained AS (
  SELECT unnest(ARRAY[
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb',
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'
  ]) AS folder
),
objs AS (
  SELECT
    bucket_id,
    (storage.foldername(name))[1] AS owner_folder,
    name,
    id
  FROM storage.objects
  WHERE bucket_id IN ('business-logos', 'business-gallery')
)
SELECT
  'J_storage_summary' AS section,
  bucket_id,
  CASE
    WHEN owner_folder IN (SELECT folder FROM retained) THEN 'RETAIN'
    WHEN owner_folder IN (SELECT folder FROM candidates) THEN 'CANDIDATE'
    ELSE 'OTHER'
  END AS disposition,
  count(*) AS object_count
FROM objs
GROUP BY 2, 3, 1
ORDER BY 3, 1, 2;

-- K. Storage manifest for candidate folders only (paths, no file bytes)
WITH candidates AS (
  SELECT unnest(ARRAY[
    '8b8ac262-7def-44b4-967a-635f8acd76d0',
    'dc9064d6-4ab3-4bfe-b6a5-ef4f30bc85d6',
    '41784a40-40e5-418d-9435-49ebab176196',
    '2c441698-8d9a-46f3-9e56-9a5afce4e0eb',
    'cc26d880-893c-4738-9d26-f9a0e15a03a6',
    'a18d8c8f-1b10-43ce-b86f-593912d4f6c2',
    '289c7459-053e-4cd8-908b-24bd8d42b3f1',
    '4cd64220-f123-4eb6-a10b-dd6b66e6a685',
    'b9e87758-1ad0-477f-8fe7-5fcab88314f7',
    '8695e975-5486-4739-88bf-4c89e7c503e2',
    '4f061778-3e9d-4a7e-b607-1b5a4d75a834',
    '57434ecd-49e4-420c-8081-f77e7788e50b',
    '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494',
    '6bfbdce1-5020-479e-ba3e-5552a61ce6d7',
    '6dc7ca3a-30be-4254-ba43-190644314b65',
    '8bf87a44-4b05-4de6-aae0-2704b97b8dbd',
    '1e178a2c-6a20-43e8-892c-e9a08e45a6a4'
  ]) AS folder
)
SELECT
  'K_candidate_storage_manifest' AS section,
  o.bucket_id,
  o.name AS object_path,
  o.id AS object_id,
  o.created_at,
  o.updated_at,
  o.metadata->>'size' AS size_bytes,
  o.metadata->>'mimetype' AS mimetype
FROM storage.objects o
WHERE o.bucket_id IN ('business-logos', 'business-gallery')
  AND (storage.foldername(o.name))[1] IN (SELECT folder FROM candidates)
ORDER BY o.bucket_id, o.name;

-- L. RPCs that take a business id argument (catalog only)
SELECT
  'L_rpcs_with_business_id_arg' AS section,
  p.proname AS function_name,
  pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND pg_get_function_identity_arguments(p.oid) ILIKE '%business_id%'
ORDER BY p.proname;
