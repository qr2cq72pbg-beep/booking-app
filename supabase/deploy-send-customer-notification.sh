#!/usr/bin/env bash
# Deploy send-customer-notification (business → customer push)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_REF="${SUPABASE_PROJECT_REF:-sdqothuulzeczcncyfqd}"
FUNC_DIR="$ROOT/supabase/functions/send-customer-notification"

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI not found."
  echo ""
  echo "=== MANUAL DEPLOY (Dashboard) ==="
  echo "1. Run SQL: supabase-customer-push-notifications.sql"
  echo "2. Open: https://supabase.com/dashboard/project/${PROJECT_REF}/functions/send-customer-notification"
  echo "3. Replace ALL code with: ${FUNC_DIR}/index.ts"
  echo "4. Verify JWT: OFF"
  echo "5. Set secrets: FCM_SERVER_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_BUNDLE_ID"
  echo "6. Deploy"
  exit 1
fi

cd "$ROOT"
if [ ! -f supabase/.temp/project-ref ] && [ ! -f .supabase/project-ref ]; then
  supabase link --project-ref "$PROJECT_REF" || true
fi

echo "Deploying send-customer-notification to ${PROJECT_REF}..."
supabase functions deploy send-customer-notification --project-ref "$PROJECT_REF" --no-verify-jwt

echo ""
echo "Deployed. Confirm Verify JWT is OFF in Dashboard."
echo "Set push secrets: FCM_SERVER_KEY, APNS_* (see supabase/secrets.example.env)"
