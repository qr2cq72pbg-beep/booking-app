-- =============================================================================
-- XBOOK Admin Control Center — Phase 3
-- Manual subscription catalog, current state, immutable history, atomic RPC
-- =============================================================================
-- READ THIS FIRST
--
-- Do NOT run this from the XBOOK iOS / Android / web apps.
-- Do NOT apply until you explicitly approve a database change.
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / ON CONFLICT).
--
-- This file does NOT:
--   • enforce subscriptions on bookings or business features
--   • create a 7-day trial
--   • integrate Paddle or any payment provider
--   • activate, expire, or charge existing businesses
--   • modify booking RPCs, tenant RLS, or index.html
--
-- Grandfathering:
--   Angel Touch and Test Barber (gorge123) keep working unchanged.
--   Existing businesses receive NO subscription row. Unconfigured ≠ expired.
--
-- Writes from the Control Center must go through the admin-control-center
-- Edge Function, which calls admin_apply_business_subscription.
-- Pricing and expiry are computed here. Never trust client-submitted amounts.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Package catalog (source of truth for price and duration)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.subscription_packages (
  package_id     text PRIMARY KEY,
  label          text NOT NULL,
  paid_months    integer NOT NULL,
  bonus_months   integer NOT NULL,
  access_months  integer NOT NULL,
  price_eur      numeric(10,2) NOT NULL,
  sort_order     integer NOT NULL,
  is_active      boolean NOT NULL DEFAULT true,
  CONSTRAINT subscription_packages_id_format
    CHECK (package_id ~ '^[a-z0-9_]+$'),
  CONSTRAINT subscription_packages_paid_positive
    CHECK (paid_months > 0),
  CONSTRAINT subscription_packages_bonus_nonneg
    CHECK (bonus_months >= 0),
  CONSTRAINT subscription_packages_access_matches
    CHECK (access_months = paid_months + bonus_months),
  CONSTRAINT subscription_packages_price_nonneg
    CHECK (price_eur >= 0)
);

COMMENT ON TABLE public.subscription_packages IS
  'XBOOK subscription packages. Durations and prices are server-defined. '
  'Superseded for new activations by supabase-platform-subscriptions-v1-plans.sql '
  '(FLEX / PLUS / MAX). Do not re-run this seed after that migration.';

INSERT INTO public.subscription_packages (
  package_id, label, paid_months, bonus_months, access_months, price_eur, sort_order, is_active
) VALUES
  ('month_1',  '1 month',      1, 0, 1,  39.99,  1, true),
  ('pack_3_1', '3+1 package',  3, 1, 4, 119.97,  2, true),
  ('pack_6_2', '6+2 package',  6, 2, 8, 239.94,  3, true),
  ('pack_9_3', '9+3 package',  9, 3, 12, 359.91, 4, true)
ON CONFLICT (package_id) DO UPDATE
SET label = EXCLUDED.label,
    paid_months = EXCLUDED.paid_months,
    bonus_months = EXCLUDED.bonus_months,
    access_months = EXCLUDED.access_months,
    price_eur = EXCLUDED.price_eur,
    sort_order = EXCLUDED.sort_order,
    is_active = EXCLUDED.is_active;

ALTER TABLE public.subscription_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_packages FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.subscription_packages FROM PUBLIC;
REVOKE ALL ON TABLE public.subscription_packages FROM anon;
REVOKE ALL ON TABLE public.subscription_packages FROM authenticated;
GRANT SELECT ON TABLE public.subscription_packages TO service_role;

-- -----------------------------------------------------------------------------
-- 2) Current subscription per business (absent row = unconfigured)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_subscriptions (
  business_id    uuid PRIMARY KEY REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  package_id     text NOT NULL REFERENCES public.subscription_packages (package_id),
  starts_on      date NOT NULL,
  expires_on     date NOT NULL,
  activated_at   timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  last_history_id uuid,
  CONSTRAINT business_subscriptions_expires_on_or_after_start
    CHECK (expires_on >= starts_on)
);

COMMENT ON TABLE public.business_subscriptions IS
  'Current manual subscription for a business. No row means unconfigured, not expired. '
  'Phase 3 does not enforce access. Status is derived: expires_on >= CURRENT_DATE → active.';

CREATE INDEX IF NOT EXISTS business_subscriptions_expires_idx
  ON public.business_subscriptions (expires_on);

CREATE INDEX IF NOT EXISTS business_subscriptions_package_idx
  ON public.business_subscriptions (package_id);

