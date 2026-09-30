#!/usr/bin/env node
/**
 * Analytics Data Quality human-summary contract.
 * Presentation only. Does not change formulas, SQL, or RPCs.
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

function extractFunction(src, name) {
  const start = src.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  assert(start >= 0, `extract ${name}`);
  let depth = 0;
  let started = false;
  for (let i = start; i < src.length; i += 1) {
    if (src[i] === "{") {
      depth += 1;
      started = true;
    } else if (src[i] === "}") {
      depth -= 1;
      if (started && depth === 0) return src.slice(start, i + 1);
    }
  }
  assert(false, `unclosed function ${name}`);
  return "";
}

function i18nValue(block, key) {
  const match = block.match(new RegExp(`${key}:\\s*"((?:\\\\.|[^"\\\\])*)"`));
  return match ? match[1].replace(/\\"/g, '"') : "";
}

const i18nEn = extractObjectBlock(html, "const I18N = {");
const i18nMkStart = html.indexOf("\n    mk: {", html.indexOf("const I18N = {"));
const i18nSqStart = html.indexOf("\n    sq: {", html.indexOf("const I18N = {"));
assert(i18nMkStart > 0 && i18nSqStart > i18nMkStart, "I18N mk/sq blocks exist");
const i18nMk = extractObjectBlock(html.slice(i18nMkStart), "mk: {");
const i18nSq = extractObjectBlock(html.slice(i18nSqStart), "sq: {");

const COPY_KEYS = [
  "analyticsQualityComplete",
  "analyticsQualityNotices",
  "analyticsQualityNoticesOne",
  "analyticsQualityEstimatedTitle",
  "analyticsQualityEstimatedTitleOne",
  "analyticsQualityEstimatedBody",
  "analyticsQualityEstimatedBodyOne",
  "analyticsQualityUnknownTitle",
  "analyticsQualityUnknownBody",
  "analyticsQualityInvalidTitle",
  "analyticsQualityInvalidBody",
  "analyticsQualityMissingTitle",
  "analyticsQualityMissingBody",
  "analyticsQualityUnassignedTitle",
  "analyticsQualityUnassignedTitleOne",
  "analyticsQualityUnassignedBody",
  "analyticsQualityUnassignedBodyOne",
  "analyticsQualityOrphanTitle",
  "analyticsQualityOrphanBody",
  "analyticsQualityUnidentifiedTitle",
  "analyticsQualityUnidentifiedBody",
  "analyticsQualityClearTitle",
  "analyticsQualityClearBody",
  "analyticsQualityQuietChecks",
  "analyticsQualityQuietChecksOne"
];

COPY_KEYS.forEach((key) => {
  const en = i18nValue(i18nEn, key);
  const mk = i18nValue(i18nMk, key);
  const sq = i18nValue(i18nSq, key);
  assert(!!en && !!mk && !!sq, `8 ${key} exists in EN/MK/SQ`);
  assert(mk !== en, `8 ${key} MK is translated`);
  assert(sq !== en, `8 ${key} SQ is translated`);
});

const userFacingCopy = COPY_KEYS.map((key) =>
  [i18nValue(i18nEn, key), i18nValue(i18nMk, key), i18nValue(i18nSq, key)].join("\n")
).join("\n");

const banned = [
  "staff_id",
  "booking_price",
  "catalog_price",
  "appointment_start",
  "orphan FK",
  "RPC",
  "snapshot",
  "duration_minutes",
  "analytics_customer_key"
];
banned.forEach((term) => {
  assert(!userFacingCopy.toLowerCase().includes(term.toLowerCase()), `12 user-facing copy does not include ${term}`);
});

assert(i18nValue(i18nEn, "analyticsQualityEstimatedBody").includes("current service price"), "9 estimated body uses current service price");
assert(i18nValue(i18nMk, "analyticsQualityEstimatedBody").includes("тековната цена на услугата"), "9 MK estimated body uses current service price");
assert(i18nValue(i18nSq, "analyticsQualityEstimatedBody").includes("çmimin aktual të shërbimit"), "9 SQ estimated body uses current service price");
assert(!/wrong price|estimated revenue|payment missing/i.test(userFacingCopy), "9 estimated copy is not accusatory");

assert(i18nValue(i18nEn, "analyticsQualityUnassignedTitleOne").includes("completed visit"), "10 unassigned title is completed visit");
assert(i18nValue(i18nEn, "analyticsQualityUnassignedTitleOne").includes("no assigned team member"), "10 unassigned title says no assigned team member");
assert(i18nValue(i18nMk, "analyticsQualityUnassignedTitleOne").includes("завршена посета"), "10 MK unassigned is completed visit");
assert(i18nValue(i18nMk, "analyticsQualityUnassignedTitleOne").includes("доделен член на тимот"), "10 MK unassigned is no assigned team member");
assert(i18nValue(i18nEn, "analyticsQualityUnassignedBody").includes("cannot be attributed"), "10 unassigned body explains attribution");

assert(!/inactive|неактивен|joaktiv|archived|архивиран|arkivuar/i.test(
  [
    i18nValue(i18nEn, "analyticsQualityOrphanTitle"),
    i18nValue(i18nEn, "analyticsQualityOrphanTitleOne"),
    i18nValue(i18nMk, "analyticsQualityOrphanTitle"),
    i18nValue(i18nSq, "analyticsQualityOrphanTitle")
  ].join("\n")
), "11 orphan title does not claim inactive/archived");
assert(i18nValue(i18nEn, "analyticsQualityOrphanBody").includes("not the same as a team member marked inactive"), "11 orphan body rejects active=false");
assert(i18nValue(i18nMk, "analyticsQualityOrphanBody").includes("не е исто со член означен како неактивен"), "11 MK orphan body rejects inactive");
assert(i18nValue(i18nSq, "analyticsQualityOrphanBody").includes("nuk është e njëjtë me një anëtar të shënuar si joaktiv"), "11 SQ orphan body rejects inactive");

assert(i18nValue(i18nEn, "analyticsQualityComplete") === "Data quality · All clear", "zero-state collapsed EN");
assert(i18nValue(i18nMk, "analyticsQualityComplete") === "Квалитет на податоци · Сè е во ред", "zero-state collapsed MK");
assert(i18nValue(i18nSq, "analyticsQualityComplete") === "Cilësia e të dhënave · Gjithçka në rregull", "zero-state collapsed SQ");
assert(i18nValue(i18nEn, "analyticsQualityNotices") === "Data quality · {n} notes", "notes copy is category count");
assert(i18nValue(i18nMk, "analyticsQualityNotices") === "Квалитет на податоци · {n} забелешки", "MK notes copy");
assert(i18nValue(i18nSq, "analyticsQualityNotices") === "Cilësia e të dhënave · {n} shënime", "SQ notes copy");

const I18N = { en: {}, mk: {}, sq: {} };
COPY_KEYS.concat([
  "analyticsQualityUnknownTitleOne",
  "analyticsQualityUnknownBodyOne",
  "analyticsQualityInvalidTitleOne",
  "analyticsQualityInvalidBodyOne",
  "analyticsQualityMissingTitleOne",
  "analyticsQualityMissingBodyOne",
  "analyticsQualityOrphanTitleOne",
  "analyticsQualityOrphanBodyOne",
  "analyticsQualityUnidentifiedTitleOne",
  "analyticsQualityUnidentifiedBodyOne"
]).forEach((key) => {
  I18N.en[key] = i18nValue(i18nEn, key);
  I18N.mk[key] = i18nValue(i18nMk, key);
  I18N.sq[key] = i18nValue(i18nSq, key);
});

let currentLanguage = "en";
function t(key, fallback) {
  const lang = I18N[currentLanguage] || I18N.en;
  if (lang && Object.prototype.hasOwnProperty.call(lang, key) && lang[key]) return lang[key];
  if (I18N.en && Object.prototype.hasOwnProperty.call(I18N.en, key) && I18N.en[key]) return I18N.en[key];
  return fallback !== undefined ? fallback : key;
}
function tFormat(key, fallback, vars) {
  let out = String(t(key, fallback) || "");
  if (vars && typeof vars === "object") {
    Object.keys(vars).forEach((name) => {
      out = out.split("{" + name + "}").join(String(vars[name] ?? ""));
    });
  }
  return out;
}
function escapeHtml(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
function formatPerformanceCount(value) {
  if (value == null || !Number.isFinite(Number(value))) return "—";
  return String(Math.trunc(Number(value)));
}

const fnNames = [
  "analyticsQualityCategoryDefs",
  "analyticsQualityIssueItems",
  "analyticsQualityNoticeCount",
  "analyticsQualityCollapsedLabel",
  "analyticsQualityIssueTitle",
  "buildAnalyticsQualityDetailsHtml"
];
const runtime = `${fnNames.map((name) => extractFunction(html, name)).join("\n")}\nreturn { ${fnNames.join(", ")} };`;
const helpers = new Function("t", "tFormat", "escapeHtml", "formatPerformanceCount", runtime)(
  t,
  tFormat,
  escapeHtml,
  formatPerformanceCount
);

const example = {
  estimatedPrices: 3,
  unknownPrices: 0,
  invalidTimes: 0,
  missingDurations: 0,
  unassignedVisits: 1,
  orphanStaff: 0,
  unidentifiedCustomers: 0
};
const allZero = {
  estimatedPrices: 0,
  unknownPrices: 0,
  invalidTimes: 0,
  missingDurations: 0,
  unassignedVisits: 0,
  orphanStaff: 0,
  unidentifiedCustomers: 0
};

assert(helpers.analyticsQualityCategoryDefs(example).length === 7, "seven quality categories remain");
assert(helpers.analyticsQualityNoticeCount(example) === 2, "3 issue-category count is 2, not 4");
assert(helpers.analyticsQualityCollapsedLabel(example) === "Data quality · 2 notes", "3 collapsed row uses category count");
assert(helpers.analyticsQualityNoticeCount(allZero) === 0, "5 all-zero has no notes");
assert(helpers.analyticsQualityCollapsedLabel(allZero) === "Data quality · All clear", "5 all-zero collapsed label");
assert(helpers.analyticsQualityCollapsedLabel({ estimatedPrices: 3 }) === "Data quality · 1 note", "singular note label");

const exampleHtml = helpers.buildAnalyticsQualityDetailsHtml(example);
assert(exampleHtml.includes("3 bookings use an estimated price"), "4 estimated count is in the title");
assert(exampleHtml.includes("1 completed visit has no assigned team member"), "4 unassigned count is in the title");
assert(exampleHtml.includes("analytics-quality-issue") && exampleHtml.match(/data-quality-issue="/g)?.length === 2, "2 only non-zero categories render");
assert(!exampleHtml.includes("data-quality-issue=\"unknown\""), "1 zero unknown is not an issue row");
assert(!exampleHtml.includes("data-quality-issue=\"invalidTimes\""), "1 zero invalid is not an issue row");
assert(!exampleHtml.includes("data-quality-issue=\"missingDurations\""), "1 zero missing duration is not an issue row");
assert(!exampleHtml.includes("data-quality-issue=\"orphanStaff\""), "1 zero orphan is not an issue row");
assert(!exampleHtml.includes("data-quality-issue=\"unidentified\""), "1 zero unidentified is not an issue row");
assert(exampleHtml.includes("5 checks with no notes ✓"), "quiet remaining-checks line");
assert(exampleHtml.includes("<button") && exampleHtml.includes("onclick=\"openAnalyticsQualityIssue('estimated')\""), "non-zero issues are actionable");
assert(exampleHtml.includes("analytics-quality-issue__chevron"), "non-zero issues expose a disclosure chevron");
assert(!exampleHtml.includes("analytics-quality-list__row"), "old diagnostic rows are gone");

const zeroHtml = helpers.buildAnalyticsQualityDetailsHtml(allZero);
assert(zeroHtml.includes("analytics-quality-clear"), "5 all-zero renders clean status");
assert(zeroHtml.includes("No data quality notes."), "5 all-zero title");
assert(!zeroHtml.includes("analytics-quality-issue"), "5 all-zero has no issue rows");
assert(!zeroHtml.includes("0 booking"), "5 all-zero does not list zeros");

currentLanguage = "mk";
assert(helpers.analyticsQualityCollapsedLabel(example) === "Квалитет на податоци · 2 забелешки", "MK collapsed uses 2 notes");
const mkHtml = helpers.buildAnalyticsQualityDetailsHtml(example);
assert(mkHtml.includes("3 резервации користат проценета цена"), "MK estimated title");
assert(mkHtml.includes("тековната цена на услугата"), "MK estimated explanation");
assert(mkHtml.includes("1 завршена посета нема доделен член на тимот"), "MK unassigned title");
assert(mkHtml.includes("не може да се припише на конкретен член на тимот"), "MK unassigned explanation");

currentLanguage = "sq";
assert(helpers.analyticsQualityCollapsedLabel(example) === "Cilësia e të dhënave · 2 shënime", "SQ collapsed uses 2 notes");
const sqHtml = helpers.buildAnalyticsQualityDetailsHtml(example);
assert(sqHtml.includes("3 rezervime përdorin një çmim të vlerësuar"), "SQ estimated title");
assert(sqHtml.includes("çmimin aktual të shërbimit"), "SQ estimated explanation");
assert(sqHtml.includes("1 vizitë e përfunduar nuk ka anëtar të caktuar të ekipit"), "SQ unassigned title");

assert(html.includes(".analytics-quality-issue"), "quality issue styles exist");
assert(html.includes("var(--theme-warning-bg)") && html.includes(".analytics-quality-issue__icon"), "13 warning icon uses semantic tokens");
assert(html.includes("button.analytics-quality-issue") && html.includes("display: flex;"), "issue block CSS exists");
const issueCssStart = html.indexOf("button.analytics-quality-issue {");
const issueCss = html.slice(issueCssStart, html.indexOf("}", issueCssStart) + 1);
assert(issueCss.includes("var(--theme-surface-primary)"), "13 issue surface uses semantic token");
assert(issueCss.includes("var(--theme-border-default)"), "13 issue border uses semantic token");
assert(!issueCss.includes("#fff") && !issueCss.includes("#000"), "13 issue CSS has no hardcoded black/white");

assert(html.includes("get_business_analytics_quality_records"), "quality records RPC is used for exact drill-down");
assert(!html.includes("from(\"bookings_api\")") || html.includes("function loadBookingsFull"), "does not add quality recount from bookings_api");

const sheet = html.slice(html.indexOf('id="analyticsQualitySheet"'), html.indexOf('id="adminSectionCustomerAnalytics"'));
assert(sheet.includes('id="analyticsQualityList"'), "quality list mount remains");
assert(!sheet.includes("analyticsQualityFootnote"), "technical footnote removed from sheet");

const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
assert(inlineScripts.length >= 1, "14 inline JS extracted");
const checkFile = path.join(root, "scripts", ".tmp-analytics-quality-syntax-check.js");
fs.writeFileSync(checkFile, inlineScripts.join("\n;\n"));
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
assert(checked.status === 0, "14 node --check inline JS" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout)));
try {
  fs.unlinkSync(checkFile);
} catch {
  /* keep on failure */
}

console.log("PASS analytics quality human-summary contract");
