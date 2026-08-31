-- =============================================================================
-- XBOOK: Business-scoped customer identity links (analytics only)
-- Apply via linked CLI or Dashboard SQL Editor.
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE).
--
-- Maps a guest/legacy analytics key (p:/e:/n:) to a canonical authenticated
-- customer (u:{user_id}) WITHIN ONE business.
--
-- Does NOT:
--   rewrite bookings.customer_user_id
--   delete bookings
--   auto-merge by phone/email/name
--   change booking RLS or My Bookings
--   change Clients UI
--   store phone/email/name/DOB
-- =============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.business_customer_identity_links (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id                 uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  canonical_customer_user_id  uuid NOT NULL,
  legacy_analytics_key        text NOT NULL,
  reason                      text NOT NULL DEFAULT 'legacy_guest_history',
  created_at                  timestamptz NOT NULL DEFAULT now(),
  created_by                  uuid,
  revoked_at                  timestamptz,
  revoked_by                  uuid,
  CONSTRAINT business_customer_identity_links_legacy_key_not_blank
    CHECK (length(trim(legacy_analytics_key)) > 2),
  CONSTRAINT business_customer_identity_links_legacy_not_auth
    CHECK (left(lower(trim(legacy_analytics_key)), 2) <> 'u:'),
  CONSTRAINT business_customer_identity_links_legacy_guest_prefix
    CHECK (left(lower(trim(legacy_analytics_key)), 2) IN ('p:', 'e:', 'n:')),
  CONSTRAINT business_customer_identity_links_revoked_pair
    CHECK (
      (revoked_at IS NULL AND revoked_by IS NULL)
      OR (revoked_at IS NOT NULL)
    )
);

COMMENT ON TABLE public.business_customer_identity_links IS
  'Owner-managed analytics aliases: guest/legacy key → canonical auth customer, scoped to one business. Does not rewrite bookings.';
COMMENT ON COLUMN public.business_customer_identity_links.legacy_analytics_key IS
  'Raw guest analytics key (p:/e:/n:). Never a u: auth key. Never phone/email/name plaintext beyond the existing key encoding.';
COMMENT ON COLUMN public.business_customer_identity_links.canonical_customer_user_id IS
  'Authenticated customer_user_id that must already have a business_customers membership in this business.';
COMMENT ON COLUMN public.business_customer_identity_links.revoked_at IS
  'NULL = active. Unlink sets this; rows are kept for audit. Resolver ignores revoked rows.';

CREATE UNIQUE INDEX IF NOT EXISTS business_customer_identity_links_active_legacy_uidx
  ON public.business_customer_identity_links (business_id, legacy_analytics_key)
  WHERE revoked_at IS NULL;

CREATE INDEX IF NOT EXISTS business_customer_identity_links_business_canonical_idx
  ON public.business_customer_identity_links (business_id, canonical_customer_user_id)
  WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- Membership + key validation (insert/update of active rows)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_business_customer_identity_link_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text;
BEGIN
  v_key := nullif(trim(NEW.legacy_analytics_key), '');
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'Legacy analytics key is required.' USING ERRCODE = '22023';
  END IF;
  NEW.legacy_analytics_key := v_key;
  NEW.reason := nullif(trim(NEW.reason), '');
  IF NEW.reason IS NULL THEN
    NEW.reason := 'legacy_guest_history';
  END IF;

  IF NEW.business_id IS NULL OR NEW.canonical_customer_user_id IS NULL THEN
    RAISE EXCEPTION 'Business and canonical customer are required.' USING ERRCODE = '22023';
  END IF;

  IF left(lower(v_key), 2) = 'u:' THEN
    RAISE EXCEPTION 'Cannot link an authenticated customer key as a legacy alias.'
      USING ERRCODE = '22023';
  END IF;

  IF left(lower(v_key), 2) NOT IN ('p:', 'e:', 'n:') THEN
    RAISE EXCEPTION 'Legacy analytics key must be a guest identity (p:, e:, or n:).'
      USING ERRCODE = '22023';
  END IF;

  IF NEW.revoked_at IS NULL THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.business_customers bc
      WHERE bc.business_id = NEW.business_id
        AND bc.customer_user_id = NEW.canonical_customer_user_id
    ) THEN
      RAISE EXCEPTION 'Canonical customer is not a member of this business.'
        USING ERRCODE = '22023';
    END IF;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS business_customer_identity_links_assert
  ON public.business_customer_identity_links;
CREATE TRIGGER business_customer_identity_links_assert
  BEFORE INSERT OR UPDATE ON public.business_customer_identity_links
  FOR EACH ROW
  EXECUTE FUNCTION public._assert_business_customer_identity_link_row();

REVOKE ALL ON FUNCTION public._assert_business_customer_identity_link_row() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_business_customer_identity_link_row()
  FROM anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- RLS: owner tenant only. Customers cannot manage links.
-- ---------------------------------------------------------------------------
ALTER TABLE public.business_customer_identity_links ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_customer_identity_links_owner_select
  ON public.business_customer_identity_links;
CREATE POLICY business_customer_identity_links_owner_select
  ON public.business_customer_identity_links
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_identity_links_owner_insert
  ON public.business_customer_identity_links;
