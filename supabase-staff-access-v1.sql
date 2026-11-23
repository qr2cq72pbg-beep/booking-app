-- =============================================================================
-- GT Termin — Basic employee access (Phase F3)
-- =============================================================================
-- Read-only appointment agenda for team members, paired with a one-time code.
--
-- Adds (no existing function, policy or trigger is changed):
--   1) staff_members.access_user_id / access_enabled / access_scope
--      (all optional; existing staff rows keep working without any account)
--   2) staff_members_guard_access_link — only the server (service_role) can
--      link an auth account to a staff row
--   3) public.staff_access_codes — HMAC-only one-time pairing codes
--      (server access only, same model as customer_app_login_codes)
--   4) _staff_access_member / _staff_can_see_booking — the single access and
--      visibility rule (reused by push notifications in F4)
--   5) get_staff_agenda — the ONLY data an employee can read: minimal fields,
--      own or all appointments according to the owner's setting
--   6) Owner RPCs: set_staff_access_scope, revoke_staff_access
--   7) service_role helpers used by the staff-access Edge Function
--
-- Security model:
--   • The employee is a normal Supabase Auth user (app_metadata.gt_account =
--     'staff'), created by the Edge Function. No user_profiles row, so every
--     existing owner/customer RLS policy and RPC keeps denying it.
--   • Access is checked on every call: access_enabled, active staff member and
--     matching access_user_id. Revoking or deactivating stops access at once.
--   • No prices, phone numbers, e-mails, manage tokens or customer ids are
--     returned to employees.
--
-- Safe to re-run. Rollback at the end (commented out).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Staff access columns
-- -----------------------------------------------------------------------------
ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS access_user_id uuid REFERENCES auth.users (id) ON DELETE SET NULL;
ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS access_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS access_scope text NOT NULL DEFAULT 'own';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'staff_members_access_scope_ok' AND conrelid = 'public.staff_members'::regclass
  ) THEN
    ALTER TABLE public.staff_members
      ADD CONSTRAINT staff_members_access_scope_ok CHECK (access_scope IN ('own', 'all'));
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS staff_members_access_user_uniq
  ON public.staff_members (access_user_id) WHERE access_user_id IS NOT NULL;

COMMENT ON COLUMN public.staff_members.access_user_id IS
  'Auth account of the team member (created by the staff-access Edge Function). NULL = no app access.';
COMMENT ON COLUMN public.staff_members.access_enabled IS
  'Owner switch for app access. false = no access, even with a linked account.';
COMMENT ON COLUMN public.staff_members.access_scope IS
  'own = only appointments assigned to this member (default); all = every appointment of the business.';

-- -----------------------------------------------------------------------------
-- 2) Only the server may link an auth account (owners may only clear it)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_members_guard_access_link()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.access_user_id IS NOT NULL
     AND (TG_OP = 'INSERT' OR NEW.access_user_id IS DISTINCT FROM OLD.access_user_id)
     AND current_user NOT IN ('service_role', 'postgres', 'supabase_admin')
  THEN
    RAISE EXCEPTION 'Team member access can only be linked by GT Termin.' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS staff_members_guard_access_link ON public.staff_members;
CREATE TRIGGER staff_members_guard_access_link
  BEFORE INSERT OR UPDATE ON public.staff_members
  FOR EACH ROW EXECUTE FUNCTION public._staff_members_guard_access_link();

-- -----------------------------------------------------------------------------
-- 3) One-time pairing codes (server only)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_access_codes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid NOT NULL,
  staff_id        uuid NOT NULL REFERENCES public.staff_members (id) ON DELETE CASCADE,
  code_hmac       text NOT NULL,
  expires_at      timestamptz NOT NULL,
  consumed_at     timestamptz,
  revoked_at      timestamptz,
  failed_attempts integer NOT NULL DEFAULT 0,
  created_by      uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_access_codes_hmac_uniq UNIQUE (code_hmac)
);

CREATE INDEX IF NOT EXISTS staff_access_codes_staff_idx ON public.staff_access_codes (staff_id);

ALTER TABLE public.staff_access_codes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.staff_access_codes FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.staff_access_codes TO service_role;

