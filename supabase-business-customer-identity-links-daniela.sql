-- =============================================================================
-- XBOOK: One-time Daniela #002 analytics identity link
-- Current business only. Idempotent. No PII. No booking writes.
--
-- Looks up customer_number = 2 (authenticated) and links that row's client_key
-- (legacy p: analytics identity) to its customer_user_id.
-- =============================================================================

BEGIN;

INSERT INTO public.business_customer_identity_links (
  business_id,
  canonical_customer_user_id,
  legacy_analytics_key,
  reason,
  created_by
)
SELECT
  bc.business_id,
  bc.customer_user_id,
  bc.client_key,
  'legacy_guest_history',
  bc.business_id
FROM public.business_customers bc
WHERE bc.business_id = '4fb21268-7a4d-4c62-8c0a-30f7571eac41'
  AND bc.customer_number = 2
  AND bc.customer_user_id IS NOT NULL
  AND bc.client_key LIKE 'p:%'
  AND NOT EXISTS (
    SELECT 1
    FROM public.business_customer_identity_links l
    WHERE l.business_id = bc.business_id
      AND l.legacy_analytics_key = bc.client_key
      AND l.revoked_at IS NULL
  );

COMMIT;
