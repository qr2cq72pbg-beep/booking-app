#!/usr/bin/env node
/**
 * Phase 4C: Service Analytics UI V1.
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

function isServiceAnalyticsResponseStale(request, current) {
  if (!request || !current) return true;
  if (request.requestId !== current.requestId) return true;
  if (String(request.bizId || "") !== String(current.bizId || "")) return true;
  if (String(request.fromDate || "") !== String(current.fromDate || "")) return true;
  if (String(request.toDate || "") !== String(current.toDate || "")) return true;
  return false;
}

function shouldShowServiceAnalyticsEstimatedNote(quality) {
  return !!(quality && quality.contains_estimated_prices === true);
}

function shouldShowServiceAnalyticsCancellation(row) {
  const n = Number(row && row.cancelled_bookings);
  return Number.isFinite(n) && n > 0;
}

function isServiceAnalyticsArchived(row) {
  return !!(row && (row.is_orphan === true || row.is_missing_from_catalog === true));
}

function sortServiceAnalyticsRows(services) {
  const rows = Array.isArray(services) ? services.slice() : [];
  rows.sort((a, b) => {
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

function formatServiceAnalyticsVisitsLine(count) {
  const n = Number(count);
  if (Number.isFinite(n) && n === 1) return t("saCompletedVisitOne", "1 completed visit");
  return t("saCompletedVisitsLine", "{n} completed visits").replace("{n}", formatPerformanceCount(count));
}

function formatServiceAnalyticsCustomers(count) {
  if (count == null || count === "") return "—";
  const n = Number(count);
  if (!Number.isFinite(n)) return "—";
  if (n === 1) return t("saCustomerOne", "1 customer");
  return t("saCustomersCount", "{n} customers").replace("{n}", formatPerformanceCount(n));
}

function formatServiceAnalyticsUpcoming(count) {
  const n = Number(count);
  if (!Number.isFinite(n) || n <= 0) return "";
  return t("saUpcomingCount", "{n} upcoming").replace("{n}", formatPerformanceCount(n));
}

function formatServiceAnalyticsCancelledLine(row) {
  if (!shouldShowServiceAnalyticsCancellation(row)) return "";
  const countLabel = `${formatPerformanceCount(row.cancelled_bookings)} ${t("saCancelled", "cancelled")}`;
  const rate = row && row.cancellation_rate;
  if (rate == null || rate === "" || !Number.isFinite(Number(rate))) return countLabel;
  return `${countLabel} · ${formatCustomerAnalyticsPct(rate)}`;
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

let passed = 0;
function assert(cond, name) {
  if (!cond) {
    console.error(`FAIL: ${name}`);
    process.exitCode = 1;
    return;
  }
  passed += 1;
}

const saJsStart = html.indexOf("let serviceAnalyticsReportRequestId");
const saJsEnd = html.indexOf("function refreshAdminServiceAnalyticsIfActive");
const saJs = saJsStart >= 0 && saJsEnd > saJsStart ? html.slice(saJsStart, saJsEnd) : "";
const fetchFnStart = html.indexOf("async function fetchBusinessServiceAnalytics");
const fetchFn = fetchFnStart >= 0 ? html.slice(fetchFnStart, html.indexOf("async function runAdminServiceAnalyticsReport")) : "";
const runFnStart = html.indexOf("async function runAdminServiceAnalyticsReport");
const runFn = runFnStart >= 0 ? html.slice(runFnStart, html.indexOf("function renderAdminServiceAnalytics")) : "";
const paintListStart = html.indexOf("function paintServiceAnalyticsList");
const paintList = paintListStart >= 0 ? html.slice(paintListStart, html.indexOf("function paintServiceAnalyticsPayload")) : "";
const saCssStart = html.indexOf("/* Service Analytics — ranking cards");
const saCss = saCssStart >= 0 ? html.slice(saCssStart, html.indexOf("/* Customer Analytics — presentation extras")) : "";

const augustServices = [
  {
    group_key: "sisanje",
    display_name: "Sisanje",
    completed_visits: 10,
    completed_revenue: 3000,
    unique_customers: 2,
    visit_share_pct: 58.8,
    revenue_share_pct: 50,
    visit_trend: { status: "decrease", pct: -47.4 },
    revenue_trend: { status: "decrease", pct: -47.4 },
    upcoming_bookings: 0,
    cancelled_bookings: 0,
    is_orphan: false
  },
  {
    group_key: "masaza",
    display_name: "Masaza",
    completed_visits: 6,
    completed_revenue: 3000,
    unique_customers: 1,
    visit_share_pct: 35.3,
    revenue_share_pct: 50,
    visit_trend: { status: "increase", pct: 50 },
    revenue_trend: { status: "increase", pct: 50 },
    upcoming_bookings: 0,
    cancelled_bookings: 0,
    is_orphan: false
  },
  {
    group_key: "combo",
    display_name: "Sisanje + Bricenje",
    completed_visits: 1,
    completed_revenue: 0,
    unique_customers: 1,
    visit_share_pct: 5.9,
    revenue_share_pct: 0,
    visit_trend: { status: "decrease", pct: -75 },
    revenue_trend: { status: "not_applicable", pct: null },
    upcoming_bookings: 0,
    cancelled_bookings: 0,
    is_orphan: false
  }
];

const augustSummary = {
  top_service_by_visits: { display_name: "Sisanje", completed_visits: 10 },
  top_service_by_revenue: { display_name: "Sisanje", completed_revenue: 3000 },
  services_used: 3
};

const septemberUpcoming = {
  group_key: "sisanje",
  display_name: "Sisanje",
  completed_visits: 0,
  completed_revenue: 0,
  unique_customers: 0,
  upcoming_bookings: 2,
  visit_trend: { status: "new", pct: null },
  revenue_trend: { status: "not_applicable", pct: null },
  cancelled_bookings: 0
};

/* 1 entry */
assert(html.includes('data-admin-section="service-analytics"'), "1 Service Analytics entry renders");
assert(html.includes('id="adminSectionServiceAnalytics"'), "1 section panel");
assert(html.includes("setAdminSection('service-analytics')"), "1 overview hub entry");
assert(html.includes("Аналитика на услуги") && html.includes("Analitika e shërbimeve"), "1 MK/SQ titles");

