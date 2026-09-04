-- Read-only EXPLAIN / timing for Phase 8B Actionable Insights.
-- No schema changes. No leftover rows. No new indexes.
-- Uses live Test Barber owner JWT.

CREATE TEMP TABLE IF NOT EXISTS _xbook_ai8b_explain (
  case_name text PRIMARY KEY,
  elapsed_ms numeric,
  insight_count bigint,
  completed_visits bigint,
  notes text
);
TRUNCATE _xbook_ai8b_explain;

CREATE TEMP TABLE IF NOT EXISTS _xbook_ai8b_explain_plan (
  case_name text,
  plan_line text
);

DO $$
DECLARE
  v_biz uuid := '4fb21268-7a4d-4c62-8c0a-30f7571eac41';
  v_from date := DATE '2026-08-01';
  v_to date := DATE '2026-08-31';
  t0 timestamptz;
  t1 timestamptz;
  v_payload jsonb;
  r record;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', v_biz::text, true);
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_biz::text, 'role', 'authenticated')::text,
    true
  );

  t0 := clock_timestamp();
  v_payload := public.get_business_actionable_insights(v_biz, v_from, v_to);
  t1 := clock_timestamp();
  INSERT INTO _xbook_ai8b_explain VALUES (
    'august_closed',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    jsonb_array_length(v_payload->'insights'),
    (v_payload->'quality'->>'completed_visits')::bigint,
    array_to_string(
      ARRAY(SELECT e->>'id' FROM jsonb_array_elements(coalesce(v_payload->'insights', '[]'::jsonb)) e),
      ','
    )
  );

  t0 := clock_timestamp();
  v_payload := public.get_business_actionable_insights(v_biz, DATE '2026-01-01', DATE '2026-09-04');
  t1 := clock_timestamp();
  INSERT INTO _xbook_ai8b_explain VALUES (
    'ytd_open',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    jsonb_array_length(v_payload->'insights'),
    (v_payload->'quality'->>'completed_visits')::bigint,
    v_payload->'period'->>'timezone'
  );

  t0 := clock_timestamp();
  v_payload := public.get_business_actionable_insights(v_biz, DATE '2026-09-04', DATE '2026-09-04');
  t1 := clock_timestamp();
  INSERT INTO _xbook_ai8b_explain VALUES (
    'today',
    round(extract(epoch FROM (t1 - t0)) * 1000.0, 1),
    jsonb_array_length(v_payload->'insights'),
    (v_payload->'quality'->>'completed_visits')::bigint,
    NULL
  );

  FOR r IN
    EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
    SELECT public.get_business_actionable_insights(v_biz, v_from, v_to)
  LOOP
    INSERT INTO _xbook_ai8b_explain_plan VALUES ('august_analyze', r."QUERY PLAN");
  END LOOP;
END;
$$;

SELECT case_name, elapsed_ms, insight_count, completed_visits, notes
FROM _xbook_ai8b_explain
ORDER BY case_name;

SELECT case_name, plan_line
FROM _xbook_ai8b_explain_plan
ORDER BY case_name, plan_line;
