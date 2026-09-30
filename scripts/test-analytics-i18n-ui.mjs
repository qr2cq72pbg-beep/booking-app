#!/usr/bin/env node
/**
 * Business Analytics EN/MK/SQ localization contract.
 * Static checks only. Does not change metrics, SQL, or visual IA.
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

function extractObjectBlock(src, startNeedle) {
  const start = src.indexOf(startNeedle);
  assert(start >= 0, `missing block start: ${startNeedle.slice(0, 80)}`);
  let i = src.indexOf("{", start);
  assert(i >= 0, `missing { after ${startNeedle.slice(0, 80)}`);
  let depth = 0;
  for (let j = i; j < src.length; j += 1) {
    const ch = src[j];
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return src.slice(i, j + 1);
    }
  }
  assert(false, `unclosed block ${startNeedle.slice(0, 80)}`);
  return "";
}

function extractKeys(block) {
  const keys = new Set();
  const re = /(?:^|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/gm;
  let m;
  while ((m = re.exec(block))) keys.add(m[1]);
  return keys;
}

const ANALYTICS_PREFIXES = [
  "analytics",
  "caGroup",
  "caInsight",
  "caCoverage",
  "caMix",
  "caRisk",
  "caValue",
  "caKpi",
  "caCard",
  "caFreq",
  "caSeg",
  "caDet",
  "caEmpty",
  "caRetry",
  "caLoad",
  "caPeriod",
  "caLifetime",
  "caSubtitle",
  "caNav",
  "perfLoad",
  "perfRetry",
  "perfEmpty",
  "perfRank",
  "sa",
  "sta",
  "xa"
];

function isAnalyticsKey(key) {
  return ANALYTICS_PREFIXES.some((prefix) => key === prefix || key.startsWith(prefix));
}

const i18nEn = extractObjectBlock(html, "const I18N = {");
const i18nMkStart = html.indexOf("\n    mk: {", html.indexOf("const I18N = {"));
const i18nSqStart = html.indexOf("\n    sq: {", html.indexOf("const I18N = {"));
assert(i18nMkStart > 0 && i18nSqStart > i18nMkStart, "I18N mk/sq blocks exist");
const i18nMk = extractObjectBlock(html.slice(i18nMkStart), "mk: {");
const i18nSq = extractObjectBlock(html.slice(i18nSqStart), "sq: {");

const enKeys = [...extractKeys(i18nEn)].filter(isAnalyticsKey);
const mkKeys = extractKeys(i18nMk);
const sqKeys = extractKeys(i18nSq);

assert(enKeys.length >= 80, `expected a full analytics key set, found ${enKeys.length}`);

const missingMk = enKeys.filter((key) => !mkKeys.has(key));
const missingSq = enKeys.filter((key) => !sqKeys.has(key));
assert(missingMk.length === 0, `MK missing analytics keys: ${missingMk.slice(0, 20).join(", ")}`);
assert(missingSq.length === 0, `SQ missing analytics keys: ${missingSq.slice(0, 20).join(", ")}`);

const REQUIRED = [
  "analyticsQualityEstimated",
  "analyticsQualityUnknown",
  "analyticsQualityEstimatedTitle",
  "analyticsQualityEstimatedBody",
  "analyticsQualityUnassignedTitle",
  "analyticsQualityUnassignedBody",
  "analyticsQualityOrphanTitle",
  "analyticsQualityClearTitle",
  "analyticsQualityQuietChecks",
  "analyticsQualityNoticesOne",
  "analyticsQualityDetailEstimated",
  "analyticsQualityReasonEstimated",
  "analyticsQualityReasonUnassigned",
  "analyticsQualityDetailLoading",
  "commonBack",
  "analyticsEstimatedBadge",
  "analyticsPeriodThisMonth",
  "analyticsPeriodThisWeek",
  "analyticsPeriodThisQuarter",
  "analyticsBookedValue",
  "analyticsRealizedPlusBooked",
  "analyticsCmpStillNeeded",
  "analyticsOutlookStillNeeded",
  "analyticsCustomPeriod",
  "analyticsInsightVipInactive",
  "analyticsInsightReview",
  "caInsightMissingDemo",
  "caCoverageLine",
  "caMixNew",
  "caMixReturning"
];
REQUIRED.forEach((key) => {
  assert(html.includes(`${key}:`), `required key ${key}`);
});

assert(html.includes('tFormat("analyticsQualityEstimatedTitle"') || html.includes("row.titleKey"), "quality issue titles use t()/tFormat");
assert(html.includes("analyticsQualityEstimatedTitle"), "quality estimated title key is used");
assert(html.includes('t("analyticsInsightReview"'), "insight fallback uses t()");
assert(html.includes('tFormat("analyticsInsightVipInactive"'), "insight templates use tFormat");
assert(html.includes('t("caInsightMissingDemo"'), "customer insights use t()");
assert(html.includes('tFormat("caCoverageLine"'), "coverage line uses template");
assert(html.includes('data-i18n="staEmpty"'), "staff empty uses t()/i18n");
assert(html.includes('data-i18n="saEmpty"'), "service empty uses t()/i18n");
assert(html.includes('t("analyticsPeriodThisMonth"'), "period fallback uses t()");
assert(html.includes('t("analyticsChooseValidDates"'), "date toast uses t()");
assert(!html.includes('["Estimated prices", quality.estimatedPrices]'), "no hardcoded quality EN labels");

assert(html.includes('xaPresetAtRisk30: "Inactive 30+ days"'), "EN inactive 30+ days");
assert(html.includes('xaPresetAtRisk90: "Inactive 90+ days"'), "EN inactive 90+ days");
assert(html.includes('caSegAtRisk90: "Inactive — 90+ days"'), "EN segment inactive 90");
assert(html.includes('xaLoadError: "Could not load advanced analysis."'), "EN advanced analysis error");
assert(html.includes('analyticsOverview: "Overview"'), "EN Overview");
assert(html.includes('analyticsTeam: "Team"'), "EN Team nav");
assert(html.includes('analyticsBookingValue: "Booking value"'), "EN Booking value");
assert(html.includes('analyticsViewDetails: "View details"'), "EN View details");
assert(html.includes('caGroupOverview: "Customer overview"'), "EN Customer overview");
assert(html.includes('caGroupMix: "New vs returning"'), "EN New vs returning");
assert(html.includes('analyticsReturningShare: "Returning share"'), "EN keeps returning share");

assert(html.includes('analyticsOverview: "Преглед"'), "MK Overview");
assert(html.includes('analyticsTeam: "Тим"'), "MK Team");
assert(html.includes('analyticsBookingValue: "Вредност на резервации"'), "MK Booking value");
assert(html.includes('analyticsViewDetails: "Види детали"'), "MK View details");
assert(html.includes('caGroupMix: "Нови и повторни"'), "MK New vs returning");
assert(html.includes('caGroupRepeat: "Повторни посети"'), "MK Repeat behavior");
assert(html.includes('caSegReturning: "Повторни клиенти"'), "MK Returning customers");
assert(html.includes('caSegLoadMore: "Прикажи повеќе"'), "MK Load more");
assert(html.includes('analyticsQualityEstimated: "Проценети цени"'), "MK Estimated prices");
assert(html.includes('analyticsInsights: "Согледувања"'), "MK Insights");
assert(html.includes('staUnassigned: "Недоделено"'), "MK Unassigned");
assert(html.includes('xaPresetAtRisk30: "Неактивни 30+ дена"'), "MK inactive 30+ days");
assert(html.includes('xaPresetAtRisk90: "Неактивни 90+ дена"'), "MK inactive 90+ days");
assert(html.includes('caSegAtRisk90: "Неактивни — 90+ дена"'), "MK segment inactive 90");
assert(html.includes('analyticsInsightChange: "Промена во резултатите"'), "MK performance-change insight");
assert(html.includes('analyticsInsightOpportunity: "Деловна можност"'), "MK business-opportunity insight");
assert(html.includes('analyticsAdvanced: "Напредна анализа"'), "MK Advanced analysis");
assert(html.includes('caNavCustomerList: "Customer list"'), "EN Customer list nav");
assert(html.includes('caNavCustomerList: "Листа на клиенти"'), "MK Customer list nav");
assert(html.includes('caNavCustomerList: "Lista e klientëve"'), "SQ Customer list nav");

assert(html.includes('analyticsOverview: "Përmbledhje"'), "SQ Overview");
assert(html.includes('analyticsTeam: "Ekipi"'), "SQ Team");
assert(html.includes('analyticsBookingValue: "Vlera e rezervimeve"'), "SQ Booking value");
assert(html.includes('analyticsViewDetails: "Shiko detajet"'), "SQ View details");
assert(html.includes('caGroupMix: "Të rinj dhe që rikthehen"'), "SQ New vs returning");
assert(html.includes('caGroupRepeat: "Vizita të përsëritura"'), "SQ Repeat behavior");
assert(html.includes('caSegReturning: "Klientë që rikthehen"'), "SQ Returning customers");
assert(html.includes('caSegLoadMore: "Shfaq më shumë"'), "SQ Load more");
assert(html.includes('analyticsQualityEstimated: "Çmime të vlerësuara"'), "SQ Estimated prices");
assert(html.includes('analyticsInsights: "Vëzhgime"'), "SQ Insights");
assert(html.includes('analyticsCompleted: "Të përfunduara"'), "SQ Completed");
assert(html.includes('xaPresetAtRisk30: "Joaktivë 30+ ditë"'), "SQ inactive 30+ days");
assert(html.includes('xaPresetAtRisk90: "Joaktivë 90+ ditë"'), "SQ inactive 90+ days");
assert(html.includes('caSegAtRisk90: "Joaktivë — 90+ ditë"'), "SQ segment inactive 90");

assert(html.includes('"Estimated prices": "Проценети цени"'), "I18N_UI MK estimated prices");
assert(html.includes('"Estimated prices": "Çmime të vlerësuara"'), "I18N_UI SQ estimated prices");
assert(html.includes('"Includes estimated prices": "Вклучува проценети цени"'), "I18N_UI MK estimated badge");
assert(html.includes('"Includes estimated prices": "Përfshin çmime të vlerësuara"'), "I18N_UI SQ estimated badge");
assert(html.includes('"Choose a valid start and end date.": "Изберете валиден почетен и краен датум."'), "I18N_MESSAGES MK date toast");
assert(html.includes('"Choose a valid start and end date.": "Zgjidhni një datë fillimi dhe mbarimi të vlefshme."'), "I18N_MESSAGES SQ date toast");

assert(html.includes("function tFormat("), "template helper exists");
assert(html.includes("renderAdminServiceAnalytics()"), "language switch refreshes Services");
assert(html.includes("renderAdminStaffAnalytics()"), "language switch refreshes Team");
assert(html.includes("renderAdminCrossAnalytics()"), "language switch refreshes Advanced analysis");

assert(!html.includes("retention"), "does not rename returning share to retention");

console.log(`PASS analytics i18n contract (${enKeys.length} analytics keys in EN/MK/SQ)`);
