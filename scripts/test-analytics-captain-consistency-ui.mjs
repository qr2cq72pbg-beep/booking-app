#!/usr/bin/env node
/**
 * Analytics CAPTAIN consistency sweep.
 * Static UI contract only. Does not call RPCs or change formulas.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
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

function buttonSnippet(id) {
  const start = html.indexOf(`id="${id}"`);
  assert(start >= 0, `missing button ${id}`);
  const tagStart = html.lastIndexOf("<button", start);
  const tagEnd = html.indexOf("</button>", start);
  assert(tagStart >= 0 && tagEnd > tagStart, `unclosed button ${id}`);
  return html.slice(tagStart, tagEnd + "</button>".length);
}

function extractFn(name) {
  const start = html.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  assert(start >= 0, `missing function ${name}`);
  let depth = 0;
  let started = false;
  for (let i = start; i < html.length; i += 1) {
    if (html[i] === "{") {
      depth += 1;
      started = true;
    } else if (html[i] === "}") {
      depth -= 1;
      if (started && depth === 0) return html.slice(start, i + 1);
    }
  }
  assert(false, `unclosed function ${name}`);
  return "";
}

const ANALYTICS_BACK_IDS = [
  "perfHomeBackBtn",
  "caHomeBackBtn",
  "saHomeBackBtn",
  "staffHomeBackBtn",
  "crossHomeBackBtn",
  "caSegBackBtn",
  "caDetBackBtn"
];

const ANALYTICS_RETRY_IDS = [
  "performanceRetryBtn",
  "customerAnalyticsRetryBtn",
  "caSegRetryBtn",
  "caDetRetryBtn",
  "serviceAnalyticsRetryBtn",
  "staffAnalyticsRetryBtn",
  "crossAnalyticsRetryBtn",
  "crossAnalyticsMoreRetryBtn"
];

/* 1. No Analytics Back uses primary/full-width CTA classes. */
for (const id of ANALYTICS_BACK_IDS) {
  const snippet = buttonSnippet(id);
  assert(snippet.includes('class="admin-ca-seg-back'), `1 ${id} uses canonical Back class`);
  assert(!/\badmin-primary-btn\b/.test(snippet), `1 ${id} is not admin-primary-btn`);
  assert(!/\badmin-saas-btn--primary\b/.test(snippet), `1 ${id} is not saas primary`);
  assert(!/\badmin-performance-generate\b/.test(snippet), `1 ${id} is not generate CTA`);
  assert(!/width:\s*100%/.test(snippet), `1 ${id} has no inline full width`);
}

/* 2. Canonical Back is used by all Analytics-owned drill-downs. */
assert(buttonSnippet("caSegBackBtn").includes("admin-ca-seg-back"), "2 segment Back canonical");
assert(buttonSnippet("caDetBackBtn").includes("admin-ca-seg-back"), "2 detail Back canonical");
assert(buttonSnippet("crossHomeBackBtn").includes("admin-ca-seg-back"), "2 Cross Back canonical");
assert(html.includes('id="analyticsQualityBackBtn"') && html.includes("analytics-sheet__back"), "2 quality Back canonical");
assert(html.includes("Canonical Analytics Back"), "2 host-independent Back CSS present");
assert(html.includes("#customerAnalyticsDetailView") && html.includes("button.admin-ca-seg-back"), "2 detail Back styled off section owner");
assert(html.includes("portalCustomerAnalyticsDetailToCross"), "2 Cross still portals the same detail view");

/* 3. No Analytics Retry uses giant primary/full-width CTA styling. */
for (const id of ANALYTICS_RETRY_IDS) {
  const snippet = buttonSnippet(id);
  assert(
    snippet.includes("admin-analytics-retry") || snippet.includes("admin-ca-seg-retry"),
    `3 ${id} uses compact retry class`
  );
  assert(!/\badmin-primary-btn\b/.test(snippet), `3 ${id} is not admin-primary-btn`);
  assert(!/\badmin-performance-generate\b/.test(snippet), `3 ${id} is not generate CTA`);
}

const retryCss = sliceBetween(
  html,
  "/* Canonical compact retry — never a full-width primary CTA. */",
  "#customerAnalyticsDetailView .admin-ca-det-identity"
);
assert(retryCss.includes("width: auto"), "3 retry width auto");
assert(retryCss.includes("min-height: 44px"), "3 retry 44px");
assert(retryCss.includes("var(--theme-surface-primary)"), "3 retry semantic surface");
assert(retryCss.includes("var(--theme-text-link)"), "3 retry not on-primary navy CTA");
assert(!retryCss.includes("background: #001b5e"), "3 retry not hardcoded navy");
assert(!/(?:^|[^-])width:\s*100%/.test(retryCss), "3 retry not full-width");

const notesFn = extractFn("buildCustomerAnalyticsDetailNotesHtml");
assert(notesFn.includes("caDetNotesRetryBtn") && notesFn.includes("admin-ca-det-notes__btn--muted"), "3 notes retry is secondary");
assert(notesFn.includes("caDetNotesAddBtn") && notesFn.includes("admin-ca-det-notes__btn--muted"), "4 add note is secondary");
assert(notesFn.includes("caDetNotesSaveBtn") && notesFn.includes("admin-ca-det-notes__btn--primary"), "4 save remains the commit action");

