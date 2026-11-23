// staff-access Edge Function (Phase F3): wires logic.ts to Supabase.
// verify_jwt = false (redeem is public); owner actions verify the JWT here.
// Reuses CUSTOMER_APP_LOGIN_HMAC_SECRET (separate "staff:" prefix) and the
// customer_app_login_touch_rate_limit table, so no new secret is needed.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";
import { handleStaffAccess, json, randomHexSuffix, randomNineDigitCode } from "./logic.ts";

Deno.serve(async (req) => {
  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim();
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const anonKey = String(Deno.env.get("SUPABASE_ANON_KEY") || "").trim();
  const hmacSecret = String(Deno.env.get("CUSTOMER_APP_LOGIN_HMAC_SECRET") || "").trim();
  if (req.method !== "OPTIONS" && (!supabaseUrl || !serviceRoleKey || !anonKey)) {
    return json({ ok: false, error: "not_configured" }, 503);
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  return await handleStaffAccess(req, {
    hmacSecret,
    now: () => Date.now(),
    getUserId: async (authHeader) => {
      const userClient = createClient(supabaseUrl, anonKey, {
        global: { headers: { Authorization: authHeader } },
        auth: { persistSession: false, autoRefreshToken: false },
      });
      const { data, error } = await userClient.auth.getUser();
      return error ? null : String(data?.user?.id || "").trim() || null;
    },
    isBusinessOwner: async (userId) => {
      const { data } = await admin
        .from("business_settings")
        .select("business_id")
        .eq("business_id", userId)
        .maybeSingle();
      return !!data?.business_id;
    },
    rpc: async (name, args) => {
      const { data, error } = await admin.rpc(name, args);
      return { data, error: error ? { message: error.message } : null };
    },
    createStaffUser: async ({ email, staffId, businessId }) => {
      const { data, error } = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        // app_metadata cannot be changed by the user; the app routes on it.
        app_metadata: { gt_account: "staff", staff_id: staffId, business_id: businessId },
        user_metadata: {},
      });
      return error ? null : String(data?.user?.id || "").trim() || null;
    },
    getUserEmail: async (userId) => {
      const { data, error } = await admin.auth.admin.getUserById(userId);
      return error ? null : String(data?.user?.email || "").trim() || null;
    },
    magicLinkTokenHash: async (email) => {
      const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
      const hashedToken = String(data?.properties?.hashed_token || "").trim();
      if (error || !hashedToken) return null;
      return { hashedToken, type: String(data?.properties?.verification_type || "magiclink") };
    },
    deleteUser: async (userId) => {
      await admin.auth.admin.deleteUser(userId);
    },
    randomCode: randomNineDigitCode,
    randomSuffix: randomHexSuffix,
  });
});
