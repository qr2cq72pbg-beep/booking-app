#!/usr/bin/env node
/**
 * Business Customers / CRM — CAPTAIN visual migration + detail scroll contract.
 * Static checks only. Does not change membership, approval, or analytics formulas.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

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

function i18nValue(block, key) {
  const re = new RegExp(`(?:^|,)\\s*${key}\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"`, "m");
  const m = block.match(re);
  return m ? m[1].replace(/\\"/g, '"') : "";
}

const clientsCssStart = html.indexOf("/* Business Customers / CRM — CAPTAIN-derived XBook layer */");
const clientsCssEnd = html.indexOf("body.admin-mobile-shell-active #adminView #clientNotesSheet.client-notes-sheet,");
assert(clientsCssStart >= 0, "1 CAPTAIN CRM CSS block present");
assert(clientsCssEnd > clientsCssStart, "1 CRM CSS ends before notes sheet");
const clientsCss = html.slice(clientsCssStart, clientsCssEnd);

assert(clientsCss.includes("var(--theme-surface-elevated"), "11 list/detail use semantic elevated surface");
assert(clientsCss.includes("var(--theme-text-primary"), "11 semantic text tokens");
assert(clientsCss.includes("var(--xbook-navy"), "11 XBook navy fallback");
assert(!clientsCss.includes("linear-gradient(135deg, #8b5cf6"), "2 no legacy purple Close CTA");
assert(!clientsCss.includes("max-height: min(82vh, 560px)"), "3 no legacy 560px sheet cap");
assert(!clientsCss.includes("min-height: 42px"), "2 no giant 42px filter CTA in CRM block");
assert(/height:\s*3[2-6]px/.test(clientsCss), "2 compact filter chips 32-36px");
assert(clientsCss.includes("height: 44px"), "1 44px search/back controls");
assert(clientsCss.includes("border-radius: 16px"), "1 16px card radius");
assert(clientsCss.includes("admin-clients-detail-open"), "3 full-screen detail class");
assert(clientsCss.includes("position: relative"), "3 detail is in-flow, not viewport sheet");
assert(clientsCss.includes("padding: 0 0 calc(var(--admin-tabbar-height, 58px) + env(safe-area-inset-bottom, 0px) + 16px)"), "4 detail bottom clearance");
assert(clientsCss.includes("#adminSectionClients .clients-list") && clientsCss.includes("padding-bottom: calc(var(--admin-tabbar-height"), "4 list bottom clearance");
assert(clientsCss.includes("overflow-x: hidden"), "10 no horizontal page overflow");
assert(clientsCss.includes("max-width: 375px") || clientsCss.includes("@media (max-width: 375px)"), "10 375 chip tightening");
assert(clientsCss.includes("grid-template-columns: minmax(0, 1fr) auto"), "10 row grid prevents page overflow");
assert(clientsCss.includes("text-overflow: ellipsis"), "10 long names/emails ellipsize");
assert(clientsCss.includes("overflow-wrap: anywhere"), "10 long detail values wrap");
assert(clientsCss.includes("white-space: nowrap"), "10 badges stay on one line");

const filterCssStart = clientsCss.indexOf("#adminSectionClients .clients-approval-filters");
const filterActiveCss = clientsCss.indexOf("button.clients-approval-filter.clients-approval-filter--active");
assert(filterCssStart >= 0 && filterActiveCss > filterCssStart, "11 filter chip rules present");
const unselectedFilterCss = clientsCss.slice(filterCssStart, filterActiveCss);
assert(
  !unselectedFilterCss.includes(":is(:hover, :focus, :active)"),
  "11 unselected chip hover/active no longer beats selected navy"
);
assert(
  clientsCss.includes("button.clients-approval-filter.clients-approval-filter--active:is(:hover, :focus, :active)"),
  "11 selected chip keeps navy through iOS sticky hover"
);
assert(clientsCss.includes("var(--theme-primary-bg, var(--xbook-navy"), "11 selected uses navy token");
assert(clientsCss.includes("var(--theme-on-primary, #fff)"), "11 selected text uses on-primary");
assert(clientsCss.includes("var(--theme-surface-elevated"), "11 unselected uses elevated surface");
assert(clientsCss.includes("@media (hover: hover) and (pointer: fine)"), "11 hover paint is pointer-fine only");
assert(clientsCss.includes("touch-action: manipulation"), "12 chip taps use manipulation");
assert(clientsCss.includes("scroll-snap-type: none"), "12 rail snap does not steal taps");
assert(clientsCss.includes("touch-action: pan-x"), "12 rail can still scroll horizontally");