CREATE POLICY business_customer_identity_links_owner_insert
  ON public.business_customer_identity_links
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_identity_links_owner_update
  ON public.business_customer_identity_links;
CREATE POLICY business_customer_identity_links_owner_update
  ON public.business_customer_identity_links
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

REVOKE ALL ON public.business_customer_identity_links FROM PUBLIC;
REVOKE ALL ON public.business_customer_identity_links FROM anon;
GRANT SELECT, INSERT, UPDATE ON public.business_customer_identity_links TO authenticated;
-- No DELETE grant: unlink revokes in place.

-- ---------------------------------------------------------------------------
-- Shared resolver. Internal. No fuzzy/contact matching.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._resolve_business_analytics_customer_key(
  p_business_id uuid,
  p_raw_key text
)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $$
  SELECT CASE
    WHEN p_raw_key IS NULL OR btrim(p_raw_key) = '' THEN NULL
    WHEN left(p_raw_key, 2) = 'u:' THEN p_raw_key
    ELSE coalesce(
      (
        SELECT 'u:' || l.canonical_customer_user_id::text
        FROM public.business_customer_identity_links l
        WHERE l.business_id = p_business_id
          AND l.legacy_analytics_key = p_raw_key
          AND l.revoked_at IS NULL
        LIMIT 1
      ),
      p_raw_key
    )
  END;
$$;

COMMENT ON FUNCTION public._resolve_business_analytics_customer_key(uuid, text) IS
  'Analytics identity resolver: active business-scoped legacy key → u:{canonical_user_id}. u: keys unchanged. Revoked/wrong-business/no-row → raw key. No contact matching.';

REVOKE ALL ON FUNCTION public._resolve_business_analytics_customer_key(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._resolve_business_analytics_customer_key(uuid, text)
  FROM anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Owner-only link / unlink RPCs (no frontend required this phase)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.link_business_customer_identity(
  p_business_id uuid,
  p_canonical_customer_user_id uuid,
  p_legacy_analytics_key text,
  p_reason text DEFAULT 'legacy_guest_history'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := nullif(trim(coalesce(p_legacy_analytics_key, '')), '');
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_existing public.business_customer_identity_links%ROWTYPE;
  v_row public.business_customer_identity_links%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL OR p_canonical_customer_user_id IS NULL OR v_key IS NULL THEN
    RAISE EXCEPTION 'Business, canonical customer, and legacy key are required.'
      USING ERRCODE = '22023';
  END IF;

  IF v_reason IS NULL THEN
    v_reason := 'legacy_guest_history';
  END IF;

  IF left(lower(v_key), 2) = 'u:' THEN
    RAISE EXCEPTION 'Cannot link an authenticated customer key as a legacy alias.'
      USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.business_customer_identity_links l
  WHERE l.business_id = p_business_id
    AND l.legacy_analytics_key = v_key
    AND l.revoked_at IS NULL
  LIMIT 1;

  IF FOUND THEN
    IF v_existing.canonical_customer_user_id IS NOT DISTINCT FROM p_canonical_customer_user_id THEN
      RETURN jsonb_build_object(
        'ok', true,
        'id', v_existing.id,
        'already_linked', true
      );
    END IF;
    RAISE EXCEPTION 'This legacy identity is already linked to another customer in this business.'
      USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.business_customer_identity_links (
    business_id,
    canonical_customer_user_id,
    legacy_analytics_key,
    reason,
    created_by
  ) VALUES (
    p_business_id,
    p_canonical_customer_user_id,
    v_key,
    v_reason,
    auth.uid()
  )
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'id', v_row.id,
    'already_linked', false
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.unlink_business_customer_identity(
  p_business_id uuid,
  p_legacy_analytics_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := nullif(trim(coalesce(p_legacy_analytics_key, '')), '');
  v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_business_id IS NULL OR v_key IS NULL THEN
    RAISE EXCEPTION 'Business and legacy key are required.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.business_customer_identity_links l
  SET
    revoked_at = now(),
    revoked_by = auth.uid()
  WHERE l.business_id = p_business_id
    AND l.legacy_analytics_key = v_key
    AND l.revoked_at IS NULL
  RETURNING l.id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'revoked', false);
  END IF;

  RETURN jsonb_build_object('ok', true, 'revoked', true, 'id', v_id);
END;
$$;

COMMENT ON FUNCTION public.link_business_customer_identity(uuid, uuid, text, text) IS
  'Owner-only: create an active analytics identity link in this business. Does not rewrite bookings.';
COMMENT ON FUNCTION public.unlink_business_customer_identity(uuid, text) IS
  'Owner-only: revoke an active analytics identity link. Does not delete the audit row or touch bookings.';

REVOKE ALL ON FUNCTION public.link_business_customer_identity(uuid, uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.link_business_customer_identity(uuid, uuid, text, text) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.link_business_customer_identity(uuid, uuid, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.unlink_business_customer_identity(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unlink_business_customer_identity(uuid, text) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.unlink_business_customer_identity(uuid, text) TO authenticated;

COMMIT;
