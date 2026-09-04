-- =============================================================================
-- XBOOK Phase 3A.1 — Lock down public.ensure_business_customer
-- Apply AFTER supabase-business-customer-crm-actions.sql
-- Safe to re-run.
--
-- Canonical EXECUTE policy for ensure_business_customer:
--   INTERNAL helper. Not a customer/owner PostgREST RPC.
--   REVOKE from PUBLIC, anon, authenticated.
--   GRANT service_role only (backend automation).
--   Function owner (postgres) retains EXECUTE for nested SECURITY DEFINER
--   callers: _ensure_business_customer_membership (guest path),
--   _upsert_business_customer_approval_row, _ensure_guest_business_customer_from_key.
--
-- Owner frontend (Add Booking / approval fallback) uses:
--   public.ensure_business_customer_for_owner
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Owner-only wrapper — same args/return as the internal helper
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_business_customer_for_owner(
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
BEGIN
  IF p_business_id IS NULL
     OR auth.uid() IS NULL
     OR auth.uid() IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  RETURN public.ensure_business_customer(
    p_business_id,
    p_phone,
    p_email,
    p_name
  );
END;
$$;

COMMENT ON FUNCTION public.ensure_business_customer_for_owner(uuid, text, text, text) IS
  'Owner-only guest/manual CRM upsert. auth.uid() must equal p_business_id. '
  'Wraps internal ensure_business_customer. Does not assign customer_user_id.';

REVOKE ALL ON FUNCTION public.ensure_business_customer_for_owner(uuid, text, text, text)
  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_business_customer_for_owner(uuid, text, text, text)
  FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.ensure_business_customer_for_owner(uuid, text, text, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 2) Internal helper — no direct authenticated / anon EXECUTE
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  TO service_role;

COMMENT ON FUNCTION public.ensure_business_customer(uuid, text, text, text) IS
  'INTERNAL guest/manual CRM upsert by client_key. Not a PostgREST RPC. '
  'SECURITY DEFINER, search_path=public. No owner check (guest booking helpers '
  'call this with customer or NULL auth.uid()). EXECUTE: service_role + function '
  'owner only. Owners use ensure_business_customer_for_owner. '
  'Does not assign customer_user_id. Does not overwrite linked identity fields.';

COMMIT;
