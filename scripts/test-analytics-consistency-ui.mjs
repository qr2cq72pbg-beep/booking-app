#!/usr/bin/env node
/**
 * Phase 6B: Analytics UX consistency (frontend only).
 * Static contract checks. Does not call SQL, RPCs, or recompute formulas.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
}

function count(hay, needle) {
  let n = 0;
  let i = 0;
  while ((i = hay.indexOf(needle, i)) !== -1) {
    n += 1;
    i += needle.length;
  }
  return n;
}

function sliceBetween(src, startNeedle, endNeedle) {
  const start = src.indexOf(startNeedle);
  const end = src.indexOf(endNeedle, start >= 0 ? start + startNeedle.length : 0);
  assert(start >= 0, `missing start: ${startNeedle.slice(0, 90)}`);
  assert(end > start, `missing end after: ${startNeedle.slice(0, 90)}`);
  return src.slice(start, end);
}

function cssRule(selector) {
  const needle = `${selector} {`;
  const start = html.indexOf(needle);
  assert(start >= 0, `missing CSS rule ${selector}`);
  const end = html.indexOf("}", start);
  assert(end > start, `unclosed CSS rule ${selector}`);
  return html.slice(start, end + 1);
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

function formatPerformanceCount(value) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  return String(Math.trunc(Number(value)));
}

const perfSection = sliceBetween(html, 'id="adminSectionPerformance"', 'id="adminSectionCustomerAnalytics"');
const caSection = sliceBetween(html, 'id="adminSectionCustomerAnalytics"', 'id="adminSectionServiceAnalytics"');
const saSection = sliceBetween(html, 'id="adminSectionServiceAnalytics"', 'id="adminSectionStaffAnalytics"');
const staSection = sliceBetween(html, 'id="adminSectionStaffAnalytics"', 'id="adminSectionCrossAnalytics"');
const perfRun = sliceBetween(html, "async function runAdminPerformanceReport()", "function bindAdminPerformanceControls()");
const caRun = sliceBetween(html, "async function runAdminCustomerAnalyticsReport", "let customerAnalyticsSegmentRequestId");
const bindPerf = sliceBetween(html, "function bindAdminPerformanceControls()", "function renderAdminPerformance()");
const bindSa = sliceBetween(html, "function bindServiceAnalyticsUi()", "function paintServiceAnalyticsDashValues()");
const bindSta = sliceBetween(html, "function bindStaffAnalyticsUi()", "function paintStaffAnalyticsDashValues()");
const paintPerfUnavailable = sliceBetween(html, "function renderAdminPerformanceUnavailable", "async function fetchBusinessPerformanceReport");
const paintCaUnavailable = sliceBetween(html, "function paintCustomerAnalyticsUnavailable", "function paintCustomerAnalyticsPayload");
const caValueCss = cssRule("#adminSectionCustomerAnalytics .admin-ca-value-row__value");
const kpiBtnCss = html.slice(
  html.indexOf("#adminSectionCustomerAnalytics .admin-ca-kpi--clickable {"),
  html.indexOf("body.admin-mobile-shell-active #adminView #adminSectionCustomerAnalytics button.admin-ca-kpi--clickable,")
);
const insightCss = cssRule("#adminSectionCustomerAnalytics .admin-ca-insight");
const noteCss = html.slice(
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-analytics-note {"),
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-analytics-note--warn {")
);
const retryCss = html.slice(
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-analytics-retry {"),
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-analytics-skel,")
);
const chipCss = html.slice(
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-performance-preset {"),
  html.indexOf(":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-performance-year-wrap {")
);
const mobileChipCss = html.slice(
  html.indexOf("/* Performance period chips — override global admin mobile button sizing */"),
  html.indexOf("body.admin-mobile-shell-active #adminView :is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) select.admin-performance-select")
);
const staTertiaryCss = cssRule("#adminSectionStaffAnalytics .admin-sta-card__tertiary");
const saMetricCss = cssRule("#adminSectionServiceAnalytics .admin-sa-kpi__metric");
const staMetricCss = cssRule("#adminSectionStaffAnalytics .admin-sta-kpi__metric");
const staffTrendFn = sliceBetween(html, "function formatStaffAnalyticsTrend(", "function formatStaffAnalyticsTrendLine(");
const serviceTrendFn = sliceBetween(html, "function formatServiceAnalyticsTrend(", "function formatServiceAnalyticsTrendLine(");
const fetchPerf = sliceBetween(html, "async function fetchBusinessPerformanceReport", "function renderPerformanceRankList");
const fetchCa = sliceBetween(html, "async function fetchBusinessCustomerAnalyticsOverview", "async function runAdminCustomerAnalyticsReport");
const fetchSa = html.slice(html.indexOf("async function fetchBusinessServiceAnalytics"), html.indexOf("async function runAdminServiceAnalyticsReport"));
const fetchSta = html.slice(html.indexOf("async function fetchBusinessStaffAnalytics"), html.indexOf("async function runAdminStaffAnalyticsReport"));

