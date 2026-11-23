-- =============================================================================
-- GT Termin — Staff services and individual working hours (Phase F1)
-- =============================================================================
-- Adds, without changing any existing function or trigger:
--   1) staff_members.all_services        (default true  = performs every service)
--      staff_members.uses_business_hours (default true  = follows business hours)
--   2) public.staff_services        — which services a staff member performs
--   3) public.staff_working_hours   — weekly hours and break per staff member
--   4) _staff_booking_rule_violation — the single rule used everywhere
--   5) bookings_enforce_staff_rules  — BEFORE INSERT/UPDATE trigger on bookings
--      (covers create_booking, create_recurring_bookings, manage-link reschedule
--       and owner edits, the same way bookings_enforce_staff_time_off does)
--   6) get_public_staff_booking_rules — read-only data for the booking UI
--   7) Owner RPCs: set_staff_services, assign_service_to_all_staff,
--      set_staff_working_hours, list_staff_rule_conflicts
--   8) create_booking_any_staff — "Било кој слободен"
--
-- Compatibility:
--   • Every existing staff row gets all_services = true and
--     uses_business_hours = true, so availability is unchanged until the owner
--     changes something.
--   • Bookings without staff_id (legacy) are never checked by the new rule.
--   • Updates that do not touch staff, service, date, time, duration or
--     re-activation are never checked (notes, status Pending↔Confirmed,
--     contact data, price, cancellation).
--   • An existing booking is never changed by this file. If the owner later
--     removes a service or narrows hours, the booking stays as it is; only
--     a move (date, time, duration, staff or service) or a re-activation has
--     to satisfy the current rules, like a new booking.
--   • The rule applies to everyone, including the business owner.
--
-- The business-level checks (working days, business hours, business break,
-- closed days, window, past time, overlap, time off, subscription) are not
-- touched and still run first.
--
-- Safe to re-run. Rollback script at the end (commented out).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Staff flags (metadata-only ALTER, no table rewrite)
-- -----------------------------------------------------------------------------
ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS all_services boolean NOT NULL DEFAULT true;

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS uses_business_hours boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.staff_members.all_services IS
  'true = performs every service of the business (default, also for new services). '
  'false = only the services listed in staff_services.';
COMMENT ON COLUMN public.staff_members.uses_business_hours IS
  'true = follows the business working days and hours (default). '
  'false = works only the days listed in staff_working_hours.';

-- -----------------------------------------------------------------------------
-- 2) staff_services
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_services (
  business_id uuid NOT NULL,
  staff_id    uuid NOT NULL REFERENCES public.staff_members (id) ON DELETE CASCADE,
  service_id  uuid NOT NULL REFERENCES public.services (id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (staff_id, service_id)
);

CREATE INDEX IF NOT EXISTS staff_services_business_idx ON public.staff_services (business_id);
CREATE INDEX IF NOT EXISTS staff_services_service_idx  ON public.staff_services (service_id);

COMMENT ON TABLE public.staff_services IS
  'Services a staff member performs. Used only when staff_members.all_services = false.';

-- -----------------------------------------------------------------------------
-- 3) staff_working_hours (dow uses EXTRACT(DOW): 0 = Sunday … 6 = Saturday,
--    the same convention as business_settings.working_days)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_working_hours (
  business_id uuid NOT NULL,
  staff_id    uuid NOT NULL REFERENCES public.staff_members (id) ON DELETE CASCADE,
  dow         smallint NOT NULL,
  start_time  time NOT NULL,
  end_time    time NOT NULL,
  break_start time,
  break_end   time,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (staff_id, dow),
  CONSTRAINT staff_working_hours_dow_ok CHECK (dow BETWEEN 0 AND 6),
  CONSTRAINT staff_working_hours_range_ok CHECK (end_time > start_time),
  CONSTRAINT staff_working_hours_break_ok CHECK (
    (break_start IS NULL AND break_end IS NULL)
    OR (
      break_start IS NOT NULL AND break_end IS NOT NULL
      AND break_end > break_start
      AND break_start >= start_time
      AND break_end <= end_time
    )
  )
);

CREATE INDEX IF NOT EXISTS staff_working_hours_business_idx ON public.staff_working_hours (business_id);

COMMENT ON TABLE public.staff_working_hours IS
  'Weekly hours per staff member. Used only when staff_members.uses_business_hours = false. '
  'A missing day = day off. Business hours, closed days and time off still apply on top.';

