#!/usr/bin/env node
/**
 * Static UI contract: Analytics Overview exits to Home; drill-downs return to Overview.
 * Does not call RPCs or change analytics formulas.
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
  assert(start >= 0, `missing start: ${startNeedle.slice(0, 80)}`);
  assert(end > start, `missing end after: ${startNeedle.slice(0, 80)}`);
  return src.slice(start, end);
}

function buttonSnippet(id) {
  const start = html.indexOf(`id="${id}"`);
  assert(start >= 0, `missing button ${id}`);
  const tagStart = html.lastIndexOf("<button", start);
  const tagEnd = html.indexOf("</button>", start);
  assert(tagStart >= 0 && tagEnd > tagStart, `unclosed button ${id}`);
  return html.slice(tagStart, tagEnd + "</button>".length);
}

const homeBackCss = sliceBetween(
  html,
  "/* Top-level analytics Home Back — mobile only; do not reuse Segment/Detail selectors */",
  ":is(#adminSectionPerformance, #adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) .admin-performance-screen__subtitle"
);

const perfBtn = buttonSnippet("perfHomeBackBtn");
const caBtn = buttonSnippet("caHomeBackBtn");
const saBtn = buttonSnippet("saHomeBackBtn");
const staffBtn = buttonSnippet("staffHomeBackBtn");
const crossBtn = buttonSnippet("crossHomeBackBtn");
const segBtn = buttonSnippet("caSegBackBtn");
const detBtn = buttonSnippet("caDetBackBtn");

/* 1–3 exist */
assert(html.includes('id="perfHomeBackBtn"'), "1 perfHomeBackBtn exists");
assert(html.includes('id="caHomeBackBtn"'), "2 caHomeBackBtn exists");
assert(html.includes('id="saHomeBackBtn"'), "3 saHomeBackBtn exists");
assert(html.includes('id="staffHomeBackBtn"'), "3b staffHomeBackBtn exists");
assert(html.includes('id="crossHomeBackBtn"'), "3c crossHomeBackBtn exists");

/* First child of each screen header */
assert(
  /<header class="admin-native-screen__header admin-performance-screen__header">\s*<button[^>]+id="perfHomeBackBtn"/.test(html),
  "1 perfHomeBackBtn is first child of Performance header"
);
assert(
  /<header class="admin-native-screen__header admin-performance-screen__header">\s*<button[^>]+id="caHomeBackBtn"/.test(html),
  "2 caHomeBackBtn is first child of Customer Analytics header"
);
assert(
  /<header class="admin-native-screen__header admin-performance-screen__header">\s*<button[^>]+id="saHomeBackBtn"/.test(html),
  "3 saHomeBackBtn is first child of Service Analytics header"
);
assert(
  /<header class="admin-native-screen__header admin-performance-screen__header">\s*<button[^>]+id="staffHomeBackBtn"/.test(html),
  "3b staffHomeBackBtn is first child of Staff Analytics header"
);
assert(
  /<header class="admin-native-screen__header admin-performance-screen__header">\s*<button type="button" id="crossHomeBackBtn"/.test(html),
  "3c crossHomeBackBtn is first child of Cross Analytics header"
);

/* 4 class */
assert(perfBtn.includes('class="admin-ca-seg-back hidden"') && perfBtn.includes(" hidden"), "4 Overview legacy Back is hidden");
assert(caBtn.includes('class="admin-ca-seg-back hidden"') && caBtn.includes(" hidden"), "4 Customer legacy Back is hidden");
assert(saBtn.includes('class="admin-ca-seg-back hidden"') && saBtn.includes(" hidden"), "4 Service legacy Back is hidden");
assert(staffBtn.includes('class="admin-ca-seg-back hidden"') && staffBtn.includes(" hidden"), "4 Staff legacy Back is hidden");
assert(crossBtn.includes('class="admin-ca-seg-back"'), "4 cross uses admin-ca-seg-back");

/* 5 commonBack */
for (const [name, snippet] of [
  ["perf", perfBtn],
  ["ca", caBtn],
  ["sa", saBtn],
  ["staff", staffBtn]
]) {
  assert(snippet.includes('data-i18n-aria-label="commonBack"'), `5 ${name} aria commonBack`);
  assert(snippet.includes('data-i18n="commonBack"'), `5 ${name} label commonBack`);
  assert(snippet.includes(">Back</span>"), `5 ${name} EN Back`);
  assert(snippet.includes('class="admin-ca-seg-back__icon"'), `5 ${name} same chevron class`);
}

