#!/usr/bin/env node
/**
 * Phase 5C: Staff Analytics UI V1.
 * Mirrors index.html display helpers. Does not aggregate bookings or call SQL.
 */

import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

function t(_key, fallback) {
  return fallback;
}

function formatPerformanceCount(value) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  return String(Math.trunc(Number(value)));
}

function formatBusinessMoney(amount) {
  if (amount == null || !Number.isFinite(Number(amount))) return "—";
  const n = Number(amount);
  const formatted = n.toLocaleString("en-US", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 0
  });
  return `${formatted} MKD`;
}

function formatCustomerAnalyticsPct(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  const rounded = Math.round(n * 10) / 10;
  if (Number.isInteger(rounded)) return `${rounded}%`;
  return `${rounded}%`;
}

function isStaffAnalyticsResponseStale(request, current) {
  if (!request || !current) return true;
  if (request.requestId !== current.requestId) return true;
  if (String(request.bizId || "") !== String(current.bizId || "")) return true;
  if (String(request.fromDate || "") !== String(current.fromDate || "")) return true;
  if (String(request.toDate || "") !== String(current.toDate || "")) return true;
  return false;
}

function shouldShowStaffAnalyticsEstimatedNote(quality) {
  return !!(quality && quality.contains_estimated_prices === true);
}

function shouldShowStaffAnalyticsCancellation(row) {
  const n = Number(row && row.cancelled_bookings);
  return Number.isFinite(n) && n > 0;
}

function isStaffAnalyticsUnassigned(row) {
  return !!(row && row.is_unassigned === true);
}

function isStaffAnalyticsOrphan(row) {
  return !!(row && row.is_orphan === true);
}

function isStaffAnalyticsInactive(row) {
  return !!(row && row.is_active === false && row.is_orphan !== true && row.is_unassigned !== true);
}

function shouldShowStaffAnalyticsUnassignedWarning(quality) {
  return !!(quality && quality.has_material_unassigned_history === true);
}

function staffAnalyticsRankBucket(row) {
  if (isStaffAnalyticsUnassigned(row)) return 3;
  if (isStaffAnalyticsOrphan(row)) return 2;
  const visits = Number(row && row.completed_visits);
  if (Number.isFinite(visits) && visits > 0) return 0;
  return 1;
}

function sortStaffAnalyticsRows(staff) {
  const rows = Array.isArray(staff) ? staff.slice() : [];
  rows.sort((a, b) => {
    const ba = staffAnalyticsRankBucket(a);
    const bb = staffAnalyticsRankBucket(b);
    if (ba !== bb) return ba - bb;
    const av = Number(a && a.completed_visits);
    const bv = Number(b && b.completed_visits);
    const ar = Number(a && a.completed_revenue);
    const br = Number(b && b.completed_revenue);
    const visitsA = Number.isFinite(av) ? av : 0;
    const visitsB = Number.isFinite(bv) ? bv : 0;
    const revA = Number.isFinite(ar) ? ar : 0;
    const revB = Number.isFinite(br) ? br : 0;
    if (visitsB !== visitsA) return visitsB - visitsA;
    if (revB !== revA) return revB - revA;
    const nameCmp = String((a && a.display_name) || "").localeCompare(String((b && b.display_name) || ""), undefined, {
      sensitivity: "base"
    });
    if (nameCmp) return nameCmp;
    return String((a && a.group_key) || "").localeCompare(String((b && b.group_key) || ""), undefined, {
      sensitivity: "base"
    });
  });
  return rows;
}

function formatServiceAnalyticsTrend(trend) {
  const status = trend && typeof trend === "object" ? String(trend.status || "") : "";
  if (status === "new") return t("saTrendNew", "New");
  if (status === "no_change") return t("saTrendNoChange", "No change");
  if (status === "not_applicable") return t("saTrendNA", "N/A");
  const n = Number(trend && trend.pct);
  const abs = Number.isFinite(n) ? formatCustomerAnalyticsPct(Math.abs(n)).replace(/%$/, "") : null;
  if (status === "increase") {
    return abs == null ? t("saTrendNA", "N/A") : `+${abs}%`;
  }
  if (status === "decrease") {
    return abs == null ? t("saTrendNA", "N/A") : `-${abs}%`;
  }
  return t("saTrendNA", "N/A");
}

