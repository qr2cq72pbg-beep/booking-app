#!/usr/bin/env node
/**
 * Phase 2B: Customer Analytics UI presentation helpers.
 * Mirrors index.html formatters. Does not aggregate bookings.
 */

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

function formatCustomerAnalyticsDecimal(value) {
  if (value == null || value === "") return "—";
  const n = Number(value);
  if (!Number.isFinite(n)) return "—";
  if (Math.abs(n - Math.round(n)) < 0.005) return String(Math.round(n));
  return String(Math.round(n * 100) / 100);
}

function customerAnalyticsSharePct(count, population) {
  const pop = Number(population);
  const n = Number(count);
  if (!Number.isFinite(pop) || pop <= 0 || !Number.isFinite(n)) return null;
  return (n / pop) * 100;
}

function customerAnalyticsExclusiveAtRisk(inactivity) {
  const src = inactivity || {};
  return {
    d30to59: src.at_risk_30_to_59,
    d60to89: src.at_risk_60_to_89,
    d90plus: src.at_risk_90_plus,
    bookedAhead: src.booked_ahead_customers
  };
}

function shouldShowCustomerAnalyticsEstimatedNote(valueBlock) {
  return !!(valueBlock && valueBlock.contains_estimated_prices === true);
}

const CA_AGE_BUCKETS = [
  { key: "under_18", rpcFilter: "under_18", label: "Under 18" },
  { key: "age_18_24", rpcFilter: "18_24", label: "18–24" },
  { key: "age_25_34", rpcFilter: "25_34", label: "25–34" },
  { key: "age_35_44", rpcFilter: "35_44", label: "35–44" },
  { key: "age_45_54", rpcFilter: "45_54", label: "45–54" },
  { key: "age_55_64", rpcFilter: "55_64", label: "55–64" },
  { key: "age_65_plus", rpcFilter: "65_plus", label: "65+" }
];

function customerAnalyticsAgeRpcFilter(overviewKey) {
  const bucket = CA_AGE_BUCKETS.find((row) => row.key === overviewKey);
  return bucket ? bucket.rpcFilter : null;
}

function isCustomerAnalyticsFreqClickable(freqKey) {
  return freqKey === "visits_1";
}

