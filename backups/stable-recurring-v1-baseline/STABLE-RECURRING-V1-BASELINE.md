# PRODUCTION-CANDIDATE BASELINE V1

**Label / version:** `stable-recurring-v1-baseline`  
**Date:** 2026-05-20  
**Status:** New stable foundation — do not refactor from this snapshot without explicit planning.

---

## What this baseline is

A point-in-time backup of the booking app after **Recurring Bookings V1** and the preceding customer/admin polish phases. Architecture is unchanged: single-file app (`index.html`) + Supabase SQL migrations + Edge Function for email.

This build is marked **PRODUCTION-CANDIDATE BASELINE V1** — suitable as the reference branch/tag before the next major features.

---

## Stable systems included

| System | Notes |
|--------|--------|
| Admin scheduling timeline | Interactive week timeline, add/edit booking flow |
| Public weekly timeline | Customer slot selection, preview blocks |
| Hover line + preview | Timeline hover / slot preview UX |
| Customer auth / session | Login, signup, session restore, hub vs booking routing |
| QR / business auto-detect | URL `?business=` slug, manual entry, hub context |
| Customer My Bookings calendar | Month view, lists, day detail, manage links |
| Branding / white-label | Logo, cover, accent, layouts, tagline, social, visibility toggles |
| Onboarding polish | Fullscreen wizard, roadmap, launch screen |
| **Recurring bookings V1** | Weekly / biweekly, max 6, admin toggle, `create_recurring_bookings` RPC |
| Emails / manage booking | Resend edge function, create/cancel/reschedule, manage token flow |
| Recurring SQL | `supabase-recurring-bookings-v1.sql` |
| Branding SQL | Social, tagline, cover, accent, logos storage, etc. |

---

## Version notes / changelog (baseline scope)

### Recurring bookings V1
- Business setting: `allow_recurring_appointments` (default OFF).
- Admin: Availability → “Allow recurring appointments” + dedicated **Save availability** (`saveAvailabilitySettings`).
- Public: Optional repeat UI on Details step (No repeat / Weekly / Every 2 weeks, count 2–6).
- Server: `create_recurring_bookings` — all-or-nothing validation via `_assert_booking_slot_available`.
- Bookings metadata: `recurring_group_id`, `recurring_index`, `recurring_total`, `recurring_rule`.
- Single confirmation email for first occurrence in a series (minimal email change).

### Customer My Bookings
- `get_customer_my_bookings()` RPC + calendar UI in customer hub.

### Branding / white-label
- Theme presets, public layout, social links, show/hide toggles.
- SQL: branding, tagline, cover, accent, Instagram/Facebook, `public_show_about`.

### Onboarding polish
- Step copy, roadmap pills, launch screen, helper callouts (UI only).

### Auth / public routing
- Customer hub vs booking when URL has business slug.
- Separate login/signup panels; QR/link persistence fixes.

### Prior stable core (unchanged in this baseline)
- `create_booking` RPC + slot assertion (working hours, breaks, blocked days, conflicts).
- Per-weekday `working_hours_overrides`.
- Admin/public timelines and hover preview.
- Manage booking cancel/reschedule + emails.

---

## Repository layout at baseline

```
booking appp/
├── index.html                          # Full app (UI + CSS + JS)
├── supabase-*.sql                      # Root SQL migrations (run in order — see below)
├── supabase/
│   ├── config.toml
│   ├── functions/send-booking-email/
│   ├── deploy-send-booking-email.sh
│   ├── verify-email-live.sh
│   └── secrets.example.env
└── backups/stable-recurring-v1-baseline/
    ├── STABLE-RECURRING-V1-BASELINE.md  (this file)
    ├── SQL-MIGRATIONS-ORDER.md
    ├── FUTURE-ROADMAP.md
    ├── DEBUG-LOGS-TO-REMOVE.md
    └── MANIFEST.txt
```

---

## Restore instructions

1. Unzip `stable-recurring-v1-baseline.zip` to a clean directory.
2. Deploy SQL in order from `SQL-MIGRATIONS-ORDER.md` on a **fresh** or **existing** Supabase project (additive migrations use `IF NOT EXISTS` where possible).
3. **Reload Supabase API schema** after recurring (and any new) migrations.
4. Deploy Edge Function `send-booking-email` per `supabase/deploy-send-booking-email.sh`.
5. Open `index.html` via static host or local server; set `SUPABASE_URL` / `SUPABASE_ANON_KEY` in file if needed.

---

## Git reference (optional)

If restoring from repo instead of ZIP, tag this commit:

```bash
git tag -a stable-recurring-v1-baseline -m "PRODUCTION-CANDIDATE BASELINE V1"
```

---

## Do not do from this snapshot

- No admin calendar core rewrite
- No public timeline engine rewrite
- No `create_booking` rewrite
- No advanced recurring editor / monthly rules / endless series

See `FUTURE-ROADMAP.md` for planned next work.
