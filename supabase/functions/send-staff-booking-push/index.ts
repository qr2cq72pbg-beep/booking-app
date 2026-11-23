// Employee push for booking changes (Phase F4). Called by the database webhook
// on public.staff_push_events (AFTER INSERT). verify_jwt is false, like
// send-customer-booking-push: no client can choose a recipient or text; the
// event is loaded and claimed from the database (see logic.ts).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";
import {
  parseFirebaseServiceAccount,
  sendApnsNotification,
  sendFcmNotification,
} from "../_shared/push-delivery.ts";
import { eventIdFromBody, processStaffPushEvent, type StaffPushEvent } from "./logic.ts";

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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ ok: false, error: "not_configured" }, 503);

  let raw: unknown = null;
  try {
    raw = await req.json();
  } catch {
    raw = null;
  }
  const eventId = eventIdFromBody(raw);
  if (!eventId) return jsonResponse({ ok: false, error: "invalid_request" }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const firebase = parseFirebaseServiceAccount(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "");
  const apns = {
    keyId: Deno.env.get("APNS_KEY_ID") || "",
    teamId: Deno.env.get("APNS_TEAM_ID") || "",
    privateKey: (Deno.env.get("APNS_PRIVATE_KEY") || "").replace(/\\n/g, "\n"),
    bundleId: Deno.env.get("APNS_BUNDLE_ID") || "com.gtwebstudio.booking",
    production: Deno.env.get("APNS_PRODUCTION") === "true",
  };

  const result = await processStaffPushEvent(eventId, {
    now: () => Date.now(),
    loadEvent: async (id) => {
      const { data } = await supabase
        .from("staff_push_events")
        .select("id, business_id, booking_id, staff_id, event_type, payload, created_at")
        .eq("id", id)
        .maybeSingle();
      return (data as StaffPushEvent) || null;
    },
    claimEvent: async (id) => {
      const { data } = await supabase
        .from("staff_push_events")
        .update({ sent_at: new Date().toISOString() })
        .eq("id", id)
        .is("sent_at", null)
        .select("id");
      return Array.isArray(data) && data.length > 0;
    },
    activeRecipient: async (event) => {
      const { data } = await supabase
        .from("staff_members")
        .select("id, access_user_id, access_enabled, active")
        .eq("id", event.staff_id)
        .eq("business_id", event.business_id)
        .maybeSingle();
      if (!data || data.access_enabled !== true || data.active === false || !data.access_user_id) return null;
      return { staff_id: String(data.id), user_id: String(data.access_user_id) };
    },
    tokensFor: async (target) => {
      const { data } = await supabase
        .from("staff_push_tokens")
        .select("id, device_token, platform, locale")
        .eq("staff_id", target.staff_id)
        .eq("user_id", target.user_id);
      return Array.isArray(data) ? data : [];
    },
    send: async (token, title, body, data) => {
      if (token.platform === "android") {
        if (!firebase.creds) return { ok: false, error: firebase.error || "fcm_not_configured" };
        return await sendFcmNotification(firebase.creds, token.device_token, title, body, data);
      }
      if (!apns.keyId || !apns.teamId || !apns.privateKey) return { ok: false, error: "apns_not_configured" };
      const first = await sendApnsNotification(apns, token.device_token, title, body, data);
      // A token from an Xcode/development install only works on the sandbox APNs host (and a
      // store install only on production). On BadDeviceToken try the other host once.
      if (first.ok || !/BadDeviceToken/i.test(first.error || "")) return first;
      const other = await sendApnsNotification({ ...apns, production: !apns.production }, token.device_token, title, body, data);
      return other.ok ? other : first;
    },
    deleteToken: async (tokenId) => {
      await supabase.from("staff_push_tokens").delete().eq("id", tokenId);
    },
    saveResult: async (id, value) => {
      await supabase.from("staff_push_events").update({ result: value.slice(0, 200) }).eq("id", id);
    },
  });

  return jsonResponse(result, result.ok === false ? 404 : 200);
});
