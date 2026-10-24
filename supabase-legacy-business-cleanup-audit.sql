-- =============================================================================
-- XBOOK — LEGACY TEST BUSINESS CLEANUP AUDIT (READ-ONLY)
-- =============================================================================
-- SELECT only. Do NOT run DELETE / TRUNCATE / DROP / UPDATE / ALTER.
-- Safe for the SQL Editor. Re-run anytime.
-- Customer names, phones, and emails are NOT selected.
-- =============================================================================

-- A. All businesses + owner profile + counts
SELECT
  'A_business_inventory' AS audit_section,
  bs.business_id,
  bs.business_name,
  bs.business_slug,
  up.email AS owner_email,
  up.full_name AS owner_name,
  up.role AS owner_profile_role,
  up.created_at AS owner_profile_created_at,
  au.email AS auth_email,
  au.last_sign_in_at AS owner_last_sign_in_at,
  au.created_at AS auth_created_at,
  CASE
    WHEN lower(trim(coalesce(bs.business_slug, ''))) = 'angel-touch' THEN 'RETAIN_ANGEL_TOUCH'
    WHEN lower(trim(coalesce(bs.business_name, ''))) LIKE '%angel touch%' THEN 'RETAIN_ANGEL_TOUCH_NAME_MATCH'
    WHEN lower(trim(coalesce(bs.business_name, ''))) LIKE '%gorge 123%'
      OR lower(trim(coalesce(bs.business_slug, ''))) LIKE '%gorge-123%'
      OR lower(trim(coalesce(bs.business_slug, ''))) LIKE '%gorge123%'
      OR lower(trim(coalesce(bs.business_name, ''))) LIKE 'gorge 123%'
      THEN 'RETAIN_GORGE_123_CANDIDATE'
    ELSE 'DELETION_CANDIDATE'
  END AS retain_flag,
  (SELECT count(*) FROM public.business_customers bc WHERE bc.business_id = bs.business_id) AS crm_records,
  (SELECT count(*) FROM public.business_customers bc
     WHERE bc.business_id = bs.business_id AND bc.customer_user_id IS NOT NULL) AS linked_members,
  (SELECT count(*) FROM public.business_customers bc
     WHERE bc.business_id = bs.business_id AND bc.customer_user_id IS NULL) AS guest_crm,
  (SELECT count(*) FROM public.bookings b WHERE b.business_id = bs.business_id) AS bookings,
  (SELECT count(*) FROM public.services s WHERE s.business_id = bs.business_id) AS services,
  (SELECT count(*) FROM public.staff_members st WHERE st.business_id = bs.business_id) AS staff
FROM public.business_settings bs
LEFT JOIN public.user_profiles up ON up.id = bs.business_id
LEFT JOIN auth.users au ON au.id = bs.business_id
ORDER BY retain_flag, bs.business_name, bs.business_slug;

-- B. Foreign keys pointing at business_settings
SELECT
  'B_fks_to_business_settings' AS audit_section,
  tc.table_schema,
  tc.table_name,
  kcu.column_name,
  rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.table_schema = kcu.table_schema
JOIN information_schema.referential_constraints rc
  ON rc.constraint_name = tc.constraint_name
 AND rc.constraint_schema = tc.table_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
 AND ccu.constraint_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND ccu.table_schema = 'public'
  AND ccu.table_name = 'business_settings'
ORDER BY tc.table_name, kcu.column_name;

-- C. Public tables that have a business_id column (FK or not)
SELECT
  'C_tables_with_business_id' AS audit_section,
  c.table_name,
  c.column_name,
  c.data_type
FROM information_schema.columns c
WHERE c.table_schema = 'public'
  AND c.column_name IN ('business_id', 'originating_business_id')
ORDER BY c.table_name, c.column_name;

-- D. Cross-business linked customers (counts only — no PII)
-- D1. Linked auth customers present on more than one business
SELECT
  'D1_multi_business_linked_customers' AS audit_section,
  count(*) AS linked_auth_customers_on_multiple_businesses
FROM (
  SELECT bc.customer_user_id
  FROM public.business_customers bc
  WHERE bc.customer_user_id IS NOT NULL
  GROUP BY bc.customer_user_id
  HAVING count(DISTINCT bc.business_id) > 1
) x;

