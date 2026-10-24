-- =============================================================================
-- XBOOK Admin Control Center — Phase 4A
-- Complimentary (FREE) access schema + admin preview/apply extensions
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT apply until explicitly approved.
-- Safe to re-run (IF NOT EXISTS / DROP CONSTRAINT IF EXISTS / CREATE OR REPLACE).
--
-- This file does NOT:
--   • enforce subscription access on create_booking / create_recurring_bookings
--   • create or backfill 7-day trials
--   • grant FREE to Angel Touch or any existing business
--   • insert a public FREE package into subscription_packages
--   • charge, renew, or delete business/booking data
--   • modify index.html or tenant RLS
--
-- Paid activate / extend keep the same RPC names and named arguments.
-- Complimentary adds optional p_expires_on (NULL = FREE UNTIL CHANGED).
-- Deploy order if approved: apply this SQL, then redeploy admin-control-center.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Entitlement columns
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_subscriptions
  ADD COLUMN IF NOT EXISTS access_kind text NOT NULL DEFAULT 'paid';

ALTER TABLE public.business_subscriptions
  ALTER COLUMN package_id DROP NOT NULL;

ALTER TABLE public.business_subscriptions
  ALTER COLUMN expires_on DROP NOT NULL;

ALTER TABLE public.business_subscriptions
  DROP CONSTRAINT IF EXISTS business_subscriptions_expires_on_or_after_start;

ALTER TABLE public.business_subscriptions
  DROP CONSTRAINT IF EXISTS business_subscriptions_access_kind_ok;

ALTER TABLE public.business_subscriptions
  DROP CONSTRAINT IF EXISTS business_subscriptions_paid_package_required;

ALTER TABLE public.business_subscriptions
  DROP CONSTRAINT IF EXISTS business_subscriptions_expires_kind_ok;

ALTER TABLE public.business_subscriptions
  ADD CONSTRAINT business_subscriptions_expires_on_or_after_start
    CHECK (expires_on IS NULL OR expires_on >= starts_on);

ALTER TABLE public.business_subscriptions
  ADD CONSTRAINT business_subscriptions_access_kind_ok
    CHECK (access_kind IN ('paid', 'complimentary', 'trial'));

ALTER TABLE public.business_subscriptions
  ADD CONSTRAINT business_subscriptions_paid_package_required
    CHECK (
      (access_kind = 'paid' AND package_id IS NOT NULL AND expires_on IS NOT NULL)
      OR (access_kind <> 'paid')
    );

ALTER TABLE public.business_subscriptions
  ADD CONSTRAINT business_subscriptions_expires_kind_ok
    CHECK (
      access_kind <> 'complimentary'
      OR expires_on IS NULL
      OR expires_on >= starts_on
    );

COMMENT ON TABLE public.business_subscriptions IS
  'Current access entitlement. No row = unconfigured, not expired. '
  'access_kind complimentary with expires_on NULL = FREE UNTIL CHANGED. '
  'Phase 4A does not enforce bookings. Trial rows are reserved; not auto-granted here.';

COMMENT ON COLUMN public.business_subscriptions.access_kind IS
  'paid = FLEX/PLUS/MAX. complimentary = admin FREE. trial = reserved, not granted by this migration.';

COMMENT ON COLUMN public.business_subscriptions.expires_on IS
  'Inclusive UTC calendar date. NULL means no expiration (FREE UNTIL CHANGED). '
  'Status: NULL or expires_on >= CURRENT_DATE → active.';

CREATE INDEX IF NOT EXISTS business_subscriptions_access_kind_idx
  ON public.business_subscriptions (access_kind);

-- -----------------------------------------------------------------------------
-- 2) History: new operations, nullable package/expiry, requested end date
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS access_kind text NOT NULL DEFAULT 'paid';

ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS previous_access_kind text;

ALTER TABLE public.business_subscription_history
  ADD COLUMN IF NOT EXISTS requested_expires_on date;

ALTER TABLE public.business_subscription_history
  ALTER COLUMN package_id DROP NOT NULL;

ALTER TABLE public.business_subscription_history
  ALTER COLUMN new_expires_on DROP NOT NULL;

ALTER TABLE public.business_subscription_history
  DROP CONSTRAINT IF EXISTS business_subscription_history_operation_ok;

