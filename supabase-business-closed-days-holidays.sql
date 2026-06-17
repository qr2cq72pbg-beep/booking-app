-- XBOOK: Non-working days & public holidays (beta)
-- Run in Supabase SQL Editor after existing migrations.

-- 1) Manual closed days (replaces/extends blocked_days for new UI)
CREATE TABLE IF NOT EXISTS public.business_closed_days (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.business_settings(business_id) ON DELETE CASCADE,
  date date NOT NULL,
  reason text,
  source text NOT NULL DEFAULT 'manual',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_closed_days_business_date_unique UNIQUE (business_id, date)
);

CREATE INDEX IF NOT EXISTS business_closed_days_business_id_date_idx
  ON public.business_closed_days (business_id, date);

ALTER TABLE public.business_closed_days ENABLE ROW LEVEL SECURITY;

-- 2) Holiday settings on business_settings
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS block_public_holidays boolean NOT NULL DEFAULT false;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS holiday_country text NOT NULL DEFAULT 'MK';

-- 3) Migrate existing manual blocked_days → business_closed_days
INSERT INTO public.business_closed_days (business_id, date, reason, source)
SELECT bd.business_id, bd.date::date, bd.reason, 'manual'
FROM public.blocked_days bd
ON CONFLICT (business_id, date) DO NOTHING;

-- 4) Optional: create_booking RPC still checks blocked_days; mirror is kept in sync via
--    supabase-business-closed-days-fix-rls.sql (SECURITY DEFINER trigger).
--    Reschedule uses _assert_booking_slot_available which checks business_closed_days too.
