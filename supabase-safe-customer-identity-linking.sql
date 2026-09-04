-- =============================================================================
-- XBOOK: Safe customer identity / membership linking
--
-- Apply via linked CLI or Dashboard SQL Editor AFTER:
--   supabase-business-customers.sql
--   supabase-client-approval.sql
--   supabase-sync-missing-business-customers.sql
--
-- Safe to re-run (CREATE OR REPLACE). Does NOT delete/merge CRM rows.
-- Does NOT rewrite historical client_key values.
-- Does NOT modify countries/cities, demographics tables, or auth email callbacks.
--
-- Canonical rule:
--   ONE authenticated XBook customer account
--   → AT MOST ONE business_customers row per business.
--   Guest/manual CRM rows are preserved.
--   Ambiguous identities are NEVER auto-merged.
--
-- Account linking happens ONLY through:
--   _ensure_business_customer_membership
--   register_customer_business_membership
--   handle_new_user_business_customer (unchanged trigger; calls _ensure)
--   _upsert_business_customer_approval_row (when customer_user_id IS NOT NULL)
--
-- Historical booking-wide customer_user_id backfills are disabled in:
--   supabase-client-approval.sql
--   supabase-fix-notification-recipient-linking.sql
-- Do NOT re-enable them. They stamped one auth id onto many CRM rows.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Phone / email canonicalization for ACCOUNT identity matching
--    (comparison-time only; historical client_key values are not rewritten)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._identity_calling_code(p_country_code text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE upper(trim(coalesce(p_country_code, '')))
    WHEN 'MK' THEN '389'
    -- Add further ISO 3166-1 alpha-2 codes here as XBook expands.
    -- Matching is country-aware via this helper; it is not MK-only schema.
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION public._identity_calling_code(text) IS
  'Maps ISO country code → calling code for identity phone canonicalization. MK=389. Extend here for other countries.';

CREATE OR REPLACE FUNCTION public._canonical_identity_phone(
  p_phone text,
  p_default_country text DEFAULT 'MK'
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_stripped text;
  v_digits text;
  v_cc text;
  v_had_plus boolean := false;
  v_national text;
BEGIN
  IF p_phone IS NULL THEN
    RETURN NULL;
  END IF;

  v_stripped := regexp_replace(trim(p_phone), '[^0-9+]', '', 'g');
  IF v_stripped = '' THEN
    RETURN NULL;
  END IF;

  IF left(v_stripped, 1) = '+' THEN
    v_had_plus := true;
    v_digits := regexp_replace(substr(v_stripped, 2), '[^0-9]', '', 'g');
  ELSIF left(v_stripped, 2) = '00' THEN
    v_had_plus := true;
    v_digits := regexp_replace(substr(v_stripped, 3), '[^0-9]', '', 'g');
  ELSE
    v_digits := regexp_replace(v_stripped, '[^0-9]', '', 'g');
  END IF;

  -- Too short / random numeric strings are not reliable identity.
  IF v_digits = '' OR length(v_digits) < 8 THEN
    RETURN NULL;
  END IF;

  v_cc := public._identity_calling_code(p_default_country);

  -- Explicit international (+CC... or 00CC...)
  IF v_had_plus THEN
    IF v_cc IS NOT NULL
       AND left(v_digits, length(v_cc)) = v_cc
       AND substr(v_digits, length(v_cc) + 1, 1) = '0' THEN
      -- +389078123456 → +38978123456 (strip trunk 0 after country code)
      RETURN '+' || v_cc || substr(v_digits, length(v_cc) + 2);
    END IF;
    RETURN '+' || v_digits;
  END IF;

  -- Bare country calling code without +  (38978123456 → +38978123456)
  IF v_cc IS NOT NULL
     AND left(v_digits, length(v_cc)) = v_cc
     AND length(v_digits) >= length(v_cc) + 8 THEN
    v_national := substr(v_digits, length(v_cc) + 1);
    IF left(v_national, 1) = '0' THEN
      v_national := substr(v_national, 2);
    END IF;
    IF length(v_national) < 8 THEN
      RETURN NULL;
    END IF;
    RETURN '+' || v_cc || v_national;
  END IF;

  -- National trunk-0 form for default country  (078123456 → +38978123456)
  IF v_cc IS NOT NULL AND left(v_digits, 1) = '0' AND length(v_digits) >= 9 THEN
    v_national := substr(v_digits, 2);
    IF length(v_national) < 8 THEN
      RETURN NULL;
    END IF;
    RETURN '+' || v_cc || v_national;
  END IF;

  -- Bare MK mobile without trunk 0  (78123456 → +38978123456)
  IF v_cc = '389' AND length(v_digits) = 8 AND v_digits ~ '^7' THEN
    RETURN '+389' || v_digits;
  END IF;

  -- Long unprefixed digit string: keep as +digits (do not guess NANP).
  IF length(v_digits) >= 10 THEN
    RETURN '+' || v_digits;
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._canonical_identity_phone(text, text) IS
  'Canonical E.164-like phone for account identity matching. Strips spaces/parens/hyphens; supports +. Default country MK maps +389… / 389… / 0… to the same +389… form. Returns NULL if shorter than 8 digits. Comparison-time only.';

CREATE OR REPLACE FUNCTION public._canonical_identity_email(p_email text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_email text;
BEGIN
  v_email := lower(trim(coalesce(p_email, '')));
  IF v_email = ''
     OR position('@' IN v_email) <= 1
     OR position('@' IN v_email) >= length(v_email) THEN
    RETURN NULL;
  END IF;
  RETURN v_email;
END;
$$;

COMMENT ON FUNCTION public._canonical_identity_email(text) IS
  'Case-normalized email for account identity matching. NULL if empty or missing @.';

-- -----------------------------------------------------------------------------
-- 2) Trusted account fields (auth.users / user_profiles — never booking-form proof)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._trusted_customer_account_email(p_user_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public._canonical_identity_email(u.email)
  FROM auth.users u
  WHERE u.id = p_user_id;
$$;

CREATE OR REPLACE FUNCTION public._trusted_customer_account_phone(
  p_user_id uuid,
  p_fallback_phone text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT coalesce(
    nullif(trim(p.phone), ''),
    nullif(trim(p_fallback_phone), '')
  )
  FROM (SELECT p_user_id AS id) s
  LEFT JOIN public.user_profiles p ON p.id = s.id;
$$;

CREATE OR REPLACE FUNCTION public._trusted_customer_account_name(
  p_user_id uuid,
  p_fallback_name text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT nullif(
    trim(coalesce(
      nullif(trim(p.full_name), ''),
      nullif(trim(p_fallback_name), '')
    )),
    ''
  )
  FROM (SELECT p_user_id AS id) s
  LEFT JOIN public.user_profiles p ON p.id = s.id;
$$;

-- -----------------------------------------------------------------------------
-- 3) Allocate next per-business customer_number
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._allocate_business_customer_number(p_business_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_next integer;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN NULL;
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

  RETURN v_next;
END;
$$;

-- -----------------------------------------------------------------------------
-- 4) Fill empty CRM identity fields from trusted account data only
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._fill_empty_business_customer_identity(
  p_id uuid,
  p_name text,
  p_phone text,
  p_email text
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
BEGIN
  UPDATE public.business_customers
  SET
    display_name = CASE
      WHEN nullif(trim(display_name), '') IS NULL THEN nullif(trim(p_name), '')
      ELSE display_name
    END,
    phone = CASE
      WHEN nullif(trim(phone), '') IS NULL THEN nullif(trim(p_phone), '')
      ELSE phone
    END,
    email = CASE
      WHEN nullif(trim(email), '') IS NULL THEN public._canonical_identity_email(p_email)
      ELSE email
    END,
    updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5) Insert one authenticated membership row (never uses n:<name> as the key)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._insert_authenticated_business_customer(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_phone              text,
  p_email              text,
  p_name               text,
  p_approval_status    text,
  p_force_user_key     boolean DEFAULT false,
  p_match_note         text DEFAULT NULL
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
  v_user_key text := 'u:' || p_customer_user_id::text;
BEGIN
  IF p_force_user_key THEN
    v_key := v_user_key;
  ELSE
    -- Contact key from trusted phone/email only. Name is never identity proof.
    v_key := public._booking_client_key(p_phone, p_email, NULL);
    IF v_key IS NULL OR left(v_key, 2) = 'n:' THEN
      v_key := v_user_key;
    END IF;
  END IF;

  -- client_key is NOT proof of authenticated identity. If that contact key
  -- already exists, do not claim it here — use the stable per-user key instead.
  IF v_key IS DISTINCT FROM v_user_key
     AND EXISTS (
       SELECT 1
       FROM public.business_customers bc
       WHERE bc.business_id = p_business_id
         AND bc.client_key = v_key
     ) THEN
    v_key := v_user_key;
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.client_key = v_key;

  IF FOUND THEN
    IF v_row.customer_user_id = p_customer_user_id THEN
      RETURN v_row;
    END IF;
    IF v_row.customer_user_id IS NULL AND v_key = v_user_key THEN
      UPDATE public.business_customers
      SET
        customer_user_id = p_customer_user_id,
        updated_at = now()
      WHERE id = v_row.id
        AND customer_user_id IS NULL
      RETURNING * INTO v_row;
      IF FOUND THEN
        RETURN public._fill_empty_business_customer_identity(
          v_row.id, p_name, p_phone, p_email
        );
      END IF;
    END IF;
    -- Occupied by someone else (should not happen for u:<uuid>). Re-query membership.
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    LIMIT 1;
    RETURN v_row;
  END IF;

  v_next := public._allocate_business_customer_number(p_business_id);

  INSERT INTO public.business_customers (
    business_id,
    client_key,
    customer_number,
    display_name,
    phone,
    email,
    customer_user_id,
    approval_status
  )
  VALUES (
    p_business_id,
    v_key,
    v_next,
    nullif(trim(p_name), ''),
    nullif(trim(p_phone), ''),
    public._canonical_identity_email(p_email),
    p_customer_user_id,
    p_approval_status
  )
  RETURNING * INTO v_row;

  IF p_match_note IS NOT NULL THEN
    RAISE LOG 'xbook identity: new membership business_id=% user_id=% crm_id=% note=%',
      p_business_id, p_customer_user_id, v_row.id, p_match_note;
  END IF;

  RETURN v_row;
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    LIMIT 1;
    IF v_row.id IS NOT NULL THEN
      RETURN v_row;
    END IF;
    -- client_key collision with a guest/other row: do not claim it.
    IF NOT coalesce(p_force_user_key, false) THEN
      RETURN public._insert_authenticated_business_customer(
        p_business_id,
        p_customer_user_id,
        p_phone,
        p_email,
        p_name,
        p_approval_status,
        true,
        coalesce(p_match_note, 'client_key collision; used u:<user>')
      );
    END IF;
    RAISE;
END;
$$;

-- -----------------------------------------------------------------------------
-- 6) Guest / CRM lookup — no email-OR-phone LIMIT 1, no account claiming
-- -----------------------------------------------------------------------------

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
  -- Authenticated identity: only the unique membership row.
  -- Never fall through to name / email-OR-phone claiming.
  IF p_customer_user_id IS NOT NULL THEN
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    LIMIT 1;
    RETURN v_row;
  END IF;

  -- Guest / manual CRM: client_key only (p:/e:/n: historical grouping).
  v_key := public._booking_client_key(p_customer_phone, p_customer_email, p_customer_name);
  IF v_key IS NOT NULL THEN
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.client_key = v_key
    LIMIT 1;
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public._lookup_business_customer_row(uuid, uuid, text, text, text) IS
  'Lookup CRM row. Auth user → unique (business_id, customer_user_id) only. Guest → client_key only. Does not claim by name and does not use email OR phone LIMIT 1.';

-- -----------------------------------------------------------------------------
-- 7) Safe authenticated membership (claim unique phone XOR unique email, else insert)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._ensure_business_customer_membership(
  p_business_id        uuid,
  p_customer_user_id   uuid,
  p_customer_phone     text,
  p_customer_email     text,
  p_customer_name      text,
  p_approval_status    text DEFAULT NULL
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row          public.business_customers%ROWTYPE;
  v_status       text;
  v_require      boolean;
  v_phone_raw    text;
  v_email        text;
  v_name         text;
  v_phone_canon  text;
  v_phone_ids    uuid[];
  v_email_ids    uuid[];
  v_phone_n      integer := 0;
  v_email_n      integer := 0;
  v_claim_id     uuid;
  v_ambiguous    boolean := false;
  v_note         text;
BEGIN
  IF p_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Guest / manual: CRM contact row only. Never assign customer_user_id.
  IF p_customer_user_id IS NULL THEN
    RETURN public.ensure_business_customer(
      p_business_id, p_customer_phone, p_customer_email, p_customer_name
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_customer_user_id) THEN
    RETURN NULL;
  END IF;

  -- 1) Existing account link
  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.customer_user_id = p_customer_user_id
  LIMIT 1;
  IF FOUND THEN
    RETURN v_row;
  END IF;

  SELECT coalesce(bs.require_client_approval, false)
  INTO v_require
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  v_status := lower(trim(coalesce(p_approval_status, '')));
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    v_status := CASE WHEN coalesce(v_require, false) THEN 'pending' ELSE 'approved' END;
  END IF;

  -- Trusted account identity (profile phone, auth.users email). Name is fill-only.
  v_email := public._trusted_customer_account_email(p_customer_user_id);
  v_phone_raw := public._trusted_customer_account_phone(p_customer_user_id, p_customer_phone);
  v_name := public._trusted_customer_account_name(p_customer_user_id, p_customer_name);
  v_phone_canon := public._canonical_identity_phone(v_phone_raw, 'MK');

  IF v_phone_canon IS NOT NULL THEN
    SELECT coalesce(array_agg(bc.id ORDER BY bc.created_at, bc.id), '{}')
    INTO v_phone_ids
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id IS NULL
      AND public._canonical_identity_phone(bc.phone, 'MK') = v_phone_canon;
    v_phone_n := coalesce(array_length(v_phone_ids, 1), 0);
  END IF;

  IF v_email IS NOT NULL THEN
    SELECT coalesce(array_agg(bc.id ORDER BY bc.created_at, bc.id), '{}')
    INTO v_email_ids
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id IS NULL
      AND public._canonical_identity_email(bc.email) = v_email;
    v_email_n := coalesce(array_length(v_email_ids, 1), 0);
  END IF;

  -- Phone and email are independent. Cross-row matches are ambiguous.
  -- Display name / n:<name> is never used.
  IF v_phone_n >= 2 OR v_email_n >= 2 THEN
    v_ambiguous := true;
    v_note := format(
      'ambiguous phone_n=%s email_n=%s phone_ids=%s email_ids=%s',
      v_phone_n, v_email_n, v_phone_ids, v_email_ids
    );
  ELSIF v_phone_n = 1 AND v_email_n = 1 THEN
    IF v_phone_ids[1] = v_email_ids[1] THEN
      v_claim_id := v_phone_ids[1];
    ELSE
      v_ambiguous := true;
      v_note := format(
        'ambiguous phone_row=%s email_row=%s',
        v_phone_ids[1], v_email_ids[1]
      );
    END IF;
  ELSIF v_phone_n = 1 THEN
    v_claim_id := v_phone_ids[1];
  ELSIF v_email_n = 1 THEN
    v_claim_id := v_email_ids[1];
  END IF;

  IF v_claim_id IS NOT NULL THEN
    UPDATE public.business_customers
    SET
      customer_user_id = p_customer_user_id,
      updated_at = now()
    WHERE id = v_claim_id
      AND customer_user_id IS NULL
    RETURNING * INTO v_row;

    IF FOUND THEN
      -- Preserve existing CRM values; fill only empty fields from trusted account.
      RETURN public._fill_empty_business_customer_identity(
        v_row.id, v_name, v_phone_raw, v_email
      );
    END IF;

    -- Lost the claim race; another session linked this user or this row.
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    LIMIT 1;
    IF FOUND THEN
      RETURN v_row;
    END IF;
  END IF;

  IF v_ambiguous THEN
    RAISE LOG 'xbook identity: % business_id=% user_id=% — creating new membership, leaving guest rows untouched',
      v_note, p_business_id, p_customer_user_id;
    RETURN public._insert_authenticated_business_customer(
      p_business_id,
      p_customer_user_id,
      v_phone_raw,
      v_email,
      v_name,
      v_status,
      true,
      v_note
    );
  END IF;

  RETURN public._insert_authenticated_business_customer(
    p_business_id,
    p_customer_user_id,
    v_phone_raw,
    v_email,
    v_name,
    v_status,
    false,
    NULL
  );
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = p_customer_user_id
    LIMIT 1;
    IF v_row.id IS NOT NULL THEN
      RETURN v_row;
    END IF;
    RAISE;
END;
$$;

COMMENT ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) IS
  'Safe membership: existing (business_id, customer_user_id), else unique canonical phone, else unique auth email, else insert. Ambiguous matches create a new u:<user> row and never merge guests. Name is never identity proof.';

-- -----------------------------------------------------------------------------
-- 8) Customer self-register (join-code / signup). Idempotent.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.register_customer_business_membership(
  p_business_id   uuid,
  p_phone         text DEFAULT '',
  p_email         text DEFAULT NULL,
  p_name          text DEFAULT NULL
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.business_customers%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  IF p_business_id IS NULL THEN
    RAISE EXCEPTION 'Business not found.' USING ERRCODE = 'P0001';
  END IF;

  -- p_email is never identity proof. Matching uses auth.users.email.
  -- p_phone is used only when user_profiles.phone is empty.
  v_row := public._ensure_business_customer_membership(
    p_business_id,
    v_uid,
    p_phone,
    NULL,
    p_name,
    NULL
  );

  RETURN v_row;
EXCEPTION
  WHEN unique_violation THEN
    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = v_uid
    LIMIT 1;
    IF v_row.id IS NOT NULL THEN
      RETURN v_row;
    END IF;
    RAISE;
END;
$$;

COMMENT ON FUNCTION public.register_customer_business_membership(uuid, text, text, text) IS
  'Authenticated membership RPC. Idempotent under UNIQUE (business_id, customer_user_id). Uses trusted auth email + profile phone. Does not match by display name.';

REVOKE ALL ON FUNCTION public.register_customer_business_membership(uuid, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_customer_business_membership(uuid, text, text, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 9) Guest CRM upsert: do not overwrite linked identity fields
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
    -- Linked membership: never blindly replace trusted identity from a booking form.
    IF v_row.customer_user_id IS NOT NULL THEN
      RETURN v_row;
    END IF;

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

  v_next := public._allocate_business_customer_number(p_business_id);

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
  'Guest/manual CRM upsert by client_key. Does not assign customer_user_id. Does not overwrite identity fields once a row is linked to an auth user.';

REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  TO service_role;
-- Canonical ACL lives with ensure_business_customer_for_owner (Phase 3A.1).
-- Do NOT grant authenticated. Nested SECURITY DEFINER helpers still call this
-- as function owner. Guest booking would break if this function required
-- auth.uid() = p_business_id.

-- -----------------------------------------------------------------------------
-- 10) Booking approval upsert — same identity rules
-- -----------------------------------------------------------------------------

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
  v_status text := lower(trim(coalesce(p_approval_status, 'pending')));
BEGIN
  IF v_status NOT IN ('approved', 'pending', 'rejected', 'blocked') THEN
    v_status := 'pending';
  END IF;

  -- Authenticated booking: resolve membership safely. Booking-form name/phone/email
  -- are not identity proof and must not overwrite a linked CRM row.
  IF p_customer_user_id IS NOT NULL THEN
    v_row := public._ensure_business_customer_membership(
      p_business_id,
      p_customer_user_id,
      p_customer_phone,
      p_customer_email,
      p_customer_name,
      v_status
    );
    RETURN v_row;
  END IF;

  -- Guest / manual: client_key CRM only. Never pretend this is an auth account.
  v_row := public._lookup_business_customer_row(
    p_business_id, NULL, p_customer_phone, p_customer_email, p_customer_name
  );

  IF v_row.id IS NOT NULL THEN
    IF v_row.customer_user_id IS NOT NULL THEN
      RETURN v_row;
    END IF;

    UPDATE public.business_customers
    SET
      display_name = coalesce(nullif(trim(p_customer_name), ''), display_name),
      phone = coalesce(nullif(trim(p_customer_phone), ''), phone),
      email = coalesce(nullif(lower(trim(p_customer_email)), ''), email),
      approval_status = v_status,
      updated_at = now()
    WHERE id = v_row.id
      AND customer_user_id IS NULL
    RETURNING * INTO v_row;
    RETURN v_row;
  END IF;

  v_row := public.ensure_business_customer(
    p_business_id, p_customer_phone, p_customer_email, p_customer_name
  );

  IF v_row.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF v_row.customer_user_id IS NOT NULL THEN
    RETURN v_row;
  END IF;

  UPDATE public.business_customers
  SET
    approval_status = v_status,
    updated_at = now()
  WHERE id = v_row.id
    AND customer_user_id IS NULL
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public._upsert_business_customer_approval_row(uuid, uuid, text, text, text, text) IS
  'Approval-row upsert. Auth users use safe membership (no name claim, no email-OR-phone LIMIT 1, no linked-field overwrite). Guests stay guest CRM.';

-- handle_new_user_business_customer is intentionally unchanged: it already
-- calls _ensure_business_customer_membership with NEW.email + signup metadata.
-- Trigger, role assignment, and xbook://auth/callback are not modified.

REVOKE ALL ON FUNCTION public._insert_authenticated_business_customer(uuid, uuid, text, text, text, text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._fill_empty_business_customer_identity(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._allocate_business_customer_number(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) TO service_role;

COMMIT;