ALTER TABLE public.business_subscription_history
  DROP CONSTRAINT IF EXISTS business_subscription_history_expires_ok;

ALTER TABLE public.business_subscription_history
  DROP CONSTRAINT IF EXISTS business_subscription_history_access_kind_ok;

ALTER TABLE public.business_subscription_history
  ADD CONSTRAINT business_subscription_history_operation_ok
    CHECK (operation IN (
      'activate',
      'extend',
      'grant_complimentary',
      'extend_complimentary',
      'replace_complimentary',
      'revoke_complimentary',
      'convert_to_paid',
      'convert_to_complimentary'
    ));

ALTER TABLE public.business_subscription_history
  ADD CONSTRAINT business_subscription_history_expires_ok
    CHECK (new_expires_on IS NULL OR new_expires_on >= new_starts_on);

ALTER TABLE public.business_subscription_history
  ADD CONSTRAINT business_subscription_history_access_kind_ok
    CHECK (access_kind IN ('paid', 'complimentary', 'trial'));

COMMENT ON TABLE public.business_subscription_history IS
  'Insert-only log of manual access grants. Complimentary rows store price_eur = 0. '
  'NULL new_expires_on = FREE UNTIL CHANGED. Idempotency key prevents double-apply.';

-- -----------------------------------------------------------------------------
-- 3) Status helper (row exists). NULL expires_on = active unlimited.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._subscription_row_status(
  p_expires_on date,
  p_as_of date
)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_expires_on IS NULL THEN 'active'
    WHEN p_as_of IS NULL THEN 'expired'
    WHEN p_expires_on >= p_as_of THEN 'active'
    ELSE 'expired'
  END;
$$;

COMMENT ON FUNCTION public._subscription_row_status(date, date) IS
  'Derived status for an existing entitlement row. NULL expiry = active (unlimited).';

