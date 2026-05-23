-- Optional social links + about visibility for public booking branding.
-- Run once in Supabase Dashboard → SQL Editor.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_instagram_url text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_facebook_url text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_show_about boolean;

COMMENT ON COLUMN public.business_settings.business_instagram_url IS 'Public Instagram profile URL (optional).';
COMMENT ON COLUMN public.business_settings.business_facebook_url IS 'Public Facebook page URL (optional).';
COMMENT ON COLUMN public.business_settings.public_show_about IS 'When false, hide business_description on public booking hero.';

ALTER TABLE public.business_settings ALTER COLUMN public_show_about SET DEFAULT true;

UPDATE public.business_settings
SET public_show_about = COALESCE(public_show_about, true)
WHERE public_show_about IS NULL;
