// Customer push for an owner-made booking change (cancelled / rescheduled).
// Called by the database webhook on public.notifications (recipient_type = 'booking').
// No client can choose a recipient or text: the function loads the notification from
// the database, requires it to be a recent booking notice, re-checks that each
// recipient belongs to the business, and claims unsent recipients atomically
// (sent_at) so each push is delivered at most once. verify_jwt is false.
const FUNCTION_VERSION = "send-customer-booking-push-v1";
const MAX_NOTIFICATION_AGE_MS = 15 * 60 * 1000;

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";
import {
  parseFirebaseServiceAccount,
  sendApnsNotification,
  sendFcmNotification,
} from "../_shared/push-delivery.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function resolveNotificationId(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const body = raw as Record<string, unknown>;
  const record = body.record && typeof body.record === "object"
    ? body.record as Record<string, unknown>
    : null;
  const id = String(record?.id ?? body.notification_id ?? body.notificationId ?? "").trim();
  return UUID_RE.test(id) ? id : "";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ ok: false, error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ ok: false, error: "not_configured" }, 503);
  }

  let raw: unknown = null;
  try {
    raw = await req.json();
  } catch {
    raw = null;
  }
  const notificationId = resolveNotificationId(raw);
  if (!notificationId) return jsonResponse({ ok: false, error: "invalid_request" }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: notification, error: notificationError } = await supabase
    .from("notifications")
    .select("id, business_id, title, message, recipient_type, created_at")
    .eq("id", notificationId)
    .maybeSingle();

  if (notificationError || !notification || notification.recipient_type !== "booking") {
    return jsonResponse({ ok: false, error: "not_found" }, 404);
  }
  const ageMs = Date.now() - new Date(String(notification.created_at)).getTime();
  if (!(ageMs >= 0 && ageMs <= MAX_NOTIFICATION_AGE_MS)) {
    return jsonResponse({ ok: true, skipped: "expired", version: FUNCTION_VERSION });
  }

  // Claim: only recipients not yet sent. A repeated call finds nothing to send.
  const claimedAt = new Date().toISOString();
  const { data: claimed, error: claimError } = await supabase
    .from("notification_recipients")
    .update({ sent_at: claimedAt })
    .eq("notification_id", notificationId)
    .is("sent_at", null)
    .select("customer_user_id");

  if (claimError) return jsonResponse({ ok: false, error: "claim_failed" }, 500);
  const claimedIds = [...new Set((claimed || []).map((r) => String(r.customer_user_id || "")).filter(Boolean))];
  if (!claimedIds.length) {
    return jsonResponse({ ok: true, skipped: "already_sent", version: FUNCTION_VERSION });
  }

  // Re-check membership server-side: only customers who belong to this business.
  const { data: members } = await supabase
    .from("business_customers")
    .select("customer_user_id")
    .eq("business_id", notification.business_id)
    .in("customer_user_id", claimedIds);
  const memberIds = [...new Set((members || []).map((r) => String(r.customer_user_id || "")).filter(Boolean))];
  if (!memberIds.length) {
    return jsonResponse({ ok: true, skipped: "no_member_recipient", version: FUNCTION_VERSION });
  }

  const { data: tokenRows } = await supabase
    .from("customer_push_tokens")
    .select("id, customer_user_id, device_token, platform")
    .in("customer_user_id", memberIds);
  const tokens = tokenRows || [];

  const firebaseAccount = parseFirebaseServiceAccount(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "");
  const apnsKeyId = Deno.env.get("APNS_KEY_ID") || "";
  const apnsTeamId = Deno.env.get("APNS_TEAM_ID") || "";
  const apnsPrivateKey = (Deno.env.get("APNS_PRIVATE_KEY") || "").replace(/\\n/g, "\n");
  const apnsBundleId = Deno.env.get("APNS_BUNDLE_ID") || "com.gtwebstudio.booking";
  const apnsProduction = Deno.env.get("APNS_PRODUCTION") === "true";
  const hasApns = Boolean(apnsKeyId && apnsTeamId && apnsPrivateKey);

  const title = String(notification.title || "").trim();
  const body = String(notification.message || "").trim();
  const data = {
    type: "booking_changed",
    business_id: String(notification.business_id),
    notification_id: notificationId,
  };

  let sent = 0;
  let failed = 0;
  const invalidTokenIds: string[] = [];
  for (const row of tokens) {
    const token = String(row.device_token || "").trim();
    const platform = String(row.platform || "").toLowerCase();
    if (!token) continue;
    let result: { ok: boolean; error?: string; invalidToken?: boolean };
    if (platform === "android") {
      result = firebaseAccount.creds
        ? await sendFcmNotification(firebaseAccount.creds, token, title, body, data)
        : { ok: false, error: firebaseAccount.error || "FCM not configured" };
    } else if (platform === "ios") {
      result = hasApns
        ? await sendApnsNotification(
          { keyId: apnsKeyId, teamId: apnsTeamId, privateKey: apnsPrivateKey, bundleId: apnsBundleId, production: apnsProduction },
          token,
          title,
          body,
          data,
        )
        : { ok: false, error: "APNs not configured" };
    } else {
      result = { ok: false, error: "unknown_platform" };
    }
    if (result.ok) sent += 1;
    else failed += 1;
    if (result.invalidToken) invalidTokenIds.push(String(row.id));
    if (!result.ok) console.warn("send-customer-booking-push: delivery failed", { platform, error: result.error });
  }

  if (invalidTokenIds.length) {
    await supabase.from("customer_push_tokens").delete().in("id", invalidTokenIds);
  }

  return jsonResponse({
    ok: true,
    version: FUNCTION_VERSION,
    notificationId,
    recipients: memberIds.length,
    tokenCount: tokens.length,
    pushSuccessCount: sent,
    pushFailureCount: failed,
  });
});
