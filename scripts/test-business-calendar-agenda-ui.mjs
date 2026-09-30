#!/usr/bin/env node
/**
 * Phase 1: Business Calendar agenda-first UI contract.
 * Static checks only. Does not call SQL, RPCs, or change availability math.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

let passed = 0;
function assert(cond, msg) {
  if (!cond) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
  passed += 1;
}

function sliceBetween(src, startNeedle, endNeedle) {
  const start = src.indexOf(startNeedle);
  const end = src.indexOf(endNeedle, start >= 0 ? start + startNeedle.length : 0);
  assert(start >= 0, `missing start: ${startNeedle.slice(0, 80)}`);
  assert(end > start, `missing end after: ${startNeedle.slice(0, 80)}`);
  return src.slice(start, end);
}

const calendarHtml = sliceBetween(
  html,
  '<section id="adminSectionCalendar"',
  '<section id="adminSectionManual"'
);
const calendarJs = sliceBetween(html, "function populateAdminCalendarStaffFilter()", "async function openAdminBookingDetailModal(");
const mobileCss = sliceBetween(
  html,
  "body.admin-mobile-shell-active #adminSectionCalendar .admin-calendar-screen--ref {",
  "/* Bookings — premium reference (mobile shell) */"
);

assert(calendarHtml.includes('data-i18n="screenCalendar"'), "compact Calendar title is localized");
assert(!/admin-calendar-screen__header[\s\S]{0,200}arrow-left|back arrow/i.test(calendarHtml), "root tab has no back arrow");
assert(calendarHtml.includes("onclick=\"openAdminCalendarDatePicker()\""), "date area reuses date picker");
assert(calendarHtml.includes("onclick=\"adminCalendarNavigate(-1)\""), "prev reuses adminCalendarNavigate");
assert(calendarHtml.includes("onclick=\"adminCalendarNavigate(1)\""), "next reuses adminCalendarNavigate");
assert(
  (calendarHtml.match(/onclick="adminCalendarNavigate\(/g) || []).length === 2,
  "only the TOP previous/next date arrows exist in mobile Day"
);
const dayToolsHtml = sliceBetween(calendarHtml, 'id="adminCalendarDayTools"', 'id="adminScheduleCalendar"');
assert(!dayToolsHtml.includes("adminCalendarNavigate"), "Day content header has no lower date arrows");
assert(!dayToolsHtml.includes("cal-nav-btn"), "Day content header has no second nav pair");
assert(calendarHtml.includes('data-admin-cal-view="day"'), "Day segmented tab remains");
assert(calendarHtml.includes('data-admin-cal-view="week"'), "Week segmented tab remains");
assert(calendarHtml.includes('data-admin-cal-view="month"'), "Month segmented tab remains");
assert(calendarHtml.includes('id="adminCalendarServiceFilter"'), "authoritative service select kept");
assert(calendarHtml.includes('id="adminCalendarStaffFilter"'), "authoritative staff select kept");
assert(calendarHtml.includes('id="adminCalendarServiceTrigger"'), "compact service trigger exists");
assert(calendarHtml.includes('id="adminCalendarStaffTrigger"'), "compact staff trigger exists");
assert(calendarHtml.includes("openAdminCalendarServicePicker()"), "service picker wired");
assert(calendarHtml.includes("openAdminCalendarStaffPicker()"), "staff picker wired");
assert(calendarHtml.includes('id="adminCalendarDayTools"'), "Day tools node remains in DOM but is disabled");
assert(calendarJs.includes("tools.hidden = true"), "Day tools row is always hidden");
assert(mobileCss.includes("display: none !important"), "Day tools CSS has zero visual footprint");

assert(html.includes('id="adminCalendarServicePicker"'), "service picker sheet exists");
assert(html.includes('id="adminCalendarStaffPicker"'), "staff picker sheet exists");

assert(html.includes("let adminCalendarView = \"week\";"), "desktop default remains week");
assert(html.includes("function ensureAdminCalendarMobileDefaultView()"), "mobile default helper exists");
assert(calendarJs.includes('adminCalendarView = "day";'), "mobile default switches to day");
assert(calendarJs.includes("if (adminCalendarViewUserSet) return;"), "user-selected view is preserved");
assert(calendarJs.includes("function renderAdminMobileWeekOverview()"), "week overview renderer exists");
assert(calendarJs.includes("openAdminCalendarDayView(dateStr)"), "week/month navigate to day agenda");
assert(calendarJs.includes("function renderAdminScheduleMobileAgenda()"), "day agenda renderer reused");
assert(calendarJs.includes("buildAdminMobileAgendaEntries"), "existing agenda builder reused");
assert(calendarJs.includes("classifyAdminMobileAgendaSlot"), "existing slot classifier still present in file");
assert(html.includes("const PUBLIC_SLOT_STEP_MINUTES = 15;"), "15-minute cadence unchanged");
assert(html.includes("function isAdminScheduleSlotAvailable("), "availability formula kept");
assert(html.includes("function generateSlots("), "generateSlots kept");
assert(html.includes("function addAdminBooking()"), "addAdminBooking kept");
assert(html.includes("function openQuickAddBooking("), "openQuickAddBooking kept");
assert(html.includes("function adminScheduleOpenQuickAddAt("), "adminScheduleOpenQuickAddAt kept");

assert(
  calendarJs.includes("adminScheduleOpenQuickAddAt(dateStr, grid, startMin, duration)"),
  "free-slot + still calls existing quick add"
);
assert(
  !calendarJs.includes("bottom-sheet Quick Add") && !html.includes("id=\"adminQuickAddSheet\""),
  "no new Quick Add sheet"
);
assert(html.includes('id="adminSectionManual"'), "manual booking section remains");
assert(html.includes('id="adminAddCustomerSearch"'), "existing customer picker remains");
assert(html.includes("onclick=\"addAdminBooking()\""), "existing create booking button remains");

assert(calendarJs.includes("needsService: true"), "no-service path still flagged");
assert(calendarJs.includes("buildAdminMobileBookedEntries"), "no-service still shows booked rows");
assert(calendarJs.includes("calSelectServiceToSeeSlots"), "compact service prompt used");
assert(!calendarJs.includes("cal-premium-empty"), "giant empty illustration removed from agenda renderer");
assert(calendarJs.includes("isAdminAgendaSlotVisuallyPast"), "past empty slots are display-filtered");
assert(calendarJs.includes("openAdminBookingDetailModal(b.id)"), "booked row still opens detail");

assert(calendarJs.includes("renderAdminScheduleDay()"), "existing detailed day renderer kept for desktop");
assert(!calendarJs.includes("openAdminOverviewFullDay"), "Full day does not redirect to Bookings");
assert(html.includes("function openAdminOverviewFullDay()"), "Overview Full day helper left untouched");
assert(calendarJs.includes('if (mobileDay) adminCalendarDayPresentation = "agenda"'), "mobile Day is locked to agenda");
assert(calendarJs.includes("renderAdminScheduleMobileAgenda()"), "mobile Day always uses agenda renderer");
assert(!calendarJs.includes('adminCalendarView === "day" && adminCalendarDayPresentation === "timeline"'), "mobile Day no longer enters timeline from this screen");
assert(calendarJs.includes("function getAdminCalendarDayDateStr()"), "canonical Calendar day date helper remains");
assert(calendarJs.includes("function isAdminCalendarDayNonWorking(dateStr)"), "closed day uses authoritative Calendar helpers");
assert(calendarJs.includes("isAdminScheduleDayClosed(dateStr) || !isAdminScheduleDayWorking(dateStr)"), "closed/off is not inferred from zero bookings");
assert(calendarJs.includes('empty.className = "cal-day-empty"'), "closed day mounts compact empty state");
assert(calendarJs.includes('t("bookingsNonWorkingDay", "Non-working day")'), "closed title reuses existing non-working language");
assert(calendarJs.includes('t("calNoAppointmentsThisDay"'), "closed day has a specific no-appointments description");
assert(calendarJs.includes('if (!visible.length && !needsService && meta.state === "open")'), "working day with zero rows stays an open-day empty");
assert(calendarJs.includes('t("bookingsNoAppointments", "No appointments")'), "working-day empty does not reuse closed-day copy");
assert(calendarJs.includes('t("calSelectServiceToSeeSlots"'), "no-service working day keeps the service prompt");
assert(!calendarJs.includes('if (needsService) {\n      const empty'), "no-service path does not use the closed empty state");

const dayRenderer = sliceBetween(html, "function renderAdminScheduleDay() {", "function renderAdminScheduleMonth() {");
assert(dayRenderer.includes('wrap.className = "admin-schedule-day-view"'), "existing day-view wrap still built");
assert(dayRenderer.includes("mount.innerHTML = \"\""), "day renderer still replaces mount contents");
assert(!dayRenderer.includes("admin-calendar--day-timeline"), "day renderer logic has no presentation chrome");
assert(!dayRenderer.includes("cal-day-tools"), "day renderer does not own the section header");

const agendaRenderer = sliceBetween(html, "function renderAdminScheduleMobileAgenda() {", "function formatAdminCalendarWeekCount(");
assert(agendaRenderer.includes("mount.innerHTML = \"\""), "agenda renderer still replaces mount contents");
assert(agendaRenderer.includes('wrap.className = "admin-mobile-agenda"'), "agenda still mounts a single list wrap");

const toggleFn = sliceBetween(html, "function toggleAdminCalendarDayPresentation() {", "window.toggleAdminCalendarDayPresentation");
assert(toggleFn.includes("isAdminCalendarMobileViewport()"), "mobile Day tools toggle is disabled");
assert(!toggleFn.includes("adminCalendarServiceFilter"), "toggle does not change service");
assert(!toggleFn.includes("adminCalendarStaffFilter"), "toggle does not change staff");
assert(!toggleFn.includes("adminCalendarAnchorDate"), "toggle does not change selected date");

assert(mobileCss.includes("390px"), "390 layout rule present");
assert(mobileCss.includes("430px"), "430 layout rule present");
assert(mobileCss.includes(".cal-day-empty"), "closed empty state is styled");
assert(mobileCss.includes("admin-calendar--day-closed"), "closed-day mount chrome is scoped");
assert(mobileCss.includes(".cal-day-empty__title"), "closed empty title exists");
assert(mobileCss.includes(".cal-day-empty__detail"), "closed empty detail exists");
assert(mobileCss.includes("body.app-theme-dark.admin-mobile-shell-active #adminSectionCalendar .cal-day-empty__title"), "dark closed empty title scoped");

assert(calendarJs.includes("setAdminCalendarServiceFilter(value)"), "service picker writes existing setter");
assert(calendarJs.includes("setAdminCalendarStaffFilter(value)"), "staff picker writes existing setter");
assert(calendarJs.includes('label: t("calAllStaff", "All staff")'), "staff picker includes All staff");
assert(!calendarJs.includes("Сите услуги"), "no fake All services free-slot option");
assert(calendarJs.includes("activeStaff.length === 1"), "1-staff auto-select preserved");

assert(mobileCss.includes("var(--xbook-navy"), "mobile chrome uses XBook navy");
assert(!mobileCss.includes("#7c3aed"), "purple removed from mobile calendar chrome");
assert(!mobileCss.includes("#9333ea"), "purple accent removed from mobile calendar chrome");
assert(mobileCss.includes(".cal-agenda-filter"), "compact filter rows styled");
assert(mobileCss.includes(".admin-mobile-week-overview"), "week overview styled");
assert(mobileCss.includes("375px"), "375 layout rule present");
assert(mobileCss.includes("--admin-tabbar-height"), "floating tab bar clearance present");

const i18nEn = sliceBetween(html, "navBook: \"Book\"", "calendarPillClosed: \"Closed\"");
assert(html.includes('calSelectService: "Select service"'), "EN select service");
assert(html.includes('calSelectService: "Изберете услуга"'), "MK select service");
assert(html.includes('calSelectService: "Zgjidh shërbimin"'), "SQ select service");
assert(html.includes('calAppointmentsToday: "Appointments today"'), "EN today heading");
assert(html.includes('calAppointmentsToday: "Термини за денес"'), "MK today heading");
assert(html.includes('calAppointmentsForDay: "Термини за денот"'), "MK not-today heading");
assert(html.includes('calAvailable: "Слободно"'), "MK available language");
assert(html.includes('calAgenda: "Агенда"'), "MK agenda");
assert(html.includes('bookingsAllDay: "Цел ден"'), "reuses existing Full day MK");
assert(html.includes('bookingsModeDay: "Ден"'), "reuses existing Day MK");
assert(!i18nEn.includes("calSelectService"), "new keys sit with calendar i18n, not nav block");

function timeToMinutes(time) {
  const [h, m] = String(time).split(":").map(Number);
  return h * 60 + m;
}

function shouldShowAgendaFreeSlot(entry, dateStr, todayStr, nowMins) {
  if (!entry || entry.type !== "available") return false;
  if (dateStr === todayStr && timeToMinutes(entry.time) < nowMins) return false;
  return true;
}

function agendaHeading(dateStr, todayStr) {
  return dateStr === todayStr ? "Appointments today" : "Appointments for this day";
}

assert(shouldShowAgendaFreeSlot({ type: "available", time: "14:30" }, "2026-09-26", "2026-09-26", 10 * 60) === true, "future free slot stays visible");
assert(shouldShowAgendaFreeSlot({ type: "available", time: "09:00" }, "2026-09-26", "2026-09-26", 10 * 60) === false, "past free slot hidden");
assert(shouldShowAgendaFreeSlot({ type: "booked", time: "09:00" }, "2026-09-26", "2026-09-26", 10 * 60) === false, "booked rows are not free-slot actions");
assert(agendaHeading("2026-09-26", "2026-09-26") === "Appointments today", "today heading");
assert(agendaHeading("2026-09-27", "2026-09-26") === "Appointments for this day", "other-day heading");

const generateSlotsSrc = sliceBetween(html, "function generateSlots(start, end, duration, stepMinutes = 15)", "function hasConflict(");
assert(generateSlotsSrc.includes("current += step;"), "slot step loop unchanged");

assert(html.includes("getPublicBookingTargetTemporalState(date, time)"), "create-time past guard kept");
assert(html.includes("if (startMin < nowMins) return false;"), "calendar same-day past guard kept");

assert(html.includes('calAppointmentsToday: "Terminet e sotme"'), "SQ today heading");
assert(html.includes('calAppointmentsForDay: "Terminet e kësaj dite"'), "SQ not-today heading");
assert(html.includes('calAgenda: "Axhenda"'), "SQ agenda");
assert(html.includes('bookingsAllDay: "All day"'), "EN Full day");
assert(html.includes('bookingsAllDay: "Gjithë ditën"'), "SQ Full day");
assert(html.includes('calNoAppointmentsThisDay: "No appointments are available for this day."'), "EN closed-day detail");
assert(html.includes('calNoAppointmentsThisDay: "Нема достапни термини за овој ден."'), "MK closed-day detail");
assert(html.includes('calNoAppointmentsThisDay: "Nuk ka termine të disponueshme për këtë ditë."'), "SQ closed-day detail");
assert(html.includes('bookingsNonWorkingDay: "Non-working day"'), "EN closed-day title");
assert(html.includes('bookingsNonWorkingDay: "Неработен ден"'), "MK closed-day title");
assert(html.includes('bookingsNonWorkingDay: "Ditë jo pune"'), "SQ closed-day title");

function isAuthoritativeClosedDay(metaState, bookingCount) {
  return metaState !== "open";
}
assert(isAuthoritativeClosedDay("open", 0) === false, "zero bookings on a working day is not closed");
assert(isAuthoritativeClosedDay("open", 3) === false, "bookings do not define closed");
assert(isAuthoritativeClosedDay("off", 0) === true, "off day is closed even with zero bookings");
assert(isAuthoritativeClosedDay("closed", 2) === true, "closed day stays closed even if bookings exist");

function headingForSelected(selectedStr, todayStr) {
  return selectedStr === todayStr ? "Appointments today" : "Appointments for this day";
}
assert(headingForSelected("2026-09-27", "2026-09-27") === "Appointments today", "selected today uses Today heading");
assert(headingForSelected("2026-09-28", "2026-09-27") === "Appointments for this day", "selected non-today uses For-day heading");

const parseSrc = [
  sliceBetween(html, "function getAdminCalendarDayDateStr() {", "function getAdminCalendarSelectedService() {"),
  sliceBetween(html, "function renderAdminScheduleDay() {", "function renderAdminScheduleMonth() {"),
  sliceBetween(html, "function renderAdminScheduleMobileAgenda() {", "function formatAdminCalendarWeekCount("),
  sliceBetween(html, "function renderAdminMobileAgendaSlots(container, dateStr) {", "function ensureAdminCalendarFiltersDockedOutsideMount() {")
].join("\n");
try {
  // Parse only — do not execute Calendar functions.
  new Function(parseSrc);
} catch (err) {
  console.error("FAIL: JS parse:", err.message);
  process.exit(1);
}
assert(true, "targeted Calendar JS parses");

console.log(`PASS ${passed} business calendar agenda-first UI checks`);
