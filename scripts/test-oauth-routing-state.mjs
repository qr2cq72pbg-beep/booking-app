#!/usr/bin/env node
/**
 * Executable OAuth routing / recovery state-machine tests.
 * Loads the live decision helpers from index.html. Does not call Supabase,
 * create users, or perform a live Google OAuth round trip.
 */

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
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

const start = html.indexOf("// <xbook-oauth-route-decision>");
const end = html.indexOf("// </xbook-oauth-route-decision>");
assert(start >= 0 && end > start, "oauth route decision helpers are missing from index.html");
const source = html.slice(start, end + "// </xbook-oauth-route-decision>".length);
const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(source, sandbox);

const {
  resolveOAuthPostAuthDecision,
  resolveAuthRetryPlan,
  applyRecoveryIsolation,
  sanitizeAuthDiagDetail
} = sandbox;

assert(typeof resolveOAuthPostAuthDecision === "function", "resolveOAuthPostAuthDecision loaded");
assert(typeof resolveAuthRetryPlan === "function", "resolveAuthRetryPlan loaded");
assert(typeof applyRecoveryIsolation === "function", "applyRecoveryIsolation loaded");
assert(typeof sanitizeAuthDiagDetail === "function", "sanitizeAuthDiagDetail loaded");

function createShell(overrides = {}) {
  return Object.assign(
    {
      welcomeVisible: true,
      authVisible: true,
      modeView: "visible",
      overlay: "hidden",
      overlayKind: "",
      session: false,
      roleStatus: "none",
      role: "",
      pendingIntent: "",
      pendingValid: false,
      pendingExpired: false,
      writeCalls: 0,
      remainingWriteFailures: 0,
      signedOut: false,
      screen: "welcome",
      routed: false,
      lastAction: ""
    },
    overrides
  );
}

function applyDecisionToShell(shell, decision) {
  shell.lastAction = decision.action;
  if (decision.hideWelcome) {
    shell.welcomeVisible = false;
    shell.authVisible = false;
    shell.modeView = "hidden";
  }
  if (decision.action === "recovery") {
    Object.assign(shell, applyRecoveryIsolation(shell));
    shell.overlayKind = decision.recoveryKind;
    shell.screen = "recovery";
  } else if (decision.action === "admin-onboarding") {
    shell.overlay = "hidden";
    shell.screen = "admin-onboarding";
    shell.welcomeVisible = false;
  } else if (decision.action === "customer-onboarding") {
    shell.overlay = "hidden";
    shell.screen = "customer-onboarding";
    shell.welcomeVisible = false;
  } else if (decision.action === "admin-shell") {
    shell.overlay = "hidden";
    shell.screen = "admin-shell";
    shell.welcomeVisible = false;
  } else if (decision.action === "customer-shell") {
    shell.overlay = "hidden";
    shell.screen = "customer-shell";
    shell.welcomeVisible = false;
  } else if (decision.action === "welcome") {
    shell.overlay = "hidden";
    shell.overlayKind = "";
    shell.welcomeVisible = true;
    shell.modeView = "visible";
    shell.screen = "welcome";
  } else if (decision.action === "ignore-duplicate") {
    /* leave current screen */
  }
  return decision;
}

function completeMissingRoleWrite(shell) {
  shell.writeCalls += 1;
  if (shell.remainingWriteFailures > 0) {
    shell.remainingWriteFailures -= 1;
    return "write-failed";
  }
  return shell.pendingIntent === "customer" ? "success-customer" : "success-admin";
}

