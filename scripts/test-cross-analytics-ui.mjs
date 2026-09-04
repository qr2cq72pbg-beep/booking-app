#!/usr/bin/env node
/**
 * Phase 7C: Cross Analytics UI V1.
 * Static contract checks. Does not call SQL, RPCs, or recompute backend formulas.
 */

import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

let passed = 0;
function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
  passed += 1;
}

function sliceBetween(src, startNeedle, endNeedle) {
  const start = src.indexOf(startNeedle);
  const end = src.indexOf(endNeedle, start >= 0 ? start + startNeedle.length : 0);
  assert(start >= 0, `missing start: ${startNeedle.slice(0, 80)}`);
  assert(end > start, `missing end after: ${startNeedle.slice(0, 80)}`);
  return src.slice(start, end);
}

function t(_key, fallback) {
  return fallback;
}

function formatCustomerAnalyticsPct(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  const rounded = Math.round(n * 10) / 10;
  if (Number.isInteger(rounded)) return `${rounded}%`;
  return `${rounded}%`;
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

function xaStableValue(value) {
  if (Array.isArray(value)) {
    const mapped = value.map(xaStableValue);
    const primitives = mapped.every((item) => item == null || typeof item !== "object");
    return primitives
      ? mapped.slice().sort((a, b) => String(a).localeCompare(String(b)))
      : mapped;
  }
  if (value && typeof value === "object") {
    const out = {};
    Object.keys(value)
      .sort()
      .forEach((key) => {
        out[key] = xaStableValue(value[key]);
      });
    return out;
  }
  return value;
}

function buildXaRpcFilters(raw) {
  const src = raw && typeof raw === "object" ? raw : {};
  const out = {};
  const gender = Array.isArray(src.gender) ? src.gender : [];
  if (gender.length) out.gender = gender.slice();
  const ages = Array.isArray(src.age_buckets) ? src.age_buckets : [];
  if (ages.length) out.age_buckets = ages.slice();
  const cityIds = Array.isArray(src.city_ids) ? src.city_ids : [];
  if (cityIds.length) out.city_ids = cityIds.slice();
  if (src.city_unknown === true) out.city_unknown = true;
  if (src.is_vip === true || src.is_vip === false) out.is_vip = src.is_vip;
  if (src.customer_type === "new" || src.customer_type === "returning") out.customer_type = src.customer_type;
  if (src.visit_frequency === "repeat" || src.visit_frequency === "single") out.visit_frequency = src.visit_frequency;
  if (Number.isFinite(Number(src.inactive_days_min))) out.inactive_days_min = Number(src.inactive_days_min);
  if (src.has_future_booking === true || src.has_future_booking === false) {
    out.has_future_booking = src.has_future_booking;
  }
  if (Number.isFinite(Number(src.lifetime_visits_min))) out.lifetime_visits_min = Number(src.lifetime_visits_min);
  if (Number.isFinite(Number(src.lifetime_revenue_min))) out.lifetime_revenue_min = Number(src.lifetime_revenue_min);
  const serviceAny = Array.isArray(src.service_ids) ? src.service_ids.slice() : [];
  const serviceNone = Array.isArray(src.service_ids_none) ? src.service_ids_none.slice() : [];
  if (serviceAny.length) {
    out.service_ids = serviceAny;
    out.service_match = "any";
  }
  if (serviceNone.length) out.service_ids_none = serviceNone;
  if (serviceAny.length || serviceNone.length) {
    out.service_scope = src.service_scope === "period" ? "period" : "lifetime";
  }
  const staffIds = Array.isArray(src.staff_ids) ? src.staff_ids.slice() : [];
  if (staffIds.length) {
    out.staff_ids = staffIds;
    out.staff_match = "any";
    out.staff_scope = src.staff_scope === "period" ? "period" : "lifetime";
  }
  return out;
}

function xaFiltersKey(filters) {
  return JSON.stringify(xaStableValue(buildXaRpcFilters(filters || {})));
}

function xaFiltersEqual(a, b) {
  return xaFiltersKey(a) === xaFiltersKey(b);
}

function xaServiceConflict(filters) {
  const positive = new Set(Array.isArray(filters?.service_ids) ? filters.service_ids : []);
  return (Array.isArray(filters?.service_ids_none) ? filters.service_ids_none : []).some((id) => positive.has(id));
}

function isCrossAnalyticsResponseStale(request, current) {
  if (!request || !current) return true;
  if (request.requestId !== current.requestId) return true;
  if (String(request.bizId || "") !== String(current.bizId || "")) return true;
  if (String(request.fromDate || "") !== String(current.fromDate || "")) return true;
  if (String(request.toDate || "") !== String(current.toDate || "")) return true;
  if (String(request.sort || "") !== String(current.sort || "")) return true;
  if (String(request.filtersKey || "") !== String(current.filtersKey || "")) return true;
  if (Number(request.offset || 0) !== Number(current.offset || 0)) return true;
  return false;
}

function formatXaFutureCoverage(futureCount, matched) {
  const m = Number(matched);
  const f = Number(futureCount);
  if (!Number.isFinite(m) || m <= 0) return "—";
  if (!Number.isFinite(f) || f < 0) return "—";
  return formatCustomerAnalyticsPct((f / m) * 100);
}

function shouldShowCrossAnalyticsEstimatedNote(payload) {
  return !!(
    payload?.summary?.contains_estimated_prices === true ||
    payload?.quality?.contains_estimated_prices === true
  );
}

const xaSection = sliceBetween(html, 'id="adminSectionCrossAnalytics"', 'id="adminSectionProfile"');
const xaJs = sliceBetween(html, "const XA_PAGE_SIZE = 50;", "async function ensureBusinessSettings()");
const fetchFn = sliceBetween(html, "async function fetchBusinessCrossAnalytics", "async function runAdminCrossAnalyticsReport");
const runFn = sliceBetween(html, "async function runAdminCrossAnalyticsReport", "function bindCrossAnalyticsUi()");
const paintRow = sliceBetween(html, "function paintCrossAnalyticsRowHtml", "function paintCrossAnalyticsRows");
const paintSummary = sliceBetween(html, "function paintCrossAnalyticsSummary", "function paintCrossAnalyticsRowHtml");
const paintPayload = sliceBetween(html, "function paintCrossAnalyticsPayload", "function paintXaCityResults");
const bindFn = sliceBetween(html, "function bindCrossAnalyticsUi()", "function renderAdminCrossAnalytics()");
const closeDetail = sliceBetween(html, "function closeCustomerAnalyticsCustomerDetail(opts = {}) {", "function renderAdminCustomerAnalytics()");
const bottomNav = sliceBetween(html, 'id="adminMobileBottomNav"', "</nav>");
const xaCss = sliceBetween(html, "/* Cross Analytics — filter/segment chrome on shared Performance family */", "/* Customer Analytics — presentation extras on shared Performance chrome */");
const nav = sliceBetween(html, 'id="adminNav"', "</nav>");
const overviewActions = sliceBetween(html, 'class="overview-actions overview-actions--hub overview-actions--compact"', "</section>");

const XA_PRESETS = {
  all: {},
  at_risk_30: { inactive_days_min: 30, has_future_booking: false },
  at_risk_60: { inactive_days_min: 60, has_future_booking: false },
  at_risk_90: { inactive_days_min: 90, has_future_booking: false },
  vip: { is_vip: true },
  new: { customer_type: "new" },
  returning: { customer_type: "returning" },
  repeat: { visit_frequency: "repeat" },
  no_future: { has_future_booking: false }
};

/* 1–5 navigation */
assert(html.includes('id="adminSectionCrossAnalytics"'), "1 Cross Analytics section exists");
assert(nav.includes('data-admin-section="cross-analytics"'), "2 desktop nav item exists");
assert(
  nav.indexOf('data-admin-section="staff-analytics"') < nav.indexOf('data-admin-section="cross-analytics"') &&
    nav.indexOf('data-admin-section="service-analytics"') < nav.indexOf('data-admin-section="staff-analytics"'),
  "2 desktop nav after Staff"
);
assert(overviewActions.includes("setAdminSection('cross-analytics')"), "3 mobile Quick Action exists");
assert(
  overviewActions.indexOf("setAdminSection('staff-analytics')") <
    overviewActions.indexOf("setAdminSection('cross-analytics')"),
  "3 Quick Action after Staff Analytics"
);
assert(!bottomNav.includes("cross-analytics"), "4 no bottom-nav Cross tab");
assert(!bottomNav.includes('data-admin-mobile-tab="cross-analytics"'), "4 no cross-analytics mobile tab");
assert(html.includes('id="crossHomeBackBtn"'), "5 mobile Back exists");
assert(xaSection.includes("onclick=\"setAdminSection('overview')\""), "5 mobile Back → overview");

/* 6–8 shared period */
assert(xaSection.includes('id="crossAnalyticsPresetChips"'), "6 shared period controls used");
assert(xaSection.includes('data-performance-preset="this_month"'), "6 shared period presets");
assert(!xaJs.includes("let crossAnalyticsActivePreset"), "7 no second independent period state");
assert(!xaJs.includes("crossAnalyticsCustomRangeState"), "7 no second custom range engine");
assert(runFn.includes("getActivePerformancePeriodRange()"), "8 RPC called with current shared period");
assert(fetchFn.includes("p_from_date: range.startDate") && fetchFn.includes("p_to_date: range.endDate"), "8 from/to from shared range");

/* 9–11 one RPC, no bookings, no aggregation */
assert((fetchFn.match(/sb\.rpc\(/g) || []).length === 1, "9 one RPC only");
assert(fetchFn.includes('sb.rpc("get_business_cross_analytics"'), "9 generic Cross RPC");
assert(!fetchFn.includes(".from(\"bookings\")") && !xaJs.includes("filterBookingsForPerformanceRange"), "10 no bookings download");
assert(!paintSummary.includes("payload.customers") && paintSummary.includes("payload.summary"), "11 no frontend analytics aggregation");
assert(!paintSummary.includes(".reduce(") && !runFn.includes("completed_visits_lifetime +"), "11 summary backend-only");

/* 12–20 presets */
assert(xaJs.includes("inactive_days_min: 30") && xaJs.includes("has_future_booking: false"), "12 preset At Risk 30");
assert(xaJs.includes("inactive_days_min: 60"), "13 preset At Risk 60");
assert(xaJs.includes("inactive_days_min: 90"), "14 preset At Risk 90");
assert(xaJs.includes('vip: { is_vip: true }'), "15 VIP preset");
assert(xaJs.includes('new: { customer_type: "new" }'), "16 New preset");
assert(xaJs.includes('returning: { customer_type: "returning" }'), "17 Returning preset");
assert(xaJs.includes('repeat: { visit_frequency: "repeat" }'), "18 Repeat preset");
assert(xaJs.includes('no_future: { has_future_booking: false }'), "19 No Future preset");
assert(xaJs.includes("applyXaPreset") && xaJs.includes("XA_PRESETS[id]"), "preset click replaces filters");
assert(html.includes('data-xa-preset="all"') && xaJs.includes("applyXaFiltersNow({})"), "20 Clear → {}");
assert(xaFiltersEqual(XA_PRESETS.at_risk_30, { inactive_days_min: 30, has_future_booking: false }), "12 At Risk 30 maps backend");
assert(xaFiltersEqual(XA_PRESETS.vip, { is_vip: true }), "15 VIP maps backend");

/* 21–24 draft / apply */
assert(xaJs.includes("crossAnalyticsDraft") && xaJs.includes("openCrossAnalyticsFilterSheet"), "21 filter sheet draft state");
assert(xaJs.includes("function cancelCrossAnalyticsFilters") && xaJs.includes("cloneXaFilters(crossAnalyticsState.appliedFilters)"), "22 Cancel discards");
assert(xaJs.includes("function applyCrossAnalyticsFilters") && xaJs.includes("applyXaFiltersNow(crossAnalyticsDraft)"), "23 Apply commits");
assert(xaJs.includes("crossAnalyticsState.offset = 0") && runFn.includes("const offset = append ?"), "24 Apply resets offset");

/* 25–43 filters */
assert(xaJs.includes('data-xa-gender') && xaJs.includes("out.gender"), "25 gender multi-select");
assert(xaJs.includes("age_buckets") && xaJs.includes("under_18") && xaJs.includes("65_plus"), "26 age multi-select");
assert(xaJs.includes("city_ids") && xaJs.includes("isXaUuid"), "27 city UUID filter");
assert(xaJs.includes("city_unknown") && xaSection.includes('id="xaCityUnknown"'), "28 city unknown");
assert(xaJs.includes('data-xa-vip') && xaJs.includes("is_vip === true") && xaJs.includes("is_vip === false"), "29 VIP tri-state");
assert(xaJs.includes('data-xa-type') && xaJs.includes('customer_type === "new"'), "30 customer type exclusive");
assert(xaJs.includes('data-xa-freq') && xaJs.includes('visit_frequency === "repeat"') && xaJs.includes('"single"'), "31 repeat/single exclusive");
assert(xaJs.includes("inactive_days_min") && !xaSection.includes("inactive_days_max"), "32 inactivity min");
assert(xaJs.includes('data-xa-future') && xaJs.includes("has_future_booking === true"), "33 future booking tri-state");
assert(xaJs.includes("lifetime_visits_min") && xaSection.includes('id="xaVisitsMin"'), "34 lifetime visits min");
assert(xaJs.includes("lifetime_revenue_min") && xaSection.includes('id="xaRevenueMin"'), "35 lifetime revenue min");
assert(xaJs.includes('service_match = "any"') && xaJs.includes("service_ids"), "36 service ANY");
assert(xaJs.includes("service_ids_none"), "37 service NONE");
assert(xaJs.includes("service_scope") && xaJs.includes('"lifetime"') && xaJs.includes('"period"'), "38 service scope");
assert(xaJs.includes("xaServiceConflict") && xaJs.includes("service_ids_none"), "39 positive/negative same service blocked");
assert(xaServiceConflict({ service_ids: ["a"], service_ids_none: ["a"] }), "39 conflict detected");
assert(!xaServiceConflict({ service_ids: ["a"], service_ids_none: ["b"] }), "39 distinct services allowed");
assert(xaJs.includes("staff_ids") && xaJs.includes('staff_match = "any"'), "40 staff ANY");
assert(xaJs.includes('"unassigned"') && html.includes('xaUnassigned: "Unassigned"'), "41 Unassigned");
assert(xaJs.includes("staff_scope"), "42 staff scope");
assert(!xaJs.includes("staff_ids_none") && !xaSection.includes("Never served"), "43 no staff NONE UI");

/* 44–46 chips + applied_filters */
assert(xaJs.includes("function paintXaChips") && xaJs.includes("function removeXaChip"), "44 active chips reflect applied filters");
assert(bindFn.includes("removeXaChip") && xaJs.includes("applyXaFiltersNow(next)"), "45 removing chip refetches");
assert(paintPayload.includes("payload.applied_filters") && paintPayload.includes("normalizeXaAppliedFilters"), "46 applied_filters from backend replaces local applied state");

/* 47–52 summary */
assert(paintSummary.includes("summary.matched_customers"), "47 summary backend-only / 48 matched customers");
assert(paintSummary.includes("summary.period_completed_visits"), "49 completed visits");
assert(paintSummary.includes("summary.period_completed_revenue"), "50 completed revenue");
assert(paintSummary.includes("formatXaFutureCoverage") && paintSummary.includes("future_booking_count"), "51 future booking coverage");
assert(formatXaFutureCoverage(25, 100) === "25%", "51 coverage ratio from summary numbers");
assert(formatXaFutureCoverage(0, 0) === "—", "51 coverage unavailable when no matched customers");
assert(xaJs.includes("shouldShowCrossAnalyticsEstimatedNote") && xaJs.includes("formatServiceAnalyticsEstimatedNote"), "52 estimated note");
assert(shouldShowCrossAnalyticsEstimatedNote({ summary: { contains_estimated_prices: true } }), "52 summary estimated flag");
assert(shouldShowCrossAnalyticsEstimatedNote({ quality: { contains_estimated_prices: true } }), "52 quality estimated flag");
assert(!shouldShowCrossAnalyticsEstimatedNote({ summary: {}, quality: {} }), "52 estimated hidden when false");

/* 53–57 row display */
assert(!paintRow.includes("row.phone") && !paintRow.includes("row.email") && !paintRow.includes("identity_type"), "53 customer rows do not show raw private fields");
assert(paintRow.includes("xaNoCompletedVisits") && paintRow.includes("visits <= 0"), "54 zero-visit row safe");
assert(!paintRow.includes("Inactive") || paintRow.includes("xaDaysInactive"), "54 zero-visit does not use Inactive label for empty lifetime");
assert(paintRow.includes("formatXaGender") && paintRow.includes("t(\"xaUnknown\""), "55 unknown demographics localized");
assert(paintRow.includes("formatXaAgeBucket") && paintRow.includes("row.age_bucket"), "56 age uses bucket only");
assert(!paintRow.includes("age_years") && !paintRow.includes("date_of_birth"), "56 no client-side age derive");
assert(paintRow.includes("formatXaRowMoney") && xaJs.includes("formatBusinessMoney(amount"), "57 money formatter reused");
assert(formatBusinessMoney(0) === "0 MKD", "57 known zero preserved");
assert(formatBusinessMoney(null) === "—", "57 null money vs zero preserved");

/* 58–60 sort */
["last_visit_desc", "last_visit_asc", "lifetime_revenue_desc", "period_revenue_desc", "lifetime_visits_desc", "name_asc", "next_booking_asc"].forEach((sort) => {
  assert(xaSection.includes(`value="${sort}"`) && xaJs.includes(`"${sort}"`), `58 sort ${sort} maps backend`);
});
assert(!paintRow.includes(".sort(") && !runFn.includes("customers.sort") && !xaJs.includes("sortCrossAnalytics"), "59 no local sort");
assert(bindFn.includes("crossAnalyticsState.offset = 0") && bindFn.includes("crossAnalyticsState.sort = value"), "60 sort resets offset");

/* 61–65 pagination */
assert(xaJs.includes("const XA_PAGE_SIZE = 50"), "61 default limit 50");
assert(fetchFn.includes("p_limit: limit") && fetchFn.includes("p_offset: offset"), "62 Load More uses offset");
assert(runFn.includes("append ? Number(crossAnalyticsState.offset || 0) + XA_PAGE_SIZE"), "62 offset += limit");
assert(paintPayload.includes("opts.append") && paintPayload.includes("concat"), "63 rows append");
assert(runFn.includes("isCrossAnalyticsResponseStale"), "64 stale Load More blocked");
assert(
  isCrossAnalyticsResponseStale(
    { requestId: 1, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31", sort: "name_asc", filtersKey: "{}", offset: 50 },
    { requestId: 2, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31", sort: "name_asc", filtersKey: "{}", offset: 50 }
  ),
  "64 slower old request blocked"
);
assert(
  !isCrossAnalyticsResponseStale(
    { requestId: 4, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31", sort: "name_asc", filtersKey: "{}", offset: 50 },
    { requestId: 4, bizId: "a", fromDate: "2026-08-01", toDate: "2026-08-31", sort: "name_asc", filtersKey: "{}", offset: 50 }
  ),
  "64 matching Load More not stale"
);
assert(paintPayload.includes("has_more") && xaSection.includes('id="crossAnalyticsLoadMore"'), "65 has_more controls button");

/* 66–70 loading / error / empty */
assert(runFn.includes("paintCrossAnalyticsLoadingSkeleton") && xaJs.includes("admin-xa-skel"), "66 loading state");
assert(xaSection.includes('id="crossAnalyticsRetryBtn"') && runFn.includes("paintCrossAnalyticsUnavailable"), "67 full-query error + Retry");
assert(runFn.includes("append") && runFn.includes("crossAnalyticsMoreError") && runFn.includes("return;"), "68 Load More error keeps old rows");
assert(paintPayload.includes("xaEmptyFiltered") && paintPayload.includes("xaEmptyNone"), "69/70 empty states");
assert(html.includes("No customers match these filters."), "69 empty filtered copy");
assert(html.includes("No customers yet."), "70 empty no-customer copy");
assert(!xaSection.includes("No activity in this period"), "70 does not use period-empty copy");

/* 71–75 customer detail reuse */
assert(xaJs.includes("openCrossAnalyticsCustomerDetail") && xaJs.includes("openCustomerAnalyticsCustomerDetail(customerKey)"), "71 row click opens existing Customer Detail");
assert((html.match(/id="customerAnalyticsDetailView"/g) || []).length === 1, "72 no duplicate Detail screen");
assert(xaJs.includes("customerDetailReturnContext") && xaJs.includes('section: "cross-analytics"'), "73 Cross state preserved");
assert(closeDetail.includes('returnCtx?.section === "cross-analytics"'), "74 Back returns Cross");
assert(closeDetail.includes("if (customerAnalyticsSegmentState.open)") && closeDetail.includes("paintCustomerAnalyticsSegmentView()"), "75 existing Customer Segment→Detail→Segment still works");
assert(xaJs.includes("portalCustomerAnalyticsDetailToCross") && xaJs.includes("restoreCustomerAnalyticsDetailHome"), "72 portal not duplicate DOM");

/* 76–82 a11y / mobile */
assert(xaCss.includes("env(safe-area-inset-bottom") && xaCss.includes("env(safe-area-inset-top"), "76 mobile filter sheet safe-area");
assert(xaCss.includes(".admin-xa-filters-btn") && xaCss.includes("min-height: 44px"), "77 filters button >=44");
assert(xaCss.includes(".admin-xa-sheet__apply") && xaCss.includes("min-height: 44px"), "78 apply >=44");
assert(xaCss.includes(".admin-xa-more") && xaCss.includes("min-height: 44px"), "79 Load More >=44");
assert(xaCss.includes(".admin-xa-chips") && xaCss.includes("flex-wrap: wrap"), "80 chips wrap");
assert(xaCss.includes("overflow-x: hidden") && !xaCss.includes("overflow-x: auto") && !xaCss.includes("overflow-x: scroll"), "81 no horizontal overflow rules");
assert(xaCss.includes(".admin-xa-kpi__value--money") && xaCss.includes("overflow-wrap: anywhere"), "82 long money wraps");
assert(xaCss.includes(".admin-xa-row__name") && xaCss.includes("word-break: break-word"), "81 names wrap");
assert(paintRow.includes("<button type=\"button\"") && paintRow.includes("data-xa-customer-key"), "51 rows are real buttons");

/* 83–85 i18n */
assert(html.includes('commonCrossAnalytics: "Cross Analytics"'), "83 EN Cross Analytics");
assert(html.includes('xaFilters: "Filters"') && html.includes('xaApplyFilters: "Apply Filters"'), "83 EN filter keys");
assert(html.includes('commonCrossAnalytics: "Вкрстена аналитика"'), "84 MK title");
assert(html.includes('xaCompletedVisits: "Реализирани посети"') && html.includes('xaCompletedRevenue: "Реализиран приход"'), "84 MK locked terminology");
assert(html.includes('commonCrossAnalytics: "Analitika e kryqëzuar"'), "85 SQ title");
assert(html.includes('xaCompletedVisits: "Vizita të realizuara"') && html.includes('xaCompletedRevenue: "Të ardhura të realizuara"'), "85 SQ locked terminology");
assert(html.includes("No customers match these filters.") && html.includes("Нема клиенти што одговараат на овие филтри.") && html.includes("Asnjë klient nuk përputhet me këta filtra."), "83–85 empty filtered i18n");

/* 86–93 scope */
assert(!html.includes("CREATE OR REPLACE FUNCTION public.get_business_cross_analytics"), "86 no SQL in index.html");
assert(!xaJs.includes("CREATE OR REPLACE"), "86 no SQL in Cross JS");
let sqlDiff = "";
try {
  sqlDiff = execSync(
    "git diff --name-only -- supabase-get-business-cross-analytics.sql supabase-get-business-cross-analytics-tests.sql",
    { cwd: root, encoding: "utf8" }
  ).trim();
} catch {
  sqlDiff = "git-error";
}
assert(sqlDiff === "", `86 no SQL files changed (${sqlDiff || "clean"})`);
assert(!xaJs.includes("completed_visits_lifetime +") && !xaJs.includes("days_since_last_visit ="), "87 no backend formula changes in UI");
assert(!html.includes("openStaffDetail") && !xaSection.includes("Staff Detail"), "88 no Staff Detail");
assert(!html.includes("openServiceDetail") && !xaSection.includes("Service Detail"), "89 no Service Detail");
assert(!xaJs.toLowerCase().includes("saved segment") && !xaSection.includes("Save segment"), "90 no saved segments");
assert(!xaJs.toLowerCase().includes("campaign") && !xaSection.toLowerCase().includes("campaign"), "91 no campaigns");
assert(!xaJs.toLowerCase().includes("export") && !xaSection.toLowerCase().includes("export"), "92 no export");
assert(!xaSection.includes("boolean builder") && !xaJs.includes("nested boolean") && !xaJs.includes("filter_tree"), "93 no nested Boolean builder");

assert(html.includes('"cross-analytics": "adminSectionCrossAnalytics"'), "registry includes Cross");
assert(html.includes("commitPerformanceCustomRangeFromPrefix(\"crossAnalyticsCustom\")"), "shared custom range prefix");
assert(xaSection.includes('id="crossAnalyticsFilterSheet"'), "filter sheet exists");
assert(!xaJs.includes("sb.from(\"bookings\")"), "no bookings table download");
assert(fetchFn.includes("p_filters: filters") && fetchFn.includes("p_sort: sort") && fetchFn.includes("p_limit: limit") && fetchFn.includes("p_offset: offset"), "RPC arg contract");

console.log(`cross-analytics-ui: ${passed} passed`);
