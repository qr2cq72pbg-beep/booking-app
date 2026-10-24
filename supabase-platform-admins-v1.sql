-- =============================================================================
-- XBOOK Admin Control Center — Phase 2
-- platform_admins allowlist + audit log
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT run this from the XBOOK iOS / Android / web apps.
-- Do NOT apply until you explicitly approve a database change.
-- Safe to re-run (IF NOT EXISTS / DROP POLICY IF EXISTS).
--
-- This file does NOT:
--   • change bookings, RLS on tenant tables, or business/customer RPCs
--   • create business_settings rows
--   • add subscription / trial enforcement
--   • grant platform access to user_profiles.role = 'admin' (business owners)
--
-- Authorization model:
--   Only rows in public.platform_admins with is_active = true are super-admins.
--   Business owners are NOT platform administrators.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Allowlist
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id     uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  email       text,
  is_active   boolean NOT NULL DEFAULT false,
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.platform_admins IS
  'XBOOK Control Center allowlist. Independent of user_profiles.role. '
  'Only Edge Functions using service_role may read or write this table.';

CREATE INDEX IF NOT EXISTS platform_admins_active_idx
  ON public.platform_admins (user_id)
  WHERE is_active = true;

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.platform_admins FROM PUBLIC;
REVOKE ALL ON TABLE public.platform_admins FROM anon;
REVOKE ALL ON TABLE public.platform_admins FROM authenticated;
GRANT ALL ON TABLE public.platform_admins TO service_role;

-- -----------------------------------------------------------------------------
-- 2) Audit log (privileged Control Center actions)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.platform_admin_audit_log (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  action       text NOT NULL,
  business_id  uuid,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT platform_admin_audit_log_action_nonempty
    CHECK (length(trim(action)) > 0)
);

COMMENT ON TABLE public.platform_admin_audit_log IS
  'Control Center audit trail. No JWTs, manage tokens, or secrets. '
  'Client roles have no grants.';

CREATE INDEX IF NOT EXISTS platform_admin_audit_log_actor_idx
  ON public.platform_admin_audit_log (actor_user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS platform_admin_audit_log_created_idx
  ON public.platform_admin_audit_log (created_at DESC);

ALTER TABLE public.platform_admin_audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.platform_admin_audit_log FROM PUBLIC;
REVOKE ALL ON TABLE public.platform_admin_audit_log FROM anon;
REVOKE ALL ON TABLE public.platform_admin_audit_log FROM authenticated;
GRANT ALL ON TABLE public.platform_admin_audit_log TO service_role;

COMMIT;

-- =============================================================================
-- FIRST SUPER-ADMIN (run separately after this file, in the SQL Editor)
-- =============================================================================
-- 1. In Supabase Dashboard → Authentication → Users → Add user
--    • Create with email + password
--    • Auto-confirm the email
--    • Do NOT set user_metadata.role to admin or customer
--    • Do NOT sign up through the XBOOK owner or customer app
--    • Do NOT insert a business_settings row for this user
--
-- 2. Look up the Auth UUID (replace the email placeholder only in the editor,
--    never commit a real address):
--
--    SELECT id, email, created_at
--    FROM auth.users
--    WHERE lower(email) = lower('YOUR_ADMIN_EMAIL_HERE');
--
-- 3. Allowlist that user:
--
--    INSERT INTO public.platform_admins (user_id, email, is_active, notes)
--    VALUES (
--      'PASTE_AUTH_USER_UUID_HERE',
--      'YOUR_ADMIN_EMAIL_HERE',
--      true,
--      'Initial platform administrator'
--    )
--    ON CONFLICT (user_id) DO UPDATE
--    SET email = EXCLUDED.email,
--        is_active = true,
--        updated_at = now();
--
-- 4. Confirm (must return one row, is_active = true):
--
--    SELECT user_id, email, is_active, created_at
--    FROM public.platform_admins
--    WHERE is_active = true;
--
-- Deactivate later without deleting the Auth user:
--    UPDATE public.platform_admins SET is_active = false, updated_at = now()
--    WHERE user_id = 'PASTE_AUTH_USER_UUID_HERE';
-- =============================================================================
