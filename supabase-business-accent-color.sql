-- Run in Supabase Dashboard → SQL Editor (one time)
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS business_accent_color text;
