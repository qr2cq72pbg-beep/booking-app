#!/usr/bin/env node
/**
 * Social-login UI is hidden; email/password and OAuth implementation remain.
 * Does not call Supabase or create accounts.
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

const oauthButtons = [
  ...html.matchAll(
    /<button type="button" class="auth-btn auth-btn--oauth auth-btn--oauth-(?:google|apple)"([^>]*)>/g
  )
];
assert(oauthButtons.length === 12, `expected 12 Google/Apple auth buttons, found ${oauthButtons.length}`);
oauthButtons.forEach((match, i) => {
  const attrs = match[1];
  assert(/\bhidden\b/.test(attrs), `oauth button ${i} is not hidden`);
  assert(/\bdisabled\b/.test(attrs), `oauth button ${i} is not disabled`);
  assert(/tabindex="-1"/.test(attrs), `oauth button ${i} is still keyboard-focusable`);
  assert(/aria-hidden="true"/.test(attrs), `oauth button ${i} is still exposed to assistive tech`);
});

assert(html.includes('id="xbook-hide-social-auth"'), "social-auth hide stylesheet is present");
assert(
  html.includes("html body.native-app-shell #authView .admin-auth-oauth"),
  "hide CSS beats the native iOS flex !important rule"
);
assert(html.includes("function lockHiddenSocialAuthUi()"), "startup re-locks hidden social-auth controls");
assert(html.includes("lockHiddenSocialAuthUi();"), "init calls the social-auth lock");

assert((html.match(/class="admin-auth-oauth" hidden aria-hidden="true"/g) || []).length === 4, "admin oauth groups are hidden");
assert((html.match(/class="customer-auth-oauth" hidden aria-hidden="true"/g) || []).length === 2, "customer oauth groups are hidden");
assert(html.includes('id="customerJoinOauthBlock" hidden aria-hidden="true"'), "join-business oauth block is hidden");
assert(
  (html.match(/class="auth-divider" role="separator" hidden aria-hidden="true"/g) || []).length === 6,
  "oauth 'or' separators are hidden"
);
assert(
  html.includes('<hr class="auth-divider" id="customerAuthDivider" />'),
  "non-oauth customer hub divider stays in the layout"
);

assert(html.includes("function signInWithGoogle()"), "Google login implementation remains");
assert(html.includes("function signInWithApple()"), "Apple login implementation remains");
assert(html.includes("function signUpBusinessWithGoogle()"), "business Google signup implementation remains");
assert(html.includes("function signUpBusinessWithApple()"), "business Apple signup implementation remains");
assert(html.includes("function signUpCustomerAccountWithGoogle()"), "customer Google signup implementation remains");
assert(html.includes("async function signInWithOAuthProvider"), "OAuth provider helper remains");
assert(html.includes("async function handleNativeAuthCallbackUrl"), "native OAuth callback remains");
assert(html.includes("sb.auth.signInWithOAuth"), "Supabase OAuth call remains");

assert(html.includes("async function signup()"), "business email signup remains");
assert(html.includes("async function login()"), "business email login remains");
assert(html.includes("async function customerSignup"), "customer email signup remains");
assert(html.includes("async function customerLogin()"), "customer email login remains");
assert(html.includes("function sendPasswordResetEmail()"), "password recovery remains");
assert(html.includes('id="logoutConfirmModal"'), "logout confirmation remains");
assert(html.includes("validateSignupPasswordPair"), "email signup still requires a password");
assert(html.includes("sb.auth.signInWithPassword"), "email/password login still uses password auth");
assert(html.includes("clearPendingAuth();"), "email login still clears leftover OAuth signup intent");

assert(html.includes('welcomeSignIn: "Sign In"'), "EN Sign In remains");
assert(html.includes('welcomeSignIn: "Најави се"'), "MK Sign In remains");
assert(html.includes('welcomeSignIn: "Hyr"'), "SQ Sign In remains");
assert(html.includes("transform: none"), "iOS login keyboard transform fix remains");
assert(html.includes('onclick="chooseCreateBusinessAccount()"'), "Welcome Create Business remains");
assert(html.includes('onclick="chooseCreateCustomerAccount()"'), "Welcome Create Customer remains");
assert(!html.includes("service_role"), "app still has no service_role key");

console.log("PASS: social auth UI hidden; email/password and OAuth implementation retained");