/* 1 four screens */
assert(html.includes('id="adminSectionPerformance"'), "1 Performance screen");
assert(html.includes('id="adminSectionCustomerAnalytics"'), "1 Customer Analytics screen");
assert(html.includes('id="adminSectionServiceAnalytics"'), "1 Service Analytics screen");
assert(html.includes('id="adminSectionStaffAnalytics"'), "1 Staff Analytics screen");
assert(html.includes('id="adminSectionCrossAnalytics"'), "1 Cross Analytics screen");

/* 2 same mobile Back contract */
assert(perfSection.includes('id="perfHomeBackBtn"') && perfSection.includes('class="admin-ca-seg-back"'), "2 Performance Back");
assert(caSection.includes('id="caHomeBackBtn"') && caSection.includes('class="admin-ca-seg-back"'), "2 Customer Back");
assert(saSection.includes('id="saHomeBackBtn"') && saSection.includes('class="admin-ca-seg-back"'), "2 Service Back");
assert(staSection.includes('id="staffHomeBackBtn"') && staSection.includes('class="admin-ca-seg-back"'), "2 Staff Back");
assert(html.includes("onclick=\"setAdminSection('overview')\""), "2 Back → overview");

/* 3 shared period classes */
["performancePresetChips", "customerAnalyticsPresetChips", "serviceAnalyticsPresetChips", "staffAnalyticsPresetChips", "crossAnalyticsPresetChips"].forEach((id) => {
  assert(html.includes(`id="${id}"`), `3 period wrap ${id}`);
});
assert(html.includes("admin-performance-presets--primary") && html.includes("admin-performance-preset--secondary"), "3 shared period classes");

/* 4 period chips >=44px mobile */
assert(chipCss.includes("min-height: 44px"), "4 period chips min-height 44px");
assert(mobileChipCss.includes("min-height: 44px"), "4 mobile period chips min-height 44px");

/* 5 aria-pressed preserved */
assert(html.includes("function syncPerformancePresetChipUi()"), "5 chip sync exists");
assert(html.includes('btn.setAttribute("aria-pressed", on ? "true" : "false")'), "5 aria-pressed preserved");

/* 6–8 Performance loading / stale / Retry */
assert(html.includes("function paintPerformanceLoadingSkeleton()"), "6 Performance loading state");
assert(html.includes("admin-analytics-skel"), "6 Performance skeleton");
assert(perfRun.includes("classList.add(\"is-loading\")"), "6 Performance is-loading");
assert(perfRun.includes("setPerformanceText(\"performancePeriodLabel\""), "6 period label updates first");
assert(perfRun.includes("paintPerformanceLoadingSkeleton()"), "7 stale values cleared before fetch");
assert(html.includes("function paintPerformanceDashValues()") && html.includes('setPerformanceText("performanceKpiCompletedRevenue", "—")'), "7 KPIs dash while loading");
assert(perfSection.includes('id="performanceRetryBtn"') && perfSection.includes("admin-analytics-retry"), "8 Performance Retry exists");
assert(paintPerfUnavailable.includes("paintPerformanceDashValues()"), "8 error clears misleading values");

