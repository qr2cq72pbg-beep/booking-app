// Business owner event push (customer_booking / customer_join).
// Auth: service_role bearer or BUSINESS_PUSH_DISPATCH_SECRET only.
// verify_jwt should be false; the function rejects anon / user JWTs.
// Loads the outbox row server-side. Clients cannot choose recipient or copy.

const FUNCTION_VERSION = "send-business-event-notification-v3";
const ANDROID_CHANNEL_ID = "xbook-business-push-v1";
const SENDING_STALE_MS = 2 * 60 * 1000;
const FCM_OAUTH_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-business-push-secret",
};

type EventType = "customer_booking" | "customer_join";
type Locale = "en" | "mk" | "sq";

interface OutboxEvent {
  id: string;
  business_id: string;
  event_type: EventType;
  source_key: string;
  source_id: string | null;
  payload: Record<string, unknown> | null;
  status: string;
  sent_at: string | null;
  last_attempt_at: string | null;
  attempt_count: number;
}

interface BusinessTokenRow {
  id: string;
  business_id: string;
  device_token: string;
  platform: string;
  locale: string | null;
}

interface FirebaseServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function unwrapEventId(raw: Record<string, unknown>): string {
  const direct = raw.event_id ?? raw.eventId ?? raw.id;
  if (typeof direct === "string" && direct.trim()) return direct.trim();

  const record = raw.record ?? raw.new ?? raw.NEW;
  if (record && typeof record === "object" && !Array.isArray(record)) {
    const id = (record as Record<string, unknown>).id;
    if (typeof id === "string" && id.trim()) return id.trim();
  }
  return "";
}

function isAuthorized(req: Request): boolean {
  const serviceRole = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const dispatchSecret = String(Deno.env.get("BUSINESS_PUSH_DISPATCH_SECRET") || "").trim();
  const bearer = (req.headers.get("Authorization") || "")
    .replace(/^Bearer\s+/i, "")
    .trim();
  const headerSecret = String(req.headers.get("x-business-push-secret") || "").trim();

  if (dispatchSecret && (bearer === dispatchSecret || headerSecret === dispatchSecret)) {
    return true;
  }
  if (serviceRole && bearer === serviceRole) {
    return true;
  }
  return false;
}

function normalizeLocale(value: unknown): Locale {
  const raw = String(value || "").trim().toLowerCase();
  if (raw === "mk" || raw === "en" || raw === "sq") return raw;
  return "en";
}

function payloadText(payload: Record<string, unknown> | null, key: string): string {
  if (!payload) return "";
  return String(payload[key] ?? "").trim();
}

function fallbackCustomerName(locale: Locale): string {
  if (locale === "mk") return "Клиент";
  if (locale === "sq") return "Klient";
  return "Customer";
}

function fallbackServiceName(locale: Locale): string {
  if (locale === "mk") return "термин";
  if (locale === "sq") return "termin";
  return "appointment";
}

function buildNotificationCopy(
  eventType: EventType,
  locale: Locale,
  payload: Record<string, unknown> | null,
): { title: string; body: string } {
  const customerName =
    payloadText(payload, "customer_name") || fallbackCustomerName(locale);
  const serviceName =
    payloadText(payload, "service_name") || fallbackServiceName(locale);
  const date = payloadText(payload, "date");
  const time = payloadText(payload, "time");
  const when = date && time ? `${date} ${locale === "en" ? "at" : locale === "sq" ? "në" : "во"} ${time}` : date || time;

  if (eventType === "customer_join") {
    if (locale === "mk") {
      return {
        title: "Нов клиент",
        body: `${customerName} се приклучи на вашиот бизнис.`,
      };
    }
    if (locale === "sq") {
      return {
        title: "Klient i ri",
        body: `${customerName} u bashkua me biznesin tuaj.`,
      };
    }
    return {
      title: "New customer",
      body: `${customerName} joined your business.`,
    };
  }

  if (locale === "mk") {
    return {
      title: "Нов термин",
      body: when
        ? `${customerName} закажа ${serviceName} — ${date} во ${time}.`
        : `${customerName} закажа ${serviceName}.`,
    };
  }
  if (locale === "sq") {
    return {
      title: "Termin i ri",
      body: when
        ? `${customerName} rezervoi ${serviceName} — ${date} në ${time}.`
        : `${customerName} rezervoi ${serviceName}.`,
    };
  }
  return {
    title: "New appointment",
    body: when
      ? `${customerName} booked ${serviceName} — ${date} at ${time}.`
      : `${customerName} booked ${serviceName}.`,
  };
}

