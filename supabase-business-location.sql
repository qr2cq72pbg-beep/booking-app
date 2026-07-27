-- Exact business location (latitude/longitude) for navigation, in addition
-- to the existing free-text business_address column.
-- Run once in Supabase Dashboard → SQL Editor.
-- Safe to re-run: uses IF NOT EXISTS / DROP CONSTRAINT IF EXISTS guards.
--
-- Both columns are nullable and independent of business_address:
--   - business_address stays the display value (unchanged).
--   - business_latitude / business_longitude are the exact-location source
--     of truth for navigation once set (see index.html customer-view plan).
-- They must be saved together or not at all (enforced below).

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_latitude double precision;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_longitude double precision;

COMMENT ON COLUMN public.business_settings.business_latitude IS 'Exact business location latitude (-90 to 90). Null unless the owner set an exact location. Independent of business_address.';
COMMENT ON COLUMN public.business_settings.business_longitude IS 'Exact business location longitude (-180 to 180). Null unless the owner set an exact location. Independent of business_address.';

-- Range + "both or neither" pair validation, enforced at the database level
-- so a half-complete coordinate pair can never be stored regardless of
-- which client wrote it.
ALTER TABLE public.business_settings
  DROP CONSTRAINT IF EXISTS business_settings_location_valid;

ALTER TABLE public.business_settings
  ADD CONSTRAINT business_settings_location_valid CHECK (
    (business_latitude IS NULL AND business_longitude IS NULL)
    OR (
      business_latitude IS NOT NULL AND business_longitude IS NOT NULL
      AND business_latitude BETWEEN -90 AND 90
      AND business_longitude BETWEEN -180 AND 180
    )
  );
