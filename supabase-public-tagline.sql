-- Optional subtitle shown on the public booking page hero (below business name).
-- Safe to run once in Supabase SQL Editor. NULL = default "Book your appointment online".

ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS public_tagline text;

COMMENT ON COLUMN public.business_settings.public_tagline IS
  'Short subtitle on public booking hero. NULL = default copy. About text uses business_description.';