/* 9–11 Customer / Service / Staff Retry */
assert(caSection.includes('id="customerAnalyticsRetryBtn"') && caSection.includes("admin-analytics-retry"), "9 Customer Retry exists");
assert(saSection.includes('id="serviceAnalyticsRetryBtn"') && saSection.includes("admin-sa-retry"), "10 Service Retry unchanged");
assert(staSection.includes('id="staffAnalyticsRetryBtn"') && staSection.includes("admin-sta-retry"), "11 Staff Retry unchanged");

/* 12 Retry >=44px */
assert(retryCss.includes("min-height: 44px") && retryCss.includes("min-width: 44px"), "12 Retry min 44px");
assert(retryCss.includes("width: auto"), "12 Retry not full-width CTA");

/* 13 Retry uses current period/business */
assert(bindPerf.includes("void runAdminPerformanceReport()"), "13 Performance retry reruns active report");
assert(bindPerf.includes("void runAdminCustomerAnalyticsReport({ force: true })"), "13 Customer retry force current period");
assert(bindSa.includes("void runAdminServiceAnalyticsReport({ force: true })"), "13 Service retry force current");
assert(bindSta.includes("void runAdminStaffAnalyticsReport({ force: true })"), "13 Staff retry force current");
assert(perfRun.includes("getActivePerformancePeriodRange()") && caRun.includes("getActivePerformancePeriodRange()"), "13 retry path uses active period");

/* 14 no duplicate listener */
assert(bindPerf.includes("if (performanceControlsBound) return"), "14 Performance bind guard");
assert(bindSa.includes("if (serviceAnalyticsUiBound) return"), "14 Service bind guard");
assert(bindSta.includes("if (staffAnalyticsUiBound) return"), "14 Staff bind guard");
assert(count(html, 'getElementById("performanceRetryBtn")?.addEventListener') === 1, "14 Performance Retry bound once");
assert(count(html, 'getElementById("customerAnalyticsRetryBtn")?.addEventListener') === 1, "14 Customer Retry bound once");
assert(count(html, 'getElementById("serviceAnalyticsRetryBtn")?.addEventListener') === 1, "14 Service Retry bound once");
assert(count(html, 'getElementById("staffAnalyticsRetryBtn")?.addEventListener') === 1, "14 Staff Retry bound once");

/* 15–20 shared quality notes */
assert(html.includes(".admin-analytics-note"), "15 shared analytics note class");
assert(noteCss.includes("font-size: 12px") && noteCss.includes("padding: 10px 12px") && noteCss.includes("border-radius: 12px"), "15 note visual contract");
assert(perfSection.includes('id="performanceEstimatedNote"') && perfSection.includes("admin-analytics-note"), "16 Performance quality note");
assert(perfSection.includes("admin-analytics-note admin-performance-footnote"), "16 Performance methodology note");
assert(caSection.includes('id="caCoverage"') && caSection.includes("admin-analytics-note admin-ca-coverage"), "17 Customer coverage note");
assert(caSection.includes('id="caEstimatedNote"') && caSection.includes("admin-analytics-note"), "17 Customer estimated note");
assert(!cssRule("#adminSectionCustomerAnalytics .admin-ca-note").includes("#4338ca"), "17 CA estimated note not indigo KPI");
assert(saSection.includes('id="serviceAnalyticsEstimatedNote"') && saSection.includes("admin-analytics-note"), "18 Service estimated note");
assert(staSection.includes('id="staffAnalyticsEstimatedNote"') && staSection.includes("admin-analytics-note"), "19 Staff estimated note");
assert(staSection.includes('id="staffAnalyticsUnassignedNote"') && staSection.includes("admin-analytics-note--warn"), "20 Staff warning variant");

