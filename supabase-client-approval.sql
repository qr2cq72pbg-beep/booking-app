-- Client approval system for XBOOK.
-- Run once in Supabase Dashboard → SQL Editor AFTER:
--   supabase-business-customers.sql
--   supabase-booking-limits.sql (recommended — provides _normalize_booking_phone, _booking_belongs_to_client)
--
-- Extends business_customers with approval_status (reuses CRM registry).
-- Enforces rules via BEFORE INSERT trigger on bookings + helper RPCs.

BEGIN;

-- ---------------------------------------------------------------------------
-- 0) Helpers (safe no-ops if already created by supabase-booking-limits.sql)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._normalize_booking_phone(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT regexp_replace(coalesce(trim(p), ''), '[\s\-().]', '', 'g');
$$;

CREATE OR REPLACE FUNCTION public._booking_belongs_to_client(
  b                    public.bookings,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT
    (p_customer_user_id IS NOT NULL AND b.customer_user_id = p_customer_user_id)
    OR (
      coalesce(nullif(lower(trim(p_customer_email)), ''), '') <> ''
      AND lower(trim(coalesce(b.customer_email, ''))) = lower(trim(p_customer_email))
    )
    OR (
      length(public._normalize_booking_phone(p_customer_phone)) >= 8
      AND public._normalize_booking_phone(b.customer_phone)
        = public._normalize_booking_phone(p_customer_phone)
    );
$$;

-- ---------------------------------------------------------------------------
-- 1) Business settings
-- ---------------------------------------------------------------------------
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS require_client_approval boolean NOT NULL DEFAULT false;

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS accept_new_clients boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.business_settings.require_client_approval IS
  'When true, new clients must be approved before booking.';
COMMENT ON COLUMN public.business_settings.accept_new_clients IS
  'When false, only approved existing clients may book.';

-- ---------------------------------------------------------------------------
-- 2) Extend business_customers (reuse existing CRM table)
-- ---------------------------------------------------------------------------
ALTER TABLE public.business_customers
  ADD COLUMN IF NOT EXISTS customer_user_id uuid;

ALTER TABLE public.business_customers
  ADD COLUMN IF NOT EXISTS approval_status text NOT NULL DEFAULT 'approved';

ALTER TABLE public.business_customers
  DROP CONSTRAINT IF EXISTS business_customers_approval_status_check;

ALTER TABLE public.business_customers
  ADD CONSTRAINT business_customers_approval_status_check
  CHECK (approval_status IN ('approved', 'pending', 'rejected', 'blocked'));

CREATE INDEX IF NOT EXISTS business_customers_business_user_idx
  ON public.business_customers (business_id, customer_user_id)
  WHERE customer_user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS business_customers_business_status_idx
  ON public.business_customers (business_id, approval_status);

-- Existing CRM clients stay approved (beta safety).
UPDATE public.business_customers
SET approval_status = 'approved'
WHERE approval_status IS NULL
   OR trim(approval_status) = '';

-- Link customer_user_id from past bookings where possible.
UPDATE public.business_customers bc
SET customer_user_id = sub.customer_user_id
FROM (
  SELECT DISTINCT ON (b.business_id, public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name))
    b.business_id,
    public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name) AS client_key,
    b.customer_user_id
  FROM public.bookings b
  WHERE b.customer_user_id IS NOT NULL
    AND public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name) IS NOT NULL
  ORDER BY
    b.business_id,
    public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name),
    b.created_at DESC NULLS LAST
) sub
WHERE bc.business_id = sub.business_id
  AND bc.client_key = sub.client_key
  AND bc.customer_user_id IS NULL;

