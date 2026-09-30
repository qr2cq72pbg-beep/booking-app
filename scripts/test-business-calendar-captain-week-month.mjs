#!/usr/bin/env node
/**
 * Business Calendar CAPTAIN typography + Week/Month presentation contract.
 * Static + Chrome computed-style checks. No backend / date-math changes.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");
const outDir = path.join(root, ".tmp-calendar-qa");
const shotsDir = path.join(outDir, "shots");

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

const CANONICAL_FONT = '"Work Sans", var(--font-display), sans-serif';
const calendarCss = sliceBetween(
  html,
  "/* —— Admin scheduling calendar (Day / Week / Month) —— */",
  ".admin-booking-modal {"
);
const mobileCss = sliceBetween(
  html,
  "body.admin-mobile-shell-active #adminSectionCalendar .admin-calendar-screen--ref {",
  "/* Bookings — premium reference (mobile shell) */"
);
const weekJs = sliceBetween(html, "function renderAdminMobileWeekOverview() {", "function renderAdminScheduleWeek() {");
const monthJs = sliceBetween(html, "function renderAdminScheduleMonth() {", "function renderAdminCalendar() {");

assert(calendarCss.includes(CANONICAL_FONT), "Calendar root uses canonical Work Sans/CAPTAIN stack");
assert(calendarCss.includes("#adminSectionCalendar {\n      font-family: " + CANONICAL_FONT), "font-family is applied on #adminSectionCalendar");
assert(!calendarCss.includes("@import") && !html.slice(0, 50).includes("family=Inter"), "no extra font import added for Calendar");

assert(mobileCss.includes("font-size: 22px"), "Calendar title is 22px");
assert(mobileCss.includes("font-size: 16px"), "date field / week labels use 16px");
assert(mobileCss.includes("font-size: 15px"), "segmented control is 15px");
assert(mobileCss.includes("letter-spacing: 0.06em"), "week kicker letter-spacing");

const todayWhen = sliceBetween(
  mobileCss,
  "body.admin-mobile-shell-active #adminSectionCalendar .admin-mobile-week-row--today .admin-mobile-week-row__when {",
  "body.admin-mobile-shell-active #adminSectionCalendar .admin-mobile-week-row--closed .admin-mobile-week-row__when,"
);
assert(!todayWhen.includes("font-weight: 800"), "selected/today Week day does not bump font-weight to 800");
assert(!todayWhen.includes("font-size:"), "today Week color rule does not change font-size");
assert(
  mobileCss.includes("font-size: 16px") &&
    mobileCss.includes(".admin-mobile-week-row--today .admin-mobile-week-row__when") &&
    mobileCss.includes(".admin-mobile-week-row--selected .admin-mobile-week-row__when"),
  "today/selected Week labels share the locked typography selector"
);
assert(mobileCss.includes("font-size: 14px") && mobileCss.includes(".admin-mobile-week-row__meta"), "Week status is 14px");

assert(!monthJs.includes("badge-red"), "Month renderer has no red closed pill");
assert(!monthJs.includes("calendarPillClosed"), "Month renderer has no visible Closed/Затворено copy");
assert(!monthJs.includes("getBusinessClosedDayCalendarLabel"), "Month cells do not render closed-day text");
assert(!monthJs.includes("appt"), "Month cells do not render 'appt(s)' labels");
assert(!monthJs.includes("bookingsAppointments"), "Month visible count does not append 'термини'");
assert(monthJs.includes('countEl.textContent = String(dayCount)'), "Month count is numeric/compact");
assert(monthJs.includes("admin-schedule-month-day__count"), "Month count class present");
assert(monthJs.includes("openAdminCalendarDayView(dateStr)"), "Month tap still opens Day");
assert(weekJs.includes("openAdminCalendarDayView(dateStr)"), "Week tap still opens Day");
assert(calendarCss.includes("repeat(7, minmax(0, 1fr))"), "7-column Month grid preserved");
assert(calendarCss.includes("min-height: 72px"), "Month cells match Reservations default height");
assert(calendarCss.includes("min-height: 64px"), "Month cells match Reservations phone height");
assert(calendarCss.includes("box-shadow: inset 0 -1px 0"), "Month cells use Reservations hairline boxes");
assert(calendarCss.includes("border-radius: 0"), "Month cells match Reservations radius");
assert(calendarCss.includes("min-width: 0"), "Month tracks can shrink inside 1/7");
assert(!calendarCss.includes(".badge.badge-red"), "obsolete Month closed-pill CSS removed");
assert(!calendarCss.includes("admin-schedule-month-count"), "obsolete Month 'X термини' block CSS removed");
assert(!calendarCss.includes("admin-schedule-month-day--busy"), "obsolete busy-card Month style removed");
assert(!monthJs.includes("div.style.outline"), "giant selected-day outline removed from Month JS");
assert(monthJs.includes("admin-schedule-month-day--today"), "today uses a class, not inline outline");
assert(monthJs.includes("admin-schedule-month-day--selected"), "selected uses a class");
assert(monthJs.includes("admin-schedule-month-day--closed"), "closed/non-working is a subtle class");
assert(weekJs.includes("admin-mobile-week-row--selected"), "Week selected state is class-based");

