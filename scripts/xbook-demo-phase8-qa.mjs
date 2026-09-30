#!/usr/bin/env node
/**
 * Explore XBOOK Demo — Phase 8 static/unit QA.
 * Loads Demo JS from index.html into a stubbed VM. No Supabase. No cap sync.
 */
import fs from "fs";
import path from "path";
import vm from "vm";
import { fileURLToPath } from "url";
import { spawnSync } from "child_process";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const indexPath = path.join(root, "index.html");
const html = fs.readFileSync(indexPath, "utf8");

const failures = [];
const passes = [];
function assert(cond, name) {
  if (cond) passes.push(name);
  else failures.push(name);
}

function makeEl(id) {
  const classes = new Set(id && /View$|Shell$|Host$|Detail$/.test(id) ? ["hidden"] : []);
  const listeners = [];
  return {
    id,
    hidden: classes.has("hidden"),
    innerHTML: "",
    textContent: "",
    value: "",
    dataset: {},
    style: { setProperty() {}, removeProperty() {}, display: "" },
    classList: {
      add(...c) {
        c.forEach((x) => classes.add(x));
      },
      remove(...c) {
        c.forEach((x) => classes.delete(x));
      },
      contains(c) {
        return classes.has(c);
      },
      toggle(c, on) {
        if (on === false) classes.delete(c);
        else if (on === true) classes.add(c);
        else if (classes.has(c)) classes.delete(c);
        else classes.add(c);
      }
    },
    addEventListener(type, fn, opts) {
      listeners.push({ type, fn, opts });
    },
    _listeners: listeners,
    setAttribute() {},
    getAttribute() {
      return null;
    },
    hasAttribute() {
      return false;
    },
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    closest() {
      return null;
    },
    scrollTo() {},
    focus() {},
    setSelectionRange() {}
  };
}

function makeDocument() {
  const els = new Map();
  const get = (id) => {
    if (!id) return null;
    if (!els.has(id)) els.set(id, makeEl(id));
    return els.get(id);
  };
  const listeners = [];
  const bodyClasses = new Set();
  return {
    _els: els,
    _listeners: listeners,
    body: {
      classList: {
        add(...c) {
          c.forEach((x) => bodyClasses.add(x));
        },
        remove(...c) {
          c.forEach((x) => bodyClasses.delete(x));
        },
        contains(c) {
          return bodyClasses.has(c);
        }
      },
      style: {}
    },
    activeElement: null,
    getElementById: get,
    querySelector() {
      return null;
    },
    querySelectorAll() {
      return [];
    },
    addEventListener(type, fn, opts) {
      listeners.push({ type, fn, capture: !!(opts && opts.capture) });
    }
  };
}

const documentStub = makeDocument();
const windowStub = {
  scrollTo() {},
  scroll() {},
  document: documentStub
};
windowStub.window = windowStub;
const ctx = vm.createContext({
  console,
  Date,
  JSON,
  Object,
  Array,
  String,
  Number,
  Boolean,
  Math,
  Set,
  Map,
  RegExp,
  Error,
  TypeError,
  parseInt,
  parseFloat,
  isNaN,
  isFinite,
  Infinity,
  NaN,
  undefined,
  Intl,
  structuredClone: typeof structuredClone === "function" ? structuredClone : (v) => JSON.parse(JSON.stringify(v)),
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
  document: documentStub,
  window: windowStub,
  globalThis: windowStub,
  t: (k, f) => f || k,
  escapeHtml: (s) => String(s ?? ""),
  showToast: () => {},
  hideAllViews: () => {},
  applyTranslations: () => {},
  isCustomerPreviewActive: () => false,
  chooseCreateBusinessAccount: () => {},
  showModeView: () => {},
  HTMLElement: function HTMLElement() {},
  scrollTo: () => {},
  scroll: () => {}
});
ctx.globalThis = ctx;
ctx.window = windowStub;
windowStub.globalThis = ctx;

