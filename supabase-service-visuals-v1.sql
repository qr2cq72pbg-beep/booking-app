-- =============================================================================
-- XBOOK — Service Visuals V1 (additive)
-- =============================================================================
-- Run once in Supabase Dashboard → SQL Editor AFTER reviewing this file.
-- DO NOT run from the app. DO NOT apply as part of an automated deploy.
--
-- Adds:
--   public.services.service_visual_key  (nullable text, no default, no backfill)
--   get_public_services(...) also returns service_visual_key
--
-- Does NOT:
--   migrate or reuse icon_key
--   change RLS
--   change bookings / analytics
--   add a service-category column
--   add CHECK constraints
-- =============================================================================

BEGIN;

ALTER TABLE public.services
  ADD COLUMN IF NOT EXISTS service_visual_key text;

COMMENT ON COLUMN public.services.service_visual_key IS
  'Optional curated local visual key (e.g. barber_haircut_01). NULL means no visual. Independent of legacy icon_key.';

DROP FUNCTION IF EXISTS public.get_public_services(uuid);

CREATE FUNCTION public.get_public_services(p_business_id uuid)
RETURNS TABLE (
  id uuid,
  name text,
  duration integer,
  price numeric,
  icon_key text,
  service_visual_key text
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
    s.icon_key,
    s.service_visual_key
  FROM public.services s
  WHERE p_business_id IS NOT NULL
    AND s.business_id = p_business_id
  ORDER BY s.created_at ASC NULLS LAST, s.name ASC;
$$;

COMMENT ON FUNCTION public.get_public_services(uuid) IS
  'Public/guest/customer catalog for ONE business. Requires p_business_id. Does not dump all tenants. Includes optional service_visual_key.';

REVOKE ALL ON FUNCTION public.get_public_services(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_services(uuid) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