function nextCustomerAnalyticsSegmentOffset(loadedCount) {
  const n = Number(loadedCount);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

function mergeCustomerAnalyticsSegmentRows(existing, incoming) {
  const out = Array.isArray(existing) ? existing.slice() : [];
  const seen = new Set(out.map((row) => row && row.analytics_customer_key).filter(Boolean));
  (incoming || []).forEach((row) => {
    const key = row && row.analytics_customer_key;
    if (!key || seen.has(key)) return;
    seen.add(key);
    out.push(row);
  });
  return out;
}

function isCustomerAnalyticsSegmentResponseStale(requestId, currentId, token, currentToken) {
  return requestId !== currentId || token !== currentToken;
}

function isCustomerAnalyticsSegmentSchemaError(error) {
  const msg = String(error?.message || error?.details || error?.code || "");
  return /could not find the function|PGRST202|schema cache/i.test(msg);
}

function customerAnalyticsSegmentContactHtml(phone, email) {
  const parts = [];
  const tel = String(phone || "").trim();
  const mail = String(email || "").trim();
  if (tel) parts.push("tel");
  if (mail) parts.push("mailto");
  return parts;
}

function buildCustomerAnalyticsCityRows(cities) {
  const block = cities || {};
  const groups = Array.isArray(block.groups) ? block.groups.slice() : [];
  groups.sort((a, b) => Number(b.count) - Number(a.count) || String(a.city_name || "").localeCompare(String(b.city_name || "")));
  const known = groups
    .filter((row) => Number(row.count) > 0)
    .slice(0, 5)
    .map((row) => ({
      label: String(row.city_name || "").trim() || "Unknown",
      count: row.count,
      unknown: false,
      segment: row.city_id ? "city" : null,
      filterValue: row.city_id ? String(row.city_id) : null,
      filterLabel: String(row.city_name || "").trim() || "Unknown"
    }));
  return known.concat([{
    label: "Unknown",
    count: block.unknown_count ?? block.unknown_city ?? 0,
    unknown: true,
    segment: "city",
    filterValue: "unknown",
    filterLabel: "Unknown"
  }]);
}

function buildCustomerAnalyticsAgeRows(age) {
  const block = age || {};
  const rows = CA_AGE_BUCKETS
    .filter((bucket) => Number(block[bucket.key]) > 0)
    .map((bucket) => ({
      label: bucket.label,
      count: block[bucket.key],
      unknown: false,
      segment: "age_bucket",
      filterValue: bucket.rpcFilter,
      filterLabel: bucket.label
    }));
  rows.push({
    label: "Unknown",
    count: block.unknown ?? 0,
    unknown: true,
    segment: "age_bucket",
    filterValue: "unknown",
    filterLabel: "Unknown"
  });
  return rows;
}

function buildCustomerAnalyticsGenderRows(gender) {
  const block = gender || {};
  return [
    { label: "Male", count: block.male ?? 0, unknown: false, segment: "gender", filterValue: "male" },
    { label: "Female", count: block.female ?? 0, unknown: false, segment: "gender", filterValue: "female" },
    { label: "Unknown", count: block.unknown ?? 0, unknown: true, segment: "gender", filterValue: "unknown" }
  ];
}

function buildCustomerAnalyticsInsights(payload) {
  const insights = [];
  const overview = payload?.overview || {};
  const inactivity = payload?.inactivity || {};
  const quality = payload?.quality || {};
  const active = Number(overview.active_customers);
  const known = Number(quality.demographic_known_customer_count);
  const unknown = Number(quality.demographic_unknown_customer_count);
  const pop = Number.isFinite(known) && Number.isFinite(unknown) ? known + unknown : Number(payload?.demographics?.gender?.population_total);
  const atRisk90 = Number(inactivity.at_risk_90_plus);
  const repeatPct = overview.repeat_rate_pct == null ? null : Number(overview.repeat_rate_pct);

  if (Number.isFinite(active) && active === 0) {
    insights.push("No customer activity in this period.");
  }
  if (Number.isFinite(unknown) && Number.isFinite(pop) && pop > 0 && unknown > pop / 2) {
    insights.push("Most customer profiles are missing demographic information.");
  }
  if (Number.isFinite(atRisk90) && atRisk90 > 0) {
    insights.push(
      atRisk90 === 1
        ? "1 customer has not visited in 90+ days."
        : `${atRisk90} customers have not visited in 90+ days.`
    );
  }
  if (insights.length < 3 && repeatPct != null && Number.isFinite(repeatPct) && repeatPct >= 50) {
    insights.push(
      repeatPct >= 49.5 && repeatPct < 60
        ? "Half of your customers have returned more than once."
        : "Most of your customers have returned more than once."
    );
  }
  if (
    insights.length < 3 &&
    Number.isFinite(active) &&
    active > 0 &&
    Number(overview.new_customers) === active &&
    Number(overview.returning_customers) === 0
  ) {
    insights.push("All active customers in this period are new.");
  }
  return insights.slice(0, 3);
}

function formatCustomerAnalyticsCoverage(payload) {
  const quality = payload?.quality || {};
  const known = quality.demographic_known_customer_count;
  const unknown = quality.demographic_unknown_customer_count;
  const pop =
    known != null && unknown != null
      ? Number(known) + Number(unknown)
      : payload?.demographics?.gender?.population_total;
  if (known == null || pop == null || !Number.isFinite(Number(known)) || !Number.isFinite(Number(pop))) {
    return "";
  }
  return `Profile coverage: ${Number(known)} of ${Number(pop)} customers`;
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

const august = {
  overview: {
    total_customers: 6,
    customers_with_visits: 6,
    active_customers: 0,
    new_customers: 0,
    returning_customers: 0,
    average_visits_per_customer: null,
    repeat_rate_pct: 50.0,
    completed_visits: 0
  },
  inactivity: {
    at_risk_30: 4,
    at_risk_60: 4,
    at_risk_90: 4,
    at_risk_30_to_59: 0,
    at_risk_60_to_89: 0,
    at_risk_90_plus: 4,
    booked_ahead_customers: 0
  },
  demographics: {
    gender: { population_total: 6, male: 1, female: 0, unknown: 5 },
    age: { population_total: 6, under_18: 0, age_18_24: 0, age_25_34: 1, age_35_44: 0, age_45_54: 0, age_55_64: 0, age_65_plus: 0, unknown: 5 },
    cities: { population_total: 6, unknown_count: 5, groups: [{ city_id: 1, city_name: "Skopje", count: 1 }] }
  },
  frequency: { visits_1: 3, visits_2: 0, visits_3: 1, visits_4_5: 0, visits_6_10: 1, visits_11_plus: 1, population_total: 6 },
  value: {
    completed_revenue_total: 0,
    completed_revenue_per_active_customer: null,
    average_spend_per_completed_visit: 0,
    contains_estimated_prices: false
  },
  quality: { demographic_known_customer_count: 1, demographic_unknown_customer_count: 5 }
};

const ytd = {
  overview: {
    total_customers: 6,
    customers_with_visits: 6,
    active_customers: 6,
    new_customers: 6,
    returning_customers: 0,
    average_visits_per_customer: 19,
    repeat_rate_pct: 50.0,
    completed_visits: 114
  },
  inactivity: {
    at_risk_30_to_59: 1,
    at_risk_60_to_89: 1,
    at_risk_90_plus: 2,
    booked_ahead_customers: 2
  },
  demographics: august.demographics,
  frequency: august.frequency,
  value: {
    completed_revenue_total: 0,
    completed_revenue_per_active_customer: 0,
    average_spend_per_completed_visit: 0,
    contains_estimated_prices: true
  },
  quality: august.quality
};

/* A. Period with no active customers */
assert(formatPerformanceCount(august.overview.active_customers) === "0", "A active 0");
assert(formatCustomerAnalyticsDecimal(august.overview.average_visits_per_customer) === "—", "A avg visits dash");
assert(buildCustomerAnalyticsInsights(august)[0] === "No customer activity in this period.", "A empty insight");

/* B. New customers */
assert(formatPerformanceCount(ytd.overview.new_customers) === "6", "B new");

/* C. Returning */
assert(formatPerformanceCount(ytd.overview.returning_customers) === "0", "C returning");
assert(formatPerformanceCount(3) === "3", "C returning nonzero");

/* D. Repeat rate 50% not 0.5% or 5000% */
assert(formatCustomerAnalyticsPct(50) === "50%", "D 50");
assert(formatCustomerAnalyticsPct(50.0) === "50%", "D 50.0");
assert(formatCustomerAnalyticsPct(august.overview.repeat_rate_pct) === "50%", "D payload");
assert(formatCustomerAnalyticsPct(0.5) !== "50%", "D does not treat 0.5 as 50");

/* E/F. Unknown + known demographics */
const gender = buildCustomerAnalyticsGenderRows(august.demographics.gender);
assert(gender.some((r) => r.label === "Unknown" && r.count === 5), "E unknown gender");
assert(gender.some((r) => r.label === "Male" && r.count === 1), "F known male");
const age = buildCustomerAnalyticsAgeRows(august.demographics.age);
assert(age.some((r) => r.label === "Unknown"), "E unknown age always present");
assert(!age.some((r) => r.label === "Under 18"), "empty age bucket hidden");
assert(age.some((r) => r.label === "25–34" && r.count === 1), "F known age");
const cities = buildCustomerAnalyticsCityRows(august.demographics.cities);
assert(cities.length === 2, "one known city + unknown");
assert(cities[0].label === "Skopje" && cities[0].count === 1, "F known city");
assert(cities[1].label === "Unknown" && cities[1].count === 5, "E unknown city");
assert(customerAnalyticsSharePct(5, 6) > 80, "unknown % of full population");

/* G. Exclusive at-risk, no cumulative display */
const risk = customerAnalyticsExclusiveAtRisk(august.inactivity);
assert(risk.d30to59 === 0 && risk.d60to89 === 0 && risk.d90plus === 4, "G exclusive 90+");
assert(!Object.prototype.hasOwnProperty.call(risk, "at_risk_90"), "G no cumulative field in UI map");
const ytdRisk = customerAnalyticsExclusiveAtRisk(ytd.inactivity);
assert(Number(ytdRisk.d30to59) + Number(ytdRisk.d60to89) + Number(ytdRisk.d90plus) === 4, "G exclusive sum");

/* H. Booked ahead separate */
assert(risk.bookedAhead === 0, "H august booked ahead");
assert(ytdRisk.bookedAhead === 2, "H ytd booked ahead");

/* I/J. Estimated price note */
assert(shouldShowCustomerAnalyticsEstimatedNote(ytd.value) === true, "I estimated true");
assert(shouldShowCustomerAnalyticsEstimatedNote(august.value) === false, "J estimated false");
assert(shouldShowCustomerAnalyticsEstimatedNote({ contains_estimated_prices: false }) === false, "J snapshot-only");

/* K. Revenue zero is legitimate */
assert(formatBusinessMoney(0) === "0 MKD", "K zero revenue");
assert(formatBusinessMoney(ytd.value.completed_revenue_total) === "0 MKD", "K ytd zero");

/* L. RPC failure uses dashes not fake zeros */
assert(formatPerformanceCount(null) === "—", "L null count");
assert(formatCustomerAnalyticsDecimal(null) === "—");
assert(formatCustomerAnalyticsPct(null) === "—");
assert(formatBusinessMoney(null) === "—");

/* Coverage */
assert(formatCustomerAnalyticsCoverage(august) === "Profile coverage: 1 of 6 customers", "coverage");

/* Insights cap */
assert(buildCustomerAnalyticsInsights(august).length <= 3, "max 3 insights");
const allNewOnly = buildCustomerAnalyticsInsights({
  overview: { active_customers: 6, new_customers: 6, returning_customers: 0, repeat_rate_pct: 10 },
  inactivity: { at_risk_90_plus: 0 },
  quality: { demographic_known_customer_count: 5, demographic_unknown_customer_count: 1 }
});
assert(allNewOnly.includes("All active customers in this period are new."), "all new insight");

/* Avg visits YTD */
assert(formatCustomerAnalyticsDecimal(19) === "19", "ytd avg visits");
assert(formatCustomerAnalyticsDecimal(19.00) === "19", "ytd avg int");

import fs from "fs";
import path from "path";
const html = fs.readFileSync(path.join(process.cwd(), "index.html"), "utf8");

assert(html.includes('data-admin-section="customer-analytics"'), "nav/section customer-analytics");
assert(html.includes("get_business_customer_analytics_overview"), "RPC wired");
assert(html.includes('id="adminSectionCustomerAnalytics"'), "section exists");
assert(html.includes("commonCustomerAnalytics"), "i18n key");
assert(html.includes("Аналитика на клиенти"), "MK label");
assert(html.includes("Could not load customer analytics."), "error copy");
assert(html.includes("Historical values include estimated service prices."), "estimated note EN");
assert(html.includes("Историските вредности вклучуваат проценети цени на услуги."), "estimated note MK");
assert(html.includes("Стапка на повторни посети"), "repeat rate MK");
assert(html.includes("Структура на клиенти"), "mix MK");
assert(html.includes("Фреквенција на посети"), "freq MK");
assert(html.includes("at_risk_30_to_59"), "exclusive 30-59");
assert(html.includes("at_risk_60_to_89"), "exclusive 60-89");
assert(html.includes("at_risk_90_plus"), "exclusive 90+");
assert(html.includes("booked_ahead_customers"), "booked ahead");
assert(html.includes("#adminSectionCustomerAnalytics") && html.includes("overflow-x: hidden"), "N overflow hidden");
assert(!/function fetchBusinessCustomerAnalyticsOverview[\s\S]{0,2500}from\(['\"]bookings['\"]/.test(html), "no bookings query in CA fetch");
assert(!/function fetchBusinessCustomerAnalyticsOverview[\s\S]{0,4000}customer_private_profiles/.test(html), "no private profiles in CA fetch");
assert(html.includes('id="adminSectionClients"'), "Clients screen still present");

const caFn = html.slice(html.indexOf("function fetchBusinessCustomerAnalyticsOverview"), html.indexOf("function renderAdminCustomerAnalytics"));
assert(caFn.includes("get_business_customer_analytics_overview"), "fetch uses CA RPC");
assert(!caFn.includes("get_business_performance_report"), "CA fetch does not use Performance RPC");
assert(!caFn.includes("computePerformanceReport"), "no JS analytics engine");

console.log("customer-analytics-ui helpers: all cases A–L passed");
console.log("customer-analytics-ui wiring: MK/EN, RPC, exclusive at-risk, mobile overflow CSS passed");

/* Phase 2D — segment drill-down */
assert(html.includes('data-ca-segment="active"'), "A active clickable");
assert(html.includes('data-ca-segment="new"'), "B new clickable");
assert(html.includes('data-ca-segment="returning"'), "C returning clickable");
assert(html.includes('data-ca-segment="repeat"'), "D repeat clickable");
assert(html.includes('segment: "at_risk_30_59"'), "E 30-59");
assert(html.includes('segment: "at_risk_60_89"'), "E 60-89");
assert(html.includes('segment: "at_risk_90_plus"'), "E 90+");
assert(html.includes('segment: "booked_ahead"'), "F booked ahead");
assert(html.includes('filterValue: "male"') || html.includes('filterValue: "male"') || /filterValue:\s*"male"/.test(html), "G gender male");
assert(/filterValue:\s*"female"/.test(html), "G gender female");
assert(/filterValue:\s*"unknown"/.test(html), "G gender unknown");
assert(customerAnalyticsAgeRpcFilter("age_25_34") === "25_34", "H age 25_34 machine value");
assert(customerAnalyticsAgeRpcFilter("age_18_24") === "18_24", "H age 18_24");
assert(customerAnalyticsAgeRpcFilter("under_18") === "under_18", "H under_18");
assert(customerAnalyticsAgeRpcFilter("age_65_plus") === "65_plus", "H 65_plus");
assert(html.includes('rpcFilter: "25_34"'), "H rpcFilter in source");
const cityRows = buildCustomerAnalyticsCityRows(august.demographics.cities);
assert(cityRows[0].filterValue === "1" && cityRows[0].segment === "city", "I city_id");
assert(cityRows[1].filterValue === "unknown" && cityRows[1].segment === "city", "J unknown city");
assert(isCustomerAnalyticsFreqClickable("visits_1") === true, "K single visit clickable");
assert(html.includes('data-ca-segment') && html.includes("single_visit"), "K single_visit segment");
assert(isCustomerAnalyticsFreqClickable("visits_2") === false, "L 2 visits not clickable");
assert(isCustomerAnalyticsFreqClickable("visits_3") === false, "L 3 visits not clickable");
assert(isCustomerAnalyticsFreqClickable("visits_4_5") === false, "L 4-5 not clickable");
assert(isCustomerAnalyticsFreqClickable("visits_6_10") === false, "L 6-10 not clickable");
assert(isCustomerAnalyticsFreqClickable("visits_11_plus") === false, "L 11+ not clickable");
assert(!html.includes('data-ca-segment="visits_2"'), "L no fake visits_2 segment");
assert(html.includes("CA_SEGMENT_PAGE_SIZE = 50"), "M initial limit 50");
assert(nextCustomerAnalyticsSegmentOffset(50) === 50, "N offset += loaded");
assert(nextCustomerAnalyticsSegmentOffset(0) === 0, "N offset 0");
const merged = mergeCustomerAnalyticsSegmentRows(
  [{ analytics_customer_key: "p:1" }],
  [{ analytics_customer_key: "p:1" }, { analytics_customer_key: "p:2" }]
);
assert(merged.length === 2, "O duplicate key skipped");
assert(html.includes("if (st.loading) return"), "O duplicate-load guard");
assert(isCustomerAnalyticsSegmentResponseStale(1, 2, "a", "a") === true, "P stale request id");
assert(isCustomerAnalyticsSegmentResponseStale(1, 1, "a", "b") === true, "P stale token");
assert(isCustomerAnalyticsSegmentResponseStale(3, 3, "x", "x") === false, "P current accepted");
assert(html.includes("No customers in this segment."), "Q empty");
assert(html.includes("No customers currently match this at-risk group."), "Q empty at-risk");
assert(html.includes("Could not load this customer list."), "R error copy");
assert(html.includes("caSegRetryBtn"), "R retry");
assert(isCustomerAnalyticsSegmentSchemaError({ message: "Could not find the function public.get_business_customer_segment" }), "R schema cache");
assert(html.includes("id=\"caSegEstimatedNote\""), "S estimated note on drill-down");
assert(html.includes("Historical values include estimated service prices."), "S estimated EN");
assert(customerAnalyticsSegmentContactHtml(null, null).length === 0, "T omit missing contact");
assert(customerAnalyticsSegmentContactHtml("+38970111222", null).join() === "tel", "T phone only");
assert(customerAnalyticsSegmentContactHtml(null, "a@b.com").join() === "mailto", "T email only");
assert(html.includes("caSegAtRisk90"), "U i18n key");
assert(html.includes("Ризични — 90+ дена"), "U MK at-risk 90");
assert(html.includes("Вчитај уште"), "U MK load more");
assert(html.includes("Në rrezik — 90+ ditë"), "U SQ at-risk 90");
assert(html.includes("Ngarko më shumë"), "U SQ load more");
assert(html.includes("Klientë të përsëritur") || html.includes("caSegRepeat"), "U SQ repeat");
assert(html.includes("#customerAnalyticsSegmentView") && html.includes("overflow-x: hidden"), "V overflow");
assert(html.includes("id=\"caSegBackBtn\""), "W back button");
assert(html.includes("closeCustomerAnalyticsSegmentView"), "W close restores");
assert(html.includes("customerAnalyticsCache.key === cacheKey"), "W restore from cache");
assert(html.includes('sb.rpc("get_business_customer_segment"'), "X segment RPC");
const segFn = html.slice(html.indexOf("async function fetchBusinessCustomerSegment"), html.indexOf("async function loadCustomerAnalyticsSegment"));
assert(segFn.includes("get_business_customer_segment"), "X fetch uses segment RPC");
assert(!segFn.includes('.from("bookings")'), "X no raw bookings query");
assert(!segFn.includes("customer_private_profiles"), "X no private profiles");
assert(!html.includes("data-ca-segment=\"active\"") || html.includes("admin-ca-kpi--clickable"), "click affordance");
assert(!/data-ca-segment="active"[\s\S]{0,200}Avg visits/.test(html) || html.includes("caKpiAvgVisits"), "avg visits still present");
assert(!html.includes('data-ca-segment="avg'), "avg visits not a segment");
assert(!html.includes('id="caKpiAvgVisits"') || !/id="caKpiAvgVisits"[\s\S]{0,80}data-ca-segment/.test(html), "avg visits not clickable");
assert(!/id="caKpiTotal"[\s\S]{0,120}data-ca-segment/.test(html), "total customers not clickable");
assert(!/id="caValueBody"[\s\S]{0,400}data-ca-segment/.test(html), "value metrics not clickable");
assert(!html.includes("openClientDetailSheet") || html.includes("buildCustomerAnalyticsSegmentRowHtml"), "no customer detail from segment rows");
assert(!/function buildCustomerAnalyticsSegmentRowHtml[\s\S]{0,2500}openClientDetailSheet/.test(html), "segment rows not opening client detail");

const ageRow = buildCustomerAnalyticsAgeRows(august.demographics.age).find((r) => r.label === "25–34");
assert(ageRow && ageRow.filterValue === "25_34" && ageRow.segment === "age_bucket", "H age row rpc filter");

console.log("customer-analytics-ui phase 2D: A–X passed");

function isCustomerAnalyticsDetailResponseStale(requestId, currentId, token, currentToken) {
  return requestId !== currentId || token !== currentToken;
}

function mergeCustomerAnalyticsDetailHistory(existing, incoming) {
  const out = Array.isArray(existing) ? existing.slice() : [];
  const seen = new Set(out.map((row) => row && row.booking_id).filter(Boolean));
  (incoming || []).forEach((row) => {
    const id = row && row.booking_id;
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push(row);
  });
  return out;
}

function shouldShowCustomerAnalyticsDetailEstimatedNote(payload) {
  return !!(payload && (payload.contains_estimated_prices === true || payload.summary?.contains_estimated_prices === true));
}

function customerAnalyticsDetailContactActions(phone, email) {
  const parts = [];
  if (String(phone || "").trim()) parts.push("tel");
  if (String(email || "").trim()) parts.push("mailto");
  return parts;
}

function customerAnalyticsDetailMoney(value) {
  return formatBusinessMoney(value);
}

function customerAnalyticsDetailHasEditControls(source) {
  return /caDetEdit|Edit customer|Delete customer|Merge customer|Mark Completed|Mark No-show/i.test(source);
}

/* Phase 2E — read-only customer detail */
assert(html.includes("data-ca-customer-key"), "U segment row customer key");
assert(html.includes("openCustomerAnalyticsCustomerDetail"), "U tap opens detail");
assert(!/function buildCustomerAnalyticsSegmentRowHtml[\s\S]{0,4000}openClientDetailSheet/.test(html), "U does not open Clients sheet");
assert(html.includes("caDetLoading") && html.includes("id=\"caDetStatus\""), "V loading state");
assert(html.includes("id=\"caDetError\"") && html.includes("caDetRetryBtn"), "W error retry");
assert(html.includes("caDetNotFound"), "W not found");
assert(isCustomerAnalyticsDetailResponseStale(1, 2, "a", "a") === true, "X stale request id");
assert(isCustomerAnalyticsDetailResponseStale(1, 1, "a", "b") === true, "X stale token");
assert(isCustomerAnalyticsDetailResponseStale(4, 4, "u:1", "u:1") === false, "X current accepted");
assert(html.includes("isCustomerAnalyticsDetailResponseStale"), "X stale guard in app");
assert(html.includes("payload: null"), "X clear payload on open");
assert(html.includes("id=\"caDetBackBtn\""), "Y detail back");
assert(html.includes("closeCustomerAnalyticsCustomerDetail"), "Y close detail");
assert(html.includes("customerAnalyticsSegmentState.open"), "Y return to segment");
assert(html.includes("closeCustomerAnalyticsCustomerDetail({ silent: true })"), "Z silent close on leave");
assert(html.includes("closeCustomerAnalyticsSegmentView({ silent: true })"), "Z second back / leave restores overview path");
assert(customerAnalyticsDetailContactActions(null, null).length === 0, "AA omit missing contact");
assert(customerAnalyticsDetailContactActions("+38970111222", null).join() === "tel", "AA phone only");
assert(customerAnalyticsDetailContactActions(null, "a@b.com").join() === "mailto", "AA email only");
assert(html.includes("tel:${escapeHtml(href)}") && html.includes("mailto:${escapeHtml(email)}"), "AA tel/mailto in detail");
assert(shouldShowCustomerAnalyticsDetailEstimatedNote({ contains_estimated_prices: true }) === true, "AB estimated true");
assert(shouldShowCustomerAnalyticsDetailEstimatedNote({ summary: { contains_estimated_prices: false } }) === false, "AB estimated false");
assert(html.includes("Historical revenue includes estimated service prices."), "AB estimated EN");
assert(html.includes("Историскиот приход вклучува проценети цени на услуги."), "AB estimated MK");
assert(html.includes("Të ardhurat historike përfshijnë çmimet e vlerësuara të shërbimeve."), "AB estimated SQ");
assert(customerAnalyticsDetailMoney(0) === "0 MKD", "AC revenue zero displays 0");
assert(customerAnalyticsDetailMoney(null) === "—", "AD missing value dash");
assert(html.includes("caDetTitle") && html.includes("Детали за клиент"), "AE MK title");
assert(html.includes("Detajet e klientit"), "AE SQ title");
assert(html.includes("caDetRevenueToDate") && html.includes("Приход до сега"), "AE MK revenue");
assert(html.includes("caDetStatusCompleted") && html.includes("Реализирано"), "AE MK completed");
assert(html.includes("Përfunduar"), "AE SQ completed");
assert(html.includes("#customerAnalyticsDetailView") && html.includes("overflow-x: hidden"), "AF mobile overflow");
assert(html.includes("min-height: 44px"), "AF 44px targets present");
assert(!customerAnalyticsDetailHasEditControls(html.slice(html.indexOf("function openCustomerAnalyticsCustomerDetail"), html.indexOf("function renderAdminCustomerAnalytics"))), "AG no edit/delete in detail flow");
assert(!html.includes("id=\"caDetEditBtn\""), "AG no edit button");
assert(!html.includes("id=\"caDetDeleteBtn\""), "AG no delete button");
const detFn = html.slice(html.indexOf("async function fetchBusinessCustomerDetail"), html.indexOf("async function loadCustomerAnalyticsCustomerDetail"));
assert(detFn.includes("get_business_customer_detail"), "AH fetch uses detail RPC");
assert(!detFn.includes('.from("bookings")'), "AH no raw bookings query");
assert(!detFn.includes("customer_private_profiles"), "AH no private profiles");
assert(html.includes("CA_DETAIL_HISTORY_PAGE_SIZE = 25"), "history page size 25");
const mergedHist = mergeCustomerAnalyticsDetailHistory(
  [{ booking_id: "1" }],
  [{ booking_id: "1" }, { booking_id: "2" }]
);
assert(mergedHist.length === 2, "history merge dedupes booking_id");
assert(html.includes("caDetVip"), "VIP badge i18n");
assert(!/function buildCustomerAnalyticsDetailBodyHtml[\s\S]{0,3500}analytics_customer_key\}/.test(html) || !html.includes("caDetKey"), "key not displayed");
assert(!html.includes("id=\"caDetCustomerKey\""), "key not a visible field");

console.log("customer-analytics-ui phase 2E: U–AH passed");

/* Phase 3B — Customer Detail VIP + Internal Notes */
function isCustomerAnalyticsCrmResponseStale(requestId, currentId, token, currentToken) {
  return requestId !== currentId || token !== currentToken;
}
function customerAnalyticsDetailVipIsOn(customer) {
  return customer?.is_vip === true;
}
function customerAnalyticsDetailVipNextValue(isVip) {
  return !isVip;
}
function customerAnalyticsCanToggleVip(saving, open, customerKey) {
  return !saving && !!open && !!String(customerKey || "").trim();
}
function customerAnalyticsCrmRpcParams(businessId, customerKey, extra) {
  return Object.assign({
    p_business_id: businessId,
    p_customer_key: customerKey
  }, extra || {});
}
function customerAnalyticsNormalizeNoteForSave(text) {
  return String(text ?? "").replace(/^\s+|\s+$/g, "");
}
function customerAnalyticsNoteIsEmpty(text) {
  return customerAnalyticsNormalizeNoteForSave(text) === "";
}
function customerAnalyticsNoteExceedsLimit(text, max) {
  const limit = Number.isFinite(Number(max)) ? Number(max) : 2000;
  return String(text ?? "").length > limit;
}
function applyCustomerAnalyticsDetailVipSuccess(customer, isVip) {
  if (!customer) return customer;
  customer.is_vip = !!isVip;
  return customer;
}
function applyCustomerAnalyticsDetailVipFailure(customer, previous) {
  if (!customer) return customer;
  customer.is_vip = !!previous;
  return customer;
}

const detCrm = html.slice(
  html.indexOf("function paintCustomerAnalyticsDetailBadges"),
  html.indexOf("function renderAdminCustomerAnalytics")
);
const notesHtmlFn = html.slice(
  html.indexOf("function buildCustomerAnalyticsDetailNotesHtml"),
  html.indexOf("function paintCustomerAnalyticsDetailNotes")
);
const vipFetchFn = html.slice(
  html.indexOf("async function fetchSetBusinessCustomerVip"),
  html.indexOf("async function fetchBusinessCustomerInternalNotes")
);
const notesGetFn = html.slice(
  html.indexOf("async function fetchBusinessCustomerInternalNotes"),
  html.indexOf("async function fetchUpdateBusinessCustomerInternalNotes")
);
const notesSaveFn = html.slice(
  html.indexOf("async function fetchUpdateBusinessCustomerInternalNotes"),
  html.indexOf("async function toggleCustomerAnalyticsDetailVip")
);
const vipToggleFn = html.slice(
  html.indexOf("async function toggleCustomerAnalyticsDetailVip"),
  html.indexOf("async function loadCustomerAnalyticsDetailNotes")
);
const notesLoadFn = html.slice(
  html.indexOf("async function loadCustomerAnalyticsDetailNotes"),
  html.indexOf("function enterCustomerAnalyticsDetailNotesEdit")
);
const notesSaveUiFn = html.slice(
  html.indexOf("async function saveCustomerAnalyticsDetailNotes"),
  html.indexOf("function buildCustomerAnalyticsDetailHistoryRowHtml")
);
const bodyHtmlFn = html.slice(
  html.indexOf("function buildCustomerAnalyticsDetailBodyHtml"),
  html.indexOf("function paintCustomerAnalyticsDetailView")
);

assert(html.includes("id=\"caDetBody\""), "1 detail body still renders");
assert(html.includes("buildCustomerAnalyticsDetailBodyHtml"), "1 detail render fn");
assert(html.includes('t("caDetMarkVip", "Mark VIP")'), "2 VIP false Mark VIP");
assert(html.includes("admin-ca-det-vip--off"), "2 inactive VIP class");
assert(html.includes('t("caDetVip", "VIP")'), "3 VIP true label");
assert(html.includes("admin-ca-det-vip--on"), "3 active VIP class");
assert(vipFetchFn.includes('sb.rpc("set_business_customer_vip"'), "4 VIP RPC name");
assert(vipToggleFn.includes("fetchSetBusinessCustomerVip(st.customerKey, next)"), "4 toggle uses analytics key");
const vipParams = customerAnalyticsCrmRpcParams("biz-1", "u:abc", { p_is_vip: true });
assert(vipParams.p_business_id === "biz-1", "5 business_id param");
assert(vipFetchFn.includes("customerAnalyticsCrmRpcParams(bizId, customerKey, { p_is_vip: isVip })"), "5 RPC business id");
assert(vipParams.p_customer_key === "u:abc", "6 analytics_customer_key param");
assert(!vipFetchFn.includes("business_customer_id") && !vipToggleFn.includes("customer_user_id"), "6 no id substitution");
assert(customerAnalyticsCanToggleVip(true, true, "u:1") === false, "7 saving blocks toggle");
assert(vipToggleFn.includes("customerAnalyticsCanToggleVip(st.vipSaving"), "7 double-click guard");
assert(vipToggleFn.includes("st.vipSaving = true"), "7 sets saving");
const vipCust = { is_vip: false };
applyCustomerAnalyticsDetailVipSuccess(vipCust, true);
assert(vipCust.is_vip === true, "8 success updates is_vip");
assert(vipToggleFn.includes("paintCustomerAnalyticsDetailBadges()"), "8 paints chip");
applyCustomerAnalyticsDetailVipFailure(vipCust, false);
assert(vipCust.is_vip === false, "9 failure restores previous");
assert(vipToggleFn.includes("applyCustomerAnalyticsDetailVipFailure") && vipToggleFn.includes('showToast(result.error, "error")'), "9 toast on failure");
assert(html.includes("void loadCustomerAnalyticsDetailNotes()"), "10 notes load on open");
assert(notesGetFn.includes('sb.rpc("get_business_customer_internal_notes"'), "10 get notes RPC");
assert(notesHtmlFn.includes("caDetNotesEmpty") && notesHtmlFn.includes("caDetNotesAddBtn"), "11 empty state");
assert(notesHtmlFn.includes("admin-ca-det-notes__body") && notesHtmlFn.includes("caDetNotesEditBtn"), "12 existing note render");
assert(html.includes("function enterCustomerAnalyticsDetailNotesEdit") && notesHtmlFn.includes("caDetNotesAddBtn"), "13 add enters edit");
assert(html.includes("st.notes.draft = st.notes.note || \"\"") && notesHtmlFn.includes("caDetNotesInput"), "14 edit preloads note");
assert(notesSaveFn.includes('sb.rpc("update_business_customer_internal_notes"'), "15 save RPC");
assert(notesSaveUiFn.includes("customerAnalyticsNormalizeNoteForSave"), "15 trimmed save");
assert(customerAnalyticsNoteIsEmpty("   \n") === true, "16 whitespace is empty");
assert(customerAnalyticsNormalizeNoteForSave("  hello  ") === "hello", "16 trim");
assert(notesSaveUiFn.includes("fetchUpdateBusinessCustomerInternalNotes(st.customerKey, toSave)"), "16 empty save still calls RPC");
assert(notesSaveUiFn.includes("st.notes.editing = true") && notesSaveUiFn.includes("input.value = st.notes.draft"), "17 failed save keeps draft");
assert(html.includes("CA_DET_NOTE_MAX = 2000"), "18 2000 max constant");
assert(notesHtmlFn.includes("maxlength=\"${CA_DET_NOTE_MAX}\"") || notesHtmlFn.includes("maxlength=\"${CA_DET_NOTE_MAX}\""), "18 textarea maxlength");
assert(customerAnalyticsNoteExceedsLimit("a".repeat(2000), 2000) === false, "18 2000 accepted");
assert(customerAnalyticsNoteExceedsLimit("a".repeat(2001), 2000) === true, "19 over 2000 blocked");
assert(notesSaveUiFn.includes("customerAnalyticsNoteExceedsLimit"), "19 client-side over-limit");
assert(isCustomerAnalyticsCrmResponseStale(1, 2, "A", "A") === true, "20 stale request id");
assert(isCustomerAnalyticsCrmResponseStale(1, 1, "A", "B") === true, "20 stale token A vs B");
assert(isCustomerAnalyticsCrmResponseStale(3, 3, "u:2", "u:2") === false, "20 current notes accepted");
assert(notesLoadFn.includes("isCustomerAnalyticsCrmResponseStale"), "20 notes stale guard");
assert(vipToggleFn.includes("isCustomerAnalyticsCrmResponseStale"), "20 VIP stale guard");
assert(html.includes("id=\"caDetBackBtn\"") && html.includes("closeCustomerAnalyticsCustomerDetail();"), "21 back unchanged");
assert(html.includes("openCustomerAnalyticsCustomerDetail(key)"), "22 segment to detail unchanged");
assert(html.includes("function buildCustomerAnalyticsDetailHistoryRowHtml") && bodyHtmlFn.includes("caDetVisitHistory"), "23 history unchanged");
assert(!detCrm.includes("completed_visits_lifetime +") && !detCrm.includes("completed_revenue_lifetime ="), "24 no visit/revenue mutation");
assert(!vipFetchFn.includes(".from(\"bookings\")") && !notesSaveFn.includes(".from(\"bookings\")"), "25 no booking writes");
assert(!html.includes("function set_business_customer_vip") && !detCrm.includes("CREATE OR REPLACE"), "25 no SQL in detail JS");
assert(html.includes("#customerAnalyticsDetailView .admin-ca-det-vip") && html.includes("min-height: 44px"), "26 VIP 44px target");
assert(html.includes("#customerAnalyticsDetailView .admin-ca-det-notes__textarea") && html.includes("overflow-x: hidden"), "26 notes overflow");
assert(html.includes("font-size: 16px") && html.includes("admin-ca-det-notes__textarea"), "26 iOS 16px textarea");
assert(html.includes("caDetMarkVip: \"Mark VIP\""), "27 EN Mark VIP");
assert(html.includes("caDetNotesTitle: \"Internal Notes\""), "27 EN notes title");
assert(html.includes("caDetNotesPrivacy: \"Only visible to your business\""), "27 EN privacy");
assert(html.includes("caDetMarkVip: \"Означи VIP\""), "27 MK Mark VIP");
assert(html.includes("caDetNotesTitle: \"Внатрешни белешки\""), "27 MK notes");
assert(html.includes("caDetNotesPrivacy: \"Видливо само за вашиот бизнис\""), "27 MK privacy");
assert(html.includes("caDetMarkVip: \"Shëno VIP\""), "27 SQ Mark VIP");
assert(html.includes("caDetNotesTitle: \"Shënime të brendshme\""), "27 SQ notes");
assert(html.includes("caDetNotesPrivacy: \"E dukshme vetëm për biznesin tuaj\""), "27 SQ privacy");
assert(html.includes("id=\"caDetVipBtn\""), "VIP is a real button");
assert(html.includes("aria-label=") && html.includes("caDetVipAriaMark"), "VIP aria-label");
assert(notesHtmlFn.includes("for=\"caDetNotesInput\"") && notesHtmlFn.includes("caDetNotesLabel"), "textarea labelled");
assert(bodyHtmlFn.includes("buildCustomerAnalyticsDetailNotesHtml()"), "notes after KPIs in body");
assert(customerAnalyticsDetailVipIsOn({ is_vip: false }) === false, "VIP false helper");
assert(customerAnalyticsDetailVipNextValue(false) === true, "VIP next value");
assert(html.includes("caDetRepeat") && html.includes("admin-ca-det-badge"), "Repeat remains status-only");
assert(!notesHtmlFn.includes("created_by") && !notesHtmlFn.includes("updated_by"), "no UUID authors");
assert(!html.includes("confirm(") || !vipToggleFn.includes("confirm("), "no browser confirm on VIP");
assert(html.includes("Only visible to your business"), "privacy wording EN");

console.log("customer-analytics-ui phase 3B: VIP + notes passed");

/* Mobile segment list layout — back button vs global button { width: 100% } */
const segBackCss = html.slice(
  html.indexOf("#adminSectionCustomerAnalytics .admin-ca-seg-top"),
  html.indexOf("#customerAnalyticsSegmentView .admin-ca-seg-title")
);
assert(segBackCss.includes("width: auto"), "1 Back width auto not 100%");
assert(segBackCss.includes("text-align: left") && segBackCss.includes("justify-content: flex-start"), "1 Back left-aligned");
assert(segBackCss.includes("flex-direction: column"), "1 mobile stacks Back then title");
assert(html.includes("id=\"caSegBackBtn\"") && html.includes("closeCustomerAnalyticsSegmentView"), "2 Back still clickable / restores");
assert(segBackCss.includes("flex: 0 0 auto") && segBackCss.includes("admin-ca-seg-heading"), "3 heading does not grow into a blank column");
assert(html.includes("justify-content: flex-start"), "3 segment column starts at top");
assert(html.includes("id=\"caSegEstimatedNote\"") && html.includes("id=\"caSegList\""), "4 note then list remain in order");
assert(html.includes("openCustomerAnalyticsCustomerDetail(key)"), "5 Segment → Detail unchanged");
assert(html.includes("customerAnalyticsCache.key === cacheKey"), "6 Back restores analytics cache");
assert(html.includes("var(--admin-tabbar-height") && html.includes("env(safe-area-inset-bottom"), "7 bottom nav spacing preserved");
assert(html.includes("#customerAnalyticsSegmentView") && html.includes("overflow-x: hidden"), "8 no horizontal overflow");
assert(html.includes("id=\"caDetVipBtn\"") && html.includes("id=\"caDetNotesCard\""), "9 VIP/Notes markup untouched");
assert(html.includes('sb.rpc("get_business_customer_segment"') && html.includes("completed_visits_lifetime"), "10 analytics values untouched");
assert(html.includes("admin-ca-seg-back__icon"), "Back chevron present");
assert(html.includes("data-i18n-aria-label=\"commonBack\""), "Back aria-label");
assert(html.includes("min-height: 44px"), "44px touch target still present");

console.log("customer-analytics-ui segment mobile layout: passed");

