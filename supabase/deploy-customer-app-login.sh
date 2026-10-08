#!/usr/bin/env bash
# Deploy Phase 3 customer app-login Edge Functions.
# Does NOT set CUSTOMER_APP_LOGIN_HMAC_SECRET (configure in Dashboard).
# Apply supabase-customer-app-login-codes.sql before first deploy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_REF="${SUPABASE_PROJECT_REF:-sdqothuulzeczcncyfqd}"

if ! command -v supabase >/dev/null 2>&1; then
  echo "Supabase CLI not found."
  echo "Apply SQL: supabase-customer-app-login-codes.sql"
  echo "Set secret name CUSTOMER_APP_LOGIN_HMAC_SECRET in Dashboard → Edge Functions → Secrets"
  echo "Deploy functions:"
  echo "  issue-customer-app-login-code (Verify JWT: ON)"
  echo "  redeem-customer-app-login-code (Verify JWT: OFF)"
  exit 1
fi

cd "$ROOT"
if [ ! -f supabase/.temp/project-ref ] && [ ! -f .supabase/project-ref ]; then
  supabase link --project-ref "$PROJECT_REF" || true
fi

echo "Deploying issue-customer-app-login-code (JWT required)..."
supabase functions deploy issue-customer-app-login-code --project-ref "$PROJECT_REF"

echo "Deploying redeem-customer-app-login-code (JWT not required)..."
supabase functions deploy redeem-customer-app-login-code --project-ref "$PROJECT_REF" --no-verify-jwt

echo "Deployed. Confirm HMAC secret CUSTOMER_APP_LOGIN_HMAC_SECRET is set."
echo "Do not print the secret value."
