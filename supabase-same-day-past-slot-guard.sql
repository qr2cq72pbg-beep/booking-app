-- XBook: authoritative business-timezone target-start guard.
-- Built from the deployed production signatures/ACLs inspected on 2026-09-22.
-- Public signatures and existing booking behavior remain unchanged.

BEGIN;

CREATE OR REPLACE FUNCTION public._booking_timezone_id(p_business_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_timezone text;
BEGIN
  SELECT nullif(trim(bs.timezone), '')
    INTO v_timezone
  FROM public.business_settings bs
  WHERE bs.business_id = p_business_id;

  IF v_timezone IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM pg_timezone_names tz
       WHERE tz.name = v_timezone
     )
  THEN
    RAISE EXCEPTION 'Business timezone is missing or invalid.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN v_timezone;
END;
$$;

CREATE OR REPLACE FUNCTION public._assert_booking_target_not_expired(
  p_business_id uuid,
  p_date date,
  p_time time without time zone
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_timezone text;
  v_target_start timestamptz;
BEGIN
  IF p_business_id IS NULL OR p_date IS NULL OR p_time IS NULL THEN
    RAISE EXCEPTION 'Invalid booking target parameters.'
      USING ERRCODE = 'P0001';
  END IF;

  v_timezone := public._booking_timezone_id(p_business_id);
  v_target_start := (p_date + p_time) AT TIME ZONE v_timezone;

  IF v_target_start <= clock_timestamp() THEN
    RAISE EXCEPTION 'Booking target start has already passed.'
      USING ERRCODE = 'P0001';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public._booking_timezone_id(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._booking_timezone_id(uuid) FROM anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._assert_booking_target_not_expired(uuid, date, time without time zone) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_booking_target_not_expired(uuid, date, time without time zone)
  FROM anon, authenticated, service_role;

-- Wrap the exact deployed validator instead of copying its body. Setting the
-- transaction-local timezone also makes its existing CURRENT_DATE/window
-- checks business-local.
ALTER FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time without time zone, uuid, uuid
) RENAME TO _assert_booking_slot_available_pre_past_guard;

REVOKE ALL ON FUNCTION public._assert_booking_slot_available_pre_past_guard(
  uuid, uuid, date, time without time zone, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_booking_slot_available_pre_past_guard(
  uuid, uuid, date, time without time zone, uuid, uuid
) FROM anon, authenticated, service_role;

CREATE FUNCTION public._assert_booking_slot_available(
  p_business_id uuid,
  p_service_id uuid,
  p_date date,
  p_time time without time zone,
  p_staff_id uuid DEFAULT NULL,
  p_exclude_booking_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_timezone text;
BEGIN
  v_timezone := public._booking_timezone_id(p_business_id);
  PERFORM set_config('TimeZone', v_timezone, true);
  PERFORM public._assert_booking_target_not_expired(p_business_id, p_date, p_time);
  PERFORM public._assert_booking_slot_available_pre_past_guard(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_staff_id,
    p_exclude_booking_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time without time zone, uuid, uuid
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time without time zone, uuid, uuid
) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._assert_booking_slot_available(
  uuid, uuid, date, time without time zone, uuid, uuid
) TO service_role;

-- create_booking has its own inlined availability checks in production, so it
-- receives the same wrapper. The original deployed function remains private.
ALTER FUNCTION public.create_booking(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) RENAME TO _create_booking_pre_past_guard;

REVOKE ALL ON FUNCTION public._create_booking_pre_past_guard(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._create_booking_pre_past_guard(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) FROM anon, authenticated, service_role;

CREATE FUNCTION public.create_booking(
  p_business_id uuid,
  p_service_id uuid,
  p_date date,
  p_time time without time zone,
  p_customer_name text,
  p_customer_phone text,
  p_customer_email text DEFAULT NULL,
  p_notes text DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL,
  p_customer_user_id uuid DEFAULT NULL,
  p_booking_status text DEFAULT 'Pending'
)
RETURNS public.bookings
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_timezone text;
BEGIN
  v_timezone := public._booking_timezone_id(p_business_id);
  PERFORM set_config('TimeZone', v_timezone, true);
  PERFORM public._assert_booking_target_not_expired(p_business_id, p_date, p_time);

  RETURN public._create_booking_pre_past_guard(
    p_business_id,
    p_service_id,
    p_date,
    p_time,
    p_customer_name,
    p_customer_phone,
    p_customer_email,
    p_notes,
    p_staff_id,
    p_customer_user_id,
    p_booking_status
  );
END;
$$;

REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_booking(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) FROM anon;
GRANT EXECUTE ON FUNCTION public.create_booking(
  uuid, uuid, date, time without time zone, text, text, text, text, uuid, uuid, text
) TO authenticated, service_role;

-- RETURNS TABLE changes require drop/recreate. No deployed dependants were
-- found; ownership/security and the exact live grants are restored.
DROP FUNCTION public.get_public_business_settings(uuid, text);

CREATE FUNCTION public.get_public_business_settings(
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
  business_latitude double precision,
  business_longitude double precision,
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
  timezone text,
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
  v_slug := left(
    trim(
      both '-'
      FROM regexp_replace(
        lower(trim(coalesce(p_business_slug, ''))),
        '[^a-z0-9]+',
        '-',
        'g'
      )
    ),
    60
  );

  v_has_slug := v_slug IS NOT NULL AND length(v_slug) > 0;

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
      bs.business_latitude,
      bs.business_longitude,
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
      bs.timezone,
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
    bs.business_latitude,
    bs.business_longitude,
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
    bs.timezone,
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
  'Public/customer safe business settings for one business by id or slug. Includes the canonical IANA timezone used by booking validation.';

REVOKE ALL ON FUNCTION public.get_public_business_settings(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_business_settings(uuid, text)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
