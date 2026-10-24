/**
 * Verify Phase 4C i18n keys exist in en / mk / sq and required DOM hooks exist.
 */
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

const KEYS = [
  "welcomeBadge",
  "welcomeHeadline",
  "welcomeSubtitle",
  "welcomeCreateBusiness",
  "welcomeCreateCustomer",
  "welcomeSetupHint",
  "welcomeSignIn",
  "welcomeSignInHint",
  "welcomeTrustLine",
  "settingsSubscription",
  "settingsSubscriptionSub",
  "subCurrentAccess",
  "subCurrentPlan",
  "subAvailablePlans",
  "subStatus",
  "subStatusActive",
  "subStatusExpired",
  "subStatusUnconfigured",
  "subStatusUnavailable",
  "subAccessComplimentary",
  "subAccessTrial",
  "subAccessPaid",
  "subFreeUntilChanged",
  "subUnlimitedAccess",
  "subUntilChanged",
  "subRemainingDay",
  "subRemainingDays",
  "subExpiresToday",
  "subExpirationDate",
  "subStartDate",
  "subRenewalInfo",
  "subMonthlyEquivalent",
  "subSavings",
  "subBestValue",
  "subPlanSameFeatures",
  "subPlanDurationMonth",
  "subPlanDurationMonths",
  "subContactXbook",
  "subContactHint",
  "subLoading",
  "subUnavailable",
  "subRetry",
  "subNetworkError",
  "subUnconfiguredInfo",
  "subComplimentaryInfo",
  "subComplimentaryDatedInfo",
  "subPaidInfo",
  "subTrialInfo",
  "subExpiredInfo",
  "subExpiredBookingNote",
  "subBannerTrial",
  "subBannerTrialBody",
  "subBannerTrialBodyOne",
  "subBannerTrialUrgent",
  "subBannerWarning",
  "subBannerWarningBody",
  "subBannerWarningBodyOne",
  "subBannerUrgent",
  "subBannerUrgentBody",
  "subBannerExpired",
  "subBannerExpiredBody"
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
  'id="welcomeLanguageBtn"',
  'id="welcomeLanguageValue"',
  'id="adminSettingsSubscriptionPanel"',
  'id="adminSettingsAccountHub"',
  'id="overviewSubscriptionBanner"',
  "openAdminSettingsSubscriptionFromCategory()",
  "get_my_business_access",
  "list_active_subscription_packages"
];
for (const hook of hooks) {
  if (!html.includes(hook)) missing.push("missing hook " + hook);
}

if (html.includes("service_role") && /refreshOwnerSubscriptionAccess[\s\S]{0,400}service_role/.test(html)) {
  missing.push("service_role referenced near owner subscription fetch");
}

if (missing.length) {
  console.error(missing.join("\n"));
  process.exit(1);
}
console.log("xbook-phase4c-i18n-check: ok (" + KEYS.length + " keys x 3 languages)");