/* 21–22 Customer insights hierarchy */
const kpiPos = caSection.indexOf('id="caKpiAvgVisits"');
const insightsPos = caSection.indexOf('id="customerAnalyticsInsights"');
const lifetimePos = caSection.indexOf('data-i18n="caLifetimeHeading"');
assert(kpiPos >= 0 && insightsPos > kpiPos, "21 insights below primary KPI grid");
assert(lifetimePos > insightsPos, "21 insights above lifetime/detail");
assert(insightCss.includes("font-size: 12px") && insightCss.includes("color: #64748b"), "22 insights visually secondary");
assert(!insightCss.includes("#001b5e"), "22 insights not navy KPI");
assert(html.includes('class="admin-analytics-note admin-ca-insight"'), "22 insights use note container");

/* 23–26 clickable Customer KPI buttons */
assert(caSection.includes("<button type=\"button\"") && caSection.includes("admin-ca-kpi--clickable"), "25 semantic button remains");
assert(kpiBtnCss.includes("margin: 0") && kpiBtnCss.includes("padding: 14px 22px 14px 12px"), "23 opted out of global CTA margin/padding");
assert(kpiBtnCss.includes("min-height: 92px") && kpiBtnCss.includes("border-radius: 16px"), "24 clickable KPI matches article card");
assert(html.includes("body.admin-mobile-shell-active #adminView #adminSectionCustomerAnalytics button.admin-ca-kpi--clickable"), "23 mobile CTA override");
assert(caSection.includes('aria-label="Active Customers"') && caSection.includes("admin-ca-kpi__chev"), "26 aria-label and chevron remain");

