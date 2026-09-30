#!/usr/bin/env node
/**
 * Deterministic Client reminder scheduling rules.
 * Mirrors resolveCustomerBookingReminderPlan() in index.html.
 */
const CUSTOMER_REMINDER_1_MINUTES = 24 * 60;
const MIN_LEAD_MS = 5000;
const ALLOWED_R2 = [15, 30, 60, 120, 180, 360, 720];

function normalizeCustomerNotifPrefs(raw) {
  const r2 = Number(raw?.reminder2OffsetMinutes ?? raw?.reminder_2_offset_minutes);
  return {
    appointmentRemindersEnabled: !(
      raw?.appointmentRemindersEnabled === false || raw?.appointment_reminders_enabled === false
    ),
    reminder1Enabled: !(raw?.reminder1Enabled === false || raw?.reminder_1_enabled === false),
    reminder2Enabled: !(raw?.reminder2Enabled === false || raw?.reminder_2_enabled === false),
    reminder2OffsetMinutes: ALLOWED_R2.includes(r2) ? r2 : 120
  };
}

function resolveCustomerBookingReminderPlan(appointmentMs, prefs, nowMs) {
  const appointmentAt = Number(appointmentMs);
  const now = Number(nowMs);
  const plan = [];
  if (!Number.isFinite(appointmentAt) || appointmentAt <= now) return plan;
  const normalized = normalizeCustomerNotifPrefs(prefs);
  if (!normalized.appointmentRemindersEnabled) return plan;

  if (normalized.reminder1Enabled) {
    const remindAt = appointmentAt - CUSTOMER_REMINDER_1_MINUTES * 60 * 1000;
    if (remindAt > now + MIN_LEAD_MS && remindAt < appointmentAt) {
      plan.push({ kind: "r1", offsetKey: "r1-24h", minutes: CUSTOMER_REMINDER_1_MINUTES, remindAt });
    }
  }

  if (normalized.reminder2Enabled) {
    const minutes = normalized.reminder2OffsetMinutes;
    const remindAt = appointmentAt - minutes * 60 * 1000;
    if (minutes !== CUSTOMER_REMINDER_1_MINUTES && remindAt > now + MIN_LEAD_MS && remindAt < appointmentAt) {
      plan.push({ kind: "r2", offsetKey: "r2-" + minutes, minutes, remindAt });
    }
  }
  return plan;
}

function assert(cond, message) {
  if (!cond) {
    console.error("FAIL:", message);
    process.exitCode = 1;
  } else {
    console.log("ok:", message);
  }
}

const now = Date.parse("2026-09-30T10:00:00");
const plus48h = now + 48 * 60 * 60 * 1000;
const plus10h = now + 10 * 60 * 60 * 1000;
const plus10m = now + 10 * 60 * 1000;
const past = now - 60 * 60 * 1000;

const defaults = resolveCustomerBookingReminderPlan(plus48h, {}, now);
assert(defaults.length === 2, "48h appointment schedules r1 + r2 by default");
assert(defaults[0].kind === "r1" && defaults[1].minutes === 120, "default r2 is 2 hours");

const r1Off = resolveCustomerBookingReminderPlan(plus48h, { reminder1Enabled: false }, now);
assert(r1Off.length === 1 && r1Off[0].kind === "r2", "r1 can be disabled independently");

const r2Off = resolveCustomerBookingReminderPlan(plus48h, { reminder2Enabled: false }, now);
assert(r2Off.length === 1 && r2Off[0].kind === "r1", "r2 can be disabled independently");

const bothOff = resolveCustomerBookingReminderPlan(plus48h, { reminder1Enabled: false, reminder2Enabled: false }, now);
assert(bothOff.length === 0, "both disabled schedules nothing");

const lateR1 = resolveCustomerBookingReminderPlan(plus10h, { reminder2OffsetMinutes: 120 }, now);
assert(lateR1.length === 1 && lateR1[0].kind === "r2", "appointment <24h skips r1 and keeps valid r2");

const tooSoon = resolveCustomerBookingReminderPlan(plus10m, { reminder2OffsetMinutes: 15 }, now);
assert(tooSoon.length === 0, "appointment < selected r2 interval skips r2; r1 also skipped");

const r2Past = resolveCustomerBookingReminderPlan(plus10h, { reminder2OffsetMinutes: 720 }, now);
assert(r2Past.length === 0, "r2 12h is skipped when appointment is only 10h away");

const pastAppt = resolveCustomerBookingReminderPlan(past, {}, now);
assert(pastAppt.length === 0, "past appointments are not scheduled");

const invalidR2 = resolveCustomerBookingReminderPlan(plus48h, { reminder2OffsetMinutes: 1440 }, now);
assert(invalidR2.length === 2 && invalidR2[1].minutes === 120, "24h r2 is rejected and falls back to 2h");
assert(invalidR2[0].minutes !== invalidR2[1].minutes, "r2 never duplicates r1");

const masterOff = resolveCustomerBookingReminderPlan(
  plus48h,
  { appointmentRemindersEnabled: false, reminder1Enabled: true, reminder2Enabled: true, reminder2OffsetMinutes: 60 },
  now
);
assert(masterOff.length === 0, "master off schedules nothing even when r1/r2 stay on");
const masterOffPrefs = normalizeCustomerNotifPrefs({
  appointmentRemindersEnabled: false,
  reminder1Enabled: true,
  reminder2Enabled: true,
  reminder2OffsetMinutes: 60
});
assert(
  masterOffPrefs.appointmentRemindersEnabled === false &&
    masterOffPrefs.reminder1Enabled === true &&
    masterOffPrefs.reminder2Enabled === true &&
    masterOffPrefs.reminder2OffsetMinutes === 60,
  "master off does not reset reminder 1/2"
);
const masterOnAgain = resolveCustomerBookingReminderPlan(
  plus48h,
  { appointmentRemindersEnabled: true, reminder1Enabled: true, reminder2Enabled: true, reminder2OffsetMinutes: 60 },
  now
);
assert(masterOnAgain.length === 2 && masterOnAgain[1].minutes === 60, "master on reschedules using saved r1/r2");

if (process.exitCode) {
  console.error("customer reminder plan tests failed");
  process.exit(1);
}
console.log("customer reminder plan tests passed");
