/**
 * Local Phase 4C math + reminder-rule checks.
 * Mirrors formulas used in index.html owner subscription UI.
 * Does not call production APIs or write data.
 */
function roundMoney(value) {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function savingsVsFlex(flexPrice, packagePrice, months) {
  const flexTotal = flexPrice * months;
  if (!(flexTotal > 0) || months <= 1) return null;
  return Math.round(((flexTotal - packagePrice) / flexTotal) * 1000) / 10;
}

function utcDateParts(iso) {
  const [year, month, day] = String(iso).split("-").map(Number);
  return Date.UTC(year, month - 1, day);
}

function calendarDaysBetween(fromIso, toIso) {
  return Math.round((utcDateParts(toIso) - utcDateParts(fromIso)) / 86400000);
}

function reminderForAccess(access) {
  if (!access || access.unavailable || access.networkError) return null;
  if (access.status === "unconfigured" || !access.configured) return null;
  if (access.unlimited || access.display_code === "complimentary_unlimited") return null;
  const remaining =
    access.expires_on && access.as_of_date
      ? calendarDaysBetween(access.as_of_date, access.expires_on)
      : null;
  if (access.status === "expired") {
    return { level: "expired", remainingDays: remaining };
  }
  if (access.access_kind === "trial") {
    if (remaining == null) return { level: "normal", remainingDays: remaining };
    if (remaining <= 0) return { level: "urgent", remainingDays: remaining };
    if (remaining <= 3) return { level: "warning", remainingDays: remaining };
    return { level: "normal", remainingDays: remaining };
  }
  if (remaining == null || remaining > 14) return null;
  if (remaining <= 3) return { level: "urgent", remainingDays: remaining };
  return { level: "warning", remainingDays: remaining };
}

function assertEqual(name, actual, expected) {
  const ok = Object.is(actual, expected) || actual === expected;
  if (!ok) {
    throw new Error(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const flex = 39.99;
const plus = { price: 119.99, months: 4 };
const max = { price: 499.0, months: 18 };

assertEqual("plus monthly", roundMoney(plus.price / plus.months), 30.0);
assertEqual("max monthly", roundMoney(max.price / max.months), 27.72);
assertEqual("plus savings", savingsVsFlex(flex, plus.price, plus.months), 25.0);
assertEqual("max savings", savingsVsFlex(flex, max.price, max.months), 30.7);
assertEqual("flex savings", savingsVsFlex(flex, flex, 1), null);

assertEqual("remaining 14", calendarDaysBetween("2026-10-13", "2026-10-27"), 14);
assertEqual("remaining 0", calendarDaysBetween("2026-10-13", "2026-10-13"), 0);

assertEqual(
  "free until changed",
  reminderForAccess({
    configured: true,
    status: "active",
    unlimited: true,
    display_code: "complimentary_unlimited"
  }),
  null
);
assertEqual(
  "unconfigured",
  reminderForAccess({ configured: false, status: "unconfigured" }),
  null
);
assertEqual(
  "network not expired",
  reminderForAccess({ unavailable: false, networkError: true, status: "expired" }),
  null
);
assertEqual(
  "paid 14 warning",
  reminderForAccess({
    configured: true,
    status: "active",
    access_kind: "paid",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-27"
  }).level,
  "warning"
);
assertEqual(
  "paid 3 urgent",
  reminderForAccess({
    configured: true,
    status: "active",
    access_kind: "paid",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-16"
  }).level,
  "urgent"
);
assertEqual(
  "paid 15 none",
  reminderForAccess({
    configured: true,
    status: "active",
    access_kind: "paid",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-28"
  }),
  null
);
assertEqual(
  "expired banner",
  reminderForAccess({
    configured: true,
    status: "expired",
    access_kind: "paid",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-01"
  }).level,
  "expired"
);
assertEqual(
  "trial 4 normal",
  reminderForAccess({
    configured: true,
    status: "active",
    access_kind: "trial",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-17"
  }).level,
  "normal"
);
assertEqual(
  "trial 0 urgent",
  reminderForAccess({
    configured: true,
    status: "active",
    access_kind: "trial",
    as_of_date: "2026-10-13",
    expires_on: "2026-10-13"
  }).level,
  "urgent"
);

console.log("xbook-phase4c-access-math-tests: ok");