/* 4. Customer list uses canonical compact row class. */
const segRowFn = extractFn("buildCustomerAnalyticsSegmentRowHtml");
assert(segRowFn.includes("admin-ca-seg-row"), "4 segment rows use compact row class");
assert(segRowFn.includes("admin-ca-seg-row__metrics"), "4 segment metrics hierarchy");
assert(segRowFn.includes("admin-ca-seg-row__activity"), "4 segment activity hierarchy");
assert(segRowFn.includes("admin-ca-seg-row__inactive"), "4 inactivity is a compact badge");
assert(segRowFn.includes("admin-ca-row__chev"), "4 clickable rows keep chevron");
assert(html.includes("#customerAnalyticsSegmentView .admin-ca-seg-row"), "4 segment row CSS present");
assert(html.includes("border-radius: var(--analytics-radius-row, 16px)"), "4 16px row radius");

const xaRowFn = extractFn("paintCrossAnalyticsRowHtml");
assert(xaRowFn.includes("admin-xa-row"), "4 Cross rows stay compact");
assert(xaRowFn.includes("admin-xa-row__metrics"), "4 Cross metrics hierarchy");
assert(xaRowFn.includes("admin-xa-row__activity"), "4 Cross activity hierarchy");
assert(xaRowFn.includes("admin-xa-row__inactive"), "4 Cross inactivity badge");
assert(xaRowFn.includes("admin-xa-row__chev"), "4 Cross chevron");
assert(xaRowFn.includes("demoParts"), "4 Cross omits empty demographics");
assert(xaRowFn.includes('t("xaUnknown", "Unknown")'), "4 unknown demographics still localized");
assert(!xaRowFn.includes("lines.push(`${city} · ${age} · ${gender}`)"), "4 no forced Unknown · Unknown · Unknown");

/* 5. Customer detail uses canonical header/navigation. */
const detailHtml = sliceBetween(html, 'id="customerAnalyticsDetailView"', 'id="adminSectionServiceAnalytics"');
assert(detailHtml.includes('id="caDetBackBtn"') && detailHtml.includes("admin-ca-seg-back"), "5 detail Back canonical");
assert(detailHtml.includes("admin-ca-seg-top") && detailHtml.includes("admin-ca-seg-heading"), "5 detail in-flow header");
assert(!detailHtml.includes("admin-primary-btn"), "5 detail has no primary Back class");
const detailBodyFn = extractFn("buildCustomerAnalyticsDetailBodyHtml");
assert(detailBodyFn.includes("admin-ca-det-identity"), "5 identity group");
assert(detailBodyFn.includes("admin-ca-det-kpis"), "5 2x2 metrics remain");
assert(detailBodyFn.includes("buildCustomerAnalyticsDetailNotesHtml"), "5 notes remain");
assert(detailBodyFn.includes("caDetNoUpcoming"), "5 upcoming state remains");
assert(detailBodyFn.includes("caDetTopServices"), "5 top service remains");
assert(detailBodyFn.includes("caDetVisitHistory"), "5 booking history remains");
assert(html.includes("flex-direction: row") && html.includes("#customerAnalyticsDetailView .admin-ca-seg-top"), "5 header is Back + title row");
assert(detailBodyFn.includes("caDetContact") && detailBodyFn.includes("admin-ca-det-contact__row"), "5 contact is a compact section");
assert(detailBodyFn.includes("caDetProfile") && detailBodyFn.includes("admin-ca-det-demo"), "5 profile metadata is grouped");
assert(detailBodyFn.includes("admin-ca-det-kicker"), "5 detail uses CAPTAIN section kickers");
assert(html.includes("#customerAnalyticsDetailView .admin-ca-seg-error[hidden]"), "5 detail error honors hidden");
assert(html.includes("admin-ca-det-error") && html.includes("admin-ca-det-error__copy"), "5 detail error is compact inline");
assert(html.includes('caDetContact: "Contact"') && html.includes('caDetContact: "Контакт"') && html.includes('caDetContact: "Kontakt"'), "5 contact EN/MK/SQ");
assert(html.includes('caDetProfile: "Profile"') && html.includes('caDetProfile: "Профил"') && html.includes('caDetProfile: "Profili"'), "5 profile EN/MK/SQ");

/* 6. Data Quality remains canonical. */
assert(html.includes('id="analyticsQualitySheet"') && html.includes("analytics-sheet"), "6 quality sheet canonical");
assert(html.includes("analytics-quality-issue") && html.includes("analytics-quality-record"), "6 quality rows canonical");
assert(html.includes('id="analyticsQualityBackBtn"') && html.includes("analytics-sheet__back"), "6 quality Back unchanged");
assert(html.includes("function showAnalyticsQualitySummary") && html.includes("function showAnalyticsQualityDetail"), "6 quality states unchanged");

