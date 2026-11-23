// Local test for logic.ts with an in-memory fake of the database and Auth.
// Run: node supabase/functions/staff-access/logic.test.ts   (Node 23.6+)
import {
  CODE_HMAC_PREFIX,
  handleStaffAccess,
  hmacHex,
  normalizeCode,
  randomNineDigitCode,
  type Deps,
} from "./logic.ts";

const SECRET = "x".repeat(40);
const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const STAFF = "33333333-3333-4333-8333-333333333333";
const NOW = Date.parse("2026-11-20T10:00:00Z");

type Code = { id: string; hmac: string; staff: string; consumed: boolean; revoked: boolean; expires: number };

function makeWorld() {
  const w = {
    staff: { id: STAFF, business: OWNER, active: true, enabled: false, user: null as string | null },
    codes: [] as Code[],
    users: new Map<string, string>(),
    deleted: [] as string[],
    rpcCalls: [] as string[],
    rateLimited: false,
    nextCode: "482731946",
    linkRace: null as string | null,
  };
  const deps: Deps = {
    hmacSecret: SECRET,
    now: () => NOW,
    getUserId: async (h) => (h === "Bearer owner" ? OWNER : h === "Bearer other" ? OTHER : null),
    isBusinessOwner: async (uid) => uid === OWNER,
    rpc: async (name, args) => {
      w.rpcCalls.push(name);
      switch (name) {
        case "customer_app_login_touch_rate_limit":
          return { data: w.rateLimited, error: null };
        case "_issue_staff_access_code_core": {
          if (args.p_staff_id !== w.staff.id || args.p_business_id !== w.staff.business) {
            return { data: null, error: { message: "Staff member not found for this business." } };
          }
          w.codes.forEach((c) => { if (!c.consumed) c.revoked = true; });
          w.codes.push({ id: "code-" + w.codes.length, hmac: String(args.p_code_hmac), staff: STAFF, consumed: false,
            revoked: false, expires: Date.parse(String(args.p_expires_at)) });
          w.staff.enabled = true;
          return { data: { ok: true }, error: null };
        }
        case "_staff_access_redeem_begin": {
          const c = w.codes.find((x) => x.hmac === args.p_code_hmac);
          if (!c || c.consumed || c.revoked || c.expires <= NOW || !w.staff.active || !w.staff.enabled) {
            return { data: { ok: false }, error: null };
          }
          return { data: { ok: true, code_id: c.id, staff_id: STAFF, business_id: OWNER, access_user_id: w.staff.user }, error: null };
        }
        case "_staff_access_link_user": {
          if (w.linkRace && !w.staff.user) w.staff.user = w.linkRace;
          const linkedNew = !w.staff.user;
          if (!w.staff.user) w.staff.user = String(args.p_user_id);
          return { data: { ok: true, access_user_id: w.staff.user, linked_new: linkedNew }, error: null };
        }
        case "_staff_access_redeem_finish": {
          const c = w.codes.find((x) => x.id === args.p_code_id);
          if (!c || c.consumed || c.revoked) return { data: false, error: null };
          c.consumed = true;
          return { data: true, error: null };
        }
        case "_revoke_staff_access_core": {
          if (args.p_staff_id !== w.staff.id || args.p_business_id !== w.staff.business) {
            return { data: null, error: { message: "Staff member not found for this business." } };
          }
          const prev = w.staff.user;
          w.staff.enabled = false;
          w.staff.user = null;
          w.codes.forEach((c) => { if (!c.consumed) c.revoked = true; });
          return { data: { ok: true, previous_user_id: prev }, error: null };
        }
      }
      return { data: null, error: { message: "unknown rpc " + name } };
    },
    createStaffUser: async ({ email }) => {
      const id = "44444444-4444-4444-8444-44444444444" + w.users.size;
      w.users.set(id, email);
      return id;
    },
    getUserEmail: async (id) => w.users.get(id) || (id === w.linkRace ? "race@staff.gt-termin.invalid" : null),
    magicLinkTokenHash: async (email) => ({ hashedToken: "hash-for-" + email, type: "magiclink" }),
    deleteUser: async (id) => { w.deleted.push(id); w.users.delete(id); },
    randomCode: () => w.nextCode,
    randomSuffix: () => "abc123",
  };
  return { w, deps };
}

function post(body: unknown, auth?: string, ip = "1.2.3.4"): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json", "x-forwarded-for": ip };
  if (auth) headers.Authorization = auth;
  return new Request("https://fn.local/staff-access", { method: "POST", headers, body: JSON.stringify(body) });
}

let passed = 0;
let failed = 0;
function ok(label: string, cond: boolean, detail = "") {
  if (cond) { passed++; console.log("ok - " + label); } else { failed++; console.log("FAIL - " + label + (detail ? " (" + detail + ")" : "")); }
}

// Helpers
ok("normalizeCode strips spaces and dashes", normalizeCode("482 731-946") === "482731946");
for (let i = 0; i < 200; i++) {
  const c = randomNineDigitCode();
  if (!/^[1-9]\d{8}$/.test(c)) { ok("random code format", false, c); break; }
  if (i === 199) ok("random codes are always 9 digits, no leading zero", true);
}
ok("HMAC is deterministic and prefixed",
  (await hmacHex(SECRET, CODE_HMAC_PREFIX + "1")) === (await hmacHex(SECRET, "staff:v1:1"))
  && (await hmacHex(SECRET, "staff:v1:1")) !== (await hmacHex(SECRET, "v1:1")));

