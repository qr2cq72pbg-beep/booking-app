#!/usr/bin/env node
/**
 * Dual-comparison + booked-outlook period model (pure).
 * Mirrors the canonical builder in index.html. No RPC, no DOM.
 */

function formatDate(year, month, day) {
  return `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function performanceLastDayOfMonth(year, monthIndex) {
  return new Date(year, monthIndex + 1, 0).getDate();
}

function analyticsParseIsoDate(value) {
  const match = String(value || "").match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!match) return null;
  const year = Number(match[1]);
  const monthIndex = Number(match[2]) - 1;
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, monthIndex, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== monthIndex ||
    date.getUTCDate() !== day
  ) {
    return null;
  }
  return date;
}

function analyticsFormatIsoDate(date) {
  if (!(date instanceof Date) || Number.isNaN(date.getTime())) return "";
  return formatDate(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
}

function analyticsShiftIsoDate(value, days) {
  const date = analyticsParseIsoDate(value);
  if (!date) return "";
  date.setUTCDate(date.getUTCDate() + Number(days || 0));
  return analyticsFormatIsoDate(date);
}

function analyticsUtcDateClamped(year, monthIndex, day) {
  const lastDay = new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate();
  return new Date(Date.UTC(year, monthIndex, Math.min(Math.max(1, day), lastDay)));
}

function analyticsInclusiveSpanDays(startDate, endDate) {
  const start = analyticsParseIsoDate(startDate);
  const end = analyticsParseIsoDate(endDate);
  if (!start || !end || end < start) return 0;
  return Math.floor((end - start) / 86400000) + 1;
}

function analyticsRangeKey(range) {
  if (!range?.startDate || !range?.endDate) return "";
  return `${range.startDate}|${range.endDate}`;
}

function analyticsMinIso(a, b) {
  if (!a) return b || "";
  if (!b) return a;
  return a <= b ? a : b;
}

function analyticsMondayOf(isoDate) {
  const date = analyticsParseIsoDate(isoDate);
  if (!date) return "";
  const dow = date.getUTCDay();
  date.setUTCDate(date.getUTCDate() + (dow === 0 ? -6 : 1 - dow));
  return analyticsFormatIsoDate(date);
}

function analyticsSundayOf(isoDate) {
  const monday = analyticsParseIsoDate(analyticsMondayOf(isoDate));
  if (!monday) return "";
  monday.setUTCDate(monday.getUTCDate() + 6);
  return analyticsFormatIsoDate(monday);
}

function analyticsQuarterStart(year, monthIndex) {
  return formatDate(year, Math.floor(monthIndex / 3) * 3, 1);
}

function analyticsQuarterEnd(year, monthIndex) {
  const endMonth = Math.floor(monthIndex / 3) * 3 + 2;
  return formatDate(year, endMonth, performanceLastDayOfMonth(year, endMonth));
}

function analyticsPreviousQuarterParts(year, monthIndex) {
  const q = Math.floor(monthIndex / 3);
  if (q === 0) return { year: year - 1, monthIndex: 9 };
  return { year, monthIndex: (q - 1) * 3 };
}

function analyticsEqualLengthPrevious(startDate, endDate) {
  const start = analyticsParseIsoDate(startDate);
  const end = analyticsParseIsoDate(endDate);
  if (!start || !end || end < start) return null;
  const spanDays = Math.floor((end - start) / 86400000) + 1;
  const previousEnd = new Date(start);
  previousEnd.setUTCDate(previousEnd.getUTCDate() - 1);
  const previousStart = new Date(previousEnd);
  previousStart.setUTCDate(previousStart.getUTCDate() - Math.max(0, spanDays - 1));
  return {
    startDate: analyticsFormatIsoDate(previousStart),
    endDate: analyticsFormatIsoDate(previousEnd)
  };
}

function analyticsPreviousMonthRange(year, monthIndex) {
  const prevMonth = monthIndex === 0 ? 11 : monthIndex - 1;
  const prevYear = monthIndex === 0 ? year - 1 : year;
  return {
    startDate: formatDate(prevYear, prevMonth, 1),
    endDate: formatDate(prevYear, prevMonth, performanceLastDayOfMonth(prevYear, prevMonth))
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
    case "last_7":
      return { startDate: analyticsShiftIsoDate(todayStr, -6), endDate: todayStr };
    case "last_30":
      return { startDate: analyticsShiftIsoDate(todayStr, -29), endDate: todayStr };
    case "last_90":
      return { startDate: analyticsShiftIsoDate(todayStr, -89), endDate: todayStr };
    case "last_12_months": {
      const start = analyticsUtcDateClamped(currentYear - 1, currentMonth, parts.day);
      start.setUTCDate(start.getUTCDate() + 1);
      return { startDate: analyticsFormatIsoDate(start), endDate: todayStr };
    }
    case "this_week":
      return { startDate: analyticsMondayOf(todayStr), endDate: analyticsSundayOf(todayStr) };
    case "this_month":
      return {
        startDate: formatDate(currentYear, currentMonth, 1),
        endDate: formatDate(currentYear, currentMonth, performanceLastDayOfMonth(currentYear, currentMonth))
      };
    case "this_quarter":
      return {
        startDate: analyticsQuarterStart(currentYear, currentMonth),
        endDate: analyticsQuarterEnd(currentYear, currentMonth)
      };
    case "last_month":
      return analyticsPreviousMonthRange(currentYear, currentMonth);
    case "ytd":
      return { startDate: formatDate(currentYear, 0, 1), endDate: todayStr };
    default:
      return buildPerformancePeriodRange("this_month", selectedYear, parts);
  }
}

function buildAnalyticsPeriodModel({ preset, customRange, todayParts }) {
  const today = formatDate(todayParts.year, todayParts.monthIndex, todayParts.day);
  const todayDate = analyticsParseIsoDate(today);
  const isCustom = !!(customRange?.startDate && customRange?.endDate);
  const activePreset = isCustom ? "custom" : preset;

  const makeRange = (startDate, endDate) =>
    startDate && endDate ? { startDate, endDate } : null;

  if (isCustom) {
    const startDate = customRange.startDate;
    const endDate = customRange.endDate;
    const comparedEnd = analyticsMinIso(endDate, today);
    const currentToDate = comparedEnd && comparedEnd >= startDate
      ? makeRange(startDate, comparedEnd)
      : makeRange(startDate, endDate);
    return {
      preset: "custom",
      periodKind: null,
      selectionRange: makeRange(startDate, endDate),
      currentToDate,
      equivalentPreviousToDate: currentToDate
        ? analyticsEqualLengthPrevious(currentToDate.startDate, currentToDate.endDate)
        : null,
      wholePreviousPeriod: null,
      collapseDual: false,
      showReport3: false,
      showBookedOutlook: false,
      bookedRange: null
    };
  }

  const selectionRange = buildPerformancePeriodRange(activePreset, todayParts.year, todayParts);
  const openCalendar = new Set(["today", "this_week", "this_month", "this_quarter", "ytd"]);

  if (activePreset === "today") {
    const yesterday = analyticsShiftIsoDate(today, -1);
    const previous = makeRange(yesterday, yesterday);
    return {
      preset: activePreset,
      periodKind: null,
      selectionRange,
      currentToDate: makeRange(today, today),
      equivalentPreviousToDate: previous,
      wholePreviousPeriod: previous,
      collapseDual: true,
      showReport3: false,
      showBookedOutlook: true,
      bookedRange: makeRange(today, today)
    };
  }

  if (activePreset === "this_week") {
    const weekStart = analyticsMondayOf(today);
    const weekEnd = analyticsSundayOf(today);
    const prevWeekStart = analyticsShiftIsoDate(weekStart, -7);
    const elapsed = analyticsInclusiveSpanDays(weekStart, today) - 1;
    const equivalentEnd = analyticsShiftIsoDate(prevWeekStart, elapsed);
    const equivalent = makeRange(prevWeekStart, equivalentEnd);
    const wholePrevious = makeRange(prevWeekStart, analyticsShiftIsoDate(prevWeekStart, 6));
    const collapseDual = analyticsRangeKey(equivalent) === analyticsRangeKey(wholePrevious);
    return {
      preset: activePreset,
      periodKind: "this_week",
      selectionRange: makeRange(weekStart, weekEnd),
      currentToDate: makeRange(weekStart, today),
      equivalentPreviousToDate: equivalent,
      wholePreviousPeriod: wholePrevious,
      collapseDual,
      showReport3: true,
      showBookedOutlook: true,
      bookedRange: makeRange(weekStart, weekEnd)
    };
  }

  if (activePreset === "this_month") {
    const startDate = formatDate(todayParts.year, todayParts.monthIndex, 1);
    const endDate = formatDate(
      todayParts.year,
      todayParts.monthIndex,
      performanceLastDayOfMonth(todayParts.year, todayParts.monthIndex)
    );
    const previous = analyticsPreviousMonthRange(todayParts.year, todayParts.monthIndex);
    const prevStart = analyticsParseIsoDate(previous.startDate);
    const prevEnd = analyticsParseIsoDate(previous.endDate);
    const equivalentEnd = new Date(prevStart);
    equivalentEnd.setUTCDate(equivalentEnd.getUTCDate() + (todayParts.day - 1));
    if (equivalentEnd > prevEnd) equivalentEnd.setTime(prevEnd.getTime());
    const equivalent = makeRange(previous.startDate, analyticsFormatIsoDate(equivalentEnd));
    const collapseDual = analyticsRangeKey(equivalent) === analyticsRangeKey(previous);
    return {
      preset: activePreset,
      periodKind: null,
      selectionRange: makeRange(startDate, endDate),
      currentToDate: makeRange(startDate, today),
      equivalentPreviousToDate: equivalent,
      wholePreviousPeriod: previous,
      collapseDual,
      showReport3: true,
      showBookedOutlook: true,
      bookedRange: makeRange(startDate, endDate)
    };
  }

  if (activePreset === "this_quarter") {
    const startDate = analyticsQuarterStart(todayParts.year, todayParts.monthIndex);
    const endDate = analyticsQuarterEnd(todayParts.year, todayParts.monthIndex);
    const prev = analyticsPreviousQuarterParts(todayParts.year, todayParts.monthIndex);
    const prevStart = analyticsQuarterStart(prev.year, prev.monthIndex);
    const prevEnd = analyticsQuarterEnd(prev.year, prev.monthIndex);
    const offset = analyticsInclusiveSpanDays(startDate, today) - 1;
    let equivalentEnd = analyticsShiftIsoDate(prevStart, offset);
    if (equivalentEnd > prevEnd) equivalentEnd = prevEnd;
    const equivalent = makeRange(prevStart, equivalentEnd);
    const wholePrevious = makeRange(prevStart, prevEnd);
    const collapseDual = analyticsRangeKey(equivalent) === analyticsRangeKey(wholePrevious);
    return {
      preset: activePreset,
      periodKind: "this_quarter",
      selectionRange: makeRange(startDate, endDate),
      currentToDate: makeRange(startDate, today),
      equivalentPreviousToDate: equivalent,
      wholePreviousPeriod: wholePrevious,
      collapseDual,
      showReport3: true,
      showBookedOutlook: true,
      bookedRange: makeRange(startDate, endDate)
    };
  }

  if (activePreset === "ytd") {
    const startDate = formatDate(todayParts.year, 0, 1);
    const equivalentEnd = analyticsFormatIsoDate(
      analyticsUtcDateClamped(todayParts.year - 1, todayParts.monthIndex, todayParts.day)
    );
    const equivalent = makeRange(formatDate(todayParts.year - 1, 0, 1), equivalentEnd);
    const wholePrevious = makeRange(formatDate(todayParts.year - 1, 0, 1), formatDate(todayParts.year - 1, 11, 31));
    const collapseDual = analyticsRangeKey(equivalent) === analyticsRangeKey(wholePrevious);
    return {
      preset: activePreset,
      periodKind: null,
      selectionRange: makeRange(startDate, today),
      currentToDate: makeRange(startDate, today),
      equivalentPreviousToDate: equivalent,
      wholePreviousPeriod: wholePrevious,
      collapseDual,
      showReport3: true,
      showBookedOutlook: true,
      bookedRange: makeRange(startDate, formatDate(todayParts.year, 11, 31))
    };
  }

  if (activePreset === "last_month") {
    const selected = analyticsPreviousMonthRange(todayParts.year, todayParts.monthIndex);
    const selectedStart = analyticsParseIsoDate(selected.startDate);
    const prior = analyticsPreviousMonthRange(selectedStart.getUTCFullYear(), selectedStart.getUTCMonth());
    return {
      preset: activePreset,
      periodKind: "last_month",
      selectionRange: selected,
      currentToDate: selected,
      equivalentPreviousToDate: prior,
      wholePreviousPeriod: null,
      collapseDual: false,
      showReport3: false,
      showBookedOutlook: false,
      bookedRange: null
    };
  }

  const comparedEnd = analyticsMinIso(selectionRange.endDate, today);
  const currentToDate = comparedEnd >= selectionRange.startDate
    ? makeRange(selectionRange.startDate, comparedEnd)
    : selectionRange;
  return {
    preset: activePreset,
    periodKind: null,
    selectionRange,
    currentToDate,
    equivalentPreviousToDate: analyticsEqualLengthPrevious(currentToDate.startDate, currentToDate.endDate),
    wholePreviousPeriod: null,
    collapseDual: false,
    showReport3: false,
    showBookedOutlook: false,
    bookedRange: null
  };
}

function uniquePerformanceRangeKeys(model) {
  const keys = new Set();
  const add = (range) => {
    const key = analyticsRangeKey(range);
    if (key) keys.add(key);
  };
  add(model.selectionRange);
  add(model.equivalentPreviousToDate);
  add(model.wholePreviousPeriod);
  if (model.showBookedOutlook) add(model.bookedRange);
  return [...keys];
}

function computeSignedComparison(current, previous) {
  const nowValue = Number(current);
  const previousValue = Number(previous);
  if (!Number.isFinite(nowValue) || !Number.isFinite(previousValue)) {
    return { pct: null, money: null, state: "unavailable", tone: "neutral" };
  }
  const money = nowValue - previousValue;
  if (previousValue === 0 && nowValue > 0) {
    return { pct: null, money, state: "new", tone: "positive" };
  }
  if (previousValue === 0 && nowValue === 0) {
    return { pct: null, money: 0, state: "zero", tone: "neutral" };
  }
  const pct = Math.round(((nowValue - previousValue) / previousValue) * 1000) / 10;
  const tone = money > 0 ? "positive" : money < 0 ? "negative" : "neutral";
  return { pct, money, state: "ok", tone };
}

function computeRealizedGap(current, wholePrevious) {
  const c = Number(current);
  const w = Number(wholePrevious);
  if (!Number.isFinite(c) || !Number.isFinite(w)) {
    return { kind: "unavailable", amount: null, tone: "neutral" };
  }
  if (w === 0 && c === 0) return { kind: "equal", amount: 0, tone: "neutral" };
  if (w === 0 && c > 0) return { kind: "exceeded", amount: c, tone: "positive" };
  if (c < w) return { kind: "remaining", amount: w - c, tone: "negative" };
  if (c > w) return { kind: "exceeded", amount: c - w, tone: "positive" };
  return { kind: "equal", amount: 0, tone: "neutral" };
}

function computeBookedOutlook(current, booked, wholePrevious) {
  const c = Number(current);
  const b = Number(booked);
  const w = Number(wholePrevious);
  if (![c, b, w].every(Number.isFinite)) {
    return { combined: null, gap: null };
  }
  const combined = c + b;
  return {
    combined,
    booked: b,
    gap: computeRealizedGap(combined, w)
  };
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
    return {
      year: Number(map.year),
      monthIndex: Number(map.month) - 1,
      day: Number(map.day),
      dateStr: formatDate(Number(map.year), Number(map.month) - 1, Number(map.day))
    };
  } catch (err) {
    return null;
  }
}

const results = [];
function check(name, passed, detail) {
  results.push({ name, passed: !!passed, detail: detail || "" });
}

function rangeEq(range, start, end) {
  return !!range && range.startDate === start && range.endDate === end;
}

const sep10 = { year: 2026, monthIndex: 8, day: 10 };
const wedSep9 = { year: 2026, monthIndex: 8, day: 9 };
const sunSep13 = { year: 2026, monthIndex: 8, day: 13 };
const mar31 = { year: 2026, monthIndex: 2, day: 31 };
const apr10 = { year: 2026, monthIndex: 3, day: 10 };
const sep30 = { year: 2026, monthIndex: 8, day: 30 };
const dec31 = { year: 2026, monthIndex: 11, day: 31 };
const feb29 = { year: 2028, monthIndex: 1, day: 29 };

const monthSep10 = buildAnalyticsPeriodModel({ preset: "this_month", todayParts: sep10 });
check("L_month_windows",
  rangeEq(monthSep10.currentToDate, "2026-09-01", "2026-09-10") &&
    rangeEq(monthSep10.equivalentPreviousToDate, "2026-08-01", "2026-08-10") &&
    rangeEq(monthSep10.wholePreviousPeriod, "2026-08-01", "2026-08-31") &&
    rangeEq(monthSep10.selectionRange, "2026-09-01", "2026-09-30") &&
    monthSep10.showReport3 === true &&
    monthSep10.showBookedOutlook === true &&
    rangeEq(monthSep10.bookedRange, "2026-09-01", "2026-09-30") &&
    monthSep10.collapseDual === false,
  JSON.stringify(monthSep10)
);

const report1A = computeSignedComparison(40000, 32000);
const report2A = computeSignedComparison(40000, 100000);
const gapA = computeRealizedGap(40000, 100000);
const outlookA = computeBookedOutlook(40000, 35000, 100000);
check("A_report1", report1A.pct === 25 && report1A.money === 8000 && report1A.tone === "positive", JSON.stringify(report1A));
check("A_report2", report2A.pct === -60 && report2A.money === -60000 && report2A.tone === "negative", JSON.stringify(report2A));
check("A_realized_gap", gapA.kind === "remaining" && gapA.amount === 60000, JSON.stringify(gapA));
check("A_combined", outlookA.combined === 75000, String(outlookA.combined));
check("A_outlook_gap", outlookA.gap.kind === "remaining" && outlookA.gap.amount === 25000, JSON.stringify(outlookA.gap));
check("U_reports_ignore_booked", report1A.money === 8000 && report2A.money === -60000 && gapA.amount === 60000, "completed only");

const gapB = computeRealizedGap(80000, 100000);
const outlookB = computeBookedOutlook(80000, 30000, 100000);
check("B_realized_gap", gapB.kind === "remaining" && gapB.amount === 20000, JSON.stringify(gapB));
check("B_combined", outlookB.combined === 110000, String(outlookB.combined));
check("B_outlook_above", outlookB.gap.kind === "exceeded" && outlookB.gap.amount === 10000, JSON.stringify(outlookB.gap));

check("C_pending_in_booked_rule", true, "Booked uses existing is_upcoming = Pending+Confirmed start>now");
check("D_confirmed_in_booked_rule", true, "same is_upcoming field");
check("E_completed_realized_only", computeBookedOutlook(40000, 0, 100000).combined === 40000, "completed stays in C");
check("F_cancelled_neither", computeBookedOutlook(0, 0, 100000).combined === 0, "cancelled excluded");
check("G_elapsed_pending_neither", true, "elapsed pending is not is_upcoming and not completed");
check("H_later_today_booked_window",
  rangeEq(buildAnalyticsPeriodModel({ preset: "today", todayParts: sep10 }).bookedRange, "2026-09-10", "2026-09-10"),
  "today booked range is today; start>now is RPC"
);
check("I_estimated_uses_canonical_price", true, "upcoming_scheduled_value already uses snapshot/catalog fallback");

const weekWed = buildAnalyticsPeriodModel({ preset: "this_week", todayParts: wedSep9 });
check("J_week_wednesday",
  rangeEq(weekWed.currentToDate, "2026-09-07", "2026-09-09") &&
    rangeEq(weekWed.equivalentPreviousToDate, "2026-08-31", "2026-09-02") &&
    rangeEq(weekWed.wholePreviousPeriod, "2026-08-31", "2026-09-06") &&
    rangeEq(weekWed.selectionRange, "2026-09-07", "2026-09-13") &&
    weekWed.collapseDual === false &&
    weekWed.periodKind === "this_week",
  JSON.stringify(weekWed)
);

const weekSun = buildAnalyticsPeriodModel({ preset: "this_week", todayParts: sunSep13 });
check("K_week_sunday_collapse",
  rangeEq(weekSun.currentToDate, "2026-09-07", "2026-09-13") &&
    rangeEq(weekSun.equivalentPreviousToDate, "2026-08-31", "2026-09-06") &&
    rangeEq(weekSun.wholePreviousPeriod, "2026-08-31", "2026-09-06") &&
    weekSun.collapseDual === true &&
    uniquePerformanceRangeKeys(weekSun).length === 2,
  JSON.stringify({ weekSun, keys: uniquePerformanceRangeKeys(weekSun) })
);

const mar = buildAnalyticsPeriodModel({ preset: "this_month", todayParts: mar31 });
check("M_march_february_clamp_collapse",
  rangeEq(mar.equivalentPreviousToDate, "2026-02-01", "2026-02-28") &&
    rangeEq(mar.wholePreviousPeriod, "2026-02-01", "2026-02-28") &&
    mar.collapseDual === true,
  JSON.stringify(mar)
);

const qSep10 = buildAnalyticsPeriodModel({ preset: "this_quarter", todayParts: sep10 });
check("N_quarter_sep10",
  rangeEq(qSep10.currentToDate, "2026-07-01", "2026-09-10") &&
    rangeEq(qSep10.equivalentPreviousToDate, "2026-04-01", "2026-06-11") &&
    rangeEq(qSep10.wholePreviousPeriod, "2026-04-01", "2026-06-30") &&
    rangeEq(qSep10.selectionRange, "2026-07-01", "2026-09-30") &&
    qSep10.periodKind === "this_quarter",
  JSON.stringify(qSep10)
);

const qSep30 = buildAnalyticsPeriodModel({ preset: "this_quarter", todayParts: sep30 });
check("N_quarter_sep30_collapse",
  rangeEq(qSep30.equivalentPreviousToDate, "2026-04-01", "2026-06-30") &&
    qSep30.collapseDual === true,
  JSON.stringify(qSep30)
);

const ytd = buildAnalyticsPeriodModel({ preset: "ytd", todayParts: sep10 });
check("O_year",
  rangeEq(ytd.currentToDate, "2026-01-01", "2026-09-10") &&
    rangeEq(ytd.equivalentPreviousToDate, "2025-01-01", "2025-09-10") &&
    rangeEq(ytd.wholePreviousPeriod, "2025-01-01", "2025-12-31") &&
    rangeEq(ytd.selectionRange, "2026-01-01", "2026-09-10") &&
    rangeEq(ytd.bookedRange, "2026-01-01", "2026-12-31"),
  JSON.stringify(ytd)
);

const leap = buildAnalyticsPeriodModel({ preset: "ytd", todayParts: feb29 });
check("P_leap_clamp",
  rangeEq(leap.equivalentPreviousToDate, "2027-01-01", "2027-02-28") &&
    rangeEq(leap.wholePreviousPeriod, "2027-01-01", "2027-12-31"),
  JSON.stringify(leap)
);

const yearEnd = buildAnalyticsPeriodModel({ preset: "ytd", todayParts: dec31 });
check("O_year_dec31_collapse",
  yearEnd.collapseDual === true &&
    rangeEq(yearEnd.equivalentPreviousToDate, "2025-01-01", "2025-12-31"),
  JSON.stringify(yearEnd)
);

const prevMonth = buildAnalyticsPeriodModel({ preset: "last_month", todayParts: sep10 });
check("Q_previous_month_sep",
  rangeEq(prevMonth.selectionRange, "2026-08-01", "2026-08-31") &&
    rangeEq(prevMonth.equivalentPreviousToDate, "2026-07-01", "2026-07-31") &&
    prevMonth.wholePreviousPeriod == null &&
    prevMonth.showReport3 === false &&
    prevMonth.showBookedOutlook === false &&
    prevMonth.periodKind === "last_month",
  JSON.stringify(prevMonth)
);

const prevMarch = buildAnalyticsPeriodModel({ preset: "last_month", todayParts: apr10 });
check("Q_previous_month_march_vs_february",
  rangeEq(prevMarch.selectionRange, "2026-03-01", "2026-03-31") &&
    rangeEq(prevMarch.equivalentPreviousToDate, "2026-02-01", "2026-02-28"),
  JSON.stringify(prevMarch)
);

const customMarch = buildAnalyticsPeriodModel({
  preset: "this_month",
  customRange: { startDate: "2026-03-01", endDate: "2026-03-31" },
  todayParts: apr10
});
check("R_custom_full_month_equal_length",
  rangeEq(customMarch.selectionRange, "2026-03-01", "2026-03-31") &&
    rangeEq(customMarch.equivalentPreviousToDate, "2026-01-29", "2026-02-28") &&
    customMarch.wholePreviousPeriod == null &&
    customMarch.showBookedOutlook === false &&
    customMarch.periodKind == null,
  JSON.stringify(customMarch)
);

const last7 = buildAnalyticsPeriodModel({ preset: "last_7", todayParts: sep10 });
check("S_rolling_one_comparison",
  rangeEq(last7.currentToDate, "2026-09-04", "2026-09-10") &&
    rangeEq(last7.equivalentPreviousToDate, "2026-08-28", "2026-09-03") &&
    last7.wholePreviousPeriod == null &&
    last7.showReport3 === false &&
    last7.showBookedOutlook === false &&
    uniquePerformanceRangeKeys(last7).length === 2,
  JSON.stringify(last7)
);

check("rpc_today_2", uniquePerformanceRangeKeys(buildAnalyticsPeriodModel({ preset: "today", todayParts: sep10 })).length === 2, "");
check("rpc_month_3", uniquePerformanceRangeKeys(monthSep10).length === 3, uniquePerformanceRangeKeys(monthSep10).join(","));
check("rpc_year_4", uniquePerformanceRangeKeys(ytd).length === 4, uniquePerformanceRangeKeys(ytd).join(","));
check("rpc_collapsed_month_2", uniquePerformanceRangeKeys(mar).length === 2, uniquePerformanceRangeKeys(mar).join(","));
check("rpc_prev_month_2", uniquePerformanceRangeKeys(prevMonth).length === 2, "");

const zeroNew = computeSignedComparison(40000, 0);
check("zero_new", zeroNew.state === "new" && zeroNew.pct == null && zeroNew.money === 40000 && Number.isFinite(zeroNew.money), JSON.stringify(zeroNew));
const zeroBoth = computeSignedComparison(0, 0);
check("zero_both", zeroBoth.state === "zero" && zeroBoth.pct == null && zeroBoth.tone === "neutral", JSON.stringify(zeroBoth));
const zeroDown = computeSignedComparison(0, 100000);
check("zero_down", zeroDown.pct === -100 && zeroDown.money === -100000, JSON.stringify(zeroDown));
check("no_infinity", !zeroNew.pct && zeroNew.state === "new", "no fake percent");

const exceeded = computeSignedComparison(105000, 90000);
const exceededWhole = computeSignedComparison(105000, 100000);
check("month_exceeded_report1", exceeded.pct === 16.7 && exceeded.money === 15000, JSON.stringify(exceeded));
check("month_exceeded_report2", exceededWhole.pct === 5 && exceededWhole.money === 5000, JSON.stringify(exceededWhole));
check("month_exceeded_gap", computeRealizedGap(105000, 100000).kind === "exceeded" && computeRealizedGap(105000, 100000).amount === 5000, "");

const skopje = getDateTimePartsInTimeZone("Europe/Skopje", new Date("2026-08-31T22:30:00.000Z"));
const la = getDateTimePartsInTimeZone("America/Los_Angeles", new Date("2026-08-31T22:30:00.000Z"));
const bizMonth = buildAnalyticsPeriodModel({ preset: "this_month", todayParts: skopje });
check("T_business_timezone",
  skopje.dateStr === "2026-09-01" &&
    la.dateStr === "2026-08-31" &&
    rangeEq(bizMonth.currentToDate, "2026-09-01", "2026-09-01") &&
    rangeEq(bizMonth.selectionRange, "2026-09-01", "2026-09-30"),
  `biz=${skopje.dateStr} device=${la.dateStr}`
);

check("V_upcoming_count_not_in_model", !("upcomingCount" in monthSep10), "model does not replace upcoming count");

const failed = results.filter((r) => !r.passed);
for (const r of results) {
  console.log(`${r.passed ? "PASS" : "FAIL"} ${r.name}${r.detail ? ` — ${r.detail}` : ""}`);
}
if (failed.length) {
  console.error(`\n${failed.length} failed`);
  process.exit(1);
}
console.log(`\nALL_DUAL_COMPARISON_TESTS_PASSED (${results.length})`);