function formatServiceAnalyticsTrendLine(trend, kind) {
  const dim = kind === "revenue" ? t("saTrendRevenueLabel", "Revenue") : t("saTrendVisitsLabel", "Visits");
  const status = trend && typeof trend === "object" ? String(trend.status || "") : "";
  const value = formatServiceAnalyticsTrend(trend);
  if (status === "increase") {
    return `${dim} ↑ ${String(value).replace(/^\+/, "")}`;
  }
  if (status === "decrease") {
    return `${dim} ↓ ${String(value).replace(/^-/, "")}`;
  }
  return `${dim} ${value}`;
}

function formatServiceAnalyticsShare(pct, kind) {
  const of = kind === "revenue" ? t("saOfRevenue", "of revenue") : t("saOfVisits", "of visits");
  if (pct == null || pct === "") return t("saTrendNA", "N/A");
  const n = Number(pct);
  if (!Number.isFinite(n)) return t("saTrendNA", "N/A");
  return `${formatCustomerAnalyticsPct(n)} ${of}`;
}

function formatServiceAnalyticsComparisonLabel(payload) {
  const type = String((payload && payload.comparison_type) || "");
  if (type === "elapsed_mtd") {
    return t("saComparedElapsed", "Compared with equivalent elapsed period");
  }
  if (type === "not_applicable" || !(payload && payload.previous_from)) {
    return t("saComparedPrevious", "Compared with previous period");
  }
  return t("saComparedPrevious", "Compared with previous period");
}

function formatStaffAnalyticsVisitsLine(count) {
  const n = Number(count);
  if (Number.isFinite(n) && n === 1) return t("staCompletedVisitOne", "1 completed visit");
  return t("staCompletedVisitsLine", "{n} completed visits").replace("{n}", formatPerformanceCount(count));
}

function formatStaffAnalyticsCustomers(count) {
  if (count == null || count === "") return "—";
  const n = Number(count);
  if (!Number.isFinite(n)) return "—";
  if (n === 1) return t("staCustomerOne", "1 customer");
  return t("staCustomersCount", "{n} customers").replace("{n}", formatPerformanceCount(n));
}

function formatStaffAnalyticsServices(count) {
  if (count == null || count === "") return "—";
  const n = Number(count);
  if (!Number.isFinite(n)) return "—";
  if (n === 1) return t("staServiceOne", "1 service");
  return t("staServicesCount", "{n} services").replace("{n}", formatPerformanceCount(n));
}

function formatStaffAnalyticsUpcoming(count) {
  const n = Number(count);
  if (!Number.isFinite(n) || n <= 0) return "";
  return t("staUpcomingCount", "{n} upcoming").replace("{n}", formatPerformanceCount(n));
}

function formatStaffAnalyticsCancelledLine(row) {
  if (!shouldShowStaffAnalyticsCancellation(row)) return "";
  const countLabel = `${formatPerformanceCount(row.cancelled_bookings)} ${t("staCancelled", "cancelled")}`;
  const rate = row && row.cancellation_rate;
  if (rate == null || rate === "" || !Number.isFinite(Number(rate))) return countLabel;
  return `${countLabel} · ${formatCustomerAnalyticsPct(rate)}`;
}

function formatStaffAnalyticsCompletedMinutes(count) {
  if (count == null || count === "") return "";
  const n = Number(count);
  if (!Number.isFinite(n)) return "";
  return t("staCompletedMinLine", "{n} completed min").replace("{n}", formatPerformanceCount(n));
}

function formatStaffAnalyticsUpcomingMinutes(count) {
  const n = Number(count);
  if (!Number.isFinite(n) || n <= 0) return "";
  return t("staUpcomingMinLine", "{n} upcoming min").replace("{n}", formatPerformanceCount(n));
}

function formatStaffAnalyticsTeamActivity(summary) {
  const n = summary && summary.staff_with_period_activity;
  const total = summary && summary.active_team_size;
  if (n == null || n === "" || total == null || total === "" || !Number.isFinite(Number(n)) || !Number.isFinite(Number(total))) {
    return "—";
  }
  return t("staTeamActivityValue", "{n} of {total} active")
    .replace("{n}", formatPerformanceCount(n))
    .replace("{total}", formatPerformanceCount(total));
}

function formatStaffAnalyticsUnassignedShareKpi(pct) {
  if (pct == null || pct === "") return t("saTrendNA", "N/A");
  const n = Number(pct);
  if (!Number.isFinite(n)) return t("saTrendNA", "N/A");
  return t("staUnassignedShareValue", "{n} unassigned").replace("{n}", formatCustomerAnalyticsPct(n));
}

