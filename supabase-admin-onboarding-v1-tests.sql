-- =============================================================================
-- Tests for supabase-admin-onboarding-v1.sql (Super Admin drafts + activation)
-- =============================================================================
-- Runs inside BEGIN … ROLLBACK with synthetic data only (test.invalid e-mails).
-- Prints "ok - …" per check; raises "FAIL - …" on the first failure.
-- =============================================================================

BEGIN;

CREATE FUNCTION pg_temp.act_as(p_uid uuid) RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', coalesce(p_uid::text, ''), true),
         set_config('request.jwt.claim.role', CASE WHEN p_uid IS NULL THEN 'anon' ELSE 'authenticated' END, true),
         set_config('request.jwt.claims',
           CASE WHEN p_uid IS NULL THEN '{"role":"anon"}'
                ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
$$;
CREATE FUNCTION pg_temp.as_server() RETURNS void LANGUAGE sql AS $$
  SELECT set_config('request.jwt.claim.sub', '', true),
         set_config('request.jwt.claim.role', 'service_role', true),
         set_config('request.jwt.claims', '{"role":"service_role"}', true);
$$;
CREATE FUNCTION pg_temp.expect_error(p_label text, p_sql text, p_expect text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(lower(p_expect) IN lower(SQLERRM)) > 0 THEN
      RAISE NOTICE 'ok - %', p_label;
      RETURN;
    END IF;
    RAISE EXCEPTION 'FAIL - % (unexpected error: %)', p_label, SQLERRM;
  END;
  RAISE EXCEPTION 'FAIL - % (no error, expected "%")', p_label, p_expect;
END;
$$;
CREATE FUNCTION pg_temp.ok(p_label text, p_cond boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_cond IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL - %', p_label;
  END IF;
  RAISE NOTICE 'ok - %', p_label;
END;
$$;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pg_temp TO PUBLIC;


-- ---------------------------------------------------------------- privileges
SELECT pg_temp.ok('business_onboarding has RLS enabled',
  (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.business_onboarding'::regclass));
SELECT pg_temp.ok('anon has no table privileges',
  NOT has_table_privilege('anon', 'public.business_onboarding', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.business_onboarding', 'INSERT'));
SELECT pg_temp.ok('authenticated has no table privileges',
  NOT has_table_privilege('authenticated', 'public.business_onboarding', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.business_onboarding', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.business_onboarding', 'TRUNCATE'));
SELECT pg_temp.ok('service_role can read/write onboarding',
  has_table_privilege('service_role', 'public.business_onboarding', 'SELECT')
  AND has_table_privilege('service_role', 'public.business_onboarding', 'INSERT'));
SELECT pg_temp.ok('_admin_owner_email_status is server-only',
  NOT has_function_privilege('authenticated', 'public._admin_owner_email_status(text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public._admin_owner_email_status(text)', 'EXECUTE')
  AND has_function_privilege('service_role', 'public._admin_owner_email_status(text)', 'EXECUTE'));
SELECT pg_temp.ok('_admin_owner_account is server-only',
  NOT has_function_privilege('authenticated', 'public._admin_owner_account(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public._admin_owner_account(uuid)', 'EXECUTE'));
SELECT pg_temp.ok('complete_business_activation: authenticated yes, anon no',
  has_function_privilege('authenticated', 'public.complete_business_activation()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.complete_business_activation()', 'EXECUTE'));

-- ---------------------------------------------------------------- fixtures
-- d1: draft (no auth user yet). d2: draft that will be invited and activated.
-- x: an existing self-registered owner business with a paid subscription.
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
INSERT INTO auth.users (id, email, email_confirmed_at, encrypted_password)
VALUES ('5a000000-0000-4000-8000-0000000000aa', 'sa-existing@test.invalid', now(), 'x');
INSERT INTO public.business_settings (business_id, business_slug, business_name, timezone, working_days, work_start, work_end)
VALUES ('5a000000-0000-4000-8000-0000000000aa', 'sa-existing', 'SA Existing', 'Europe/Skopje', ARRAY['1','2','3','4','5'], '09:00', '17:00');
INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on)
SELECT '5a000000-0000-4000-8000-0000000000aa', 'complimentary', current_date
WHERE NOT EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id = '5a000000-0000-4000-8000-0000000000aa');
CREATE TEMP TABLE sa_existing_sub AS
  SELECT to_jsonb(s) AS row FROM public.business_subscriptions s WHERE business_id = '5a000000-0000-4000-8000-0000000000aa';
GRANT SELECT ON sa_existing_sub TO PUBLIC;
CREATE TEMP TABLE sa_before AS
  SELECT (SELECT count(*) FROM public.business_subscriptions) AS subs,
         (SELECT count(*) FROM public.business_settings) AS biz;
GRANT SELECT ON sa_before TO PUBLIC;

-- Draft insert exactly like the Edge Function: service_role, no auth.uid().
INSERT INTO public.business_settings (business_id, business_slug, business_name, onboarding_completed_at, onboarding_step)
VALUES ('5a000000-0000-4000-8000-0000000000d1', 'sa-draft-one', 'SA Draft One', NULL, 1),
       ('5a000000-0000-4000-8000-0000000000d2', 'sa-draft-two', 'SA Draft Two', NULL, 1);
INSERT INTO public.business_onboarding (business_id, status, owner_email, owner_name, preferred_language)
VALUES ('5a000000-0000-4000-8000-0000000000d1', 'draft', 'sa-owner1@test.invalid', 'Owner One', 'mk'),
       ('5a000000-0000-4000-8000-0000000000d2', 'draft', 'sa-owner2@test.invalid', 'Owner Two', 'en');

SELECT pg_temp.ok('draft creation does not start a trial or subscription',
  NOT EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id IN
    ('5a000000-0000-4000-8000-0000000000d1', '5a000000-0000-4000-8000-0000000000d2')));
SELECT pg_temp.ok('draft creation does not consume trial eligibility',
  NOT EXISTS (SELECT 1 FROM public.business_trial_eligibility WHERE owner_user_id IN
    ('5a000000-0000-4000-8000-0000000000d1', '5a000000-0000-4000-8000-0000000000d2')));

SELECT pg_temp.expect_error('second open draft with the same e-mail (any case) is rejected',
  $$INSERT INTO public.business_settings (business_id, business_slug, business_name) VALUES ('5a000000-0000-4000-8000-0000000000d3', 'sa-draft-3', 'x');
    INSERT INTO public.business_onboarding (business_id, owner_email) VALUES ('5a000000-0000-4000-8000-0000000000d3', 'SA-Owner1@test.invalid')$$,
  'business_onboarding_open_email_uniq');
SELECT pg_temp.expect_error('unknown status is rejected',
  $$UPDATE public.business_onboarding SET status = 'trial' WHERE business_id = '5a000000-0000-4000-8000-0000000000d1'$$,
  'business_onboarding_status_ok');
SELECT pg_temp.expect_error('unknown language is rejected',
  $$UPDATE public.business_onboarding SET preferred_language = 'de' WHERE business_id = '5a000000-0000-4000-8000-0000000000d1'$$,
  'business_onboarding_language_ok');
SELECT pg_temp.expect_error('onboarding row requires an existing business',
  $$INSERT INTO public.business_onboarding (business_id, owner_email) VALUES ('5a000000-0000-4000-8000-0000000000ff', 'nobody@test.invalid')$$,
  'foreign key');

-- ---------------------------------------------------------------- helpers
SELECT pg_temp.ok('email status: existing account detected (case-insensitive)',
  (public._admin_owner_email_status(' SA-Existing@test.invalid ')->>'auth_user_id') = '5a000000-0000-4000-8000-0000000000aa');
SELECT pg_temp.ok('email status: open draft detected',
  (public._admin_owner_email_status('sa-owner1@test.invalid')->>'open_draft_business_id') = '5a000000-0000-4000-8000-0000000000d1'
  AND public._admin_owner_email_status('sa-owner1@test.invalid')->'auth_user_id' = 'null'::jsonb);
SELECT pg_temp.ok('email status: unknown e-mail is free',
  public._admin_owner_email_status('free@test.invalid') = '{"auth_user_id": null, "auth_confirmed": null, "open_draft_business_id": null}'::jsonb);
SELECT pg_temp.ok('owner account: none for a draft without invitation',
  public._admin_owner_account('5a000000-0000-4000-8000-0000000000d1') IS NULL);
SELECT pg_temp.ok('owner account: no password information returned',
  (public._admin_owner_account('5a000000-0000-4000-8000-0000000000aa')->>'exists')::boolean
  AND NOT (public._admin_owner_account('5a000000-0000-4000-8000-0000000000aa') ? 'encrypted_password')
  AND NOT (public._admin_owner_account('5a000000-0000-4000-8000-0000000000aa') ? 'has_password'));

-- ---------------------------------------------------------------- activation
-- Invitation (what send_invitation does): auth user with id = business_id, unconfirmed, no password.
INSERT INTO auth.users (id, email, invited_at) VALUES ('5a000000-0000-4000-8000-0000000000d2', 'sa-owner2@test.invalid', now());
UPDATE public.business_onboarding SET status = 'invited', invited_at = now(), invite_count = 1 WHERE business_id = '5a000000-0000-4000-8000-0000000000d2';
UPDATE public.business_settings SET onboarding_completed_at = now() WHERE business_id = '5a000000-0000-4000-8000-0000000000d2';

SELECT pg_temp.act_as(NULL);
SET LOCAL ROLE anon;
SELECT pg_temp.expect_error('anon cannot call activation',
  $$SELECT public.complete_business_activation()$$, 'permission denied');
SET LOCAL ROLE postgres;

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000aa');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ok('normal owner: activation is a no-op (not_prepared)',
  public.complete_business_activation()->>'status' = 'not_prepared');
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('normal owner: subscription unchanged',
  (SELECT to_jsonb(s) FROM public.business_subscriptions s WHERE business_id = '5a000000-0000-4000-8000-0000000000aa')
  = (SELECT row FROM sa_existing_sub));

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000d1');
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_error('draft (not invited) cannot activate',
  $$SELECT public.complete_business_activation()$$, 'not ready for activation');

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000d2');
SET LOCAL ROLE authenticated;
SELECT pg_temp.expect_error('invited but invitation link not opened (e-mail unconfirmed) → refused',
  $$SELECT public.complete_business_activation()$$, 'Open the invitation link first');

SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
UPDATE auth.users SET email_confirmed_at = now() WHERE id = '5a000000-0000-4000-8000-0000000000d2';
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('still no trial before activation',
  NOT EXISTS (SELECT 1 FROM public.business_subscriptions WHERE business_id = '5a000000-0000-4000-8000-0000000000d2'));

SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000aa');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ok('another owner cannot activate someone else''s business',
  public.complete_business_activation()->>'status' = 'not_prepared');
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
SELECT pg_temp.ok('…and d2 is still invited',
  (SELECT status FROM public.business_onboarding WHERE business_id = '5a000000-0000-4000-8000-0000000000d2') = 'invited');

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000d2');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE sa_act AS SELECT public.complete_business_activation() AS r;
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('activation succeeds', (SELECT r->>'status' FROM sa_act) = 'active');
SELECT pg_temp.ok('activation granted the trial', (SELECT (r->'trial'->>'granted')::boolean FROM sa_act));

SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
SELECT pg_temp.ok('onboarding row is active with activated_at',
  (SELECT status = 'active' AND activated_at IS NOT NULL FROM public.business_onboarding WHERE business_id = '5a000000-0000-4000-8000-0000000000d2'));
SELECT pg_temp.ok('trial subscription is 14 days from activation',
  (SELECT access_kind = 'trial' AND expires_on = (now() AT TIME ZONE 'UTC')::date + 14
   FROM public.business_subscriptions WHERE business_id = '5a000000-0000-4000-8000-0000000000d2'));
SELECT pg_temp.ok('onboarding_completed_at is set',
  (SELECT onboarding_completed_at IS NOT NULL FROM public.business_settings WHERE business_id = '5a000000-0000-4000-8000-0000000000d2'));

SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000d2');
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE sa_act2 AS SELECT public.complete_business_activation() AS r;
SET LOCAL ROLE postgres;
SELECT pg_temp.ok('second activation is idempotent', (SELECT (r->>'already')::boolean FROM sa_act2));
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
SELECT pg_temp.ok('no second trial / history row',
  (SELECT count(*) FROM public.business_subscriptions WHERE business_id = '5a000000-0000-4000-8000-0000000000d2') = 1
  AND (SELECT count(*) FROM public.business_trial_eligibility WHERE owner_user_id = '5a000000-0000-4000-8000-0000000000d2') = 1);

SELECT pg_temp.ok('the activated e-mail no longer blocks as an open draft',
  public._admin_owner_email_status('sa-owner2@test.invalid')->'open_draft_business_id' = 'null'::jsonb
  AND (public._admin_owner_email_status('sa-owner2@test.invalid')->>'auth_user_id') = '5a000000-0000-4000-8000-0000000000d2');

-- ---------------------------------------------------------------- RLS on owner data
SELECT pg_temp.act_as('5a000000-0000-4000-8000-0000000000d2');
SET LOCAL ROLE authenticated;
SELECT pg_temp.ok('activated owner sees own business through normal RLS',
  (SELECT count(*) FROM public.business_settings WHERE business_id = '5a000000-0000-4000-8000-0000000000d2') = 1);
SELECT pg_temp.expect_error('owner cannot read the onboarding table',
  $$SELECT * FROM public.business_onboarding$$, 'permission denied');

-- ---------------------------------------------------------------- existing data untouched
SET LOCAL ROLE postgres;
SELECT pg_temp.as_server();
SELECT pg_temp.ok('existing subscriptions unchanged apart from the new trial',
  (SELECT count(*) FROM public.business_subscriptions) = (SELECT subs FROM sa_before) + 1);
SELECT pg_temp.ok('existing subscription row identical',
  (SELECT to_jsonb(s) FROM public.business_subscriptions s WHERE business_id = '5a000000-0000-4000-8000-0000000000aa')
  = (SELECT row FROM sa_existing_sub));

-- Deleting a never-activated draft removes its onboarding row (cascade).
DELETE FROM public.business_settings WHERE business_id = '5a000000-0000-4000-8000-0000000000d1';
SELECT pg_temp.ok('draft delete cascades to onboarding',
  NOT EXISTS (SELECT 1 FROM public.business_onboarding WHERE business_id = '5a000000-0000-4000-8000-0000000000d1'));

SELECT pg_temp.ok('superseded password helper is not installed',
  to_regprocedure('public._admin_clear_unused_owner_password(uuid)') IS NULL);

DO $$ BEGIN RAISE NOTICE 'ALL ADMIN ONBOARDING TESTS PASSED'; END $$;
ROLLBACK;
