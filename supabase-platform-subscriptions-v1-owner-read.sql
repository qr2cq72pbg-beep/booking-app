-- =============================================================================
-- XBOOK Phase 4C — Owner-facing read-only subscription access
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Safe to re-run (CREATE OR REPLACE / REVOKE / GRANT).
--
-- Requires already-applied:
--   supabase-platform-subscriptions-v1.sql
--   supabase-platform-subscriptions-v1-plans.sql
--   supabase-platform-subscriptions-v1-access.sql
--
-- This file does NOT:
--   • enforce expired access on create_booking / create_recurring_bookings
--   • create or backfill 7-day trials
--   • grant FREE to Angel Touch or any business
--   • activate Test Barber
--   • expose history, admin apply/preview, or table SELECT to clients
--   • modify index.html, booking RPCs, or tenant RLS
--
-- Owner identity is auth.uid() = business_settings.business_id.
-- Callers cannot pass a business_id. Customers receive 'Business owner only.'
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_my_business_access()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_as_of date := CURRENT_DATE;
  v_row public.business_subscriptions%ROWTYPE;
  v_pkg public.subscription_packages%ROWTYPE;
  v_status text;
  v_unlimited boolean := false;
  v_label text := null;
  v_display_code text := 'unconfigured';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Business owner only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_subscriptions
  WHERE business_id = v_uid;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'as_of_date', v_as_of,
      'business_id', v_uid,
      'configured', false,
      'status', 'unconfigured',
      'access_kind', null,
      'package_id', null,
      'package_label', null,
      'display_code', 'unconfigured',
      'price_eur', null,
      'access_months', null,
      'starts_on', null,
      'expires_on', null,
      'unlimited', false,
      'starts_in_future', false,
      'activated_at', null
    );
  END IF;

  v_status := public._subscription_row_status(v_row.expires_on, v_as_of);
  v_unlimited := (v_row.expires_on IS NULL);

  IF v_row.package_id IS NOT NULL THEN
    SELECT *
    INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_row.package_id;
  END IF;

  IF v_row.access_kind = 'complimentary' AND v_unlimited THEN
    v_display_code := 'complimentary_unlimited';
    v_label := 'FREE UNTIL CHANGED';
  ELSIF v_row.access_kind = 'complimentary' THEN
    v_display_code := 'complimentary';
    v_label := 'FREE';
  ELSIF v_row.access_kind = 'trial' THEN
    v_display_code := 'trial';
    v_label := 'Trial';
  ELSIF v_row.package_id IS NOT NULL THEN
    v_display_code := v_row.package_id;
    v_label := COALESCE(v_pkg.label, v_row.package_id);
  ELSE
    v_display_code := 'paid';
    v_label := COALESCE(v_pkg.label, 'XBOOK');
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', v_as_of,
    'business_id', v_uid,
    'configured', true,
    'status', v_status,
    'access_kind', v_row.access_kind,
    'package_id', v_row.package_id,
    'package_label', v_label,
    'display_code', v_display_code,
    'price_eur', CASE
      WHEN v_row.access_kind = 'paid' THEN v_pkg.price_eur
      ELSE null
    END,
    'access_months', CASE
      WHEN v_row.access_kind = 'paid' THEN v_pkg.access_months
      ELSE null
    END,
    'starts_on', v_row.starts_on,
    'expires_on', v_row.expires_on,
    'unlimited', v_unlimited,
    'starts_in_future', (v_row.starts_on IS NOT NULL AND v_row.starts_on > v_as_of),
    'activated_at', v_row.activated_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_business_access() IS
  'Owner-only read of the caller''s current subscription entitlement. '
  'Identity is auth.uid(). No row = unconfigured, not expired. '
  'Does not expose history, admin notes, or write operations.';

REVOKE ALL ON FUNCTION public.get_my_business_access() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_my_business_access() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_my_business_access() TO authenticated;

CREATE OR REPLACE FUNCTION public.list_active_subscription_packages()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_packages jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Business owner only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'package_id', p.package_id,
        'label', p.label,
        'description', p.description,
        'access_months', p.access_months,
        'price_eur', p.price_eur,
        'effective_monthly_eur', p.effective_monthly_eur,
        'savings_vs_flex_pct', p.savings_vs_flex_pct,
        'is_best_value', p.is_best_value,
        'sort_order', p.sort_order
      )
      ORDER BY p.sort_order, p.package_id
    ),
    '[]'::jsonb
  )
  INTO v_packages
  FROM public.subscription_packages p
  WHERE p.is_active = true;

  RETURN jsonb_build_object(
    'ok', true,
    'packages', v_packages
  );
END;
$$;

COMMENT ON FUNCTION public.list_active_subscription_packages() IS
  'Owner-only active FLEX/PLUS/MAX catalog for the Subscription screen. '
  'Read-only. Complimentary is not a catalog package.';

REVOKE ALL ON FUNCTION public.list_active_subscription_packages() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_active_subscription_packages() FROM anon;
GRANT EXECUTE ON FUNCTION public.list_active_subscription_packages() TO authenticated;

-- Tables stay RPC-only. Reaffirm no client SELECT.
REVOKE ALL ON TABLE public.subscription_packages FROM PUBLIC;
REVOKE ALL ON TABLE public.subscription_packages FROM anon;
REVOKE ALL ON TABLE public.subscription_packages FROM authenticated;
REVOKE ALL ON TABLE public.business_subscriptions FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscriptions FROM anon;
REVOKE ALL ON TABLE public.business_subscriptions FROM authenticated;
REVOKE ALL ON TABLE public.business_subscription_history FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscription_history FROM anon;
REVOKE ALL ON TABLE public.business_subscription_history FROM authenticated;

-- Admin write path remains service_role only.
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM PUBLIC, anon, authenticated;

COMMIT;
