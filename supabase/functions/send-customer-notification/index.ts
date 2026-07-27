// Business → Customer push notifications (one-way).
// Auth: admin JWT where sub === business_id.
// verify_jwt should be false; we validate JWT manually (same pattern as send-booking-email).
const FUNCTION_VERSION = "send-customer-notification-v1";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type RecipientType = "all" | "vip" | "selected";

const VALID_RECIPIENT_TYPES = new Set<RecipientType>(["all", "vip", "selected"]);

interface RequestBody {
  title?: string;
  message?: string;
  recipientType?: string;
  recipient_type?: string;
  recipientUserIds?: string[];
  recipient_user_ids?: string[];
  body?: RequestBody;
}

interface PushTokenRow {
  id: string;
  customer_user_id: string;
  device_token: string;
  platform: string;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isJwt(token: string): boolean {
  return token.split(".").length === 3;
}

function unwrapRequestBody(raw: RequestBody): RequestBody {
  if (raw?.body && typeof raw.body === "object" && !Array.isArray(raw.body)) {
    return { ...raw.body, ...raw };
  }
  return raw;
}

function normalizeRecipientType(value: unknown): RecipientType | null {
  const normalized = String(value || "").trim().toLowerCase();
  if (VALID_RECIPIENT_TYPES.has(normalized as RecipientType)) {
    return normalized as RecipientType;
  }
  return null;
}

function createApnsJwt(
  keyId: string,
  teamId: string,
  privateKeyPem: string,
): string {
  const header = { alg: "ES256", kid: keyId };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: teamId, iat: now };

  const encode = (obj: Record<string, unknown>) =>
    btoa(String.fromCharCode(...new TextEncoder().encode(JSON.stringify(obj))))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

  const unsigned = `${encode(header)}.${encode(payload)}`;

