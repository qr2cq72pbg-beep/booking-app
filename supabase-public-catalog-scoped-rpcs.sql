-- =============================================================================
-- XBOOK — Scoped public catalog RPCs (services / staff / closed dates)
-- =============================================================================
-- Run once in Supabase Dashboard → SQL Editor AFTER reviewing this file.
-- DO NOT run from the app. DO NOT apply as part of an automated deploy.
--
-- Replaces dump-all SELECT USING (true) on:
--   public.services
--   public.staff_members
--   public.blocked_days
--
-- Public/guest/customer reads go through SECURITY DEFINER RPCs that require
-- p_business_id and return only that tenant's public fields.
--
-- Does NOT change:
--   owner/admin write policies
--   owner/admin SELECT policies (if any)
--   business_gallery_images public SELECT
--   bookings / notifications / business_settings RLS
--   get_public_business_settings
--
-- If CREATE get_public_services fails with "column icon_key does not exist":
--   remove icon_key from RETURNS TABLE and the SELECT list, then re-run.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) get_public_services
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_public_services(uuid);

CREATE FUNCTION public.get_public_services(p_business_id uuid)
RETURNS TABLE (
  id uuid,
  name text,
  duration integer,
  price numeric,
  icon_key text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    s.id,
    s.name,
    s.duration::integer,
    s.price::numeric,
    s.icon_key
  FROM public.services s
  WHERE p_business_id IS NOT NULL
    AND s.business_id = p_business_id
  ORDER BY s.created_at ASC NULLS LAST, s.name ASC;
$$;

COMMENT ON FUNCTION public.get_public_services(uuid) IS
  'Public/guest/customer catalog for ONE business. Requires p_business_id. Does not dump all tenants.';

REVOKE ALL ON FUNCTION public.get_public_services(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_services(uuid) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2) get_public_staff
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_public_staff(uuid);

CREATE FUNCTION public.get_public_staff(p_business_id uuid)
RETURNS TABLE (
  id uuid,
  name text,
  role text,
  active boolean,
  photo_url text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    sm.id,
    sm.name,
    sm.role,
    coalesce(sm.active, true) AS active,
    sm.photo_url
  FROM public.staff_members sm
  WHERE p_business_id IS NOT NULL
    AND sm.business_id = p_business_id
    AND coalesce(sm.active, true) = true
  ORDER BY sm.created_at ASC NULLS LAST, sm.name ASC;
$$;

COMMENT ON FUNCTION public.get_public_staff(uuid) IS
  'Public/guest/customer active staff for ONE business. Hides is_owner and inactive staff.';

REVOKE ALL ON FUNCTION public.get_public_staff(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_staff(uuid) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3) get_public_closed_dates
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_public_closed_dates(uuid);

CREATE FUNCTION public.get_public_closed_dates(p_business_id uuid)
RETURNS TABLE (
  closed_date date
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT bd.date::date AS closed_date
  FROM public.blocked_days bd
  WHERE p_business_id IS NOT NULL
    AND bd.business_id = p_business_id
  ORDER BY 1;
$$;

COMMENT ON FUNCTION public.get_public_closed_dates(uuid) IS
  'Public/guest/customer closed dates for ONE business. Dates only; no reason/id.';

REVOKE ALL ON FUNCTION public.get_public_closed_dates(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_closed_dates(uuid) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4) Owner SELECT (admin CRUD) — not used by guest/customer
--    Guest/customer must not rely on these; they use the RPCs above.
--    Required so dropping USING(true) does not break owner table SELECT.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS services_select_own_business ON public.services;
CREATE POLICY services_select_own_business
  ON public.services
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS staff_members_select_own_business ON public.staff_members;
CREATE POLICY staff_members_select_own_business
  ON public.staff_members
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS blocked_days_select_own_business ON public.blocked_days;
CREATE POLICY blocked_days_select_own_business
  ON public.blocked_days
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 5) Drop dump-all public SELECT policies
--    Owner/admin INSERT/UPDATE/DELETE policies are not named here and
--    are left untouched. Gallery public SELECT is left untouched.
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS public_can_read_services ON public.services;
DROP POLICY IF EXISTS services_select_authenticated ON public.services;

DROP POLICY IF EXISTS public_can_read_staff ON public.staff_members;

DROP POLICY IF EXISTS public_can_read_blocked_days ON public.blocked_days;

NOTIFY pgrst, 'reload schema';

COMMIT;
