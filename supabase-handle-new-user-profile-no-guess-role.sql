-- XBOOK: handle_new_user_profile — do not guess role for OAuth / missing metadata
-- Safe to re-run. CREATE OR REPLACE FUNCTION only.
-- Does not alter schema, RLS, RPCs, trigger order, membership trigger, or existing rows.
-- Email signup still sends options.data.role = 'admin' | 'customer' and is unchanged.

CREATE OR REPLACE FUNCTION public.handle_new_user_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_role text;
  v_full_name text;
  v_phone text;
BEGIN
  v_role := lower(trim(coalesce(NEW.raw_user_meta_data->>'role', '')));

  -- Explicit XBOOK signup metadata only. Never default OAuth / unknown to customer.
  IF v_role NOT IN ('customer', 'admin') THEN
    RETURN NEW;
  END IF;

  v_full_name := nullif(trim(coalesce(NEW.raw_user_meta_data->>'full_name', '')), '');
  v_phone := nullif(trim(coalesce(NEW.raw_user_meta_data->>'phone', '')), '');

  INSERT INTO public.user_profiles (id, email, role, full_name, phone)
  VALUES (NEW.id, NEW.email, v_role, v_full_name, v_phone)
  ON CONFLICT (id) DO UPDATE SET
    email = coalesce(EXCLUDED.email, user_profiles.email),
    full_name = coalesce(EXCLUDED.full_name, user_profiles.full_name),
    phone = coalesce(EXCLUDED.phone, user_profiles.phone),
    role = coalesce(EXCLUDED.role, user_profiles.role),
    updated_at = now();

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user_profile() IS
  'Creates user_profiles from explicit auth signup metadata (role=admin|customer). Does not guess a role when metadata is missing (OAuth).';
