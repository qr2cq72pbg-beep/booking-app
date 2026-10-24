#!/usr/bin/env node
/**
 * Login keyboard / Welcome Sign In performance contract (frontend only).
 * Does not call Supabase, change schemas, or require a physical device.
 */

import fs from "node:fs";
import path from "node:path";
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

function sliceBetween(src, startNeedle, endNeedle) {
  const start = src.indexOf(startNeedle);
  const end = src.indexOf(endNeedle, start >= 0 ? start + startNeedle.length : 0);
  assert(start >= 0, `missing start: ${startNeedle.slice(0, 90)}`);
  assert(end > start, `missing end after: ${startNeedle.slice(0, 90)}`);
  return src.slice(start, end);
}

const lgCss = sliceBetween(
  html,
  '<style id="xbook-liquid-glass-create-business">',
  "</style>"
);
const riseSelectors = sliceBetween(
  lgCss,
  "#authView.xb-lg-create .auth-brand,\n    #authView.xb-lg-create :is(#adminAuthLoginPanel, #adminAuthSignupPanel, #adminAuthCustomerSignupPanel, #adminAuthCustomerCodePanel) > .auth-card-lead,",
  "xb-create-biz-rise 560ms"
);
const noTransformBlock = sliceBetween(
  lgCss,
  "Do not animate transform/opacity on form controls",
  "#authView.xb-lg-create .auth-brand { animation-delay"
);
const chooseAdmin = sliceBetween(html, "async function chooseAdmin() {", "function openSwitchToAdminAccountPrompt");
const showAuth = sliceBetween(html, "function showAuthView(panel) {", "function showResetPasswordView");
const welcome = sliceBetween(html, 'id="modeView"', 'id="xbookDemoHomeView"');
const loginPanel = sliceBetween(html, 'id="adminAuthLoginPanel"', 'id="adminAuthSignupPanel"');
const sinkHelper = sliceBetween(html, "function xbFocusNavSinkIfAllowed() {", "function releaseNavigationInteractionState");

assert(welcome.includes('onclick="chooseAdmin()"'), "Welcome Sign In still calls chooseAdmin()");
assert(welcome.includes('data-i18n="welcomeSignIn"'), "Welcome Sign In keeps i18n key");
assert(welcome.includes("xb-welcome"), "Liquid Glass Welcome class remains");
assert(html.includes('welcomeSignIn: "Sign In"'), "EN Sign In copy remains");
assert(html.includes('welcomeSignIn: "Најави се"'), "MK Sign In copy remains");
assert(html.includes('welcomeSignIn: "Hyr"'), "SQ Sign In copy remains");

assert(lgCss.includes("@media (prefers-reduced-motion: reduce)"), "reduced-motion auth rules remain");
assert(lgCss.includes("xb-create-biz-rise"), "auth chrome rise animation preserved");
assert(lgCss.includes("xb-create-biz-atmosphere"), "Liquid Glass auth atmosphere preserved");

assert(!riseSelectors.includes("> input,"), "entrance rise animation must not target auth inputs");
assert(!riseSelectors.includes("> .password-wrap,"), "entrance rise animation must not target password wrap");
assert(noTransformBlock.includes("animation: none"), "auth inputs disable entrance animation");
assert(noTransformBlock.includes("transform: none"), "auth inputs force transform: none");
assert(
  lgCss.includes("#authView.xb-lg-create :is(#adminAuthLoginPanel") &&
    lgCss.includes("transform: none"),
  "lg-create input rule keeps transform: none"
);

assert(!chooseAdmin.includes("await xbHandoffWelcomeToCreateBusiness()"), "Sign In guest path must not await 110ms handoff");
assert(chooseAdmin.includes('showAuthView("login")'), "Sign In guest path opens login panel");
assert(chooseAdmin.includes("xbLoginPerfMark(\"sign-in-tap\")"), "Sign In tap is instrumented");
assert(chooseAdmin.includes("currentUser"), "authenticated Sign In path preserved");

assert(showAuth.includes("xbFocusAuthEntryInput"), "login screen focuses the entry input in the same turn");
assert(showAuth.includes("login-screen-visible"), "login visible mark exists");
assert(html.includes("input-focus-requested"), "focus requested mark exists");
assert(html.includes("input-focus-confirmed"), "focus confirmed probe exists");
assert(html.includes("visualViewport-resize"), "visualViewport keyboard probe exists");

assert(sinkHelper.includes("isNativeIosApp"), "nav focus sink is skipped on native iOS");
assert(html.includes("function isNativeIosApp()"), "isNativeIosApp helper exists");

assert(loginPanel.includes('id="authEmail"'), "login email field exists");
assert(loginPanel.includes('id="authPassword"'), "login password field exists");
assert(loginPanel.includes("signInWithGoogle()"), "Google login preserved");
assert(loginPanel.includes("signInWithApple()"), "Apple login preserved");
assert(loginPanel.includes("onclick=\"login()\""), "email login preserved");
assert(html.includes('id="authSignupEmail"'), "business signup email preserved");
assert(html.includes('id="customerAccountEmail"'), "customer signup email preserved");
assert(html.includes('id="logoutConfirmModal"'), "logout confirmation preserved");
assert(html.includes("function setAppLanguage"), "language switching preserved");
assert(html.includes('data-xbook-theme="dark"') || html.includes("data-xbook-theme"), "theme attribute preserved");
assert(html.includes("adminMobileBottomNav"), "business mobile nav preserved");
assert(html.includes("customer-mobile-nav"), "customer mobile nav preserved");
assert(html.includes("renderOwnerSubscriptionUi") || html.includes("function renderOwnerSubscriptionUi"), "subscription UI preserved");
assert(html.includes("function login()"), "login() function preserved");
assert(!html.includes("CREATE OR REPLACE"), "no SQL embedded in frontend HTML");

const handoff = sliceBetween(html, "function xbHandoffWelcomeToCreateBusiness() {", "function xbHandoffCreateBusinessToWelcome");
assert(!handoff.includes("setTimeout"), "welcome handoff no longer blocks on a timeout");

console.log("PASS: login keyboard / Welcome Sign In performance contract");
