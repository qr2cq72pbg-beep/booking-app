#!/usr/bin/env node
/**
 * Headless visual QA for the Analytics CAPTAIN consistency sweep.
 * Renders fixture screens at 375/390/430 light + one dark token preview.
 */

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const outDir = path.join(root, ".tmp-analytics-qa");
const shotsDir = path.join(outDir, "shots");

function extractStyle(html) {
  const parts = [];
  const re = /<style[^>]*>([\s\S]*?)<\/style>/gi;
  let m;
  while ((m = re.exec(html))) parts.push(m[1]);
  return parts.join("\n");
}

const source = fs.readFileSync(path.join(root, "index.html"), "utf8");
const css = extractStyle(source);
fs.mkdirSync(shotsDir, { recursive: true });
fs.writeFileSync(path.join(outDir, "analytics-extract.css"), css);

const fixture = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Analytics CAPTAIN consistency QA</title>
  <link rel="stylesheet" href="analytics-extract.css" />
  <style>
    html, body { margin: 0; background: var(--theme-surface-secondary, #f4f6f8); }
    body.admin-mobile-shell-active { font-family: Inter, -apple-system, BlinkMacSystemFont, sans-serif; }
    .qa-page { display: none; padding-bottom: 80px; }
    .qa-page.is-on { display: block; }
    [hidden] { display: none !important; }
    #adminView { min-height: 100vh; }
    .admin-section { display: block; }
    #qa-report { position: absolute; left: -9999px; }
  </style>
</head>
<body class="admin-mobile-shell-active">
  <div id="adminView">
    <section id="adminSectionPerformance" class="qa-page is-on" data-qa="overview">
      <div class="admin-native-screen admin-performance-screen analytics-hub-screen">
        <header class="admin-native-screen__header admin-performance-screen__header">
          <h1 class="admin-native-screen__title admin-performance-screen__title">Analytics</h1>
          <p class="admin-native-screen__subtitle admin-performance-screen__subtitle">Business performance & insights</p>
        </header>
        <div class="analytics-period-bar">
          <div class="analytics-period-bar__copy">
            <button type="button" class="analytics-period-trigger"><span>This month</span><span class="analytics-period-trigger__caret"></span></button>
          </div>
        </div>
        <nav class="analytics-hub-nav">
          <button type="button" class="analytics-hub-nav__item is-active">Overview</button>
          <button type="button" class="analytics-hub-nav__item">Customers</button>
          <button type="button" class="analytics-hub-nav__item">Team</button>
          <button type="button" class="analytics-hub-nav__item">Services</button>
        </nav>
        <div class="admin-analytics-error">
          <span>Could not load analytics.</span>
          <button type="button" class="admin-analytics-retry">Retry</button>
        </div>
      </div>
    </section>

    <section id="adminSectionCustomerAnalytics" class="qa-page" data-qa="customers">
      <div class="admin-native-screen admin-performance-screen analytics-hub-screen">
        <header class="admin-native-screen__header admin-performance-screen__header">
          <h1 class="admin-native-screen__title admin-performance-screen__title">Analytics</h1>
        </header>
        <div class="analytics-period-bar">
          <div class="analytics-period-bar__copy">
            <button type="button" class="analytics-period-trigger"><span>This month</span><span class="analytics-period-trigger__caret"></span></button>
          </div>
        </div>
        <nav class="analytics-hub-nav">
          <button type="button" class="analytics-hub-nav__item">Overview</button>
          <button type="button" class="analytics-hub-nav__item is-active">Customers</button>
          <button type="button" class="analytics-hub-nav__item">Team</button>
          <button type="button" class="analytics-hub-nav__item">Services</button>
        </nav>
        <div id="customerAnalyticsError" class="admin-analytics-error">
          <span>Could not load customer analytics.</span>
          <button type="button" id="customerAnalyticsRetryBtn" class="admin-analytics-retry">Retry</button>
        </div>
      </div>
    </section>

    <section id="adminSectionCustomerAnalyticsList" class="qa-page" data-qa="customer-list">
      <div id="adminSectionCustomerAnalytics" class="admin-section admin-ca-segment-open">
        <div class="admin-native-screen admin-performance-screen">
          <div id="customerAnalyticsSegmentView">
            <div class="admin-ca-seg-top">
              <button type="button" id="caSegBackBtn" class="admin-ca-seg-back" aria-label="Back">
                <span class="admin-ca-seg-back__icon"></span>
                <span>Back</span>
              </button>
              <div class="admin-ca-seg-heading">
                <h2 class="admin-ca-seg-title">Active customers</h2>
                <p class="admin-ca-seg-count">12 customers</p>
              </div>
            </div>
            <div class="admin-ca-seg-error">
              <span>Could not load this list.</span>
              <button type="button" class="admin-ca-seg-retry">Retry</button>
            </div>
            <div class="admin-ca-seg-list">
              <div class="admin-ca-seg-row admin-ca-seg-row--clickable">
                <div class="admin-ca-seg-row__head">
                  <span class="admin-ca-seg-row__name">Ana Petrovska</span>
                  <span class="admin-ca-seg-row__num">#013</span>
                </div>
                <div class="admin-ca-seg-row__line admin-ca-seg-row__metrics">2 visits · 800 MKD</div>
                <div class="admin-ca-seg-row__line admin-ca-seg-row__activity">Last visit: 24 Sep · No upcoming appointment</div>
                <span class="admin-ca-seg-row__inactive">1 day inactive</span>
                <span class="admin-ca-row__chev"></span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section id="adminSectionCustomerAnalyticsDetail" class="qa-page" data-qa="customer-detail">
      <div id="adminSectionCrossAnalytics" class="admin-section admin-ca-detail-open">
        <div class="admin-native-screen admin-performance-screen">
          <div id="customerAnalyticsDetailView">
            <div class="admin-ca-seg-top">
              <button type="button" id="caDetBackBtn" class="admin-ca-seg-back" aria-label="Back">
                <span class="admin-ca-seg-back__icon"></span>
                <span>Back</span>
              </button>
              <div class="admin-ca-seg-heading">
                <h2 class="admin-ca-seg-title">Ana Petrovska</h2>
                <p class="admin-ca-seg-period">#013</p>
              </div>
            </div>
            <div class="admin-ca-det-badges">
              <button type="button" class="admin-ca-det-vip admin-ca-det-vip--off"><span class="admin-ca-det-vip__star">☆</span><span>Mark VIP</span></button>
              <span class="admin-ca-det-badge">Repeat customer</span>
            </div>
            <div class="admin-ca-seg-error admin-ca-det-error">
              <span class="admin-ca-det-error__mark"></span>
              <div class="admin-ca-det-error__copy">
                <span>Could not load this customer.</span>
                <button type="button" class="admin-ca-seg-retry">Retry</button>
              </div>
            </div>
            <div class="admin-ca-det-body">
              <section class="admin-ca-det-identity">
                <div class="admin-ca-det-block">
                  <h3 class="admin-ca-det-kicker">Contact</h3>
                  <div class="admin-ca-det-contact">
                    <a class="admin-ca-det-contact__row" href="#"><span class="admin-ca-det-contact__icon admin-ca-det-contact__icon--phone"></span><span class="admin-ca-det-contact__value">070 123 456</span></a>
                    <a class="admin-ca-det-contact__row" href="#"><span class="admin-ca-det-contact__icon admin-ca-det-contact__icon--mail"></span><span class="admin-ca-det-contact__value">ana.petrovska@example.com</span></a>
                  </div>
                </div>
                <div class="admin-ca-det-block">
                  <h3 class="admin-ca-det-kicker">Profile</h3>
                  <p class="admin-ca-det-demo">Strumica   ·   45–54   ·   Male</p>
                </div>
              </section>
              <section class="admin-ca-det-kpis">
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Visits</p><p class="admin-ca-det-kpi__value">2</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Revenue to date</p><p class="admin-ca-det-kpi__value">800 MKD</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Average spend</p><p class="admin-ca-det-kpi__value">400 MKD</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Last visit</p><p class="admin-ca-det-kpi__value">24 Sep</p><p class="admin-ca-det-kpi__hint">First visit: 12 Jan</p></div>
              </section>
              <section class="admin-ca-det-card admin-ca-det-notes admin-ca-det-block">
                <h3 class="admin-ca-det-card__title admin-ca-det-kicker">Internal Notes</h3>
                <p class="admin-ca-det-notes__privacy">Only visible to your business</p>
                <p class="admin-ca-det-notes__empty">Add a private note about this customer.</p>
                <div class="admin-ca-det-notes__actions">
                  <button type="button" class="admin-ca-det-notes__btn admin-ca-det-notes__btn--muted">Add note</button>
                </div>
              </section>
              <section class="admin-ca-det-block admin-ca-det-next">
                <h3 class="admin-ca-det-kicker">Next appointment</h3>
                <p class="admin-ca-det-empty">No upcoming appointment</p>
              </section>
              <section class="admin-ca-det-block admin-ca-det-services">
                <h3 class="admin-ca-det-kicker">Top services</h3>
                <div class="admin-ca-det-svc">
                  <div class="admin-ca-det-svc__name">Men's haircut</div>
                  <div class="admin-ca-det-svc__meta">2 visits · 800 MKD</div>
                  <div class="admin-ca-det-svc__bar"><span style="width:100%"></span></div>
                </div>
              </section>
              <section class="admin-ca-det-block">
                <h3 class="admin-ca-det-section-title admin-ca-det-kicker">Visit history</h3>
                <div class="admin-ca-det-hist">
                  <article class="admin-ca-det-row">
                    <div class="admin-ca-det-row__top">
                      <div class="admin-ca-det-row__when">24 Sep · 10:00</div>
                      <span class="admin-ca-det-status status-completed">Completed</span>
                    </div>
                    <div class="admin-ca-det-row__svc">Men's haircut</div>
                    <div class="admin-ca-det-row__meta">Elena · 30 min · 400 MKD</div>
                  </article>
                </div>
              </section>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section id="adminSectionCustomerAnalyticsDetailMk" class="qa-page" data-qa="customer-detail-mk">
      <div id="adminSectionCrossAnalytics" class="admin-section admin-ca-detail-open">
        <div class="admin-native-screen admin-performance-screen">
          <div id="customerAnalyticsDetailView">
            <div class="admin-ca-seg-top">
              <button type="button" id="caDetBackBtnMk" class="admin-ca-seg-back" aria-label="Назад">
                <span class="admin-ca-seg-back__icon"></span>
                <span>Назад</span>
              </button>
              <div class="admin-ca-seg-heading">
                <h2 class="admin-ca-seg-title">Александра Николовска-Стојанова</h2>
                <p class="admin-ca-seg-period">#013</p>
              </div>
            </div>
            <div class="admin-ca-det-badges">
              <button type="button" class="admin-ca-det-vip admin-ca-det-vip--off"><span class="admin-ca-det-vip__star">☆</span><span>Означи VIP</span></button>
              <span class="admin-ca-det-badge">Повторен клиент</span>
            </div>
            <div class="admin-ca-det-body">
              <section class="admin-ca-det-identity">
                <div class="admin-ca-det-block">
                  <h3 class="admin-ca-det-kicker">Контакт</h3>
                  <div class="admin-ca-det-contact">
                    <a class="admin-ca-det-contact__row" href="#"><span class="admin-ca-det-contact__icon admin-ca-det-contact__icon--phone"></span><span class="admin-ca-det-contact__value">+389 70 123 456</span></a>
                    <a class="admin-ca-det-contact__row" href="#"><span class="admin-ca-det-contact__icon admin-ca-det-contact__icon--mail"></span><span class="admin-ca-det-contact__value">aleksandra.nikolovska.stojanova@studio.example.com</span></a>
                  </div>
                </div>
                <div class="admin-ca-det-block">
                  <h3 class="admin-ca-det-kicker">Профил</h3>
                  <p class="admin-ca-det-demo">Струмица-Ново Село   ·   45–54   ·   Машко</p>
                </div>
              </section>
              <section class="admin-ca-det-kpis">
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Посети</p><p class="admin-ca-det-kpi__value">12</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Приход до сега</p><p class="admin-ca-det-kpi__value">12 400 MKD</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Просечна потрошувачка</p><p class="admin-ca-det-kpi__value">1 033 MKD</p></div>
                <div class="admin-ca-det-kpi"><p class="admin-ca-det-kpi__label">Последна посета</p><p class="admin-ca-det-kpi__value">24 сеп</p><p class="admin-ca-det-kpi__hint">Прва посета: 12 јан</p></div>
              </section>
              <section class="admin-ca-det-card admin-ca-det-notes admin-ca-det-block">
                <h3 class="admin-ca-det-card__title admin-ca-det-kicker">Внатрешни белешки</h3>
                <p class="admin-ca-det-notes__privacy">Видливо само за вашиот бизнис</p>
                <p class="admin-ca-det-notes__empty">Додадете приватна белешка за овој клиент.</p>
                <div class="admin-ca-det-notes__actions">
                  <button type="button" class="admin-ca-det-notes__btn admin-ca-det-notes__btn--muted">Додај белешка</button>
                </div>
              </section>
              <section class="admin-ca-det-block admin-ca-det-next">
                <h3 class="admin-ca-det-kicker">Следен термин</h3>
                <p class="admin-ca-det-empty">Нема следен термин</p>
              </section>
            </div>
          </div>
        </div>
      </div>
    </section>

    <section id="adminSectionStaffAnalytics" class="qa-page" data-qa="team">
      <div class="admin-native-screen admin-performance-screen analytics-hub-screen">
        <header class="admin-native-screen__header admin-performance-screen__header">
          <h1 class="admin-native-screen__title admin-performance-screen__title">Analytics</h1>
        </header>
        <div class="admin-sta-list">
          <article class="admin-sta-card"><strong>Elena</strong><span>12 visits</span></article>
        </div>
      </div>
    </section>

    <section id="adminSectionServiceAnalytics" class="qa-page" data-qa="services">
      <div class="admin-native-screen admin-performance-screen analytics-hub-screen">
        <header class="admin-native-screen__header admin-performance-screen__header">
          <h1 class="admin-native-screen__title admin-performance-screen__title">Analytics</h1>
        </header>
        <div class="admin-sa-list">
          <article class="admin-sa-card"><strong>Haircut</strong><span>18 visits</span></article>
        </div>
      </div>
    </section>

    <section id="adminSectionCrossAnalytics" class="qa-page" data-qa="cross">
      <div class="admin-native-screen admin-performance-screen analytics-hub-screen">
        <header class="admin-native-screen__header admin-performance-screen__header">
          <button type="button" id="crossHomeBackBtn" class="admin-ca-seg-back" aria-label="Back">
            <span class="admin-ca-seg-back__icon"></span>
          </button>
          <h1 class="admin-native-screen__title admin-performance-screen__title">Advanced analysis</h1>
        </header>
        <div class="admin-xa-list">
          <button type="button" class="admin-xa-row">
            <div class="admin-xa-row__head">
              <span class="admin-xa-row__name">Ana Petrovska</span>
              <span class="admin-xa-row__status"><span class="admin-xa-row__num">#013</span></span>
            </div>
            <div class="admin-xa-row__demo">Strumica · 45–54 · Male</div>
            <div class="admin-xa-row__metrics">2 visits · 800 MKD</div>
            <div class="admin-xa-row__activity">Last visit: 24 Sep · No future booking<span class="admin-xa-row__inactive">1 day inactive</span></div>
            <span class="admin-xa-row__chev"></span>
          </button>
        </div>
      </div>
    </section>
  </div>
  <pre id="qa-report"></pre>
  <script>
    (function () {
      var params = new URLSearchParams(location.search);
      var screen = params.get("screen");
      var theme = params.get("theme");
      if (theme === "dark") {
        document.body.classList.add("app-theme-dark");
        document.documentElement.setAttribute("data-xbook-theme", "dark");
      }
      if (screen) {
        document.querySelectorAll(".qa-page").forEach(function (el) {
          el.classList.toggle("is-on", el.getAttribute("data-qa") === screen);
        });
      }
      function read(el) {
        if (!el) return null;
        var cs = getComputedStyle(el);
        var rect = el.getBoundingClientRect();
        return {
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          radius: cs.borderRadius,
          bg: cs.backgroundColor,
          color: cs.color,
          display: cs.display
        };
      }
      var report = {
        overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth + 1,
        back: read(document.querySelector(".qa-page.is-on .admin-ca-seg-back")),
        retry: read(document.querySelector(".qa-page.is-on .admin-analytics-retry, .qa-page.is-on .admin-ca-seg-retry")),
        row: read(document.querySelector(".qa-page.is-on .admin-ca-seg-row, .qa-page.is-on .admin-xa-row"))
      };
      document.getElementById("qa-report").textContent = JSON.stringify(report);
    })();
  </script>
</body>
</html>
`;

fs.writeFileSync(path.join(outDir, "captain-consistency-preview.html"), fixture);

const widths = [375, 390, 430];
const screens = [
  "overview",
  "customers",
  "customer-list",
  "customer-detail",
  "team",
  "services",
  "cross"
];

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
if (!fs.existsSync(chrome)) {
  console.log("qa-analytics-captain-consistency: preview written, Chrome unavailable — screenshots skipped");
  process.exit(0);
}

const previewUrl = pathToFileURL(path.join(outDir, "captain-consistency-preview.html")).href;
const results = [];

function chromeRun(args) {
  const ran = spawnSync(chrome, ["--headless=new", "--disable-gpu", "--hide-scrollbars", ...args], {
    encoding: "utf8",
    maxBuffer: 20 * 1024 * 1024
  });
  if (ran.status !== 0) {
    throw new Error(`Chrome failed: ${ran.stderr || ran.stdout || ran.status}`);
  }
  return ran.stdout;
}

function capture(screen, width, theme) {
  const url = `${previewUrl}?screen=${encodeURIComponent(screen)}&theme=${theme}`;
  const shot = path.join(shotsDir, `captain-${screen}-${theme}-${width}.png`);
  chromeRun([`--window-size=${width},844`, `--screenshot=${shot}`, url]);
  const dom = chromeRun([`--window-size=${width},844`, "--dump-dom", url]);
  const match = dom.match(/<pre id="qa-report">([^<]*)<\/pre>/);
  const metrics = match ? JSON.parse(match[1]) : {};
  if (metrics.back) {
    if (metrics.back.width > 56) throw new Error(`${screen}@${width} Back is not compact (${metrics.back.width}px)`);
    if (metrics.back.height < 40 || metrics.back.height > 48) {
      throw new Error(`${screen}@${width} Back height ${metrics.back.height} is not the 44px family`);
    }
  }
  if (metrics.retry && metrics.retry.width > width - 32) {
    throw new Error(`${screen}@${width} Retry is full-width (${metrics.retry.width}px)`);
  }
  if (metrics.overflow) throw new Error(`${screen}@${width} horizontal overflow`);
  results.push({ screen, width, theme, shot, ...metrics });
}

for (const width of widths) {
  for (const screen of screens) {
    capture(screen, width, "light");
  }
}
capture("customer-detail", 390, "dark");
capture("customer-detail-mk", 375, "light");
capture("customer-detail-mk", 390, "light");
capture("customer-detail-mk", 430, "light");
capture("cross", 390, "dark");
capture("customer-list", 390, "dark");

fs.writeFileSync(path.join(outDir, "captain-consistency-qa.json"), JSON.stringify(results, null, 2));
console.log(`qa-analytics-captain-consistency: ${results.length} shots written`);