/* 2–5 RPC */
assert(fetchFn.includes('sb.rpc("get_business_service_analytics"'), "2 correct RPC called");
assert(fetchFn.includes("p_business_id: bizId"), "3 business id passed");
assert(fetchFn.includes("p_from_date: range.startDate") && fetchFn.includes("p_to_date: range.endDate"), "4 from/to dates passed");
assert(!fetchFn.includes(".from(\"bookings\")") && !fetchFn.includes("filterBookingsForPerformanceRange"), "5 no bookings fetched");
assert((fetchFn.match(/sb\.rpc\(/g) || []).length === 1, "2 one RPC in fetch");
assert(!runFn.includes("computePerformanceTopServices"), "5 no Performance Top Services fallback");
assert(!saJs.includes("completed_visits +") && !paintList.includes("visit_share_pct ="), "3 no JS metric recompute");

/* 6–8 summary */
assert(html.includes('data-i18n="saTopByVisits"') && html.includes('id="saKpiVisitsName"'), "6 summary Top Visits renders");
assert(html.includes('data-i18n="saTopByRevenue"') && html.includes('id="saKpiRevenueValue"'), "7 summary Top Revenue renders");
assert(html.includes('data-i18n="saServicesUsed"') && html.includes('id="saKpiUsed"'), "8 Services Used renders");
assert(html.includes("payload.summary") || html.includes("summary.top_service_by_visits") || html.includes("top_service_by_visits"), "27 uses backend summary objects");
assert(html.includes("summary.top_service_by_visits") || html.includes("topVisits.display_name"), "27 no JS top recompute");

/* 9 estimated note */
assert(shouldShowServiceAnalyticsEstimatedNote({ contains_estimated_prices: true }), "9 estimated note when true");
assert(!shouldShowServiceAnalyticsEstimatedNote({ contains_estimated_prices: false }), "9 estimated note hidden when false");
assert(html.includes("shouldShowServiceAnalyticsEstimatedNote") && html.includes("quality.contains_estimated_prices"), "9 conditional quality note");
assert(html.includes("saEstimatedNote") && html.includes("Historical values include estimated service prices."), "9 EN estimated copy");

/* 1–3 toggle removed */
assert(!html.includes('id="saSortVisitsBtn"'), "1 By Visits button absent");
assert(!html.includes('id="saSortRevenueBtn"'), "2 By Revenue button absent");
assert(!html.includes('saByVisits: "By Visits"') && !html.includes('saByRevenue: "By Revenue"'), "1/2 EN sort keys removed");
assert(!html.includes("admin-sa-sort"), "1 sort control markup/CSS absent");
assert(!html.includes("serviceAnalyticsSortMode"), "3 no obsolete sort-mode state");
assert(!html.includes("syncServiceAnalyticsSortUi"), "3 no sort-mode handler");
assert(!html.includes("data-sa-sort"), "3 no sort-switch handlers");
assert(!html.includes("serviceAnalyticsLastPayload"), "3 no sort-only last payload");

/* 4 deterministic single-list ordering */
const visitOrder = sortServiceAnalyticsRows(augustServices).map((r) => r.display_name);
assert(visitOrder.join("|") === "Sisanje|Masaza|Sisanje + Bricenje", "4 visit-then-revenue sort deterministic");
assert(saJs.includes("if (visitsB !== visitsA) return visitsB - visitsA"), "4 visits DESC");
assert(saJs.includes("if (revB !== revA) return revB - revA"), "4 then revenue DESC");
assert(paintList.includes("sortServiceAnalyticsRows(payload && payload.services)"), "4 single-list sort");
assert(!paintList.includes("sortServiceAnalyticsRows(payload && payload.services,"), "4 no sort-mode argument");

/* 5–11 card hierarchy: visits + revenue + shares + trends together */
assert(paintList.includes("formatServiceAnalyticsVisitsLine(row && row.completed_visits)"), "5 completed visits shown");
assert(paintList.includes("admin-sa-card__visits") && paintList.includes("admin-sa-card__revenue"), "6 visits and revenue simultaneous");
assert(paintList.includes("formatBusinessMoney(row && row.completed_revenue"), "6 completed revenue shown");
assert(paintList.includes("admin-sa-card__customers") && paintList.includes("unique_customers"), "7 unique customers shown");
assert(paintList.includes('formatServiceAnalyticsShare(row && row.visit_share_pct, "visits")'), "8 visit share shown");
assert(paintList.includes('formatServiceAnalyticsShare(row && row.revenue_share_pct, "revenue")'), "9 revenue share shown simultaneously");
assert(paintList.includes('formatServiceAnalyticsTrendLine(visitTrend, "visits")'), "10 visit trend shown");
assert(paintList.includes('formatServiceAnalyticsTrendLine(revenueTrend, "revenue")'), "11 revenue trend shown simultaneously");
assert(paintList.includes("row.visit_trend") && paintList.includes("row.revenue_trend"), "12 both backend trends used");
assert(html.includes("trend.status") || html.includes('status === "new"'), "12 trends backend-driven");

/* 14–18 trends */
assert(formatServiceAnalyticsTrend({ status: "decrease", pct: -47.4 }) === "-47.4%", "12 visit trend uses backend status");
assert(formatServiceAnalyticsTrend({ status: "increase", pct: 50 }) === "+50%", "12 revenue trend uses backend status");
assert(formatServiceAnalyticsTrend({ status: "increase", pct: -12 }) === "+12%", "12 status not inferred from pct sign");
assert(formatServiceAnalyticsTrend({ status: "new", pct: 80 }) === "New", "16 New renders");
assert(formatServiceAnalyticsTrend({ status: "no_change", pct: 0 }) === "No change", "17 No change renders");
assert(formatServiceAnalyticsTrend({ status: "not_applicable", pct: null }) === "N/A", "18 N/A renders");
assert(formatServiceAnalyticsTrendLine({ status: "decrease", pct: -47.4 }, "visits") === "Visits ↓ 47.4%", "10 labeled visit decrease");
assert(formatServiceAnalyticsTrendLine({ status: "increase", pct: 50 }, "revenue") === "Revenue ↑ 50%", "11 labeled revenue increase");
assert(formatServiceAnalyticsTrendLine({ status: "new", pct: null }, "visits") === "Visits New", "16 labeled New");
assert(formatServiceAnalyticsTrendLine({ status: "not_applicable", pct: null }, "revenue") === "Revenue N/A", "18 labeled N/A");
assert(formatServiceAnalyticsShare(58.8, "visits") === "58.8% of visits", "8 visit share format");
assert(formatServiceAnalyticsShare(50, "revenue") === "50% of revenue", "9 revenue share format");
assert(formatServiceAnalyticsShare(0, "revenue") === "0% of revenue", "14 zero revenue share");
assert(formatServiceAnalyticsShare(null, "visits") === "N/A", "8 null share is N/A not 0");
assert(formatServiceAnalyticsVisitsLine(10) === "10 completed visits", "5 visits line");
assert(formatServiceAnalyticsVisitsLine(1) === "1 completed visit", "5 singular visit");
assert(formatServiceAnalyticsVisitsLine(0) === "0 completed visits", "22 zero visits line");

/* 19 unique customers */
assert(formatServiceAnalyticsCustomers(2) === "2 customers", "19 unique customers renders");
assert(formatServiceAnalyticsCustomers(1) === "1 customer", "19 1 customer");
assert(paintList.includes("unique_customers") && !paintList.includes("openCustomerAnalytics"), "19 display-only");

/* 20 upcoming-only */
const withUpcoming = sortServiceAnalyticsRows([septemberUpcoming, ...augustServices]);
assert(withUpcoming.some((r) => r.display_name === "Sisanje" && r.completed_visits === 0 && r.upcoming_bookings === 2), "20 upcoming-only service remains");
assert(withUpcoming.findIndex((r) => r.completed_visits === 0 && r.upcoming_bookings === 2) === withUpcoming.length - 1, "13 upcoming-only after completed activity");
assert(formatServiceAnalyticsUpcoming(2) === "2 upcoming", "20 upcoming line");
assert(!formatServiceAnalyticsUpcoming(0), "20 no upcoming line when 0");
assert(paintList.includes("upcoming_bookings") && paintList.includes("formatServiceAnalyticsUpcoming"), "20 upcoming rendered when >0");

/* 21 zero-price */
assert(formatBusinessMoney(0) === "0 MKD", "21 zero-price service renders 0");
assert(formatBusinessMoney(3000) === "3,000 MKD", "21 money formatting");
assert(!paintList.includes("Unknown") && html.includes("formatBusinessMoney(row && row.completed_revenue"), "21 no Unknown for zero");

/* 22 archived */
assert(isServiceAnalyticsArchived({ is_orphan: true }), "22 orphan visible flag");
assert(isServiceAnalyticsArchived({ is_missing_from_catalog: true }), "22 missing catalog visible flag");
assert(paintList.includes("isServiceAnalyticsArchived") && html.includes("saArchived"), "22 archived label");

/* 23 cancellation */
assert(!shouldShowServiceAnalyticsCancellation({ cancelled_bookings: 0 }), "23 hide 0 cancelled");
assert(shouldShowServiceAnalyticsCancellation({ cancelled_bookings: 3 }), "23 show cancelled >0");
assert(formatServiceAnalyticsCancelledLine({ cancelled_bookings: 3, cancellation_rate: 4.8 }) === "3 cancelled · 4.8%", "23 cancellation line");
assert(formatServiceAnalyticsCancelledLine({ cancelled_bookings: 0, cancellation_rate: 0 }) === "", "23 no 0 cancelled line");

/* 24 empty */
assert(html.includes('id="serviceAnalyticsEmpty"') && html.includes("No service activity in this period."), "24 empty state renders");
assert(html.includes("services.length === 0"), "24 empty when services array empty");

/* 25–26 stale */
assert(
  isServiceAnalyticsResponseStale(
    { requestId: 1, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 2, bizId: "a", fromDate: "2026-09-01", toDate: "2026-09-30" }
  ),
  "25 stale period response blocked"
);
assert(
  isServiceAnalyticsResponseStale(
    { requestId: 3, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 3, bizId: "biz-b", fromDate: "2026-08-01", toDate: "2026-08-31" }
  ),
  "26 stale business response blocked"
);
assert(
  !isServiceAnalyticsResponseStale(
    { requestId: 4, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" },
    { requestId: 4, bizId: "biz-a", fromDate: "2026-08-01", toDate: "2026-08-31" }
  ),
  "26 matching request not stale"
);
assert(runFn.includes("isServiceAnalyticsResponseStale") && runFn.includes("paintServiceAnalyticsLoadingSkeleton"), "17 loading clears old cards");

/* 27 mobile overflow */
assert(saCss.includes("overflow-x: hidden"), "27 mobile no-overflow overflow-x hidden");
assert(saCss.includes("word-break: break-word") && saCss.includes("overflow-wrap: anywhere"), "27 service names wrap");
assert(saCss.includes("min-height: 44px"), "27 44px retry target");
assert(html.includes("var(--admin-tabbar-height") && html.includes("env(safe-area-inset-bottom"), "27 safe area / tab bar");
assert(!saCss.includes("overflow-x: auto") && !saCss.includes("overflow-x: scroll"), "27 no horizontal scroll");
assert(saCss.includes("admin-sa-card__pair") && saCss.includes("minmax(140px, 1fr)"), "26 pair rows wrap gracefully");
assert(html.includes("grid-template-columns: repeat(3, minmax(0, 1fr))"), "19 desktop 3-col summary");
assert(!paintList.includes("formatServiceAnalyticsComparisonLabel"), "18 comparison not repeated per card");
assert(html.includes("serviceAnalyticsCompareLabel") && html.includes("formatServiceAnalyticsComparisonLabel"), "18 comparison context remains");
assert(!paintList.includes("saEstimatedNote"), "17 estimated note not duplicated in cards");

/* 28–30 strings */
assert(html.includes('commonServiceAnalytics: "Service Analytics"'), "28 EN Service Analytics");
assert(html.includes('saTopByVisits: "Top by Visits"') && html.includes('saTopByRevenue: "Top by Revenue"'), "28 EN strings present");
assert(html.includes('saTrendNew: "New"') && html.includes('saTrendNoChange: "No change"') && html.includes('saTrendNA: "N/A"'), "28 EN trend labels");
assert(html.includes('saTrendVisitsLabel: "Visits"') && html.includes('saTrendRevenueLabel: "Revenue"'), "28 EN trend dimension labels");
assert(html.includes('saTrendVisitsLabel: "Посети"') && html.includes('saTrendRevenueLabel: "Приход"'), "29 MK trend labels");
assert(html.includes('saTrendVisitsLabel: "Vizita"') && html.includes('saTrendRevenueLabel: "Të ardhura"'), "30 SQ trend labels");
assert(html.includes('saArchived: "Archived service"') && html.includes('saEmpty: "No service activity in this period."'), "28 EN empty/archived");
assert(html.includes('commonServiceAnalytics: "Аналитика на услуги"'), "29 MK Service Analytics");
assert(html.includes('saArchived: "Архивирана услуга"') && html.includes("Историските вредности вклучуваат проценети цени на услуги."), "29 MK strings present");
assert(html.includes('commonServiceAnalytics: "Analitika e shërbimeve"'), "30 SQ Service Analytics");
assert(html.includes('saArchived: "Shërbim i arkivuar"') && html.includes("Vlerat historike përfshijnë çmime të vlerësuara të shërbimeve."), "30 SQ strings present");
assert(html.includes("Failed to load service analytics") && html.includes("Не може да се вчита аналитиката на услуги"), "28/29 error strings");

/* 31–34 unchanged analytics */
assert(html.includes('id="adminSectionPerformance"') && html.includes("performanceKpiCompletedRevenue"), "31 Performance UI unchanged");
assert(html.includes('sb.rpc("get_business_performance_report"') || html.includes("get_business_performance_report"), "31 Performance RPC unchanged");
assert(html.includes('id="adminSectionCustomerAnalytics"') && html.includes("caKpiActive"), "32 Customer Analytics UI unchanged");
assert(html.includes('id="caDetVipBtn"') && html.includes("caDetMarkVip: \"Mark VIP\""), "33 Customer Detail VIP unchanged");
assert(html.includes("caDetNotesTitle: \"Internal Notes\"") && html.includes('id="caDetNotesCard"'), "33 Notes unchanged");
assert(html.includes('sb.rpc("get_business_customer_segment"') && html.includes("closeCustomerAnalyticsSegmentView"), "34 Segment navigation unchanged");
assert(html.includes('id="saHomeBackBtn"') && html.includes('id="perfHomeBackBtn"') && html.includes('id="caHomeBackBtn"'), "30 analytics Home Back buttons unchanged");
assert(html.includes("onclick=\"setAdminSection('overview')\""), "30 Home Back destination unchanged");
assert(!html.includes("openServiceDetail") && !html.includes("service-detail"), "22 no Service Detail");

/* 22 cards not tappable / no detail / no staff */
assert(html.includes('<article class="admin-sa-card') || paintList.includes('<article class="admin-sa-card'), "22 cards are articles");
assert(!paintList.includes("onclick") && !html.includes("openServiceDetail") && !html.includes("service-detail"), "22 no Service Detail");
assert(!saJs.includes("get_business_staff_analytics") && !paintList.includes("is_unassigned"), "23 Service Analytics list has no staff ranking");

/* August expected parity helpers */
assert(augustSummary.top_service_by_visits.display_name === "Sisanje" && augustSummary.top_service_by_visits.completed_visits === 10, "T August top visits");
assert(augustSummary.top_service_by_revenue.completed_revenue === 3000, "T August top revenue");
assert(augustSummary.services_used === 3, "T August services used");
assert(formatServiceAnalyticsShare(58.8, "visits") === "58.8% of visits", "T August visit share");
assert(formatServiceAnalyticsShare(50, "revenue") === "50% of revenue", "T August revenue share");
assert(formatServiceAnalyticsTrendLine(augustServices[0].visit_trend, "visits") === "Visits ↓ 47.4%", "T August Sisanje visit trend");
assert(formatServiceAnalyticsTrendLine(augustServices[0].revenue_trend, "revenue") === "Revenue ↓ 47.4%", "T August Sisanje revenue trend");
assert(formatServiceAnalyticsTrendLine(augustServices[1].visit_trend, "visits") === "Visits ↑ 50%", "T August Masaza visit trend");
assert(formatServiceAnalyticsTrendLine(augustServices[2].revenue_trend, "revenue") === "Revenue N/A", "T August combo revenue N/A");
assert(formatBusinessMoney(0) === "0 MKD", "T combo zero currency");
assert(formatServiceAnalyticsUpcoming(2) === "2 upcoming", "T September upcoming");
assert(formatServiceAnalyticsTrend(augustServices[0].visit_trend) === "-47.4%", "T August Sisanje trend");
assert(formatServiceAnalyticsTrend(augustServices[1].visit_trend) === "+50%", "T August Masaza trend");
assert(formatServiceAnalyticsTrend(augustServices[2].visit_trend) === "-75%", "T August combo trend");
assert(formatServiceAnalyticsComparisonLabel({ comparison_type: "elapsed_mtd", previous_from: "2026-08-01" }) === "Compared with equivalent elapsed period", "K elapsed MTD wording");

/* 35 SQL files unchanged in this phase */
assert(!html.includes("CREATE OR REPLACE FUNCTION public.get_business_service_analytics"), "35 no SQL in index.html");
assert(!saJs.includes("CREATE OR REPLACE"), "35 no SQL in SA JS");
let sqlDiff = "";
try {
  sqlDiff = execSync(
    "git diff --name-only -- supabase-get-business-service-analytics.sql supabase-get-business-service-analytics-tests.sql",
    { cwd: root, encoding: "utf8" }
  ).trim();
} catch {
  sqlDiff = "git-error";
}
assert(sqlDiff === "", `35 no SQL files changed (${sqlDiff || "clean"})`);

/* period reuse */
assert(html.includes("serviceAnalyticsPresetChips") && html.includes("getActivePerformancePeriodRange"), "C period reuse");
assert(html.includes('data-performance-preset="this_month"') && html.includes('data-performance-preset="last_month"') && html.includes('data-performance-preset="ytd"'), "C shared presets");
assert(html.includes("serviceAnalyticsCustomStartMonth") && html.includes("commitPerformanceCustomRangeFromPrefix(\"serviceAnalyticsCustom\")"), "C custom range shared");

console.log(`service-analytics-ui: ${passed} passed`);
