# Required SQL migrations — `stable-recurring-v1-baseline`

Run in **Supabase Dashboard → SQL Editor** unless noted. After any migration that adds columns, **reload the API schema** (Settings → API).

## Core / booking (foundation)

| Order | File | Purpose |
|------:|------|---------|
| 1 | `supabase-fix-working-days.sql` | Working days helper + booking fixes |
| 2 | `supabase-create-booking-full-fix.sql` | `create_booking` RPC baseline |
| 3 | `supabase-fix-reschedule-assert.sql` | Reschedule slot assertion |
| 4 | `supabase-working-hours-overrides.sql` | Per-weekday hours + `_assert_booking_slot_available` + patched `create_booking` |
| 5 | `supabase-reschedule-booking-by-manage-token.sql` | Customer manage reschedule RPC |
| 6 | `supabase-bookings-admin-delete.sql` | Admin delete support (if used) |

## Business profile / branding

| Order | File | Purpose |
|------:|------|---------|
| 7 | `supabase-business-accent-color.sql` | Accent color column |
| 8 | `supabase-business-logos-storage.sql` | Storage bucket / policies for logos |
| 9 | `supabase-business-cover-url.sql` | Cover image URL |
| 10 | `supabase-public-tagline.sql` | Public tagline |
| 11 | `supabase-business-branding-social.sql` | Instagram, Facebook, `public_show_about` |
| 12 | `supabase-staff-photo-url.sql` | Staff photo URL (if staff photos enabled) |

## Onboarding / admin foundation

| Order | File | Purpose |
|------:|------|---------|
| 13 | `supabase-onboarding-phase-a.sql` | Onboarding columns, defaults |

## Customer features

| Order | File | Purpose |
|------:|------|---------|
| 14 | `supabase-customer-my-bookings.sql` | `get_customer_my_bookings()` RPC |

## Recurring V1 (this baseline)

| Order | File | Purpose |
|------:|------|---------|
| 15 | **`supabase-recurring-bookings-v1.sql`** | `allow_recurring_appointments`, booking recurring columns, `create_recurring_bookings` |

## Dependencies (critical)

- **#15 requires #4** (`_assert_booking_slot_available`, `create_booking` context).
- **#14** is independent of recurring.
- Branding files (#7–11) are independent but should run before relying on those columns in the app.

## Edge function (not SQL)

- `supabase/functions/send-booking-email/` — deploy via `supabase/deploy-send-booking-email.sh`
- Secrets: see `supabase/secrets.example.env`

## Post-migration checklist

- [ ] All migrations applied without error
- [ ] API schema reloaded
- [ ] `allow_recurring_appointments` visible in Table Editor
- [ ] `create_recurring_bookings` exists in Database → Functions
- [ ] Test: admin save availability + public repeat UI when ON
