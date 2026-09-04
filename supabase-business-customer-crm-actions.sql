-- =============================================================================
-- XBOOK Phase 3A: CRM Actions backend — VIP + internal customer notes
-- Apply via linked CLI or Dashboard SQL Editor AFTER:
--   supabase-business-customers.sql
--   supabase-safe-customer-identity-linking.sql
--   supabase-business-customer-identity-links.sql
--
-- Safe to re-run (IF NOT EXISTS / CREATE OR REPLACE / DROP POLICY).
--
-- Reuses live public.business_customers.is_vip. Does NOT add internal_notes
-- to business_customers (membership RPCs return ROWTYPE; customer SELECT exists).
--
-- Does NOT:
--   change booking rows, identity-link semantics, analytics formulas
--   add Customer Detail / Clients UI
--   add a VIP analytics segment
--   add auth.uid() = business_id to ensure_business_customer
--     (would break guest booking CRM upsert via SECURITY DEFINER callers)
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 0) ensure_business_customer is INTERNAL (Phase 3A.1).
--    Direct authenticated EXECUTE is revoked. Nested SECURITY DEFINER helpers
--    still call it as function owner. Owner frontend uses
--    ensure_business_customer_for_owner.
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ensure_business_customer(uuid, text, text, text)
  TO service_role;

COMMENT ON FUNCTION public.ensure_business_customer(uuid, text, text, text) IS
  'INTERNAL guest/manual CRM upsert by client_key. Not a PostgREST RPC. '
  'SECURITY DEFINER, search_path=public. EXECUTE: service_role + function owner. '
  'Owners use ensure_business_customer_for_owner. '
  'Does not assign customer_user_id. Does not overwrite identity fields once linked.';

-- -----------------------------------------------------------------------------
-- 1) Composite uniqueness so notes can FK (business_customer_id, business_id)
-- -----------------------------------------------------------------------------
ALTER TABLE public.business_customers
  DROP CONSTRAINT IF EXISTS business_customers_id_business_uniq;

ALTER TABLE public.business_customers
  ADD CONSTRAINT business_customers_id_business_uniq
  UNIQUE (id, business_id);

-- -----------------------------------------------------------------------------
-- 2) Internal notes — one current note per CRM customer, owner-private
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.business_customer_internal_notes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id           uuid NOT NULL
    REFERENCES public.business_settings (business_id) ON DELETE CASCADE,
  business_customer_id  uuid NOT NULL,
  note                  text NOT NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            uuid,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid,
  CONSTRAINT business_customer_internal_notes_customer_uniq
    UNIQUE (business_customer_id),
  CONSTRAINT business_customer_internal_notes_customer_business_fk
    FOREIGN KEY (business_customer_id, business_id)
    REFERENCES public.business_customers (id, business_id)
    ON DELETE CASCADE,
  CONSTRAINT business_customer_internal_notes_note_len
    CHECK (char_length(note) <= 2000),
  CONSTRAINT business_customer_internal_notes_note_not_blank
    CHECK (length(btrim(note)) > 0)
);

COMMENT ON TABLE public.business_customer_internal_notes IS
  'Owner-private single current CRM note per business_customers.id. Never exposed to customers. No phone/email/name/DOB/analytics key stored.';
COMMENT ON COLUMN public.business_customer_internal_notes.business_customer_id IS
  'Canonical CRM row. One note per customer; empty write deletes this row.';
COMMENT ON COLUMN public.business_customer_internal_notes.note IS
  'Trimmed free-text, 1–2000 characters. Whitespace-only is treated as clear.';

CREATE INDEX IF NOT EXISTS business_customer_internal_notes_business_id_idx
  ON public.business_customer_internal_notes (business_id);

ALTER TABLE public.business_customer_internal_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_customer_internal_notes_owner_select
  ON public.business_customer_internal_notes;
CREATE POLICY business_customer_internal_notes_owner_select
  ON public.business_customer_internal_notes
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_internal_notes_owner_insert
  ON public.business_customer_internal_notes;
CREATE POLICY business_customer_internal_notes_owner_insert
  ON public.business_customer_internal_notes
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_internal_notes_owner_update
  ON public.business_customer_internal_notes;
CREATE POLICY business_customer_internal_notes_owner_update
  ON public.business_customer_internal_notes
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_customer_internal_notes_owner_delete
  ON public.business_customer_internal_notes;
CREATE POLICY business_customer_internal_notes_owner_delete
  ON public.business_customer_internal_notes
  FOR DELETE
  TO authenticated
  USING (business_id = auth.uid());