-- ---------------------------------------------------------------------------
-- 3) Match client to bookings / registry
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._approval_client_matches_booking(
  b                    public.bookings,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT public._booking_belongs_to_client(b, p_customer_user_id, p_customer_phone, p_customer_email)
    OR (
      coalesce(nullif(trim(p_customer_name), ''), '') <> ''
      AND lower(trim(coalesce(b.customer_name, ''))) = lower(trim(p_customer_name))
      AND public._booking_client_key(b.customer_phone, b.customer_email, b.customer_name)
        = public._booking_client_key(p_customer_phone, p_customer_email, p_customer_name)
    );
$$;

CREATE OR REPLACE FUNCTION public._client_has_past_business_bookings(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.bookings b
    WHERE b.business_id = p_business_id
      AND lower(trim(coalesce(b.booking_status::text, b.status::text, ''))) <> 'cancelled'
      AND public._approval_client_matches_booking(
        b, p_customer_user_id, p_customer_phone, p_customer_email, p_customer_name
      )
  );
$$;

CREATE OR REPLACE FUNCTION public._lookup_business_customer_row(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text
)
RETURNS public.business_customers
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
  v_key text;
BEGIN
  IF p_customer_user_id IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    ORDER BY bc.updated_at DESC
    LIMIT 1;
    IF FOUND THEN RETURN v_row; END IF;
  END IF;

  v_key := public._booking_client_key(p_customer_phone, p_customer_email, p_customer_name);
  IF v_key IS NOT NULL THEN
    SELECT * INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.client_key = v_key
    LIMIT 1;
    IF FOUND THEN RETURN v_row; END IF;
  END IF;

  SELECT * INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND (
      (
        coalesce(nullif(lower(trim(p_customer_email)), ''), '') <> ''
        AND lower(trim(coalesce(bc.email, ''))) = lower(trim(p_customer_email))
      )
      OR (
        length(public._normalize_booking_phone(p_customer_phone)) >= 8
        AND public._normalize_booking_phone(bc.phone)
          = public._normalize_booking_phone(p_customer_phone)
      )
    )
  ORDER BY bc.updated_at DESC
  LIMIT 1;

  RETURN v_row;
END;
$$;

-- ---------------------------------------------------------------------------
-- 4) Upsert pending / link auth user on registry row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._upsert_business_customer_approval_row(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_approval_status    text
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
  v_key text;
  v_status text := lower(trim(coalesce(p_approval_status, 'pending')));
BEGIN
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    v_status := 'pending';
  END IF;

  v_row := public._lookup_business_customer_row(
    p_business_id, p_customer_user_id, p_customer_phone, p_customer_email, p_customer_name
  );

  IF v_row.id IS NOT NULL THEN
    UPDATE public.business_customers
    SET
      customer_user_id = coalesce(p_customer_user_id, customer_user_id),
      display_name = coalesce(nullif(trim(p_customer_name), ''), display_name),
      phone = coalesce(nullif(trim(p_customer_phone), ''), phone),
      email = coalesce(nullif(lower(trim(p_customer_email)), ''), email),
      approval_status = v_status,
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;
    RETURN v_row;
  END IF;

  v_key := public._booking_client_key(p_customer_phone, p_customer_email, p_customer_name);
  IF v_key IS NULL THEN
    RETURN NULL;
  END IF;

  v_row := public.ensure_business_customer(
    p_business_id, p_customer_phone, p_customer_email, p_customer_name
  );

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  UPDATE public.business_customers
  SET
    customer_user_id = coalesce(p_customer_user_id, customer_user_id),
    approval_status = v_status,
    updated_at = now()
  WHERE id = v_row.id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5) Core approval decision (shared by trigger + check RPC)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._evaluate_client_booking_approval(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_create_pending     boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings     public.business_settings%ROWTYPE;
  v_row          public.business_customers%ROWTYPE;
  v_status       text;
  v_has_past     boolean;
  v_caller_uid   uuid := auth.uid();
  v_jwt_role     text := coalesce(nullif(auth.jwt() ->> 'role', ''), '');
BEGIN
  IF p_business_id IS NULL THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'ok', 'message', '');
  END IF;

  -- Admin manual booking bypass.
  IF v_jwt_role <> 'service_role'
     AND v_caller_uid IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM public.business_settings bs
       WHERE bs.business_id = p_business_id AND bs.business_id = v_caller_uid
     ) THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'admin', 'message', '');
  END IF;

  SELECT * INTO v_settings FROM public.business_settings bs WHERE bs.business_id = p_business_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'ok', 'message', '');
  END IF;

  v_has_past := public._client_has_past_business_bookings(
    p_business_id, p_customer_user_id, p_customer_phone, p_customer_email, p_customer_name
  );

  v_row := public._lookup_business_customer_row(
    p_business_id, p_customer_user_id, p_customer_phone, p_customer_email, p_customer_name
  );
  v_status := lower(trim(coalesce(v_row.approval_status, 'approved')));

  -- Legacy clients with past bookings are always treated as approved unless blocked.
  IF v_has_past THEN
    IF v_status = 'blocked' THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'code', 'blocked',
        'message', 'You cannot book with this business.'
      );
    END IF;
    IF v_row.id IS NOT NULL AND v_status <> 'approved' THEN
      UPDATE public.business_customers
      SET approval_status = 'approved', updated_at = now()
      WHERE id = v_row.id AND approval_status <> 'approved';
    END IF;
    RETURN jsonb_build_object('allowed', true, 'code', 'legacy', 'message', '');
  END IF;

  IF v_status = 'blocked' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'blocked',
      'message', 'You cannot book with this business.'
    );
  END IF;

  IF v_status = 'rejected' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'rejected',
      'message', 'This business is not accepting your booking request at this time.'
    );
  END IF;

  IF v_status = 'pending' THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'pending',
      'message', 'Your account is waiting for approval. You will be able to book after the business approves you.'
    );
  END IF;

  IF coalesce(v_settings.require_client_approval, false) = false
     AND coalesce(v_settings.accept_new_clients, true) = true THEN
    RETURN jsonb_build_object('allowed', true, 'code', 'ok', 'message', '');
  END IF;

  IF coalesce(v_settings.accept_new_clients, true) = false THEN
    IF v_status = 'approved' THEN
      RETURN jsonb_build_object('allowed', true, 'code', 'approved', 'message', '');
    END IF;
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'closed',
      'message', 'This business is not accepting new clients right now.'
    );
  END IF;

  -- require_client_approval = true, accept_new_clients = true, new client.
  IF coalesce(v_settings.require_client_approval, false) THEN
    IF p_create_pending THEN
      PERFORM public._upsert_business_customer_approval_row(
        p_business_id,
        p_customer_user_id,
        p_customer_phone,
        p_customer_email,
        p_customer_name,
        'pending'
      );
    END IF;
    RETURN jsonb_build_object(
      'allowed', false,
      'code', 'request_sent',
      'message', 'Your request has been sent. This business needs to approve new clients before they can book.'
    );
  END IF;

  RETURN jsonb_build_object('allowed', true, 'code', 'ok', 'message', '');