const sectionStart = html.indexOf('id="adminSectionClients"');
assert(sectionStart >= 0, "clients section exists");
const sectionEnd = html.indexOf('id="adminSectionPerformance"', sectionStart);
const sectionHtml = html.slice(sectionStart, sectionEnd);

assert(sectionHtml.includes('id="clientsListBackBtn"'), "6 list back exists");
assert(sectionHtml.includes('class="admin-ca-seg-back'), "1 CAPTAIN back class");
assert(sectionHtml.includes('data-i18n="screenClients">Customers'), "1 Customers title");
assert(sectionHtml.includes('data-i18n="clientsSubtitle"'), "1 subtitle i18n");
assert(sectionHtml.includes('class="admin-clients-list-chrome"'), "3 list chrome wrapper");
assert(sectionHtml.includes('data-i18n-placeholder="clientsSearchPlaceholder"'), "8 search placeholder i18n");
assert(sectionHtml.includes("clients-approval-filter"), "2 filters remain");
assert(
  /data-clients-approval-filter="all"[^>]*clients-approval-filter--active|class="clients-approval-filter clients-approval-filter--active"[^>]*data-clients-approval-filter="all"/.test(
    sectionHtml
  ),
  "1 All selected by default"
);
assert(sectionHtml.includes('onclick="setClientsApprovalFilter(\'pending\')"'), "2 Pending tap binding remains");
assert(sectionHtml.includes('oninput="onClientsSearchInput()"'), "8 search paints locally");
assert(!sectionHtml.includes('oninput="renderClients()"'), "8 search no longer refetches");
assert(!sectionHtml.includes("client-detail-sheet__done"), "3 no trailing Close CTA");
assert(!sectionHtml.includes("client-detail-sheet__close"), "3 no sheet Close button");
assert(!sectionHtml.includes('role="dialog"'), "3 detail is not a modal dialog");
assert(sectionHtml.includes('role="region"'), "3 detail is a full-screen region");
assert(sectionHtml.includes('id="clientDetailBackBtn"'), "3 detail back exists");
assert(sectionHtml.includes('data-i18n="caDetLastVisit"'), "8 last visit reused");
assert(sectionHtml.includes('data-i18n="analyticsTopService"'), "8 top service reused");
assert(sectionHtml.includes('data-i18n="clientsNextVisit"'), "8 next visit i18n");
assert(sectionHtml.includes('data-i18n="caDetVisitHistory"'), "8 history title reused");
assert(sectionHtml.includes('id="clientDetailSheetNextVisit"'), "4 next visit stat");

assert(html.includes("openBusinessCustomersList({ from: 'customer-analytics' })"), "6 Analytics Customers opens CRM with return");
assert(html.includes("function leaveBusinessCustomersList()"), "6 list back helper");
assert(html.includes('const dest = clientsListReturnSection || "customer-analytics"'), "6 default return is Analytics Customers, not Home");
assert(html.includes("clientsListScrollTop = section.scrollTop || 0"), "5 list scroll saved");
assert(html.includes("section.scrollTop = clientsListScrollTop || 0"), "5 list scroll restored");
assert(html.includes('section?.classList.add("admin-clients-detail-open")'), "3 open adds full-screen class");
assert(html.includes('section?.classList.remove("admin-clients-detail-open")'), "3 close removes full-screen class");
assert(!html.includes("(client.bookings || []).slice(0, 12)"), "9 history is not hard-capped at 12 in CRM detail");
assert(html.includes("const history = Array.isArray(client.bookings) ? client.bookings : []"), "9 all in-memory bookings render");
assert(html.includes("getClientBookingStatusLabel"), "7 localized booking status helper");
assert(html.includes('t("caDetStatusConfirmed", "Confirmed")'), "7 Confirmed uses canonical key");
assert(html.includes('t("caDetStatusPending", "Pending")'), "7 Pending uses canonical key");
assert(html.includes('t("caDetStatusCancelled", "Cancelled")'), "7 Cancelled uses canonical key");
assert(html.includes('t("analyticsTopService"') || html.includes('data-i18n="analyticsTopService"'), "8 Top service label localized");
assert(html.includes('t("caDetLastVisit", "Last visit")'), "8 Last visit label localized");
assert(!html.includes("Top service: ${i18nUserHtml"), "8 no hardcoded English Top service label on rows");
assert(html.includes("clients-card__contact"), "1 compact row secondary contact");
assert(html.includes("clients-card__trail"), "1 compact row trailing badge/count");
assert(!html.includes("Total spent: ${escapeHtml(spent)}"), "1 spend moved off dense list rows");