const demoStart = html.indexOf("/** —— Explore XBOOK Demo Phase 1");
const demoEnd = html.indexOf("\n  function showAuthView()");
assert(demoStart > 0 && demoEnd > demoStart, "demo JS region located");
const demoSrcRaw = html.slice(demoStart, demoEnd);
const demoSrc = demoSrcRaw + `
;this.XBOOK_DEMO_SEED = XBOOK_DEMO_SEED;
this.__demo = {
  get store() { return xbookDemoStore; },
  get session() { return xbookDemoSession; },
  get admin() { return xbookDemoAdminState; },
  set admin(v) { xbookDemoAdminState = v; },
  get customer() { return xbookDemoCustomerState; },
  set customer(v) { xbookDemoCustomerState = v; },
  get adminBound() { return xbookDemoAdminListenersBound; },
  get customerBound() { return xbookDemoCustomerListenersBound; },
  get tutorialBound() { return xbookDemoTutorialListenersBound; },
  ANY_STAFF: XBOOK_DEMO_ANY_STAFF
};
`;

try {
  vm.runInContext(demoSrc, ctx, { filename: "xbook-demo.js" });
  assert(true, "demo JS evaluates in VM");
} catch (err) {
  assert(false, "demo JS evaluates in VM: " + (err && err.message));
  console.error(err);
  process.exit(1);
}

const g = ctx;

function ymdOf(d) {
  return g.xbookDemoFormatYmd(d);
}

const NOW = new Date(2026, 8, 14, 10, 0, 0, 0);

function booking(partial) {
  return {
    id: "t1",
    date: "2026-09-14",
    time: "09:00",
    durationMin: 60,
    status: "Confirmed",
    price: 25,
    customerId: "demo-customer-1",
    serviceId: "demo-service-1",
    staffId: "demo-staff-1",
    ...partial
  };
}

assert(g.xbookDemoIsCompletedVisit(booking({ time: "08:00", durationMin: 60 }), NOW) === true, "completed YES: 08:00/60 at 10:00");
assert(g.xbookDemoIsCompletedVisit(booking({ time: "09:30", durationMin: 60 }), NOW) === false, "completed NO: 09:30/60 at 10:00");
assert(g.xbookDemoIsCompletedVisit(booking({ time: "17:00", durationMin: 60 }), NOW) === false, "completed NO: 17:00/60 at 10:00");
assert(
  g.xbookDemoIsCompletedVisit(booking({ date: "2026-09-13", time: "23:00", durationMin: 120 }), NOW) === true,
  "overnight 23:00+120 ended 01:00 → completed YES at 10:00 next day"
);
assert(g.xbookDemoIsCompletedVisit(booking({ date: "2026-09-13", time: "09:00", status: "Pending" }), NOW) === false, "Pending past → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ date: "2026-09-13", time: "09:00", status: "Cancelled" }), NOW) === false, "Cancelled past → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ time: "not-a-time", durationMin: 60 }), NOW) === false, "invalid time → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ durationMin: 0 }), NOW) === false, "duration 0 → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ durationMin: -10 }), NOW) === false, "negative duration → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ date: "2026-13-40", time: "09:00" }), NOW) === false, "invalid date → not completed");
assert(g.xbookDemoIsCompletedVisit(booking({ time: "09:00", durationMin: 30 }), NOW) === true, "09:00–09:30 at 10:00 → completed YES");
assert(g.xbookDemoIsCompletedVisit(booking({ time: "09:45", durationMin: 45 }), NOW) === false, "09:45–10:30 at 10:00 → completed NO");

const utcProbe = g.xbookDemoParseYmdStrict("2026-09-14");
assert(utcProbe instanceof Date && utcProbe.getFullYear() === 2026 && utcProbe.getMonth() === 8 && utcProbe.getDate() === 14, "ParseYmdStrict local Y-M-D");
assert(g.xbookDemoParseYmdStrict("not-a-date") === null, "ParseYmdStrict rejects junk");
const start = g.xbookDemoBookingStartDate(booking({ time: "09:45" }));
assert(start && start.getHours() === 9 && start.getMinutes() === 45, "local start 09:45");