assert(crossBtn.includes('data-i18n-aria-label="commonBack"'), "5 cross aria commonBack");
assert(crossBtn.includes('class="admin-ca-seg-back__icon"'), "5 cross same chevron class");
assert(!crossBtn.includes('data-i18n="commonBack"'), "5 cross Back is icon-only like Filters");
assert(!crossBtn.includes(">Back</span>"), "5 cross has no visible Back label");
assert(html.includes("#crossHomeBackBtn") && html.includes("#xaFilterHeader .admin-xa-sheet__back"), "5 cross shares Filters circular Back rules");

assert(html.includes('commonBack: "Back"'), "12 EN commonBack reused");
assert(html.includes('commonBack: "Назад"'), "12 MK commonBack reused");
assert(html.includes('commonBack: "Kthehu"'), "12 SQ commonBack reused");

/* 6 destination */
assert(perfBtn.includes("onclick=\"setAdminSection('overview')\""), "6 perf → overview");
assert(caBtn.includes("onclick=\"setAdminSection('performance')\""), "6 ca → Analytics Overview");
assert(saBtn.includes("onclick=\"setAdminSection('performance')\""), "6 sa → Analytics Overview");
assert(staffBtn.includes("onclick=\"setAdminSection('performance')\""), "6 staff → Analytics Overview");
assert(crossBtn.includes("onclick=\"setAdminSection('performance')\""), "6 cross → Analytics Overview");
assert(html.includes('id="adminSectionOverview"'), "6 canonical Home panel exists");
assert(!perfBtn.includes("adminSectionHome") && !caBtn.includes("adminSectionHome") && !saBtn.includes("adminSectionHome") && !staffBtn.includes("adminSectionHome") && !crossBtn.includes("adminSectionHome"), "6 not #adminSectionHome");
assert(!html.includes("setAdminSection('home')"), "6 no navigate to home panel");

/* 7–8 no browser history */
for (const [name, snippet] of [
  ["perf", perfBtn],
  ["ca", caBtn],
  ["sa", saBtn],
  ["staff", staffBtn],
  ["cross", crossBtn]
]) {
  assert(!snippet.includes("history.back"), `7 ${name} no history.back`);
  assert(!snippet.includes("history.go"), `7 ${name} no history.go`);
  assert(!snippet.includes("popstate"), `8 ${name} no popstate`);
  assert(!snippet.includes("setAdminMobileTab"), `6 ${name} no tab-click simulation`);
}

