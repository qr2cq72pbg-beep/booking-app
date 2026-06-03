-- Client Notes (CRM): one private note per client per business (admin-only).
-- Run once in Supabase Dashboard → SQL Editor.
-- App also caches notes in localStorage; this table enables sync across devices.

CREATE TABLE IF NOT EXISTS public.business_client_notes (
  business_id uuid NOT NULL,
  client_key text NOT NULL,
  customer_note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, client_key),
  CONSTRAINT business_client_notes_business_fk
    FOREIGN KEY (business_id) REFERENCES public.business_settings (business_id) ON DELETE CASCADE
);

COMMENT ON TABLE public.business_client_notes IS 'Private admin notes per CRM client key (phone/email/name hash). Not exposed to customers.';
COMMENT ON COLUMN public.business_client_notes.client_key IS 'Stable client key from app: p:phone, e:email, or n:name';
COMMENT ON COLUMN public.business_client_notes.customer_note IS 'Single internal note text for this client';

CREATE INDEX IF NOT EXISTS business_client_notes_business_id_idx
  ON public.business_client_notes (business_id);

ALTER TABLE public.business_client_notes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS business_client_notes_owner_select ON public.business_client_notes;
CREATE POLICY business_client_notes_owner_select
  ON public.business_client_notes
  FOR SELECT
  TO authenticated
  USING (business_id = auth.uid());

DROP POLICY IF EXISTS business_client_notes_owner_insert ON public.business_client_notes;
CREATE POLICY business_client_notes_owner_insert
  ON public.business_client_notes
  FOR INSERT
  TO authenticated
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_client_notes_owner_update ON public.business_client_notes;
CREATE POLICY business_client_notes_owner_update
  ON public.business_client_notes
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS business_client_notes_owner_delete ON public.business_client_notes;
CREATE POLICY business_client_notes_owner_delete
  ON public.business_client_notes
  FOR DELETE
  TO authenticated
  USING (business_id = auth.uid());

-- Customers and anon must not access notes
REVOKE ALL ON public.business_client_notes FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.business_client_notes TO authenticated;
