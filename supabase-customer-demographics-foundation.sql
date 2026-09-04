-- =============================================================================
-- XBOOK: Customer demographics foundation (database only)
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (idempotent guards). Additive. Does not modify bookings,
-- auth triggers, or application UI.
--
-- Live duplicate re-audit (2026-08-25, project sdqothuulzeczcncyfqd):
--
--   Previous audit counted 1 duplicate *pair*:
--     business_id       = 8bf87a44-4b05-4de6-aae0-2704b97b8dbd  (business "petre")
--     customer_user_id  = 2c441698-8d9a-46f3-9e56-9a5afce4e0eb
--
--   That pair is NOT two copies of one CRM customer. It is 15 DISTINCT
--   guest/manual CRM rows (different client_key, phone, name, email,
--   customer_number) that were later stamped with the same customer_user_id.
--   That auth user NO LONGER EXISTS in auth.users (dangling UUID).
--   Bookings.customer_user_id was already SET NULL (bookings FK exists).
--   No table has an FK to business_customers.id.
--
--   Deleting 14 CRM rows would destroy distinct client identities
--   (Daniela, Vase, petre, gorge, …) and their customer numbers.
--   Bookings remain keyed by phone/email/name (client_key), not CRM id.
--
-- SAFE RESOLUTION (this file):
--   Do NOT delete business_customers rows.
--   SET customer_user_id = NULL on every CRM row whose auth user is gone
--   (18 rows, 3 deleted user ids — required before adding the FK).
--   Then UNIQUE (business_id, customer_user_id) WHERE NOT NULL can be added.
--
--   Expected business_customers count: UNCHANGED (54 → 54).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Unlink dangling customer_user_id (deleted auth users)
--    Equivalent to the ON DELETE SET NULL behavior we are about to add.
-- -----------------------------------------------------------------------------
UPDATE public.business_customers bc
SET
  customer_user_id = NULL,
  updated_at = now()
WHERE bc.customer_user_id IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM auth.users u WHERE u.id = bc.customer_user_id
  );

-- -----------------------------------------------------------------------------
-- 2) FK: business_customers.customer_user_id → auth.users(id) ON DELETE SET NULL
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_customers
  DROP CONSTRAINT IF EXISTS business_customers_customer_user_id_fkey;

ALTER TABLE public.business_customers
  ADD CONSTRAINT business_customers_customer_user_id_fkey
  FOREIGN KEY (customer_user_id)
  REFERENCES auth.users (id)
  ON DELETE SET NULL;

-- -----------------------------------------------------------------------------
-- 3) Partial UNIQUE membership: one auth customer per business
--    Guest/manual rows (customer_user_id IS NULL) remain allowed and may
--    coexist via UNIQUE (business_id, client_key).
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.business_customers_business_user_uniq;

CREATE UNIQUE INDEX business_customers_business_user_uniq
  ON public.business_customers (business_id, customer_user_id)
  WHERE customer_user_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 4) countries lookup (ISO 3166-1 alpha-2). Not phone dial codes.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.countries (
  code        text PRIMARY KEY,
  name_en     text NOT NULL,
  name_mk     text,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT countries_code_iso2 CHECK (code ~ '^[A-Z]{2}$')
);

COMMENT ON TABLE public.countries IS
  'ISO 3166-1 alpha-2 residence countries. Display names are bilingual; code is the identity.';

CREATE INDEX IF NOT EXISTS countries_is_active_idx
  ON public.countries (is_active)
  WHERE is_active = true;

ALTER TABLE public.countries ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS countries_select_all ON public.countries;
CREATE POLICY countries_select_all
  ON public.countries
  FOR SELECT
  TO anon, authenticated
  USING (true);

REVOKE ALL ON public.countries FROM PUBLIC;
REVOKE ALL ON public.countries FROM anon;
REVOKE ALL ON public.countries FROM authenticated;
GRANT SELECT ON public.countries TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5) cities lookup
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.cities (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  country_code       text NOT NULL,
  name_en            text NOT NULL,
  name_mk            text,
  normalized_search  text NOT NULL,
  aliases            text[] NOT NULL DEFAULT '{}',
  is_active          boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cities_country_fk
    FOREIGN KEY (country_code) REFERENCES public.countries (code) ON DELETE RESTRICT,
  CONSTRAINT cities_country_normalized_uniq
    UNIQUE (country_code, normalized_search),
  CONSTRAINT cities_id_country_uniq
    UNIQUE (id, country_code)
);

