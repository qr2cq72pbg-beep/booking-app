/**
 * Verify Phase 4F trial i18n keys exist in en / mk / sq and required hooks exist.
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

const KEYS = [
  "subFreeTrialTitle",
  "subNoPaymentRequired",
  "subExpirationDateTime",
  "subRemainingHours",
  "subRemainingHour",
  "subRemainingDaysHours",
  "subTrialExpiredInfo",
  "subBannerTrialHours",
  "subBannerTrialUrgentHours",
  "subBannerTrialEnded",
  "subBannerTrialEndedBody",
  "subAccessTrial",
  "subTrialInfo",
  "subExpiredBookingNote"
];

function countKey(lang, key) {
  const re = new RegExp(`\\n\\s+${key}:`, "g");
  const start = html.indexOf(`    ${lang}: {`);
  if (start < 0) return 0;
  const next = ["en", "mk", "sq"].filter((code) => code !== lang);
  let end = html.length;
  for (const other of next) {
    const idx = html.indexOf(`    ${other}: {`, start + 8);
    if (idx > start && idx < end) end = idx;
  }
  const slice = html.slice(start, end);
  return (slice.match(re) || []).length;
}

const missing = [];
for (const lang of ["en", "mk", "sq"]) {
  for (const key of KEYS) {
    const n = countKey(lang, key);
    if (n !== 1) missing.push(`${lang}.${key} count=${n}`);
  }
}

const hooks = [
  "XBOOK FREE TRIAL",
  "formatOwnerSubDateTime",
  "formatOwnerSubRemainingPrecise",
  "ownerSubRemainingMs",
  "starts_at",
  "expires_at",
  "remaining_seconds",
  "get_my_business_access"
];
for (const hook of hooks) {
  if (!html.includes(hook)) missing.push("missing hook " + hook);
}

if (html.includes("Booking restrictions are now active")) {
  missing.push("false claim that booking restrictions are active");
}

if (missing.length) {
  console.error(missing.join("\n"));
  process.exit(1);
}
console.log("xbook-phase4f-i18n-check: ok (" + KEYS.length + " keys x 3 languages)");