-- Tenant guard: the staff member (and service) must belong to business_id.
CREATE OR REPLACE FUNCTION public._staff_rules_assert_tenant()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm
    WHERE sm.id = NEW.staff_id AND sm.business_id = NEW.business_id
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  IF TG_TABLE_NAME = 'staff_services' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.services s
      WHERE s.id = NEW.service_id AND s.business_id = NEW.business_id
    ) THEN
      RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS staff_services_assert_tenant ON public.staff_services;
CREATE TRIGGER staff_services_assert_tenant
  BEFORE INSERT OR UPDATE ON public.staff_services
  FOR EACH ROW EXECUTE FUNCTION public._staff_rules_assert_tenant();

DROP TRIGGER IF EXISTS staff_working_hours_assert_tenant ON public.staff_working_hours;
CREATE TRIGGER staff_working_hours_assert_tenant
  BEFORE INSERT OR UPDATE ON public.staff_working_hours
  FOR EACH ROW EXECUTE FUNCTION public._staff_rules_assert_tenant();

-- RLS: same owner model as staff_members / staff_time_off.
ALTER TABLE public.staff_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_working_hours ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_services_owner_select ON public.staff_services;
CREATE POLICY staff_services_owner_select ON public.staff_services
  FOR SELECT TO authenticated USING (business_id = auth.uid());
DROP POLICY IF EXISTS staff_services_owner_insert ON public.staff_services;
CREATE POLICY staff_services_owner_insert ON public.staff_services
  FOR INSERT TO authenticated WITH CHECK (business_id = auth.uid());
DROP POLICY IF EXISTS staff_services_owner_delete ON public.staff_services;
CREATE POLICY staff_services_owner_delete ON public.staff_services
  FOR DELETE TO authenticated USING (business_id = auth.uid());

DROP POLICY IF EXISTS staff_working_hours_owner_select ON public.staff_working_hours;
CREATE POLICY staff_working_hours_owner_select ON public.staff_working_hours
  FOR SELECT TO authenticated USING (business_id = auth.uid());
DROP POLICY IF EXISTS staff_working_hours_owner_insert ON public.staff_working_hours;
CREATE POLICY staff_working_hours_owner_insert ON public.staff_working_hours
  FOR INSERT TO authenticated WITH CHECK (business_id = auth.uid());
DROP POLICY IF EXISTS staff_working_hours_owner_update ON public.staff_working_hours;
CREATE POLICY staff_working_hours_owner_update ON public.staff_working_hours
  FOR UPDATE TO authenticated USING (business_id = auth.uid()) WITH CHECK (business_id = auth.uid());
DROP POLICY IF EXISTS staff_working_hours_owner_delete ON public.staff_working_hours;
CREATE POLICY staff_working_hours_owner_delete ON public.staff_working_hours
  FOR DELETE TO authenticated USING (business_id = auth.uid());

-- Supabase default privileges grant ALL (incl. TRUNCATE) on new tables to
-- anon/authenticated; reset to exactly what the owner UI needs.
REVOKE ALL ON TABLE public.staff_services, public.staff_working_hours FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, DELETE ON TABLE public.staff_services TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.staff_working_hours TO authenticated;
GRANT ALL ON TABLE public.staff_services, public.staff_working_hours TO service_role;

