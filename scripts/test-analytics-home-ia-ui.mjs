#!/usr/bin/env node
/**
 * Business Home Analytics / Actions information architecture (frontend only).
 * Static contract checks. Does not call SQL, RPCs, or change analytics formulas.
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

const performance = sliceBetween(html, 'id="adminSectionPerformance"', 'id="adminSectionCustomerAnalytics"');
const businessHome = sliceBetween(html, 'id="adminSectionOverview"', 'id="adminSectionCustomize"');
const categoryRail = sliceBetween(performance, 'class="analytics-hub-nav"', "</nav>");
const desktopNav = sliceBetween(html, 'id="adminNav"', "</nav>");
const bottomNav = sliceBetween(html, 'id="adminMobileBottomNav"', "</nav>");
const customerAnalytics = sliceBetween(html, 'id="adminSectionCustomerAnalytics"', 'id="adminSectionServiceAnalytics"');
const serviceAnalytics = sliceBetween(html, 'id="adminSectionServiceAnalytics"', 'id="adminSectionStaffAnalytics"');
const staffAnalytics = sliceBetween(html, 'id="adminSectionStaffAnalytics"', 'id="adminSectionCrossAnalytics"');
const scheduleDeferred = sliceBetween(html, "function scheduleAdminOverviewDeferredData(model)", "function renderAdminStats(opts = {})");

assert(performance.includes('data-i18n="commonAnalytics"') && performance.includes(">Analytics</h1>"), "1 unified Analytics heading exists");
assert(categoryRail.includes('data-analytics-section="performance"'), "2 Overview category exists");
assert(categoryRail.includes('data-analytics-section="customer-analytics"'), "3 Customers category exists");
assert(categoryRail.includes('data-analytics-section="staff-analytics"'), "4 Team category exists");
assert(categoryRail.includes('data-analytics-section="service-analytics"'), "5 Services category exists");
assert(!categoryRail.includes('data-analytics-section="cross-analytics"'), "6 Cross Analytics is not a primary category");
assert(categoryRail.indexOf("performance") < categoryRail.indexOf("customer-analytics"), "7 Overview leads category order");
assert(categoryRail.indexOf("customer-analytics") < categoryRail.indexOf("staff-analytics"), "7 Customers precede Team");
assert(categoryRail.indexOf("staff-analytics") < categoryRail.indexOf("service-analytics"), "7 Team precedes Services");

assert(desktopNav.includes('data-admin-section="performance"'), "8 desktop nav exposes Analytics");
assert(!desktopNav.includes('data-admin-section="customer-analytics"'), "9 no duplicate Customers desktop destination");
assert(!desktopNav.includes('data-admin-section="service-analytics"'), "9 no duplicate Services desktop destination");
assert(!desktopNav.includes('data-admin-section="staff-analytics"'), "9 no duplicate Staff desktop destination");
assert(!desktopNav.includes('data-admin-section="cross-analytics"'), "9 no duplicate Explore desktop destination");

assert(bottomNav.includes('data-admin-mobile-tab="analytics"'), "10 Analytics replaces Clients in bottom navigation");
assert(!bottomNav.includes('data-admin-mobile-tab="clients"'), "10 Clients is not a bottom-nav destination");
assert(!bottomNav.includes('data-admin-mobile-tab="cross-analytics"'), "10 no Explore bottom-nav item");
assert(bottomNav.includes('data-admin-mobile-tab="overview"'), "10 Home tab unchanged");

assert(performance.includes('id="analyticsPeriodSheet"'), "11 shared period sheet exists");
assert(performance.includes('id="analyticsQualitySheet"'), "12 quality sheet exists");
assert(performance.includes("Booking value"), "13 authoritative financial wording");
assert(!performance.includes('id="analyticsReturningRing"'), "14 Overview has no category preview radial");
assert(!performance.includes('id="analyticsCustomerHealthHeading"'), "14 Overview has no Customers preview");
assert(!performance.includes('id="analyticsStaffPreviewHeading"') && !performance.includes('id="analyticsStaffPreview"'), "14 Overview has no Team preview");
assert(!performance.includes('id="analyticsServicePreviewHeading"') && !performance.includes('id="analyticsServicePreview"'), "14 Overview has no Services preview");
assert(!performance.includes("analyticsViewDetails"), "14 Overview has no category View details actions");
assert(!performance.toLowerCase().includes("no-show"), "15 no unsupported no-show metric");
assert(!performance.toLowerCase().includes("utilization"), "16 no unsupported utilization metric");
assert(!performance.includes("CREATE OR REPLACE"), "17 no SQL in Analytics markup");
assert(!html.includes('data-admin-section="analytics-hub"'), "18 performance destination is repurposed");

assert(
  [...bottomNav.matchAll(/data-admin-mobile-tab="([^"]+)"/g)].map((match) => match[1]).join(",") ===
    "overview,calendar,bookings,analytics,settings",
  "19 bottom navigation has exactly Home / Book / Bookings / Analytics / Settings"
);
assert(!businessHome.includes('id="overviewBusinessPulse"'), "20 Home monthly Pulse removed");
assert(!businessHome.includes("Business pulse") && !businessHome.includes("This month"), "20 Home has no monthly performance copy");
assert(!businessHome.includes("overview-quick-actions") && !businessHome.includes("overviewHomeActionsHeading"), "20 Home Shortcuts card removed");
assert(!businessHome.includes("Notify clients") && !businessHome.includes("Shortcuts"), "20 Home has no Shortcuts / Notify clients entry points");
assert(scheduleDeferred.includes("renderAdminOverviewInsights(model)") && !scheduleDeferred.includes("loadAdminOverviewPulse"), "21 Home retains only TODAY insight scheduling");
assert(!sliceBetween(html, "function renderAdminOverviewInsights(model)", "function scheduleAdminOverviewDeferredData(model)").includes("inactiveClients"), "22 historical inactivity insight removed from Home");

for (const [name, section] of [
  ["Customers", customerAnalytics],
  ["Team", staffAnalytics],
  ["Services", serviceAnalytics]
]) {
  assert(section.includes('data-i18n="commonAnalytics">Analytics</h1>'), `23 ${name} inherits Analytics title`);
}
assert(customerAnalytics.includes("openBusinessCustomersList({ from: 'customer-analytics' })"), "24 CRM remains reachable from Customer Analytics");
assert(customerAnalytics.includes("onclick=\"setAdminSection('cross-analytics')\""), "25 Cross Analytics preserved as advanced analysis");
assert(customerAnalytics.includes("admin-ca-overview-nav__row"), "24/25 Customer overview uses compact nav rows");
assert(!customerAnalytics.includes("analytics-section-link"), "24/25 Customer overview no longer uses naked text links");
assert(html.includes('sectionKey === "cross-analytics"') && html.includes('.analytics-hub-nav")?.remove()'), "25 Advanced analysis does not keep the Overview hub tab");

const heroPos = performance.indexOf('class="analytics-financial-hero"');
const comparisonPos = performance.indexOf('id="analyticsComparisonStack"');
const kpiPos = performance.indexOf('class="analytics-kpi-band"');
const insightsPos = performance.indexOf('id="analyticsInsightsSection"');
const qualityPos = performance.indexOf('id="analyticsQualityRow"');
assert(
  heroPos >= 0 &&
    comparisonPos > heroPos &&
    kpiPos > comparisonPos &&
    insightsPos > kpiPos &&
    qualityPos > insightsPos,
  "26 Overview hierarchy: hero, dual comparison, KPI, Insights, Data Quality"
);
assert(
  !/analytics-(?:customer-health|preview-list|preview-row)|analyticsCustomerHealthHeading|analyticsStaffPreview|analyticsServicePreview/.test(performance),
  "26 Overview does not render Customers/Team/Services previews"
);

console.log("analytics-home-ia-ui: passed");