const en = extractObjectBlock(html, "const I18N = {");
const mkStart = html.indexOf("mk: {", html.indexOf("const I18N = {"));
const sqStart = html.indexOf("sq: {", html.indexOf("const I18N = {"));
const mk = extractObjectBlock(html.slice(mkStart - 20), "mk: {");
const sq = extractObjectBlock(html.slice(sqStart - 20), "sq: {");

const crmKeys = [
  "clientsSubtitle",
  "clientsSearchPlaceholder",
  "clientsNextVisit",
  "clientsBookingsLabel",
  "clientsActionApprove",
  "clientsBookingMany",
  "clientsCountMany",
  "clientsNoBookings",
  "clientsFilterAll",
  "clientsFilterPending",
  "clientsFilterApproved",
  "clientsFilterRejected"
];
for (const key of crmKeys) {
  const enV = i18nValue(en, key);
  const mkV = i18nValue(mk, key);
  const sqV = i18nValue(sq, key);
  assert(!!enV && !!mkV && !!sqV, `8 ${key} has EN/MK/SQ`);
  assert(mkV !== enV, `8 ${key} MK is translated`);
  assert(sqV !== enV, `8 ${key} SQ is translated`);
}

assert(i18nValue(en, "caDetStatusConfirmed") === "Confirmed", "7 EN Confirmed canonical");
assert(i18nValue(mk, "caDetStatusConfirmed") === "Потврдено", "7 MK Confirmed canonical");
assert(i18nValue(sq, "caDetStatusConfirmed") === "Konfirmuar", "7 SQ Confirmed canonical");
assert(i18nValue(en, "analyticsTopService") === "Top service", "8 EN Top service canonical");
assert(i18nValue(mk, "analyticsTopService") === "Најбарана услуга", "8 MK Top service canonical");
assert(i18nValue(sq, "analyticsTopService") === "Shërbimi kryesor", "8 SQ Top service canonical");
assert(i18nValue(en, "screenClients") === "Customers", "1 EN header Customers");

const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
assert(inlineScripts.length >= 1, "12 inline JS extracted");
const checkFile = path.join(root, "scripts", ".tmp-crm-syntax-check.js");
fs.writeFileSync(checkFile, inlineScripts.join("\n;\n"));
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
assert(checked.status === 0, "12 node --check inline JS" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout)));
try {
  fs.unlinkSync(checkFile);
} catch {
  /* keep on failure */
}

function extractFunction(src, name) {
  const start = src.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  assert(start >= 0, `extract ${name}`);
  let paren = src.indexOf("(", start);
  assert(paren >= 0, `extract ${name} params`);
  let depth = 0;
  for (let i = paren; i < src.length; i += 1) {
    if (src[i] === "(") depth += 1;
    else if (src[i] === ")") {
      depth -= 1;
      if (depth === 0) {
        paren = i;
        break;
      }
    }
  }
  const bodyStart = src.indexOf("{", paren);
  assert(bodyStart >= 0, `extract ${name} body`);
  depth = 0;
  for (let i = bodyStart; i < src.length; i += 1) {
    if (src[i] === "{") depth += 1;
    else if (src[i] === "}") {
      depth -= 1;
      if (depth === 0) return src.slice(start, i + 1);
    }
  }
  assert(false, `unclosed function ${name}`);
  return "";
}

const setFilterSrc = extractFunction(html, "setClientsApprovalFilter");
const renderClientsSrc = extractFunction(html, "renderClients");
const paintMemorySrc = extractFunction(html, "paintClientsListFromMemory");
const listContentsSrc = extractFunction(html, "renderClientsListContents");
const closeDetailSrc = extractFunction(html, "closeClientDetailSheet");
const getFilteredSrc = extractFunction(html, "getFilteredClients");
const syncMissingSrc = extractFunction(html, "syncMissingBusinessCustomers");

