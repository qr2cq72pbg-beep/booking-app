// Issue a one-time 9-digit customer app login code.
// Auth: caller JWT (verify_jwt = true). user_id is derived from the token.
// Plaintext code is returned ONCE and never stored or logged.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const CODE_TTL_MS = 30 * 60 * 1000;
const HMAC_PREFIX = "v1:";

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizeSlug(raw: unknown): string {
  return String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "")
    .replace(/^-+|-+$/g, "");
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

function randomNineDigitCode(): string {
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

function formatCode(canonical: string): string {
  return `${canonical.slice(0, 3)} ${canonical.slice(3, 6)} ${canonical.slice(6)}`;
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
    return jsonResponse({ ok: false, error: "not_configured" }, 503);
  }

  const authHeader = String(req.headers.get("Authorization") || "").trim();
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }

  let body: { business_slug?: string; reissue?: boolean } = {};
  try {
    body = (await req.json()) || {};
  } catch {
    body = {};
  }

  const anonKey = String(Deno.env.get("SUPABASE_ANON_KEY") || "").trim();
  if (!anonKey) {
    return jsonResponse({ ok: false, error: "not_configured" }, 503);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  const uid = String(userData?.user?.id || "").trim();
  if (userError || !uid) {
    return jsonResponse({ ok: false, error: "unauthorized" }, 401);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: profile } = await admin
    .from("user_profiles")
    .select("role")
    .eq("id", uid)
    .maybeSingle();
  if (String(profile?.role || "").trim().toLowerCase() !== "customer") {
    return jsonResponse({ ok: false, error: "forbidden" }, 403);
  }

  const requestedSlug = normalizeSlug(body.business_slug);
  const { data: memberships, error: memError } = await admin
    .from("business_customers")
    .select("business_id, approval_status")
    .eq("customer_user_id", uid);

  if (memError) {
    return jsonResponse({ ok: false, error: "issue_failed" }, 500);
  }

  const rememberedIds = (Array.isArray(memberships) ? memberships : [])
    .filter((row) => {
      const status = String(row?.approval_status || "").trim().toLowerCase();
      return status === "approved" || status === "pending";
    })
    .map((row) => String(row.business_id || "").trim())
    .filter(Boolean);

  if (!rememberedIds.length) {
    return jsonResponse({ ok: false, error: "issue_failed" }, 400);
  }

  const { data: settingsRows, error: settingsError } = await admin
    .from("business_settings")
    .select("business_id, business_slug")
    .in("business_id", rememberedIds);

  if (settingsError) {
    return jsonResponse({ ok: false, error: "issue_failed" }, 500);
  }

  const withSlug = (Array.isArray(settingsRows) ? settingsRows : [])
    .map((row) => ({
      business_id: String(row.business_id || "").trim(),
      business_slug: normalizeSlug(row.business_slug),
    }))
    .filter((row) => row.business_id && row.business_slug);

  let chosen = requestedSlug
    ? withSlug.find((row) => row.business_slug === requestedSlug) || null
    : withSlug.length === 1
      ? withSlug[0]
      : null;
  if (!chosen) {
    return jsonResponse({ ok: false, error: "issue_failed" }, 400);
  }

  const nowIso = new Date().toISOString();
  const { data: activeRows } = await admin
    .from("customer_app_login_codes")
    .select("id, expires_at")
    .eq("user_id", uid)
    .eq("originating_business_id", chosen.business_id)
    .is("consumed_at", null)
    .is("revoked_at", null)
    .gt("expires_at", nowIso)
    .order("created_at", { ascending: false })
    .limit(1);

  const active = Array.isArray(activeRows) && activeRows[0] ? activeRows[0] : null;
  if (active && body.reissue !== true) {
    return jsonResponse({
      ok: true,
      issued: false,
      active: true,
      expires_at: active.expires_at,
    });
  }

  await admin
    .from("customer_app_login_codes")
    .update({ revoked_at: nowIso })
    .eq("user_id", uid)
    .eq("originating_business_id", chosen.business_id)
    .is("consumed_at", null)
    .is("revoked_at", null);

  const expiresAt = new Date(Date.now() + CODE_TTL_MS).toISOString();
  let issuedCode = "";
  let insertOk = false;
  for (let i = 0; i < 5; i++) {
    const canonical = randomNineDigitCode();
    const codeHmac = await hmacHex(hmacSecret, HMAC_PREFIX + canonical);
    const { error: insertError } = await admin.from("customer_app_login_codes").insert({
      user_id: uid,
      originating_business_id: chosen.business_id,
      code_hmac: codeHmac,
      expires_at: expiresAt,
    });
    if (!insertError) {
      issuedCode = canonical;
      insertOk = true;
      break;
    }
    const dup =
      String(insertError.code || "") === "23505" ||
      /duplicate|unique/i.test(String(insertError.message || ""));
    if (!dup) break;
  }
  if (!insertOk || !issuedCode) {
    return jsonResponse({ ok: false, error: "issue_failed" }, 500);
  }

  return jsonResponse({
    ok: true,
    issued: true,
    code: issuedCode,
    code_display: formatCode(issuedCode),
    expires_at: expiresAt,
    ttl_seconds: Math.floor(CODE_TTL_MS / 1000),
  });
});
