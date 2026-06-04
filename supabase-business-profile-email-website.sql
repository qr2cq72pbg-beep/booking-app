-- Business profile: optional email and website (same fields as onboarding).
-- Run once in Supabase Dashboard → SQL Editor.
-- Until this is applied, the app stores email/website in localStorage on the device only.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_email text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_website text;

COMMENT ON COLUMN public.business_settings.business_email IS 'Public contact email (optional).';
COMMENT ON COLUMN public.business_settings.business_website IS 'Business website URL (optional).';
