-- XBOOK: user_profiles RLS fix — customer/admin self-signup profile upsert
-- Run once in Supabase Dashboard → SQL Editor.
--
-- App schema (index.html upsertUserProfile):
--   id         uuid PRIMARY KEY = auth.users.id = auth.uid()
--   email      text
--   role       text  ('customer' | 'admin')
--   full_name  text
--   phone      text
--
-- No user_id column — id is the auth user id.

-- ---------------------------------------------------------------------------
-- 1) Table (create if missing; add columns if legacy ZIP table exists)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_profiles (
  id         uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email      text,
  role       text NOT NULL DEFAULT 'customer',
  full_name  text,
  phone      text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS email text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS role text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS full_name text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS phone text;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

UPDATE public.user_profiles SET role = 'customer' WHERE role IS NULL OR trim(role) = '';

ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- 2) Replace all existing policies (avoids conflicting legacy rules)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  pol record;
BEGIN
  FOR pol IN
    SELECT policyname
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_profiles'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.user_profiles', pol.policyname);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 3) Secure per-user policies (authenticated users — own row only)
-- ---------------------------------------------------------------------------
CREATE POLICY user_profiles_select_own
  ON public.user_profiles
  FOR SELECT
  TO authenticated
  USING (id = auth.uid());

CREATE POLICY user_profiles_insert_own
  ON public.user_profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (id = auth.uid());

CREATE POLICY user_profiles_update_own
  ON public.user_profiles
  FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (id = auth.uid());

-- ---------------------------------------------------------------------------
-- 4) Grants (RLS still enforced; no anon access)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON public.user_profiles TO authenticated;

COMMENT ON TABLE public.user_profiles IS
  'XBOOK user profile (id = auth.users.id). RLS: users may read/insert/update only their own row.';

-- ---------------------------------------------------------------------------
-- 5) Auto-create profile on auth.users INSERT (email-confirm flows have no session)
--    Reads full_name, phone, role from signUp options.data (raw_user_meta_data).
-- ---------------------------------------------------------------------------
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
  v_role := lower(trim(coalesce(NEW.raw_user_meta_data->>'role', 'customer')));
  IF v_role NOT IN ('customer', 'admin') THEN
    v_role := 'customer';
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

DROP TRIGGER IF EXISTS on_auth_user_created_profile ON auth.users;
CREATE TRIGGER on_auth_user_created_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_profile();

COMMENT ON FUNCTION public.handle_new_user_profile() IS
  'Creates user_profiles row from auth signUp metadata when client has no session yet.';