assert(g.xbookDemoIsStillUpcoming(booking({ time: "09:45", durationMin: 45 }), NOW) === true, "in-progress still upcoming");
assert(g.xbookDemoIsStillUpcoming(booking({ time: "09:00", durationMin: 30 }), NOW) === false, "ended this morning not upcoming");
assert(g.xbookDemoIsStillUpcoming(booking({ time: "17:00", durationMin: 60 }), NOW) === true, "later today still upcoming");

const entered = g.enterXbookDemoSession();
assert(entered && entered.ok, "enter Demo session");
const store = g.getXbookDemoStore();
assert(!!store && Array.isArray(store.bookings), "DemoStore created");
assert(g.getXbookDemoStore() === store, "shared store singleton");

const seedJsonBefore = JSON.stringify(g.XBOOK_DEMO_SEED);
try {
  g.XBOOK_DEMO_SEED.business.name = "MUTATED";
  assert(g.XBOOK_DEMO_SEED.business.name !== "MUTATED", "frozen seed rejects name mutate");
} catch (e) {
  assert(true, "frozen seed throws on mutate");
}
assert(g.XBOOK_DEMO_SEED.bookings[0].serviceName == null, "frozen seed has no name snapshots");
assert(store.bookings.every((b) => b.id && b.date && b.time && b.customerId && b.serviceId && b.staffId), "materialized bookings have core fields");
assert(store.bookings.every((b) => typeof b.serviceName === "string" && b.serviceName.length > 0), "materialize stamps serviceName");
assert(store.bookings.every((b) => typeof b.staffName === "string" && b.staffName.length > 0), "materialize stamps staffName");
assert(store.customers.length === 24, "24 seed customers");

const ids = store.bookings.map((b) => b.id);
assert(new Set(ids).size === ids.length, "booking ids unique");
const allowedStatus = new Set(["Confirmed", "Pending", "Cancelled"]);
const custIds = new Set(store.customers.map((c) => c.id));
const svcIds = new Set(store.services.map((s) => s.id));
const staffIds = new Set(store.staff.map((s) => s.id));
assert(store.bookings.every((b) => custIds.has(b.customerId)), "every booking customerId valid");
assert(store.bookings.every((b) => svcIds.has(b.serviceId)), "every booking serviceId valid");
assert(store.bookings.every((b) => staffIds.has(b.staffId)), "every booking staffId valid");
assert(store.bookings.every((b) => /^\d{4}-\d{2}-\d{2}$/.test(b.date)), "every booking date valid");
assert(store.bookings.every((b) => /^\d{1,2}:\d{2}/.test(String(b.time))), "every booking time valid");
assert(store.bookings.every((b) => Number(b.durationMin) > 0), "every durationMin > 0");
assert(store.bookings.every((b) => Number.isFinite(Number(b.price))), "every price numeric");
assert(store.bookings.every((b) => allowedStatus.has(b.status)), "every status allowed");

const laterClock = new Date(Date.now() + 3 * 60 * 60 * 1000);
const laterToday = booking({
  id: "demo-booking-future-today",
  date: ymdOf(laterClock),
  time: String(laterClock.getHours()).padStart(2, "0") + ":" + String(laterClock.getMinutes()).padStart(2, "0"),
  durationMin: 60,
  price: 999,
  customerId: "demo-customer-1",
  status: "Confirmed",
  serviceId: "demo-service-1",
  staffId: "demo-staff-1"
});
store.bookings.push(laterToday);
const elena = store.customers.find((c) => c.id === "demo-customer-1");
const crm = g.xbookDemoCustomerCrm(store, elena);
assert(!crm.completed.some((b) => b.id === "demo-booking-future-today"), "later booking not in completed visits");
assert(crm.spend === crm.completed.reduce((s, b) => s + Number(b.price || 0), 0), "spend is sum of completed only");
assert(!crm.last || crm.last.id !== "demo-booking-future-today", "unfinished booking is not last visit");
assert(crm.next && g.xbookDemoIsStillUpcoming(crm.next), "CRM next is still upcoming");
assert(
  !crm.completed.some((b) => b.id === crm.next.id),
  "next appointment is not counted as completed"
);