function routingData(event: OutboxEvent): Record<string, string> {
  return {
    type: event.event_type,
    event_id: event.id,
    business_id: event.business_id,
  };
}

function base64UrlEncode(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function parseFirebaseServiceAccount(
  rawSecret: string,
): { creds: FirebaseServiceAccount | null; error: string } {
  const raw = String(rawSecret || "").trim();
  if (!raw) {
    return { creds: null, error: "FIREBASE_SERVICE_ACCOUNT_JSON is not set" };
  }

  let parsed: Record<string, unknown>;
  try {
    const value = JSON.parse(raw);
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { creds: null, error: "FIREBASE_SERVICE_ACCOUNT_JSON must be a JSON object" };
    }
    parsed = value as Record<string, unknown>;
  } catch {
    return { creds: null, error: "FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON" };
  }

  const projectId = String(parsed.project_id || "").trim();
  const clientEmail = String(parsed.client_email || "").trim();
  let privateKey = String(parsed.private_key || "").trim();
  if (privateKey.includes("\\n")) {
    privateKey = privateKey.replace(/\\n/g, "\n");
  }

  if (!projectId || !clientEmail || !privateKey) {
    return {
      creds: null,
      error: "FIREBASE_SERVICE_ACCOUNT_JSON missing project_id, client_email, or private_key",
    };
  }

  return { creds: { project_id: projectId, client_email: clientEmail, private_key: privateKey }, error: "" };
}

function summarizeGoogleError(prefix: string, status: number, json: Record<string, unknown>): string {
  const oauthError = typeof json.error === "string" ? json.error.trim() : "";
  const oauthDesc = String(json.error_description || "").trim();
  const nested = json.error && typeof json.error === "object" && !Array.isArray(json.error)
    ? json.error as Record<string, unknown>
    : null;
  const apiStatus = String(nested?.status || "").trim();
  const apiMessage = String(nested?.message || "").trim();
  const details = Array.isArray(nested?.details) ? nested.details : [];
  let fcmCode = "";
  for (const detail of details) {
    if (!detail || typeof detail !== "object") continue;
    const code = String((detail as Record<string, unknown>).errorCode || "").trim();
    if (code) {
      fcmCode = code;
      break;
    }
  }

  const parts = [
    `${prefix} HTTP ${status}`,
    fcmCode,
    apiStatus || oauthError,
    apiMessage || oauthDesc,
  ].filter(Boolean);

  return parts.join(": ");
}

function isInvalidFcmRegistration(status: number, json: Record<string, unknown>): boolean {
  const nested = json.error && typeof json.error === "object" && !Array.isArray(json.error)
    ? json.error as Record<string, unknown>
    : null;
  const apiStatus = String(nested?.status || "").trim();
  const apiMessage = String(nested?.message || "").trim();
  const details = Array.isArray(nested?.details) ? nested.details : [];
  const codes = details
    .map((detail) =>
      detail && typeof detail === "object"
        ? String((detail as Record<string, unknown>).errorCode || "")
        : "",
    )
    .join(" ");

  if (/UNREGISTERED|SENDER_ID_MISMATCH/i.test(codes)) return true;
  if (status === 404 && /NOT_FOUND|UNREGISTERED/i.test(`${apiStatus} ${codes}`)) return true;
  if (/registration token is not a valid FCM registration token/i.test(apiMessage)) return true;
  return false;
}