const parseSrc = [
  sliceBetween(html, "function getAdminCalendarWeekdayShortLabels() {", "function renderAdminCalendar() {"),
  sliceBetween(html, "function renderAdminMobileWeekOverview() {", "function renderAdminScheduleWeek() {"),
  sliceBetween(html, "function formatAdminCalendarWeekCount(count) {", "function renderAdminMobileWeekOverview() {")
].join("\n");
try {
  new Function(parseSrc);
} catch (err) {
  console.error("FAIL: JS parse:", err.message);
  process.exit(1);
}
assert(true, "targeted Calendar JS parses");

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const css = [...html.matchAll(/<style[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1]).join("\n");
fs.mkdirSync(shotsDir, { recursive: true });

const fixture = `<!DOCTYPE html>
<html lang="mk">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Work+Sans:wght@400;500;600;700&display=swap" rel="stylesheet" />
  <style>${css}</style>
  <style>
    html, body { margin: 0; background: #e8edf3; }
    #qa-phone {
      box-sizing: border-box;
      overflow-x: hidden;
      min-height: 100vh;
      background: var(--theme-surface-secondary, #f8f9fb);
    }
    #qa-report { position: fixed; inset: 0 auto auto 0; width: 0; height: 0; overflow: hidden; opacity: 0; }
  </style>
</head>
<body class="admin-mobile-shell-active">
  <div id="qa-phone">
  <div id="adminView">
    <section id="adminSectionCalendar" class="admin-section admin-section--active">
      <div class="admin-calendar-screen admin-calendar-screen--ref">
        <header class="admin-calendar-screen__header">
          <h2 class="admin-calendar-screen__title">Календар</h2>
          <div class="cal-toolbar-premium">
            <div class="cal-nav-row">
              <button type="button" class="cal-nav-btn"></button>
              <button type="button" class="cal-date-card">
                <span class="cal-date-card__icon"></span>
                <div class="cal-date-card__text">
                  <h3 id="adminCalendarTitle" class="cal-date-card__range">28 сеп – 4 окт 2026</h3>
                </div>
              </button>
              <button type="button" class="cal-nav-btn"></button>
            </div>
            <div class="cal-view-tabs">
              <button type="button" class="cal-view-tab">Ден</button>
              <button type="button" class="cal-view-tab admin-calendar-view-tab--active">Недела</button>
              <button type="button" class="cal-view-tab">Месец</button>
            </div>
          </div>
        </header>
        <div id="weekMount" class="qa-week">
          <div class="admin-mobile-week-overview">
            <p class="admin-mobile-week-overview__title">Недела</p>
            <div class="admin-mobile-week-overview__list">
              <button type="button" class="admin-mobile-week-row admin-mobile-week-row--today admin-mobile-week-row--selected"><span class="admin-mobile-week-row__when">пон, 28</span><span class="admin-mobile-week-row__meta admin-mobile-week-row__meta--count">5 термини</span></button>
              <button type="button" class="admin-mobile-week-row"><span class="admin-mobile-week-row__when">вто, 29</span><span class="admin-mobile-week-row__meta">Нема термини</span></button>
              <button type="button" class="admin-mobile-week-row"><span class="admin-mobile-week-row__when">сре, 30</span><span class="admin-mobile-week-row__meta">Нема термини</span></button>
              <button type="button" class="admin-mobile-week-row"><span class="admin-mobile-week-row__when">чет, 1</span><span class="admin-mobile-week-row__meta">Нема термини</span></button>
              <button type="button" class="admin-mobile-week-row"><span class="admin-mobile-week-row__when">пет, 2</span><span class="admin-mobile-week-row__meta admin-mobile-week-row__meta--count">4 термини</span></button>
              <button type="button" class="admin-mobile-week-row"><span class="admin-mobile-week-row__when">саб, 3</span><span class="admin-mobile-week-row__meta">Нема термини</span></button>
              <button type="button" class="admin-mobile-week-row admin-mobile-week-row--off"><span class="admin-mobile-week-row__when">нед, 4</span><span class="admin-mobile-week-row__meta">Неработно</span></button>
            </div>
          </div>
        </div>
        <div id="monthMount" class="qa-month">
          <div class="admin-schedule-month">
            <div class="admin-schedule-month__dow">Пон</div>
            <div class="admin-schedule-month__dow">Вто</div>
            <div class="admin-schedule-month__dow">Сре</div>
            <div class="admin-schedule-month__dow">Чет</div>
            <div class="admin-schedule-month__dow">Пет</div>
            <div class="admin-schedule-month__dow">Саб</div>
            <div class="admin-schedule-month__dow">Нед</div>
            <button type="button" class="admin-schedule-month-day admin-schedule-month-day--outside"><span class="admin-schedule-month-day__num">31</span></button>
            <button type="button" class="admin-schedule-month-day admin-schedule-month-day--today admin-schedule-month-day--selected"><span class="admin-schedule-month-day__num">1</span><span class="admin-schedule-month-day__count">5</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">2</span><span class="admin-schedule-month-day__count">13</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">3</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">4</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">5</span></button>
            <button type="button" class="admin-schedule-month-day admin-schedule-month-day--closed"><span class="admin-schedule-month-day__num">6</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">7</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">8</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">9</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">10</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">11</span></button>
            <button type="button" class="admin-schedule-month-day"><span class="admin-schedule-month-day__num">12</span></button>
            <button type="button" class="admin-schedule-month-day admin-schedule-month-day--closed"><span class="admin-schedule-month-day__num">13</span></button>
          </div>
        </div>
      </div>
    </section>
  </div>
  </div>
  <pre id="qa-report"></pre>
  <script>
    (function () {
      const params = new URLSearchParams(location.search);
      const theme = params.get("theme") || "light";
      const width = Number(params.get("w") || "390");
      document.body.classList.toggle("app-theme-dark", theme === "dark");
      const phone = document.getElementById("qa-phone");
      phone.style.width = width + "px";
      phone.style.maxWidth = width + "px";
      const cs = (el) => getComputedStyle(el);
      const root = document.getElementById("adminSectionCalendar");
      const frame = phone.getBoundingClientRect();
      const labels = [...document.querySelectorAll(".admin-mobile-week-row__when")].map((el) => {
        const s = cs(el);
        return { text: el.textContent.trim(), family: s.fontFamily, size: s.fontSize, weight: s.fontWeight, line: s.lineHeight };
      });
      const metas = [...document.querySelectorAll(".admin-mobile-week-row__meta")].map((el) => {
        const s = cs(el);
        return {
          text: el.textContent.trim(),
          family: s.fontFamily,
          size: s.fontSize,
          weight: s.fontWeight,
          clipped: el.scrollWidth > el.clientWidth + 1,
          x: Math.round(el.getBoundingClientRect().x),
          w: Math.round(el.getBoundingClientRect().width),
          r: Math.round(el.getBoundingClientRect().right)
        };
      });
      const month = document.querySelector(".admin-schedule-month");
      const cells = [...document.querySelectorAll(".admin-schedule-month-day")];
      const counts = [...document.querySelectorAll(".admin-schedule-month-day__count")];
      const dowEls = [...document.querySelectorAll(".admin-schedule-month__dow")];
      const dows = dowEls.map((el) => {
        const s = cs(el);
        return { text: el.textContent.trim(), family: s.fontFamily, size: s.fontSize, weight: s.fontWeight };
      });
      const lastDow = dowEls[dowEls.length - 1];
      const lastCell = cells[6];
      const todayNum = document.querySelector(".admin-schedule-month-day--today .admin-schedule-month-day__num");
      const otherNum = document.querySelector(".admin-schedule-month-day:not(.admin-schedule-month-day--today):not(.admin-schedule-month-day--outside) .admin-schedule-month-day__num");
      const report = {
        overflow: root.scrollWidth > root.clientWidth + 1 || phone.scrollWidth > phone.clientWidth + 1,
        frameWidth: Math.round(frame.width),
        rootFamily: cs(root).fontFamily,
        titleSize: cs(document.querySelector(".admin-calendar-screen__title")).fontSize,
        dateSize: cs(document.getElementById("adminCalendarTitle")).fontSize,
        tabSizes: [...document.querySelectorAll(".cal-view-tab")].map((el) => cs(el).fontSize),
        labels,
        metas,
        monthCols: getComputedStyle(month).gridTemplateColumns.split(" ").length,
        cellOverflow: cells.some((el) => el.scrollWidth > el.clientWidth + 1),
        cellMinHeight: Math.min(...cells.map((el) => el.getBoundingClientRect().height)),
        cellRadius: cs(cells[1]).borderRadius,
        lastDowRight: lastDow ? Math.round(lastDow.getBoundingClientRect().right) : 0,
        lastCellRight: lastCell ? Math.round(lastCell.getBoundingClientRect().right) : 0,
        viewport: Math.round(frame.width),
        closedText: document.body.innerText.includes("Затворено"),
        terminiInCells: counts.some((el) => /термин/i.test(el.textContent)),
        countTexts: counts.map((el) => el.textContent.trim()),
        dows,
        todayNumSize: cs(todayNum).fontSize,
        todayNumWeight: cs(todayNum).fontWeight,
        otherNumSize: cs(otherNum).fontSize,
        otherNumWeight: cs(otherNum).fontWeight
      };
      document.getElementById("qa-report").textContent = JSON.stringify(report);
    })();
  </script>
</body>
</html>
`;

const previewPath = path.join(outDir, "calendar-week-month-preview.html");
fs.writeFileSync(previewPath, fixture);

function same(arr, key) {
  return arr.every((item) => item[key] === arr[0][key]);
}

if (!fs.existsSync(chrome)) {
  console.log(`PASS ${passed} source checks (Chrome unavailable for computed-style QA)`);
  process.exit(0);
}

function chromeRun(args) {
  const ran = spawnSync(chrome, ["--headless=new", "--disable-gpu", "--hide-scrollbars", ...args], {
    encoding: "utf8",
    maxBuffer: 30 * 1024 * 1024
  });
  if (ran.status !== 0) throw new Error(ran.stderr || ran.stdout || String(ran.status));
  return ran.stdout;
}

const previewUrl = pathToFileURL(previewPath).href;
const widths = [375, 390, 430];
const results = [];

for (const width of widths) {
  for (const theme of width === 390 ? ["light", "dark"] : ["light"]) {
    const url = `${previewUrl}?theme=${theme}&w=${width}`;
    const shot = path.join(shotsDir, `calendar-${theme}-${width}.png`);
    chromeRun([`--window-size=${width},1400`, `--screenshot=${shot}`, url]);
    const dom = chromeRun([`--window-size=${width},1400`, "--dump-dom", url]);
    const match = dom.match(/<pre id="qa-report">([^<]*)<\/pre>/);
    const metrics = match ? JSON.parse(match[1].replace(/&quot;/g, '"')) : null;
    assert(metrics, `computed-style report missing at ${width} ${theme}`);
    assert(metrics.frameWidth === width, `QA frame ${metrics.frameWidth} !== ${width}`);
    assert(!metrics.overflow, `horizontal overflow at ${width} ${theme}`);
    assert(/Work Sans/i.test(metrics.rootFamily), `root font-family at ${width} ${theme}: ${metrics.rootFamily}`);
    assert(metrics.titleSize === "22px", `title size ${metrics.titleSize} at ${width}`);
    assert(metrics.dateSize === "16px", `date size ${metrics.dateSize} at ${width}`);
    assert(metrics.tabSizes.every((s) => s === "15px"), `segmented tabs mixed size ${metrics.tabSizes} at ${width}`);
    assert(metrics.labels.length === 7, "Week has 7 date labels");
    assert(same(metrics.labels, "family"), `Week font-family mixed at ${width}: ${metrics.labels.map((l) => l.family).join(" | ")}`);
    assert(same(metrics.labels, "size"), `Week font-size mixed at ${width}: ${metrics.labels.map((l) => l.size).join(" | ")}`);
    assert(same(metrics.labels, "weight"), `Week font-weight mixed at ${width}: ${metrics.labels.map((l) => l.weight).join(" | ")}`);
    assert(metrics.labels[0].size === "16px", `Week label size ${metrics.labels[0].size}`);
    assert(metrics.labels[0].weight === "700", `Week label weight ${metrics.labels[0].weight}`);
    assert(same(metrics.metas, "size"), `Week status size mixed at ${width}`);
    assert(metrics.metas[0].size === "14px", `Week status size ${metrics.metas[0].size}`);
    assert(metrics.metas.every((m) => !m.clipped), `Week status clipped at ${width}: ${metrics.metas.filter((m) => m.clipped).map((m) => m.text).join(", ")}`);
    assert(metrics.metas.every((m) => m.r <= metrics.viewport + 1), `Week status off-canvas at ${width}: ${JSON.stringify(metrics.metas)}`);
    assert(metrics.metas.every((m) => m.x > 80), `Week status not on the right at ${width}: ${JSON.stringify(metrics.metas)}`);
    assert(metrics.monthCols === 7, `Month columns ${metrics.monthCols} at ${width}`);
    assert(!metrics.cellOverflow, `Month cell overflow at ${width} ${theme}`);
    assert(metrics.cellMinHeight >= 64, `Month cell height ${metrics.cellMinHeight} at ${width}`);
    assert(metrics.cellRadius === "0px", `Month cell radius ${metrics.cellRadius} at ${width}`);
    assert(metrics.lastDowRight <= metrics.viewport + 1, `weekday header clipped at ${width}: right=${metrics.lastDowRight} vw=${metrics.viewport}`);
    assert(metrics.lastCellRight <= metrics.viewport + 1, `month cell clipped at ${width}: right=${metrics.lastCellRight} vw=${metrics.viewport}`);
    assert(!metrics.closedText, "Month still shows Затворено");
    assert(!metrics.terminiInCells, "Month still shows термини inside cells");
    assert(metrics.countTexts.every((t) => /^\d+$/.test(t)), `Month counts not numeric: ${metrics.countTexts}`);
    assert(metrics.todayNumSize === metrics.otherNumSize, `today date size ${metrics.todayNumSize} vs ${metrics.otherNumSize}`);
    assert(metrics.todayNumWeight === metrics.otherNumWeight, `today date weight ${metrics.todayNumWeight} vs ${metrics.otherNumWeight}`);
    assert(metrics.dows.every((d) => d.size === "11px"), `weekday header size mixed at ${width}`);
    results.push({
      width,
      theme,
      shot,
      rootFamily: metrics.rootFamily,
      weekSize: metrics.labels[0].size,
      weekWeight: metrics.labels[0].weight,
      metas: metrics.metas,
      lastDowRight: metrics.lastDowRight,
      viewport: metrics.viewport
    });
  }
}

fs.writeFileSync(path.join(outDir, "calendar-week-month-qa.json"), JSON.stringify(results, null, 2));
console.log(`PASS ${passed} business calendar CAPTAIN typography + week/month checks`);