/* 27–28 CA long money wrap */
assert(caValueCss.includes("white-space: normal"), "27 CA money can wrap");
assert(caValueCss.includes("overflow-wrap: anywhere"), "27 long money wraps");
assert(!/#adminSectionCustomerAnalytics \.admin-ca-value-row__value\s*\{[^}]*white-space:\s*nowrap/.test(html), "27 no nowrap on CA money");
assert(html.includes("#adminSectionCustomerAnalytics") && html.includes("overflow-x: hidden"), "28 no horizontal scroll introduced");

/* 29–33 summary grids */
const saSummaryCss = cssRule("#adminSectionServiceAnalytics .admin-performance-kpi-grid--sa-summary");
const staSummaryCss = cssRule("#adminSectionStaffAnalytics .admin-performance-kpi-grid--sta-summary");
assert(saSummaryCss.includes("repeat(2, minmax(0, 1fr))"), "29 Service mobile summary 2-col");
assert(html.includes("#adminSectionServiceAnalytics .admin-performance-kpi-grid--sa-summary > :nth-child(3)") && html.includes("grid-column: 1 / -1"), "29 third Service card spans");
assert(staSummaryCss.includes("repeat(2, minmax(0, 1fr))"), "30 Staff mobile summary 2-col");
assert(html.includes("grid-template-columns: repeat(2, minmax(0, 1fr))"), "31/32 shared 2-col mobile KPI grid");
assert(html.includes("#adminSectionPerformance .admin-performance-kpi-grid--primary") && html.includes("repeat(4, minmax(0, 1fr))"), "33 Performance desktop 4-col primary");

/* 34 SA/STA summary typography */
assert(saMetricCss.includes("font-size: 1.15rem"), "34 Service summary 1.15rem");
assert(staMetricCss.includes("font-size: 1.15rem"), "34 Staff summary 1.15rem");

/* 35 Staff tertiary secondary */
assert(staTertiaryCss.includes("font-size: 12px") && staTertiaryCss.includes("font-weight: 500") && staTertiaryCss.includes("color: #64748b"), "35 Staff tertiary secondary");
assert(html.includes('class="admin-sta-card__tertiary"'), "35 tertiary grouping markup");

/* 36–42 terminology */
assert(html.includes('commonCustomerAnalytics: "Аналитика на клиенти"'), "36 MK Customer Analytics");
assert(html.includes('saCompletedRevenue: "Реализиран приход"') && html.includes('staCompletedRevenue: "Реализиран приход"'), "37 MK Completed revenue");
assert(html.includes('saCompletedVisits: "Реализирани посети"') && html.includes('staCompletedVisits: "Реализирани посети"'), "38 MK Completed visits");
assert(html.includes('perfLoadError: "Не може да се вчитаат Перформанси"'), "39 MK Performance error uses Перформанси");
assert(!html.includes("извештајот за успешност"), "39 no успешност leftover");
assert(html.includes('staTrendNew: "Ново"'), "40 MK staff New is Ново");
assert(html.includes('saTrendNew: "Нова"'), "40 Service keeps feminine Нова");
assert(staffTrendFn.includes('t("staTrendNew", "New")'), "40 staff trend uses staTrendNew");
assert(serviceTrendFn.includes('t("saTrendNew", "New")'), "40 service trend still saTrendNew");
assert(html.includes('commonCustomerAnalytics: "Analitika e klientëve"'), "41 SQ Customer Analytics");
assert(html.includes('saCompletedRevenue: "Të ardhura të realizuara"') && html.includes('staCompletedRevenue: "Të ardhura të realizuara"'), "42 SQ completed revenue locked");

/* 43 Customers not Clients inside Analytics */
assert(html.includes('perfEmptyCustomers: "No customers in this period."'), "43 Performance empty uses customers");
assert(html.includes('perfTopCustomers: "Top customers"'), "43 Top customers");
assert(perfSection.includes(">Top customers<"), "43 rank heading customers");
assert(!perfSection.includes(">Top clients<"), "43 no Top clients leftover");
assert(html.includes("No customer activity in this period."), "43 Customer empty uses customers");

/* 44–46 missing-value contract */
assert(formatBusinessMoney(0) === "0 MKD", "44 zero money = 0 currency");
assert(formatBusinessMoney(null) === "—", "45 null money = —");
assert(formatBusinessMoney(undefined) === "—", "45 undefined money = —");
assert(formatPerformanceCount(0) === "0", "46 known zero stays 0");
assert(formatPerformanceCount(null) === "—", "46 general unavailable not silent zero");
assert(html.includes("performanceNumericOrNull(rpc.completed_revenue)"), "46 Performance money null not coerced to zero");
assert(html.includes('formatStaffAnalyticsUnassignedShareKpi(null)') || html.includes("return t(\"saTrendNA\", \"N/A\")") || html.includes('staTrendNA') || html.includes('saTrendNA: "N/A"'), "46 N/A for unavailable metrics");

/* 47–53 no backend / no new surfaces */
assert(fetchPerf.includes("get_business_performance_report"), "47 Performance RPC unchanged");
assert(fetchCa.includes("get_business_customer_analytics_overview"), "48 Customer RPC unchanged");
assert(fetchSa.includes("get_business_service_analytics"), "48 Service RPC unchanged");
assert(fetchSta.includes("get_business_staff_analytics"), "48 Staff RPC unchanged");
assert(!/CREATE\s+OR\s+REPLACE/i.test(fetchPerf + fetchCa + fetchSa + fetchSta), "47 no SQL in analytics fetches");
assert(!fetchPerf.includes("computePerformanceReport("), "50 Performance UI does not call legacy aggregator");
assert(!html.includes('id="adminSectionStaffDetail"') && !html.includes("openStaffDetail"), "51 no Staff Detail");
assert(!html.includes('id="adminSectionServiceDetail"') && !html.includes("openServiceDetail"), "52 no Service Detail");
assert(!staSection.toLowerCase().includes("utilization"), "53 no utilization");

/* Extra: empty-state copy + period chips still 6 secondary */
assert(html.includes("No service activity in this period."), "empty Service specific");
assert(html.includes("No staff activity in this period."), "empty Staff specific");
assert(count(perfSection, 'data-performance-preset="q1"') === 1, "six secondary chips still present");
assert(html.includes("admin-performance-presets--secondary"), "secondary chip row remains");
assert(html.includes("caLifetimeHeading: \"За цело време\""), "lifetime MK communicates historical scope");
assert(html.includes("caLifetimeHeading: \"Gjatë gjithë kohës\""), "lifetime SQ communicates historical scope");
assert(html.includes("@keyframes admin-analytics-skel-shimmer"), "skeleton animation shared");

console.log("analytics-consistency-ui: all Phase 6B contract checks passed");