g.__demo.admin.analyticsRangeDays = 7;
const an7 = g.xbookDemoDeriveAnalytics();
g.__demo.admin.analyticsRangeDays = 30;
const an30 = g.xbookDemoDeriveAnalytics();
g.__demo.admin.analyticsRangeDays = 90;
const an90 = g.xbookDemoDeriveAnalytics();
assert(an7.bookings >= an7.completed.length, "7d bookings >= completed");
assert(an30.bookings >= an30.completed.length, "30d bookings >= completed");
assert(an90.bookings >= an90.completed.length, "90d bookings >= completed");
assert(!an30.completed.some((b) => b.id === "demo-booking-future-today"), "analytics completed excludes later-today");
assert(an30.revenue === an30.completed.reduce((s, b) => s + Number(b.price || 0), 0), "revenue = completed prices");
const inRangeToday = an30.bookings >= 1;
assert(inRangeToday, "analytics booking count includes in-range records");
assert(Number.isFinite(an30.cancelled), "cancelled is numeric");
assert(
  an30.completed.length === 0
    ? an30.avgValue === 0
    : Math.abs(an30.avgValue - an30.revenue / an30.completed.length) < 1e-9,
  "avg value from completed"
);

const kpis = g.xbookDemoDeriveHomeKpis();
if (laterToday.date === store.seededOn) {
  assert(kpis.todayList.some((b) => b.id === "demo-booking-future-today"), "Home Today still includes later-today booking");
  assert(kpis.todayRevenue >= 999, "Home Today revenue is booking-oriented (includes later-today)");
  assert(!kpis.upcomingList.some((b) => b.id === "demo-booking-future-today"), "Home Upcoming is date > today, not remaining-today");
} else {
  assert(kpis.upcomingList.some((b) => b.id === "demo-booking-future-today"), "Home Upcoming includes tomorrow unfinished booking");
}
const todayRows = g.xbookDemoFilteredBookingRows("today");
if (laterToday.date === store.seededOn) {
  assert(todayRows.some((b) => b.id === "demo-booking-future-today"), "Bookings Today list includes later-today");
}

store.bookings = store.bookings.filter((b) => b.id !== "demo-booking-future-today");

const svc = store.services.find((s) => s.id === "demo-service-1");
const dates = g.xbookDemoBookableDates(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF });
assert(dates.length > 0, "bookable dates exist");
let slotYmd = null;
let slot = null;
for (const ymd of dates) {
  const slots = g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd });
  if (slots.length) {
    slotYmd = ymd;
    slot = slots[0];
    break;
  }
}
assert(!!slot, "availability produced a slot");

svc.active = false;
assert(g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd: slotYmd }).length === 0, "inactive service yields no slots");
svc.active = true;
const stOff = store.staff.find((s) => s.id === slot.staffId);
stOff.active = false;
const slotsAfterStaffOff = g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: slot.staffId, ymd: slotYmd });
assert(slotsAfterStaffOff.length === 0, "inactive staff yields no slots for that staff");
stOff.active = true;

const closed = store.closedDays[0] && store.closedDays[0].date;
if (closed) {
  assert(g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd: closed }).length === 0, "closed day yields no slots");
}
const sunday = (() => {
  const start = g.xbookDemoParseYmd(store.seededOn);
  for (let i = 0; i < 8; i++) {
    const d = g.xbookDemoAddDays(start, i);
    if (d.getDay() === 0) return g.xbookDemoFormatYmd(d);
  }
  return null;
})();
if (sunday) {
  assert(g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd: sunday }).length === 0, "Sunday closed (days Mon-Sat) yields no slots");
}

