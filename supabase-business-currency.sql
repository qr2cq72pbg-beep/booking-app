-- Business currency for price display (MKD, EUR, USD).
-- Run once in Supabase Dashboard → SQL Editor.
-- Existing businesses default to MKD. Numeric prices are not converted.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_currency text NOT NULL DEFAULT 'MKD';

COMMENT ON COLUMN public.business_settings.business_currency IS 'Display currency code: MKD, EUR, or USD. Does not convert stored amounts.';