function routeAfterOAuth(shell, extras = {}) {
  const decision = resolveOAuthPostAuthDecision({
    hasSession: shell.session,
    roleStatus: shell.roleStatus,
    role: shell.role,
    pendingIntent: shell.pendingIntent,
    pendingValid: shell.pendingValid,
    pendingExpired: shell.pendingExpired,
    writeStatus: extras.writeStatus || "",
    duplicateCallback: extras.duplicateCallback === true,
    alreadyRouted: extras.alreadyRouted === true || shell.routed
  });

  if (decision.action === "attempt-write") {
    const writeStatus = completeMissingRoleWrite(shell);
    const afterWrite = resolveOAuthPostAuthDecision({
      hasSession: shell.session,
      roleStatus: "missing",
      role: "",
      pendingIntent: shell.pendingIntent,
      pendingValid: shell.pendingValid,
      pendingExpired: shell.pendingExpired,
      writeStatus
    });
    if (writeStatus === "success-admin") {
      shell.roleStatus = "resolved";
      shell.role = "admin";
    } else if (writeStatus === "success-customer") {
      shell.roleStatus = "resolved";
      shell.role = "customer";
    }
    applyDecisionToShell(shell, afterWrite);
    if (afterWrite.action !== "ignore-duplicate") shell.routed = true;
    return afterWrite;
  }

  applyDecisionToShell(shell, decision);
  if (decision.action !== "ignore-duplicate") shell.routed = true;
  return decision;
}

function retryShell(shell) {
  const plan = resolveAuthRetryPlan(shell.overlayKind);
  assert(plan.keepOverlayIsolated, "retry must keep recovery isolated from Welcome");
  shell.overlay = "loading";
  shell.welcomeVisible = false;
  if (plan.operation === "write-role" || plan.operation === "choose-role" || plan.operation === "reload-role") {
    return routeAfterOAuth(shell);
  }
  return routeAfterOAuth(shell);
}

function returnToWelcome(shell) {
  shell.overlay = "hidden";
  shell.overlayKind = "";
  shell.welcomeVisible = true;
  shell.modeView = "visible";
  shell.authVisible = false;
  shell.screen = "welcome";
}

function signOut(shell) {
  shell.session = false;
  shell.role = "";
  shell.roleStatus = "none";
  shell.signedOut = true;
  shell.pendingIntent = "";
  shell.pendingValid = false;
  returnToWelcome(shell);
}

// 1. OAuth success, missing role, valid Business intent
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true
  });
  const decision = routeAfterOAuth(shell);
  assert(decision.action === "admin-onboarding", "business intent + write success routes to business onboarding");
  assert(shell.screen === "admin-onboarding", "business onboarding screen is active");
  assert(shell.welcomeVisible === false, "Welcome is hidden after business OAuth success");
  assert(shell.writeCalls === 1, "business missing-role path writes once");
}

// 2. OAuth success, missing role, valid Customer intent
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "customer",
    pendingValid: true
  });
  const decision = routeAfterOAuth(shell);
  assert(decision.action === "customer-onboarding", "customer intent + write success routes to customer onboarding");
  assert(shell.screen === "customer-onboarding", "customer onboarding screen is active");
  assert(shell.welcomeVisible === false, "Welcome is hidden after customer OAuth success");
}

// 3. Role-write failure
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true,
    remainingWriteFailures: 1
  });
  const decision = routeAfterOAuth(shell);
  assert(decision.action === "recovery", "write failure shows recovery");
  assert(decision.recoveryKind === "write-failed", "write failure kind is write-failed");
  assert(decision.retryOperation === "write-role", "retry must retry the role write");
  assert(shell.welcomeVisible === false, "write-failure recovery hides Welcome");
  assert(shell.overlay === "error", "write-failure recovery uses the error overlay");
  assert(shell.overlayBlocksWelcome === true, "write-failure recovery blocks Welcome");
}

// 4. Missing or expired signup intent
{
  const missing = createShell({
    session: true,
    roleStatus: "missing"
  });
  const missingDecision = routeAfterOAuth(missing);
  assert(missingDecision.recoveryKind === "missing-intent", "missing pending intent is missing-intent");
  assert(missing.welcomeVisible === false, "missing-intent recovery hides Welcome");

  const expired = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: false,
    pendingExpired: true
  });
  const expiredDecision = routeAfterOAuth(expired);
  assert(expiredDecision.recoveryKind === "missing-intent", "expired pending intent is missing-intent");
  assert(expiredDecision.retryOperation === "choose-role", "expired intent asks the user to choose");
}

// 5. Retry after transient failure
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true,
    remainingWriteFailures: 1
  });
  routeAfterOAuth(shell);
  assert(shell.screen === "recovery", "first write failure lands on recovery");
  const retried = retryShell(shell);
  assert(retried.action === "admin-onboarding", "retry after transient write failure reaches business onboarding");
  assert(shell.writeCalls === 2, "retry performs a second role write");
  assert(shell.welcomeVisible === false, "retry does not reopen Welcome");
}