COMMENT ON TABLE public.cities IS
  'Canonical cities/towns for customer residence. Identity is id; UI language picks name_en/name_mk.';
COMMENT ON COLUMN public.cities.normalized_search IS
  'Lowercase ASCII fold of the English name for exact lookup. Typo tolerance is application-side.';
COMMENT ON COLUMN public.cities.aliases IS
  'Legitimate alternate searchable forms (transliterations), not typos.';

CREATE INDEX IF NOT EXISTS cities_country_code_idx
  ON public.cities (country_code);

CREATE INDEX IF NOT EXISTS cities_country_normalized_idx
  ON public.cities (country_code, normalized_search);

CREATE INDEX IF NOT EXISTS cities_country_active_idx
  ON public.cities (country_code)
  WHERE is_active = true;

CREATE INDEX IF NOT EXISTS cities_aliases_gin_idx
  ON public.cities USING gin (aliases);

ALTER TABLE public.cities ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cities_select_all ON public.cities;
CREATE POLICY cities_select_all
  ON public.cities
  FOR SELECT
  TO anon, authenticated
  USING (true);

REVOKE ALL ON public.cities FROM PUBLIC;
REVOKE ALL ON public.cities FROM anon;
REVOKE ALL ON public.cities FROM authenticated;
GRANT SELECT ON public.cities TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 6) Seed MK + North Macedonian cities/towns (municipalities, Skopje as one city)
-- -----------------------------------------------------------------------------
INSERT INTO public.countries (code, name_en, name_mk, is_active)
VALUES ('MK', 'North Macedonia', 'Северна Македонија', true)
ON CONFLICT (code) DO UPDATE
SET
  name_en = EXCLUDED.name_en,
  name_mk = EXCLUDED.name_mk,
  is_active = EXCLUDED.is_active;

