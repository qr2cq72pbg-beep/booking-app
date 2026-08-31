-- =============================================================================
-- XBOOK: Canonical analytics customer population helper
-- Run once in Supabase Dashboard → SQL Editor, or via linked CLI.
-- Safe to re-run (CREATE OR REPLACE).
--
-- Adds:
--   public._business_analytics_customer_keys(uuid)
--     → analytics_customer_key, has_approved_membership, has_booking_history,
--       membership_status, identity_type
--
-- Population for one business_id:
--   approved CRM analytics keys
--   UNION
--   booking analytics keys for this business
--
-- Excludes rejected / pending / blocked CRM-only keys with no booking history.
-- Booking-history identities remain even if current membership is not approved.
-- Explicit business_customer_identity_links collapse a guest key to u:{uid}.
-- Does NOT fuzzy-merge u:{auth} with p:/e:/n: guest keys without a link.
--
-- Internal helper. Not granted to anon / authenticated / service_role.
-- Callers (SECURITY DEFINER report RPCs) already enforce auth.uid() = p_business_id.
--
-- Does NOT:
--   change RLS, booking writes, Completed Visit, identity helpers, Clients UI
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._business_analytics_customer_keys(
  p_business_id uuid
)
RETURNS TABLE (
  analytics_customer_key text,
  has_approved_membership boolean,
  has_booking_history boolean,
  membership_status text,
  identity_type text
)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  WITH booking_keys AS (
    SELECT DISTINCT public._resolve_business_analytics_customer_key(
      p_business_id,
      public._analytics_customer_key(
        b.customer_user_id,
        b.customer_phone,
        b.customer_email,
        b.customer_name
      )
    ) AS analytics_customer_key
    FROM public.bookings b
    WHERE b.business_id = p_business_id
      AND public._resolve_business_analytics_customer_key(
        p_business_id,
        public._analytics_customer_key(
          b.customer_user_id,
          b.customer_phone,
          b.customer_email,
          b.customer_name
        )
      ) IS NOT NULL
  ),
  crm AS (
    SELECT
      public._resolve_business_analytics_customer_key(
        p_business_id,
        CASE
          WHEN bc.customer_user_id IS NOT NULL THEN 'u:' || bc.customer_user_id::text
          ELSE nullif(trim(bc.client_key), '')
        END
      ) AS analytics_customer_key,
      bc.approval_status
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
  ),
  crm_agg AS (
    SELECT
      analytics_customer_key,
      bool_or(approval_status = 'approved') AS has_approved_membership,
      (
        ARRAY_AGG(approval_status ORDER BY
          CASE approval_status
            WHEN 'approved' THEN 1
            WHEN 'pending' THEN 2
            WHEN 'rejected' THEN 3
            WHEN 'blocked' THEN 4
            ELSE 5
          END,
          approval_status
        )
      )[1] AS membership_status
    FROM crm
    WHERE analytics_customer_key IS NOT NULL
    GROUP BY analytics_customer_key
  ),
  canonical AS (
    SELECT ca.analytics_customer_key
    FROM crm_agg ca
    WHERE ca.has_approved_membership
    UNION
    SELECT bk.analytics_customer_key
    FROM booking_keys bk
  )
  SELECT
    c.analytics_customer_key,
    coalesce(ca.has_approved_membership, false) AS has_approved_membership,
    (bk.analytics_customer_key IS NOT NULL) AS has_booking_history,
    ca.membership_status,
    CASE
      WHEN c.analytics_customer_key LIKE 'u:%' THEN 'auth'
      ELSE 'guest'
    END AS identity_type
  FROM canonical c
  LEFT JOIN crm_agg ca
    ON ca.analytics_customer_key = c.analytics_customer_key
  LEFT JOIN booking_keys bk
    ON bk.analytics_customer_key = c.analytics_customer_key
$$;

COMMENT ON FUNCTION public._business_analytics_customer_keys(uuid) IS
  'Internal canonical analytics population for one business: approved CRM keys UNION this-business booking keys, after explicit identity-link resolution. Excludes rejected/pending/blocked CRM-only. Does not fuzzy-merge auth and guest identities.';

REVOKE ALL ON FUNCTION public._business_analytics_customer_keys(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._business_analytics_customer_keys(uuid) FROM anon, authenticated, service_role;

COMMIT;