function formatStaffAnalyticsUnassignedWarning(quality, summary) {
  if (!shouldShowStaffAnalyticsUnassignedWarning(quality)) return "";
  const base = t("staUnassignedWarning", "A significant share of completed visits is unassigned to staff.");
  const pct =
    quality && quality.unassigned_visit_share_pct != null && quality.unassigned_visit_share_pct !== ""
      ? quality.unassigned_visit_share_pct
      : summary && summary.unassigned_visit_share_pct;
  if (pct == null || pct === "" || !Number.isFinite(Number(pct))) return base;
  return `${base} ${t("staUnassignedWarningPct", "{n} of completed visits are unassigned.").replace(
    "{n}",
    formatCustomerAnalyticsPct(pct)
  )}`;
}

let passed = 0;
function assert(cond, name) {
  if (!cond) {
    console.error(`FAIL: ${name}`);
    process.exitCode = 1;
    return;
  }
  passed += 1;
}

const staJsStart = html.indexOf("let staffAnalyticsReportRequestId");
const staJsEnd = html.indexOf("function refreshAdminStaffAnalyticsIfActive");
const staJs = staJsStart >= 0 && staJsEnd > staJsStart ? html.slice(staJsStart, staJsEnd) : "";
const fetchFnStart = html.indexOf("async function fetchBusinessStaffAnalytics");
const fetchFn = fetchFnStart >= 0 ? html.slice(fetchFnStart, html.indexOf("async function runAdminStaffAnalyticsReport")) : "";
const runFnStart = html.indexOf("async function runAdminStaffAnalyticsReport");
const runFn = runFnStart >= 0 ? html.slice(runFnStart, html.indexOf("function renderAdminStaffAnalytics")) : "";
const paintListStart = html.indexOf("function paintStaffAnalyticsCard");
const paintList = paintListStart >= 0 ? html.slice(paintListStart, html.indexOf("function paintStaffAnalyticsPayload")) : "";
const paintSummaryStart = html.indexOf("function paintStaffAnalyticsSummary");
const paintSummary = paintSummaryStart >= 0 ? html.slice(paintSummaryStart, html.indexOf("function paintStaffAnalyticsCard")) : "";
const staCssStart = html.indexOf("/* Staff Analytics — ranking cards");
const staCss = staCssStart >= 0 ? html.slice(staCssStart, html.indexOf("/* Customer Analytics — presentation extras")) : "";
const staffSectionStart = html.indexOf('<section id="adminSectionStaffAnalytics"');
const staffSectionEnd = html.indexOf('<section id="adminSectionProfile"');
const staffSection = staffSectionStart >= 0 && staffSectionEnd > staffSectionStart ? html.slice(staffSectionStart, staffSectionEnd) : "";
const bottomNavStart = html.indexOf('id="adminMobileBottomNav"');
const bottomNav = bottomNavStart >= 0 ? html.slice(bottomNavStart, html.indexOf("</nav>", bottomNavStart)) : "";

const augustStefan = {
  group_key: "4737854b-b339-42b5-b8b5-81a5480d1f38",
  staff_id: "4737854b-b339-42b5-b8b5-81a5480d1f38",
  display_name: "Stefan",
  role: "Barber",
  photo_url: "https://example.com/stefan.jpg",
  is_active: true,
  is_unassigned: false,
  is_orphan: false,
  completed_visits: 17,
  completed_revenue: 6000,
  unique_customers: 2,
  services_delivered: 3,
  visit_share_pct: 100,
  revenue_share_pct: 100,
  visit_trend: { status: "increase", pct: 6.3 },
  revenue_trend: { status: "increase", pct: 33.3 },
  completed_minutes: 360,
  upcoming_minutes: 0,
  upcoming_bookings: 0,
  cancelled_bookings: 0,
  scheduled_bookings: 0
};

const ytdUnassigned = {
  group_key: "unassigned",
  staff_id: null,
  display_name: "Unassigned",
  role: null,
  photo_url: null,
  is_active: false,
  is_unassigned: true,
  is_orphan: false,
  completed_visits: 29,
  completed_revenue: 7100,
  unique_customers: 2,
  services_delivered: 3,
  visit_share_pct: 35.4,
  revenue_share_pct: 30.6,
  visit_trend: { status: "increase", pct: 10 },
  revenue_trend: { status: "increase", pct: 10 },
  completed_minutes: 200,
  upcoming_minutes: 0,
  upcoming_bookings: 0,
  cancelled_bookings: 0,
  scheduled_bookings: 0
};

