// Employee app access (Phase F3): pairing codes for team members.
// Pure request handling with injected dependencies, so it can be tested
// without Supabase. index.ts wires the real Supabase clients.
//
// Actions (POST JSON { action, ... }):
//   issue_code { staff_id }  owner JWT  → one-time 9-digit code (24 h)
//   revoke     { staff_id }  owner JWT  → access off + employee account deleted
//   redeem     { code }      public     → token_hash for supabase.auth.verifyOtp
//
// Same model as the customer login codes: HMAC-only storage, the same
// HMAC secret with a separate "staff:" prefix, the same IP rate limit table.
// Never logs plaintext codes, HMACs or token hashes.

export const CODE_TTL_MS = 24 * 60 * 60 * 1000;
export const IP_WINDOW_MS = 15 * 60 * 1000;
export const IP_WINDOW_LIMIT = 8;
export const CODE_HMAC_PREFIX = "staff:v1:";
export const IP_HMAC_PREFIX = "staff-ip:";
export const STAFF_EMAIL_DOMAIN = "staff.gt-termin.invalid";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type RpcResult = { data: unknown; error: { message?: string } | null };

export type Deps = {
  hmacSecret: string;
  now: () => number;
  /** Verified user id from "Bearer <jwt>", or null. */
  getUserId: (authHeader: string) => Promise<string | null>;
  isBusinessOwner: (userId: string) => Promise<boolean>;
  rpc: (name: string, args: Record<string, unknown>) => Promise<RpcResult>;
  createStaffUser: (input: { email: string; staffId: string; businessId: string }) => Promise<string | null>;
  getUserEmail: (userId: string) => Promise<string | null>;
  magicLinkTokenHash: (email: string) => Promise<{ hashedToken: string; type: string } | null>;
  deleteUser: (userId: string) => Promise<void>;
  randomCode: () => string;
  randomSuffix: () => string;
};

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return bytesToHex(new Uint8Array(sig));
}

/** Uniform 9-digit code without modulo bias (same format as customer codes). */
export function randomNineDigitCode(): string {
  const min = 100000000;
  const range = 900000000;
  const max = 0x100000000;
  const limit = max - (max % range);
  const buf = new Uint32Array(1);
  let x = 0;
  do {
    crypto.getRandomValues(buf);
    x = buf[0] >>> 0;
  } while (x >= limit);
  return String(min + (x % range));
}

export function randomHexSuffix(): string {
  const buf = new Uint8Array(6);
  crypto.getRandomValues(buf);
  return bytesToHex(buf);
}

export function normalizeCode(raw: unknown): string {
  return String(raw ?? "").replace(/\D/g, "");
}

export function formatCode(canonical: string): string {
  return `${canonical.slice(0, 3)} ${canonical.slice(3, 6)} ${canonical.slice(6)}`;
}

export function clientIp(req: Request): string {
  const cf = String(req.headers.get("cf-connecting-ip") || "").trim();
  if (cf) return cf;
  const forwarded = String(req.headers.get("x-forwarded-for") || "").split(",")[0].trim();
  if (forwarded) return forwarded;
  return String(req.headers.get("x-real-ip") || "").trim() || "unknown";
}

function windowStart(nowMs: number): string {
  return new Date(Math.floor(nowMs / IP_WINDOW_MS) * IP_WINDOW_MS).toISOString();
}

function rpcObject(result: RpcResult): Record<string, unknown> | null {
  if (result.error || !result.data || typeof result.data !== "object") return null;
  return result.data as Record<string, unknown>;
}

const invalidCode = (status = 401) => json({ ok: false, error: "invalid_code" }, status);

async function requireOwner(req: Request, deps: Deps): Promise<string | Response> {
  const auth = String(req.headers.get("Authorization") || "").trim();
  if (!auth.toLowerCase().startsWith("bearer ")) return json({ ok: false, error: "unauthorized" }, 401);
  const uid = await deps.getUserId(auth);
  if (!uid) return json({ ok: false, error: "unauthorized" }, 401);
  if (!(await deps.isBusinessOwner(uid))) return json({ ok: false, error: "forbidden" }, 403);
  return uid;
}

