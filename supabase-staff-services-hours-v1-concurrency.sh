#!/usr/bin/env bash
# Concurrency test for create_booking_any_staff ("Било кој слободен").
# Two real parallel sessions book the same slot at the same moment.
#
# LOCAL / STAGING COPY ONLY: commits synthetic fixtures (and removes them at
# the end). Refuses to run against a Supabase host.
#
# Usage: PGHOST=127.0.0.1 PGPORT=54329 PGDATABASE=gt_f1 PGUSER=postgres ./supabase-staff-services-hours-v1-concurrency.sh
set -euo pipefail

case "${PGHOST:-}" in
  *supabase*) echo "Refusing to run against ${PGHOST}: local/staging only." >&2; exit 2 ;;
esac

OWNER=f1c00000-0000-4000-8000-0000000000c0
SVC=f1c00000-0000-4000-8000-0000000005c1
ST1=f1c00000-0000-4000-8000-0000000000c1
ST2=f1c00000-0000-4000-8000-0000000000c2
PSQL=(psql -X -q -At -v ON_ERROR_STOP=1 -v VERBOSITY=terse)

cleanup() {
  "${PSQL[@]}" <<SQL >/dev/null
DELETE FROM public.bookings WHERE business_id = '$OWNER';
DELETE FROM public.staff_members WHERE business_id = '$OWNER';
DELETE FROM public.services WHERE business_id = '$OWNER';
DELETE FROM public.business_subscriptions WHERE business_id = '$OWNER';
DELETE FROM public.business_settings WHERE business_id = '$OWNER';
DELETE FROM auth.users WHERE id = '$OWNER';
SQL
}
trap cleanup EXIT
cleanup

# Monday at least 7 days ahead, inside business hours.
DAY=$("${PSQL[@]}" -c "SELECT current_date + ((8 - EXTRACT(DOW FROM current_date)::int) % 7) + 7")

"${PSQL[@]}" <<SQL >/dev/null
INSERT INTO auth.users (id, email) VALUES ('$OWNER', 'f1-concurrency@test.invalid');
INSERT INTO public.business_settings (business_id, business_slug, business_name, work_start, work_end, working_days, timezone)
VALUES ('$OWNER', 'f1-concurrency', 'F1 Concurrency', '09:00', '17:00', ARRAY['1','2','3','4','5'], 'Europe/Skopje');
INSERT INTO public.business_subscriptions (business_id, access_kind, starts_on) VALUES ('$OWNER', 'complimentary', current_date - 1);
INSERT INTO public.services (id, business_id, name, duration, price) VALUES ('$SVC', '$OWNER', 'Cut', 60, 500);
INSERT INTO public.staff_members (id, business_id, name, active, created_at) VALUES
  ('$ST1', '$OWNER', 'One', true, now() - interval '1 day'),
  ('$ST2', '$OWNER', 'Two', true, now());
SQL

AS_OWNER="SELECT set_config('request.jwt.claim.sub','$OWNER',false), set_config('request.jwt.claim.role','authenticated',false), set_config('request.jwt.claims','{\"sub\":\"$OWNER\",\"role\":\"authenticated\"}',false); SET ROLE authenticated;"

# $1 = time, $2 = seconds to hold the transaction open after booking.
any_staff() {
  { "${PSQL[@]}" 2>&1 || true; } <<SQL | grep -v '^$' | tail -1
$AS_OWNER
BEGIN;
SELECT 'staff=' || staff_id FROM public.create_booking_any_staff('$OWNER', '$SVC', '$DAY', '$1', 'Parallel', '+38970000000');
SELECT pg_sleep($2);
COMMIT;
SQL
  true  # an expected booking error must not stop the script (set -e / pipefail)
}

explicit_staff() {
  { "${PSQL[@]}" 2>&1 || true; } <<SQL | grep -v '^$' | tail -1
$AS_OWNER
SELECT 'staff=' || staff_id FROM public.create_booking('$OWNER', '$SVC', '$DAY', '$1', 'Parallel', '+38970000000', NULL, NULL, '$2');
SQL
  true
}

pass=0; fail=0
check() { if [ "$2" = "1" ]; then echo "ok - $1"; pass=$((pass+1)); else echo "FAIL - $1 ($3)"; fail=$((fail+1)); fi; }

# 1) Two staff free, two simultaneous any-staff requests → two different staff.
A_OUT=$(mktemp); B_OUT=$(mktemp)
( any_staff 10:00 3 > "$A_OUT" ) & PA=$!
sleep 0.5
START=$(date +%s)
any_staff 10:00 0 > "$B_OUT"
WAITED=$(( $(date +%s) - START ))
wait $PA
A=$(cat "$A_OUT"); B=$(cat "$B_OUT")
check "parallel any-staff: both succeed with different staff" \
  "$([ "${A#staff=}" != "$A" ] && [ "${B#staff=}" != "$B" ] && [ "$A" != "$B" ] && echo 1 || echo 0)" "A=$A B=$B"
check "second request waited for the first (same day lock)" "$([ "$WAITED" -ge 2 ] && echo 1 || echo 0)" "waited ${WAITED}s"

# 2) Only one staff member: second parallel any-staff request must fail, not double-book.
"${PSQL[@]}" -c "UPDATE public.staff_members SET active = false WHERE id = '$ST2'" >/dev/null
( any_staff 12:00 3 > "$A_OUT" ) & PA=$!
sleep 0.5
any_staff 12:00 0 > "$B_OUT"
wait $PA
A=$(cat "$A_OUT"); B=$(cat "$B_OUT")
check "one staff: first succeeds, parallel second gets 'No team member is available'" \
  "$([ "$A" = "staff=$ST1" ] && echo "$B" | grep -q 'No team member is available' && echo 1 || echo 0)" "A=$A B=$B"

# 3) any-staff and an explicit booking for the same staff at the same time.
( any_staff 14:00 3 > "$A_OUT" ) & PA=$!
sleep 0.5
explicit_staff 14:00 "$ST1" > "$B_OUT"
wait $PA
A=$(cat "$A_OUT"); B=$(cat "$B_OUT")
check "any-staff vs explicit booking: explicit one is rejected" \
  "$([ "$A" = "staff=$ST1" ] && echo "$B" | grep -q 'not available' && echo 1 || echo 0)" "A=$A B=$B"

# 4) Final invariant: no overlapping active bookings for the same staff member.
OVERLAPS=$("${PSQL[@]}" -c "
SELECT count(*) FROM public.bookings x JOIN public.bookings y
  ON x.business_id = y.business_id AND x.id < y.id AND x.staff_id = y.staff_id AND x.date = y.date
WHERE x.business_id = '$OWNER'
  AND public._booking_active_status(coalesce(x.booking_status, x.status))
  AND public._booking_active_status(coalesce(y.booking_status, y.status))
  AND public._booking_row_time_to_minutes(x.time) < public._booking_row_time_to_minutes(y.time) + coalesce(nullif(y.duration_minutes,0),30)
  AND public._booking_row_time_to_minutes(y.time) < public._booking_row_time_to_minutes(x.time) + coalesce(nullif(x.duration_minutes,0),30)")
check "no overlapping bookings for any staff member" "$([ "$OVERLAPS" = "0" ] && echo 1 || echo 0)" "overlaps=$OVERLAPS"

rm -f "$A_OUT" "$B_OUT"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
