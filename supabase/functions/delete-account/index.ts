// In-app account deletion (App Store 5.1.1(v) / Google Play account deletion policy).
// The account id always comes from the verified JWT, never from the request body.
// Order: database (one transaction, idempotent) → owner storage files → auth user.
// If the last step fails the data is already removed; retrying is safe and finishes the job.
const FUNCTION_VERSION = "delete-account-v1";
const REAUTH_WINDOW_MS = 15 * 60 * 1000;
const CONFIRM_TOKEN = "delete-my-account";
const OWNER_BUCKETS = ["business-gallery", "business-logos"];

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify({ ...body, version: FUNCTION_VERSION }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isJwt(value: string): boolean {
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
}

async function removeOwnerStorage(supabase: SupabaseClient, ownerId: string): Promise<{ removed: number; failed: number }> {
  let removed = 0;
  let failed = 0;
  for (const bucket of OWNER_BUCKETS) {
    const paths: string[] = [];
    const queue = [ownerId];
    while (queue.length) {
      const prefix = queue.shift() as string;
      const { data, error } = await supabase.storage.from(bucket).list(prefix, { limit: 1000 });
      if (error) {
        failed += 1;
        break;
      }
      for (const item of data || []) {
        const path = `${prefix}/${item.name}`;
        // Folders come back without an id.
        if (item.id) paths.push(path);
        else queue.push(path);
      }
    }
    for (let i = 0; i < paths.length; i += 100) {
      const chunk = paths.slice(i, i + 100);
      const { error } = await supabase.storage.from(bucket).remove(chunk);
      if (error) failed += chunk.length;
      else removed += chunk.length;
    }
  }
  return { removed, failed };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ ok: false, error: "not_configured" }, 503);

  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!bearer || !isJwt(bearer)) return jsonResponse({ ok: false, error: "unauthorized" }, 401);

  let body: Record<string, unknown> = {};
  try {
    body = (await req.json()) || {};
  } catch {
    body = {};
  }
  if (body.confirm !== CONFIRM_TOKEN) return jsonResponse({ ok: false, error: "confirmation_required" }, 400);

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: userData, error: userError } = await supabase.auth.getUser(bearer);
  const user = userData?.user;
  if (userError || !user?.id) return jsonResponse({ ok: false, error: "unauthorized" }, 401);

  // Destructive action: the user must have signed in (or re-entered the password) recently.
  const lastSignIn = Date.parse(String(user.last_sign_in_at || ""));
  if (!Number.isFinite(lastSignIn) || Date.now() - lastSignIn > REAUTH_WINDOW_MS) {
    return jsonResponse({ ok: false, error: "reauth_required" }, 403);
  }

  const { data: result, error: dbError } = await supabase.rpc("_delete_account_data", { p_user_id: user.id });
  if (dbError) {
    const message = String(dbError.message || "");
    if (message.startsWith("owner_upcoming_bookings")) {
      const count = Number(message.split(":")[1]) || 0;
      return jsonResponse({ ok: false, error: "owner_upcoming_bookings", upcoming: count }, 409);
    }
    if (message === "platform_admin") return jsonResponse({ ok: false, error: "platform_admin" }, 403);
    console.error("delete-account: database step failed", { message });
    return jsonResponse({ ok: false, error: "delete_failed" }, 500);
  }

  const accountType = String((result as Record<string, unknown>)?.account_type || "");
  let storage = { removed: 0, failed: 0 };
  if (accountType === "business_owner") {
    storage = await removeOwnerStorage(supabase, user.id);
    if (storage.failed) console.warn("delete-account: storage cleanup incomplete", storage);
  }

  // Deleting the auth user also deletes its sessions and refresh tokens (all devices signed out).
  const { error: authError } = await supabase.auth.admin.deleteUser(user.id);
  if (authError) {
    console.error("delete-account: auth deletion failed", { message: authError.message });
    return jsonResponse({ ok: false, error: "auth_delete_failed", data_removed: true }, 500);
  }

  return jsonResponse({ ok: true, account_type: accountType, storage_files_removed: storage.removed, storage_cleanup_failed: storage.failed });
});
