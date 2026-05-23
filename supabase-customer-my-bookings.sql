-- Customer "My Bookings" — read-only list scoped to the signed-in customer.
-- Run once in Supabase Dashboard → SQL Editor.
-- Does not change create_booking or manage-token RPCs.

DROP FUNCTION IF EXISTS public.get_customer_my_bookings();

CREATE OR REPLACE FUNCTION public.get_customer_my_bookings()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_phone text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT
    lower(trim(coalesce(nullif(trim(p.email), ''), nullif(trim(u.email), '')))),
    nullif(regexp_replace(coalesce(p.phone, ''), '[^0-9+]', '', 'g'), '')
  INTO v_email, v_phone
  FROM auth.users u
  LEFT JOIN public.user_profiles p ON p.id = u.id
  WHERE u.id = v_uid;

  RETURN COALESCE(
    (
      SELECT jsonb_agg(row_data ORDER BY row_data->>'date', row_data->>'time')
      FROM (
        SELECT jsonb_build_object(
          'id', b.id,
          'date', b.date::text,
          'time', to_char(b.time, 'HH24:MI'),
          'booking_status', coalesce(nullif(trim(b.booking_status), ''), nullif(trim(b.status), ''), 'Pending'),
          'service_id', b.service_id,
          'service_name', coalesce(nullif(trim(b.service_name), ''), s.name),
          'staff_id', b.staff_id,
          'staff_name', st.name,
          'business_id', b.business_id,
          'business_name', bs.business_name,
          'business_slug', bs.business_slug,
          'manage_token', b.manage_token,
          'booking_ref', b.booking_ref
        ) AS row_data
        FROM public.bookings b
        LEFT JOIN public.business_settings bs ON bs.business_id = b.business_id
        LEFT JOIN public.services s ON s.id = b.service_id AND s.business_id = b.business_id
        LEFT JOIN public.staff_members st ON st.id = b.staff_id AND st.business_id = b.business_id
        WHERE
          b.customer_user_id = v_uid
          OR (
            v_email IS NOT NULL
            AND v_email <> ''
            AND lower(trim(coalesce(b.customer_email, ''))) = v_email
          )
          OR (
            v_phone IS NOT NULL
            AND length(v_phone) >= 8
            AND regexp_replace(coalesce(b.customer_phone, ''), '[^0-9+]', '', 'g') = v_phone
          )
      ) sub
    ),
    '[]'::jsonb
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_customer_my_bookings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_customer_my_bookings() TO authenticated;
