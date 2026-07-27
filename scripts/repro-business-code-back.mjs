/**
 * Verifies Profile -> Enter Business Code -> wait -> Back flow.
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");

function instrumentHtml(raw) {
  const needle = `let currentUser = null;
  let currentUserRole = null;
  let businessId = null;
  let businessSettings = null;`;
  const block = `${needle}
  if (new URLSearchParams(location.search).get("repro") === "1") {
    currentUser = { id: "00000000-0000-4000-8000-000000000099", email: "customer@test.com" };
    currentUserRole = "customer";
    businessId = "demo-salon";
    businessSettings = { business_id: "00000000-0000-4000-8000-000000000001", business_slug: "demo-salon", business_name: "Demo Salon" };
  }`;
  if (!raw.includes(needle)) throw new Error("instrumentation needle not found");
  return raw.replace(needle, block);
}

function startServer(getHtml) {
  return new Promise((resolve) => {
    const server = createServer(async (_req, res) => {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      res.end(await getHtml());
    });
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      resolve({ server, url: `http://127.0.0.1:${port}/` });
    });
  });
}

async function main() {
  const raw = await readFile(path.join(root, "index.html"), "utf8");
  const { server, url } = await startServer(() => instrumentHtml(raw));
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });

  const logs = [];
  page.on("console", (m) => {
    const t = m.text();
    if (t.includes("[nav-debug]")) logs.push(t);
  });
  page.on("pageerror", (e) => console.error("PAGEERROR:", e.message));

  await page.goto(`${url}?business=demo-salon&repro=1`, { waitUntil: "domcontentloaded", timeout: 180000 });
  await page.waitForFunction(() => typeof window.onCustomerChangeBusinessClick === "function", { timeout: 180000 });

  await page.evaluate(() => {
    document.getElementById("modeView")?.classList.add("hidden");
    document.getElementById("authView")?.classList.add("hidden");
    document.getElementById("publicView")?.classList.remove("hidden");
    document.body.classList.add("customer-mobile-shell-active");
    document.getElementById("customerMobileBottomNav")?.classList.remove("hidden");
    document.getElementById("customerStartCard")?.classList.add("hidden");
    document.getElementById("customerMobileTabProfile")?.classList.remove("hidden");
    window.setCustomerMobileTab("profile", { skipWizardInit: true });
  });

  await page.evaluate(() => window.onCustomerChangeBusinessClick());
  await page.waitForTimeout(3000);
  await page.evaluate(() => window.syncPublicBusinessFromUrl());
  await page.waitForTimeout(500);

  const mid = await page.evaluate(() => ({
    picker: document.body.classList.contains("customer-shell-business-picker"),
    startCardVisible: !document.getElementById("customerStartCard")?.classList.contains("hidden"),
    manualVisible: !document.getElementById("customerManualBusinessSection")?.classList.contains("hidden"),
    shellPickerCard: document.getElementById("customerStartCard")?.classList.contains("customer-hub-card--shell-picker")
  }));
  console.log("MID (overlay preserved after sync):", JSON.stringify(mid, null, 2));

  await page.evaluate(() => window.onCustomerChangeBusinessBack());
  await page.waitForTimeout(300);

  const result = await page.evaluate(() => ({
    shell: document.body.classList.contains("customer-mobile-shell-active"),
    picker: document.body.classList.contains("customer-shell-business-picker"),
    preferManual: false,
    overlayReturnTab: null,
    startCardHidden: document.getElementById("customerStartCard")?.classList.contains("hidden"),
    profileHidden: document.getElementById("customerMobileTabProfile")?.classList.contains("hidden"),
    navHidden: document.getElementById("customerMobileBottomNav")?.classList.contains("hidden"),
    businessId: "demo-salon",
    url: location.search
  }));

  const pass =
    mid.picker === true &&
    mid.startCardVisible === true &&
    mid.manualVisible === true &&
    mid.shellPickerCard === true &&
    result.shell &&
    result.startCardHidden &&
    !result.profileHidden &&
    !result.navHidden &&
    !result.picker &&
    result.url.includes("business=demo-salon");

  console.log("RESULT:", JSON.stringify(result, null, 2));
  console.log("PASS:", pass);
  if (logs.length) console.log("LOGS:\n" + logs.join("\n"));

  await browser.close();
  server.close();
  process.exit(pass ? 0 : 1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