-- -----------------------------------------------------------------------------
-- 4) The single staff rule. Returns NULL when the booking is allowed,
--    otherwise the user-facing message. Used by the trigger, the any-staff
--    picker and the conflict list, so the logic exists once.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_booking_rule_violation(
  p_business_id   uuid,
  p_staff_id      uuid,
  p_service_id    uuid,
  p_date          date,
  p_start_min     integer,
  p_end_min       integer,
  p_check_service boolean DEFAULT true,
  p_check_hours   boolean DEFAULT true
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff public.staff_members%ROWTYPE;
  v_hours public.staff_working_hours%ROWTYPE;
  v_start integer;
  v_end   integer;
  v_bs    integer;
  v_be    integer;
BEGIN
  IF p_business_id IS NULL OR p_staff_id IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT * INTO v_staff
  FROM public.staff_members sm
  WHERE sm.id = p_staff_id AND sm.business_id = p_business_id;

  -- Unknown or foreign staff is reported by the existing booking checks.
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  IF p_check_service
     AND p_service_id IS NOT NULL
     AND coalesce(v_staff.all_services, true) = false
     AND NOT EXISTS (
       SELECT 1 FROM public.staff_services ss
       WHERE ss.staff_id = p_staff_id AND ss.service_id = p_service_id
     )
  THEN
    RETURN 'This team member does not perform this service.';
  END IF;

  IF p_check_hours
     AND coalesce(v_staff.uses_business_hours, true) = false
     AND p_date IS NOT NULL
     AND p_start_min IS NOT NULL
  THEN
    SELECT * INTO v_hours
    FROM public.staff_working_hours h
    WHERE h.staff_id = p_staff_id
      AND h.dow = EXTRACT(DOW FROM p_date)::int;

    IF NOT FOUND THEN
      RETURN 'This team member does not work on this day.';
    END IF;

    v_start := public._time_to_minutes(v_hours.start_time);
    v_end   := public._time_to_minutes(v_hours.end_time);
    IF p_start_min < v_start OR coalesce(p_end_min, p_start_min) > v_end THEN
      RETURN 'This time is outside this team member''s working hours.';
    END IF;

    IF v_hours.break_start IS NOT NULL AND v_hours.break_end IS NOT NULL THEN
      v_bs := public._time_to_minutes(v_hours.break_start);
      v_be := public._time_to_minutes(v_hours.break_end);
      IF p_start_min < v_be AND coalesce(p_end_min, p_start_min) > v_bs THEN
        RETURN 'This time overlaps this team member''s break.';
      END IF;
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._staff_booking_rule_violation(uuid, uuid, uuid, date, integer, integer, boolean, boolean) IS
  'Staff service assignment + individual hours rule. NULL = allowed, otherwise the error message.';

-- -----------------------------------------------------------------------------
-- 5) Trigger on bookings (mirrors _enforce_bookings_staff_time_off)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._enforce_bookings_staff_rules()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_check_service boolean := true;
  v_check_hours   boolean := true;
  v_date          date;
  v_start_min     integer;
  v_end_min       integer;
  v_message       text;
BEGIN
  -- Cancelled / inactive rows and legacy rows without staff are never checked.
  IF NOT public._booking_active_status(coalesce(NEW.booking_status::text, NEW.status::text))
     OR NEW.staff_id IS NULL
  THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
     AND public._booking_active_status(coalesce(OLD.booking_status::text, OLD.status::text))
     AND NEW.staff_id IS NOT DISTINCT FROM OLD.staff_id
     AND NEW.service_id IS NOT DISTINCT FROM OLD.service_id
     AND NEW.date IS NOT DISTINCT FROM OLD.date
     AND NEW.time IS NOT DISTINCT FROM OLD.time
     AND NEW.duration_minutes IS NOT DISTINCT FROM OLD.duration_minutes
  THEN
    -- Active → active without touching the slot (notes, status, contact
    -- details): the existing booking is left exactly as it is.
    RETURN NEW;
  END IF;
  -- INSERT, a move / re-staff / re-service, or re-activating a cancelled
  -- booking: the new slot must satisfy all current rules.

  BEGIN
    v_date := trim(NEW.date::text)::date;
  EXCEPTION
    WHEN OTHERS THEN
      RETURN NEW;  -- malformed legacy date: left to the existing checks
  END;

  v_start_min := public._booking_row_time_to_minutes(NEW.time);
  IF v_start_min IS NULL OR v_date IS NULL THEN
    RETURN NEW;
  END IF;
  v_end_min := v_start_min + coalesce(nullif(NEW.duration_minutes, 0), 30);

  v_message := public._staff_booking_rule_violation(
    NEW.business_id, NEW.staff_id, NEW.service_id, v_date,
    v_start_min, v_end_min, v_check_service, v_check_hours
  );
  IF v_message IS NOT NULL THEN
    RAISE EXCEPTION '%', v_message USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS bookings_enforce_staff_rules ON public.bookings;
CREATE TRIGGER bookings_enforce_staff_rules
  BEFORE INSERT OR UPDATE ON public.bookings
  FOR EACH ROW EXECUTE FUNCTION public._enforce_bookings_staff_rules();