REVOKE ALL ON FUNCTION public._subscription_row_status(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._subscription_row_status(date, date) FROM anon;
REVOKE ALL ON FUNCTION public._subscription_row_status(date, date) FROM authenticated;

-- -----------------------------------------------------------------------------
-- 4) Preview / apply — new overloads with p_expires_on. Paid 4-arg / 7-arg
--    identities are kept as wrappers so existing activate/extend callers
--    do not break.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_preview_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_expires_on date
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_as_of date := CURRENT_DATE;
  v_pkg public.subscription_packages%ROWTYPE;
  v_cur public.business_subscriptions%ROWTYPE;
  v_business_ok boolean;
  v_period record;
  v_current_status text;
  v_operation text := lower(btrim(COALESCE(p_operation, '')));
  v_package_id text := NULLIF(btrim(COALESCE(p_package_id, '')), '');
  v_starts_on date := p_starts_on;
  v_expires_on date := p_expires_on;
  v_new_starts date;
  v_new_expires date;
  v_new_kind text;
  v_is_revenue boolean := true;
  v_label text;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;
  IF v_operation NOT IN (
    'activate', 'extend',
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_paid', 'convert_to_complimentary'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.business_settings s WHERE s.business_id = p_business_id
  ) INTO v_business_ok;
  IF NOT v_business_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id;

  IF FOUND THEN
    v_current_status := public._subscription_row_status(v_cur.expires_on, v_as_of);
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF v_operation IN ('activate', 'extend', 'convert_to_paid') THEN
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;

    SELECT * INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
    END IF;

    IF v_operation = 'activate' THEN
      IF v_current_status = 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
    ELSIF v_operation = 'extend' THEN
      IF v_current_status = 'unconfigured' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
      END IF;
      IF COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_paid_subscription');
      END IF;
    ELSE
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    END IF;

    SELECT * INTO v_period
    FROM public._subscription_compute_period(
      CASE WHEN v_operation = 'extend' THEN 'extend' ELSE 'activate' END,
      v_starts_on,
      v_pkg.access_months,
      v_cur.starts_on,
      v_cur.expires_on,
      v_as_of
    );
    v_new_starts := v_period.new_starts_on;
    v_new_expires := v_period.new_expires_on;
    v_new_kind := 'paid';
    v_is_revenue := true;

    RETURN jsonb_build_object(
      'ok', true,
      'as_of_date', v_as_of,
      'operation', v_operation,
      'access_kind', v_new_kind,
      'previous_access_kind', v_cur.access_kind,
      'is_revenue', v_is_revenue,
      'unlimited', false,
      'package', jsonb_build_object(
        'package_id', v_pkg.package_id,
        'label', v_pkg.label,
        'paid_months', v_pkg.paid_months,
        'bonus_months', v_pkg.bonus_months,
        'access_months', v_pkg.access_months,
        'price_eur', v_pkg.price_eur
      ),
      'current_status', v_current_status,
      'previous_starts_on', v_cur.starts_on,
      'previous_expires_on', v_cur.expires_on,
      'new_starts_on', v_new_starts,
      'new_expires_on', v_new_expires,
      'resulting_status', public._subscription_row_status(v_new_expires, v_as_of),
      'preserves_remaining_access',
        (v_operation = 'extend' AND v_current_status = 'active')
    );
  END IF;

  -- Complimentary operations. Not revenue. No catalog package.
  v_is_revenue := false;
  v_new_kind := 'complimentary';

  IF v_operation = 'revoke_complimentary' THEN
    IF v_current_status = 'unconfigured'
       OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
    END IF;
    IF v_current_status IS DISTINCT FROM 'active' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'already_revoked');
    END IF;
    v_new_expires := v_as_of - 1;
    v_new_starts := LEAST(v_cur.starts_on, v_new_expires);
    v_label := 'FREE';
  ELSIF v_operation = 'extend_complimentary' THEN
    IF v_current_status = 'unconfigured'
       OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
    END IF;
    IF v_current_status IS DISTINCT FROM 'active' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'no_active_complimentary');
    END IF;
    IF v_cur.expires_on IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'cannot_extend_unlimited');
    END IF;
    IF v_expires_on IS NULL
       OR v_expires_on <= v_cur.expires_on
       OR v_expires_on < DATE '2018-01-01'
       OR v_expires_on > (v_as_of + 7300) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
    END IF;
    v_new_starts := v_cur.starts_on;
    v_new_expires := v_expires_on;
    v_label := 'FREE';
  ELSE
    -- grant / replace / convert_to_complimentary
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;
    IF v_expires_on IS NOT NULL
       AND (
         v_expires_on < v_starts_on
         OR v_expires_on < DATE '2018-01-01'
         OR v_expires_on > (v_as_of + 7300)
       ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
    END IF;

    IF v_operation = 'grant_complimentary' THEN
      IF v_current_status = 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
    ELSIF v_operation = 'replace_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    ELSE
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_paid_subscription');
      END IF;
    END IF;

    v_new_starts := v_starts_on;
    v_new_expires := v_expires_on;
    v_label := CASE
      WHEN v_new_expires IS NULL THEN 'FREE UNTIL CHANGED'
      ELSE 'FREE'
    END;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', v_as_of,
    'operation', v_operation,
    'access_kind', v_new_kind,
    'previous_access_kind', v_cur.access_kind,
    'is_revenue', v_is_revenue,
    'unlimited', (v_new_expires IS NULL),
    'package', jsonb_build_object(
      'package_id', NULL,
      'label', v_label,
      'paid_months', 0,
      'bonus_months', 0,
      'access_months', 0,
      'price_eur', 0
    ),
    'current_status', v_current_status,
    'previous_starts_on', v_cur.starts_on,
    'previous_expires_on', v_cur.expires_on,
    'new_starts_on', v_new_starts,
    'new_expires_on', to_jsonb(v_new_expires),
    'resulting_status', public._subscription_row_status(v_new_expires, v_as_of),
    'preserves_remaining_access',
      (v_operation = 'extend_complimentary' AND v_current_status = 'active')
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_note text,
  p_expires_on date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_as_of date := CURRENT_DATE;
  v_pkg public.subscription_packages%ROWTYPE;
  v_cur public.business_subscriptions%ROWTYPE;
  v_hist public.business_subscription_history%ROWTYPE;
  v_business_ok boolean;
  v_period record;
  v_current_status text;
  v_note text;
  v_history_id uuid;
  v_replay boolean := false;
  v_operation text := lower(btrim(COALESCE(p_operation, '')));
  v_package_id text := NULLIF(btrim(COALESCE(p_package_id, '')), '');
  v_starts_on date := p_starts_on;
  v_expires_on date := p_expires_on;
  v_new_starts date;
  v_new_expires date;
  v_new_kind text;
  v_store_package text;
  v_paid_months integer := 0;
  v_bonus_months integer := 0;
  v_access_months integer := 0;
  v_price numeric(10,2) := 0;
  v_requested_starts date;
  v_requested_expires date := p_expires_on;
  v_idem_package text;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;
  IF p_idempotency_key IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_idempotency_key');
  END IF;
  IF p_actor_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_actor');
  END IF;
  IF v_operation NOT IN (
    'activate', 'extend',
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_paid', 'convert_to_complimentary'
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_note');
  END IF;

  IF v_operation = 'revoke_complimentary' AND v_starts_on IS NULL THEN
    v_starts_on := v_as_of;
  END IF;
  IF v_operation = 'extend_complimentary' AND v_starts_on IS NULL THEN
    v_starts_on := v_as_of;
  END IF;
  v_requested_starts := v_starts_on;
  IF v_operation IN ('activate', 'extend', 'convert_to_paid', 'revoke_complimentary') THEN
    v_requested_expires := NULL;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-biz'), hashtext(p_business_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-idem'), hashtext(p_idempotency_key::text));

  IF v_operation IN (
    'grant_complimentary', 'extend_complimentary', 'replace_complimentary',
    'revoke_complimentary', 'convert_to_complimentary'
  ) THEN
    v_idem_package := NULL;
  ELSE
    v_idem_package := v_package_id;
  END IF;

  SELECT * INTO v_hist
  FROM public.business_subscription_history
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_hist.business_id IS DISTINCT FROM p_business_id
       OR v_hist.operation IS DISTINCT FROM v_operation
       OR v_hist.package_id IS DISTINCT FROM v_idem_package
       OR v_hist.requested_starts_on IS DISTINCT FROM v_requested_starts
       OR v_hist.requested_expires_on IS DISTINCT FROM v_requested_expires THEN
      RETURN jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
    END IF;
    v_replay := true;
    SELECT * INTO v_cur
    FROM public.business_subscriptions
    WHERE business_id = p_business_id;

    RETURN jsonb_build_object(
      'ok', true,
      'replayed', true,
      'as_of_date', v_as_of,
      'history_id', v_hist.id,
      'subscription', jsonb_build_object(
        'business_id', p_business_id,
        'access_kind', COALESCE(v_cur.access_kind, v_hist.access_kind),
        'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
        'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
        'expires_on', to_jsonb(COALESCE(v_cur.expires_on, v_hist.new_expires_on)),
        'updated_at', v_cur.updated_at,
        'updated_by', v_cur.updated_by,
        'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
      ),
      'history', jsonb_build_object(
        'id', v_hist.id,
        'operation', v_hist.operation,
        'access_kind', v_hist.access_kind,
        'package_id', v_hist.package_id,
        'new_starts_on', v_hist.new_starts_on,
        'new_expires_on', to_jsonb(v_hist.new_expires_on)
      )
    );
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings s
    WHERE s.business_id = p_business_id
    FOR UPDATE
  ) INTO v_business_ok;
  IF NOT v_business_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id
  FOR UPDATE;

  IF FOUND THEN
    v_current_status := public._subscription_row_status(v_cur.expires_on, v_as_of);
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF v_operation IN ('activate', 'extend', 'convert_to_paid') THEN
    IF v_starts_on IS NULL
       OR v_starts_on < DATE '2018-01-01'
       OR v_starts_on > (v_as_of + 366) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
    END IF;

    SELECT * INTO v_pkg
    FROM public.subscription_packages
    WHERE package_id = v_package_id AND is_active = true;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
    END IF;

    IF v_operation = 'activate' AND v_current_status = 'active' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'already_active');
    END IF;
    IF v_operation = 'extend' THEN
      IF v_current_status = 'unconfigured' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
      END IF;
      IF COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'not_paid_subscription');
      END IF;
    END IF;
    IF v_operation = 'convert_to_paid' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
    END IF;

    SELECT * INTO v_period
    FROM public._subscription_compute_period(
      CASE WHEN v_operation = 'extend' THEN 'extend' ELSE 'activate' END,
      v_starts_on,
      v_pkg.access_months,
      v_cur.starts_on,
      v_cur.expires_on,
      v_as_of
    );
    v_new_starts := v_period.new_starts_on;
    v_new_expires := v_period.new_expires_on;
    v_new_kind := 'paid';
    v_store_package := v_pkg.package_id;
    v_paid_months := v_pkg.paid_months;
    v_bonus_months := v_pkg.bonus_months;
    v_access_months := v_pkg.access_months;
    v_price := v_pkg.price_eur;
  ELSE
    v_new_kind := 'complimentary';
    v_store_package := NULL;
    v_paid_months := 0;
    v_bonus_months := 0;
    v_access_months := 0;
    v_price := 0;

    IF v_operation = 'revoke_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
      IF v_current_status IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_revoked');
      END IF;
      v_new_expires := v_as_of - 1;
      v_new_starts := LEAST(v_cur.starts_on, v_new_expires);
    ELSIF v_operation = 'extend_complimentary' THEN
      IF v_current_status = 'unconfigured'
         OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
      END IF;
      IF v_current_status IS DISTINCT FROM 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_active_complimentary');
      END IF;
      IF v_cur.expires_on IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'cannot_extend_unlimited');
      END IF;
      IF v_expires_on IS NULL
         OR v_expires_on <= v_cur.expires_on
         OR v_expires_on < DATE '2018-01-01'
         OR v_expires_on > (v_as_of + 7300) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
      END IF;
      v_new_starts := v_cur.starts_on;
      v_new_expires := v_expires_on;
    ELSE
      IF v_starts_on IS NULL
         OR v_starts_on < DATE '2018-01-01'
         OR v_starts_on > (v_as_of + 366) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
      END IF;
      IF v_expires_on IS NOT NULL
         AND (
           v_expires_on < v_starts_on
           OR v_expires_on < DATE '2018-01-01'
           OR v_expires_on > (v_as_of + 7300)
         ) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_expires_on');
      END IF;

      IF v_operation = 'grant_complimentary' AND v_current_status = 'active' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'already_active');
      END IF;
      IF v_operation = 'replace_complimentary' THEN
        IF v_current_status = 'unconfigured'
           OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'complimentary' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'no_complimentary');
        END IF;
      END IF;
      IF v_operation = 'convert_to_complimentary' THEN
        IF v_current_status = 'unconfigured'
           OR COALESCE(v_cur.access_kind, 'paid') IS DISTINCT FROM 'paid' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'no_paid_subscription');
        END IF;
      END IF;

      v_new_starts := v_starts_on;
      v_new_expires := v_expires_on;
    END IF;
  END IF;

  BEGIN
    INSERT INTO public.business_subscription_history (
      business_id,
      idempotency_key,
      operation,
      package_id,
      access_kind,
      previous_access_kind,
      paid_months,
      bonus_months,
      access_months,
      price_eur,
      requested_starts_on,
      requested_expires_on,
      previous_package_id,
      previous_starts_on,
      previous_expires_on,
      new_starts_on,
      new_expires_on,
      actor_user_id,
      note
    ) VALUES (
      p_business_id,
      p_idempotency_key,
      v_operation,
      v_store_package,
      v_new_kind,
      v_cur.access_kind,
      v_paid_months,
      v_bonus_months,
      v_access_months,
      v_price,
      v_requested_starts,
      v_requested_expires,
      v_cur.package_id,
      v_cur.starts_on,
      v_cur.expires_on,
      v_new_starts,
      v_new_expires,
      p_actor_user_id,
      v_note
    )
    RETURNING id INTO v_history_id;
  EXCEPTION
    WHEN unique_violation THEN
      SELECT * INTO v_hist
      FROM public.business_subscription_history
      WHERE idempotency_key = p_idempotency_key;
      IF NOT FOUND THEN
        RAISE;
      END IF;
      IF v_hist.business_id IS DISTINCT FROM p_business_id
         OR v_hist.operation IS DISTINCT FROM v_operation THEN
        RETURN jsonb_build_object('ok', false, 'error', 'idempotency_conflict');
      END IF;
      SELECT * INTO v_cur
      FROM public.business_subscriptions
      WHERE business_id = p_business_id;
      RETURN jsonb_build_object(
        'ok', true,
        'replayed', true,
        'as_of_date', v_as_of,
        'history_id', v_hist.id,
        'subscription', jsonb_build_object(
          'business_id', p_business_id,
          'access_kind', COALESCE(v_cur.access_kind, v_hist.access_kind),
          'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
          'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
          'expires_on', to_jsonb(COALESCE(v_cur.expires_on, v_hist.new_expires_on)),
          'updated_at', v_cur.updated_at,
          'updated_by', v_cur.updated_by,
          'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
        ),
        'history', jsonb_build_object(
          'id', v_hist.id,
          'operation', v_hist.operation,
          'access_kind', v_hist.access_kind,
          'package_id', v_hist.package_id,
          'new_starts_on', v_hist.new_starts_on,
          'new_expires_on', to_jsonb(v_hist.new_expires_on)
        )
      );
  END;

  INSERT INTO public.business_subscriptions (
    business_id,
    package_id,
    access_kind,
    starts_on,
    expires_on,
    activated_at,
    updated_at,
    updated_by,
    last_history_id
  ) VALUES (
    p_business_id,
    v_store_package,
    v_new_kind,
    v_new_starts,
    v_new_expires,
    now(),
    now(),
    p_actor_user_id,
    v_history_id
  )
  ON CONFLICT (business_id) DO UPDATE
  SET package_id = EXCLUDED.package_id,
      access_kind = EXCLUDED.access_kind,
      starts_on = EXCLUDED.starts_on,
      expires_on = EXCLUDED.expires_on,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by,
      last_history_id = EXCLUDED.last_history_id,
      activated_at = CASE
        WHEN public._subscription_row_status(
          public.business_subscriptions.expires_on,
          v_as_of
        ) = 'active'
        AND public.business_subscriptions.access_kind IS NOT DISTINCT FROM EXCLUDED.access_kind
          THEN public.business_subscriptions.activated_at
        ELSE EXCLUDED.activated_at
      END;

  RETURN jsonb_build_object(
    'ok', true,
    'replayed', false,
    'as_of_date', v_as_of,
    'history_id', v_history_id,
    'subscription', jsonb_build_object(
      'business_id', p_business_id,
      'access_kind', v_new_kind,
      'package_id', v_store_package,
      'starts_on', v_new_starts,
      'expires_on', to_jsonb(v_new_expires),
      'updated_by', p_actor_user_id,
      'last_history_id', v_history_id
    ),
    'history', jsonb_build_object(
      'id', v_history_id,
      'operation', v_operation,
      'access_kind', v_new_kind,
      'package_id', v_store_package,
      'new_starts_on', v_new_starts,
      'new_expires_on', to_jsonb(v_new_expires)
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_preview_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date
)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_preview_business_subscription(
    p_business_id, p_package_id, p_operation, p_starts_on, NULL::date
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date,
  p_idempotency_key uuid,
  p_actor_user_id uuid,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.admin_apply_business_subscription(
    p_business_id,
    p_package_id,
    p_operation,
    p_starts_on,
    p_idempotency_key,
    p_actor_user_id,
    p_note,
    NULL::date
  );
$$;

COMMENT ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) IS
  'Privileged Control Center preview. Paid math unchanged. Complimentary is not revenue. No writes.';

COMMENT ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) IS
  'Paid-compatible wrapper. Calls the five-argument preview with p_expires_on NULL.';

COMMENT ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) IS
  'Privileged Control Center RPC. service_role only. Complimentary stores price_eur = 0. '
  'Does not grant trials or assign Angel Touch.';

COMMENT ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) IS
  'Paid-compatible wrapper. Calls the eight-argument apply with p_expires_on NULL.';

REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date, date)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text, date)
  TO service_role;

COMMIT;

-- =============================================================================
-- POST-APPLY CHECKS (run separately, read-only)
-- =============================================================================
-- SELECT package_id, is_active FROM public.subscription_packages ORDER BY sort_order;
-- Expect no complimentary / FREE package_id.
--
-- SELECT count(*) FROM public.business_subscriptions;
-- Expect still 0 until an admin grants access. Angel Touch stays unconfigured.
--
-- SELECT column_name FROM information_schema.columns
-- WHERE table_name = 'business_subscriptions' AND column_name IN ('access_kind','expires_on');
-- =============================================================================
