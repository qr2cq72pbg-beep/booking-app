# Temporary debug logs — remove before production hardening

Search in `index.html` for prefix: **`[recurring]`**

| Location (approx.) | Type | Message / purpose |
|--------------------|------|-------------------|
| `loadPublicData` | `console.log` | `[recurring] loaded public setting` + boolean |
| `readAllowRecurringAppointmentsSetting` | `console.debug` | Missing column from payload / schema hint |
| `loadBusinessSettings` | `console.warn` | `allow_recurring_appointments select failed` |
| `loadBusinessSettings` | `console.log` | `loadBusinessSettings allow_recurring_appointments=` |
| `saveAvailabilitySettings` | `console.debug` | Save payload |
| `saveAvailabilitySettings` | `console.warn` | Retry / error / no row / catch |
| `saveAvailabilitySettings` | `console.debug` | Save succeeded |
| `saveBusinessSettings` | `console.warn` / `console.debug` | Legacy full-settings save path (if still used) |
| `syncPublicRecurringBookingUi` | `console.log` | `enabled=` flag |

## Removal checklist

1. Grep: `\[recurring\]`
2. Delete or gate behind `const DEBUG_RECURRING = false` if you want a single switch later.
3. Keep user-facing copy: `availabilitySaveStatus`, toasts (“Availability saved.”), and `formatAvailabilitySaveError` schema message — those are **not** debug logs.

## Keep (not temporary)

- `RECURRING_BOOKINGS_UNAVAILABLE_MSG` user error string
- `setAvailabilitySaveStatus` / `#availabilitySaveStatus` inline admin feedback