-- -----------------------------------------------------------------------------
-- 6) Public read: rules the booking UI needs (same exposure as get_public_staff)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_public_staff_booking_rules(p_business_id uuid)
RETURNS TABLE (
  staff_id            uuid,
  all_services        boolean,
  service_ids         uuid[],
  uses_business_hours boolean,
  weekly_hours        jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    sm.id,
    coalesce(sm.all_services, true),
    CASE WHEN coalesce(sm.all_services, true) THEN NULL
         ELSE coalesce(
           (SELECT array_agg(ss.service_id ORDER BY ss.service_id)
            FROM public.staff_services ss WHERE ss.staff_id = sm.id),
           '{}'::uuid[])
    END,
    coalesce(sm.uses_business_hours, true),
    CASE WHEN coalesce(sm.uses_business_hours, true) THEN NULL
         ELSE coalesce(
           (SELECT jsonb_agg(jsonb_build_object(
                     'dow', h.dow,
                     'start', to_char(h.start_time, 'HH24:MI'),
                     'end', to_char(h.end_time, 'HH24:MI'),
                     'break_start', to_char(h.break_start, 'HH24:MI'),
                     'break_end', to_char(h.break_end, 'HH24:MI'))
                   ORDER BY h.dow)
            FROM public.staff_working_hours h WHERE h.staff_id = sm.id),
           '[]'::jsonb)
    END
  FROM public.staff_members sm
  WHERE p_business_id IS NOT NULL
    AND sm.business_id = p_business_id
    AND coalesce(sm.active, true) = true
  ORDER BY sm.created_at ASC NULLS LAST, sm.name ASC;
$$;

COMMENT ON FUNCTION public.get_public_staff_booking_rules(uuid) IS
  'Per active staff member: services (NULL = all) and weekly hours (NULL = business hours).';

-- -----------------------------------------------------------------------------
-- 7) Owner management. Each *_core function takes an explicit business id
--    (service_role only, reusable later by the Super Admin); the public
--    wrapper resolves the business from the signed-in owner.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._staff_rules_require_owner()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.business_settings bs WHERE bs.business_id = v_uid
  ) THEN
    RAISE EXCEPTION 'Only the business owner can change this.' USING ERRCODE = '42501';
  END IF;
  RETURN v_uid;
END;
$$;