END;
$$;

CREATE OR REPLACE FUNCTION public._assert_client_approval_for_booking(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  v_result := public._evaluate_client_booking_approval(
    p_business_id,
    p_customer_user_id,
    p_customer_phone,
    p_customer_email,
    p_customer_name,
    true
  );

  IF coalesce((v_result ->> 'allowed')::boolean, false) THEN
    RETURN;
  END IF;

  RAISE EXCEPTION '%', coalesce(nullif(trim(v_result ->> 'message'), ''), 'Booking is not available.')
    USING ERRCODE = 'P0001';
END;
$$;

-- ---------------------------------------------------------------------------
-- 6) Customer pre-check RPC (frontend)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.check_client_booking_approval(
  p_business_id      uuid,
  p_customer_phone   text,
  p_customer_email   text DEFAULT NULL,
  p_customer_name    text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'This business requires an account to book.' USING ERRCODE = 'P0001';
  END IF;

  RETURN public._evaluate_client_booking_approval(
    p_business_id,
    v_uid,
    p_customer_phone,
    p_customer_email,
    p_customer_name,
    true
  );
END;
$$;

REVOKE ALL ON FUNCTION public.check_client_booking_approval(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.check_client_booking_approval(uuid, text, text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7) Admin approval status RPC
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_business_customer_approval_status(
  p_client_key   text,
  p_status       text
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_business_id uuid := auth.uid();
  v_key         text := nullif(trim(p_client_key), '');
  v_status      text := lower(trim(coalesce(p_status, '')));
  v_row         public.business_customers%ROWTYPE;
BEGIN
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated.' USING ERRCODE = 'P0001';
  END IF;
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'Client key is required.' USING ERRCODE = 'P0001';
  END IF;
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    RAISE EXCEPTION 'Invalid status. Use approved, pending, rejected, or blocked.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.business_customers bc
  SET approval_status = v_status, updated_at = now()
  WHERE bc.business_id = v_business_id
    AND bc.client_key = v_key
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Client not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.set_business_customer_approval_status(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_business_customer_approval_status(text, text)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8) RLS — customers can read their own approval row (not other businesses)
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS business_customers_customer_select_own ON public.business_customers;
CREATE POLICY business_customers_customer_select_own
  ON public.business_customers
  FOR SELECT
  TO authenticated
  USING (
    customer_user_id = auth.uid()
    OR (
      customer_user_id IS NULL
      AND email IS NOT NULL
      AND trim(email) <> ''
      AND lower(trim(email)) = lower(trim(coalesce(auth.jwt() ->> 'email', '')))
    )
  );

-- ---------------------------------------------------------------------------
-- 9) BEFORE INSERT trigger — server-side booking enforcement
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trg_bookings_before_insert_client_approval()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public._assert_client_approval_for_booking(
    NEW.business_id,
    NEW.customer_user_id,
    NEW.customer_phone,
    NEW.customer_email,
    NEW.customer_name
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_before_insert_client_approval ON public.bookings;
CREATE TRIGGER bookings_before_insert_client_approval
  BEFORE INSERT ON public.bookings
  FOR EACH ROW
  EXECUTE FUNCTION public.trg_bookings_before_insert_client_approval();

COMMIT;

-- After success: Supabase Dashboard → Settings → API → Reload schema cache.
