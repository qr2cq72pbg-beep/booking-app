-- =============================================================================
-- GT Termin — team members may create appointments for themselves (opt-in)
-- =============================================================================
-- 1) staff_members.can_create_bookings (default false): switched on per team
--    member by the owner (app, RLS) or the platform admin (Control Center).
-- 2) staff_create_booking(): the ONLY write path for a team member. It checks
--    the team member session (_staff_access_member), the permission and the
--    business, fixes staff_id = this team member and status = Confirmed, then
--    runs the standard create_booking path (all booking rules, subscription,
--    staff hours/services, conflicts, time off) as a trusted server call.
--    Editing, moving and cancelling stay owner-only.
-- 3) get_staff_agenda() also returns staff.can_create_bookings (additive).
-- Existing owner, customer and public paths are unchanged.
-- Safe to re-run. Rollback at the end (commented out).
-- =============================================================================

BEGIN;

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS can_create_bookings boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.staff_members.can_create_bookings IS
  'Team member may create appointments for themselves in the app (staff_create_booking). Off by default.';

CREATE OR REPLACE FUNCTION public.get_staff_agenda(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $fn$
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
    'staff', jsonb_build_object('id', v_member.id, 'name', v_member.name, 'role', v_member.role, 'photo_url', v_member.photo_url,
                                'can_create_bookings', coalesce(v_member.can_create_bookings, false)),
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
$fn$;

CREATE OR REPLACE FUNCTION public.staff_create_booking(
  p_service_id     uuid,
  p_date           date,
  p_time           time,
  p_customer_name  text,
  p_customer_phone text DEFAULT NULL,
  p_customer_email text DEFAULT NULL,
  p_notes          text DEFAULT NULL
)
RETURNS public.bookings
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_member public.staff_members;
  v_name   text := btrim(coalesce(p_customer_name, ''));
  v_phone  text := nullif(btrim(coalesce(p_customer_phone, '')), '');
  v_email  text := nullif(btrim(coalesce(p_customer_email, '')), '');
  v_notes  text := nullif(btrim(coalesce(p_notes, '')), '');
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub    text := current_setting('request.jwt.claim.sub', true);
  v_role   text := current_setting('request.jwt.claim.role', true);
  v_row    public.bookings;
BEGIN
  v_member := public._staff_access_member();
  IF v_member.id IS NULL THEN
    RAISE EXCEPTION 'Team member access is not active.' USING ERRCODE = '42501';
  END IF;
  IF NOT coalesce(v_member.can_create_bookings, false) THEN
    RAISE EXCEPTION 'Creating appointments is not enabled for this team member.' USING ERRCODE = '42501';
  END IF;
  IF v_name = '' OR length(v_name) > 120 THEN
    RAISE EXCEPTION 'Enter the client''s name.' USING ERRCODE = 'P0001';
  END IF;
  IF (v_phone IS NOT NULL AND length(v_phone) > 40) OR (v_email IS NOT NULL AND length(v_email) > 120)
     OR (v_notes IS NOT NULL AND length(v_notes) > 1000) THEN
    RAISE EXCEPTION 'Some details are too long.' USING ERRCODE = 'P0001';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.services s WHERE s.id = p_service_id AND s.business_id = v_member.business_id) THEN
    RAISE EXCEPTION 'Service not found.' USING ERRCODE = 'P0001';
  END IF;

  -- Standard booking path as a trusted server call (same as an owner-created booking),
  -- with business, team member and status fixed above. Claims are restored afterwards.
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);
  PERFORM set_config('request.jwt.claim.role', 'service_role', true);
  BEGIN
    PERFORM public.ensure_business_customer(v_member.business_id, coalesce(v_phone, ''), coalesce(v_email, ''), v_name);
    v_row := public.create_booking(
      v_member.business_id, p_service_id, p_date, p_time, v_name, coalesce(v_phone, '—'),
      v_email, v_notes, v_member.id, NULL, 'Confirmed');
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    PERFORM set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
    PERFORM set_config('request.jwt.claim.role', coalesce(v_role, ''), true);
    RAISE;
  END;
  PERFORM set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  PERFORM set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  PERFORM set_config('request.jwt.claim.role', coalesce(v_role, ''), true);

  -- No push to the team member about the appointment they just created themselves.
  DELETE FROM public.staff_push_events e
  WHERE e.booking_id = v_row.id AND e.staff_id = v_member.id AND e.event_type = 'new';

  RETURN v_row;
END;
$fn$;

COMMENT ON FUNCTION public.staff_create_booking(uuid, date, time, text, text, text, text) IS
  'Team member creates a confirmed appointment for themselves (requires staff_members.can_create_bookings).';

REVOKE ALL ON FUNCTION public.staff_create_booking(uuid, date, time, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_create_booking(uuid, date, time, text, text, text, text) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- DROP FUNCTION IF EXISTS public.staff_create_booking(uuid, date, time, text, text, text, text);
-- (re-apply get_staff_agenda from supabase-staff-access-v1.sql)
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS can_create_bookings;
-- COMMIT;
