-- =============================================================================
-- XBook STEP 6C: is_business_slug_taken
-- Boolean-only slug conflict check for admin onboarding/customize.
--
-- DO NOT drop public_can_read_business_settings in this step (apply RPC first;
-- drop only after frontend uses this RPC and smoke tests pass).
-- DO NOT modify other RLS policies.
-- DO NOT create any new business_slug index (UNIQUE already exists).
--
-- Returns true iff another business already owns the normalized slug.
-- Never returns business rows, names, emails, or settings.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.is_business_slug_taken(
  p_business_slug text,
  p_exclude_business_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slug text;
  v_taken boolean := false;
BEGIN
  -- Match index.html normalizeBusinessSlug:
  -- trim → lower → replace non [a-z0-9]+ with "-" → strip edge "-" → max 60
  v_slug := left(
    trim(both '-' FROM
      regexp_replace(
        lower(trim(coalesce(p_business_slug, ''))),
        '[^a-z0-9]+',
        '-',
        'g'
      )
    ),
    60
  );

  IF v_slug IS NULL OR length(v_slug) = 0 THEN
    RETURN false;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.business_settings bs
    WHERE bs.business_slug = v_slug
      AND (p_exclude_business_id IS NULL OR bs.business_id IS DISTINCT FROM p_exclude_business_id)
  )
  INTO v_taken;

  RETURN coalesce(v_taken, false);
END;
$$;

COMMENT ON FUNCTION public.is_business_slug_taken(text, uuid) IS
  'STEP 6C: Returns true if normalized business_slug is already used by another business. Boolean only; no row data exposed. Admin onboarding/settings slug checks.';

REVOKE ALL ON FUNCTION public.is_business_slug_taken(text, uuid) FROM PUBLIC;

-- Admin-only use (onboarding / settings). Anon not required.
GRANT EXECUTE ON FUNCTION public.is_business_slug_taken(text, uuid)
  TO authenticated;

COMMIT;

-- =============================================================================
-- Tests (run after APPLY; replace placeholders)
-- =============================================================================
-- Own slug (exclude self) → false:
--   SELECT public.is_business_slug_taken('your-slug', 'YOUR-BUSINESS-UUID'::uuid);
--
-- Taken by another → true:
--   SELECT public.is_business_slug_taken('other-business-slug', 'YOUR-BUSINESS-UUID'::uuid);
--
-- Empty → false:
--   SELECT public.is_business_slug_taken('', 'YOUR-BUSINESS-UUID'::uuid);
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.is_business_slug_taken(text, uuid);
