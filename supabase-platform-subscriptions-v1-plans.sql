-- =============================================================================
-- XBOOK Admin Control Center — subscription catalog FLEX / PLUS / MAX
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Safe to re-run (IF NOT EXISTS / ON CONFLICT / UPDATE).
--
-- This file does NOT:
--   • delete legacy package rows
--   • insert or update business_subscriptions
--   • start 7-day trials
--   • enforce subscription access on bookings
--   • charge or renew anything
--
-- Legacy packages (month_1, pack_3_1, pack_6_2, pack_9_3) are deactivated,
-- not deleted, so history FKs remain valid.
-- =============================================================================

BEGIN;

ALTER TABLE public.subscription_packages
  ADD COLUMN IF NOT EXISTS description text;

ALTER TABLE public.subscription_packages
  ADD COLUMN IF NOT EXISTS is_best_value boolean NOT NULL DEFAULT false;

ALTER TABLE public.subscription_packages
  ADD COLUMN IF NOT EXISTS effective_monthly_eur numeric(10,2);

ALTER TABLE public.subscription_packages
  ADD COLUMN IF NOT EXISTS savings_vs_flex_pct numeric(4,1);

COMMENT ON TABLE public.subscription_packages IS
  'XBOOK subscription catalog. All active plans include the same product features. '
  'They differ only in price and calendar-month duration. '
  'Legacy 3+1 / 6+2 / 9+3 rows stay for history; is_active = false.';

COMMENT ON COLUMN public.subscription_packages.description IS
  'Admin-facing plan copy. Not a feature-differentiation list.';

COMMENT ON COLUMN public.subscription_packages.effective_monthly_eur IS
  'Catalog display amount: price_eur / access_months, rounded to 2 decimals.';

COMMENT ON COLUMN public.subscription_packages.savings_vs_flex_pct IS
  'Catalog display savings versus FLEX monthly price × access_months. Null for FLEX.';

-- Deactivate previous plans. Do not DELETE.
UPDATE public.subscription_packages
SET is_active = false
WHERE package_id IN ('month_1', 'pack_3_1', 'pack_6_2', 'pack_9_3');

INSERT INTO public.subscription_packages (
  package_id,
  label,
  paid_months,
  bonus_months,
  access_months,
  price_eur,
  sort_order,
  is_active,
  description,
  is_best_value,
  effective_monthly_eur,
  savings_vs_flex_pct
) VALUES
  (
    'flex_monthly',
    'XBOOK FLEX',
    1, 0, 1,
    39.99,
    1,
    true,
    'Maximum flexibility. No long-term commitment.',
    false,
    39.99,
    NULL
  ),
  (
    'plus_4_months',
    'XBOOK PLUS',
    4, 0, 4,
    119.99,
    2,
    true,
    'More value, less commitment.',
    false,
    30.00,
    25.0
  ),
  (
    'max_18_months',
    'XBOOK MAX',
    18, 0, 18,
    499.00,
    3,
    true,
    'Maximum savings. Long-term price security.',
    true,
    27.72,
    30.7
  )
ON CONFLICT (package_id) DO UPDATE
SET label = EXCLUDED.label,
    paid_months = EXCLUDED.paid_months,
    bonus_months = EXCLUDED.bonus_months,
    access_months = EXCLUDED.access_months,
    price_eur = EXCLUDED.price_eur,
    sort_order = EXCLUDED.sort_order,
    is_active = true,
    description = EXCLUDED.description,
    is_best_value = EXCLUDED.is_best_value,
    effective_monthly_eur = EXCLUDED.effective_monthly_eur,
    savings_vs_flex_pct = EXCLUDED.savings_vs_flex_pct;

COMMIT;

-- =============================================================================
-- POST-APPLY CHECKS (run separately, read-only)
-- =============================================================================
-- SELECT package_id, label, access_months, price_eur, is_active, is_best_value
-- FROM public.subscription_packages
-- ORDER BY is_active DESC, sort_order;
--
-- Expect active: flex_monthly, plus_4_months, max_18_months
-- Expect inactive: month_1, pack_3_1, pack_6_2, pack_9_3
-- Expect business_subscriptions count still 0 until an admin activates a plan.
-- =============================================================================
