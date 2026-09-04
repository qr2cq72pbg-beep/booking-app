-- =============================================================================
-- XBOOK: North Macedonia city/town dataset cleanup
-- Location REFERENCE DATA only. No schema, RLS, auth, bookings, or UI changes.
--
-- Source of truth for "City":
--   The 34 legally recognized urban settlements (градови) of North Macedonia
--   (Wikipedia "List of cities in North Macedonia"; matches the 34 municipal
--   seats classified as city/town, not the 80-municipality list).
--
-- Pre-cleanup live audit (project sdqothuulzeczcncyfqd, 2026-08-25):
--   public.cities MK rows: 71 (all is_active)
--   customer_private_profiles: 0
--   customer_private_profiles.city_id IS NOT NULL: 0
--
-- Resume (2026-08-26): interrupted apply never committed. Live still 71 MK rows.
--   This file is idempotent: UPDATE keepers, DELETE leftovers (0-row OK),
--   then assert exactly 34 canonical active MK rows.
--
-- Classification of the 71:
--   A. Real city/town (keep, preserve UUID): 34
--   B. Municipality / village / administrative area (remove): 37
--   C. Reviewed then treated as B (not official grad):
--        Dojran   — municipality; Star/Nov Dojran are settlements, not a grad
--        Vevchani — village municipality, not in the 34-town set
--   No Skopje boroughs were in the 71 (already absent).
--
-- Model choice: DELETE the 37 non-city rows, do not is_active=false.
--   Why: zero live FKs; inactive municipalities would still occupy
--   UNIQUE(country_code, normalized_search); a City picker must not mix
--   admin units even if a query forgets WHERE is_active.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0) Safety stop if any customer already references a city
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_refs integer;
BEGIN
  SELECT count(*) INTO v_refs
  FROM public.customer_private_profiles
  WHERE city_id IS NOT NULL;

  IF v_refs > 0 THEN
    RAISE EXCEPTION
      'STOP: % customer_private_profiles row(s) reference city_id. Refusing destructive city deletion.',
      v_refs;
  END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- 1) Canonical 34 cities/towns: refresh names, aliases, keep existing UUIDs
--    Matched by (country_code, normalized_search) so ids are not rewritten.
-- -----------------------------------------------------------------------------
UPDATE public.cities AS c
SET
  name_en = v.name_en,
  name_mk = v.name_mk,
  aliases = v.aliases,
  is_active = true