CREATE OR REPLACE FUNCTION public._set_staff_services_core(
  p_business_id  uuid,
  p_staff_id     uuid,
  p_all_services boolean,
  p_service_ids  uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ids   uuid[] := ARRAY(SELECT DISTINCT x FROM unnest(coalesce(p_service_ids, '{}'::uuid[])) AS x WHERE x IS NOT NULL);
  v_valid integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm
    WHERE sm.id = p_staff_id AND sm.business_id = p_business_id
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(p_all_services, false) THEN
    DELETE FROM public.staff_services WHERE staff_id = p_staff_id;
    UPDATE public.staff_members SET all_services = true WHERE id = p_staff_id;
    RETURN jsonb_build_object('ok', true, 'all_services', true, 'service_count', NULL);
  END IF;

  SELECT count(*) INTO v_valid
  FROM public.services s
  WHERE s.business_id = p_business_id AND s.id = ANY (v_ids);
  IF v_valid <> coalesce(array_length(v_ids, 1), 0) THEN
    RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  IF v_valid = 0 THEN
    RAISE EXCEPTION 'Choose at least one service, or choose all services.' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.staff_services
  WHERE staff_id = p_staff_id AND NOT (service_id = ANY (v_ids));
  INSERT INTO public.staff_services (business_id, staff_id, service_id)
  SELECT p_business_id, p_staff_id, x FROM unnest(v_ids) AS x
  ON CONFLICT (staff_id, service_id) DO NOTHING;
  UPDATE public.staff_members SET all_services = false WHERE id = p_staff_id;

  RETURN jsonb_build_object('ok', true, 'all_services', false, 'service_count', v_valid);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_staff_services(
  p_staff_id     uuid,
  p_all_services boolean,
  p_service_ids  uuid[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public._set_staff_services_core(
    public._staff_rules_require_owner(), p_staff_id, p_all_services, p_service_ids
  );
END;
$$;

CREATE OR REPLACE FUNCTION public._assign_service_to_all_staff_core(
  p_business_id uuid,
  p_service_id  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_added integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.services s WHERE s.id = p_service_id AND s.business_id = p_business_id
  ) THEN
    RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
  END IF;
  -- Staff with all_services = true already perform it; only extend the others.
  INSERT INTO public.staff_services (business_id, staff_id, service_id)
  SELECT p_business_id, sm.id, p_service_id
  FROM public.staff_members sm
  WHERE sm.business_id = p_business_id
    AND coalesce(sm.all_services, true) = false
  ON CONFLICT (staff_id, service_id) DO NOTHING;
  GET DIAGNOSTICS v_added = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'added', v_added);
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_service_to_all_staff(p_service_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public._assign_service_to_all_staff_core(public._staff_rules_require_owner(), p_service_id);
END;
$$;

-- p_hours: [{"dow":1,"start":"09:00","end":"17:00","break_start":"12:00","break_end":"12:30"}, …]
CREATE OR REPLACE FUNCTION public._set_staff_working_hours_core(
  p_business_id         uuid,
  p_staff_id            uuid,
  p_uses_business_hours boolean,
  p_hours               jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item  jsonb;
  v_dow   integer;
  v_seen  integer[] := '{}';
  v_start time;
  v_end   time;
  v_bs    time;
  v_be    time;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm
    WHERE sm.id = p_staff_id AND sm.business_id = p_business_id
  ) THEN
    RAISE EXCEPTION 'Staff member not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  IF coalesce(p_uses_business_hours, false) THEN
    DELETE FROM public.staff_working_hours WHERE staff_id = p_staff_id;
    UPDATE public.staff_members SET uses_business_hours = true WHERE id = p_staff_id;
    RETURN jsonb_build_object('ok', true, 'uses_business_hours', true, 'days', NULL);
  END IF;

  IF p_hours IS NULL OR jsonb_typeof(p_hours) <> 'array' OR jsonb_array_length(p_hours) = 0 THEN
    RAISE EXCEPTION 'Choose at least one working day.' USING ERRCODE = 'P0001';
  END IF;

  DELETE FROM public.staff_working_hours WHERE staff_id = p_staff_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_hours) LOOP
    BEGIN
      v_dow   := (v_item ->> 'dow')::integer;
      v_start := nullif(trim(v_item ->> 'start'), '')::time;
      v_end   := nullif(trim(v_item ->> 'end'), '')::time;
      v_bs    := nullif(trim(coalesce(v_item ->> 'break_start', '')), '')::time;
      v_be    := nullif(trim(coalesce(v_item ->> 'break_end', '')), '')::time;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE EXCEPTION 'Invalid working hours.' USING ERRCODE = 'P0001';
    END;
    IF v_dow IS NULL OR v_dow < 0 OR v_dow > 6 OR v_start IS NULL OR v_end IS NULL THEN
      RAISE EXCEPTION 'Invalid working hours.' USING ERRCODE = 'P0001';
    END IF;
    IF v_dow = ANY (v_seen) THEN
      RAISE EXCEPTION 'Each day can be set only once.' USING ERRCODE = 'P0001';
    END IF;
    IF v_end <= v_start THEN
      RAISE EXCEPTION 'End time must be after start time.' USING ERRCODE = 'P0001';
    END IF;
    IF (v_bs IS NULL) <> (v_be IS NULL)
       OR (v_bs IS NOT NULL AND (v_be <= v_bs OR v_bs < v_start OR v_be > v_end))
    THEN
      RAISE EXCEPTION 'The break must be inside the working hours.' USING ERRCODE = 'P0001';
    END IF;
    v_seen := v_seen || v_dow;
    INSERT INTO public.staff_working_hours (business_id, staff_id, dow, start_time, end_time, break_start, break_end)
    VALUES (p_business_id, p_staff_id, v_dow, v_start, v_end, v_bs, v_be);
  END LOOP;

  UPDATE public.staff_members SET uses_business_hours = false WHERE id = p_staff_id;
  RETURN jsonb_build_object('ok', true, 'uses_business_hours', false, 'days', coalesce(array_length(v_seen, 1), 0));
END;
$$;

CREATE OR REPLACE FUNCTION public.set_staff_working_hours(
  p_staff_id            uuid,
  p_uses_business_hours boolean,
  p_hours               jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public._set_staff_working_hours_core(
    public._staff_rules_require_owner(), p_staff_id, p_uses_business_hours, p_hours
  );
END;
$$;

-- Future active bookings of one staff member that no longer fit the rules
-- (after a service or schedule change). Nothing is changed; the owner decides.
CREATE OR REPLACE FUNCTION public._list_staff_rule_conflicts_core(
  p_business_id uuid,
  p_staff_id    uuid
)
RETURNS TABLE (
  booking_id    uuid,
  booking_date  text,
  booking_time  text,
  customer_name text,
  service_name  text,
  reason        text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT b.id, b.date::text, b.time::text, coalesce(b.customer_name, b.name), coalesce(b.service_name, b.service), x.reason
  FROM public.bookings b
  CROSS JOIN LATERAL (
    SELECT public._staff_booking_rule_violation(
      b.business_id, b.staff_id, b.service_id,
      CASE WHEN trim(b.date::text) ~ '^\d{4}-\d{2}-\d{2}$' THEN trim(b.date::text)::date END,
      public._booking_row_time_to_minutes(b.time),
      public._booking_row_time_to_minutes(b.time) + coalesce(nullif(b.duration_minutes, 0), 30),
      true, true
    ) AS reason
  ) x
  WHERE b.business_id = p_business_id
    AND b.staff_id = p_staff_id
    AND trim(b.date::text) ~ '^\d{4}-\d{2}-\d{2}$'
    AND trim(b.date::text)::date >= CURRENT_DATE
    AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
    AND x.reason IS NOT NULL
  ORDER BY trim(b.date::text), b.time::text;
$$;

CREATE OR REPLACE FUNCTION public.list_staff_rule_conflicts(p_staff_id uuid)
RETURNS TABLE (
  booking_id    uuid,
  booking_date  text,
  booking_time  text,
  customer_name text,
  service_name  text,
  reason        text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT * FROM public._list_staff_rule_conflicts_core(public._staff_rules_require_owner(), p_staff_id);
END;
$$;

-- -----------------------------------------------------------------------------
-- 8) "Било кој слободен": pick a qualified free staff member under the same
--    per-day lock that create_booking uses, then call the unchanged
--    create_booking with that staff_id (all existing checks + triggers run).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_booking_any_staff(
  p_business_id      uuid,
  p_service_id       uuid,
  p_date             date,
  p_time             time,
  p_customer_name    text,
  p_customer_phone   text,
  p_customer_email   text DEFAULT NULL,
  p_notes            text DEFAULT NULL,
  p_customer_user_id uuid DEFAULT NULL,
  p_booking_status   text DEFAULT 'Pending'
)
RETURNS public.bookings
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_duration  integer;
  v_start_min integer;
  v_end_min   integer;
  v_date_text text;
  v_staff_id  uuid;
BEGIN
  IF p_business_id IS NULL OR p_service_id IS NULL OR p_date IS NULL OR p_time IS NULL THEN
    RAISE EXCEPTION 'Business, service, date and time are required.' USING ERRCODE = 'P0001';
  END IF;

  -- Same caller rules as create_booking, before anything is read or locked.
  PERFORM public._assert_create_booking_caller(p_business_id, p_customer_user_id);

  -- Serialise with every other booking write for this business and day.
  -- Transaction-level advisory locks are re-entrant, so create_booking taking
  -- the same lock again below does not block.
  PERFORM pg_advisory_xact_lock(public._booking_day_lock_key(p_business_id, p_date));

  SELECT coalesce(nullif(s.duration, 0), 30) INTO v_duration
  FROM public.services s
  WHERE s.id = p_service_id AND s.business_id = p_business_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Service not found for this business.' USING ERRCODE = 'P0001';
  END IF;

  v_start_min := public._time_to_minutes(p_time);
  v_end_min   := v_start_min + v_duration;
  v_date_text := to_char(p_date, 'YYYY-MM-DD');

  SELECT sm.id INTO v_staff_id
  FROM public.staff_members sm
  WHERE sm.business_id = p_business_id
    AND coalesce(sm.active, true) = true
    AND public._staff_booking_rule_violation(
          p_business_id, sm.id, p_service_id, p_date, v_start_min, v_end_min, true, true
        ) IS NULL
    AND NOT public._staff_time_off_overlaps(p_business_id, sm.id, p_date, v_start_min, v_end_min)
    AND NOT EXISTS (
      SELECT 1 FROM public.bookings b
      WHERE b.business_id = p_business_id
        AND trim(b.date::text) = v_date_text
        AND public._booking_active_status(coalesce(b.booking_status::text, b.status::text))
        AND (b.staff_id IS NULL OR b.staff_id = sm.id)
        AND public._booking_row_time_to_minutes(b.time) IS NOT NULL
        AND v_start_min < public._booking_row_time_to_minutes(b.time) + coalesce(nullif(b.duration_minutes, 0), 30)
        AND v_end_min > public._booking_row_time_to_minutes(b.time)
    )
  ORDER BY
    (SELECT count(*) FROM public.bookings b2
     WHERE b2.business_id = p_business_id
       AND b2.staff_id = sm.id
       AND trim(b2.date::text) = v_date_text
       AND public._booking_active_status(coalesce(b2.booking_status::text, b2.status::text))) ASC,
    sm.created_at ASC NULLS LAST,
    sm.id ASC
  LIMIT 1;

  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'No team member is available for this service at this time.' USING ERRCODE = 'P0001';
  END IF;

  RETURN public.create_booking(
    p_business_id, p_service_id, p_date, p_time,
    p_customer_name, p_customer_phone, p_customer_email, p_notes,
    v_staff_id, p_customer_user_id, p_booking_status
  );
END;
$$;

COMMENT ON FUNCTION public.create_booking_any_staff(uuid, uuid, date, time, text, text, text, text, uuid, text) IS
  '"Any available" booking: picks the least-busy qualified free staff member under the day lock, then calls create_booking.';

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._staff_rules_assert_tenant() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_booking_rule_violation(uuid, uuid, uuid, date, integer, integer, boolean, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_bookings_staff_rules() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._staff_rules_require_owner() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_staff_services_core(uuid, uuid, boolean, uuid[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._assign_service_to_all_staff_core(uuid, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._set_staff_working_hours_core(uuid, uuid, boolean, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._list_staff_rule_conflicts_core(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._staff_booking_rule_violation(uuid, uuid, uuid, date, integer, integer, boolean, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._set_staff_services_core(uuid, uuid, boolean, uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public._assign_service_to_all_staff_core(uuid, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public._set_staff_working_hours_core(uuid, uuid, boolean, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._list_staff_rule_conflicts_core(uuid, uuid) TO service_role;

REVOKE ALL ON FUNCTION public.get_public_staff_booking_rules(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_staff_booking_rules(uuid) TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_staff_services(uuid, boolean, uuid[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.assign_service_to_all_staff(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_staff_working_hours(uuid, boolean, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_staff_rule_conflicts(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_staff_services(uuid, boolean, uuid[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assign_service_to_all_staff(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_staff_working_hours(uuid, boolean, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.list_staff_rule_conflicts(uuid) TO authenticated, service_role;

-- Same audience as create_booking (signed-in customers and owners; not anon).
REVOKE ALL ON FUNCTION public.create_booking_any_staff(uuid, uuid, date, time, text, text, text, text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_booking_any_staff(uuid, uuid, date, time, text, text, text, text, uuid, text) TO authenticated, service_role;

COMMIT;

-- =============================================================================
-- ROLLBACK (do not run as part of apply). Removes only what this file added;
-- staff assignments and staff hours entered by owners are lost.
-- =============================================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS bookings_enforce_staff_rules ON public.bookings;
-- DROP FUNCTION IF EXISTS public.create_booking_any_staff(uuid, uuid, date, time, text, text, text, text, uuid, text);
-- DROP FUNCTION IF EXISTS public.list_staff_rule_conflicts(uuid);
-- DROP FUNCTION IF EXISTS public._list_staff_rule_conflicts_core(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.set_staff_working_hours(uuid, boolean, jsonb);
-- DROP FUNCTION IF EXISTS public._set_staff_working_hours_core(uuid, uuid, boolean, jsonb);
-- DROP FUNCTION IF EXISTS public.assign_service_to_all_staff(uuid);
-- DROP FUNCTION IF EXISTS public._assign_service_to_all_staff_core(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.set_staff_services(uuid, boolean, uuid[]);
-- DROP FUNCTION IF EXISTS public._set_staff_services_core(uuid, uuid, boolean, uuid[]);
-- DROP FUNCTION IF EXISTS public._staff_rules_require_owner();
-- DROP FUNCTION IF EXISTS public.get_public_staff_booking_rules(uuid);
-- DROP FUNCTION IF EXISTS public._enforce_bookings_staff_rules();
-- DROP FUNCTION IF EXISTS public._staff_booking_rule_violation(uuid, uuid, uuid, date, integer, integer, boolean, boolean);
-- DROP TABLE IF EXISTS public.staff_working_hours;
-- DROP TABLE IF EXISTS public.staff_services;
-- DROP FUNCTION IF EXISTS public._staff_rules_assert_tenant();
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS uses_business_hours;
-- ALTER TABLE public.staff_members DROP COLUMN IF EXISTS all_services;
-- COMMIT;