{
  const { deps } = makeWorld();
  ok("OPTIONS answers CORS", (await handleStaffAccess(new Request("https://fn.local", { method: "OPTIONS" }), deps)).status === 200);
  ok("GET is rejected", (await handleStaffAccess(new Request("https://fn.local"), deps)).status === 405);
  ok("unknown action → 400", (await handleStaffAccess(post({ action: "x" }), deps)).status === 400);
  ok("missing secret → 503", (await handleStaffAccess(post({ action: "redeem" }), { ...deps, hmacSecret: "short" })).status === 503);
}

// Issue
{
  const { w, deps } = makeWorld();
  ok("issue without login → 401", (await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }), deps)).status === 401);
  ok("issue by a non-owner → 403", (await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer other"), deps)).status === 403);
  ok("issue with a bad staff id → 400", (await handleStaffAccess(post({ action: "issue_code", staff_id: "x" }, "Bearer owner"), deps)).status === 400);
  const res = await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer owner"), deps);
  const body = await res.json();
  ok("owner gets a formatted code valid 24 h",
    res.status === 200 && body.code === "482 731 946" && body.expires_at === new Date(NOW + 86400000).toISOString());
  ok("only the HMAC is stored, never the code",
    w.codes.length === 1 && w.codes[0].hmac === (await hmacHex(SECRET, CODE_HMAC_PREFIX + "482731946")) && !w.codes[0].hmac.includes("482731946"));
  const foreign = await handleStaffAccess(post({ action: "issue_code", staff_id: "55555555-5555-4555-8555-555555555555" }, "Bearer owner"), deps);
  ok("issue for unknown staff → 404", foreign.status === 404);
}

// Redeem
{
  const { w, deps } = makeWorld();
  await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer owner"), deps);
  w.rateLimited = true;
  ok("rate limited → 429", (await handleStaffAccess(post({ action: "redeem", code: "482731946" }), deps)).status === 429);
  w.rateLimited = false;
  ok("malformed code → 401", (await handleStaffAccess(post({ action: "redeem", code: "12" }), deps)).status === 401);
  ok("wrong code → 401", (await handleStaffAccess(post({ action: "redeem", code: "111111111" }), deps)).status === 401);

  const res = await handleStaffAccess(post({ action: "redeem", code: "482 731 946" }), deps);
  const body = await res.json();
  ok("valid code creates the employee account and returns a token hash",
    res.status === 200 && body.ok === true && body.type === "magiclink"
    && String(body.token_hash).startsWith("hash-for-staff-" + STAFF) && w.staff.user !== null);
  ok("response never contains the code, HMAC or account id",
    !JSON.stringify(body).includes("482731946") && !JSON.stringify(body).includes(w.codes[0].hmac)
    && !JSON.stringify(body).includes(String(w.staff.user)));
  ok("the same code cannot be used twice", (await handleStaffAccess(post({ action: "redeem", code: "482731946" }), deps)).status === 401);

  // Second device: new code, existing account is reused (no new account).
  w.nextCode = "555444333";
  await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer owner"), deps);
  const usersBefore = w.users.size;
  const second = await handleStaffAccess(post({ action: "redeem", code: "555444333" }), deps);
  ok("second device signs in to the same account", second.status === 200 && w.users.size === usersBefore);

  // Revoke
  const linked = String(w.staff.user);
  ok("revoke without login → 401", (await handleStaffAccess(post({ action: "revoke", staff_id: STAFF }), deps)).status === 401);
  const rv = await handleStaffAccess(post({ action: "revoke", staff_id: STAFF }, "Bearer owner"), deps);
  ok("revoke switches access off and deletes the account (all sessions end)",
    rv.status === 200 && !w.staff.enabled && w.staff.user === null && w.deleted.includes(linked));
  ok("revoke for unknown staff → 404",
    (await handleStaffAccess(post({ action: "revoke", staff_id: "55555555-5555-4555-8555-555555555555" }, "Bearer owner"), deps)).status === 404);
}

// Race: another device linked an account between begin and link.
{
  const { w, deps } = makeWorld();
  await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer owner"), deps);
  w.linkRace = "66666666-6666-4666-8666-666666666666";
  const res = await handleStaffAccess(post({ action: "redeem", code: "482731946" }), deps);
  const body = await res.json();
  ok("race: the existing account wins and the extra one is deleted",
    res.status === 200 && body.token_hash === "hash-for-race@staff.gt-termin.invalid" && w.deleted.length === 1);
}

// Deactivated staff cannot redeem.
{
  const { w, deps } = makeWorld();
  await handleStaffAccess(post({ action: "issue_code", staff_id: STAFF }, "Bearer owner"), deps);
  w.staff.active = false;
  ok("deactivated member cannot redeem", (await handleStaffAccess(post({ action: "redeem", code: "482731946" }), deps)).status === 401);
}

console.log(`passed=${passed} failed=${failed}`);
if (failed) process.exit(1);
