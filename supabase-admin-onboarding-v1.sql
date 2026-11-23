-- =============================================================================
-- GT Termin — Super Admin: prepared businesses and owner activation
-- =============================================================================
-- Adds (no existing function, policy or trigger is changed):
--   1) public.business_onboarding — status of a business prepared by a platform
--      administrator: draft → invited → active (or back to draft on cancel).
--      Server-only (Control Center Edge Function); no client grants.
--   2) _admin_owner_email_status — is an e-mail already an account / draft?
--      _admin_owner_account — owner account facts for the Control Center.
--   3) complete_business_activation() — called by the owner (verified e-mail)
--      after setting a password on the activation page. Marks the business active and starts the standard 14-day
--      trial through the existing _try_grant_new_business_trial (owner session,
--      so the existing eligibility rules apply unchanged).
--
-- Ownership model is unchanged: a draft's business_id is a pre-generated UUID;
-- the owner's auth account is created with that same id when the invitation
-- is sent, so business_id = auth.uid() holds from the first login.
-- A draft has no subscription, so it cannot take bookings, and no trial is
-- consumed (uid-less inserts never start a trial).
--
-- Businesses created by owners themselves have no business_onboarding row and
-- behave exactly as before.
--
-- Safe to re-run. Rollback at the end (commented out).
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.business_onboarding (
  business_id        uuid PRIMARY KEY REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  status             text NOT NULL DEFAULT 'draft',
  owner_email        text NOT NULL,
  owner_name         text,
  owner_phone        text,
  preferred_language text NOT NULL DEFAULT 'mk',
  created_by         uuid,
  created_at         timestamptz NOT NULL DEFAULT now(),
  invited_at         timestamptz,
  invite_count       integer NOT NULL DEFAULT 0,
  last_invited_by    uuid,
  activated_at       timestamptz,
  updated_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_onboarding_status_ok CHECK (status IN ('draft', 'invited', 'active')),
  CONSTRAINT business_onboarding_language_ok CHECK (preferred_language IN ('mk', 'en', 'sq')),
  CONSTRAINT business_onboarding_email_ok CHECK (position('@' IN owner_email) > 1)
);

-- One open preparation per owner e-mail.
CREATE UNIQUE INDEX IF NOT EXISTS business_onboarding_open_email_uniq
  ON public.business_onboarding (lower(owner_email)) WHERE status IN ('draft', 'invited');

ALTER TABLE public.business_onboarding ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.business_onboarding FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.business_onboarding TO service_role;

COMMENT ON TABLE public.business_onboarding IS
  'Businesses prepared by a platform administrator: draft → invited → active. Server-only.';

-- E-mail conflicts for a new prepared business (service_role only).
CREATE OR REPLACE FUNCTION public._admin_owner_email_status(p_email text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'auth_user_id', (SELECT u.id FROM auth.users u WHERE lower(u.email) = lower(trim(p_email)) LIMIT 1),
    'auth_confirmed', (SELECT u.email_confirmed_at IS NOT NULL FROM auth.users u WHERE lower(u.email) = lower(trim(p_email)) LIMIT 1),
    'open_draft_business_id', (SELECT o.business_id FROM public.business_onboarding o
                               WHERE lower(o.owner_email) = lower(trim(p_email)) AND o.status IN ('draft', 'invited') LIMIT 1)
  );
$$;

-- Owner account facts for the Control Center (service_role only).
CREATE OR REPLACE FUNCTION public._admin_owner_account(p_user_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN u.id IS NULL THEN NULL ELSE jsonb_build_object(
    'exists', true,
    'email', u.email,
    'email_confirmed_at', u.email_confirmed_at,
    'invited_at', u.invited_at,
    'last_sign_in_at', u.last_sign_in_at
  ) END
  FROM (SELECT p_user_id AS id) x LEFT JOIN auth.users u ON u.id = x.id;
$$;

-- Called by the owner (signed in from the invitation) after setting a password.
CREATE OR REPLACE FUNCTION public.complete_business_activation()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_row   public.business_onboarding%ROWTYPE;
  v_trial jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM public.business_onboarding WHERE business_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'status', 'not_prepared');
  END IF;
  IF v_row.status = 'active' THEN
    RETURN jsonb_build_object('ok', true, 'status', 'active', 'already', true);
  END IF;
  IF v_row.status <> 'invited' THEN
    RAISE EXCEPTION 'This business is not ready for activation.' USING ERRCODE = 'P0001';
  END IF;
  -- The owner proved the e-mail by opening the single-use invitation link.
  -- (The activation page sets the owner's own password before calling this.)
  IF NOT EXISTS (
    SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Open the invitation link first.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.business_onboarding
  SET status = 'active', activated_at = now(), updated_at = now()
  WHERE business_id = v_uid;
  UPDATE public.business_settings
  SET onboarding_completed_at = coalesce(onboarding_completed_at, now())
  WHERE business_id = v_uid;

  -- Same path as a self-registered owner: owner session, existing eligibility rules.
  v_trial := public._try_grant_new_business_trial(v_uid);

  RETURN jsonb_build_object('ok', true, 'status', 'active', 'trial', v_trial);
END;
$$;

-- Superseded during rollout: GoTrue sets a temporary random password on invite
-- verification, so "has a password" cannot prove the owner chose one.
DROP FUNCTION IF EXISTS public._admin_clear_unused_owner_password(uuid);

REVOKE ALL ON FUNCTION public._admin_owner_email_status(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._admin_owner_account(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._admin_owner_email_status(text) TO service_role;
GRANT EXECUTE ON FUNCTION public._admin_owner_account(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.complete_business_activation() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.complete_business_activation() TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.complete_business_activation();
-- DROP FUNCTION IF EXISTS public._admin_owner_account(uuid);
-- DROP FUNCTION IF EXISTS public._admin_owner_email_status(text);
-- DROP TABLE IF EXISTS public.business_onboarding;
-- COMMIT;
