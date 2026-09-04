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

const overview = sliceBetween(html, 'id="adminSectionOverview"', 'id="adminSectionCustomize"');
const hub = sliceBetween(
  overview,
  'class="overview-actions overview-actions--hub overview-actions--compact"',
  "</section>"
);
const analyticsGroup = sliceBetween(hub, 'data-overview-group="analytics"', 'data-overview-group="actions"');
const actionsStart = hub.indexOf('data-overview-group="actions"');
assert(actionsStart >= 0, "missing Actions group");
const actionsGroup = hub.slice(actionsStart);
const bottomNav = sliceBetween(html, 'id="adminMobileBottomNav"', "</nav>");

assert(hub.includes('data-i18n="homeAnalytics"') && hub.includes(">Analytics</h2>"), "1 Analytics heading exists");
assert(hub.includes('data-i18n="homeActions"') && hub.includes(">Actions</h2>"), "2 Actions heading exists");
assert(!hub.includes("Quick actions"), "3 Quick actions heading absent from Business Home hub");
assert(!hub.includes('data-i18n="homeQuickActions"'), "3 Quick actions i18n unused in Home hub");
assert(!hub.includes('aria-label="Quick actions"'), "3 Quick actions aria-label absent from Home hub");

assert(analyticsGroup.includes("setAdminSection('performance')"), "4 Performance in Analytics");
assert(analyticsGroup.includes("setAdminSection('customer-analytics')"), "5 Customer Analytics in Analytics");
assert(analyticsGroup.includes("setAdminSection('service-analytics')"), "6 Service Analytics in Analytics");
assert(analyticsGroup.includes("setAdminSection('staff-analytics')"), "7 Staff Analytics in Analytics");
assert(analyticsGroup.includes("setAdminSection('cross-analytics')"), "8 Cross Analytics in Analytics");
assert(!analyticsGroup.includes("openCustomerNotificationsSheet()"), "4–8 Notify not in Analytics");
assert(!analyticsGroup.includes("adminMobileOpenNewBooking()"), "4–8 Add booking not in Analytics");

assert(actionsGroup.includes("openCustomerNotificationsSheet()"), "9 Notify customers in Actions");
assert(actionsGroup.includes("adminMobileOpenNewBooking()"), "10 Add booking in Actions");
assert(!actionsGroup.includes("setAdminSection('performance')"), "9–10 Performance not in Actions");
assert(!actionsGroup.includes("setAdminSection('cross-analytics')"), "9–10 Cross Analytics not in Actions");

const analyticsHeadingAt = hub.indexOf('data-i18n="homeAnalytics"');
const actionsHeadingAt = hub.indexOf('data-i18n="homeActions"');
const crossAt = hub.indexOf("setAdminSection('cross-analytics')");
const notifyAt = hub.indexOf("openCustomerNotificationsSheet()");
assert(analyticsHeadingAt >= 0 && analyticsHeadingAt < actionsHeadingAt, "11 Analytics appears before Actions");
assert(crossAt >= 0 && crossAt < actionsHeadingAt, "12 Cross Analytics appears before Actions heading");
assert(notifyAt > actionsHeadingAt, "13 Notify customers appears after Actions heading");

assert(hub.includes("onclick=\"setAdminSection('performance')\""), "14 Performance handler preserved");
assert(hub.includes("onclick=\"setAdminSection('customer-analytics')\""), "14 Customer Analytics handler preserved");
assert(hub.includes("onclick=\"setAdminSection('service-analytics')\""), "14 Service Analytics handler preserved");
assert(hub.includes("onclick=\"setAdminSection('staff-analytics')\""), "14 Staff Analytics handler preserved");
assert(hub.includes("onclick=\"setAdminSection('cross-analytics')\""), "14 Cross Analytics handler preserved");
assert(hub.includes('onclick="openCustomerNotificationsSheet()"'), "14 Notify handler preserved");
assert(hub.includes('onclick="adminMobileOpenNewBooking()"'), "14 Add booking handler preserved");
assert(hub.includes('aria-label="Open Performance"'), "14 Performance a11y preserved");
assert(hub.includes('aria-label="Open Cross Analytics"'), "14 Cross Analytics a11y preserved");
assert(hub.includes('aria-label="Notify customers"'), "14 Notify a11y preserved");
assert(hub.includes('aria-label="Add booking"'), "14 Add booking a11y preserved");

assert(!bottomNav.includes('data-admin-mobile-tab="analytics"'), "15 no Analytics bottom-nav item");
assert(!bottomNav.includes('data-admin-mobile-tab="actions"'), "15 no Actions bottom-nav item");
assert(!bottomNav.includes('data-admin-mobile-tab="cross-analytics"'), "15 no Cross Analytics tab");
assert(bottomNav.includes('data-admin-mobile-tab="overview"'), "15 Home tab unchanged");

assert(html.includes('homeAnalytics: "Analytics"'), "16 EN Analytics");
assert(html.includes('homeActions: "Actions"'), "16 EN Actions");
assert(html.includes('homeAnalytics: "Аналитика"'), "16 MK Analytics");
assert(html.includes('homeActions: "Акции"'), "16 MK Actions");
assert(html.includes('homeAnalytics: "Analitika"'), "16 SQ Analytics");
assert(html.includes('homeActions: "Veprime"'), "16 SQ Actions");

const actionsGap = cssRule("#adminSectionOverview .overview-home-group--actions");
const mobileActionsGap = cssRule("body.admin-mobile-shell-active #adminSectionOverview .overview-home-group--actions");
const titleRule = cssRule("#adminSectionOverview .overview-home-group__title");
const mobileTitleRule = cssRule("body.admin-mobile-shell-active #adminSectionOverview .overview-home-group__title");
assert(/margin-top:\s*28px/.test(actionsGap), "17 Actions heading 28px group gap");
assert(/margin-top:\s*28px/.test(mobileActionsGap), "17 mobile Actions heading 28px group gap");
assert(/font-size:\s*1\.125rem/.test(titleRule) && /font-weight:\s*700/.test(titleRule), "17 heading 18px / 700");
assert(/font-size:\s*1\.1875rem/.test(mobileTitleRule) && /font-weight:\s*700/.test(mobileTitleRule), "17 mobile heading ~19px / 700");
const groupRule = cssRule("#adminSectionOverview .overview-home-group");
assert(groupRule.includes("max-width: 100%"), "17 groups cannot overflow horizontally");

assert(!hub.includes("CREATE OR REPLACE"), "18 no SQL in Home hub");
assert(!hub.includes(".rpc("), "18 no RPC in Home hub");
assert(!html.includes('data-admin-section="analytics-hub"'), "18 no new analytics destination");

console.log("analytics-home-ia-ui: passed");