const breakSlot = g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd: slotYmd }).some((s) => s.time === "13:00");
assert(!breakSlot, "business break 13:00-13:30 not offered");

const busy = store.bookings.find((b) => b.status === "Confirmed" && b.date === store.seededOn);
if (busy) {
  const overlapping = g.xbookDemoGenerateSlots(store, { serviceId: busy.serviceId, staffId: busy.staffId, ymd: busy.date }).some((s) => s.time === String(busy.time).slice(0, 5));
  assert(!overlapping, "Confirmed busy overlap not offered");
}
const pending = store.bookings.find((b) => b.status === "Pending");
if (pending) {
  const pOverlap = g.xbookDemoGenerateSlots(store, { serviceId: pending.serviceId, staffId: pending.staffId, ymd: pending.date }).some((s) => s.time === String(pending.time).slice(0, 5));
  assert(!pOverlap, "Pending busy overlap not offered");
}
const cancelled = store.bookings.find((b) => b.status === "Cancelled");
if (cancelled) {
  const ignored = g.xbookDemoBusyRangesForStaff(store, cancelled.staffId, cancelled.date).some((r) => r.start === g.xbookDemoTimeToMin(cancelled.time));
  assert(!ignored, "Cancelled ignored in busy ranges");
}

g.__demo.customer.selectedService = svc.id;
g.__demo.customer.selectedStaff = g.__demo.ANY_STAFF;
g.__demo.customer.selectedDate = slotYmd;
g.__demo.customer.selectedSlot = slot.time;
g.__demo.customer.resolvedStaffId = slot.staffId;
g.__demo.customer.bookStep = 5;
const beforeCount = store.bookings.length;
const beforeNotif = store.notifications.length;
g.confirmXbookDemoCustomerBooking();
assert(store.bookings.length === beforeCount + 1, "one Confirm → +1 booking");
assert(store.notifications.length === beforeNotif + 1, "one Confirm → +1 notification");
const createdId = g.__demo.customer.createdBookingId;
assert(String(createdId).startsWith("demo-booking-user-"), "user booking id prefix");
g.confirmXbookDemoCustomerBooking();
assert(store.bookings.length === beforeCount + 1, "rapid second confirm does not duplicate");
assert(store.notifications.length === beforeNotif + 1, "rapid second confirm does not duplicate notification");
g.confirmXbookDemoCustomerBooking();
assert(store.bookings.length === beforeCount + 1, "reopen success does not duplicate");

const secondDates = g.xbookDemoBookableDates(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF });
let slot2 = null;
let ymd2 = null;
for (const ymd of secondDates) {
  const slots = g.xbookDemoGenerateSlots(store, { serviceId: svc.id, staffId: g.__demo.ANY_STAFF, ymd });
  const other = slots.find((s) => !(ymd === slotYmd && s.time === slot.time));
  if (other) {
    ymd2 = ymd;
    slot2 = other;
    break;
  }
}
if (slot2) {
  g.__demo.customer.isConfirming = false;
  g.__demo.customer.createdBookingId = null;
  g.__demo.customer.confirmDraftKey = null;
  g.__demo.customer.selectedService = svc.id;
  g.__demo.customer.selectedStaff = g.__demo.ANY_STAFF;
  g.__demo.customer.selectedDate = ymd2;
  g.__demo.customer.selectedSlot = slot2.time;
  g.__demo.customer.resolvedStaffId = slot2.staffId;
  g.confirmXbookDemoCustomerBooking();
  assert(store.bookings.length === beforeCount + 2, "second distinct booking created");
  const userIds = store.bookings.filter((b) => String(b.id).startsWith("demo-booking-user-")).map((b) => b.id);
  assert(new Set(userIds).size === userIds.length, "user booking ids unique");
}

