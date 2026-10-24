-- =============================================================================
-- XBOOK Phase 4E — read-only checks AFTER booking-enforcement is applied.
-- Does not write production bookings or subscription data.
-- Does not change Angel Touch or Test Barber.
-- =============================================================================

-- 1) Objects exist; booking RPC identities still present
SELECT
  to_regprocedure('public._assert_business_can_accept_bookings(uuid)') AS assert_fn,
  to_regprocedure('public._enforce_bookings_subscription()') AS trigger_fn,
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking,
  to_regprocedure('public._create_booking_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_inner,
  to_regprocedure('public.create_recurring_bookings(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)') AS create_recurring,
  to_regprocedure('public._create_recurring_bookings_pre_subscription(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)') AS recurring_inner,
  to_regprocedure('public.reschedule_booking_by_manage_token(text,date,time)') AS reschedule_time,
  to_regprocedure('public.reschedule_booking_by_manage_token(text,date,text)') AS reschedule_text;

-- 2) Trigger attached to bookings INSERT/UPDATE
SELECT tgname, tgenabled, pg_get_triggerdef(oid) AS def
FROM pg_trigger
WHERE tgrelid = 'public.bookings'::regclass
  AND tgname = 'bookings_enforce_subscription';
-- Expect one enabled BEFORE INSERT OR UPDATE trigger.

-- 3) Clients cannot call the assert helper. Booking RPCs keep previous EXECUTE.
SELECT
  'anon' AS role_name,
  has_function_privilege('anon', 'public._assert_business_can_accept_bookings(uuid)', 'EXECUTE') AS assert_exec,
  has_function_privilege('anon', 'public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)', 'EXECUTE') AS create_exec,
  has_function_privilege('anon', 'public.reschedule_booking_by_manage_token(text,date,time)', 'EXECUTE') AS reschedule_exec
UNION ALL
SELECT
  'authenticated',
  has_function_privilege('authenticated', 'public._assert_business_can_accept_bookings(uuid)', 'EXECUTE'),
  has_function_privilege('authenticated', 'public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)', 'EXECUTE'),
  has_function_privilege('authenticated', 'public.reschedule_booking_by_manage_token(text,date,time)', 'EXECUTE');
-- Expect anon: false, false, true
-- Expect authenticated: false, true, true

-- 4) Wrapper source contains the gate
SELECT
  pg_get_functiondef('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)'::regprocedure)
    LIKE '%_assert_business_can_accept_bookings%' AS create_gated,
  pg_get_functiondef('public.create_recurring_bookings(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text,text,integer)'::regprocedure)
    LIKE '%_assert_business_can_accept_bookings%' AS recurring_gated,
  pg_get_functiondef('public.reschedule_booking_by_manage_token(text,date,time)'::regprocedure)
    LIKE '%_assert_business_can_accept_bookings%' AS reschedule_gated,
  pg_get_functiondef('public._assert_business_can_accept_bookings(uuid)'::regprocedure)
    LIKE '%FOR UPDATE%' AS locks_rows;
-- Expect true, true, true, true

-- 5) LIVE businesses unchanged by this file (no entitlement writes)
SELECT
  bs.business_slug,
  sub.access_kind,
  sub.package_id,
  sub.expires_on,
  sub.expires_at,
  el.consumed_reason
FROM public.business_settings bs
LEFT JOIN public.business_subscriptions sub ON sub.business_id = bs.business_id
LEFT JOIN public.business_trial_eligibility el ON el.owner_user_id = bs.business_id
WHERE bs.business_slug IN ('angel-touch', 'gorge123')
ORDER BY bs.business_slug;
-- Expect Angel Touch complimentary unlimited; Test Barber paid as currently assigned.

-- 6) Existing booking counts are not rewritten by apply
SELECT count(*) AS bookings_total FROM public.bookings;