COMMENT ON TABLE public.staff_access_codes IS
  'HMAC-only one-time pairing codes for employee app access. No client access; used by the staff-access Edge Function.';

-- -----------------------------------------------------------------------------
-- 4) Access + visibility rule (single place; reused by F4 push recipients)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_access_member()
RETURNS public.staff_members
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT sm.*
  FROM public.staff_members sm
  JOIN public.business_settings bs ON bs.business_id = sm.business_id
  WHERE auth.uid() IS NOT NULL
    AND sm.access_user_id = auth.uid()
    AND sm.access_enabled = true
    AND coalesce(sm.active, true) = true
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public._staff_can_see_booking(
  p_staff          public.staff_members,
  p_booking_staff  uuid
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_staff.id IS NULL THEN false
    WHEN p_staff.access_scope = 'all' THEN true
    ELSE p_booking_staff IS NOT DISTINCT FROM p_staff.id
  END;
$$;

COMMENT ON FUNCTION public._staff_can_see_booking(public.staff_members, uuid) IS
  'Employee visibility: own scope = bookings assigned to the member; all = every booking of the business.';

-- -----------------------------------------------------------------------------
-- 5) Employee agenda (read-only, minimal fields)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_staff_agenda(
  p_from date DEFAULT NULL,
  p_to   date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_member public.staff_members;
  v_biz    public.business_settings%ROWTYPE;
  v_from   date;
  v_to     date;
  v_items  jsonb;
BEGIN
  v_member := public._staff_access_member();
  IF v_member.id IS NULL THEN
    RAISE EXCEPTION 'Team member access is not active.' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_biz FROM public.business_settings WHERE business_id = v_member.business_id;

  v_from := coalesce(p_from, (now() AT TIME ZONE coalesce(nullif(v_biz.timezone, ''), 'Europe/Skopje'))::date);
  v_to   := coalesce(p_to, v_from + 30);
  IF v_to < v_from THEN
    RAISE EXCEPTION 'Invalid date range.' USING ERRCODE = 'P0001';
  END IF;
  IF v_to - v_from > 62 THEN
    v_to := v_from + 62;
  END IF;

  SELECT coalesce(jsonb_agg(item ORDER BY item ->> 'date', item ->> 'time'), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT jsonb_build_object(
      'id', b.id,
      'date', left(trim(b.date::text), 10),
      'time', left(trim(b.time::text), 5),
      'duration_minutes', coalesce(nullif(b.duration_minutes, 0), nullif(s.duration, 0), 30),
      'customer_name', coalesce(nullif(trim(b.customer_name), ''), nullif(trim(b.name), ''), ''),
      'service_name', coalesce(nullif(trim(b.service_name), ''), nullif(trim(b.service), ''), s.name, ''),
      'staff_id', b.staff_id,
      'staff_name', coalesce(sm.name, nullif(trim(b.staff_name), ''), ''),
      'status', coalesce(nullif(trim(b.booking_status::text), ''), nullif(trim(b.status::text), ''), 'Pending'),
      'notes', nullif(trim(b.notes), ''),
      'is_mine', b.staff_id IS NOT DISTINCT FROM v_member.id
    ) AS item
    FROM public.bookings b
    LEFT JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
    LEFT JOIN public.staff_members sm ON sm.id = b.staff_id AND sm.business_id = b.business_id
    WHERE b.business_id = v_member.business_id
      AND trim(b.date::text) ~ '^\d{4}-\d{2}-\d{2}'
      AND left(trim(b.date::text), 10)::date BETWEEN v_from AND v_to
      AND public._staff_can_see_booking(v_member, b.staff_id)
  ) x;

  RETURN jsonb_build_object(
    'ok', true,
    'scope', v_member.access_scope,
    'staff', jsonb_build_object('id', v_member.id, 'name', v_member.name, 'role', v_member.role, 'photo_url', v_member.photo_url),
    'business', jsonb_build_object(
      'name', v_biz.business_name,
      'logo_url', v_biz.business_logo_url,
      'timezone', coalesce(nullif(v_biz.timezone, ''), 'Europe/Skopje')
    ),
    'from', v_from,
    'to', v_to,
    'bookings', v_items
  );
END;
$$;

COMMENT ON FUNCTION public.get_staff_agenda(date, date) IS
  'Employee agenda: time, duration, customer name, service, staff, status, notes. No prices, contacts or tokens.';

-- -----------------------------------------------------------------------------
-- 6) Owner management (core with explicit business id + owner wrapper)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_access_require_owner()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM public.business_settings bs WHERE bs.business_id = v_uid) THEN
    RAISE EXCEPTION 'Only the business owner can change this.' USING ERRCODE = '42501';
  END IF;
  RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION public._set_staff_access_scope_core(p_business_id uuid, p_staff_id uuid, p_scope text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_scope text := lower(trim(coalesce(p_scope, '')));
BEGIN
  IF v_scope NOT IN ('own', 'all') THEN
    RAISE EXCEPTION 'Invalid access setting.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.staff_members SET access_scope = v_scope
  WHERE id = p_staff_id AND business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  RETURN jsonb_build_object('ok', true, 'scope', v_scope);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_staff_access_scope(p_staff_id uuid, p_scope text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public._set_staff_access_scope_core(public._staff_access_require_owner(), p_staff_id, p_scope);
END;
$$;

-- Turns access off, unlinks the account and voids pending codes. Returns the
-- previous auth user id so the Edge Function can delete that account (which
-- ends every session on every device). Data access stops immediately even
-- before the account is deleted.
CREATE OR REPLACE FUNCTION public._revoke_staff_access_core(p_business_id uuid, p_staff_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old uuid;
BEGIN
  SELECT access_user_id INTO v_old
  FROM public.staff_members
  WHERE id = p_staff_id AND business_id = p_business_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  UPDATE public.staff_members SET access_enabled = false, access_user_id = NULL WHERE id = p_staff_id;
  UPDATE public.staff_access_codes SET revoked_at = now()
  WHERE staff_id = p_staff_id AND consumed_at IS NULL AND revoked_at IS NULL;
  RETURN jsonb_build_object('ok', true, 'previous_user_id', v_old);
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_staff_access(p_staff_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public._revoke_staff_access_core(public._staff_access_require_owner(), p_staff_id);
  -- The owner client never needs the auth id.
  RETURN v_result - 'previous_user_id';
END;
$$;

-- -----------------------------------------------------------------------------
-- 7) Server helpers for the staff-access Edge Function (service_role only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._issue_staff_access_code_core(
  p_business_id uuid,
  p_staff_id    uuid,
  p_code_hmac   text,
  p_expires_at  timestamptz,
  p_actor       uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm
    WHERE sm.id = p_staff_id AND sm.business_id = p_business_id AND coalesce(sm.active, true) = true
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  IF p_code_hmac IS NULL OR length(p_code_hmac) < 32 OR p_expires_at IS NULL OR p_expires_at <= now() THEN
    RAISE EXCEPTION 'Invalid code.' USING ERRCODE = 'P0001';
  END IF;
  -- Only the newest code works.
  UPDATE public.staff_access_codes SET revoked_at = now()
  WHERE staff_id = p_staff_id AND consumed_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.staff_access_codes (business_id, staff_id, code_hmac, expires_at, created_by)
  VALUES (p_business_id, p_staff_id, p_code_hmac, p_expires_at, p_actor);
  UPDATE public.staff_members SET access_enabled = true WHERE id = p_staff_id;
  RETURN jsonb_build_object('ok', true, 'expires_at', p_expires_at);
END;
$$;

-- Step 1 of redeem: validate the code (counts failures), return who it is for.
CREATE OR REPLACE FUNCTION public._staff_access_redeem_begin(p_code_hmac text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code  public.staff_access_codes%ROWTYPE;
  v_staff public.staff_members%ROWTYPE;
BEGIN
  SELECT * INTO v_code FROM public.staff_access_codes WHERE code_hmac = p_code_hmac FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  IF v_code.consumed_at IS NOT NULL OR v_code.revoked_at IS NOT NULL
     OR v_code.expires_at <= now() OR v_code.failed_attempts >= 5
  THEN
    UPDATE public.staff_access_codes
    SET failed_attempts = failed_attempts + 1,
        revoked_at = coalesce(revoked_at, CASE WHEN consumed_at IS NULL THEN now() END)
    WHERE id = v_code.id;
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO v_staff FROM public.staff_members
  WHERE id = v_code.staff_id AND business_id = v_code.business_id;
  IF NOT FOUND OR coalesce(v_staff.active, true) = false OR v_staff.access_enabled = false THEN
    UPDATE public.staff_access_codes SET revoked_at = now() WHERE id = v_code.id;
    RETURN jsonb_build_object('ok', false);
  END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'code_id', v_code.id,
    'staff_id', v_staff.id,
    'business_id', v_staff.business_id,
    'access_user_id', v_staff.access_user_id
  );
END;
$$;

-- Step 2: link the (new) auth account. Returns the account to sign in; if
-- another device linked first, that existing account wins.
CREATE OR REPLACE FUNCTION public._staff_access_link_user(p_staff_id uuid, p_user_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current uuid;
BEGIN
  SELECT access_user_id INTO v_current FROM public.staff_members WHERE id = p_staff_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  IF v_current IS NULL THEN
    UPDATE public.staff_members SET access_user_id = p_user_id WHERE id = p_staff_id;
    v_current := p_user_id;
  END IF;
  RETURN jsonb_build_object('ok', true, 'access_user_id', v_current, 'linked_new', v_current = p_user_id);
END;
$$;

-- Step 3: consume the code exactly once.
CREATE OR REPLACE FUNCTION public._staff_access_redeem_finish(p_code_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.staff_access_codes
  SET consumed_at = now()
  WHERE id = p_code_id AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at > now();
  RETURN FOUND;
END;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._staff_members_guard_access_link() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_access_member() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_can_see_booking(public.staff_members, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_access_require_owner() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_staff_access_scope_core(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._revoke_staff_access_core(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._issue_staff_access_code_core(uuid, uuid, text, timestamptz, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_access_redeem_begin(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_access_link_user(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_access_redeem_finish(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._staff_access_member() TO service_role;
GRANT EXECUTE ON FUNCTION public._staff_can_see_booking(public.staff_members, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._set_staff_access_scope_core(uuid, uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public._revoke_staff_access_core(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._issue_staff_access_code_core(uuid, uuid, text, timestamptz, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._staff_access_redeem_begin(text) TO service_role;
GRANT EXECUTE ON FUNCTION public._staff_access_link_user(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._staff_access_redeem_finish(uuid) TO service_role;

REVOKE ALL ON FUNCTION public.get_staff_agenda(date, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_staff_access_scope(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revoke_staff_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_staff_agenda(date, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_staff_access_scope(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_staff_access(uuid) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply). Employee auth accounts created by the
-- Edge Function stay in auth.users and must be deleted separately.
-- =============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.revoke_staff_access(uuid);
-- DROP FUNCTION IF EXISTS public.set_staff_access_scope(uuid, text);
-- DROP FUNCTION IF EXISTS public.get_staff_agenda(date, date);
-- DROP FUNCTION IF EXISTS public._staff_access_redeem_finish(uuid);
-- DROP FUNCTION IF EXISTS public._staff_access_link_user(uuid, uuid);
-- DROP FUNCTION IF EXISTS public._staff_access_redeem_begin(text);
-- DROP FUNCTION IF EXISTS public._issue_staff_access_code_core(uuid, uuid, text, timestamptz, uuid);
-- DROP FUNCTION IF EXISTS public._revoke_staff_access_core(uuid, uuid);
-- DROP FUNCTION IF EXISTS public._set_staff_access_scope_core(uuid, uuid, text);
-- DROP FUNCTION IF EXISTS public._staff_access_require_owner();
-- DROP FUNCTION IF EXISTS public._staff_can_see_booking(public.staff_members, uuid);
-- DROP FUNCTION IF EXISTS public._staff_access_member();
-- DROP TABLE IF EXISTS public.staff_access_codes;
-- DROP TRIGGER IF EXISTS staff_members_guard_access_link ON public.staff_members;
-- DROP FUNCTION IF EXISTS public._staff_members_guard_access_link();
-- DROP INDEX IF EXISTS public.staff_members_access_user_uniq;
-- ALTER TABLE public.staff_members DROP CONSTRAINT IF EXISTS staff_members_access_scope_ok;
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS access_scope;
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS access_enabled;
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS access_user_id;
-- COMMIT;
