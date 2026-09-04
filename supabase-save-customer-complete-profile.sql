-- =============================================================================
-- XBOOK: Atomic customer complete-profile save/load
-- Customer self-service only. No owner SELECT on customer_private_profiles.
-- Does not change identity-linking, cities seed, or RLS table policies.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_customer_complete_profile()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer profile only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT jsonb_build_object(
    'user_id', p.id,
    'email', coalesce(p.email, u.email),
    'role', p.role,
    'first_name', p.first_name,
    'last_name', p.last_name,
    'full_name', p.full_name,
    'phone', p.phone,
    'date_of_birth', pp.date_of_birth,
    'gender', pp.gender,
    'country_code', pp.country_code,
    'city_id', pp.city_id,
    'country_name_en', co.name_en,
    'country_name_mk', co.name_mk,
    'city_name_en', ci.name_en,
    'city_name_mk', ci.name_mk,
    'created_at', pp.created_at,
    'updated_at', pp.updated_at
  )
  INTO v_out
  FROM public.user_profiles p
  JOIN auth.users u ON u.id = p.id
  LEFT JOIN public.customer_private_profiles pp ON pp.user_id = p.id
  LEFT JOIN public.countries co ON co.code = pp.country_code
  LEFT JOIN public.cities ci ON ci.id = pp.city_id
  WHERE p.id = v_uid;

  RETURN v_out;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_customer_identity_profile(
  p_first_name text,
  p_last_name text,
  p_phone text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_first text := nullif(trim(coalesce(p_first_name, '')), '');
  v_last text := nullif(trim(coalesce(p_last_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_full text;
  v_digits text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer profile only.' USING ERRCODE = 'P0001';
  END IF;

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'First name is required.' USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NULL THEN
    RAISE EXCEPTION 'Last name is required.' USING ERRCODE = 'P0001';
  END IF;

  v_digits := regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g');
  IF v_phone IS NULL OR length(v_digits) < 8 THEN
    RAISE EXCEPTION 'Enter a valid phone number.' USING ERRCODE = 'P0001';
  END IF;

  v_full := trim(v_first || ' ' || v_last);

  UPDATE public.user_profiles
  SET
    first_name = v_first,
    last_name = v_last,
    full_name = v_full,
    phone = v_phone,
    updated_at = now()
  WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found.' USING ERRCODE = 'P0001';
  END IF;

  RETURN public.get_customer_complete_profile();
END;
$$;

CREATE OR REPLACE FUNCTION public.save_customer_complete_profile(
  p_first_name   text,
  p_last_name    text,
  p_phone        text,
  p_date_of_birth date,
  p_gender       text,
  p_country_code text,
  p_city_id      uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_first text := nullif(trim(coalesce(p_first_name, '')), '');
  v_last text := nullif(trim(coalesce(p_last_name, '')), '');
  v_phone text := nullif(trim(coalesce(p_phone, '')), '');
  v_gender text := lower(trim(coalesce(p_gender, '')));
  v_country text := upper(trim(coalesce(p_country_code, '')));
  v_full text;
  v_digits text;
  v_city_ok boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer profile only.' USING ERRCODE = 'P0001';
  END IF;

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'First name is required.' USING ERRCODE = 'P0001';
  END IF;
  IF v_last IS NULL THEN
    RAISE EXCEPTION 'Last name is required.' USING ERRCODE = 'P0001';
  END IF;

  v_digits := regexp_replace(coalesce(v_phone, ''), '[^0-9]', '', 'g');
  IF v_phone IS NULL OR length(v_digits) < 8 THEN
    RAISE EXCEPTION 'Enter a valid phone number.' USING ERRCODE = 'P0001';
  END IF;

  IF p_date_of_birth IS NULL THEN
    RAISE EXCEPTION 'Date of birth is required.' USING ERRCODE = 'P0001';
  END IF;
  IF p_date_of_birth < DATE '1900-01-01' THEN
    RAISE EXCEPTION 'Date of birth is invalid.' USING ERRCODE = 'P0001';
  END IF;
  IF p_date_of_birth > CURRENT_DATE THEN
    RAISE EXCEPTION 'Date of birth cannot be in the future.' USING ERRCODE = 'P0001';
  END IF;

  IF v_gender NOT IN ('male', 'female') THEN
    RAISE EXCEPTION 'Select a gender.' USING ERRCODE = 'P0001';
  END IF;

  IF v_country IS NULL OR length(v_country) <> 2 THEN
    RAISE EXCEPTION 'Select a country.' USING ERRCODE = 'P0001';
  END IF;

  IF p_city_id IS NULL THEN
    RAISE EXCEPTION 'Select a valid city.' USING ERRCODE = 'P0001';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.cities ci
    JOIN public.countries co ON co.code = ci.country_code
    WHERE ci.id = p_city_id
      AND ci.country_code = v_country
      AND ci.is_active = true
      AND co.is_active = true
  )
  INTO v_city_ok;

  IF NOT v_city_ok THEN
    RAISE EXCEPTION 'Select a valid city.' USING ERRCODE = 'P0001';
  END IF;

  v_full := trim(v_first || ' ' || v_last);

  UPDATE public.user_profiles
  SET
    first_name = v_first,
    last_name = v_last,
    full_name = v_full,
    phone = v_phone,
    updated_at = now()
  WHERE id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found.' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO public.customer_private_profiles (
    user_id,
    date_of_birth,
    gender,
    country_code,
    city_id
  )
  VALUES (
    v_uid,
    p_date_of_birth,
    v_gender,
    v_country,
    p_city_id
  )
  ON CONFLICT (user_id) DO UPDATE
  SET
    date_of_birth = EXCLUDED.date_of_birth,
    gender = EXCLUDED.gender,
    country_code = EXCLUDED.country_code,
    city_id = EXCLUDED.city_id;

  RETURN public.get_customer_complete_profile();
END;
$$;

REVOKE ALL ON FUNCTION public.get_customer_complete_profile() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_customer_identity_profile(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_customer_complete_profile(text, text, text, date, text, text, uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_customer_complete_profile() TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_customer_identity_profile(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_customer_complete_profile(text, text, text, date, text, text, uuid) TO authenticated;

COMMIT;