const setAdminSectionFn = sliceBetween(
  html,
  "function setAdminSection(sectionKey, opts = {}) {",
  "function shouldUseAdminMobileShell()"
);
assert(!/history\.back\s*\(/.test(setAdminSectionFn), "8 setAdminSection adds no history.back");
assert(!/history\.go\s*\(/.test(setAdminSectionFn), "8 setAdminSection adds no history.go");

/* 9–11 mobile width:auto + CTA protection + 44px */
assert(homeBackCss.includes("body.admin-mobile-shell-active #adminView"), "9 mobile #adminView specificity");
assert(homeBackCss.includes("width: auto"), "9 width:auto");
assert(homeBackCss.includes("max-width: max-content"), "9 max-content intrinsic sizing");
assert(homeBackCss.includes("display: inline-flex"), "10 inline-flex not block CTA");
assert(homeBackCss.includes("justify-content: flex-start"), "10 left-aligned");
assert(homeBackCss.includes("text-align: left"), "10 text-align left");
assert(homeBackCss.includes("flex: 0 0 auto"), "10 flex 0 0 auto");
assert(homeBackCss.includes("min-height: 44px"), "11 touch target >=44px");
assert(homeBackCss.includes("min-width: 44px"), "11 min-width 44px");
assert(homeBackCss.includes("background: var(--surface-soft, #f8fafc)"), "10 soft nav surface not navy CTA");
assert(homeBackCss.includes("color: #001b5e"), "10 navy text not white CTA");
assert(!/width:\s*100%/.test(homeBackCss), "10 Home Back CSS does not set width 100%");

/* 12 desktop hide / 13 mobile show */
assert(homeBackCss.includes("display: none"), "12 desktop hides top-level Back");
assert(
  homeBackCss.includes("body.admin-mobile-shell-active") && homeBackCss.includes("display: inline-flex"),
  "13 mobile shows top-level Back"
);
assert(
  !homeBackCss.includes("#adminSectionCustomerAnalytics .admin-ca-seg-back,") &&
    !homeBackCss.includes("#adminSectionCustomerAnalytics .admin-ca-seg-back:hover"),
  "do not alter existing Segment/Detail CSS selectors"
);

/* 14–17 Segment / Detail unchanged */
assert(segBtn.includes('id="caSegBackBtn"'), "14 caSegBackBtn unchanged id");
assert(!segBtn.includes("setAdminSection('overview')"), "14 Segment Back does not go Home");
assert(!segBtn.includes("onclick="), "14 Segment Back still listener-driven");
assert(html.includes("document.getElementById(\"caSegBackBtn\")?.addEventListener(\"click\", () => {"), "14 Segment click listener");
assert(html.includes("closeCustomerAnalyticsSegmentView();"), "16 Segment Back → Customer Analytics");
assert(html.includes("function closeCustomerAnalyticsSegmentView(opts = {}) {"), "16 closeCustomerAnalyticsSegmentView present");
assert(html.includes("function openCustomerAnalyticsSegment(spec) {"), "16 openCustomerAnalyticsSegment present");

assert(detBtn.includes('id="caDetBackBtn"'), "15 caDetBackBtn unchanged id");
assert(!detBtn.includes("setAdminSection('overview')"), "15 Detail Back does not go Home");
assert(!detBtn.includes("onclick="), "15 Detail Back still listener-driven");
assert(html.includes("document.getElementById(\"caDetBackBtn\")?.addEventListener(\"click\", () => {"), "15 Detail click listener");
assert(html.includes("closeCustomerAnalyticsCustomerDetail();"), "17 Detail Back → Segment");
assert(html.includes("function closeCustomerAnalyticsCustomerDetail(opts = {}) {"), "17 closeCustomerAnalyticsCustomerDetail present");
assert(html.includes("function openCustomerAnalyticsCustomerDetail(customerKey) {"), "17 openCustomerAnalyticsCustomerDetail present");
assert(
  html.includes("if (customerAnalyticsSegmentState.open)") && html.includes("paintCustomerAnalyticsSegmentView()"),
  "17 Detail Back restores Segment"
);

/* 18–19 sibling-hide still covers the header (caHomeBackBtn lives in header, a direct screen child) */
const segHide = html.includes(
  "#adminSectionCustomerAnalytics.admin-ca-segment-open .admin-performance-screen > *:not(#customerAnalyticsSegmentView)"
);
const detHide = html.includes(
  "#adminSectionCustomerAnalytics.admin-ca-detail-open .admin-performance-screen > *:not(#customerAnalyticsDetailView)"
);
assert(segHide, "18 Segment sibling-hide still present");
assert(detHide, "19 Detail sibling-hide still present");
assert(
  html.includes("admin-native-screen admin-performance-screen") &&
    html.includes('id="caHomeBackBtn"') &&
    html.includes('id="customerAnalyticsSegmentView"'),
  "18 header (with caHomeBackBtn) is a sibling of Segment view"
);

const caSection = sliceBetween(
  html,
  '<section id="adminSectionCustomerAnalytics"',
  '<section id="adminSectionServiceAnalytics"'
);
assert(
  caSection.indexOf("admin-performance-screen__header") < caSection.indexOf('id="customerAnalyticsSegmentView"'),
  "18 header precedes Segment view inside the same screen"
);
assert(
  caSection.indexOf('id="caHomeBackBtn"') < caSection.indexOf('id="customerAnalyticsSegmentView"'),
  "18 caHomeBackBtn is in the header sibling, not inside Segment view"
);
assert(!caSection.slice(caSection.indexOf('id="customerAnalyticsSegmentView"')).includes("caHomeBackBtn"), "18 caHomeBackBtn not inside Segment");
assert(!caSection.slice(caSection.indexOf('id="customerAnalyticsDetailView"')).includes("caHomeBackBtn"), "19 caHomeBackBtn not inside Detail");

/* 20 bottom nav now exposes one unified Analytics destination */
const bottomNav = sliceBetween(html, 'id="adminMobileBottomNav"', "</nav>");
assert(bottomNav.includes('data-admin-mobile-tab="overview"'), "20 Home tab");
assert(bottomNav.includes('data-admin-mobile-tab="calendar"'), "20 Book tab");
assert(bottomNav.includes('data-admin-mobile-tab="bookings"'), "20 Bookings tab");
assert(bottomNav.includes('data-admin-mobile-tab="analytics"'), "20 Analytics tab");
assert(bottomNav.includes('data-admin-mobile-tab="settings"'), "20 Settings tab");
assert(!bottomNav.includes('data-admin-mobile-tab="clients"'), "20 no Clients bottom tab");
assert(!bottomNav.includes("perfHomeBackBtn"), "20 back not injected into bottom nav");
assert(!bottomNav.includes("data-admin-mobile-tab=\"performance\""), "20 no separate Performance tab");
assert(!bottomNav.includes("data-admin-mobile-tab=\"customer-analytics\""), "20 no CA tab");
assert(!bottomNav.includes("data-admin-mobile-tab=\"service-analytics\""), "20 no SA tab");
assert(!bottomNav.includes("data-admin-mobile-tab=\"staff-analytics\""), "20 no Staff Analytics tab");
assert(!bottomNav.includes("data-admin-mobile-tab=\"cross-analytics\""), "20 no Cross Analytics tab");

/* 21 setAdminSection unchanged */
assert(html.includes("function setAdminSection(sectionKey, opts = {}) {"), "21 setAdminSection signature");
assert(setAdminSectionFn.includes('syncAdminMobileTabHighlightFromSection(key)'), "21 still syncs Home tab from overview");
assert(setAdminSectionFn.includes("closeCustomerAnalyticsCustomerDetail({ silent: true })"), "21 still silent-closes Detail when leaving CA");
assert(setAdminSectionFn.includes("closeCustomerAnalyticsSegmentView({ silent: true })"), "21 still silent-closes Segment when leaving CA");
assert(setAdminSectionFn.includes("renderAdminPerformance()"), "21 Performance render path");
assert(setAdminSectionFn.includes("renderAdminCustomerAnalytics()"), "21 CA render path");
assert(setAdminSectionFn.includes("renderAdminServiceAnalytics()"), "21 SA render path");
assert(setAdminSectionFn.includes("renderAdminStaffAnalytics()"), "21 Staff Analytics render path");
assert(setAdminSectionFn.includes("renderAdminCrossAnalytics()"), "21 Cross Analytics render path");

const tabHighlight = sliceBetween(
  html,
  "function syncAdminMobileTabHighlightFromSection(sectionKey) {",
  "function setAdminMobileTab(tab, opts = {}) {"
);
assert(tabHighlight.includes("overview: \"overview\""), "10 Home tab maps from overview");
assert(tabHighlight.includes('performance: "analytics"'), "Analytics Overview maps to Analytics bottom tab");
assert(tabHighlight.includes('"customer-analytics": "analytics"'), "Customer Analytics maps to Analytics bottom tab");
assert(tabHighlight.includes('"service-analytics": "analytics"'), "Service Analytics maps to Analytics bottom tab");
assert(tabHighlight.includes('"staff-analytics": "analytics"'), "Staff Analytics maps to Analytics bottom tab");

/* 22 setAdminMobileTab unchanged */
const setAdminMobileTabFn = sliceBetween(
  html,
  "function setAdminMobileTab(tab, opts = {}) {",
  "function applyAdminMobileShellUi()"
);
assert(setAdminMobileTabFn.includes("ADMIN_MOBILE_TAB_SECTIONS[key]"), "22 still maps tab → section");
assert(setAdminMobileTabFn.includes("setAdminSection("), "22 still calls setAdminSection");
assert(!setAdminMobileTabFn.includes("perfHomeBackBtn"), "22 tab function not wired to new backs");

/* Analytics RPCs untouched */
assert(html.includes("get_business_performance_report"), "23 Performance RPC present");
assert(html.includes("get_business_customer_analytics_overview") || html.includes("get_business_customer_segment"), "24 CA RPCs present");
assert(html.includes("get_business_service_analytics"), "25 Service Analytics RPC present");
assert(html.includes("get_business_staff_analytics"), "25b Staff Analytics RPC present");
assert(tabHighlight.includes('"cross-analytics": "analytics"'), "advanced analytics preserves Analytics bottom-tab state");

console.log("analytics-home-back-ui: passed");
