-- =============================================================================
-- XBOOK V1 — staff_time_off validation notes
-- Read-only / optional checks AFTER supabase-staff-time-off-v1.sql is applied.
-- Does not write production data. Does not cancel bookings.
-- =============================================================================

-- Objects exist
SELECT
  to_regclass('public.staff_time_off') AS staff_time_off_table,
  to_regprocedure('public._staff_time_off_overlaps(uuid,uuid,date,integer,integer)') AS overlap_helper,
  to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking,
  to_regprocedure('public._create_booking_pre_time_off(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') AS create_booking_inner,
  to_regprocedure('public._assert_booking_slot_available(uuid,uuid,date,time,uuid,uuid)') AS assert_slot,
  to_regprocedure('public._assert_booking_slot_available_pre_time_off(uuid,uuid,date,time,uuid,uuid)') AS assert_slot_inner,
  to_regprocedure('public.list_staff_time_off(uuid)') AS list_rpc,
  to_regprocedure('public.upsert_staff_time_off(uuid,date,date,text,text,uuid,time,time)') AS upsert_rpc,
  to_regprocedure('public.delete_staff_time_off(uuid)') AS delete_rpc,
  to_regprocedure('public.get_staff_time_off_conflicts(uuid,date,date,time,time,uuid)') AS conflicts_rpc,
  to_regprocedure('public.get_public_staff_unavailability(uuid,date,date)') AS public_rpc;

-- Public function must not expose note / type
SELECT
  p.proname,
  pg_get_function_result(p.oid) AS result
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_public_staff_unavailability';

-- Trigger present
SELECT tgname
FROM pg_trigger
WHERE tgrelid = 'public.bookings'::regclass
  AND tgname = 'bookings_enforce_staff_time_off';

-- Inner booking body preserved (wrapper must not be the only create_booking)
SELECT
  CASE
    WHEN to_regprocedure('public._create_booking_pre_time_off(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') IS NOT NULL
     AND to_regprocedure('public.create_booking(uuid,uuid,date,time,text,text,text,text,uuid,uuid,text)') IS NOT NULL
    THEN 'create_booking wrapper + inner body present'
    ELSE 'MISSING wrap — do not continue'
  END AS create_booking_wrap_status;
