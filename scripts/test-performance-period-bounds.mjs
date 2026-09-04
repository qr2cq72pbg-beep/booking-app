#!/usr/bin/env node
/**
 * Phase 1B: Performance period bounds (business timezone).
 * Mirrors the civil-date builder + Intl zoned parts used in index.html.
 */

function formatDate(year, month, day) {
  return `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function performanceLastDayOfMonth(year, monthIndex) {
  return new Date(year, monthIndex + 1, 0).getDate();
}

function getDateTimePartsInTimeZone(timeZone, instant) {
  const tz = String(timeZone || "").trim();
  const now = instant instanceof Date ? instant : new Date();
  if (!tz || Number.isNaN(now.getTime())) return null;
  try {
    const parts = new Intl.DateTimeFormat("en-GB", {
      timeZone: tz,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      hourCycle: "h23"
    }).formatToParts(now);
    const map = {};
    parts.forEach((part) => {
      if (part.type !== "literal") map[part.type] = part.value;
    });
    const year = Number(map.year);
    const month = Number(map.month);
    const day = Number(map.day);
    const hour = Number(map.hour);
    const minute = Number(map.minute);
    if (![year, month, day, hour, minute].every((n) => Number.isFinite(n))) return null;
    return {
      year,
      monthIndex: month - 1,
      day,
      hour,
      minute,
      dateStr: formatDate(year, month - 1, day)
    };
  } catch (err) {
    return null;
  }
}

function buildPerformanceMonthRange(year, startMonthIndex, endMonthIndex) {
  return {
    startDate: formatDate(year, startMonthIndex, 1),
    endDate: formatDate(year, endMonthIndex, performanceLastDayOfMonth(year, endMonthIndex))
  };
}

function buildPerformancePeriodRange(preset, year, parts) {
  const todayStr = formatDate(parts.year, parts.monthIndex, parts.day);
  const currentYear = parts.year;
  const currentMonth = parts.monthIndex;
  const selectedYear = Number(year) || currentYear;

  switch (preset) {
    case "today":
      return { startDate: todayStr, endDate: todayStr };
    case "this_month":
      return {
        startDate: formatDate(currentYear, currentMonth, 1),
        endDate: formatDate(
          currentYear,
          currentMonth,
          performanceLastDayOfMonth(currentYear, currentMonth)
        )
      };
    case "last_month": {
      const monthIndex = currentMonth === 0 ? 11 : currentMonth - 1;
      const rangeYear = currentMonth === 0 ? currentYear - 1 : currentYear;
      return {
        startDate: formatDate(rangeYear, monthIndex, 1),
        endDate: formatDate(rangeYear, monthIndex, performanceLastDayOfMonth(rangeYear, monthIndex))
      };
    }
    case "q1":
      return buildPerformanceMonthRange(selectedYear, 0, 2);
    case "q2":
      return buildPerformanceMonthRange(selectedYear, 3, 5);
    case "q3":
      return buildPerformanceMonthRange(selectedYear, 6, 8);
    case "q4":
      return buildPerformanceMonthRange(selectedYear, 9, 11);
    case "h1":
      return buildPerformanceMonthRange(selectedYear, 0, 5);
    case "h2":
      return buildPerformanceMonthRange(selectedYear, 6, 11);
    case "ytd":
      return {
        startDate: formatDate(currentYear, 0, 1),
        endDate: todayStr
      };
    default:
      return buildPerformancePeriodRange("this_month", selectedYear, parts);
  }
}

function eq(actual, expected) {
  return actual === expected;
}

function rangeEq(range, start, end) {
  return range.startDate === start && range.endDate === end;
}

const results = [];

function check(name, passed, detail) {
  results.push({ name, passed: !!passed, detail: detail || "" });
}

const skopje = "Europe/Skopje";
const la = "America/Los_Angeles";
const tokyo = "Asia/Tokyo";
const ny = "America/New_York";

// A. Same timezone as device (both Europe/Skopje): 31 Aug 2026 14:00 Skopje = 12:00 UTC
{
  const instant = new Date("2026-08-31T12:00:00.000Z");
  const biz = getDateTimePartsInTimeZone(skopje, instant);
  const device = getDateTimePartsInTimeZone(skopje, instant);
  const range = buildPerformancePeriodRange("this_month", biz.year, biz);
  const ytd = buildPerformancePeriodRange("ytd", biz.year, biz);
  check(
    "A_same_timezone",
    biz.dateStr === device.dateStr &&
      biz.dateStr === "2026-08-31" &&
      rangeEq(range, "2026-08-01", "2026-08-31") &&
      rangeEq(ytd, "2026-01-01", "2026-08-31"),
    `biz=${biz.dateStr} this_month=${range.startDate}..${range.endDate} ytd=${ytd.startDate}..${ytd.endDate}`
  );
}

// B. Device behind business: 31 Aug 22:30 UTC = 1 Sep 00:30 Skopje, 31 Aug 15:30 LA
{
  const instant = new Date("2026-08-31T22:30:00.000Z");
  const biz = getDateTimePartsInTimeZone(skopje, instant);
  const device = getDateTimePartsInTimeZone(la, instant);
  const range = buildPerformancePeriodRange("this_month", null, biz);
  check(
    "B_device_behind_business",
    biz.dateStr === "2026-09-01" &&
      device.dateStr === "2026-08-31" &&
      rangeEq(range, "2026-09-01", "2026-09-30"),
    `biz=${biz.dateStr} device=${device.dateStr} this_month=${range.startDate}..${range.endDate}`
  );
}

// C. Device ahead of business: 1 Sep 06:00 UTC = 31 Aug 23:00 LA, 1 Sep 15:00 Tokyo
{
  const instant = new Date("2026-09-01T06:00:00.000Z");
  const biz = getDateTimePartsInTimeZone(la, instant);
  const device = getDateTimePartsInTimeZone(tokyo, instant);
  const range = buildPerformancePeriodRange("this_month", null, biz);
  const ytd = buildPerformancePeriodRange("ytd", null, biz);
  check(
    "C_device_ahead_of_business",
    biz.dateStr === "2026-08-31" &&
      device.dateStr === "2026-09-01" &&
      rangeEq(range, "2026-08-01", "2026-08-31") &&
      rangeEq(ytd, "2026-01-01", "2026-08-31"),
    `biz=${biz.dateStr} device=${device.dateStr} this_month=${range.startDate}..${range.endDate}`
  );
}

// D. New Year: 31 Dec 2025 23:30 UTC = 1 Jan 2026 00:30 Skopje, 31 Dec 2025 18:30 NY
{
  const instant = new Date("2025-12-31T23:30:00.000Z");
  const biz = getDateTimePartsInTimeZone(skopje, instant);
  const device = getDateTimePartsInTimeZone(ny, instant);
  const ytd = buildPerformancePeriodRange("ytd", null, biz);
  const thisMonth = buildPerformancePeriodRange("this_month", null, biz);
  check(
    "D_new_year_boundary",
    biz.dateStr === "2026-01-01" &&
      device.dateStr === "2025-12-31" &&
      rangeEq(ytd, "2026-01-01", "2026-01-01") &&
      rangeEq(thisMonth, "2026-01-01", "2026-01-31"),
    `biz=${biz.dateStr} device=${device.dateStr} ytd=${ytd.startDate}..${ytd.endDate}`
  );
}

// E. Month-end: 30 Jun 22:00 UTC = 1 Jul 00:00 Skopje, 30 Jun 15:00 LA
{
  const instant = new Date("2026-06-30T22:00:00.000Z");
  const biz = getDateTimePartsInTimeZone(skopje, instant);
  const device = getDateTimePartsInTimeZone(la, instant);
  const range = buildPerformancePeriodRange("this_month", null, biz);
  const last = buildPerformancePeriodRange("last_month", null, biz);
  check(
    "E_month_end",
    biz.dateStr === "2026-07-01" &&
      device.dateStr === "2026-06-30" &&
      rangeEq(range, "2026-07-01", "2026-07-31") &&
      rangeEq(last, "2026-06-01", "2026-06-30"),
    `biz=${biz.dateStr} device=${device.dateStr} this_month=${range.startDate}..${range.endDate} last=${last.startDate}..${last.endDate}`
  );
}

// F. Leap year February 2028
{
  const feb = { year: 2028, monthIndex: 1, day: 10 };
  const range = buildPerformancePeriodRange("this_month", 2028, feb);
  const nonLeap = buildPerformancePeriodRange("this_month", 2027, { year: 2027, monthIndex: 1, day: 10 });
  check(
    "F_leap_year_feb",
    rangeEq(range, "2028-02-01", "2028-02-29") &&
      rangeEq(nonLeap, "2027-02-01", "2027-02-28") &&
      performanceLastDayOfMonth(2028, 1) === 29,
    `2028=${range.endDate} 2027=${nonLeap.endDate}`
  );
}

// G. Quarter 2026 Q4
{
  const parts = { year: 2026, monthIndex: 7, day: 15 };
  const q4 = buildPerformancePeriodRange("q4", 2026, parts);
  const q4hist = buildPerformancePeriodRange("q2", 2025, parts);
  check(
    "G_quarter",
    rangeEq(q4, "2026-10-01", "2026-12-31") && rangeEq(q4hist, "2025-04-01", "2025-06-30"),
    `q4_2026=${q4.startDate}..${q4.endDate} q2_2025=${q4hist.startDate}..${q4hist.endDate}`
  );
}

// H. Half-year 2026
{
  const parts = { year: 2026, monthIndex: 7, day: 15 };
  const h1 = buildPerformancePeriodRange("h1", 2026, parts);
  const h2 = buildPerformancePeriodRange("h2", 2026, parts);
  check(
    "H_half_year",
    rangeEq(h1, "2026-01-01", "2026-06-30") && rangeEq(h2, "2026-07-01", "2026-12-31"),
    `h1=${h1.startDate}..${h1.endDate} h2=${h2.startDate}..${h2.endDate}`
  );
}

// Extra: today + last_month from January + no UTC ISO slice
{
  const instant = new Date("2026-01-15T12:00:00.000Z");
  const biz = getDateTimePartsInTimeZone(skopje, instant);
  const today = buildPerformancePeriodRange("today", null, biz);
  const last = buildPerformancePeriodRange("last_month", null, biz);
  const utcHack = instant.toISOString().slice(0, 10);
  check(
    "today_and_january_last_month",
    rangeEq(today, biz.dateStr, biz.dateStr) &&
      rangeEq(last, "2025-12-01", "2025-12-31") &&
      utcHack !== undefined,
    `today=${today.startDate} last=${last.startDate}..${last.endDate} utcIso=${utcHack}`
  );
}

const failed = results.filter((r) => !r.passed);
for (const r of results) {
  console.log(`${r.passed ? "PASS" : "FAIL"} ${r.name} — ${r.detail}`);
}
if (failed.length) {
  console.error(`\n${failed.length} failed`);
  process.exit(1);
}
console.log(`\nALL_PERIOD_BOUND_TESTS_PASSED (${results.length})`);
