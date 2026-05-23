# Mobile shell stable checkpoint

Lightweight note — not a full audit. Code frozen at this checkpoint unless a targeted fix is requested.

## Stable

- **Mobile shell works** — customer mobile shell (Home, Book, Bookings, Alerts, Profile) is in place for public booking on small viewports.
- **Bottom nav works** — tab switching, active state, and iPhone-friendly tap handling (including nav portaled above content).
- **Booking UUID bug fixed** — public slug stays in URL/share links; `create_booking` / `create_recurring_bookings` receive resolved `business_id` UUID (not slug).
- **Booking submit works** — guest and logged-in customer booking completion path verified after UUID fix.
- **Recurring still works** — recurring public flow unchanged at RPC/schema level; still uses resolved UUID for submit.

## Protected (do not regress)

- **Manage booking flow** — success → manage details (not wizard Service step); `publicManageMode` / manage-load guards should remain protected when touching public or mobile shell code.

## Deploy

- **Latest stable deploy:** Vercel — `https://booking-app-fawn-five.vercel.app`
- Test public links with `?business=<slug>` (e.g. `my-business-41784a`).

## Next phase (not in this checkpoint)

- Premium mobile visual polish
- PWA install / offline / push — later

---

*Checkpoint note only. No project scan, no ZIP, no `index.html` changes in this step.*