const ytdStefan = {
  ...augustStefan,
  completed_visits: 53,
  completed_revenue: 16100,
  visit_share_pct: 64.6,
  revenue_share_pct: 69.4
};

const septemberStefan = {
  ...augustStefan,
  completed_visits: 1,
  completed_revenue: 500,
  unique_customers: 1,
  services_delivered: 1,
  visit_trend: { status: "new", pct: null },
  revenue_trend: { status: "new", pct: null },
  completed_minutes: 30,
  upcoming_minutes: 30,
  upcoming_bookings: 1,
  scheduled_bookings: 2
};

const septemberUnassigned = {
  ...ytdUnassigned,
  completed_visits: 0,
  completed_revenue: 0,
  unique_customers: 0,
  services_delivered: 0,
  visit_share_pct: null,
  revenue_share_pct: null,
  visit_trend: { status: "not_applicable", pct: null },
  revenue_trend: { status: "not_applicable", pct: null },
  completed_minutes: 0,
  upcoming_minutes: 30,
  upcoming_bookings: 1,
  scheduled_bookings: 1
};

const inactiveStaff = {
  group_key: "inactive-1",
  display_name: "Ana",
  role: "Barber",
  is_active: false,
  is_unassigned: false,
  is_orphan: false,
  completed_visits: 4,
  completed_revenue: 1200,
  unique_customers: 1,
  services_delivered: 1,
  visit_trend: { status: "decrease", pct: -10 },
  revenue_trend: { status: "no_change", pct: 0 },
  completed_minutes: 80,
  upcoming_bookings: 0,
  cancelled_bookings: 2,
  cancellation_rate: 3.6
};

const orphanStaff = {
  group_key: "orphan-1",
  display_name: "Unknown staff",
  role: null,
  is_active: false,
  is_unassigned: false,
  is_orphan: true,
  completed_visits: 2,
  completed_revenue: 400,
  unique_customers: 1,
  services_delivered: 1,
  visit_trend: { status: "not_applicable", pct: null },
  revenue_trend: { status: "not_applicable", pct: null },
  completed_minutes: 40,
  upcoming_bookings: 0,
  cancelled_bookings: 0
};

const augustSummary = {
  top_staff_by_visits: { display_name: "Stefan", completed_visits: 17 },
  top_staff_by_revenue: { display_name: "Stefan", completed_revenue: 6000 },
  staff_with_period_activity: 1,
  active_team_size: 1,
  unassigned_visit_share_pct: 0
};

/* 1 navigation */
assert(html.includes('data-admin-section="staff-analytics"'), "1 Staff Analytics navigation entry exists");
assert(html.includes('id="adminSectionStaffAnalytics"'), "1 section panel");
assert(html.includes("setAdminSection('staff-analytics')"), "2 mobile Quick Action exists");
assert(
  html.indexOf('data-admin-section="service-analytics"') < html.indexOf('data-admin-section="staff-analytics"') &&
    html.indexOf('data-admin-section="performance"') < html.indexOf('data-admin-section="customer-analytics"'),
  "1 desktop analytics order Performance → Customer → Service → Staff"
);

/* 3 no new bottom tab */
assert(!bottomNav.includes("staff-analytics"), "3 no new bottom tab");
assert(!bottomNav.includes("data-admin-mobile-tab=\"staff-analytics\""), "3 no staff-analytics mobile tab");
assert(html.includes('overview: "overview"') && html.includes('settings: "profile"'), "3 existing tabs remain");

/* 4–7 mobile Back */
assert(html.includes('id="staffHomeBackBtn"'), "4 mobile Back exists");
assert(staffSection.includes("onclick=\"setAdminSection('overview')\""), "5 Back → setAdminSection('overview')");
assert(staffSection.includes('class="admin-ca-seg-back"') && staffSection.includes('data-i18n="commonBack"'), "4 Back reuses admin-ca-seg-back / commonBack");
assert(staCss.includes("#adminSectionStaffAnalytics") || html.includes("#adminSectionStaffAnalytics"), "6 Back protected via shared analytics chrome");
assert(
  html.includes(
    "body.admin-mobile-shell-active #adminView :is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-performance-screen__header .admin-ca-seg-back"
  ),
  "6 Back protected from width:100%"
);
assert(
  html.includes(
    ":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-performance-screen__header .admin-ca-seg-back"
  ) && html.includes("display: none"),
  "7 desktop Back hidden"
);

