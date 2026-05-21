-- Phase A: Admin onboarding foundation (additive columns on business_settings).
-- Run once in Supabase Dashboard → SQL Editor.
-- Safe to re-run: uses IF NOT EXISTS / guards where applicable.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS onboarding_completed_at timestamptz;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS onboarding_step smallint;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS minimum_notice_minutes integer;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_category text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS timezone text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_layout text;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_show_logo boolean;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_show_prices boolean;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_show_staff boolean;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_show_address boolean;

COMMENT ON COLUMN public.business_settings.onboarding_completed_at IS 'When set, admin onboarding wizard is skipped.';
COMMENT ON COLUMN public.business_settings.onboarding_step IS 'Current wizard step 1–5 for resume.';

ALTER TABLE public.business_settings ALTER COLUMN onboarding_step SET DEFAULT 1;
ALTER TABLE public.business_settings ALTER COLUMN minimum_notice_minutes SET DEFAULT 60;
ALTER TABLE public.business_settings ALTER COLUMN timezone SET DEFAULT 'Europe/Skopje';
ALTER TABLE public.business_settings ALTER COLUMN public_layout SET DEFAULT 'default';
ALTER TABLE public.business_settings ALTER COLUMN public_show_logo SET DEFAULT true;
ALTER TABLE public.business_settings ALTER COLUMN public_show_prices SET DEFAULT true;
ALTER TABLE public.business_settings ALTER COLUMN public_show_staff SET DEFAULT true;
ALTER TABLE public.business_settings ALTER COLUMN public_show_address SET DEFAULT true;

-- Defaults for existing rows (columns may have been NULL before defaults applied)
UPDATE public.business_settings
SET
  onboarding_step = COALESCE(onboarding_step, 1),
  minimum_notice_minutes = COALESCE(minimum_notice_minutes, 60),
  timezone = COALESCE(NULLIF(trim(timezone), ''), 'Europe/Skopje'),
  public_layout = COALESCE(NULLIF(trim(public_layout), ''), 'default'),
  public_show_logo = COALESCE(public_show_logo, true),
  public_show_prices = COALESCE(public_show_prices, true),
  public_show_staff = COALESCE(public_show_staff, true),
  public_show_address = COALESCE(public_show_address, true)
WHERE onboarding_step IS NULL
   OR minimum_notice_minutes IS NULL
   OR timezone IS NULL
   OR public_layout IS NULL
   OR public_show_logo IS NULL
   OR public_show_prices IS NULL
   OR public_show_staff IS NULL
   OR public_show_address IS NULL;

-- Established businesses: treat as onboarding complete so existing admins are not blocked.
UPDATE public.business_settings bs
SET
  onboarding_completed_at = COALESCE(bs.onboarding_completed_at, now()),
  onboarding_step = GREATEST(COALESCE(bs.onboarding_step, 1), 5)
WHERE bs.onboarding_completed_at IS NULL
  AND (
    EXISTS (SELECT 1 FROM public.services s WHERE s.business_id = bs.business_id LIMIT 1)
    OR EXISTS (SELECT 1 FROM public.bookings b WHERE b.business_id = bs.business_id LIMIT 1)
  );
