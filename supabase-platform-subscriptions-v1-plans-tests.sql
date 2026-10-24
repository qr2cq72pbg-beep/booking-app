-- =============================================================================
-- Read-only checks AFTER supabase-platform-subscriptions-v1-plans.sql
-- Does not write subscription data. Does not start trials.
-- =============================================================================

SELECT package_id, label, paid_months, bonus_months, access_months,
       price_eur, effective_monthly_eur, savings_vs_flex_pct,
       is_best_value, is_active
FROM public.subscription_packages
ORDER BY is_active DESC, sort_order, package_id;

-- Expect 3 active plans: flex_monthly 39.99 / plus_4_months 119.99 / max_18_months 499.00
-- Expect 4 inactive legacy ids: month_1, pack_3_1, pack_6_2, pack_9_3
-- Expect no "3+1" / "6+2" / "9+3" labels on active rows

SELECT count(*) AS subscription_rows FROM public.business_subscriptions;
-- Expect unchanged from preflight (currently 0).

SELECT count(*) FILTER (WHERE is_active) AS active_packages,
       count(*) FILTER (WHERE NOT is_active) AS inactive_packages
FROM public.subscription_packages;

SELECT public.subscription_add_calendar_months(DATE '2026-10-09', 1) AS flex_end,
       public.subscription_add_calendar_months(DATE '2026-10-09', 4) AS plus_end,
       public.subscription_add_calendar_months(DATE '2026-10-09', 18) AS max_end;
-- Expect 2026-11-09, 2027-02-09, 2028-04-09
