#!/usr/bin/env bash
# Run after deploy + secrets. Usage:
#   ./supabase/verify-email-live.sh [BOOKING_ID] [MANAGE_TOKEN]
set -euo pipefail

KEY="${SUPABASE_ANON_KEY:-sb_publishable_Gn743-ISr01JNKmrOOc8Mw_S3TbNbaU}"
BASE="${SUPABASE_URL:-https://sdqothuulzeczcncyfqd.supabase.co}"
BID="${1:-}"
TOKEN="${2:-}"

if [ -z "$BID" ] || [ -z "$TOKEN" ]; then
  echo "Fetching latest confirmed booking with manage_token..."
  row=$(curl -s "${BASE}/rest/v1/bookings?select=id,manage_token,booking_ref&manage_token=not.is.null&booking_status=eq.Confirmed&order=created_at.desc&limit=1" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
  BID=$(echo "$row" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  TOKEN=$(echo "$row" | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['manage_token'])")
  echo "Using booking_ref from DB: $(echo "$row" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('booking_ref',''))")"
fi

invoke() {
  local label="$1" body="$2"
  echo ""
  echo "=== $label ==="
  resp=$(curl -sS -w "\nHTTP:%{http_code}" -X POST "${BASE}/functions/v1/send-booking-email" \
    -H "apikey: $KEY" \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d "$body")
  echo "$resp"
  if echo "$resp" | grep -q 'send-booking-email-v2'; then
    echo "(v2 deployed OK)"
  elif echo "$resp" | grep -q 'Unknown email type'; then
    echo "ERROR: Old function still live — redeploy index.ts from repo"
  fi
}

invoke "booking_created (valid token)" "{\"type\":\"booking_created\",\"bookingId\":\"$BID\",\"manageToken\":\"$TOKEN\"}"
invoke "booking_rescheduled (valid token)" "{\"type\":\"booking_rescheduled\",\"bookingId\":\"$BID\",\"manageToken\":\"$TOKEN\"}"
invoke "booking_cancelled (valid token)" "{\"type\":\"booking_cancelled\",\"bookingId\":\"$BID\",\"manageToken\":\"$TOKEN\"}"
invoke "INVALID token (expect 403)" "{\"type\":\"booking_created\",\"bookingId\":\"$BID\",\"manageToken\":\"invalid-token-000000000000000000000000\"}"

echo ""
echo "Done. Expect 200 + ok:true for valid tests, 403 for invalid token."
