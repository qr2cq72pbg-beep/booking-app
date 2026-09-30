#!/usr/bin/env node
/**
 * Analytics Data Quality exact-record drill-down contract.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const sql = fs.readFileSync(path.join(root, "supabase-get-business-analytics-quality-records.sql"), "utf8");

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
  "analyticsQualityDetailEstimated",
  "analyticsQualityDetailUnknown",
  "analyticsQualityDetailInvalid",
  "analyticsQualityDetailMissing",
  "analyticsQualityDetailUnassigned",
  "analyticsQualityDetailOrphan",
  "analyticsQualityDetailUnidentified",
  "analyticsQualityReasonEstimated",
  "analyticsQualityReasonEstimatedHint",
  "analyticsQualityReasonUnknown",
  "analyticsQualityReasonInvalid",
  "analyticsQualityReasonMissing",
  "analyticsQualityReasonUnassigned",
  "analyticsQualityReasonOrphan",
  "analyticsQualityReasonUnidentified",
  "analyticsQualityPriceEstimated",
  "analyticsQualityDetailLoading",
  "analyticsQualityDetailEmpty",
  "analyticsQualityDetailMismatch",
  "analyticsQualityDetailError",
  "analyticsQualityDetailReconcile",
  "analyticsQualityOrphanBookings",
  "analyticsQualityOrphanBookingsOne",
  "analyticsFallbackStaff",
  "commonBack"
];

COPY_KEYS.forEach((key) => {
  const en = i18nValue(i18nEn, key);
  const mk = i18nValue(i18nMk, key);
  const sq = i18nValue(i18nSq, key);
  assert(!!en && !!mk && !!sq, `${key} exists in EN/MK/SQ`);
  assert(mk !== en, `${key} MK is translated`);
  assert(sq !== en, `${key} SQ is translated`);
});

assert(i18nValue(i18nMk, "analyticsQualityDetailEstimated") === "Резервации со проценета цена", "MK estimated detail title");
assert(i18nValue(i18nMk, "analyticsQualityReasonEstimated").includes("не е зачувана"), "MK estimated reason");
assert(i18nValue(i18nMk, "analyticsQualityReasonUnassigned").includes("Нема доделен член на тимот"), "MK unassigned reason");
assert(i18nValue(i18nEn, "commonBack") === "Back", "EN Back");
assert(i18nValue(i18nMk, "commonBack") === "Назад", "MK Back");
assert(i18nValue(i18nSq, "commonBack") === "Kthehu", "SQ Back");

const userFacing = COPY_KEYS.map((key) =>
  [i18nValue(i18nEn, key), i18nValue(i18nMk, key), i18nValue(i18nSq, key)].join("\n")
).join("\n");
["staff_id", "booking_price", "manage_token", "RPC", "snapshot"].forEach((term) => {
  assert(!userFacing.toLowerCase().includes(term.toLowerCase()), `copy omits ${term}`);
});

assert(sql.includes("CREATE OR REPLACE FUNCTION public.get_business_analytics_quality_records("), "RPC exists");
assert(sql.includes("p_quality_type text"), "RPC accepts quality type");
assert(sql.includes("GRANT EXECUTE ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) TO authenticated;"), "authenticated execute");
assert(sql.includes("REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) FROM PUBLIC;"), "no public execute");
assert(sql.includes("REVOKE ALL ON FUNCTION public.get_business_analytics_quality_records(uuid, date, date, text) FROM anon, service_role;"), "no anon execute");
assert(!sql.includes("GRANT SELECT ON public.bookings"), "does not grant bookings select");
assert(!/select[\s\S]{0,80}manage_token|b\.manage_token/i.test(sql), "SQL body does not select manage_token");
assert(sql.includes("auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_business_id"), "owner auth matches Analytics RPCs");
assert(sql.includes("'estimated'") && sql.includes("'unassigned'") && sql.includes("'orphan_staff'"), "supported quality types");
assert(sql.includes("price_source = 'estimated'"), "estimated predicate uses price_source");
assert(sql.includes("is_unassigned") && sql.includes("is_completed_visit"), "unassigned uses completed + staff_id null");
assert(sql.includes("count_semantic") && sql.includes("'staff_ids'"), "orphan preserves distinct staff semantic");

const I18N = { en: {}, mk: {}, sq: {} };
COPY_KEYS.concat([
  "analyticsQualityEstimatedTitle",
  "analyticsQualityEstimatedTitleOne",
  "analyticsQualityEstimatedBody",
  "analyticsQualityEstimatedBodyOne",
  "analyticsQualityUnknownTitle",
  "analyticsQualityUnknownTitleOne",
  "analyticsQualityUnknownBody",
  "analyticsQualityUnknownBodyOne",
  "analyticsQualityInvalidTitle",
  "analyticsQualityInvalidTitleOne",
  "analyticsQualityInvalidBody",
  "analyticsQualityInvalidBodyOne",
  "analyticsQualityMissingTitle",
  "analyticsQualityMissingTitleOne",
  "analyticsQualityMissingBody",
  "analyticsQualityMissingBodyOne",
  "analyticsQualityUnassignedTitle",
  "analyticsQualityUnassignedTitleOne",
  "analyticsQualityUnassignedBody",
  "analyticsQualityUnassignedBodyOne",
  "analyticsQualityOrphanTitle",
  "analyticsQualityOrphanTitleOne",
  "analyticsQualityOrphanBody",
  "analyticsQualityOrphanBodyOne",
  "analyticsQualityUnidentifiedTitle",
  "analyticsQualityUnidentifiedTitleOne",
  "analyticsQualityUnidentifiedBody",
  "analyticsQualityUnidentifiedBodyOne",
  "analyticsQualityClearTitle",
  "analyticsQualityClearBody",
  "analyticsQualityQuietChecks",
  "analyticsQualityQuietChecksOne",
  "analyticsFallbackCustomer",
  "analyticsUnknownService"
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
function formatBusinessMoney(amount) {
  if (amount == null || !Number.isFinite(Number(amount))) return "—";
  return `${Math.trunc(Number(amount))} CUR`;
}
function formatAppLocaleDate() {
  return "12 Sep";
}
function getAppUiLocale() {
  return "en";
}

const fnNames = [
  "analyticsQualityCategoryDefs",
  "analyticsQualityIssueItems",
  "analyticsQualityNoticeCount",
  "analyticsQualityCollapsedLabel",
  "analyticsQualityIssueTitle",
  "analyticsQualityExactRecordsBlocked",
  "analyticsQualityCacheKey",
  "buildAnalyticsQualityDetailsHtml",
  "analyticsQualityRecordBadgeLabel",
  "buildAnalyticsQualityRecordHtml",
  "buildAnalyticsQualityDetailIntroHtml",
  "buildAnalyticsQualityDetailListHtml",
  "formatAnalyticsQualityTime",
  "formatAnalyticsQualityDateTime"
];
const runtime = `${fnNames.map((name) => extractFunction(html, name)).join("\n")}\nreturn { ${fnNames.join(", ")} };`;
const helpers = new Function(
  "t",
  "tFormat",
  "escapeHtml",
  "formatPerformanceCount",
  "formatBusinessMoney",
  "formatAppLocaleDate",
  "getAppUiLocale",
  "analyticsQualityMergedPerformance",
  runtime
)(t, tFormat, escapeHtml, formatPerformanceCount, formatBusinessMoney, formatAppLocaleDate, getAppUiLocale, false);

const example = {
  estimatedPrices: 3,
  unknownPrices: 0,
  invalidTimes: 0,
  missingDurations: 0,
  unassignedVisits: 1,
  orphanStaff: 0,
  unidentifiedCustomers: 0
};

const defs = helpers.analyticsQualityCategoryDefs(example);
assert(defs.find((row) => row.id === "estimated")?.rpcType === "estimated", "estimated rpc type");
assert(defs.find((row) => row.id === "unassigned")?.rpcType === "unassigned", "unassigned rpc type");
assert(defs.find((row) => row.id === "orphanStaff")?.countSemantic === "staff_ids", "orphan count semantic");
assert(defs.find((row) => row.id === "estimated")?.mergedSensitive === true, "estimated is merge-sensitive");
assert(defs.find((row) => row.id === "unassigned")?.mergedSensitive === false, "unassigned is not merge-sensitive");

const htmlSummary = helpers.buildAnalyticsQualityDetailsHtml(example);
assert(htmlSummary.includes('type="button"'), "zero-count rows stay non-actions; non-zero are buttons");
assert(htmlSummary.includes("openAnalyticsQualityIssue('estimated')"), "estimated opens exact detail");
assert(htmlSummary.includes("openAnalyticsQualityIssue('unassigned')"), "unassigned opens exact detail");
assert(!htmlSummary.includes("openAnalyticsQualityIssue('unknown')"), "zero unknown cannot open");
assert(htmlSummary.includes("analytics-quality-issue__chevron"), "chevron affordance");

assert(helpers.analyticsQualityExactRecordsBlocked(defs.find((row) => row.id === "estimated"), true), "merged YTD blocks estimated");
assert(!helpers.analyticsQualityExactRecordsBlocked(defs.find((row) => row.id === "unassigned"), true), "merged YTD does not block unassigned");
assert(!helpers.analyticsQualityExactRecordsBlocked(defs.find((row) => row.id === "estimated"), false), "unmerged estimated can open");

assert(
  helpers.analyticsQualityCacheKey("estimated", "biz|2026-09-01|2026-09-30|this_month|single") !==
    helpers.analyticsQualityCacheKey("estimated", "biz|2026-08-01|2026-08-31|last_month|single"),
  "period change uses a different cache key"
);
assert(
  helpers.analyticsQualityCacheKey("estimated", "scope-a") !== helpers.analyticsQualityCacheKey("unassigned", "scope-a"),
  "quality type is part of cache key"
);

const estimatedRow = helpers.buildAnalyticsQualityRecordHtml({
  customer_name: "Daniela Januseva",
  service_name: "Масажа",
  appointment_date: "2026-09-12",
  appointment_time: "14:30",
  staff_name: "Stefan",
  price: 500,
  price_source: "estimated"
}, defs.find((row) => row.id === "estimated"));
assert(estimatedRow.includes("Daniela Januseva"), "estimated row keeps customer name");
assert(estimatedRow.includes("Масажа"), "estimated row keeps service name");
assert(estimatedRow.includes("12 Sep · 14:30"), "estimated row shows date/time");
assert(estimatedRow.includes("Stefan"), "estimated row shows staff");
assert(estimatedRow.includes("500 CUR"), "estimated row uses currency formatter");
assert(!estimatedRow.includes("MKD"), "does not hardcode MKD");
assert(estimatedRow.includes("analytics-quality-record__badge") && estimatedRow.includes("estimated price"), "estimated price is a badge");
assert(!estimatedRow.includes("500 CUR ·"), "price is not concatenated with status text");
assert(!estimatedRow.includes("The original booking price is not saved."), "record does not repeat the list explanation");
assert(!estimatedRow.includes("Analytics uses the current service price."), "record does not repeat the list hint");

const missingStaffRow = helpers.buildAnalyticsQualityRecordHtml({
  customer_name: "Daniela Januseva",
  service_name: "Sisanje",
  appointment_date: "2026-09-24",
  appointment_time: "08:45",
  staff_name: "",
  price: 300,
  price_source: "estimated"
}, defs.find((row) => row.id === "estimated"));
assert(missingStaffRow.includes("No team member is assigned."), "missing staff uses localized wording");
assert(!missingStaffRow.includes("staff_id"), "missing staff does not expose staff_id");
assert(missingStaffRow.includes("estimated price"), "estimated badge remains when staff is missing");

const unassignedRow = helpers.buildAnalyticsQualityRecordHtml({
  customer_name: "Ana",
  service_name: "Haircut",
  appointment_date: "2026-09-12",
  appointment_time: "11:00",
  staff_name: "",
  price: 200,
  price_source: "snapshot"
}, defs.find((row) => row.id === "unassigned"));
assert(unassignedRow.includes("Ana"), "unassigned customer");
assert(unassignedRow.includes("No team member is assigned."), "unassigned reason");
assert(!unassignedRow.includes("inactive"), "unassigned does not mention inactive");

const listHtml = helpers.buildAnalyticsQualityDetailListHtml(defs.find((row) => row.id === "estimated"), [
  { customer_name: "Daniela Januseva", service_name: "Sisanje", appointment_date: "2026-09-25", appointment_time: "08:00", staff_name: "Stefan", price: 300, price_source: "estimated" },
  { customer_name: "Daniela Januseva", service_name: "Sisanje", appointment_date: "2026-09-24", appointment_time: "08:45", staff_name: "", price: 300, price_source: "estimated" },
  { customer_name: "Daniela Januseva", service_name: "Masaza", appointment_date: "2026-09-01", appointment_time: "08:15", staff_name: "Stefan", price: 500, price_source: "estimated" }
]);
assert((listHtml.match(/analytics-quality-detail__intro"/g) || []).length === 1, "explanation appears once");
assert((listHtml.match(/These bookings have no saved original price/g) || []).length === 1, "list explanation is not repeated per record");
assert((listHtml.match(/analytics-quality-record"/g) || []).length === 3, "three compact records render");

currentLanguage = "mk";
const mkRecord = helpers.buildAnalyticsQualityRecordHtml({
  customer_name: "Daniela Januseva",
  service_name: "Масажа",
  appointment_date: "2026-09-12",
  appointment_time: "14:30",
  staff_name: "Stefan",
  price: 500,
  price_source: "estimated"
}, helpers.analyticsQualityCategoryDefs(example).find((row) => row.id === "estimated"));
assert(mkRecord.includes("проценета цена"), "MK estimated price label");
assert(!mkRecord.includes("Оригиналната цена на резервацијата не е зачувана."), "MK record does not repeat explanation");
assert(mkRecord.includes("Daniela Januseva") && mkRecord.includes("Масажа") && mkRecord.includes("Stefan"), "does not translate user-entered names");
const mkList = helpers.buildAnalyticsQualityDetailListHtml(
  helpers.analyticsQualityCategoryDefs(example).find((row) => row.id === "estimated"),
  [{ customer_name: "Daniela Januseva", service_name: "Масажа", appointment_date: "2026-09-12", appointment_time: "14:30", staff_name: "Stefan", price: 500, price_source: "estimated" }]
);
assert(mkList.includes("тековната цена на услугата"), "MK list explanation uses existing copy");

const overviewFn = extractFunction(html, "loadAnalyticsOverviewSupportingData");
const summaryFn = extractFunction(html, "renderAnalyticsQualitySummary");
const fetchFn = extractFunction(html, "fetchAnalyticsQualityRecords");
const openFn = extractFunction(html, "openAnalyticsQualityIssue");
assert(!overviewFn.includes("get_business_analytics_quality_records"), "overview load does not fetch detail records");
assert(!summaryFn.includes("get_business_analytics_quality_records"), "summary render does not fetch detail records");
assert(fetchFn.includes("get_business_analytics_quality_records"), "detail fetch uses dedicated RPC");
assert(openFn.includes("fetchAnalyticsQualityRecords") && openFn.includes("row.count <= 0"), "tap fetches; zero cannot open");
assert(openFn.includes("analyticsQualityExactRecordsBlocked"), "merged scope stops instead of inventing records");

const sheet = html.slice(html.indexOf('id="analyticsQualitySheet"'), html.indexOf('id="adminSectionCustomerAnalytics"'));
assert(sheet.includes("analyticsQualityBackBtn"), "detail has Back");
assert(sheet.includes("analytics-sheet__back-icon"), "Back uses the canonical icon treatment");
assert(!sheet.includes('data-i18n="commonBack">Back'), "Back is not a large standalone text label");
assert(sheet.includes("closeAnalyticsQualityDetail()"), "Back returns to summary");
assert(sheet.includes("closeAnalyticsQualitySheet()"), "X closes quality sheet");
assert(sheet.includes("analyticsQualityDetail"), "internal detail mount");
assert(html.includes("analytics-sheet__body") && html.includes("--admin-tabbar-height"), "sheet accounts for tab bar");
assert(html.includes("-webkit-overflow-scrolling: touch"), "iOS momentum scrolling");

const firstSheet = html.indexOf(".analytics-sheet {");
const laterSheet = html.lastIndexOf(".analytics-sheet {");
assert(firstSheet >= 0 && laterSheet > firstSheet, "sheet padding is defined");
const laterCss = html.slice(laterSheet, laterSheet + 400);
assert(laterCss.includes("--admin-tabbar-height") && laterCss.includes("safe-area-inset-bottom"), "later sheet pad uses tab bar + safe area");

const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
const checkFile = path.join(root, "scripts", ".tmp-analytics-quality-records-syntax-check.js");
fs.writeFileSync(checkFile, inlineScripts.join("\n;\n"));
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
assert(checked.status === 0, "node --check inline JS" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout)));
try {
  fs.unlinkSync(checkFile);
} catch {
  /* keep on failure */
}

console.log("PASS analytics quality exact-record drill-down contract");
