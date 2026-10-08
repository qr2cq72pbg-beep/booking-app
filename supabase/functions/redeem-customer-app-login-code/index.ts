// Redeem a one-time 9-digit customer app login code.
// Public (unauthenticated). Returns short-lived token_hash for supabase.auth.verifyOtp.
// Never logs plaintext code, HMAC, or token_hash.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const HMAC_PREFIX = "v1:";
const MAX_CODE_ATTEMPTS = 5;
const IP_WINDOW_MS = 15 * 60 * 1000;
const IP_WINDOW_LIMIT = 8;
const GENERIC_ERROR = "invalid_code";

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function genericInvalid(status = 401): Response {
  return jsonResponse({ ok: false, error: GENERIC_ERROR }, status);
}

function bytesToHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(message)
  );
  return bytesToHex(new Uint8Array(sig));
}

function normalizeCode(raw: unknown): string {
  return String(raw || "").replace(/\D/g, "");
}

function clientIp(req: Request): string {
  const cf = String(req.headers.get("cf-connecting-ip") || "").trim();
  if (cf) return cf;
  const forwarded = String(req.headers.get("x-forwarded-for") || "").split(",")[0].trim();
  if (forwarded) return forwarded;
  const real = String(req.headers.get("x-real-ip") || "").trim();
  return real || "unknown";
}

function windowStart(nowMs: number): string {
  const start = Math.floor(nowMs / IP_WINDOW_MS) * IP_WINDOW_MS;
  return new Date(start).toISOString();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);
  }

  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim();
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const hmacSecret = String(Deno.env.get("CUSTOMER_APP_LOGIN_HMAC_SECRET") || "").trim();
  if (!supabaseUrl || !serviceRoleKey || hmacSecret.length < 32) {
    return genericInvalid(503);
  }

  let body: { code?: string } = {};
  try {
    body = (await req.json()) || {};
  } catch {
    body = {};
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const ipHmac = await hmacHex(hmacSecret, "ip:" + clientIp(req));
  const now = Date.now();
  const win = windowStart(now);

  const { data: rateLimited, error: rateError } = await admin.rpc(
    "customer_app_login_touch_rate_limit",
    {
      p_ip_hmac: ipHmac,
      p_window_start: win,
      p_limit: IP_WINDOW_LIMIT,
    }
  );
  if (rateError) {
    return genericInvalid(503);
  }
  if (rateLimited === true) {
    return genericInvalid(429);
  }

  const canonical = normalizeCode(body.code);
  if (!/^[1-9]\d{8}$/.test(canonical)) {
    return genericInvalid();
  }

  const codeHmac = await hmacHex(hmacSecret, HMAC_PREFIX + canonical);
  const { data: row } = await admin
    .from("customer_app_login_codes")
    .select("id, user_id, originating_business_id, expires_at, consumed_at, revoked_at, failed_attempts")
    .eq("code_hmac", codeHmac)
    .maybeSingle();

  if (!row?.id) {
    return genericInvalid();
  }

  const nowIso = new Date().toISOString();
  const expired = String(row.expires_at || "") <= nowIso;
  const consumed = !!row.consumed_at;
  const revoked = !!row.revoked_at;
  const attempts = Number(row.failed_attempts || 0);

  if (expired || consumed || revoked || attempts >= MAX_CODE_ATTEMPTS) {
    if (!consumed && !revoked && (expired || attempts >= MAX_CODE_ATTEMPTS)) {
      await admin
        .from("customer_app_login_codes")
        .update({ revoked_at: nowIso, failed_attempts: attempts + 1 })
        .eq("id", row.id)
        .is("consumed_at", null);
    } else {
      await admin
        .from("customer_app_login_codes")
        .update({ failed_attempts: attempts + 1 })
        .eq("id", row.id);
    }
    return genericInvalid();
  }

  const { data: userRes, error: userErr } = await admin.auth.admin.getUserById(row.user_id);
  const email = String(userRes?.user?.email || "").trim();
  if (userErr || !email) {
    await admin
      .from("customer_app_login_codes")
      .update({ failed_attempts: attempts + 1 })
      .eq("id", row.id);
    return genericInvalid();
  }

  const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
  });
  const hashedToken = String(linkData?.properties?.hashed_token || "").trim();
  const verificationType = String(linkData?.properties?.verification_type || "magiclink").trim();
  if (linkError || !hashedToken) {
    await admin
      .from("customer_app_login_codes")
      .update({ failed_attempts: attempts + 1 })
      .eq("id", row.id);
    return genericInvalid();
  }

  const { data: consumedRow, error: consumeError } = await admin
    .from("customer_app_login_codes")
    .update({ consumed_at: nowIso })
    .eq("id", row.id)
    .is("consumed_at", null)
    .is("revoked_at", null)
    .gt("expires_at", nowIso)
    .lt("failed_attempts", MAX_CODE_ATTEMPTS)
    .select("id")
    .maybeSingle();

  if (consumeError || !consumedRow?.id) {
    return genericInvalid();
  }

  const { data: settings } = await admin
    .from("business_settings")
    .select("business_slug")
    .eq("business_id", row.originating_business_id)
    .maybeSingle();

  return jsonResponse({
    ok: true,
    token_hash: hashedToken,
    type: verificationType === "magiclink" ? "magiclink" : "email",
    business_slug: String(settings?.business_slug || "").trim(),
  });
});
