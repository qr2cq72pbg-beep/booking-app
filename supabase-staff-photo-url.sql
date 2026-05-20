-- Optional profile image URL for staff (public Storage URL).
-- Safe to run once in Supabase SQL Editor. Keeps backward compatibility (NULL = no photo).

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS photo_url text;

COMMENT ON COLUMN public.staff_members.photo_url IS
  'Public URL for staff avatar (e.g. Supabase Storage). NULL = UI shows initials fallback.';

-- Photos are stored reusing your public `business-logos` bucket at:
--   {business_uuid}/staff/{staff_uuid}.{jpg|jpeg|png|webp}
-- If uploads fail with a policy error while business logos still work,
-- widen Storage RLS to allow that prefix (mirror your logo policy pattern).
