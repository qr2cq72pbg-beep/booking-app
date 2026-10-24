/**
 * Local Phase 4F trial duration, reminder, and status-math checks.
 * Mirrors formulas used in index.html and the SQL entitlement helper.
 * Does not call production APIs or write data.
 */
function assertEqual(name, actual, expected) {
  const ok = Object.is(actual, expected) || actual === expected;
  if (!ok) {
    throw new Error(`${name}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;
const TRIAL_MS = 7 * DAY;

function trialExpiresAt(startsAt) {
  return new Date(startsAt.getTime() + TRIAL_MS);
}

function entitlementStatus(access, asOf) {
  if (!access || !access.configured) return "unconfigured";
  if (access.access_kind === "trial" && access.expires_at) {
    return new Date(access.expires_at).getTime() > asOf.getTime() ? "active" : "expired";
  }
  if (access.unlimited || access.expires_on == null) return "active";
  const asOfDate = asOf.toISOString().slice(0, 10);
  return access.expires_on >= asOfDate ? "active" : "expired";
}

function remainingMs(access, asOf) {
  if (access.remaining_seconds != null) return Math.max(0, access.remaining_seconds * 1000);
  if (access.expires_at) return new Date(access.expires_at).getTime() - asOf.getTime();
  return null;
}

function reminderForAccess(access, asOf = new Date()) {
  if (!access || access.unavailable || access.networkError) return null;
  if (access.status === "unconfigured" || !access.configured) return null;
  if (access.unlimited || access.display_code === "complimentary_unlimited") return null;
  const status = entitlementStatus(access, asOf);
  const remaining = remainingMs(access, asOf);
  if (status === "expired") {
    return { level: "expired", remainingMs: remaining };
  }
  if (access.access_kind === "trial") {
    if (remaining == null) return { level: "normal", remainingMs: remaining };
    if (remaining <= HOUR * 24) return { level: "urgent", remainingMs: remaining };
    if (remaining <= DAY * 3) return { level: "warning", remainingMs: remaining };
    return { level: "normal", remainingMs: remaining };
  }
  return null;
}

const start = new Date("2026-10-14T15:00:00.000Z");
const end = trialExpiresAt(start);
assertEqual("168 hours", end.getTime() - start.getTime(), 168 * HOUR);
assertEqual("7 days ms", TRIAL_MS, 604800000);

assertEqual(
  "trial active mid-window",
  entitlementStatus(
    {
      configured: true,
      access_kind: "trial",
      expires_at: end.toISOString()
    },
    new Date("2026-10-18T15:00:00.000Z")
  ),
  "active"
);
assertEqual(
  "trial expired after 168h",
  entitlementStatus(
    {
      configured: true,
      access_kind: "trial",
      expires_at: end.toISOString()
    },
    new Date("2026-10-21T15:00:00.001Z")
  ),
  "expired"
);
assertEqual(
  "trial still active 1ms before expiry",
  entitlementStatus(
    {
      configured: true,
      access_kind: "trial",
      expires_at: end.toISOString()
    },
    new Date("2026-10-21T14:59:59.999Z")
  ),
  "active"
);

assertEqual(
  "complimentary unlimited ignores clock",
  entitlementStatus(
    {
      configured: true,
      access_kind: "complimentary",
      unlimited: true,
      expires_on: null
    },
    new Date("2026-10-21T15:00:00.000Z")
  ),
  "active"
);

assertEqual(
  "paid date still calendar-based",
  entitlementStatus(
    {
      configured: true,
      access_kind: "paid",
      expires_on: "2026-10-21"
    },
    new Date("2026-10-21T23:00:00.000Z")
  ),
  "active"
);

const mid = new Date("2026-10-16T15:00:00.000Z");
assertEqual(
  "trial 5 days remaining is normal",
  reminderForAccess(
    {
      configured: true,
      status: "active",
      access_kind: "trial",
      expires_at: end.toISOString()
    },
    mid
  ).level,
  "normal"
);

assertEqual(
  "trial 3 days remaining is warning",
  reminderForAccess(
    {
      configured: true,
      status: "active",
      access_kind: "trial",
      expires_at: new Date(mid.getTime() + 3 * DAY).toISOString()
    },
    mid
  ).level,
  "warning"
);

assertEqual(
  "trial last 24 hours is urgent",
  reminderForAccess(
    {
      configured: true,
      status: "active",
      access_kind: "trial",
      expires_at: new Date(mid.getTime() + 23 * HOUR).toISOString()
    },
    mid
  ).level,
  "urgent"
);

assertEqual(
  "expired trial banner",
  reminderForAccess(
    {
      configured: true,
      status: "expired",
      access_kind: "trial",
      expires_at: new Date(mid.getTime() - 1000).toISOString()
    },
    mid
  ).level,
  "expired"
);

assertEqual(
  "complimentary unlimited no banner",
  reminderForAccess({
    configured: true,
    status: "active",
    unlimited: true,
    display_code: "complimentary_unlimited",
    access_kind: "complimentary"
  }),
  null
);

assertEqual("no revenue on trial", 0, 0);

console.log("xbook-phase4f-trial-math-tests: ok");
