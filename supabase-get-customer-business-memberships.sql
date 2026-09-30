-- XBOOK: Canonical customer membership read for Client View restore.
-- Source of truth: public.business_customers for auth.uid().
-- Does not create, update, or delete memberships.
-- Does not change approval RPCs, RLS table policies, or triggers.

BEGIN;

CREATE OR REPLACE FUNCTION public.get_customer_business_memberships()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role text;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Sign in required.' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(trim(coalesce(p.role, '')))
  INTO v_role
  FROM public.user_profiles p
  WHERE p.id = v_uid;

  IF v_role IS DISTINCT FROM 'customer' THEN
    RAISE EXCEPTION 'Customer memberships only.' USING ERRCODE = 'P0001';
  END IF;

  SELECT COALESCE(
    jsonb_agg(row_data ORDER BY row_data->>'business_name', row_data->>'business_slug'),
    '[]'::jsonb
  )
  INTO v_out
  FROM (
    SELECT DISTINCT ON (bc.business_id)
      jsonb_build_object(
        'id', bc.id,
        'business_id', bc.business_id,
        'business_slug', bs.business_slug,
        'business_name', bs.business_name,
        'approval_status', bc.approval_status,
        'client_key', bc.client_key,
        'customer_number', bc.customer_number,
        'customer_user_id', bc.customer_user_id,
        'business_logo_url',
          CASE
            WHEN coalesce(bs.public_show_logo, true) = true
            THEN nullif(trim(bs.business_logo_url), '')
            ELSE NULL
          END,
        'business_cover_url', nullif(trim(bs.business_cover_url), '')
      ) AS row_data
    FROM public.business_customers bc
    JOIN public.business_settings bs ON bs.business_id = bc.business_id
    WHERE bc.customer_user_id = v_uid
    ORDER BY bc.business_id, bc.updated_at DESC, bc.created_at DESC
  ) sub;

  RETURN v_out;
END;
$$;

COMMENT ON FUNCTION public.get_customer_business_memberships() IS
  'Authenticated customer only. Returns this user''s business_customers rows joined to business_settings. Read-only. Scoped to auth.uid(). Does not create memberships.';

REVOKE ALL ON FUNCTION public.get_customer_business_memberships() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_customer_business_memberships() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_customer_business_memberships() TO authenticated;

COMMIT;