async function importGoogleServiceAccountKey(privateKeyPem: string): Promise<CryptoKey> {
  const pemBody = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binaryDer = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    binaryDer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

async function mintFirebaseAccessToken(
  creds: FirebaseServiceAccount,
): Promise<{ token: string } | { error: string }> {
  try {
    const now = Math.floor(Date.now() / 1000);
    const header = { alg: "RS256", typ: "JWT" };
    const payload = {
      iss: creds.client_email,
      sub: creds.client_email,
      aud: FCM_OAUTH_TOKEN_URL,
      iat: now,
      exp: now + 3600,
      scope: FCM_OAUTH_SCOPE,
    };
    const unsigned = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(payload))}`;
    const key = await importGoogleServiceAccountKey(creds.private_key);
    const signature = await crypto.subtle.sign(
      { name: "RSASSA-PKCS1-v1_5" },
      key,
      new TextEncoder().encode(unsigned),
    );
    const assertion = `${unsigned}.${base64UrlEncode(new Uint8Array(signature))}`;

    const res = await fetch(FCM_OAUTH_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    });

    const json = await res.json().catch(() => ({})) as Record<string, unknown>;
    if (!res.ok) {
      return { error: summarizeGoogleError("FCM OAuth", res.status, json) };
    }

    const accessToken = String(json.access_token || "").trim();
    if (!accessToken) {
      return { error: "FCM OAuth: access_token missing" };
    }
    return { token: accessToken };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { error: `FCM OAuth exception: ${message}` };
  }
}

async function importApnsPrivateKey(privateKeyPem: string): Promise<CryptoKey> {
  const pemBody = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binaryDer = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    binaryDer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

async function buildApnsProviderToken(
  keyId: string,
  teamId: string,
  privateKeyPem: string,
): Promise<string> {
  const header = { alg: "ES256", kid: keyId };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: teamId, iat: now };

  const base64url = (input: string) =>
    btoa(input)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

  const headerB64 = base64url(JSON.stringify(header));
  const payloadB64 = base64url(JSON.stringify(payload));
  const unsigned = `${headerB64}.${payloadB64}`;

  const key = await importApnsPrivateKey(privateKeyPem);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(unsigned),
  );

  const sigBytes = new Uint8Array(signature);
  const sigB64 = btoa(String.fromCharCode(...sigBytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  return `${unsigned}.${sigB64}`;
}

let cachedFirebaseAccessToken = "";
let cachedFirebaseAccessTokenExp = 0;

async function getFirebaseAccessToken(
  creds: FirebaseServiceAccount,
): Promise<{ token: string } | { error: string }> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedFirebaseAccessToken && cachedFirebaseAccessTokenExp > now + 60) {
    return { token: cachedFirebaseAccessToken };
  }

  const minted = await mintFirebaseAccessToken(creds);
  if ("error" in minted) return minted;

  cachedFirebaseAccessToken = minted.token;
  cachedFirebaseAccessTokenExp = now + 3500;
  return minted;
}

async function sendFcmNotification(
  creds: FirebaseServiceAccount,
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<{ ok: boolean; error?: string; invalidToken?: boolean }> {
  const auth = await getFirebaseAccessToken(creds);
  if ("error" in auth) {
    return { ok: false, error: auth.error };
  }

  try {
    const res = await fetch(
      `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(creds.project_id)}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${auth.token}`,
          "Content-Type": "application/json",
        },
        // Android data-only. A `notification` block makes Play Services
        // consume the message and skip FirebaseMessagingService when the
        // process is gone. Title/body stay in `data`.
        body: JSON.stringify({
          message: {
            token,
            data: {
              ...data,
              title,
              body,
              sound: "default",
              android_channel_id: ANDROID_CHANNEL_ID,
            },
            android: {
              priority: "high",
            },
          },
        }),
      },
    );

    const json = await res.json().catch(() => ({})) as Record<string, unknown>;
    if (!res.ok) {
      return {
        ok: false,
        error: summarizeGoogleError("FCM", res.status, json),
        invalidToken: isInvalidFcmRegistration(res.status, json),
      };
    }

    return { ok: true };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function sendApnsNotification(
  opts: {
    keyId: string;
    teamId: string;
    privateKey: string;
    bundleId: string;
    production: boolean;
  },
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<{ ok: boolean; error?: string; invalidToken?: boolean }> {
  try {
    const providerToken = await buildApnsProviderToken(
      opts.keyId,
      opts.teamId,
      opts.privateKey,
    );
    const host = opts.production
      ? "https://api.push.apple.com"
      : "https://api.sandbox.push.apple.com";

    const res = await fetch(`${host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${providerToken}`,
        "apns-topic": opts.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        aps: {
          alert: { title, body },
          sound: "default",
        },
        ...data,
      }),
    });

    if (res.ok) return { ok: true };

    const text = await res.text();
    const invalid = res.status === 410 || /BadDeviceToken|Unregistered/i.test(text);
    return {
      ok: false,
      error: `APNs ${res.status}: ${text}`,
      invalidToken: invalid,
    };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "Method not allowed" }, 405);
  }

  if (!isAuthorized(req)) {
    return jsonResponse({ ok: false, error: "Unauthorized." }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const firebaseAccount = parseFirebaseServiceAccount(
    Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "",
  );
  const apnsKeyId = Deno.env.get("APNS_KEY_ID") || "";
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID") || "";
  const apnsPrivateKey = (Deno.env.get("APNS_PRIVATE_KEY") || "").replace(
    /\\n/g,
    "\n",
  );
  const apnsBundleId = Deno.env.get("APNS_BUNDLE_ID") || "com.gtwebstudio.booking";
  const apnsProduction = Deno.env.get("APNS_PRODUCTION") === "true";

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(
      { ok: false, error: "Supabase service credentials missing." },
      503,
    );
  }

  let rawBody: Record<string, unknown>;
  try {
    rawBody = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: "Invalid JSON body." }, 400);
  }

  const eventId = unwrapEventId(rawBody);
  if (!eventId) {
    return jsonResponse({ ok: false, error: "event_id is required." }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: loaded, error: loadError } = await supabase
    .from("business_push_events")
    .select(
      "id, business_id, event_type, source_key, source_id, payload, status, sent_at, last_attempt_at, attempt_count",
    )
    .eq("id", eventId)
    .maybeSingle();

  if (loadError || !loaded) {
    return jsonResponse({ ok: false, error: "Event not found." }, 404);
  }

  const event = loaded as OutboxEvent;

  if (event.event_type !== "customer_booking" && event.event_type !== "customer_join") {
    return jsonResponse({ ok: false, error: "Unsupported event_type." }, 400);
  }

  if (event.sent_at || event.status === "sent") {
    return jsonResponse({
      ok: true,
      version: FUNCTION_VERSION,
      eventId: event.id,
      alreadySent: true,
    });
  }

  const lastAttemptMs = event.last_attempt_at
    ? Date.parse(event.last_attempt_at)
    : 0;
  const sendingFresh =
    event.status === "sending" &&
    lastAttemptMs > 0 &&
    Date.now() - lastAttemptMs < SENDING_STALE_MS;

  if (sendingFresh) {
    return jsonResponse({
      ok: true,
      version: FUNCTION_VERSION,
      eventId: event.id,
      inProgress: true,
    });
  }

  if (event.status === "sending") {
    await supabase
      .from("business_push_events")
      .update({
        status: "failed",
        last_error: "stale sending claim reset",
      })
      .eq("id", event.id)
      .eq("status", "sending")
      .is("sent_at", null);
  }

  const { data: claimed, error: claimError } = await supabase
    .from("business_push_events")
    .update({
      status: "sending",
      attempt_count: (event.attempt_count || 0) + 1,
      last_attempt_at: new Date().toISOString(),
      last_error: null,
    })
    .eq("id", event.id)
    .is("sent_at", null)
    .in("status", ["pending", "failed"])
    .select("id")
    .maybeSingle();

  if (claimError || !claimed) {
    return jsonResponse({
      ok: true,
      version: FUNCTION_VERSION,
      eventId: event.id,
      alreadySent: Boolean(event.sent_at || event.status === "sent"),
      inProgress: !event.sent_at && event.status !== "sent",
    });
  }

  const { data: tokenRows, error: tokensError } = await supabase
    .from("business_push_tokens")
    .select("id, business_id, device_token, platform, locale")
    .eq("business_id", event.business_id);

  if (tokensError) {
    await supabase
      .from("business_push_events")
      .update({
        status: "failed",
        last_error: tokensError.message || "token query failed",
      })
      .eq("id", event.id)
      .is("sent_at", null);

    return jsonResponse(
      { ok: false, error: "Could not load business tokens.", eventId: event.id },
      500,
    );
  }

  const tokens = (tokenRows || []) as BusinessTokenRow[];
  const routing = routingData(event);
  const hasFcm = Boolean(firebaseAccount.creds);
  const hasApns = Boolean(apnsKeyId && apnsTeamId && apnsPrivateKey);

  if (!tokens.length) {
    const sentAt = new Date().toISOString();
    await supabase
      .from("business_push_events")
      .update({
        status: "sent",
        sent_at: sentAt,
        last_error: null,
      })
      .eq("id", event.id)
      .is("sent_at", null);

    return jsonResponse({
      ok: true,
      version: FUNCTION_VERSION,
      eventId: event.id,
      tokenCount: 0,
      pushSuccessCount: 0,
      note: "no registered tokens",
    });
  }

  const pushResults: {
    tokenId: string;
    platform: string;
    ok: boolean;
    error?: string;
  }[] = [];
  const invalidTokenIds: string[] = [];
  let successCount = 0;

  for (const row of tokens) {
    const token = String(row.device_token || "").trim();
    const platform = String(row.platform || "").toLowerCase();
    if (!token) continue;

    const locale = normalizeLocale(row.locale);
    const copy = buildNotificationCopy(event.event_type, locale, event.payload);
    let result: { ok: boolean; error?: string; invalidToken?: boolean };

    if (platform === "android") {
      if (!firebaseAccount.creds) {
        result = { ok: false, error: firebaseAccount.error || "FCM not configured" };
      } else {
        result = await sendFcmNotification(
          firebaseAccount.creds,
          token,
          copy.title,
          copy.body,
          routing,
        );
      }
    } else if (platform === "ios") {
      if (!hasApns) {
        result = { ok: false, error: "APNs not configured" };
      } else {
        result = await sendApnsNotification(
          {
            keyId: apnsKeyId,
            teamId: apnsTeamId,
            privateKey: apnsPrivateKey,
            bundleId: apnsBundleId,
            production: apnsProduction,
          },
          token,
          copy.title,
          copy.body,
          routing,
        );
      }
    } else {
      result = { ok: false, error: `Unknown platform: ${platform}` };
    }

    pushResults.push({
      tokenId: row.id,
      platform,
      ok: result.ok,
      error: result.error,
    });

    if (result.ok) successCount += 1;
    if (result.invalidToken) invalidTokenIds.push(row.id);
  }

  if (invalidTokenIds.length) {
    await supabase
      .from("business_push_tokens")
      .delete()
      .eq("business_id", event.business_id)
      .in("id", invalidTokenIds);
  }

  if (successCount > 0) {
    const sentAt = new Date().toISOString();
    await supabase
      .from("business_push_events")
      .update({
        status: "sent",
        sent_at: sentAt,
        last_error: null,
      })
      .eq("id", event.id)
      .is("sent_at", null);

    return jsonResponse({
      ok: true,
      version: FUNCTION_VERSION,
      eventId: event.id,
      tokenCount: tokens.length,
      pushSuccessCount: successCount,
      pushFailureCount: pushResults.filter((r) => !r.ok).length,
      invalidTokenCount: invalidTokenIds.length,
      pushConfigured: { fcm: hasFcm, apns: hasApns },
      pushResults,
    });
  }

  const failureSummary = pushResults
    .map((r) => r.error)
    .filter(Boolean)
    .slice(0, 3)
    .join("; ");

  await supabase
    .from("business_push_events")
    .update({
      status: "failed",
      last_error: failureSummary || "all token deliveries failed",
    })
    .eq("id", event.id)
    .is("sent_at", null);

  return jsonResponse(
    {
      ok: false,
      version: FUNCTION_VERSION,
      eventId: event.id,
      tokenCount: tokens.length,
      pushSuccessCount: 0,
      pushFailureCount: pushResults.length,
      invalidTokenCount: invalidTokenIds.length,
      pushConfigured: { fcm: hasFcm, apns: hasApns },
      pushResults,
    },
    502,
  );
});
