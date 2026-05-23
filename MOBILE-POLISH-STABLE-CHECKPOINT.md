# Mobile polish stable checkpoint

Lightweight note — not a full audit. Code frozen at this checkpoint unless a targeted fix is requested.

## Stable

- **Mobile shell stable** — customer mobile shell (Home, Book, Bookings, Alerts, Profile) for public booking on small viewports.
- **Bottom nav stable** — tab switching, active state, portaled nav above content, iPhone-friendly taps.
- **Booking flow stable** — service → staff → schedule → details → success; wizard and mobile shell coexist.
- **UUID submit bug fixed** — public URL uses slug; `create_booking` / `create_recurring_bookings` receive resolved `business_id` UUID (not slug).
- **Success screen polished** — premium confirmation layout on mobile (header, summary, manage/calendar CTAs, guest account block).
- **Mobile cards/buttons polished** — consistent radius, shadows, selected states, spacing for service/staff/date pills/time slots/primary CTAs (mobile ≤768px).
- **Transitions/loading polish added** — tab fade/slide, faster step transitions, skeleton shimmer for services/staff/slots on mobile, sticky confirm blur/safe-area, subtle content fade-in.

## Protected (do not regress)

- **Manage booking flow** — success → manage details (not wizard Service step); `publicManageMode` / manage-load guards when touching public or mobile shell code.

## Deploy

- **Latest stable deploy:** Vercel — `https://booking-app-fawn-five.vercel.app`
- Test public links with `?business=<slug>` (e.g. `my-business-41784a`).

## Next phase (not in this checkpoint)

- PWA / app packaging preparation

---

*Checkpoint note only. No project scan, no ZIP, no `index.html` changes in this step.*