  const pemBody = privateKeyPem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binaryDer = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  return unsigned; // placeholder — use crypto.subtle in sendApns
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
  let sigB64 = btoa(String.fromCharCode(...sigBytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  return `${unsigned}.${sigB64}`;
}

async function sendFcmNotification(
  serverKey: string,
  token: string,
  title: string,
  body: string,
  data: Record<string, string>,
): Promise<{ ok: boolean; error?: string; invalidToken?: boolean }> {
  try {
    const res = await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: {
        Authorization: `key=${serverKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        to: token,
        notification: { title, body },
        data,
        priority: "high",
      }),
    });

    const json = await res.json().catch(() => ({}));
    if (!res.ok) {
      return {
        ok: false,
        error: `FCM HTTP ${res.status}: ${JSON.stringify(json)}`,
      };
    }

    if (json.failure > 0) {
      const result = json.results?.[0];
      const err = String(result?.error || "FCM failure");
      const invalid = /NotRegistered|InvalidRegistration|MismatchSenderId/i.test(err);
      return { ok: false, error: err, invalidToken: invalid };
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

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const fcmServerKey = Deno.env.get("FCM_SERVER_KEY") || "";
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

  let rawBody: RequestBody;
  try {
    rawBody = await req.json();
  } catch {
    return jsonResponse({ ok: false, error: "Invalid JSON body." }, 400);
  }

  const body = unwrapRequestBody(rawBody);
  const title = String(body.title || "").trim();
  const message = String(body.message || "").trim();
  const recipientType = normalizeRecipientType(
    body.recipientType ?? body.recipient_type,
  );

  if (!title || !message) {
    return jsonResponse(
      { ok: false, error: "title and message are required." },
      400,
    );
  }

  if (!recipientType) {
    return jsonResponse(
      { ok: false, error: "recipient_type must be all, vip, or selected." },
      400,
    );
  }

  const rawRecipientUserIds = [
    ...(Array.isArray(body.recipientUserIds) ? body.recipientUserIds : []),
    ...(Array.isArray(body.recipient_user_ids) ? body.recipient_user_ids : []),
  ];
  const selectedRecipientUserIds = [
    ...new Set(
      rawRecipientUserIds
        .map((id) => String(id || "").trim())
        .filter(Boolean),
    ),
  ];

  if (recipientType === "selected" && !selectedRecipientUserIds.length) {
    return jsonResponse(
      { ok: false, error: "Select at least one customer." },
      400,
    );
  }

  const authHeader = req.headers.get("Authorization") || "";
  const bearer = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!bearer || !isJwt(bearer)) {
    return jsonResponse({ ok: false, error: "Unauthorized." }, 401);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await supabase.auth.getUser(bearer);
  if (userError || !userData?.user?.id) {
    return jsonResponse({ ok: false, error: "Unauthorized." }, 401);
  }

  const businessId = userData.user.id;

  const { data: settings, error: settingsError } = await supabase
    .from("business_settings")
    .select("business_id")
    .eq("business_id", businessId)
    .maybeSingle();

  if (settingsError || !settings) {
    return jsonResponse({ ok: false, error: "Business not found." }, 403);
  }

  const { data: notification, error: notifError } = await supabase
    .from("notifications")
    .insert({
      business_id: businessId,
      title,
      message,
      recipient_type: recipientType,
      created_by: businessId,
    })
    .select("id")
    .single();

  if (notifError || !notification?.id) {
    console.error("send-customer-notification: insert failed", notifError);
    return jsonResponse(
      { ok: false, error: "Could not create notification." },
      500,
    );
  }

  const notificationId = notification.id as string;

  const recipientUserIdSet = new Set<string>();
  let crmLinkedRecipientCount = 0;

  if (recipientType === "selected") {
    for (const id of selectedRecipientUserIds) {
      recipientUserIdSet.add(id);
    }
  } else {
    let customersQuery = supabase
      .from("business_customers")
      .select("customer_user_id, email")
      .eq("business_id", businessId)
      .not("customer_user_id", "is", null);

    if (recipientType === "vip") {
      customersQuery = customersQuery.eq("is_vip", true);
    }

    const { data: customerRows, error: customersError } = await customersQuery;

    if (customersError) {
      console.error("send-customer-notification: customers query failed", customersError);
      return jsonResponse(
        { ok: false, error: "Could not resolve recipients.", notificationId },
        500,
      );
    }

    for (const row of customerRows || []) {
      const id = String(row.customer_user_id || "").trim();
      if (id) recipientUserIdSet.add(id);
    }
    crmLinkedRecipientCount = recipientUserIdSet.size;

    // CRM rows with email only: resolve via user_profiles when customer_user_id is missing.
    let unlinkedQuery = supabase
      .from("business_customers")
      .select("email")
      .eq("business_id", businessId)
      .is("customer_user_id", null)
      .not("email", "is", null);

    if (recipientType === "vip") {
      unlinkedQuery = unlinkedQuery.eq("is_vip", true);
    }

    const { data: unlinkedRows, error: unlinkedError } = await unlinkedQuery;
    if (unlinkedError) {
      console.error("send-customer-notification: unlinked CRM query failed", unlinkedError);
    } else {
      const crmEmails = [
        ...new Set(
          (unlinkedRows || [])
            .map((row) => String(row.email || "").trim().toLowerCase())
            .filter(Boolean),
        ),
      ];
      if (crmEmails.length) {
        const { data: profileRows, error: profilesError } = await supabase
          .from("user_profiles")
          .select("id, email")
          .in("email", crmEmails)
          .eq("role", "customer");

        if (profilesError) {
          console.error("send-customer-notification: user_profiles lookup failed", profilesError);
        } else {
          for (const profile of profileRows || []) {
            const id = String(profile.id || "").trim();
            if (id) recipientUserIdSet.add(id);
          }
        }
      }
    }

    // "All customers" also includes logged-in bookers even when CRM row lacks customer_user_id.
    if (recipientType === "all") {
      const { data: bookingRows, error: bookingsError } = await supabase
        .from("bookings")
        .select("customer_user_id")
        .eq("business_id", businessId)
        .not("customer_user_id", "is", null);

      if (bookingsError) {
        console.error("send-customer-notification: bookings recipient query failed", bookingsError);
      } else {
        for (const row of bookingRows || []) {
          const id = String(row.customer_user_id || "").trim();
          if (id) recipientUserIdSet.add(id);
        }
      }
    }
  }

  const recipientUserIds = [...recipientUserIdSet];
  const crmRecipientCount =
    recipientType === "selected" ? selectedRecipientUserIds.length : crmLinkedRecipientCount;
  const bookingRecipientCount =
    recipientType === "all"
      ? Math.max(0, recipientUserIds.length - crmLinkedRecipientCount)
      : 0;

  console.log("send-customer-notification: resolved recipients", {
    notificationId,
    recipientType,
    crmRecipientCount,
    bookingRecipientCount,
    recipientCount: recipientUserIds.length,
    recipientUserIds,
  });

  let recipientsInsertError: string | null = null;
  let insertedRecipientCount = 0;
  if (recipientUserIds.length) {
    const recipientRows = recipientUserIds.map((customerUserId) => ({
      notification_id: notificationId,
      customer_user_id: customerUserId,
    }));
    const { data: insertedRecipients, error: insertError } = await supabase
      .from("notification_recipients")
      .insert(recipientRows)
      .select("id");

    insertedRecipientCount = (insertedRecipients || []).length;

    if (insertError) {
      recipientsInsertError = insertError.message || String(insertError);
      console.error(
        "send-customer-notification: recipients insert failed",
        insertError,
      );
    } else if (insertedRecipientCount !== recipientUserIds.length) {
      console.warn("send-customer-notification: recipient insert count mismatch", {
        expected: recipientUserIds.length,
        inserted: insertedRecipientCount,
      });
    }
  }

  const pushData = {
    business_id: businessId,
    notification_id: notificationId,
    type: "business_notification",
  };

  let tokens: PushTokenRow[] = [];
  if (recipientUserIds.length) {
    const { data: tokenRows, error: tokensError } = await supabase
      .from("customer_push_tokens")
      .select("id, customer_user_id, device_token, platform")
      .in("customer_user_id", recipientUserIds);

    if (tokensError) {
      console.error("send-customer-notification: tokens query failed", tokensError);
    } else {
      tokens = (tokenRows || []) as PushTokenRow[];
    }
  }

  const pushResults: {
    tokenId: string;
    platform: string;
    ok: boolean;
    error?: string;
  }[] = [];
  const invalidTokenIds: string[] = [];
  const sentCustomerIds = new Set<string>();

  const hasFcm = Boolean(fcmServerKey);
  const hasApns = Boolean(apnsKeyId && apnsTeamId && apnsPrivateKey);

  for (const row of tokens) {
    const token = String(row.device_token || "").trim();
    const platform = String(row.platform || "").toLowerCase();
    if (!token) continue;

    let result: { ok: boolean; error?: string; invalidToken?: boolean };

    if (platform === "android") {
      if (!hasFcm) {
        result = { ok: false, error: "FCM not configured" };
      } else {
        result = await sendFcmNotification(
          fcmServerKey,
          token,
          title,
          message,
          pushData,
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
          title,
          message,
          pushData,
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

    if (result.ok) {
      sentCustomerIds.add(row.customer_user_id);
    }

    if (result.invalidToken) {
      invalidTokenIds.push(row.id);
    }
  }

  if (invalidTokenIds.length) {
    await supabase.from("customer_push_tokens").delete().in("id", invalidTokenIds);
  }

  const sentAt = new Date().toISOString();
  if (sentCustomerIds.size) {
    await supabase
      .from("notification_recipients")
      .update({ sent_at: sentAt })
      .eq("notification_id", notificationId)
      .in("customer_user_id", [...sentCustomerIds]);
  }

  return jsonResponse({
    ok: true,
    version: FUNCTION_VERSION,
    notificationId,
    recipientType,
    recipientCount: recipientUserIds.length,
    insertedRecipientCount,
    crmRecipientCount,
    bookingRecipientCount,
    recipientsInsertError,
    tokenCount: tokens.length,
    pushSuccessCount: pushResults.filter((r) => r.ok).length,
    pushFailureCount: pushResults.filter((r) => !r.ok).length,
    pushConfigured: { fcm: hasFcm, apns: hasApns },
    pushResults,
  });
});