-- Canonical MK City picker: 34 recognized towns/cities (градови).
-- Not the 80-municipality list. Skopje boroughs are not cities.
-- Cleanup applied by supabase-mk-cities-cleanup.sql (preserves existing UUIDs).
INSERT INTO public.cities (
  country_code, name_en, name_mk, normalized_search, aliases, is_active
)
VALUES
  ('MK', 'Skopje', 'Скопје', 'skopje', ARRAY['skopje', 'скопје'], true),
  ('MK', 'Strumica', 'Струмица', 'strumica', ARRAY['strumica', 'струмица'], true),
  ('MK', 'Bitola', 'Битола', 'bitola', ARRAY['bitola', 'битола'], true),
  ('MK', 'Prilep', 'Прилеп', 'prilep', ARRAY['prilep', 'прилеп'], true),
  ('MK', 'Kumanovo', 'Куманово', 'kumanovo', ARRAY['kumanovo', 'куманово'], true),
  ('MK', 'Tetovo', 'Тетово', 'tetovo', ARRAY['tetovo', 'тетово'], true),
  ('MK', 'Ohrid', 'Охрид', 'ohrid', ARRAY['ohrid', 'охрид'], true),
  ('MK', 'Struga', 'Струга', 'struga', ARRAY['struga', 'струга'], true),
  ('MK', 'Veles', 'Велес', 'veles', ARRAY['veles', 'велес'], true),
  ('MK', 'Shtip', 'Штип', 'stip', ARRAY['stip', 'shtip', 'štip', 'штип'], true),
  ('MK', 'Gevgelija', 'Гевгелија', 'gevgelija', ARRAY['gevgelija', 'гевгелија'], true),
  ('MK', 'Kavadarci', 'Кавадарци', 'kavadarci', ARRAY['kavadarci', 'кавадарци'], true),
  ('MK', 'Negotino', 'Неготино', 'negotino', ARRAY['negotino', 'неготино'], true),
  ('MK', 'Radovish', 'Радовиш', 'radovis', ARRAY['radovis', 'radovish', 'radoviš', 'радовиш'], true),
  ('MK', 'Kochani', 'Кочани', 'kocani', ARRAY['kocani', 'kochani', 'kočani', 'кочани'], true),
  ('MK', 'Delchevo', 'Делчево', 'delcevo', ARRAY['delcevo', 'delchevo', 'delčevo', 'делчево'], true),
  ('MK', 'Berovo', 'Берово', 'berovo', ARRAY['berovo', 'берово'], true),
  ('MK', 'Vinica', 'Виница', 'vinica', ARRAY['vinica', 'виница'], true),
  ('MK', 'Kratovo', 'Кратово', 'kratovo', ARRAY['kratovo', 'кратово'], true),
  ('MK', 'Kriva Palanka', 'Крива Паланка', 'kriva palanka', ARRAY['kriva palanka', 'krivapalanka', 'крива паланка'], true),
  ('MK', 'Kichevo', 'Кичево', 'kicevo', ARRAY['kicevo', 'kichevo', 'kičevo', 'кичево'], true),
  ('MK', 'Debar', 'Дебар', 'debar', ARRAY['debar', 'дебар'], true),
  ('MK', 'Resen', 'Ресен', 'resen', ARRAY['resen', 'ресен'], true),
  ('MK', 'Demir Kapija', 'Демир Капија', 'demir kapija', ARRAY['demir kapija', 'demirkapija', 'демир капија'], true),
  ('MK', 'Demir Hisar', 'Демир Хисар', 'demir hisar', ARRAY['demir hisar', 'demirhisar', 'демир хисар'], true),
  ('MK', 'Krushevo', 'Крушево', 'krusevo', ARRAY['krusevo', 'krushevo', 'kruševo', 'крушево'], true),
  ('MK', 'Valandovo', 'Валандово', 'valandovo', ARRAY['valandovo', 'валандово'], true),
  ('MK', 'Bogdanci', 'Богданци', 'bogdanci', ARRAY['bogdanci', 'богданци'], true),
  ('MK', 'Sveti Nikole', 'Свети Николе', 'sveti nikole', ARRAY['sveti nikole', 'svetinikole', 'свети николе'], true),
  ('MK', 'Probishtip', 'Пробиштип', 'probistip', ARRAY['probistip', 'probishtip', 'probištip', 'пробиштип'], true),
  ('MK', 'Makedonski Brod', 'Македонски Брод', 'makedonski brod', ARRAY['makedonski brod', 'makedonskibrod', 'македонски брод'], true),
  ('MK', 'Makedonska Kamenica', 'Македонска Каменица', 'makedonska kamenica', ARRAY['makedonska kamenica', 'makedonskakamenica', 'македонска каменица'], true),
  ('MK', 'Pehchevo', 'Пехчево', 'pehcevo', ARRAY['pehcevo', 'pehchevo', 'pehčevo', 'пехчево'], true),
  ('MK', 'Gostivar', 'Гостивар', 'gostivar', ARRAY['gostivar', 'гостивар'], true)
ON CONFLICT (country_code, normalized_search) DO UPDATE
SET
  name_en = EXCLUDED.name_en,
  name_mk = EXCLUDED.name_mk,
  aliases = EXCLUDED.aliases,
  is_active = EXCLUDED.is_active;

-- -----------------------------------------------------------------------------
-- 7) user_profiles: first_name / last_name (keep full_name)
-- -----------------------------------------------------------------------------
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS first_name text;

ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS last_name text;

COMMENT ON COLUMN public.user_profiles.first_name IS
  'Global given name. Nullable for legacy/OAuth until Complete Profile.';
COMMENT ON COLUMN public.user_profiles.last_name IS
  'Global family name. Remainder after first whitespace token of full_name.';

-- Same split as index.html splitCustomerFullName: first token / rest joined.
UPDATE public.user_profiles
SET
  first_name = COALESCE(
    nullif(trim(first_name), ''),
    nullif(substring(trim(full_name) FROM '^\S+'), '')
  ),
  last_name = COALESCE(
    nullif(trim(last_name), ''),
    nullif(trim(regexp_replace(trim(full_name), '^\S+\s*', '')), '')
  )
