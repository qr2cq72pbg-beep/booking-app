#!/usr/bin/env node
/**
 * Google OAuth / onboarding contract checks (static).
 * Does not call Supabase, send auth emails, or create accounts.
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

const applySession = sliceBetween(
  html,
  "async function applyAuthenticatedSession(session) {",
  "async function restoreAppSession(opts = {}) {"
);
const pendingAuth = sliceBetween(html, "const PENDING_AUTH_STORAGE_KEY", "function markStandaloneCustomerAuthSkipLocalBusiness");
const signup = sliceBetween(html, "async function signup() {", "async function customerSignup");
const routeAuth = sliceBetween(html, "async function routeAuthenticatedUser(opts = {}) {", "async function routeAdminShell");
const recovery = sliceBetween(html, "function showUnresolvedAccountTypeRecovery", "async function routeAuthenticatedUser");
const createClient = sliceBetween(html, "function createSupabaseClientInstance() {", "function initSupabaseClient()");
const passwordEvent = sliceBetween(html, "sb.auth.onAuthStateChange", "if (event === \"SIGNED_OUT\"");
const loginKeyboard = sliceBetween(
  html,
  "Do not animate transform/opacity on form controls",
  "#authView.xb-lg-create .auth-brand { animation-delay"
);

assert(html.includes("function peekPendingAuth()"), "pending auth can be read without being consumed");
assert(pendingAuth.includes("localStorage.setItem(PENDING_AUTH_STORAGE_KEY"), "signup intent is persisted to localStorage");
assert(pendingAuth.includes("PENDING_AUTH_TTL_MS"), "signup intent is TTL-bounded");
assert(applySession.includes("peekPendingAuth()"), "OAuth session restore peeks signup intent");
assert(!applySession.includes("consumePendingAuth()"), "OAuth session restore must not consume intent before success");
assert(!applySession.includes("showAuthView()"), "Google OAuth must not bounce to the email/password form");
assert(!applySession.includes("sb.auth.signOut()"), "existing admin must not be signed out by leftover customer intent");
assert(applySession.includes("decision.recoveryKind || \"missing-role\""), "new OAuth users with no profile still recover instead of dead-ending");
assert(html.includes("ACCOUNT_ROLE_WRITE_INTENT.BRAND_NEW_ADMIN_OAUTH"), "business Google signup still writes admin via existing writer");
assert(html.includes("ACCOUNT_ROLE_WRITE_INTENT.BRAND_NEW_CUSTOMER_OAUTH"), "customer Google signup still writes customer via existing writer");

assert(signup.includes("validateSignupPasswordPair"), "email/password business signup still requires a password");
assert(signup.includes("sb.auth.signUp"), "email/password business signup still uses signUp");
assert(html.includes("function signUpBusinessWithGoogle()"), "business Google button remains");
assert(html.includes("function signUpCustomerAccountWithGoogle()"), "customer Google button remains");
assert(html.includes("function signInWithGoogle()"), "Google login remains");

assert(routeAuth.includes('decision.recoveryKind || "missing-role"'), "router does not treat missing OAuth profile as a dead-end");
assert(routeAuth.includes('kind: "role-load-error"'), "router distinguishes network role-load failure");
assert(recovery.includes("hideAllViews()"), "recovery hides Welcome/Auth before overlay");
assert(html.includes("function retryUnresolvedAccountType"), "Retry retries the failed account-type operation");
assert(recovery.includes("write-failed"), "role-write failures are not hidden behind a generic missing-role screen");
assert(recovery.includes("recoverChooseAccountType"), "recovery can finish Business/Customer explicitly");
assert(recovery.includes("recoverAppShellToWelcome"), "recovery can return to Welcome");
assert(recovery.includes("recoverAppShellSignOut"), "recovery can sign out");
assert(html.includes('id="appShellChooseBusinessBtn"'), "recovery UI has Create Business");
assert(html.includes('id="appShellChooseCustomerBtn"'), "recovery UI has Create Customer");
assert(html.includes('id="appShellWelcomeBtn"'), "recovery UI has Back to Welcome");
assert(html.includes('id="appShellSignOutBtn"'), "recovery UI has Sign out");

assert(createClient.includes("detectSessionInUrl: !isNativeCapacitorApp()"), "native OAuth does not auto-detect session in the WebView URL");
assert(html.includes("function isExplicitPasswordRecoveryContext"), "password reset requires an explicit recovery context");
assert(passwordEvent.includes("isExplicitPasswordRecoveryContext"), "PASSWORD_RECOVERY does not open Set password for Google signup");

assert(html.includes("choose-create-business-account-oauth"), "Welcome Create Business can finish a signed-in Google user with no role");
assert(html.includes("choose-create-customer-account-oauth"), "Welcome Create Customer can finish a signed-in Google user with no role");
assert(html.includes("BUSINESS_SIGNUP_EXISTING_CUSTOMER_MESSAGE"), "existing customer cannot be silently converted to business");

assert(loginKeyboard.includes("transform: none"), "login keyboard transform fix is preserved");
assert(html.includes('welcomeSignIn: "Sign In"'), "EN Sign In remains");
assert(html.includes('welcomeSignIn: "Најави се"'), "MK Sign In remains");
assert(html.includes('welcomeSignIn: "Hyr"'), "SQ Sign In remains");
assert(html.includes('subFreeUntilChanged: "FREE UNTIL CHANGED"'), "subscription copy remains");
assert(html.includes('id="logoutConfirmModal"'), "logout confirmation remains");
assert(!html.includes("service_role"), "mobile app still has no service_role key");

console.log("PASS: OAuth onboarding / Google password contract");
