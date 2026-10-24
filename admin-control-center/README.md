# XBOOK Admin Control Center (Phase 3)

Separate platform-admin web app. It is **not** part of the Capacitor iOS/Android builds and must not be copied into `www/`.

Phase 3 adds **manual subscription management** on top of the Phase 2 read-only dashboard. Booking access is **not** enforced yet. There is no 7-day trial and no Paddle integration.

## Safety

- Browser code uses only the Supabase **anon / publishable** key.
- Privileged reads run in `supabase/functions/admin-control-center` with `service_role` on the server.
- Authorization is `public.platform_admins` (`is_active = true`). `user_profiles.role = 'admin'` means **business owner**, not platform admin.
- This app never inserts `business_settings` and never treats a business owner as a super-admin.

## Local install

```bash
cd admin-control-center
cp .env.example .env.local
# Fill VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (publishable key only)
npm install
npm run dev
```

Open http://localhost:5173

Also required before live data will load (do these only after you approve database/function changes):

1. Apply `../supabase-platform-admins-v1.sql` in the Supabase SQL Editor.
2. Create and allowlist the first platform administrator (see below).
3. Deploy or serve the Edge Function `admin-control-center`.
4. Set secret `ADMIN_CONTROL_CENTER_ALLOWED_ORIGINS` (include `http://localhost:5173`).

Until step 1–3 are done, login may succeed in Auth but the app will show **Allowlist not configured** or **Control Center unavailable**. That is expected.

Phase 3 also requires `../supabase-platform-subscriptions-v1.sql` (not applied by this work) before subscription pages and KPIs will load. Existing businesses stay **unconfigured** until an administrator activates them. Unconfigured is not expired.

```bash
npm run typecheck
npm run build
```

## First super-admin (do not use XBOOK owner signup)

Do **not** register this person in the XBOOK business-owner or customer app. Do **not** set `user_metadata.role` to `admin` or `customer`. Do **not** insert `business_settings` for this UUID.

1. Supabase Dashboard → **Authentication → Users → Add user**
   - Email + password
   - Auto-confirm the email
2. In the SQL Editor, look up the UUID (replace the placeholder only in the editor; do not commit a real email):

```sql
SELECT id, email, created_at
FROM auth.users
WHERE lower(email) = lower('YOUR_ADMIN_EMAIL_HERE');
```

3. Allowlist the user (after `supabase-platform-admins-v1.sql` has been applied):

```sql
INSERT INTO public.platform_admins (user_id, email, is_active, notes)
VALUES (
  'PASTE_AUTH_USER_UUID_HERE',
  'YOUR_ADMIN_EMAIL_HERE',
  true,
  'Initial platform administrator'
)
ON CONFLICT (user_id) DO UPDATE
SET email = EXCLUDED.email,
    is_active = true,
    updated_at = now();
```

4. Sign in at the Control Center with that email and password.

Deactivate without deleting the Auth user:

```sql
UPDATE public.platform_admins
SET is_active = false, updated_at = now()
WHERE user_id = 'PASTE_AUTH_USER_UUID_HERE';
```

## Edge Function (do not deploy until approved)

Source: `../supabase/functions/admin-control-center/`

`POST` JSON `{ "action": "...", ... }` with `Authorization: Bearer <user access token>`.

| action | Purpose |
|---|---|
| `session` | Confirm allowlist membership |
| `overview` | Platform metrics, including subscription KPIs |
| `list_businesses` | Searchable business list |
| `get_business` | One business + owner + counts + subscription snapshot |
| `list_business_customers` | Customers for one `business_id` |
| `list_subscriptions` | Packages, every business, status, summary |
| `list_subscription_history` | Immutable history for one business |
| `preview_subscription` | Server-side price and expiry preview (no write) |
| `apply_subscription` | Activate or extend via atomic RPC |

Subscription writes never accept client price or expiry. The function passes `actor_user_id` from the verified JWT, not from the browser.

When you later approve deploy:

```bash
supabase functions deploy admin-control-center
supabase secrets set ADMIN_CONTROL_CENTER_ALLOWED_ORIGINS="http://localhost:5173"
```

Local function serve (optional):

```bash
supabase functions serve admin-control-center --env-file supabase/secrets.env
```

Then set `VITE_ADMIN_FUNCTION_URL=http://localhost:54321/functions/v1/admin-control-center` in `.env.local`.

## Subscription packages

All three active plans include the same XBOOK features. They differ only in price and calendar-month duration.