WHERE coalesce(nullif(trim(full_name), ''), '') <> ''
  AND (first_name IS NULL OR last_name IS NULL);

-- -----------------------------------------------------------------------------
-- 8) customer_private_profiles (global demographics; not business_customers)
--    Country/city consistency: both columns kept so country can be chosen
--    before city. When city_id is set, country_code is required and the
--    composite FK (city_id, country_code) → cities(id, country_code) proves
--    the city belongs to that country.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.customer_private_profiles (
  user_id         uuid PRIMARY KEY,
  date_of_birth   date,
  gender          text,
  country_code    text,
  city_id         uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT customer_private_profiles_user_fk
    FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE,
  CONSTRAINT customer_private_profiles_country_fk
    FOREIGN KEY (country_code) REFERENCES public.countries (code) ON DELETE SET NULL,
  CONSTRAINT customer_private_profiles_city_fk
    FOREIGN KEY (city_id) REFERENCES public.cities (id) ON DELETE SET NULL,
  CONSTRAINT customer_private_profiles_city_country_match_fk
    FOREIGN KEY (city_id, country_code)
    REFERENCES public.cities (id, country_code),
  CONSTRAINT customer_private_profiles_gender_check
    CHECK (gender IS NULL OR gender IN ('male', 'female')),
  CONSTRAINT customer_private_profiles_dob_check
    CHECK (date_of_birth IS NULL OR date_of_birth >= DATE '1900-01-01'),
  CONSTRAINT customer_private_profiles_city_requires_country
    CHECK (city_id IS NULL OR country_code IS NOT NULL)
);

COMMENT ON TABLE public.customer_private_profiles IS
  '1:1 global customer demographics. Owners must not SELECT this table; analytics will use a later business-scoped RPC.';
COMMENT ON COLUMN public.customer_private_profiles.gender IS
  'Canonical analytics code: male | female. NULL only for legacy/incomplete profiles.';
COMMENT ON COLUMN public.customer_private_profiles.date_of_birth IS
  'Source of truth for age. Do not persist age or age_group.';

CREATE INDEX IF NOT EXISTS customer_private_profiles_country_code_idx
  ON public.customer_private_profiles (country_code)
  WHERE country_code IS NOT NULL;

CREATE INDEX IF NOT EXISTS customer_private_profiles_city_id_idx
  ON public.customer_private_profiles (city_id)
  WHERE city_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS customer_private_profiles_gender_idx
  ON public.customer_private_profiles (gender)
  WHERE gender IS NOT NULL;

-- Table-specific updated_at (no reusable helper exists on this project).
CREATE OR REPLACE FUNCTION public.tg_customer_private_profiles_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS customer_private_profiles_set_updated_at
  ON public.customer_private_profiles;

CREATE TRIGGER customer_private_profiles_set_updated_at
  BEFORE UPDATE ON public.customer_private_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_customer_private_profiles_set_updated_at();

ALTER TABLE public.customer_private_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS customer_private_profiles_select_own ON public.customer_private_profiles;
CREATE POLICY customer_private_profiles_select_own
  ON public.customer_private_profiles
  FOR SELECT
  TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS customer_private_profiles_insert_own ON public.customer_private_profiles;
CREATE POLICY customer_private_profiles_insert_own
  ON public.customer_private_profiles
  FOR INSERT
  TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS customer_private_profiles_update_own ON public.customer_private_profiles;
CREATE POLICY customer_private_profiles_update_own
  ON public.customer_private_profiles
  FOR UPDATE
  TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

REVOKE ALL ON public.customer_private_profiles FROM PUBLIC;
REVOKE ALL ON public.customer_private_profiles FROM anon;
REVOKE ALL ON public.customer_private_profiles FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON public.customer_private_profiles TO authenticated;

-- -----------------------------------------------------------------------------
-- 9) user_profiles: revoke unused anon grants (RLS already authenticated-only)
--    Public booking does not read user_profiles. Signup uses the auth trigger
--    (SECURITY DEFINER) then authenticated upsert. Safe.
-- -----------------------------------------------------------------------------
REVOKE ALL ON public.user_profiles FROM anon;

COMMIT;

-- After success: Supabase Dashboard → Settings → API → Reload schema cache.
