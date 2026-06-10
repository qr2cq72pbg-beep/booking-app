-- Recurring booking options (admin Settings → Working hours).
-- Run in Supabase SQL Editor after supabase-recurring-bookings-v1.sql.
-- allow_recurring_appointments already exists from that migration.

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS recurring_allowed_interval_weeks integer[] NOT NULL DEFAULT '{1,2}';

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS recurring_max_duration_months smallint NOT NULL DEFAULT 1;

ALTER TABLE public.business_settings
  DROP CONSTRAINT IF EXISTS business_settings_recurring_max_duration_months_check;

ALTER TABLE public.business_settings
  ADD CONSTRAINT business_settings_recurring_max_duration_months_check
  CHECK (recurring_max_duration_months >= 1 AND recurring_max_duration_months <= 3);

COMMENT ON COLUMN public.business_settings.recurring_allowed_interval_weeks IS
  'Weeks between recurring visits customers may choose (e.g. 1=weekly, 2=every 2 weeks).';

COMMENT ON COLUMN public.business_settings.recurring_max_duration_months IS
  'Maximum span of a recurring series in months (1–3).';