| Package | ID | Duration | Price | Effective / month | vs FLEX |
|---|---|---|---|---|---|
| XBOOK FLEX | `flex_monthly` | 1 month | €39.99 | €39.99 | — |
| XBOOK PLUS | `plus_4_months` | 4 months | €119.99 | €30.00 | ~25% |
| XBOOK MAX | `max_18_months` | 18 months | €499.00 | €27.72 | ~30.7% · Best Value |

Legacy `month_1` / `pack_3_1` / `pack_6_2` / `pack_9_3` rows stay in the catalog with `is_active = false` after `supabase-platform-subscriptions-v1-plans.sql`. Do not delete them.

A one-time 7-day trial is granted automatically when a **new** `business_settings` row is first created (Phase 4F SQL). This Control Center can inspect trials and replace them with paid or complimentary access. Booking restrictions are **not** enforced yet.

Expiration uses PostgreSQL calendar-month arithmetic (`date + n * interval '1 month'`). Extending an **active** subscription adds months onto the current expiration so remaining paid access is not lost.

## Metric definitions

| Dashboard label | Definition |
|---|---|
| Total businesses | `count(*)` of `business_settings` |
| Business owners | Same count (one business per owner UUID). **Not** `staff_members`. |
| Registered customer accounts | `user_profiles` where `role = 'customer'` |
| Unique customers linked to businesses | `count(distinct customer_user_id)` on `business_customers` |
| Customer memberships | `business_customers` rows with `customer_user_id` set |
| CRM customer records | All `business_customers` rows |
| Guest CRM records | `business_customers` with null `customer_user_id` |
| Total bookings | `count(*)` of `bookings` when readable |
| Active subscriptions | `business_subscriptions` with `expires_on >= CURRENT_DATE` |
| Expired subscriptions | `business_subscriptions` with `expires_on < CURRENT_DATE` |
| Unconfigured subscriptions | Businesses with no `business_subscriptions` row |

Registration date shown for a business is `user_profiles.created_at` for the owner UUID. Repo SQL does not define `business_settings.created_at`.

## Security review (Phase 3)

**In place**

- No `service_role` in Vite env, source, or browser bundle.
- Separate `storageKey` so Control Center sessions do not share the product app’s local session.
- `verify_jwt = true` plus a second allowlist check inside the function.
- `platform_admins` and the audit table: RLS on, grants revoked from `anon` / `authenticated`.
- CORS is origin-allowlisted (not `*`).
- Responses omit `manage_token`, internal notes, VIP flags, notification private email, and Auth hashes.
- Business owners who sign in with a valid password still receive **403** unless they are on the allowlist.
- Capacitor copy script only copies `index.html`, `manifest.json`, icons, and `vendor` — this folder is not included.
- Subscription writes go through `admin_apply_business_subscription` (atomic, SECURITY DEFINER, service_role execute only).
- Client roles have SELECT/INSERT/UPDATE/DELETE revoked on subscription tables. History is insert-only (trigger blocks UPDATE/DELETE).
- Browser never sends price or expiry; the RPC snapshots catalog values and computes dates.
- Duplicate Activate/Extend clicks reuse an idempotency key so the same request cannot grant twice.

**Residual risks**

- Anyone who obtains the first admin password can use the Control Center. Use a dedicated mailbox and a strong password; enable Auth MFA in the Supabase project if available.
- The Edge Function must be deployed with `SUPABASE_SERVICE_ROLE_KEY` (auto-injected). Do not paste that key into `.env.local`.
- If `ADMIN_CONTROL_CENTER_ALLOWED_ORIGINS` is unset, localhost origins are still allowed for development. Production must set the real admin origin.
- Overview currently scans `business_customers.customer_user_id` to compute distinct people. Fine at current scale; revisit if CRM rows grow very large.
- Live RLS on tenant tables was not re-verified in this phase. The Control Center bypasses those policies only inside the allowlisted Edge Function.

## Cannot verify without inspecting the live database

- Whether `supabase-platform-admins-v1.sql` is applied (it is not applied by this work).
- Whether hardening V1–V4-3 and optional columns (`business_email`, `first_name`, …) are present live. The function falls back when a selected column is missing.
- Exact live `bookings` grants; booking totals are omitted if the count query fails.
- Whether `business_settings` has a `created_at` column (not in repo SQL).
- Production Auth MFA and leaked-password protection settings.
- Current `platform_admins` row count (should be zero until you insert one).
- Whether `supabase-platform-subscriptions-v1.sql` is applied (it is not applied by this work). After apply, `business_subscriptions` must stay empty until an administrator activates a business.