/* 8–14 RPC */
assert((fetchFn.match(/sb\.rpc\(/g) || []).length === 1, "8 one RPC call");
assert(fetchFn.includes('sb.rpc("get_business_staff_analytics"'), "9 correct RPC name");
assert(fetchFn.includes("p_business_id: bizId"), "10 business id passed");
assert(fetchFn.includes("p_from_date: range.startDate") && fetchFn.includes("p_to_date: range.endDate"), "11 from/to passed");
assert(!fetchFn.includes(".from(\"bookings\")") && !fetchFn.includes("filterBookingsForPerformanceRange"), "12 no booking fetch");
assert(!runFn.includes("get_business_performance_report") && !staJs.includes("computePerformance"), "12 no Performance fallback");
assert(!staJs.includes("completed_visits +") && !paintList.includes("visit_share_pct =") && !paintSummary.includes("Math.max"), "13 no JS metric recompute");
assert(
  isStaffAnalyticsResponseStale(
    { requestId: 1, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 2, bizId: "a", fromDate: "2026-09-01", toDate: "2026-09-30" }
  ),
  "13 stale period response blocked"
);
assert(
  isStaffAnalyticsResponseStale(
    { requestId: 3, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 3, bizId: "biz-b", fromDate: "2026-08-01", toDate: "2026-08-31" }
  ),
  "14 stale business response blocked"
);
assert(
  !isStaffAnalyticsResponseStale(
    { requestId: 4, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 4, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" }
  ),
  "14 matching request not stale"
);
assert(runFn.includes("isStaffAnalyticsResponseStale") && runFn.includes("paintStaffAnalyticsLoadingSkeleton"), "42 loading clears old cards");

/* 15–19 summary */
assert(html.includes('data-i18n="staTopByVisits"') && html.includes('id="staKpiVisitsName"'), "15 Top Staff by Visits renders");
assert(html.includes('data-i18n="staTopByRevenue"') && html.includes('id="staKpiRevenueValue"'), "16 Top Staff by Revenue renders");
assert(html.includes('data-i18n="staTeamActivity"') && html.includes('id="staKpiTeam"'), "17 Team Activity renders");
assert(html.includes('data-i18n="staUnassignedShare"') && html.includes('id="staKpiUnassignedShare"'), "18 Unassigned Share renders");
assert(paintSummary.includes("summary.top_staff_by_visits") && paintSummary.includes("summary.top_staff_by_revenue"), "19 uses backend summary");
assert(!paintSummary.includes("payload.staff") && !paintSummary.includes("is_unassigned"), "19 Unassigned cannot be recomputed as Top Staff");
assert(formatStaffAnalyticsTeamActivity(augustSummary) === "1 of 1 active", "17 Team Activity format");
assert(formatStaffAnalyticsUnassignedShareKpi(0) === "0% unassigned", "18 known zero share");
assert(formatStaffAnalyticsUnassignedShareKpi(35.4) === "35.4% unassigned", "18 YTD unassigned share");
assert(formatStaffAnalyticsUnassignedShareKpi(null) === "N/A", "18 null share is N/A");

/* 20–25 real staff card */
assert(paintList.includes("formatStaffAnalyticsVisitsLine(row && row.completed_visits)"), "20 real staff card shows visits");
assert(paintList.includes("formatBusinessMoney(row && row.completed_revenue"), "21 revenue");
assert(paintList.includes("unique_customers") && paintList.includes("formatStaffAnalyticsCustomers"), "22 customers");
assert(paintList.includes("services_delivered") && paintList.includes("formatStaffAnalyticsServices"), "23 services delivered");
assert(paintList.includes('formatStaffAnalyticsTrendLine(visitTrend, "visits")'), "24 visit trend");
assert(paintList.includes('formatStaffAnalyticsTrendLine(revenueTrend, "revenue")'), "24 revenue trend");
assert(paintList.includes("completed_minutes") && paintList.includes("formatStaffAnalyticsCompletedMinutes"), "25 completed minutes");
assert(formatStaffAnalyticsVisitsLine(17) === "17 completed visits", "20 visits line");
assert(formatBusinessMoney(6000) === "6,000 MKD", "21 money formatting");
assert(formatStaffAnalyticsCustomers(2) === "2 customers", "22 customers format");
assert(formatStaffAnalyticsServices(3) === "3 services", "23 services format");
assert(formatServiceAnalyticsTrendLine(augustStefan.visit_trend, "visits") === "Visits ↑ 6.3%", "24 visit trend format");
assert(formatServiceAnalyticsTrendLine(augustStefan.revenue_trend, "revenue") === "Revenue ↑ 33.3%", "24 revenue trend format");
assert(formatStaffAnalyticsCompletedMinutes(360) === "360 completed min", "25 minutes format");

/* 26–29 conditional / labels */
assert(formatStaffAnalyticsUpcoming(0) === "", "26 upcoming hidden when 0");
assert(formatStaffAnalyticsUpcoming(1) === "1 upcoming", "26 upcoming when >0");
assert(paintList.includes("upcoming_bookings") && paintList.includes("formatStaffAnalyticsUpcoming"), "26 upcoming conditional");
assert(!shouldShowStaffAnalyticsCancellation({ cancelled_bookings: 0 }), "27 hide 0 cancelled");
assert(shouldShowStaffAnalyticsCancellation({ cancelled_bookings: 2 }), "27 show cancelled >0");
assert(formatStaffAnalyticsCancelledLine({ cancelled_bookings: 2, cancellation_rate: 3.6 }) === "2 cancelled · 3.6%", "27 cancellation line");
assert(formatStaffAnalyticsCancelledLine({ cancelled_bookings: 0, cancellation_rate: 0 }) === "", "27 no 0 cancelled line");
assert(isStaffAnalyticsInactive(inactiveStaff) && paintList.includes("staInactive"), "28 inactive label");
assert(isStaffAnalyticsOrphan(orphanStaff) && paintList.includes("staOrphan"), "29 orphan label");
assert(!isStaffAnalyticsInactive(orphanStaff), "29 orphan is not labeled Inactive");

/* 30–34 Unassigned */
const mixed = sortStaffAnalyticsRows([ytdUnassigned, ytdStefan, orphanStaff, inactiveStaff]);
assert(mixed.some((r) => r.is_unassigned), "30 Unassigned card visible");
assert(mixed[mixed.length - 1].is_unassigned === true, "31 Unassigned rendered last");
assert(mixed[0].display_name === "Stefan", "31 real completed staff first");
assert(paintList.includes("admin-sta-card--unassigned") && staJs.includes("staffAnalyticsUnassignedMarkHtml"), "32 Unassigned not styled as employee");
assert(!paintList.includes("staffMemberInitials") || paintList.includes("isStaffAnalyticsUnassigned(row)"), "32 Unassigned never uses fake initials path after unassigned check");
assert(staJs.includes("if (isStaffAnalyticsUnassigned(row)) return staffAnalyticsUnassignedMarkHtml()"), "32 Unassigned skips person avatar");
const thisMonth = sortStaffAnalyticsRows([septemberUnassigned, septemberStefan]);
assert(thisMonth.some((r) => r.is_unassigned && r.completed_visits === 0 && r.upcoming_bookings === 1), "33 Unassigned upcoming-only row remains");
assert(thisMonth[thisMonth.length - 1].is_unassigned === true, "33 upcoming-only Unassigned still last");
assert(!thisMonth.every((r) => Number(r.completed_visits) > 0), "33 do not filter by completed_visits > 0");
assert(shouldShowStaffAnalyticsUnassignedWarning({ has_material_unassigned_history: true }), "34 material unassigned warning when true");
assert(!shouldShowStaffAnalyticsUnassignedWarning({ has_material_unassigned_history: false }), "34 warning hidden when false");
assert(html.includes("shouldShowStaffAnalyticsUnassignedWarning") && html.includes("has_material_unassigned_history"), "34 conditional quality note");
assert(
  formatStaffAnalyticsUnassignedWarning(
    { has_material_unassigned_history: true, unassigned_visit_share_pct: 35.4 },
    { unassigned_visit_share_pct: 35.4 }
  ).includes("35.4%"),
  "34 warning may include percentage"
);

/* 35–36 estimated + comparison */
assert(shouldShowStaffAnalyticsEstimatedNote({ contains_estimated_prices: true }), "35 estimated note when true");
assert(!shouldShowStaffAnalyticsEstimatedNote({ contains_estimated_prices: false }), "35 estimated note hidden when false");
assert(html.includes("formatServiceAnalyticsEstimatedNote") && html.includes("staffAnalyticsEstimatedNote"), "35 estimated price note conditional");
assert(html.includes("Historical values include estimated service prices."), "35 EN estimated copy");
assert(html.includes("staffAnalyticsCompareLabel") && html.includes("formatServiceAnalyticsComparisonLabel"), "36 comparison context renders");
assert(formatServiceAnalyticsComparisonLabel({ comparison_type: "elapsed_mtd", previous_from: "2026-08-01" }) === "Compared with equivalent elapsed period", "36 elapsed wording");
assert(formatServiceAnalyticsComparisonLabel({ comparison_type: "previous_period", previous_from: "2026-07-01" }) === "Compared with previous period", "36 previous wording");
assert(!paintList.includes("comparison_type"), "36 technical comparison_type not on cards");

/* 37–40 no utilization / no detail */
const utilizationHits = (staJs + paintList + staffSection).match(/Utili[sz]ation|Utilized|Capacity|Available hours|Working-day/gi) || [];
assert(utilizationHits.length === 0, "37 no utilization copy");
assert(!staJs.includes("/ 60") && !staJs.includes("available_hours") && !paintList.includes("completed_minutes /"), "38 no utilization frontend math");
assert(!html.includes("openStaffDetail") && !html.includes("staff-detail") && !staffSection.includes("chevron"), "39 no Staff Detail");
assert(paintList.includes('<article class="') && !paintList.includes("onclick") && !paintList.includes("role=\"button\""), "40 cards not tappable");
assert(staCss.includes("cursor: default") && staCss.includes("pointer-events: none"), "40 cards have no tap affordance");

/* 41–43 empty / loading / error */
assert(html.includes('id="staffAnalyticsEmpty"') && html.includes("No staff activity in this period."), "41 empty state");
assert(html.includes("staff.length === 0"), "41 empty when staff array empty");
assert(html.includes("paintStaffAnalyticsLoadingSkeleton") && html.includes("admin-sta-skel"), "42 loading state");
assert(html.includes('id="staffAnalyticsError"') && html.includes('id="staffAnalyticsRetryBtn"'), "43 error + Retry");
assert(html.includes("Failed to load staff analytics") && html.includes("staRetry"), "43 error copy");

/* 44–46 i18n */
assert(html.includes('commonStaffAnalytics: "Staff Analytics"'), "44 EN Staff Analytics");
assert(html.includes('staTopByVisits: "Top Staff by Visits"') && html.includes('staTopByRevenue: "Top Staff by Revenue"'), "44 EN summary strings");
assert(html.includes('staTeamActivity: "Team Activity"') && html.includes('staUnassignedShare: "Unassigned Share"'), "44 EN team/unassigned");
assert(html.includes('staUnassigned: "Unassigned"') && html.includes("Bookings without an assigned staff member."), "44 EN Unassigned");
assert(html.includes('staInactive: "Inactive"') && html.includes("Archived / missing staff"), "44 EN inactive/orphan");
assert(html.includes("A significant share of completed visits is unassigned to staff."), "44 EN unassigned warning");
assert(html.includes('commonStaffAnalytics: "Аналитика на вработени"'), "45 MK Staff Analytics");
assert(html.includes("Нема активност на вработени во овој период."), "45 MK empty");
assert(html.includes("Значителен дел од реализираните посети се без вработен."), "45 MK unassigned warning");
assert(html.includes("Термини без доделен вработен."), "45 MK unassigned hint");
assert(html.includes('staInactive: "Неактивен"'), "45 MK Inactive");
assert(html.includes('commonStaffAnalytics: "Analitika e stafit"'), "46 SQ Staff Analytics");
assert(html.includes("Nuk ka aktivitet stafi në këtë periudhë."), "46 SQ empty");
assert(html.includes('staInactive: "Joaktiv"'), "46 SQ Inactive");
assert(html.includes("Rezervime pa anëtar stafi të caktuar."), "46 SQ unassigned hint");

/* 47–51 existing analytics unchanged */
assert(html.includes('id="adminSectionPerformance"') && html.includes("performanceKpiCompletedRevenue"), "47 Performance unchanged");
assert(html.includes("get_business_performance_report"), "47 Performance RPC unchanged");
assert(html.includes('id="adminSectionCustomerAnalytics"') && html.includes("caKpiActive"), "48 Customer Analytics unchanged");
assert(html.includes('id="adminSectionServiceAnalytics"') && html.includes("saKpiUsed"), "49 Service Analytics unchanged");
assert(html.includes('sb.rpc("get_business_service_analytics"'), "49 Service Analytics RPC unchanged");
assert(html.includes('id="caDetVipBtn"') && html.includes("caDetMarkVip: \"Mark VIP\""), "50 VIP unchanged");
assert(html.includes("caDetNotesTitle: \"Internal Notes\"") && html.includes('id="caDetNotesCard"'), "50 Notes unchanged");
assert(html.includes('id="saHomeBackBtn"') && html.includes('id="perfHomeBackBtn"') && html.includes('id="caHomeBackBtn"'), "51 analytics Home Back unchanged");
assert(html.includes("onclick=\"setAdminSection('overview')\""), "51 Home Back destination unchanged");

/* 52 no SQL */
assert(!html.includes("CREATE OR REPLACE FUNCTION public.get_business_staff_analytics"), "52 no SQL in index.html");
assert(!staJs.includes("CREATE OR REPLACE"), "52 no SQL in Staff JS");
let sqlDiff = "";
try {
  sqlDiff = execSync(
    "git diff --name-only -- supabase-get-business-staff-analytics.sql supabase-get-business-staff-analytics-tests.sql",
    { cwd: root, encoding: "utf8" }
  ).trim();
} catch {
  sqlDiff = "git-error";
}
assert(sqlDiff === "", `52 no SQL files changed (${sqlDiff || "clean"})`);

/* period reuse */
assert(html.includes("staffAnalyticsPresetChips") && html.includes("getActivePerformancePeriodRange"), "D period reuse");
assert(staffSection.includes('data-performance-preset="this_month"') && staffSection.includes('data-performance-preset="last_month"') && staffSection.includes('data-performance-preset="ytd"'), "D shared presets");
assert(html.includes("staffAnalyticsCustomStartMonth") && html.includes("commitPerformanceCustomRangeFromPrefix(\"staffAnalyticsCustom\")"), "D custom range shared");
assert(html.includes("staffAnalyticsCacheKey") && html.includes("p_business_id"), "E cache by business + period");

/* Last Month / YTD / This Month parity helpers */
assert(augustSummary.top_staff_by_visits.display_name === "Stefan" && augustSummary.top_staff_by_visits.completed_visits === 17, "U Last Month top visits");
assert(formatBusinessMoney(augustSummary.top_staff_by_revenue.completed_revenue) === "6,000 MKD", "U Last Month top revenue");
assert(sortStaffAnalyticsRows([augustStefan]).every((r) => !r.is_unassigned), "U Last Month no Unassigned row");
assert(formatStaffAnalyticsVisitsLine(53) === "53 completed visits" && formatBusinessMoney(16100) === "16,100 MKD", "V YTD Stefan");
assert(formatStaffAnalyticsVisitsLine(29) === "29 completed visits" && formatBusinessMoney(7100) === "7,100 MKD", "V YTD Unassigned");
assert(formatServiceAnalyticsShare(64.6, "visits") === "64.6% of visits", "N Stefan visit share");
assert(formatServiceAnalyticsShare(35.4, "visits") === "35.4% of visits", "N Unassigned visit share");
assert(formatStaffAnalyticsUpcomingMinutes(30) === "30 upcoming min", "L upcoming minutes when >0");
assert(formatStaffAnalyticsUpcomingMinutes(0) === "", "L upcoming minutes hidden when 0");
assert(formatStaffAnalyticsCompletedMinutes(null) === "", "34 null minutes not coerced to 0");
assert(formatServiceAnalyticsTrendLine({ status: "new", pct: null }, "visits") === "Visits New", "M New trend");
assert(formatServiceAnalyticsTrendLine({ status: "no_change", pct: 0 }, "revenue") === "Revenue No change", "M no change");
assert(formatServiceAnalyticsTrendLine({ status: "not_applicable", pct: null }, "revenue") === "Revenue N/A", "M N/A");
assert(formatServiceAnalyticsTrend({ status: "increase", pct: -12 }) === "+12%", "M status not inferred from pct sign");

/* mobile / desktop */
assert(staCss.includes("overflow-x: hidden"), "R mobile no-overflow");
assert(staCss.includes("word-break: break-word") && staCss.includes("overflow-wrap: anywhere"), "R names wrap");
assert(staCss.includes("min-height: 44px"), "R 44px retry target");
assert(staCss.includes("minmax(140px, 1fr)"), "R two-column metrics wrap");
assert(staCss.includes("repeat(4, minmax(0, 1fr))"), "S desktop 4-col summary");
assert(!staCss.includes("overflow-x: auto") && !staCss.includes("overflow-x: scroll"), "R no horizontal scroll");
assert(!paintList.includes("new_customers") && !paintList.includes("returning_customers"), "14 new/returning not on main card");
assert(!staffSection.includes("<table"), "S no desktop table");

console.log(`staff-analytics-ui: ${passed} passed`);
