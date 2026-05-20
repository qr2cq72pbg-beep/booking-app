#!/usr/bin/env bash
# Deploy send-booking-email v2 (booking_created / rescheduled / cancelled + manage_token auth)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_REF="${SUPABASE_PROJECT_REF:-sdqothuulzeczcncyfqd}"
FUNC_DIR="$ROOT/supabase/functions/send-booking-email"

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI not found."
  echo ""
  echo "=== MANUAL DEPLOY (Dashboard) ==="
  echo "1. Open: https://supabase.com/dashboard/project/${PROJECT_REF}/functions/send-booking-email"
  echo "2. Replace ALL code with: ${FUNC_DIR}/index.ts"
  echo "3. Verify JWT: OFF"
  echo "4. Deploy"
  echo ""
  echo "After deploy, run: ./supabase/verify-email-live.sh"
  exit 1
fi

cd "$ROOT"
if [ ! -f supabase/.temp/project-ref ] && [ ! -f .supabase/project-ref ]; then
  supabase link --project-ref "$PROJECT_REF" || true
fi

echo "Deploying send-booking-email v2 to ${PROJECT_REF}..."
supabase functions deploy send-booking-email --project-ref "$PROJECT_REF" --no-verify-jwt

echo ""
echo "Deployed. Confirm Verify JWT is OFF in Dashboard."
echo "Run: ./supabase/verify-email-live.sh"
