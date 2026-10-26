// Shared push delivery helpers (FCM HTTP v1 + APNs) for customer push functions.
// Copied unchanged from send-business-event-notification (the proven implementation);
// that function keeps its own copy so it is not affected by changes here.
const ANDROID_CHANNEL_ID = "xbook-business-push-v1";
const FCM_OAUTH_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token";

export interface FirebaseServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export interface ApnsOptions {
  keyId: string;
  teamId: string;
  privateKey: string;
  bundleId: string;
  production: boolean;
}

export type PushResult = { ok: boolean; error?: string; invalidToken?: boolean };

function base64UrlEncode(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (let i = 0; i < bytes.length; i += 1) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function parseFirebaseServiceAccount(
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

export async function sendFcmNotification(
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

export async function sendApnsNotification(
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