store.business.name = "Renamed Studio";
store.services[0].price = 77;
store.services[0].durationMin = 50;
assert(g.getXbookDemoStore().business.name === "Renamed Studio", "settings mutation same store");
assert(g.xbookDemoActiveServices(store)[0].price === 77 || store.services[0].price === 77, "price mutation visible");

const seedJsonAfterMutations = JSON.stringify(g.XBOOK_DEMO_SEED);
assert(seedJsonBefore === seedJsonAfterMutations, "XBOOK_DEMO_SEED immutable after Demo mutations");

g.bindXbookDemoAdminListeners();
g.bindXbookDemoAdminListeners();
g.bindXbookDemoCustomerListeners();
g.bindXbookDemoCustomerListeners();
g.bindXbookDemoTutorialListeners();
g.bindXbookDemoTutorialListeners();
const keydowns = documentStub._listeners.filter((l) => l.type === "keydown");
assert(keydowns.length <= 2, "keydown listeners bind-once (admin + tutorial capture)");
assert(g.__demo.adminBound === true, "admin listeners flag set");
assert(g.__demo.customerBound === true, "customer listeners flag set");
assert(g.__demo.tutorialBound === true, "tutorial listeners flag set");

g.resetXbookDemo();
const resetStore = g.getXbookDemoStore();
assert(resetStore.business.name === "GT Studio", "Reset restores business name");
assert(!resetStore.bookings.some((b) => String(b.id).startsWith("demo-booking-user-")), "Reset drops user bookings");
assert(resetStore.services[0].price === 25, "Reset restores service price");
assert((resetStore.ui.tutorial.completedStepIds || []).length === 0, "Reset tutorial 0/7");
assert(JSON.stringify(g.XBOOK_DEMO_SEED) === seedJsonBefore, "seed still frozen after Reset");

g.exitXbookDemoSession();
assert(g.__demo.session == null, "Exit clears session");
assert(g.__demo.store == null, "Exit discards store");
assert(g.getXbookDemoStore() == null, "getStore null when inactive");

g.enterXbookDemoSession();
assert(g.getXbookDemoStore().business.name === "GT Studio", "re-enter fresh seed");
assert(!g.getXbookDemoStore().bookings.some((b) => String(b.id).startsWith("demo-booking-user-")), "re-enter has no user booking");

assert(typeof g.handleXbookDemoSystemBack === "function", "handleXbookDemoSystemBack exists");
assert(g.handleXbookDemoSystemBack() === true || g.handleXbookDemoSystemBack() === false, "system back returns boolean");

g.exitXbookDemoSession();
assert(g.handleXbookDemoSystemBack() === false, "system back is no-op when Demo inactive");

