# Known future roadmap — after `stable-recurring-v1-baseline`

Not in this baseline. Listed for planning only.

## Recurring (V2+)

- Recurring series grouping in admin calendar / customer My Bookings
- Edit/cancel entire series vs single occurrence
- Monthly / custom intervals
- Per-occurrence confirmation emails (optional policy)
- Remove temporary `[recurring]` debug logs (see `DEBUG-LOGS-TO-REMOVE.md`)

## Scheduling (advanced — intentionally out of onboarding V1)

- Staff-specific working hours
- Multi-location
- Complex break rules / split shifts
- Minimum notice enforcement on server for public timeline

## Product / SaaS

- Multi-business admin per account (if ever needed)
- Billing / subscription gating
- Analytics dashboard

## UX polish

- Recurring summary on booking success card (“3 appointments booked” + dates list)
- Admin availability: bulk closed-day import
- Deeper My Bookings filters (past vs upcoming tabs)

## Technical debt (safe wins)

- Split `index.html` into modules (only when explicitly approved — **not** during baseline)
- Centralize Supabase migration runner / version table
- E2E smoke tests for public book + recurring + manage link

## Explicit non-goals (remain stable)

- Rewriting admin calendar core architecture
- Rewriting public timeline architecture
- Rewriting `create_booking` for V1 recurring (use additive RPC only)
