-- =============================================================================
-- XBOOK — LEGACY BUSINESS CLEANUP (TRANSACTIONAL)
-- =============================================================================
-- PROJECT: sdqothuulzeczcncyfqd
-- STATUS:  NOT APPROVED FOR EXECUTION
--
-- DO NOT RUN this file against production until BOTH of the following are true:
--   1. A separate written message explicitly authorizes DELETION (not just
--      confirmation of the candidate list).
--   2. Database + Storage backups have been taken and a restore test has passed.
--
-- This script:
--   • does NOT delete Auth users
--   • does NOT delete user_profiles
--   • does NOT delete customer_push_tokens / customer_notification_preferences
--     / customer_private_profiles
--   • does NOT delete platform_admins or platform_admin_audit_log
--   • does NOT delete the 5 bookings whose business_id IS NULL
--   • does NOT touch Storage objects (see scripts/xbook-legacy-cleanup-storage-*.sh)
--
-- Default ending is ROLLBACK. Flip the approval guard AND replace ROLLBACK
-- with COMMIT only after a successful dry-run and a second explicit approval.
-- =============================================================================

BEGIN;

-- Abort immediately unless written deletion approval has been encoded here.
DO $$
DECLARE
  v_i_have_written_deletion_approval boolean := false; -- KEEP FALSE
  v_retained_found integer;
  v_candidate_found integer;
  v_overlap integer;
  v_extra integer;
  v_live integer;
  v_angel_bookings integer;
  v_gorge_bookings integer;
  v_angel_crm integer;
  v_gorge_crm integer;
BEGIN
  IF v_i_have_written_deletion_approval IS NOT TRUE THEN
    RAISE EXCEPTION
      'Blocked: no written deletion approval. Transaction aborted. No rows changed.';
  END IF;

  SELECT count(*) INTO v_live FROM public.business_settings;
  IF v_live <> 19 THEN
    RAISE EXCEPTION
      'Blocked: expected 19 business_settings rows, found %. Refusing to continue.',
      v_live;
  END IF;

  SELECT count(*) INTO v_retained_found
  FROM public.business_settings
  WHERE business_id IN (
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  );
  IF v_retained_found <> 2 THEN
    RAISE EXCEPTION
      'Blocked: retained businesses missing (found %).', v_retained_found;
  END IF;

  SELECT count(*) INTO v_candidate_found
  FROM public.business_settings
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
  IF v_candidate_found <> 17 THEN
    RAISE EXCEPTION
      'Blocked: expected 17 candidate businesses, found %.', v_candidate_found;
  END IF;

  SELECT count(*) INTO v_overlap
  FROM public.business_settings
  WHERE business_id IN (
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  )
    AND business_id IN (
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
  IF v_overlap <> 0 THEN
    RAISE EXCEPTION 'Blocked: retained UUID appeared on the candidate list.';
  END IF;

  SELECT count(*) INTO v_extra
  FROM public.business_settings
  WHERE business_id NOT IN (
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid,
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
  IF v_extra <> 0 THEN
    RAISE EXCEPTION
      'Blocked: % unexpected business_settings rows are neither retained nor candidates.',
      v_extra;
  END IF;

  SELECT count(*) INTO v_angel_bookings FROM public.bookings
    WHERE business_id = 'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid;
  SELECT count(*) INTO v_gorge_bookings FROM public.bookings
    WHERE business_id = '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid;
  SELECT count(*) INTO v_angel_crm FROM public.business_customers
    WHERE business_id = 'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid;
  SELECT count(*) INTO v_gorge_crm FROM public.business_customers
    WHERE business_id = '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid;

  IF v_angel_bookings <> 60 OR v_gorge_bookings <> 169 THEN
    RAISE EXCEPTION
      'Blocked: retained booking counts drifted (Angel %, Gorge %). Re-run preflight.',
      v_angel_bookings, v_gorge_bookings;
  END IF;
  IF v_angel_crm <> 3 OR v_gorge_crm <> 9 THEN
    RAISE EXCEPTION
      'Blocked: retained CRM counts drifted (Angel %, Gorge %). Re-run preflight.',
      v_angel_crm, v_gorge_crm;
  END IF;
END $$;

-- Candidate allowlist (17). Used by every DELETE below.
-- Never include the two retained UUIDs.

-- 1) Bookings first. staff_members_guard_delete refuses staff rows that still
--    have booking history, and bookings have no FK to business_settings.
DELETE FROM public.bookings
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

-- 2) Non-FK calendar + catalog rows (no CASCADE from business_settings).
DELETE FROM public.blocked_days
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