FROM (
  VALUES
    ('skopje',               'Skopje',               'Скопје',              ARRAY['skopje', 'скопје']::text[]),
    ('strumica',             'Strumica',             'Струмица',            ARRAY['strumica', 'струмица']::text[]),
    ('bitola',               'Bitola',               'Битола',              ARRAY['bitola', 'битола']::text[]),
    ('prilep',               'Prilep',               'Прилеп',              ARRAY['prilep', 'прилеп']::text[]),
    ('kumanovo',             'Kumanovo',             'Куманово',            ARRAY['kumanovo', 'куманово']::text[]),
    ('tetovo',               'Tetovo',               'Тетово',              ARRAY['tetovo', 'тетово']::text[]),
    ('ohrid',                'Ohrid',                'Охрид',               ARRAY['ohrid', 'охрид']::text[]),
    ('struga',               'Struga',               'Струга',              ARRAY['struga', 'струга']::text[]),
    ('veles',                'Veles',                'Велес',               ARRAY['veles', 'велес']::text[]),
    ('stip',                 'Shtip',                'Штип',                ARRAY['stip', 'shtip', 'štip', 'штип']::text[]),
    ('gevgelija',            'Gevgelija',            'Гевгелија',           ARRAY['gevgelija', 'гевгелија']::text[]),
    ('kavadarci',            'Kavadarci',            'Кавадарци',           ARRAY['kavadarci', 'кавадарци']::text[]),
    ('negotino',             'Negotino',             'Неготино',            ARRAY['negotino', 'неготино']::text[]),
    ('radovis',              'Radovish',             'Радовиш',             ARRAY['radovis', 'radovish', 'radoviš', 'радовиш']::text[]),
    ('kocani',               'Kochani',              'Кочани',              ARRAY['kocani', 'kochani', 'kočani', 'кочани']::text[]),
    ('delcevo',              'Delchevo',             'Делчево',             ARRAY['delcevo', 'delchevo', 'delčevo', 'делчево']::text[]),
    ('berovo',               'Berovo',               'Берово',              ARRAY['berovo', 'берово']::text[]),
    ('vinica',               'Vinica',               'Виница',              ARRAY['vinica', 'виница']::text[]),
    ('kratovo',              'Kratovo',              'Кратово',             ARRAY['kratovo', 'кратово']::text[]),
    ('kriva palanka',        'Kriva Palanka',        'Крива Паланка',       ARRAY['kriva palanka', 'krivapalanka', 'крива паланка']::text[]),
    ('kicevo',               'Kichevo',              'Кичево',              ARRAY['kicevo', 'kichevo', 'kičevo', 'кичево']::text[]),
    ('debar',                'Debar',                'Дебар',               ARRAY['debar', 'дебар']::text[]),
    ('resen',                'Resen',                'Ресен',               ARRAY['resen', 'ресен']::text[]),
    ('demir kapija',         'Demir Kapija',         'Демир Капија',        ARRAY['demir kapija', 'demirkapija', 'демир капија']::text[]),
    ('demir hisar',          'Demir Hisar',          'Демир Хисар',         ARRAY['demir hisar', 'demirhisar', 'демир хисар']::text[]),
    ('krusevo',              'Krushevo',             'Крушево',             ARRAY['krusevo', 'krushevo', 'kruševo', 'крушево']::text[]),
    ('valandovo',            'Valandovo',            'Валандово',           ARRAY['valandovo', 'валандово']::text[]),
    ('bogdanci',             'Bogdanci',             'Богданци',            ARRAY['bogdanci', 'богданци']::text[]),
    ('sveti nikole',         'Sveti Nikole',         'Свети Николе',        ARRAY['sveti nikole', 'svetinikole', 'свети николе']::text[]),
    ('probistip',            'Probishtip',           'Пробиштип',           ARRAY['probistip', 'probishtip', 'probištip', 'пробиштип']::text[]),
    ('makedonski brod',      'Makedonski Brod',      'Македонски Брод',     ARRAY['makedonski brod', 'makedonskibrod', 'македонски брод']::text[]),
    ('makedonska kamenica',  'Makedonska Kamenica',  'Македонска Каменица', ARRAY['makedonska kamenica', 'makedonskakamenica', 'македонска каменица']::text[]),
    ('pehcevo',              'Pehchevo',             'Пехчево',             ARRAY['pehcevo', 'pehchevo', 'pehčevo', 'пехчево']::text[]),
    ('gostivar',             'Gostivar',             'Гостивар',            ARRAY['gostivar', 'гостивар']::text[])
) AS v(normalized_search, name_en, name_mk, aliases)
WHERE c.country_code = 'MK'
  AND c.normalized_search = v.normalized_search;

-- -----------------------------------------------------------------------------
-- 2) Remove municipality / village / admin rows that are not a City
-- -----------------------------------------------------------------------------
DELETE FROM public.cities
WHERE country_code = 'MK'
  AND normalized_search NOT IN (
    'skopje', 'strumica', 'bitola', 'prilep', 'kumanovo', 'tetovo',
    'ohrid', 'struga', 'veles', 'stip', 'gevgelija', 'kavadarci',
    'negotino', 'radovis', 'kocani', 'delcevo', 'berovo', 'vinica',
    'kratovo', 'kriva palanka', 'kicevo', 'debar', 'resen',
    'demir kapija', 'demir hisar', 'krusevo', 'valandovo', 'bogdanci',
    'sveti nikole', 'probistip', 'makedonski brod', 'makedonska kamenica',
    'pehcevo', 'gostivar'
  );

-- -----------------------------------------------------------------------------
-- 3) Idempotent post-condition (safe to re-run after a partial apply)
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_mk integer;
  v_missing integer;
BEGIN
  SELECT count(*) INTO v_mk
  FROM public.cities
  WHERE country_code = 'MK';

  IF v_mk <> 34 THEN
    RAISE EXCEPTION 'MK city cleanup expected 34 rows, found %.', v_mk;
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('skopje'), ('strumica'), ('bitola'), ('prilep'), ('kumanovo'),
      ('tetovo'), ('ohrid'), ('struga'), ('veles'), ('stip'),
      ('gevgelija'), ('kavadarci'), ('negotino'), ('radovis'), ('kocani'),
      ('delcevo'), ('berovo'), ('vinica'), ('kratovo'), ('kriva palanka'),
      ('kicevo'), ('debar'), ('resen'), ('demir kapija'), ('demir hisar'),
      ('krusevo'), ('valandovo'), ('bogdanci'), ('sveti nikole'),
      ('probistip'), ('makedonski brod'), ('makedonska kamenica'),
      ('pehcevo'), ('gostivar')
  ) AS expected(normalized_search)
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.cities c
    WHERE c.country_code = 'MK'
      AND c.normalized_search = expected.normalized_search
      AND c.is_active = true
  );

  IF v_missing > 0 THEN
    RAISE EXCEPTION 'MK city cleanup missing % canonical active rows.', v_missing;
  END IF;
END;
$$;

COMMIT;