ALTER TABLE public.business_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_subscriptions FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.business_subscriptions FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscriptions FROM anon;
REVOKE ALL ON TABLE public.business_subscriptions FROM authenticated;
GRANT SELECT ON TABLE public.business_subscriptions TO service_role;

-- -----------------------------------------------------------------------------
-- 3) Immutable change history (one row per successful apply, including replays)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_subscription_history (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          uuid NOT NULL REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  idempotency_key      uuid NOT NULL,
  operation            text NOT NULL,
  package_id           text NOT NULL REFERENCES public.subscription_packages (package_id),
  paid_months          integer NOT NULL,
  bonus_months         integer NOT NULL,
  access_months        integer NOT NULL,
  price_eur            numeric(10,2) NOT NULL,
  requested_starts_on  date NOT NULL,
  previous_package_id  text,
  previous_starts_on   date,
  previous_expires_on  date,
  new_starts_on        date NOT NULL,
  new_expires_on       date NOT NULL,
  actor_user_id        uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  note                 text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_subscription_history_operation_ok
    CHECK (operation IN ('activate', 'extend')),
  CONSTRAINT business_subscription_history_expires_ok
    CHECK (new_expires_on >= new_starts_on)
);

COMMENT ON TABLE public.business_subscription_history IS
  'Insert-only log of manual subscription grants. Idempotency key prevents double-extend.';

CREATE UNIQUE INDEX IF NOT EXISTS business_subscription_history_idempotency_uidx
  ON public.business_subscription_history (idempotency_key);

CREATE INDEX IF NOT EXISTS business_subscription_history_business_idx
  ON public.business_subscription_history (business_id, created_at DESC);

ALTER TABLE public.business_subscription_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_subscription_history FORCE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.business_subscription_history FROM PUBLIC;
REVOKE ALL ON TABLE public.business_subscription_history FROM anon;
REVOKE ALL ON TABLE public.business_subscription_history FROM authenticated;
GRANT SELECT ON TABLE public.business_subscription_history TO service_role;

CREATE OR REPLACE FUNCTION public.business_subscription_history_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  RAISE EXCEPTION 'business_subscription_history is immutable';
END;
$$;

DROP TRIGGER IF EXISTS business_subscription_history_no_update
  ON public.business_subscription_history;
CREATE TRIGGER business_subscription_history_no_update
  BEFORE UPDATE OR DELETE ON public.business_subscription_history
  FOR EACH ROW
  EXECUTE FUNCTION public.business_subscription_history_immutable();

-- -----------------------------------------------------------------------------
-- 4) Calendar-month helper and period math (PostgreSQL interval months)
--    31 Jan + 1 month → last day of February; 31 Jan + 2 months → 31 Mar.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.subscription_add_calendar_months(
  p_date date,
  p_months integer
)
RETURNS date
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = public
AS $$
  SELECT (p_date + (p_months * INTERVAL '1 month'))::date;
$$;

COMMENT ON FUNCTION public.subscription_add_calendar_months(date, integer) IS
  'Add whole calendar months to a date using PostgreSQL month arithmetic.';