// 6. Existing account role is preserved
{
  const admin = createShell({
    session: true,
    roleStatus: "resolved",
    role: "admin",
    pendingIntent: "customer",
    pendingValid: true
  });
  const adminDecision = routeAfterOAuth(admin);
  assert(adminDecision.action === "admin-shell", "existing admin is not overwritten by customer intent");
  assert(admin.writeCalls === 0, "existing admin does not write a new role");

  const customer = createShell({
    session: true,
    roleStatus: "resolved",
    role: "customer",
    pendingIntent: "business",
    pendingValid: true
  });
  const customerDecision = routeAfterOAuth(customer);
  assert(customerDecision.action === "customer-shell", "existing customer is not overwritten by business intent");
  assert(customer.writeCalls === 0, "existing customer does not write a new role");
}

// 7. Duplicate callback
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true
  });
  routeAfterOAuth(shell);
  const duplicate = routeAfterOAuth(shell, { duplicateCallback: true, alreadyRouted: true });
  assert(duplicate.action === "ignore-duplicate", "second callback is ignored");
  assert(shell.writeCalls === 1, "duplicate callback does not write a second role");
  assert(shell.screen === "admin-onboarding", "duplicate callback leaves the first route in place");
}

// 8. Recovery screen isolation
{
  const isolated = applyRecoveryIsolation({
    welcomeVisible: true,
    modeView: "visible",
    authView: "visible",
    overlay: "hidden"
  });
  assert(isolated.welcomeVisible === false, "isolation hides Welcome");
  assert(isolated.modeView === "hidden", "isolation hides modeView");
  assert(isolated.authView === "hidden", "isolation hides authView");
  assert(isolated.overlay === "error", "isolation shows the error overlay");
  assert(isolated.overlayBlocksWelcome === true, "isolation marks Welcome as blocked");
  assert(html.includes("body.app-shell-blocking #modeView"), "blocking CSS hides Welcome under the overlay");
  assert(html.includes("hideAllViews();\n    debugNavTrace(\"showUnresolvedAccountTypeRecovery\""), "recovery calls hideAllViews before showing overlay");
}

// 9. Return to Welcome
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true,
    remainingWriteFailures: 1
  });
  routeAfterOAuth(shell);
  returnToWelcome(shell);
  assert(shell.screen === "welcome", "Back to Welcome restores the Welcome screen");
  assert(shell.overlay === "hidden", "Back to Welcome closes recovery");
  assert(shell.welcomeVisible === true, "Welcome is visible after Back to Welcome");
}

// 10. Sign out
{
  const shell = createShell({
    session: true,
    roleStatus: "missing",
    pendingIntent: "business",
    pendingValid: true,
    remainingWriteFailures: 1
  });
  routeAfterOAuth(shell);
  signOut(shell);
  assert(shell.signedOut === true, "Sign Out clears the local session flag");
  assert(shell.session === false, "Sign Out drops the session");
  assert(shell.screen === "welcome", "Sign Out returns to Welcome");
  assert(shell.overlay === "hidden", "Sign Out closes recovery");
}

{
  const leaked = sanitizeAuthDiagDetail({
    errorMessage: "user test@example.com failed",
    access_token: "secret-token",
    pendingIntent: "business",
    hasSession: true
  });
  assert(leaked.errorMessage === "user [redacted-email] failed", "diagnostics redact emails");
  assert(leaked.pendingIntent === "business", "diagnostics keep intent");
  assert(!Object.prototype.hasOwnProperty.call(leaked, "access_token"), "diagnostics drop token fields");
}

assert(html.includes("retryUnresolvedAccountType"), "Retry uses the dedicated unresolved retry path");
assert(html.includes("insertOnly: usedInsert"), "first role assignment inserts instead of updating an immutable role");
assert(html.includes('kind === "write-failed"'), "recovery distinguishes a failed role write");
assert(html.includes("reason === \"resume\" && appShellState === APP_SHELL_STATE.ERROR"), "resume does not re-open Welcome under recovery");

console.log("PASS: OAuth routing / recovery state transitions");
console.log("SKIP: live Google OAuth end-to-end on a physical iPhone was not performed.");
