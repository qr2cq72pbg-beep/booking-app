-- =============================================================================
-- XBook STEP 6A: get_public_business_settings (FINAL — live types)
-- Bounded public business profile/settings for ONE business (by id OR slug).
--
-- DO NOT drop public_can_read_business_settings in this step.
-- DO NOT modify business_settings RLS policies in this step.
-- DO NOT create any new business_slug index/constraint
--   (UNIQUE already exists: business_settings_business_slug_key).
-- DO NOT change index.html in this step.
--
-- LIVE schema confirmed 2026-08-12. Returns ONLY columns that exist in production.
-- Intentionally omitted (absent live): business_latitude, business_longitude,
--   business_currency, recurring_allowed_interval_weeks, recurring_max_duration_months.
-- Intentionally omitted (private/admin): business_email, notification_email,
--   onboarding_*, timezone, public_layout, booking_limits_*, max_bookings_*,
--   block_public_holidays, holiday_country.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_public_business_settings(
  p_business_id uuid DEFAULT NULL,
  p_business_slug text DEFAULT NULL
)
RETURNS TABLE (
  business_id uuid,
  business_slug text,
  business_name text,
  business_description text,
  public_tagline text,
  business_category text,
  business_logo_url text,
  business_cover_url text,
  business_accent_color text,
  business_address text,
  business_phone text,
  business_website text,
  business_instagram_url text,
  business_facebook_url text,
  work_start text,
  work_end text,
  working_days text[],
  working_hours_overrides jsonb,
  break_start time without time zone,
  break_end time without time zone,
  booking_window_weeks integer,
  minimum_notice_minutes integer,
  public_show_logo boolean,
  public_show_prices boolean,
  public_show_staff boolean,
  public_show_address boolean,
  public_show_about boolean,
  allow_recurring_appointments boolean,
  require_client_approval boolean,
  accept_new_clients boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_slug text;
  v_has_id boolean := (p_business_id IS NOT NULL);
  v_has_slug boolean;
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
  v_has_slug := (v_slug IS NOT NULL AND length(v_slug) > 0);

  IF v_has_id AND v_has_slug THEN
    RAISE EXCEPTION 'Provide either p_business_id or p_business_slug, not both.'
      USING ERRCODE = 'P0001';
  END IF;

  IF NOT v_has_id AND NOT v_has_slug THEN
    RAISE EXCEPTION 'p_business_id or p_business_slug is required.'
      USING ERRCODE = 'P0001';
  END IF;

  IF v_has_id THEN
    RETURN QUERY
    SELECT
      bs.business_id,
      bs.business_slug,
      bs.business_name,
      bs.business_description,
      bs.public_tagline,
      bs.business_category,
      bs.business_logo_url,
      bs.business_cover_url,
      bs.business_accent_color,
      bs.business_address,
      bs.business_phone,
      bs.business_website,
      bs.business_instagram_url,
      bs.business_facebook_url,
      bs.work_start,
      bs.work_end,
      bs.working_days,
      bs.working_hours_overrides,
      bs.break_start,
      bs.break_end,
      bs.booking_window_weeks,
      bs.minimum_notice_minutes,
      bs.public_show_logo,
      bs.public_show_prices,
      bs.public_show_staff,
      bs.public_show_address,
      bs.public_show_about,
      bs.allow_recurring_appointments,
      bs.require_client_approval,
      bs.accept_new_clients
    FROM public.business_settings bs
    WHERE bs.business_id = p_business_id
    LIMIT 1;
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    bs.business_id,
    bs.business_slug,
    bs.business_name,
    bs.business_description,
    bs.public_tagline,
    bs.business_category,
    bs.business_logo_url,
    bs.business_cover_url,
    bs.business_accent_color,
    bs.business_address,
    bs.business_phone,
    bs.business_website,
    bs.business_instagram_url,
    bs.business_facebook_url,
    bs.work_start,
    bs.work_end,
    bs.working_days,
    bs.working_hours_overrides,
    bs.break_start,
    bs.break_end,
    bs.booking_window_weeks,
    bs.minimum_notice_minutes,
    bs.public_show_logo,
    bs.public_show_prices,
    bs.public_show_staff,
    bs.public_show_address,
    bs.public_show_about,
    bs.allow_recurring_appointments,
    bs.require_client_approval,
    bs.accept_new_clients
  FROM public.business_settings bs
  WHERE bs.business_slug = v_slug
  LIMIT 1;
END;
$$;

COMMENT ON FUNCTION public.get_public_business_settings(uuid, text) IS
  'STEP 6A: Public/customer safe business settings for ONE business by id or slug. Explicit live public columns only. Excludes email/notification/onboarding/limits/holiday admin fields and columns not present in production.';

REVOKE ALL ON FUNCTION public.get_public_business_settings(uuid, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_public_business_settings(uuid, text)
  TO anon, authenticated;

COMMIT;

-- =============================================================================
-- Direct tests (run after APPLY; replace placeholders)
-- =============================================================================
-- Valid slug:
--   SELECT * FROM public.get_public_business_settings(NULL, 'YOUR-SLUG-HERE');
--
-- Valid UUID:
--   SELECT * FROM public.get_public_business_settings('YOUR-UUID-HERE'::uuid, NULL);
--
-- Private columns must NOT appear in result metadata:
--   SELECT column_name
--   FROM information_schema.columns
--   WHERE table_name = '' -- N/A for set-returning fn; use:
--   SELECT * FROM public.get_public_business_settings(NULL, 'YOUR-SLUG-HERE');
--   -- then confirm result has no: business_email, notification_email,
--   -- onboarding_*, timezone, public_layout, booking_limits_*, max_bookings_*,
--   -- block_public_holidays, holiday_country
--
-- Or:
--   SELECT pg_get_function_result(
--     'public.get_public_business_settings(uuid, text)'::regprocedure
--   );
--
-- Rollback:
--   DROP FUNCTION IF EXISTS public.get_public_business_settings(uuid, text);