/* 7. Team / Services / Cross do not regress. */
assert(html.includes('id="adminSectionStaffAnalytics"') && html.includes("admin-sta-card"), "7 Team cards remain");
assert(html.includes('id="adminSectionServiceAnalytics"') && html.includes("admin-sa-card"), "7 Service cards remain");
assert(html.includes('id="adminSectionCrossAnalytics"') && html.includes("admin-xa-row"), "7 Cross rows remain");
assert(html.includes("function paintStaffAnalyticsCard") && html.includes("function paintServiceAnalyticsList"), "7 Team/Services paint paths remain");
assert(!html.includes("openStaffDetail") && !html.includes("openServiceDetail"), "7 no invented staff/service detail");

/* 8. No old Analytics underline-tab system reappears. */
assert(html.includes("analytics-hub-nav__item"), "8 segmented hub nav remains");
assert(!html.includes("admin-analytics-underline-tab"), "8 no underline-tab class");
assert(!html.includes("analytics-legacy-tabs"), "8 no legacy tab system");

/* 9. No legacy period control reappears. */
assert(
  html.includes(":is(#adminSectionCustomerAnalytics, #adminSectionServiceAnalytics, #adminSectionStaffAnalytics, #adminSectionCrossAnalytics) > .admin-performance-screen > .admin-performance-period-controls"),
  "9 leftover inline period remains hidden"
);
assert(html.includes("display: none !important"), "9 leftover period is hidden");
assert(html.includes("analytics-period-bar") && html.includes("analytics-period-trigger"), "9 canonical period field remains");
assert(!html.includes("analytics-legacy-period-chip"), "9 no legacy period chip class");

/* 10. Touched components use semantic tokens. */
const captainBack = sliceBetween(html, "/* Canonical Analytics Back — component-owned, not section-owned.", "/* Canonical compact retry — never a full-width primary CTA. */");
assert(captainBack.includes("var(--theme-surface-primary)"), "10 Back surface token");
assert(captainBack.includes("var(--theme-text-primary)"), "10 Back text token");
assert(captainBack.includes("var(--theme-border-default)"), "10 Back border token");
assert(!captainBack.includes("background: var(--xbook-navy)"), "10 Back is not navy CTA");
assert(!captainBack.includes("background: #001b5e"), "10 Back is not hardcoded navy");
assert(retryCss.includes("var(--theme-border-default)"), "10 retry border token");
assert(html.includes("#adminSectionCrossAnalytics .admin-xa-row") && html.includes("var(--theme-surface-primary)"), "10 Cross rows use surface token");

/* 11. EN / MK / SQ still pass for Back / Retry / upcoming. */
assert(html.includes('commonBack: "Back"') && html.includes('commonBack: "Назад"') && html.includes('commonBack: "Kthehu"'), "11 commonBack EN/MK/SQ");
assert(html.includes('caRetry: "Retry"') || html.includes('perfRetry: "Retry"'), "11 Retry EN");
assert(html.includes("Обиди се повторно"), "11 Retry MK");
assert(html.includes('caDetNoUpcoming: "No upcoming appointment"'), "11 upcoming EN");
assert(html.includes('caDetNoUpcoming: "Нема следен термин"'), "11 upcoming MK");
assert(html.includes('caDetNoUpcoming: "Nuk ka termin të ardhshëm"'), "11 upcoming SQ");

/* 12. inline JS node --check */
const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
assert(inlineScripts.length >= 1, "12 inline JS extracted");
const checkFile = path.join(root, "scripts", ".tmp-captain-consistency-syntax-check.js");
fs.writeFileSync(checkFile, inlineScripts.join("\n;\n"));
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
assert(
  checked.status === 0,
  "12 node --check inline JS" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout))
);
try {
  fs.unlinkSync(checkFile);
} catch {
  /* keep on failure */
}

/* Leak ownership: global CTA lists exclude canonical Analytics controls. */
const ctaBlocks = [
  sliceBetween(html, "/* CTA hierarchy (admin mobile) */", "body.admin-mobile-shell-active #adminView button.success"),
  sliceBetween(
    html,
    "body.admin-mobile-shell-active #adminView button:not(.admin-mobile-nav-item):not(.password-toggle):not(.admin-nav-btn):not(.admin-add-customer-picker__change):not(.business-bookings-main-view-btn):not(.analytics-quality-issue):not(.analytics-sheet__back):not(.analytics-sheet__close):not(.analytics-sheet__icon-btn):not(.admin-ca-seg-back)",
    "body.admin-mobile-shell-active #adminView #adminSectionManual button.admin-add-customer-picker__change"
  )
];
assert(ctaBlocks.length === 2, "6 both mobile CTA leak selectors found");
ctaBlocks.forEach((sel, i) => {
  assert(sel.includes(":not(.admin-ca-seg-back)"), `6 CTA exclusion ${i + 1} includes Back`);
  assert(sel.includes(":not(.admin-analytics-retry)"), `6 CTA exclusion ${i + 1} includes Retry`);
  assert(sel.includes(":not(.admin-ca-seg-retry)"), `6 CTA exclusion ${i + 1} includes segment Retry`);
  assert(sel.includes(":not(.admin-xa-row)"), `6 CTA exclusion ${i + 1} includes Cross rows`);
});

console.log("analytics-captain-consistency-ui: passed");
