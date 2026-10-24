-- =============================================================================
-- XBOOK — IN-DATABASE ROW SNAPSHOT (OPTIONAL, UNEXECUTED)
-- =============================================================================
-- Copies candidate-tenant rows into schema xbook_legacy_cleanup_bak.
-- Does NOT delete. Still a WRITE: do not run until snapshot approval.
--
-- Purpose: same-project rollback of deleted rows without restoring the
-- entire database. Prefer an external pg_dump as the primary backup.
-- Run this, COMMIT, verify counts, THEN run the cleanup script.
-- =============================================================================

BEGIN;

DO $$
BEGIN
  IF false THEN
    NULL;
  ELSE
    RAISE EXCEPTION
      'Blocked: snapshot not approved. No schema or tables were created.';
  END IF;
END $$;

CREATE SCHEMA IF NOT EXISTS xbook_legacy_cleanup_bak;

DO $$
DECLARE
  v_candidates uuid[] := ARRAY[
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
  ];
BEGIN
  IF EXISTS (
    SELECT 1 FROM unnest(v_candidates) id
    WHERE id IN (
      'bd5bb7ea-36ef-4d48-bd3d-0d2d8d3500bb'::uuid,
      '4fb21268-7a4d-4c62-8c0a-30f7571eac41'::uuid
    )
  ) THEN
    RAISE EXCEPTION 'Blocked: candidate list includes a retained UUID.';
  END IF;
END $$;

CREATE TABLE xbook_legacy_cleanup_bak.business_settings AS
  SELECT * FROM public.business_settings
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

CREATE TABLE xbook_legacy_cleanup_bak.bookings AS
  SELECT * FROM public.bookings
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.services AS
  SELECT * FROM public.services
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.staff_members AS
  SELECT * FROM public.staff_members
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.staff AS
  SELECT * FROM public.staff
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.blocked_days AS
  SELECT * FROM public.blocked_days
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_closed_days AS
  SELECT * FROM public.business_closed_days
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_customers AS
  SELECT * FROM public.business_customers
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_customer_counters AS
  SELECT * FROM public.business_customer_counters
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_customer_identity_links AS
  SELECT * FROM public.business_customer_identity_links
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_customer_internal_notes AS
  SELECT * FROM public.business_customer_internal_notes
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_gallery_images AS
  SELECT * FROM public.business_gallery_images
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.notifications AS
  SELECT * FROM public.notifications
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.notification_recipients AS
  SELECT nr.*
  FROM public.notification_recipients nr
  JOIN xbook_legacy_cleanup_bak.notifications n ON n.id = nr.notification_id;

CREATE TABLE xbook_legacy_cleanup_bak.staff_time_off AS
  SELECT * FROM public.staff_time_off
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_push_events AS
  SELECT * FROM public.business_push_events
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.customer_app_login_codes AS
  SELECT * FROM public.customer_app_login_codes
  WHERE originating_business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

CREATE TABLE xbook_legacy_cleanup_bak.business_push_tokens AS
  SELECT * FROM public.business_push_tokens
  WHERE business_id IN (SELECT business_id FROM xbook_legacy_cleanup_bak.business_settings);

-- Restore order after a committed cleanup (run only if rollback is required):
--   1. INSERT INTO public.business_settings SELECT * FROM xbook_legacy_cleanup_bak.business_settings;
--   2. INSERT children (CRM, closed days, gallery, notifications, then recipients,
--      services, staff_members, blocked_days, bookings, etc.)
--   3. Re-upload Storage files from the Storage backup folder.
-- Do not INSERT Auth users; they were never deleted.

ROLLBACK;