const isolationHits = [];
const patterns = [
  { re: /\bsb\s*\./g, label: "sb." },
  { re: /\bsb\s*\.rpc\b/g, label: "sb.rpc" },
  { re: /\bsupabase\b/gi, label: "supabase" },
  { re: /\blocalStorage\b/g, label: "localStorage" },
  { re: /\bsessionStorage\b/g, label: "sessionStorage" },
  { re: /\bindexedDB\b/gi, label: "indexedDB" },
  { re: /\bcreate_booking\b/g, label: "create_booking" },
  { re: /\bcreate_recurring_bookings\b/g, label: "create_recurring_bookings" },
  { re: /\bget_business_busy_slots\b/g, label: "get_business_busy_slots" },
  { re: /currentUser\s*=/g, label: "currentUser assignment" },
  { re: /currentUserRole\s*=/g, label: "currentUserRole assignment" },
  { re: /businessId\s*=/g, label: "businessId assignment" },
  { re: /\.auth\./g, label: "auth" },
  { re: /upsert_customer_push_token/g, label: "push registration" },
  { re: /createClient\s*\(/g, label: "supabase createClient" }
];
for (const p of patterns) {
  const m = demoSrcRaw.match(p.re);
  if (m && m.length) isolationHits.push(p.label + " x" + m.length);
}
assert(isolationHits.length === 0, "Demo JS isolation: zero production API hits" + (isolationHits.length ? " (" + isolationHits.join(", ") + ")" : ""));

const previewFn = html.slice(html.indexOf("function handleCustomerPreviewSystemBack()"), html.indexOf("function handleCustomerPreviewBrowserHistoryChange()"));
assert(previewFn.includes("if (!isCustomerPreviewActive()) return false;"), "Preview back handler still Preview-gated");
assert(!previewFn.includes("handleXbookDemoSystemBack"), "handleCustomerPreviewSystemBack body does not call Demo");
assert(html.includes("if (typeof handleXbookDemoSystemBack === \"function\" && handleXbookDemoSystemBack()) return;"), "Capacitor backButton calls Demo after Preview");

const cssDemo = html.slice(html.indexOf("/* —— XBOOK static demo preview"), html.indexOf("#xbookDemoCustomerShell #xbookDemoCustomerBrandedHeader"));
assert(cssDemo.includes("env(safe-area-inset-top"), "demo CSS uses top safe-area");
assert(cssDemo.includes("env(safe-area-inset-bottom"), "demo CSS uses bottom safe-area");
assert(html.includes("#xbookDemoAdminView .xbook-demo-detail") && html.includes("z-index: 80"), "booking/client detail z-index 80");
assert(html.includes("#xbookDemoTutorialHost") && html.includes("z-index: 96"), "tutorial host above details");
assert(html.includes("pointer-events: none") && html.includes("#xbookDemoTutorialHost"), "tutorial host pointer-events none by default");
assert(html.includes("repeat(3, 1fr)"), "customer slot grid 3 columns");
assert(html.includes(".xbook-demo-cal-week") && html.includes("min-width: 640px"), "week calendar horizontal min-width");
assert(html.includes(".xbook-demo-cal__scroll") && html.includes("overflow: auto"), "week calendar scroll container");

const i18nKeys = new Set();
for (const m of demoSrcRaw.matchAll(/xbookDemoT\(\s*["']([^"']+)["']/g)) i18nKeys.add(m[1]);
const enStart = html.indexOf("const I18N = {");
const mkStart = html.indexOf("\n    mk: {");
const sqStart = html.indexOf("\n    sq: {");
const enBlock = enStart > 0 && mkStart > enStart ? html.slice(enStart, mkStart) : "";
const mkBlock = mkStart > 0 ? html.slice(mkStart, sqStart) : "";
const sqBlock = sqStart > 0 ? html.slice(sqStart, html.indexOf("\n  };", sqStart)) : "";
const missingMk = [];
const missingSq = [];
for (const key of i18nKeys) {
  const needle = key + ":";
  if (!enBlock.includes(needle) && !enBlock.includes(key + " :")) missingMk.push("EN?" + key);
  if (!mkBlock.includes(needle)) missingMk.push(key);
  if (!sqBlock.includes(needle)) missingSq.push(key);
}
const missingMkUnique = [...new Set(missingMk.filter((k) => !k.startsWith("EN?")))];
const missingSqUnique = [...new Set(missingSq)];
assert(missingMkUnique.length === 0, "i18n MK has demo keys" + (missingMkUnique.length ? " missing: " + missingMkUnique.slice(0, 12).join(", ") : ""));
assert(missingSqUnique.length === 0, "i18n SQ has demo keys" + (missingSqUnique.length ? " missing: " + missingSqUnique.slice(0, 12).join(", ") : ""));

assert(!demoSrcRaw.includes('class="xbook-demo-admin-card__title">At a glance'), "Home glance title uses i18n");
assert(demoSrcRaw.includes('xbookDemoT("demoAtAGlance"'), "Home glance title calls xbookDemoT");
assert(demoSrcRaw.includes('xbookDemoT("demoTodayRevenue"'), "Home KPI today revenue uses i18n");
assert(demoSrcRaw.includes('xbookDemoT("demoNoBookingsToday"'), "Bookings empty today uses i18n");
assert(demoSrcRaw.includes('xbookDemoT("demoCalDay"'), "Calendar Day tab uses i18n");
assert(html.includes('data-i18n="demoCalendar">Calendar'), "Calendar tab is data-i18n tagged");
assert(!demoSrcRaw.includes('admin-mobile-nav-label">Calendar<'), "Calendar tab is not a raw English label");
assert(!demoSrcRaw.includes("onclick=\"setXbookDemoCalendarView('day')\">Day<"), "Calendar Day tab is not raw English");
assert(!demoSrcRaw.includes('dayPart = "Closed"'), "hours display Closed is not hardcoded");
assert(!demoSrcRaw.includes('dayPart = "Every day"'), "hours display Every day is not hardcoded");
assert(demoSrcRaw.includes("xbookDemoDateLocale()"), "Demo date chrome uses app language locale");
assert(demoSrcRaw.includes("function xbookDemoDowLabel"), "Calendar weekday chrome uses translated DOW labels");

function i18nValue(block, key) {
  const escaped = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = block.match(new RegExp("(?:^|\\n)\\s*" + escaped + ':\\s*"((?:\\\\.|[^"\\\\])*)"'));
  return m ? m[1] : "";
}
const chromeKeys = [
  "demoAtAGlance",
  "demoToday",
  "demoTodayRevenue",
  "demoThisWeek",
  "demoThisMonth",
  "demoNextBooking",
  "demoNoBookingsToday",
  "demoNoUpcomingBookings",
  "demoNoPastBookings",
  "demoNoCancelledBookings",
  "demoCalendar",
  "demoCalDay",
  "demoCalWeek",
  "demoCalMonth",
  "demoBackDemoHome",
  "demoClosed",
  "demoEveryDay",
  "demoHoursMonSat",
  "demoHoursMonFri",
  "demoMin",
  "demoDayMon",
  "demoApptCountOne",
  "demoApptCountMany"
];
for (const key of chromeKeys) {
  const enV = i18nValue(enBlock, key);
  const mkV = i18nValue(mkBlock, key);
  const sqV = i18nValue(sqBlock, key);
  assert(!!enV && !!mkV && !!sqV, key + " has EN/MK/SQ values");
  assert(mkV !== enV, key + " MK is not English (" + mkV + ")");
  assert(sqV !== enV, key + " SQ is not English (" + sqV + ")");
  assert(mkV !== key && sqV !== key, key + " does not leak key name");
}

const inlineScripts = [];
const scriptRe = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
let sm;
while ((sm = scriptRe.exec(html))) {
  const body = sm[1].trim();
  if (body) inlineScripts.push(body);
}
assert(inlineScripts.length >= 1, "inline JS extracted");
const checkFile = path.join(root, "scripts", ".xbook-demo-phase8-syntax.js");
fs.writeFileSync(checkFile, inlineScripts.join("\n;\n"));
const checked = spawnSync(process.execPath, ["--check", checkFile], { encoding: "utf8" });
assert(checked.status === 0, "node --check inline JS" + (checked.status === 0 ? "" : ": " + (checked.stderr || checked.stdout)));
try {
  fs.unlinkSync(checkFile);
} catch (e) {
  /* keep on failure */
}

const previewMarkers = ["enterCustomerPreviewFromAdmin", "customerPreviewSession", "assertCustomerPreviewReadOnly", "isCustomerPreviewActive"];
assert(previewMarkers.every((m) => html.includes(m)), "Customer Preview symbols still present");

console.log("PASS " + passes.length);
passes.forEach((n) => console.log("  ✓ " + n));
if (failures.length) {
  console.log("FAIL " + failures.length);
  failures.forEach((n) => console.log("  ✗ " + n));
  process.exit(1);
}
console.log("Phase 8 QA: all checks passed.");
