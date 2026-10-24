-- =============================================================================
-- XBOOK — POST-CLEANUP VERIFICATION (READ-ONLY)
-- =============================================================================
-- Run AFTER an approved cleanup. SELECT only.
-- Expected: exactly 2 business_settings rows (Angel Touch + Test Barber).
-- Customer names, phones, and emails are not selected.
-- =============================================================================

SELECT
  'business_settings_remaining' AS check_name,
  count(*) AS n,
  2 AS expected
FROM public.business_settings;

SELECT
  business_id,
  business_name,
  business_slug
FROM public.business_settings
ORDER BY business_slug;

SELECT 'retained_bookings' AS check_name, count(*) AS n, 229 AS expected
FROM public.bookings
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'null_business_id_bookings_untouched' AS check_name, count(*) AS n, 5 AS expected
FROM public.bookings
WHERE business_id IS NULL;

SELECT 'candidate_bookings_gone' AS check_name, count(*) AS n, 0 AS expected
FROM public.bookings
WHERE business_id IN (
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
);

SELECT 'retained_services' AS check_name, count(*) AS n, 17 AS expected
FROM public.services
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_staff_members' AS check_name, count(*) AS n, 3 AS expected
FROM public.staff_members
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_crm' AS check_name, count(*) AS n, 12 AS expected
FROM public.business_customers
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_linked_members' AS check_name, count(*) AS n, 8 AS expected
FROM public.business_customers
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
)
  AND customer_user_id IS NOT NULL;

SELECT 'retained_identity_links' AS check_name, count(*) AS n, 1 AS expected
FROM public.business_customer_identity_links
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_gallery_rows' AS check_name, count(*) AS n, 16 AS expected
FROM public.business_gallery_images
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_notifications' AS check_name, count(*) AS n, 2 AS expected
FROM public.notifications
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_push_events' AS check_name, count(*) AS n, 34 AS expected
FROM public.business_push_events
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_push_tokens' AS check_name, count(*) AS n, 4 AS expected
FROM public.business_push_tokens
WHERE business_id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'retained_auth_owners' AS check_name, count(*) AS n, 2 AS expected
FROM auth.users
WHERE id IN (
  'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
  '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
);

SELECT 'legacy_owner_auth_still_present_expected' AS check_name, count(*) AS n, 3 AS expected
FROM auth.users
WHERE id IN (
  '4cd64220-f123-4eb6-a10b-dd6b66e6a685'::uuid,
  'b9e87758-1ad0-477f-8fe7-5fcab88314f7'::uuid,
  '6bdbbdc7-ade8-4c60-8e3b-1bbc2b1f5494'::uuid
);

SELECT 'staff_members_guard_delete_enabled' AS check_name,
  tgenabled AS state
FROM pg_trigger
WHERE tgname = 'staff_members_guard_delete';

-- Storage folders that must remain
SELECT
  'retained_storage_objects' AS check_name,
  bucket_id,
  count(*) AS n
FROM storage.objects
WHERE bucket_id IN ('business-logos', 'business-gallery')
  AND (storage.foldername(name))[1] IN (
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb',
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'
  )
GROUP BY bucket_id
ORDER BY bucket_id;
