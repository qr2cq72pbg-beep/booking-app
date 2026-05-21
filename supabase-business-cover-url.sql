-- Optional hero cover/background image for public booking page (public Storage URL).
-- Safe to run once in Supabase SQL Editor. NULL = use premium gradient fallback.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_cover_url text;

COMMENT ON COLUMN public.business_settings.business_cover_url IS
  'Public URL for booking page hero cover/background. NULL = gradient fallback. Logo uses business_logo_url.';
