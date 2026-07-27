-- =============================================================================
-- Allow authenticated business owners to UPDATE their own bookings (cancel, etc.)
-- Run once: Supabase Dashboard → SQL Editor → New query → Run
--
-- Symptom without this: admin Cancel shows
--   "Status update error: Cannot coerce the result to a single JSON object"
-- because PostgREST returns 0 rows when RLS filters out UPDATE.
-- =============================================================================

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bookings_update_own_business" ON public.bookings;
CREATE POLICY "bookings_update_own_business"
  ON public.bookings
  FOR UPDATE
  TO authenticated
  USING (business_id = auth.uid())
  WITH CHECK (business_id = auth.uid());
