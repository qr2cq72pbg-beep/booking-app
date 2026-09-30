-- =============================================================================
-- XBOOK SECURITY HARDENING — V4-1 / V4-2 ONLY
-- Linked project: sdqothuulzeczcncyfqd
-- Safe to re-run (REVOKE is idempotent).
--
-- V4-1: revoke client EXECUTE on internal helpers (not frontend RPCs).
-- V4-2: revoke anon/PUBLIC EXECUTE on authenticated-only RPCs.
--
-- Does NOT change: function bodies, V1-V3, bookings.manage_token privileges,
-- manage-token authorization, booking create/reschedule/cancel logic, Paddle,
-- or index.html.
--
-- Nested SECURITY DEFINER callers are owned by postgres and keep EXECUTE
-- as function owner. Direct client EXECUTE is not required for those calls.
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- V4-1 — Internal helper EXECUTE lockdown
-- PUBLIC / anon / authenticated: NO EXECUTE
-- postgres (owner) and existing service_role grants: unchanged
-- No new GRANTs.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._insert_authenticated_business_customer(uuid, uuid, text, text, text, text, boolean, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._fill_empty_business_customer_identity(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._allocate_business_customer_number(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._upsert_business_customer_approval_row(uuid, uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._lookup_business_customer_row(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trusted_customer_account_email(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trusted_customer_account_phone(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trusted_customer_account_name(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._evaluate_client_booking_approval(uuid, uuid, text, text, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._generate_manage_token() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._assert_create_booking_caller(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._assert_client_approval_for_booking(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._assert_client_booking_limits(uuid, date, uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._assert_booking_slot_available(uuid, uuid, date, time, uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._resolve_booking_customer_user_id(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._client_has_past_business_bookings(uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._is_business_date_closed(uuid, date) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- V4-2 — Authenticated-only RPC EXECUTE lockdown
-- Revoke PUBLIC + anon. Keep authenticated. Keep existing service_role.
-- Does NOT touch public catalog RPCs or manage-token RPCs.
-- ---------------------------------------------------------------------------

REVOKE ALL ON FUNCTION public.register_customer_business_membership(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_business_customer_approval_status(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_customer_complete_profile(text, text, text, date, text, text, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_customer_identity_profile(text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_customer_complete_profile() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sync_missing_business_customers(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.upsert_customer_push_token(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.upsert_business_closed_days_manual(date[], text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.check_client_booking_approval(uuid, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.count_customer_notification_inbox_unread(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_customer_notification_inbox(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.mark_customer_notification_read(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_business_notification_history() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_business_notification_detail(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_business_notification(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_business_notification_history() FROM PUBLIC, anon;

-- Hygiene only: remove PUBLIC from manage-token reschedule overloads.
-- anon EXECUTE is intentionally KEPT for logged-out email/SMS manage links.
REVOKE ALL ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) FROM PUBLIC;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply)
-- =============================================================================
-- BEGIN;
-- GRANT EXECUTE ON FUNCTION public._ensure_business_customer_membership(uuid, uuid, text, text, text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._insert_authenticated_business_customer(uuid, uuid, text, text, text, text, boolean, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._fill_empty_business_customer_identity(uuid, text, text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._allocate_business_customer_number(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._upsert_business_customer_approval_row(uuid, uuid, text, text, text, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._lookup_business_customer_row(uuid, uuid, text, text, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._trusted_customer_account_email(uuid) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._trusted_customer_account_phone(uuid, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._trusted_customer_account_name(uuid, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._evaluate_client_booking_approval(uuid, uuid, text, text, text, boolean) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._generate_manage_token() TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._assert_create_booking_caller(uuid, uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._assert_client_approval_for_booking(uuid, uuid, text, text, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._assert_client_booking_limits(uuid, date, uuid, text, text, uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._assert_booking_slot_available(uuid, uuid, date, time, uuid, uuid) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._resolve_booking_customer_user_id(uuid, uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._client_has_past_business_bookings(uuid, uuid, text, text, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public._is_business_date_closed(uuid, date) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.register_customer_business_membership(uuid, text, text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.set_business_customer_approval_status(text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.save_customer_complete_profile(text, text, text, date, text, text, uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.save_customer_identity_profile(text, text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.get_customer_complete_profile() TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.sync_missing_business_customers(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.upsert_customer_push_token(text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.upsert_business_closed_days_manual(date[], text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.check_client_booking_approval(uuid, text, text, text) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.count_customer_notification_inbox_unread(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.list_customer_notification_inbox(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.mark_customer_notification_read(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.list_business_notification_history() TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.get_business_notification_detail(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.delete_business_notification(uuid) TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.clear_business_notification_history() TO anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, text) TO PUBLIC, anon, authenticated, service_role;
-- GRANT EXECUTE ON FUNCTION public.reschedule_booking_by_manage_token(text, date, time) TO PUBLIC, anon, authenticated, service_role;
-- COMMIT;