REVOKE ALL ON public.business_customer_internal_notes FROM PUBLIC;
REVOKE ALL ON public.business_customer_internal_notes FROM anon;
REVOKE ALL ON public.business_customer_internal_notes FROM authenticated;
-- RPC-only. Table owner / SECURITY DEFINER writers retain access.

-- -----------------------------------------------------------------------------
-- 3) Owner-gated canonical CRM resolver (analytics key → business_customers row)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._crm_action_require_owner(p_business_id uuid)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
BEGIN
  IF p_business_id IS NULL OR auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id THEN
    RAISE EXCEPTION 'Not authorized' USING ERRCODE = '42501';
  END IF;
END;
$$;

COMMENT ON FUNCTION public._crm_action_require_owner(uuid) IS
  'Raises 42501 unless auth.uid() = p_business_id.';

REVOKE ALL ON FUNCTION public._crm_action_require_owner(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._crm_action_require_owner(uuid)
  FROM anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._ensure_guest_business_customer_from_key(
  p_business_id uuid,
  p_guest_key text
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text := nullif(btrim(coalesce(p_guest_key, '')), '');
  v_prefix text;
  v_rest text;
  v_row public.business_customers%ROWTYPE;
BEGIN
  IF p_business_id IS NULL OR v_key IS NULL THEN
    RETURN NULL;
  END IF;

  v_prefix := left(v_key, 2);
  v_rest := substr(v_key, 3);
  IF v_rest IS NULL OR btrim(v_rest) = '' THEN
    RETURN NULL;
  END IF;

  IF v_prefix = 'p:' THEN
    v_row := public.ensure_business_customer(p_business_id, v_rest, NULL, NULL);
  ELSIF v_prefix = 'e:' THEN
    v_row := public.ensure_business_customer(p_business_id, NULL, v_rest, NULL);
  ELSIF v_prefix = 'n:' THEN
    v_row := public.ensure_business_customer(p_business_id, NULL, NULL, v_rest);
  ELSE
    RETURN NULL;
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public._ensure_guest_business_customer_from_key(uuid, text) IS
  'Owner-context guest CRM ensure from a p:/e:/n: analytics key. No fuzzy merge. No u: keys. Does not rewrite bookings.';

REVOKE ALL ON FUNCTION public._ensure_guest_business_customer_from_key(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._ensure_guest_business_customer_from_key(uuid, text)
  FROM anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public._resolve_business_customer_for_crm_action(
  p_business_id uuid,
  p_customer_key text,
  p_ensure boolean DEFAULT false
)
RETURNS public.business_customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_raw text := nullif(btrim(coalesce(p_customer_key, '')), '');
  v_resolved text;
  v_uid uuid;
  v_row public.business_customers%ROWTYPE;
BEGIN
  PERFORM public._crm_action_require_owner(p_business_id);

  IF v_raw IS NULL THEN
    RETURN NULL;
  END IF;

  v_resolved := public._resolve_business_analytics_customer_key(p_business_id, v_raw);
  IF v_resolved IS NULL OR btrim(v_resolved) = '' THEN
    RETURN NULL;
  END IF;

  IF left(v_resolved, 2) = 'u:' THEN
    BEGIN
      v_uid := substr(v_resolved, 3)::uuid;
    EXCEPTION
      WHEN invalid_text_representation THEN
        RETURN NULL;
    END;

    SELECT *
    INTO v_row
    FROM public.business_customers bc
    WHERE bc.business_id = p_business_id
      AND bc.customer_user_id = v_uid
    ORDER BY bc.created_at ASC, bc.id ASC
    LIMIT 1;

    -- Never fabricate an auth membership or a u: client_key via guest ensure.
    RETURN v_row;
  END IF;

  SELECT *
  INTO v_row
  FROM public.business_customers bc
  WHERE bc.business_id = p_business_id
    AND bc.client_key = v_resolved
  ORDER BY bc.created_at ASC, bc.id ASC
  LIMIT 1;

  IF FOUND THEN
    RETURN v_row;
  END IF;

  IF coalesce(p_ensure, false) THEN
    RETURN public._ensure_guest_business_customer_from_key(p_business_id, v_resolved);
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._resolve_business_customer_for_crm_action(uuid, text, boolean) IS
  'Owner-only: analytics key → one business_customers row in this business. Identity links collapse guest keys to u:{uid}. Guest ensure (p_ensure) uses existing ensure_business_customer only. No fuzzy merge. No booking writes.';

REVOKE ALL ON FUNCTION public._resolve_business_customer_for_crm_action(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._resolve_business_customer_for_crm_action(uuid, text, boolean)
  FROM anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4) VIP write
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_business_customer_vip(
  p_business_id uuid,
  p_customer_key text,
  p_is_vip boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
BEGIN
  PERFORM public._crm_action_require_owner(p_business_id);

  IF p_is_vip IS NULL THEN
    RAISE EXCEPTION 'is_vip is required.' USING ERRCODE = '22023';
  END IF;

  v_row := public._resolve_business_customer_for_crm_action(
    p_business_id, p_customer_key, true
  );

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Customer not found.' USING ERRCODE = 'P0001';
  END IF;

  UPDATE public.business_customers
  SET
    is_vip = p_is_vip,
    updated_at = now()
  WHERE id = v_row.id
    AND business_id = p_business_id
  RETURNING * INTO v_row;

  RETURN jsonb_build_object(
    'ok', true,
    'business_customer_id', v_row.id,
    'is_vip', v_row.is_vip
  );
END;
$$;

COMMENT ON FUNCTION public.set_business_customer_vip(uuid, text, boolean) IS
  'Owner-only VIP write. Resolves analytics key to canonical business_customers.id. Reuses is_vip. No booking writes.';

REVOKE ALL ON FUNCTION public.set_business_customer_vip(uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_business_customer_vip(uuid, text, boolean)
  FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.set_business_customer_vip(uuid, text, boolean)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 5) Notes write — empty/whitespace deletes the row
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_business_customer_internal_notes(
  p_business_id uuid,
  p_customer_key text,
  p_note text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
  v_note text := btrim(coalesce(p_note, ''));
  v_updated_at timestamptz;
BEGIN
  PERFORM public._crm_action_require_owner(p_business_id);

  IF char_length(v_note) > 2000 THEN
    RAISE EXCEPTION 'Note is too long.' USING ERRCODE = '22023';
  END IF;

  v_row := public._resolve_business_customer_for_crm_action(
    p_business_id, p_customer_key, true
  );

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Customer not found.' USING ERRCODE = 'P0001';
  END IF;

  IF v_note = '' THEN
    DELETE FROM public.business_customer_internal_notes n
    WHERE n.business_id = p_business_id
      AND n.business_customer_id = v_row.id;

    RETURN jsonb_build_object(
      'ok', true,
      'business_customer_id', v_row.id,
      'note', NULL,
      'updated_at', NULL
    );
  END IF;

  INSERT INTO public.business_customer_internal_notes (
    business_id,
    business_customer_id,
    note,
    created_by,
    updated_by
  ) VALUES (
    p_business_id,
    v_row.id,
    v_note,
    auth.uid(),
    auth.uid()
  )
  ON CONFLICT (business_customer_id) DO UPDATE
  SET
    note = EXCLUDED.note,
    updated_at = now(),
    updated_by = auth.uid()
  RETURNING updated_at INTO v_updated_at;

  RETURN jsonb_build_object(
    'ok', true,
    'business_customer_id', v_row.id,
    'note', v_note,
    'updated_at', v_updated_at
  );
END;
$$;

COMMENT ON FUNCTION public.update_business_customer_internal_notes(uuid, text, text) IS
  'Owner-only internal note upsert. Max 2000 chars. Empty/whitespace deletes the note row.';

REVOKE ALL ON FUNCTION public.update_business_customer_internal_notes(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_business_customer_internal_notes(uuid, text, text)
  FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.update_business_customer_internal_notes(uuid, text, text)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- 6) Notes read — does not create CRM rows
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_customer_internal_notes(
  p_business_id uuid,
  p_customer_key text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.business_customers%ROWTYPE;
  v_note text;
  v_updated_at timestamptz;
BEGIN
  PERFORM public._crm_action_require_owner(p_business_id);

  v_row := public._resolve_business_customer_for_crm_action(
    p_business_id, p_customer_key, false
  );

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'note', NULL,
      'updated_at', NULL
    );
  END IF;

  SELECT n.note, n.updated_at
  INTO v_note, v_updated_at
  FROM public.business_customer_internal_notes n
  WHERE n.business_id = p_business_id
    AND n.business_customer_id = v_row.id;

  RETURN jsonb_build_object(
    'ok', true,
    'business_customer_id', v_row.id,
    'note', v_note,
    'updated_at', v_updated_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_business_customer_internal_notes(uuid, text) IS
  'Owner-only internal note read. Missing note → note/updated_at null. Does not create CRM rows.';

REVOKE ALL ON FUNCTION public.get_business_customer_internal_notes(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_business_customer_internal_notes(uuid, text)
  FROM anon, service_role;
GRANT EXECUTE ON FUNCTION public.get_business_customer_internal_notes(uuid, text)
  TO authenticated;

COMMIT;