async function issueCode(req: Request, body: Record<string, unknown>, deps: Deps): Promise<Response> {
  const owner = await requireOwner(req, deps);
  if (owner instanceof Response) return owner;
  const staffId = String(body.staff_id || "").trim();
  if (!UUID_RE.test(staffId)) return json({ ok: false, error: "invalid_staff" }, 400);

  const code = deps.randomCode();
  const codeHmac = await hmacHex(deps.hmacSecret, CODE_HMAC_PREFIX + code);
  const expiresAt = new Date(deps.now() + CODE_TTL_MS).toISOString();
  const res = await deps.rpc("_issue_staff_access_code_core", {
    p_business_id: owner,
    p_staff_id: staffId,
    p_code_hmac: codeHmac,
    p_expires_at: expiresAt,
    p_actor: owner,
  });
  if (res.error) {
    const notFound = /not found/i.test(String(res.error.message || ""));
    return json({ ok: false, error: notFound ? "staff_not_found" : "issue_failed" }, notFound ? 404 : 500);
  }
  return json({ ok: true, code: formatCode(code), expires_at: expiresAt });
}

async function revoke(req: Request, body: Record<string, unknown>, deps: Deps): Promise<Response> {
  const owner = await requireOwner(req, deps);
  if (owner instanceof Response) return owner;
  const staffId = String(body.staff_id || "").trim();
  if (!UUID_RE.test(staffId)) return json({ ok: false, error: "invalid_staff" }, 400);

  const res = await deps.rpc("_revoke_staff_access_core", { p_business_id: owner, p_staff_id: staffId });
  const data = rpcObject(res);
  if (!data) {
    const notFound = /not found/i.test(String(res.error?.message || ""));
    return json({ ok: false, error: notFound ? "staff_not_found" : "revoke_failed" }, notFound ? 404 : 500);
  }
  // Data access already stopped above; deleting the account ends all sessions.
  const previous = String(data.previous_user_id || "").trim();
  if (UUID_RE.test(previous)) {
    try {
      await deps.deleteUser(previous);
    } catch {
      /* access is already off; a leftover account can no longer read anything */
    }
  }
  return json({ ok: true });
}

async function redeem(req: Request, body: Record<string, unknown>, deps: Deps): Promise<Response> {
  const ipHmac = await hmacHex(deps.hmacSecret, IP_HMAC_PREFIX + clientIp(req));
  const limited = await deps.rpc("customer_app_login_touch_rate_limit", {
    p_ip_hmac: ipHmac,
    p_window_start: windowStart(deps.now()),
    p_limit: IP_WINDOW_LIMIT,
  });
  if (limited.error) return invalidCode(503);
  if (limited.data === true) return invalidCode(429);

  const canonical = normalizeCode(body.code);
  if (!/^[1-9]\d{8}$/.test(canonical)) return invalidCode();

  const codeHmac = await hmacHex(deps.hmacSecret, CODE_HMAC_PREFIX + canonical);
  const begin = rpcObject(await deps.rpc("_staff_access_redeem_begin", { p_code_hmac: codeHmac }));
  if (!begin || begin.ok !== true) return invalidCode();

  const staffId = String(begin.staff_id || "");
  const businessId = String(begin.business_id || "");
  const codeId = String(begin.code_id || "");
  let userId = String(begin.access_user_id || "").trim();

  if (!UUID_RE.test(userId)) {
    const email = `staff-${staffId}-${deps.randomSuffix()}@${STAFF_EMAIL_DOMAIN}`;
    const created = await deps.createStaffUser({ email, staffId, businessId });
    if (!created) return invalidCode(503);
    const link = rpcObject(await deps.rpc("_staff_access_link_user", { p_staff_id: staffId, p_user_id: created }));
    if (!link || link.ok !== true) {
      await deps.deleteUser(created).catch(() => {});
      return invalidCode();
    }
    userId = String(link.access_user_id || "");
    if (link.linked_new !== true) {
      // Another device linked first: keep that account, drop ours.
      await deps.deleteUser(created).catch(() => {});
    }
  }

  const email = await deps.getUserEmail(userId);
  if (!email) return invalidCode(503);
  const token = await deps.magicLinkTokenHash(email);
  if (!token?.hashedToken) return invalidCode(503);

  const finished = await deps.rpc("_staff_access_redeem_finish", { p_code_id: codeId });
  if (finished.error || finished.data !== true) return invalidCode();

  return json({
    ok: true,
    token_hash: token.hashedToken,
    type: token.type === "magiclink" ? "magiclink" : "email",
  });
}

export async function handleStaffAccess(req: Request, deps: Deps): Promise<Response> {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);
  if (!deps.hmacSecret || deps.hmacSecret.length < 32) return json({ ok: false, error: "not_configured" }, 503);

  let body: Record<string, unknown> = {};
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    body = {};
  }

  switch (String(body.action || "")) {
    case "issue_code":
      return await issueCode(req, body, deps);
    case "revoke":
      return await revoke(req, body, deps);
    case "redeem":
      return await redeem(req, body, deps);
    default:
      return json({ ok: false, error: "unknown_action" }, 400);
  }
}