assert(!setFilterSrc.includes("syncMissingBusinessCustomers"), "6 filter tap does not sync");
assert(!setFilterSrc.includes("ensureBusinessCustomersLoaded"), "6 filter tap does not hydrate");
assert(!setFilterSrc.includes("renderClients("), "6 filter tap is local paint, not refetch render");
assert(setFilterSrc.includes("syncClientsApprovalFilterUi()"), "2 filter updates selected class immediately");
assert(setFilterSrc.includes("paintClientsListFromMemory()"), "5 filter paints in-memory list");
assert(paintMemorySrc.includes("renderClientsListContents(box)"), "5 memory paint writes list only");
assert(listContentsSrc.includes("syncClientsApprovalFilterUi()"), "7 selected state reapplied after list rerender");
assert(!listContentsSrc.includes("clientsApprovalFilter ="), "7 list rerender does not reset filter");
assert(!closeDetailSrc.includes("clientsApprovalFilter"), "9 detail Back does not reset filter");
assert(!closeDetailSrc.includes("clientSearch"), "9 detail Back does not clear search");
assert(closeDetailSrc.includes("clientsListScrollTop"), "9 detail Back restores list scroll");
assert(getFilteredSrc.includes("clientsApprovalFilter"), "8 filter applied in memory");
assert(getFilteredSrc.includes("clientMatchesCustomerSearch"), "8 search composes with filter");
assert(getFilteredSrc.includes('getElementById("clientSearch")'), "8 search reads live input");
assert(syncMissingSrc.includes("skipped: true"), "6 warm sync is skipped");
assert(syncMissingSrc.includes("opts.force"), "6 force refresh still possible");
assert(renderClientsSrc.includes("isBusinessCustomersCacheWarm()"), "6 open uses warm cache");
assert(renderClientsSrc.includes("paintClientsListFromMemory()"), "6 warm open does not block on fetch");
assert(html.includes("markClientsCrmNetworkFetch(\"hydrate-business-customers\")"), "6 hydrate is counted");
assert(html.includes("markClientsCrmNetworkFetch(\"sync-missing-business-customers\")"), "6 sync is counted");
assert(html.includes("const history = Array.isArray(client.bookings) ? client.bookings : []"), "9 full history only in detail paint");
assert(!html.includes("(client.bookings || []).slice(0, 12)"), "9 history still not capped at 12");

function makeChip(id) {
  const attrs = { "data-clients-approval-filter": id, "aria-selected": "false", "aria-pressed": "false" };
  const classes = new Set(["clients-approval-filter"]);
  if (id === "all") classes.add("clients-approval-filter--active");
  const el = {
    nodeType: 1,
    className: [...classes].join(" "),
    tabIndex: id === "all" ? 0 : -1,
    offsetLeft: id === "all" ? 0 : 80,
    offsetWidth: 72,
    getAttribute(name) {
      if (name === "data-clients-approval-filter") return id;
      return attrs[name] ?? null;
    },
    setAttribute(name, value) {
      attrs[name] = String(value);
    },
    classList: {
      contains(name) {
        return classes.has(name);
      },
      toggle(name, on) {
        if (on) classes.add(name);
        else classes.delete(name);
        el.className = [...classes].join(" ");
      },
      add(name) {
        classes.add(name);
        el.className = [...classes].join(" ");
      },
      remove(name) {
        classes.delete(name);
        el.className = [...classes].join(" ");
      }
    }
  };
  return el;
}

const chips = ["all", "pending", "approved", "rejected", "blocked"].map(makeChip);
const searchEl = { value: "" };
const listBox = { innerHTML: "", querySelector() { return null; } };
const rail = {
  dataset: {},
  clientWidth: 320,
  scrollLeft: 0,
  contains(node) {
    return chips.includes(node);
  },
  querySelector(sel) {
    if (sel === ".clients-approval-filter--active") {
      return chips.find((c) => c.classList.contains("clients-approval-filter--active")) || null;
    }
    return null;
  },
  addEventListener() {},
  scrollTo(opts) {
    rail.scrollLeft = opts?.left || 0;
  }
};