-- D2. Overlap between retained businesses and other businesses (counts)
WITH retained AS (
  SELECT business_id
  FROM public.business_settings
  WHERE lower(trim(coalesce(business_slug, ''))) = 'angel-touch'
     OR lower(trim(coalesce(business_name, ''))) LIKE '%angel touch%'
     OR lower(trim(coalesce(business_name, ''))) LIKE '%gorge 123%'
     OR lower(trim(coalesce(business_slug, ''))) LIKE '%gorge%123%'
),
legacy AS (
  SELECT business_id
  FROM public.business_settings
  WHERE business_id NOT IN (SELECT business_id FROM retained)
)
SELECT
  'D2_linked_overlap_retained_vs_legacy' AS audit_section,
  count(*) AS linked_customers_on_both_retained_and_legacy
FROM (
  SELECT bc.customer_user_id
  FROM public.business_customers bc
  WHERE bc.customer_user_id IS NOT NULL
  GROUP BY bc.customer_user_id
  HAVING bool_or(bc.business_id IN (SELECT business_id FROM retained))
     AND bool_or(bc.business_id IN (SELECT business_id FROM legacy))
) x;

-- D3. Overlap BETWEEN the two retained businesses
SELECT
  'D3_linked_overlap_between_retained' AS audit_section,
  count(*) AS linked_customers_on_both_retained_businesses
FROM (
  SELECT bc.customer_user_id
  FROM public.business_customers bc
  JOIN public.business_settings bs ON bs.business_id = bc.business_id
  WHERE bc.customer_user_id IS NOT NULL
    AND (
      lower(trim(coalesce(bs.business_slug, ''))) = 'angel-touch'
      OR lower(trim(coalesce(bs.business_name, ''))) LIKE '%angel touch%'
      OR lower(trim(coalesce(bs.business_name, ''))) LIKE '%gorge 123%'
      OR lower(trim(coalesce(bs.business_slug, ''))) LIKE '%gorge%123%'
    )
  GROUP BY bc.customer_user_id
  HAVING count(DISTINCT bc.business_id) > 1
) x;

-- E. Test-business owners who are also linked customers of a retained business
--    (do NOT delete these Auth users)
WITH retained AS (
  SELECT business_id
  FROM public.business_settings
  WHERE lower(trim(coalesce(business_slug, ''))) = 'angel-touch'
     OR lower(trim(coalesce(business_name, ''))) LIKE '%angel touch%'
     OR lower(trim(coalesce(business_name, ''))) LIKE '%gorge 123%'
     OR lower(trim(coalesce(business_slug, ''))) LIKE '%gorge%123%'
)
SELECT
  'E_legacy_owners_who_are_retained_customers' AS audit_section,
  count(*) AS legacy_owner_accounts_linked_as_customers_on_retained
FROM public.business_settings bs
WHERE bs.business_id NOT IN (SELECT business_id FROM retained)
  AND EXISTS (
    SELECT 1
    FROM public.business_customers bc
    WHERE bc.customer_user_id = bs.business_id
      AND bc.business_id IN (SELECT business_id FROM retained)
  );

-- F. Storage objects under owner UUID folders (counts only)
SELECT
  'F_storage_logo_objects' AS audit_section,
  x.owner_folder,
  count(*) AS object_count
FROM (
  SELECT (storage.foldername(name))[1] AS owner_folder
  FROM storage.objects
  WHERE bucket_id = 'business-logos'
) x
GROUP BY x.owner_folder
ORDER BY object_count DESC;

SELECT
  'F_storage_gallery_objects' AS audit_section,
  x.owner_folder,
  count(*) AS object_count
FROM (
  SELECT (storage.foldername(name))[1] AS owner_folder
  FROM storage.objects
  WHERE bucket_id = 'business-gallery'
) x
GROUP BY x.owner_folder
ORDER BY object_count DESC;

-- G. Name/slug search for Gorge 123 (no PII beyond business identity)
SELECT
  'G_gorge_123_search' AS audit_section,
  business_id,
  business_name,
  business_slug
FROM public.business_settings
WHERE lower(trim(coalesce(business_name, ''))) LIKE '%gorge%'
   OR lower(trim(coalesce(business_slug, ''))) LIKE '%gorge%'
ORDER BY business_name;
