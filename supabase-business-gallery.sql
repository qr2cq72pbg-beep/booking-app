-- XBOOK: Business gallery images (admin upload, public/customer read).
-- Run in Supabase Dashboard -> SQL Editor.
-- Safe to re-run (idempotent).

BEGIN;

-- Storage bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'business-gallery',
  'business-gallery',
  true,
  3145728,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- Gallery table
CREATE TABLE IF NOT EXISTS public.business_gallery_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id uuid NOT NULL REFERENCES public.business_settings(business_id) ON DELETE CASCADE,
  image_url text NOT NULL,
  storage_path text,
  caption text,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS business_gallery_images_business_sort_idx
  ON public.business_gallery_images (business_id, sort_order, created_at);

ALTER TABLE public.business_gallery_images ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read business gallery images" ON public.business_gallery_images;
CREATE POLICY "Public read business gallery images"
ON public.business_gallery_images
FOR SELECT
TO anon, authenticated
USING (true);

DROP POLICY IF EXISTS "Business owner insert own gallery images" ON public.business_gallery_images;
CREATE POLICY "Business owner insert own gallery images"
ON public.business_gallery_images
FOR INSERT
TO authenticated
WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS "Business owner update own gallery images" ON public.business_gallery_images;
CREATE POLICY "Business owner update own gallery images"
ON public.business_gallery_images
FOR UPDATE
TO authenticated
USING (business_id = auth.uid())
WITH CHECK (business_id = auth.uid());

DROP POLICY IF EXISTS "Business owner delete own gallery images" ON public.business_gallery_images;
CREATE POLICY "Business owner delete own gallery images"
ON public.business_gallery_images
FOR DELETE
TO authenticated
USING (business_id = auth.uid());

-- Storage policies
DROP POLICY IF EXISTS "Public read business gallery storage" ON storage.objects;
CREATE POLICY "Public read business gallery storage"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'business-gallery');

DROP POLICY IF EXISTS "Business owner insert own gallery storage" ON storage.objects;
CREATE POLICY "Business owner insert own gallery storage"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'business-gallery'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Business owner update own gallery storage" ON storage.objects;
CREATE POLICY "Business owner update own gallery storage"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'business-gallery'
  AND (storage.foldername(name))[1] = auth.uid()::text
)
WITH CHECK (
  bucket_id = 'business-gallery'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

DROP POLICY IF EXISTS "Business owner delete own gallery storage" ON storage.objects;
CREATE POLICY "Business owner delete own gallery storage"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'business-gallery'
  AND (storage.foldername(name))[1] = auth.uid()::text
);

COMMIT;
