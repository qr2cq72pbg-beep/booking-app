-- =============================================================================
-- Allow authenticated business owners to DELETE their own bookings
-- Run once: Supabase Dashboard → SQL Editor → New query → Run
--
-- Symptom without this: admin Delete shows confirm + success UI, but the row
-- stays in the table (PostgREST returns no error when RLS filters out DELETE).
-- =============================================================================

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bookings_delete_own_business" ON public.bookings;
CREATE POLICY "bookings_delete_own_business"
  ON public.bookings
  FOR DELETE
  TO authenticated
  USING (business_id = auth.uid());