CREATE OR REPLACE FUNCTION public._subscription_compute_period(
  p_operation text,
  p_starts_on date,
  p_access_months integer,
  p_current_starts_on date,
  p_current_expires_on date,
  p_as_of date
)
RETURNS TABLE (new_starts_on date, new_expires_on date)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF p_access_months IS NULL OR p_access_months <= 0 THEN
    RAISE EXCEPTION 'invalid_access_months';
  END IF;
  IF p_starts_on IS NULL THEN
    RAISE EXCEPTION 'invalid_starts_on';
  END IF;

  -- Remaining paid access is preserved only while the current period is still active.
  IF p_operation = 'extend'
     AND p_current_expires_on IS NOT NULL
     AND p_current_expires_on >= p_as_of THEN
    new_starts_on := p_current_starts_on;
    new_expires_on := public.subscription_add_calendar_months(p_current_expires_on, p_access_months);
    RETURN NEXT;
    RETURN;
  END IF;

  new_starts_on := p_starts_on;
  new_expires_on := public.subscription_add_calendar_months(p_starts_on, p_access_months);
  RETURN NEXT;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) Read-only preview (same math as apply; no writes)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_preview_business_subscription(
  p_business_id uuid,
  p_package_id text,
  p_operation text,
  p_starts_on date
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
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_business_id');
  END IF;
  IF p_operation IS NULL OR p_operation NOT IN ('activate', 'extend') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;
  IF p_starts_on IS NULL
     OR p_starts_on < DATE '2018-01-01'
     OR p_starts_on > (v_as_of + 366) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.business_settings s WHERE s.business_id = p_business_id
  ) INTO v_business_ok;
  IF NOT v_business_ok THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;

  SELECT * INTO v_pkg
  FROM public.subscription_packages
  WHERE package_id = p_package_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id;

  IF FOUND THEN
    v_current_status := CASE
      WHEN v_cur.expires_on >= v_as_of THEN 'active'
      ELSE 'expired'
    END;
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF p_operation = 'activate' AND v_current_status = 'active' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_active');
  END IF;
  IF p_operation = 'extend' AND v_current_status = 'unconfigured' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
  END IF;

  SELECT * INTO v_period
  FROM public._subscription_compute_period(
    p_operation,
    p_starts_on,
    v_pkg.access_months,
    v_cur.starts_on,
    v_cur.expires_on,
    v_as_of
  );

  RETURN jsonb_build_object(
    'ok', true,
    'as_of_date', v_as_of,
    'operation', p_operation,
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
    'new_starts_on', v_period.new_starts_on,
    'new_expires_on', v_period.new_expires_on,
    'resulting_status', CASE
      WHEN v_period.new_expires_on >= v_as_of THEN 'active'
      ELSE 'expired'
    END,
    'preserves_remaining_access',
      (p_operation = 'extend' AND v_current_status = 'active')
  );
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) Atomic apply (transactional, idempotent, snapshots price/duration)
-- -----------------------------------------------------------------------------
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
  IF p_operation IS NULL OR p_operation NOT IN ('activate', 'extend') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_operation');
  END IF;
  IF p_starts_on IS NULL
     OR p_starts_on < DATE '2018-01-01'
     OR p_starts_on > (v_as_of + 366) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_starts_on');
  END IF;

  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_note IS NOT NULL AND char_length(v_note) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_note');
  END IF;

  -- Serialize applies for one business (and one idempotency key) in this transaction.
  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-biz'), hashtext(p_business_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('xbook-sub-idem'), hashtext(p_idempotency_key::text));

  SELECT * INTO v_hist
  FROM public.business_subscription_history
  WHERE idempotency_key = p_idempotency_key;

  IF FOUND THEN
    IF v_hist.business_id IS DISTINCT FROM p_business_id
       OR v_hist.operation IS DISTINCT FROM p_operation
       OR v_hist.package_id IS DISTINCT FROM p_package_id
       OR v_hist.requested_starts_on IS DISTINCT FROM p_starts_on THEN
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
        'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
        'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
        'expires_on', COALESCE(v_cur.expires_on, v_hist.new_expires_on),
        'updated_at', v_cur.updated_at,
        'updated_by', v_cur.updated_by,
        'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
      ),
      'history', jsonb_build_object(
        'id', v_hist.id,
        'operation', v_hist.operation,
        'package_id', v_hist.package_id,
        'new_starts_on', v_hist.new_starts_on,
        'new_expires_on', v_hist.new_expires_on
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

  SELECT * INTO v_pkg
  FROM public.subscription_packages
  WHERE package_id = p_package_id AND is_active = true;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_package_id');
  END IF;

  SELECT * INTO v_cur
  FROM public.business_subscriptions
  WHERE business_id = p_business_id
  FOR UPDATE;

  IF FOUND THEN
    v_current_status := CASE
      WHEN v_cur.expires_on >= v_as_of THEN 'active'
      ELSE 'expired'
    END;
  ELSE
    v_current_status := 'unconfigured';
  END IF;

  IF p_operation = 'activate' AND v_current_status = 'active' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already_active');
  END IF;
  IF p_operation = 'extend' AND v_current_status = 'unconfigured' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_subscription');
  END IF;

  SELECT * INTO v_period
  FROM public._subscription_compute_period(
    p_operation,
    p_starts_on,
    v_pkg.access_months,
    v_cur.starts_on,
    v_cur.expires_on,
    v_as_of
  );

  BEGIN
    INSERT INTO public.business_subscription_history (
    business_id,
    idempotency_key,
    operation,
    package_id,
    paid_months,
    bonus_months,
    access_months,
    price_eur,
    requested_starts_on,
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
    p_operation,
    v_pkg.package_id,
    v_pkg.paid_months,
    v_pkg.bonus_months,
    v_pkg.access_months,
    v_pkg.price_eur,
    p_starts_on,
    v_cur.package_id,
    v_cur.starts_on,
    v_cur.expires_on,
    v_period.new_starts_on,
    v_period.new_expires_on,
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
         OR v_hist.operation IS DISTINCT FROM p_operation
         OR v_hist.package_id IS DISTINCT FROM p_package_id
         OR v_hist.requested_starts_on IS DISTINCT FROM p_starts_on THEN
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
          'package_id', COALESCE(v_cur.package_id, v_hist.package_id),
          'starts_on', COALESCE(v_cur.starts_on, v_hist.new_starts_on),
          'expires_on', COALESCE(v_cur.expires_on, v_hist.new_expires_on),
          'updated_at', v_cur.updated_at,
          'updated_by', v_cur.updated_by,
          'last_history_id', COALESCE(v_cur.last_history_id, v_hist.id)
        ),
        'history', jsonb_build_object(
          'id', v_hist.id,
          'operation', v_hist.operation,
          'package_id', v_hist.package_id,
          'new_starts_on', v_hist.new_starts_on,
          'new_expires_on', v_hist.new_expires_on
        )
      );
  END;

  INSERT INTO public.business_subscriptions (
    business_id,
    package_id,
    starts_on,
    expires_on,
    activated_at,
    updated_at,
    updated_by,
    last_history_id
  ) VALUES (
    p_business_id,
    v_pkg.package_id,
    v_period.new_starts_on,
    v_period.new_expires_on,
    now(),
    now(),
    p_actor_user_id,
    v_history_id
  )
  ON CONFLICT (business_id) DO UPDATE
  SET package_id = EXCLUDED.package_id,
      starts_on = EXCLUDED.starts_on,
      expires_on = EXCLUDED.expires_on,
      updated_at = now(),
      updated_by = EXCLUDED.updated_by,
      last_history_id = EXCLUDED.last_history_id,
      activated_at = CASE
        WHEN public.business_subscriptions.expires_on < v_as_of
          THEN EXCLUDED.activated_at
        ELSE public.business_subscriptions.activated_at
      END;

  RETURN jsonb_build_object(
    'ok', true,
    'replayed', false,
    'as_of_date', v_as_of,
    'history_id', v_history_id,
    'subscription', jsonb_build_object(
      'business_id', p_business_id,
      'package_id', v_pkg.package_id,
      'starts_on', v_period.new_starts_on,
      'expires_on', v_period.new_expires_on,
      'updated_by', p_actor_user_id,
      'last_history_id', v_history_id
    ),
    'history', jsonb_build_object(
      'id', v_history_id,
      'operation', p_operation,
      'package_id', v_pkg.package_id,
      'new_starts_on', v_period.new_starts_on,
      'new_expires_on', v_period.new_expires_on
    )
  );