const mockClients = [
  { key: "a", name: "Ana", status: "approved" },
  { key: "p", name: "Petar", status: "pending" },
  { key: "d", name: "Daniela", status: "approved" },
  { key: "r", name: "Rina", status: "rejected" }
];

const ctx = {
  clientsApprovalFilter: "all",
  clientsCrmNetworkFetchCount: 0,
  adminPendingClientsCount: 0,
  console,
  performance: { now: () => 0 },
  document: {
    getElementById(id) {
      if (id === "clientsApprovalFilters") return rail;
      if (id === "clientsList") return listBox;
      if (id === "clientSearch") return searchEl;
      return null;
    },
    querySelectorAll(sel) {
      if (sel === "#clientsApprovalFilters .clients-approval-filter") return chips;
      return [];
    }
  },
  bindClientsApprovalFilterRail() {},
  syncMissingBusinessCustomers() {
    ctx.clientsCrmNetworkFetchCount += 1;
    throw new Error("filter path must not sync");
  },
  ensureBusinessCustomersLoaded() {
    ctx.clientsCrmNetworkFetchCount += 1;
    throw new Error("filter path must not hydrate");
  },
  renderClients() {
    ctx.clientsCrmNetworkFetchCount += 1;
    throw new Error("filter path must not refetch via renderClients");
  },
  renderClientsListContents(box) {
    ctx.lastPainted = ctx.getFilteredClients();
    box.innerHTML = ctx.lastPainted.map((c) => c.key).join(",");
    ctx.syncClientsApprovalFilterUi();
  },
  syncAdminPendingClientsUi() {},
  getAllClientsForActiveBusiness() {
    return mockClients.slice();
  },
  getClientApprovalStatus(client) {
    return client.status;
  },
  clientMatchesCustomerSearch(client, query) {
    return String(client.name || "").toLowerCase().includes(String(query || "").toLowerCase());
  },
  lastPainted: null
};

vm.createContext(ctx);
vm.runInContext(
  [
    extractFunction(html, "getCanonicalClientsApprovalFilter"),
    extractFunction(html, "syncClientsApprovalFilterUi"),
    extractFunction(html, "scrollClientsApprovalFilterIntoView"),
    extractFunction(html, "paintClientsListFromMemory"),
    extractFunction(html, "onClientsSearchInput"),
    extractFunction(html, "setClientsApprovalFilter"),
    extractFunction(html, "getFilteredClients")
  ].join("\n"),
  ctx
);

assert(ctx.clientsApprovalFilter === "all", "1 runtime All selected by default");
ctx.setClientsApprovalFilter("pending");
assert(ctx.clientsApprovalFilter === "pending", "2 tapping Pending changes canonical state");
assert(chips.find((c) => c.getAttribute("data-clients-approval-filter") === "pending").classList.contains("clients-approval-filter--active"), "3 Pending receives selected class");
assert(!chips.find((c) => c.getAttribute("data-clients-approval-filter") === "all").classList.contains("clients-approval-filter--active"), "4 previous chip loses selected state");
assert(ctx.lastPainted.map((c) => c.key).join(",") === "p", "5 filtered records change to pending");
assert(ctx.clientsCrmNetworkFetchCount === 0, "6 filtering does not trigger data fetch");

searchEl.value = "da";
ctx.setClientsApprovalFilter("all");
assert(searchEl.value === "da", "8 filter change does not erase search");
assert(ctx.lastPainted.map((c) => c.key).join(",") === "d", "8 search + All compose");
ctx.setClientsApprovalFilter("pending");
assert(searchEl.value === "da", "8 search survives Pending");
assert(ctx.lastPainted.length === 0, "8 search + Pending compose");
ctx.setClientsApprovalFilter("approved");
assert(ctx.lastPainted.map((c) => c.key).join(",") === "d", "8 search + Approved compose");
ctx.setClientsApprovalFilter("rejected");
assert(ctx.lastPainted.length === 0, "8 search + Rejected compose");

chips.forEach((c) => c.classList.remove("clients-approval-filter--active"));
ctx.paintClientsListFromMemory();
assert(
  chips.find((c) => c.getAttribute("data-clients-approval-filter") === "rejected").classList.contains("clients-approval-filter--active"),
  "7 selected state survives rerender"
);
assert(ctx.clientsCrmNetworkFetchCount === 0, "6 rerender paint stays local");

console.log("business-customers-crm-ui: all contract checks passed");