DELETE FROM public.services
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

DELETE FROM public.staff
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

-- 3) staff_members_guard_delete blocks deleting the last staff row per
--    business even after bookings are gone. Disable only this trigger,
--    only inside this transaction, then re-enable before COMMIT/ROLLBACK.
--    ROLLBACK restores the trigger even if ENABLE is skipped.
ALTER TABLE public.staff_members DISABLE TRIGGER staff_members_guard_delete;

DELETE FROM public.staff_members
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

ALTER TABLE public.staff_members ENABLE TRIGGER staff_members_guard_delete;

-- 4) Owner device tokens FK to auth.users, not business_settings. 0 candidate
--    rows today; keep the statement so a later re-run is complete. Do not
--    delete tokens for the two retained owners.
DELETE FROM public.business_push_tokens
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

-- 5) Tenant root. CASCADE removes CRM, counters, identity links, internal
--    notes, gallery rows, closed days, notifications (+ recipients), login
--    codes, staff_time_off, and business_push_events for these 17 UUIDs only.
DELETE FROM public.business_settings
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
)
  AND business_id NOT IN (
    'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
    '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
  );

-- Post-delete assertions. Any mismatch aborts the transaction.
DO $$
DECLARE
  v_left integer;
  v_angel integer;
  v_gorge integer;
  v_bookings integer;
  v_null_bookings integer;
  v_services integer;
  v_staff integer;
  v_crm integer;
BEGIN
  SELECT count(*) INTO v_left FROM public.business_settings;
  IF v_left <> 2 THEN
    RAISE EXCEPTION 'Post-check failed: business_settings count is %, expected 2.', v_left;
  END IF;

  SELECT count(*) INTO v_angel FROM public.business_settings
    WHERE business_id = 'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid
      AND business_slug = 'angel-touch';
  SELECT count(*) INTO v_gorge FROM public.business_settings
    WHERE business_id = '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
      AND business_slug = 'gorge123';
  IF v_angel <> 1 OR v_gorge <> 1 THEN
    RAISE EXCEPTION 'Post-check failed: retained businesses missing after delete.';
  END IF;

  SELECT count(*) INTO v_bookings FROM public.bookings
    WHERE business_id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    );
  IF v_bookings <> 229 THEN
    RAISE EXCEPTION 'Post-check failed: retained bookings are %, expected 229.', v_bookings;
  END IF;

  SELECT count(*) INTO v_null_bookings FROM public.bookings WHERE business_id IS NULL;
  IF v_null_bookings <> 5 THEN
    RAISE EXCEPTION 'Post-check failed: NULL business_id bookings are %, expected 5.', v_null_bookings;
  END IF;

  SELECT count(*) INTO v_services FROM public.services
    WHERE business_id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    );
  IF v_services <> 17 THEN
    RAISE EXCEPTION 'Post-check failed: retained services are %, expected 17.', v_services;
  END IF;

  SELECT count(*) INTO v_staff FROM public.staff_members
    WHERE business_id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    );
  IF v_staff <> 3 THEN
    RAISE EXCEPTION 'Post-check failed: retained staff_members are %, expected 3.', v_staff;
  END IF;

  SELECT count(*) INTO v_crm FROM public.business_customers
    WHERE business_id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    );
  IF v_crm <> 12 THEN
    RAISE EXCEPTION 'Post-check failed: retained CRM rows are %, expected 12.', v_crm;
  END IF;

  IF (
    SELECT count(*) FROM auth.users
    WHERE id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    )
  ) <> 2 THEN
    RAISE EXCEPTION 'Post-check failed: retained Auth owners missing.';
  END IF;
END $$;

-- Default: roll back the entire cleanup, including the trigger disable.
-- Replace with COMMIT only after written deletion approval AND a successful
-- dry-run of this file that stopped at this ROLLBACK.
ROLLBACK;