END;
$$;

COMMENT ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) IS
  'Privileged Control Center RPC. service_role only. Computes price and expiry server-side.';

COMMENT ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) IS
  'Privileged Control Center preview. Same calendar math as apply. No writes.';

REVOKE ALL ON FUNCTION public.subscription_add_calendar_months(date, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.subscription_add_calendar_months(date, integer) FROM anon;
REVOKE ALL ON FUNCTION public.subscription_add_calendar_months(date, integer) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.subscription_add_calendar_months(date, integer) TO service_role;

REVOKE ALL ON FUNCTION public._subscription_compute_period(text, date, integer, date, date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._subscription_compute_period(text, date, integer, date, date, date) FROM anon;
REVOKE ALL ON FUNCTION public._subscription_compute_period(text, date, integer, date, date, date) FROM authenticated;

REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM anon;
REVOKE ALL ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_business_subscription(uuid, text, text, date)
  TO service_role;

REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM anon;
REVOKE ALL ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_business_subscription(uuid, text, text, date, uuid, uuid, text)
  TO service_role;

REVOKE ALL ON FUNCTION public.business_subscription_history_immutable() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.business_subscription_history_immutable() FROM anon;
REVOKE ALL ON FUNCTION public.business_subscription_history_immutable() FROM authenticated;

COMMIT;

-- =============================================================================
-- POST-APPLY CHECKS (run separately, read-only)
-- =============================================================================
-- SELECT package_id, label, paid_months, bonus_months, access_months, price_eur
-- FROM public.subscription_packages
-- ORDER BY sort_order;
--
-- SELECT count(*) AS subscription_rows FROM public.business_subscriptions;
-- -- Expect 0 after first apply (grandfathered businesses stay unconfigured).
--
-- SELECT relname, relrowsecurity, relforcerowsecurity
-- FROM pg_class
-- WHERE relname IN (
--   'subscription_packages',
--   'business_subscriptions',
--   'business_subscription_history'
-- );
-- =============================================================================
