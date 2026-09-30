#!/usr/bin/env node
/**
 * Customer Analytics navigation contract:
 * exclusive hub / segment / detail, portal ownership, and
 * VISIBLE_ANALYTICS_CONTENT_COUNT >= 1 after every transition.
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

function extractFunction(src, name) {
  const start = src.search(new RegExp(`(?:async\\s+)?function\\s+${name}\\s*\\(`));
  assert(start >= 0, `extract ${name}`);
  const headerEnd = src.indexOf(")", start);
  assert(headerEnd > start, `extract ${name} header`);
  let depth = 0;
  let started = false;
  for (let i = headerEnd; i < src.length; i += 1) {
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

function createNode(id, classNames) {
  const node = {
    id: id || "",
    className: classNames || "",
    _classes: new Set(String(classNames || "").split(/\s+/).filter(Boolean)),
    _attrs: {},
    parentElement: null,
    children: [],
    scrollTop: 0,
    hidden: false,
    classList: {
      contains(name) {
        return node._classes.has(name);
      },
      toggle(name, on) {
        if (on) node._classes.add(name);
        else node._classes.delete(name);
        node.className = [...node._classes].join(" ");
      },
      add(name) {
        node._classes.add(name);
        node.className = [...node._classes].join(" ");
      },
      remove(name) {
        node._classes.delete(name);
        node.className = [...node._classes].join(" ");
      }
    },
    hasAttribute(name) {
      return Object.prototype.hasOwnProperty.call(node._attrs, name);
    },
    getAttribute(name) {
      return node.hasAttribute(name) ? node._attrs[name] : null;
    },
    setAttribute(name, value) {
      node._attrs[name] = value == null ? "" : String(value);
      if (name === "hidden") node.hidden = true;
    },
    removeAttribute(name) {
      delete node._attrs[name];
      if (name === "hidden") node.hidden = false;
    },
    contains(other) {
      let cur = other;
      while (cur) {
        if (cur === node) return true;
        cur = cur.parentElement;
      }
      return false;
    },
    appendChild(child) {
      if (child.parentElement) {
        const sibs = child.parentElement.children;
        const idx = sibs.indexOf(child);
        if (idx >= 0) sibs.splice(idx, 1);
      }
      child.parentElement = node;
      node.children.push(child);
      return child;
    },
    querySelector(sel) {
      const match = (n) => {
        if (sel.startsWith(".")) return n._classes.has(sel.slice(1));
        if (sel.startsWith("#")) return n.id === sel.slice(1);
        return false;
      };
      const walk = (n) => {
        for (const child of n.children) {
          if (match(child)) return child;
          const nested = walk(child);
          if (nested) return nested;
        }
        return null;
      };
      if (match(node)) return node;
      return walk(node);
    }
  };
  return node;
}

function createNavDocument() {
  const byId = new Map();
  const register = (node) => {
    if (node.id) byId.set(node.id, node);
    return node;
  };

  const ca = register(createNode("adminSectionCustomerAnalytics", "admin-section"));
  const caScreen = createNode("", "admin-performance-screen");
  const report = register(createNode("customerAnalyticsReport", "admin-ca-report"));
  const segment = register(createNode("customerAnalyticsSegmentView", ""));
  const detail = register(createNode("customerAnalyticsDetailView", ""));
  const error = register(createNode("customerAnalyticsError", "admin-analytics-error hidden"));
  const errorText = register(createNode("customerAnalyticsErrorText", ""));
  ca.appendChild(caScreen);
  caScreen.appendChild(report);
  caScreen.appendChild(error);
  error.appendChild(errorText);
  caScreen.appendChild(segment);
  caScreen.appendChild(detail);
  segment.setAttribute("hidden", "");
  detail.setAttribute("hidden", "");
  error.setAttribute("hidden", "");

  const xa = register(createNode("adminSectionCrossAnalytics", "admin-section"));
  const xaScreen = createNode("", "admin-performance-screen");
  const xaReport = register(createNode("crossAnalyticsReport", "admin-xa-report"));
  xa.appendChild(xaScreen);
  xaScreen.appendChild(xaReport);

  const document = {
    getElementById(id) {
      return byId.get(id) || null;
    },
    querySelector(sel) {
      if (sel === "#adminSectionCustomerAnalytics .admin-performance-screen") return caScreen;
      if (sel === "#adminSectionCrossAnalytics .admin-performance-screen") return xaScreen;
      if (sel.startsWith("#")) return byId.get(sel.slice(1)) || null;
      return ca.querySelector(sel) || xa.querySelector(sel);
    }
  };

  return { document, ca, xa, caScreen, xaScreen, report, segment, detail };
}

assert(html.includes("function applyCustomerAnalyticsNav(mode, opts)"), "canonical nav helper present");
assert(html.includes("function countVisibleCustomerAnalyticsContentViews("), "visible-count helper present");
assert(html.includes("function assertCustomerAnalyticsNavInvariant("), "nav invariant present");
assert(html.includes("VISIBLE_ANALYTICS_CONTENT_COUNT"), "strict invariant names the required count");
assert(html.includes("restoreCustomerAnalyticsNavSnapshot(prev)"), "failed nav restores previous view");
assert(html.includes("detail.removeAttribute(\"hidden\")"), "detail unhides before exclusive classes");
assert(html.includes("segment.removeAttribute(\"hidden\")"), "segment unhides before exclusive classes");
assert(html.includes("ca.classList.toggle(\"admin-ca-segment-open\", true)"), "segment class applied after unhide");
assert(html.includes("ca?.classList.toggle(\"admin-ca-detail-open\", detailHost === \"customer-analytics\")"), "detail class is exclusive to host");
assert(html.includes("ca?.classList.toggle(\"admin-ca-segment-open\", false)"), "opening detail clears segment-open");
assert(html.includes("portalCustomerAnalyticsDetailToCross()"), "detail adopt uses Cross portal");
assert(html.includes("restoreCustomerAnalyticsDetailHome()"), "non-Cross paths restore home");
assert(
  html.includes("if (!opened)") && html.includes("applyCustomerAnalyticsNav(\"segment\")"),
  "failed detail open fails back to segment"
);
assert(
  html.includes('id="caSegBackBtn"') && html.includes('id="caDetBackBtn"'),
  "canonical Back controls exist on segment and detail"
);
assert(
  html.includes("#adminSectionCustomerAnalytics.admin-ca-segment-open.admin-ca-detail-open #customerAnalyticsDetailView"),
  "dual-class CSS failsafe prefers detail"
);
assert(
  html.includes("#adminSectionCustomerAnalytics.admin-ca-segment-open #customerAnalyticsSegmentView") &&
    html.includes("display: flex !important"),
  "segment show beats leftover [hidden]"
);
assert(
  html.includes("#adminSectionCustomerAnalytics.admin-ca-detail-open #customerAnalyticsDetailView") &&
    html.includes("display: flex !important"),
  "detail show beats leftover [hidden]"
);

const fnNames = [
  "customerAnalyticsNavActiveHost",
  "customerAnalyticsDetailHomeScreen",
  "customerAnalyticsDetailCrossScreen",
  "isCustomerAnalyticsHubContentVisible",
  "isCustomerAnalyticsSegmentContentVisible",
  "isCustomerAnalyticsDetailContentVisible",
  "isCrossAnalyticsListContentVisible",
  "countVisibleCustomerAnalyticsContentViews",
  "assertCustomerAnalyticsNavInvariant",
  "snapshotCustomerAnalyticsNav",
  "restoreCustomerAnalyticsNavSnapshot",
  "resetCustomerAnalyticsNavScroll",
  "applyCustomerAnalyticsNav",
  "setCustomerAnalyticsSegmentOpen",
  "setCustomerAnalyticsDetailOpen",
  "portalCustomerAnalyticsDetailToCross",
  "restoreCustomerAnalyticsDetailHome"
];
const extracted = fnNames.map((name) => extractFunction(html, name)).join("\n");

function bootNav() {
  const dom = createNavDocument();
  const factory = new Function(
    "document",
    "window",
    "console",
    `let customerDetailReturnContext = null;
    let customerAnalyticsSegmentState = { open: false };
    ${extracted}
    return {
      applyCustomerAnalyticsNav,
      setCustomerAnalyticsSegmentOpen,
      setCustomerAnalyticsDetailOpen,
      countVisibleCustomerAnalyticsContentViews,
      portalCustomerAnalyticsDetailToCross,
      restoreCustomerAnalyticsDetailHome,
      setReturnContext(value) { customerDetailReturnContext = value; },
      setSegmentOpenFlag(value) { customerAnalyticsSegmentState.open = !!value; },
      getSegmentOpenFlag() { return customerAnalyticsSegmentState.open; }
    };`
  );
  const api = factory(dom.document, { __XBOOK_CA_NAV_STRICT__: true }, console);
  return { ...dom, api };
}

function visibleCount(session, host) {
  return session.api.countVisibleCustomerAnalyticsContentViews(host);
}

function assertVisible(session, host, label) {
  const count = visibleCount(session, host);
  assert(count >= 1, `${label}: VISIBLE_ANALYTICS_CONTENT_COUNT >= 1 (got ${count})`);
  return count;
}

function assertExclusive(session, label) {
  const both =
    session.ca.classList.contains("admin-ca-segment-open") &&
    session.ca.classList.contains("admin-ca-detail-open");
  assert(!both, `${label}: CA must not keep both open classes`);
}

{
  const session = bootNav();
  assertVisible(session, "customer-analytics", "hub start");
  session.api.setSegmentOpenFlag(true);
  assert(session.api.setCustomerAnalyticsSegmentOpen(true), "Customers main → Active Customers");
  assert(session.segment.hasAttribute("hidden") === false, "Active list is unhidden");
  assert(session.ca.classList.contains("admin-ca-segment-open"), "Active list uses segment-open");
  assertExclusive(session, "Active Customers");
  assertVisible(session, "customer-analytics", "Active Customers");
  session.api.setSegmentOpenFlag(false);
  assert(session.api.setCustomerAnalyticsSegmentOpen(false), "Active Customers → Back");
  assert(session.ca.classList.contains("admin-ca-segment-open") === false, "Back clears segment-open");
  assertVisible(session, "customer-analytics", "Back to Customers main from Active");
}

{
  const session = bootNav();
  session.api.setSegmentOpenFlag(true);
  assert(session.api.applyCustomerAnalyticsNav("segment"), "Customers main → New Customers");
  assertVisible(session, "customer-analytics", "New Customers");
  session.api.setSegmentOpenFlag(false);
  assert(session.api.applyCustomerAnalyticsNav("hub"), "New Customers → Back");
  assertVisible(session, "customer-analytics", "Back to Customers main from New");
}

{
  const session = bootNav();
  session.api.setSegmentOpenFlag(true);
  assert(session.api.applyCustomerAnalyticsNav("segment"), "Customers main → Returning Customers");
  assertVisible(session, "customer-analytics", "Returning Customers");
  session.api.setSegmentOpenFlag(false);
  assert(session.api.applyCustomerAnalyticsNav("hub"), "Returning Customers → Back");
  assertVisible(session, "customer-analytics", "Back to Customers main from Returning");
}

{
  const session = bootNav();
  session.api.setSegmentOpenFlag(true);
  assert(session.api.applyCustomerAnalyticsNav("segment"), "Customers main → New Customers (detail path)");
  assertVisible(session, "customer-analytics", "New list before detail");
  session.api.setReturnContext(null);
  assert(session.api.applyCustomerAnalyticsNav("detail", { host: "customer-analytics" }), "New Customers → customer detail");
  assert(session.detail.parentElement === session.caScreen, "CASE A detail stays under Customer Analytics");
  assert(session.detail.hasAttribute("hidden") === false, "CASE A detail is unhidden");
  assert(session.ca.classList.contains("admin-ca-detail-open"), "CASE A CA owns detail-open");
  assert(session.ca.classList.contains("admin-ca-segment-open") === false, "CASE A clears segment-open while detail is showing");
  assertExclusive(session, "New Customers detail");
  assertVisible(session, "customer-analytics", "New Customers → detail");
  assert(session.api.applyCustomerAnalyticsNav("segment"), "detail → Back to New Customers");
  assert(session.ca.classList.contains("admin-ca-segment-open"), "Back restores segment-open");
  assert(session.ca.classList.contains("admin-ca-detail-open") === false, "Back clears detail-open");
  assertVisible(session, "customer-analytics", "Back to New Customers");
  session.api.setSegmentOpenFlag(false);
  assert(session.api.applyCustomerAnalyticsNav("hub"), "New Customers → Back to Customers main");
  assertVisible(session, "customer-analytics", "Back to Customers main after New detail");
}

{
  const session = bootNav();
  session.api.setSegmentOpenFlag(true);
  assert(session.api.applyCustomerAnalyticsNav("segment"), "Customers main → Active Customers (detail path)");
  assertVisible(session, "customer-analytics", "Active list before detail");
  session.api.setReturnContext(null);
  assert(session.api.applyCustomerAnalyticsNav("detail", { host: "customer-analytics" }), "Active Customers → customer detail");
  assertExclusive(session, "Active Customers detail");
  assertVisible(session, "customer-analytics", "Active Customers → detail");
  assert(session.api.applyCustomerAnalyticsNav("segment"), "detail → Back to Active Customers");
  assertVisible(session, "customer-analytics", "Back to Active Customers");
  session.api.setSegmentOpenFlag(false);
  assert(session.api.applyCustomerAnalyticsNav("hub"), "Active Customers → Back to Customers main");
  assertVisible(session, "customer-analytics", "Back to Customers main after Active detail");
}

{
  const session = bootNav();
  session.api.setReturnContext({ section: "cross-analytics", scrollTop: 40 });
  assert(session.api.applyCustomerAnalyticsNav("detail", { host: "cross-analytics" }), "Advanced Analysis → customer detail");
  assert(session.detail.parentElement === session.xaScreen, "Cross portals the same detail view");
  assert(session.xa.classList.contains("admin-ca-detail-open"), "Cross owns detail-open");
  assert(session.ca.classList.contains("admin-ca-detail-open") === false, "CA does not keep detail-open during Cross");
  assert(session.ca.classList.contains("admin-ca-segment-open") === false, "CA segment-open stays off during Cross detail");
  assertVisible(session, "cross-analytics", "Advanced Analysis → detail");
  assert(session.api.applyCustomerAnalyticsNav("hub", { host: "cross-analytics" }), "detail → Back to Advanced Analysis");
  assert(session.detail.parentElement === session.caScreen, "Back unportals detail to Customer Analytics home");
  assert(session.xa.classList.contains("admin-ca-detail-open") === false, "Back clears Cross detail-open");
  assertVisible(session, "cross-analytics", "Back to Advanced Analysis");
}

{
  const session = bootNav();
  session.ca.classList.toggle("admin-ca-segment-open", true);
  session.ca.classList.toggle("admin-ca-detail-open", true);
  session.segment.setAttribute("hidden", "");
  session.detail.setAttribute("hidden", "");
  const blank = session.api.countVisibleCustomerAnalyticsContentViews("customer-analytics");
  assert(blank < 1, "legacy dual-hide + both [hidden] is an invalid blank state");
}

{
  const session = bootNav();
  session.api.setSegmentOpenFlag(true);
  session.api.applyCustomerAnalyticsNav("segment");
  session.api.setReturnContext(null);
  session.api.applyCustomerAnalyticsNav("detail", { host: "customer-analytics" });
  session.api.setReturnContext({ section: "cross-analytics" });
  session.api.applyCustomerAnalyticsNav("detail", { host: "customer-analytics" });
  assert(session.detail.parentElement === session.caScreen, "stale Cross context must not keep detail under Cross when opening from CA");
}

const checkFile = path.join(root, "scripts", ".tmp-customer-analytics-nav-syntax-check.js");
fs.writeFileSync(checkFile, extracted);
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
fs.unlinkSync(checkFile);
assert(checked.status === 0, "node --check nav helpers" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout)));

const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
assert(inlineScripts.length >= 1, "inline JS extracted");
const appCheckFile = path.join(root, "scripts", ".tmp-customer-analytics-nav-app-syntax-check.js");
fs.writeFileSync(appCheckFile, inlineScripts.join("\n;\n"));
const appChecked = spawnSync(process.execPath, ["--check", appCheckFile], { encoding: "utf8" });
try {
  fs.unlinkSync(appCheckFile);
} catch {
  /* keep on failure */
}
assert(
  appChecked.status === 0,
  "node --check index.html inline JS" + (appChecked.status === 0 ? "" : ": " + (appChecked.stderr || appChecked.stdout))
);

console.log("customer-analytics-nav: exclusive stack, portal ownership, and VISIBLE_ANALYTICS_CONTENT_COUNT passed");
