-- =============================================================================
-- XBOOK: Per-business customer numbers
-- Run once in Supabase Dashboard → SQL Editor.
--
-- Schema inspection (from project SQL + app, not guessed):
--
--   business_settings.business_id  → uuid (PK; admin auth.users.id)
--
--   bookings.date                  → stored as text 'YYYY-MM-DD' in INSERT paths
--                                    (create_booking / create_recurring_bookings
--                                    insert v_date_text text). Comparisons in RPCs
--                                    use trim(b.date::text), so column may be text
--                                    or date; always cast via ::text.
--
--   bookings.time                  → stored as text 'HH:MM' in INSERT paths
--                                    (v_time_text). RPCs use
--                                    _booking_row_time_to_minutes(b.time) which
--                                    accepts time or text. Always cast via ::text.
--
--   bookings.created_at            → referenced by REST/API ordering in project;
--                                    not used for backfill ordering here to avoid
--                                    type/column drift. Backfill uses earliest
--                                    booking date+time per client (text-safe).
--
-- Numbering rules:
--   - Independent sequence per business_id (#001 for each business)
--   - UNIQUE (business_id, customer_number)
--   - UNIQUE (business_id, client_key)
--   - Backfill preserves all existing booking data (read-only on bookings)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Registry: one row per business + CRM client_key
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_customers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  client_key text NOT NULL,
  customer_number integer NOT NULL,
  display_name text,
  phone text,
  email text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_customers_business_client_key_uniq
    UNIQUE (business_id, client_key),
  CONSTRAINT business_customers_business_number_uniq
    UNIQUE (business_id, customer_number),
  CONSTRAINT business_customers_number_positive
    CHECK (customer_number > 0)
);

COMMENT ON TABLE public.business_customers IS
  'CRM customer registry with per-business customer_number (#001, #002, …).';
COMMENT ON COLUMN public.business_customers.client_key IS
  'Stable CRM key matching app: p:<phone_digits>, e:<email>, n:<name>.';
COMMENT ON COLUMN public.business_customers.customer_number IS
  'Per-business sequence starting at 1. Display as #001 in the app.';

CREATE INDEX IF NOT EXISTS business_customers_business_id_idx
  ON public.business_customers (business_id);

CREATE INDEX IF NOT EXISTS business_customers_business_number_idx
  ON public.business_customers (business_id, customer_number);

-- -----------------------------------------------------------------------------
-- 2) Per-business counter (next number to assign)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_customer_counters (
  business_id uuid PRIMARY KEY
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  next_number integer NOT NULL DEFAULT 1,
  CONSTRAINT business_customer_counters_next_positive
    CHECK (next_number >= 1)
);

COMMENT ON TABLE public.business_customer_counters IS
  'Next customer_number for each business_id (independent per business).';

-- -----------------------------------------------------------------------------
-- 3) CRM client_key (mirrors app getClientGroupKey)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._booking_client_key(
  p_phone text,
  p_email text,
  p_name text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_phone_trim text;
  v_digits text;
  v_email text;
  v_name text;
BEGIN
  v_phone_trim := trim(coalesce(p_phone, ''));
  v_digits := regexp_replace(v_phone_trim, '[^0-9]', '', 'g');

  IF length(v_digits) >= 6
     AND v_phone_trim <> ''
     AND v_phone_trim NOT IN (E'\u2014', '—', '-', '–') THEN
    RETURN 'p:' || v_digits;
  END IF;

  v_email := lower(trim(coalesce(p_email, '')));
  IF v_email <> '' AND position('@' in v_email) > 0 THEN
    RETURN 'e:' || v_email;
  END IF;

  v_name := lower(trim(coalesce(p_name, '')));
  IF v_name <> '' AND v_name <> 'customer' THEN
    RETURN 'n:' || v_name;
  END IF;

  RETURN NULL;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) Type-safe first_seen_at from bookings.date + bookings.time
--    (same anyelement pattern as _booking_row_time_to_minutes)
--    Never uses date + time with + operator; only text concat with ||.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._booking_row_first_seen_at(
  p_date anyelement,
  p_time anyelement
)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_date_text text;
  v_time_text text;
  v_stamp text;
BEGIN
  IF p_date IS NULL THEN
    RETURN NULL;
  END IF;

  IF pg_typeof(p_date)::text = 'date' THEN
    v_date_text := to_char(p_date::date, 'YYYY-MM-DD');
  ELSE
    v_date_text := left(trim(p_date::text), 10);
  END IF;

  IF v_date_text !~ '^\d{4}-\d{2}-\d{2}$' THEN
    RETURN NULL;
  END IF;

  IF p_time IS NULL THEN
    RETURN (v_date_text || 'T00:00:00')::timestamptz;
  END IF;

  IF pg_typeof(p_time)::text = 'time without time zone' THEN
    v_time_text := to_char(p_time::time, 'HH24:MI');
  ELSE
    v_time_text := left(trim(p_time::text), 5);
  END IF;

  IF v_time_text ~ '^\d{1,2}:\d{2}$' THEN
    v_stamp := v_date_text || 'T' || v_time_text || ':00';
    RETURN v_stamp::timestamptz;
  END IF;

  RETURN (v_date_text || 'T00:00:00')::timestamptz;
EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      RETURN (v_date_text || 'T00:00:00')::timestamptz;
    EXCEPTION
      WHEN OTHERS THEN
        RETURN NULL;
    END;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) Backfill existing customers per business_id (read-only on bookings)
--    Order: earliest booking timestamp per client, then client_key (stable).
-- -----------------------------------------------------------------------------
WITH grouped AS (
  SELECT
    b.business_id,
    public._booking_client_key(
      b.customer_phone,
      b.customer_email,
      b.customer_name
    ) AS client_key,
    min(public._booking_row_first_seen_at(b.date, b.time)) AS first_seen_at,
    max(nullif(trim(b.customer_name), '')) AS display_name,
    max(nullif(trim(b.customer_phone), '')) FILTER (
      WHERE length(regexp_replace(coalesce(b.customer_phone, ''), '[^0-9]', '', 'g')) >= 6
        AND trim(coalesce(b.customer_phone, '')) NOT IN (E'\u2014', '—', '-', '–')
    ) AS phone,
    max(nullif(lower(trim(b.customer_email)), '')) FILTER (
      WHERE position('@' in coalesce(b.customer_email, '')) > 0
    ) AS email
  FROM public.bookings b
  WHERE public._booking_client_key(
    b.customer_phone,
    b.customer_email,
    b.customer_name
  ) IS NOT NULL
  GROUP BY
    b.business_id,
    public._booking_client_key(
      b.customer_phone,
      b.customer_email,
      b.customer_name
    )
),
ranked AS (
  SELECT
    g.*,
    row_number() OVER (
      PARTITION BY g.business_id
      ORDER BY
        g.first_seen_at ASC NULLS LAST,
        g.client_key ASC
    ) AS customer_number
  FROM grouped g
)
INSERT INTO public.business_customers (
  business_id,
  client_key,
  customer_number,
  display_name,
  phone,
  email,
  first_seen_at
)
SELECT
  r.business_id,
  r.client_key,
  r.customer_number,
  r.display_name,
  r.phone,
  r.email,
  coalesce(r.first_seen_at, now())
FROM ranked r
ON CONFLICT (business_id, client_key) DO NOTHING;

-- -----------------------------------------------------------------------------
-- 6) Seed per-business counters (each business starts its own next sequence)
-- -----------------------------------------------------------------------------
INSERT INTO public.business_customer_counters (business_id, next_number)
SELECT
  bc.business_id,
  max(bc.customer_number) + 1
FROM public.business_customers bc
GROUP BY bc.business_id
ON CONFLICT (business_id) DO UPDATE
SET next_number = GREATEST(
  business_customer_counters.next_number,
  EXCLUDED.next_number
);

-- Businesses with zero bookings/customers still get counter row when first customer is created.

-- -----------------------------------------------------------------------------
-- 7) Assign or fetch customer (atomic next number per business_id only)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_business_customer(
  p_business_id uuid,
  p_phone text,
  p_email text,
  p_name text
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text;
  v_row public.business_customers%ROWTYPE;
  v_next integer;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_key := public._booking_client_key(p_phone, p_email, p_name);
  IF v_key IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers
  WHERE business_id = p_business_id
    AND client_key = v_key;

  IF FOUND THEN
    UPDATE public.business_customers
    SET
      display_name = coalesce(nullif(trim(p_name), ''), display_name),
      phone = coalesce(nullif(trim(p_phone), ''), phone),
      email = coalesce(nullif(lower(trim(p_email)), ''), email),
      updated_at = now()
    WHERE id = v_row.id
    RETURNING * INTO v_row;

    RETURN v_row;
  END IF;

  INSERT INTO public.business_customer_counters (business_id, next_number)
  VALUES (p_business_id, 1)
  ON CONFLICT (business_id) DO NOTHING;

  UPDATE public.business_customer_counters
  SET next_number = next_number + 1
  WHERE business_id = p_business_id
  RETURNING next_number - 1 INTO v_next;

  IF v_next IS NULL OR v_next < 1 THEN
    RAISE EXCEPTION 'Could not allocate customer number for business %.', p_business_id
      USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.business_customers (
    business_id,
    client_key,
    customer_number,
    display_name,
    phone,
    email
  )
  VALUES (
    p_business_id,
    v_key,
    v_next,
    nullif(trim(p_name), ''),
    nullif(trim(p_phone), ''),
    nullif(lower(trim(p_email)), '')
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.ensure_business_customer(uuid, text, text, text) IS
  'Returns existing CRM customer or assigns next customer_number for that business only.';

REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 8) RLS (same ownership model as business_client_notes)
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_customers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.business_customer_counters ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_customers_owner_all ON public.business_customers;
CREATE POLICY business_customers_owner_all
  ON public.business_customers
  FOR ALL
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_counters_owner_all ON public.business_customer_counters;
CREATE POLICY business_customer_counters_owner_all
  ON public.business_customer_counters
  FOR ALL
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

REVOKE ALL ON public.business_customers FROM anon;
REVOKE ALL ON public.business_customer_counters FROM anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.business_customers TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.business_customer_counters TO authenticated;

COMMIT;

-- After success: Supabase Dashboard → Settings → API → Reload schema cache.
