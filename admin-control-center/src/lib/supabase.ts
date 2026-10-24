import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const PRODUCT_SUPABASE_URL = "https://sdqothuulzeczcncyfqd.supabase.co";
const PRODUCT_SUPABASE_ANON_KEY = "sb_publishable_Gn743-ISr01JNKmrOOc8Mw_S3TbNbaU";

const url = (import.meta.env.VITE_SUPABASE_URL || PRODUCT_SUPABASE_URL).trim();
export const supabaseAnonKey = (
  import.meta.env.VITE_SUPABASE_ANON_KEY || PRODUCT_SUPABASE_ANON_KEY
).trim();

export function isSupabaseConfigured(): boolean {
  return Boolean(url && supabaseAnonKey);
}

function createBrowserClient(): SupabaseClient | null {
  if (!isSupabaseConfigured()) return null;
  try {
    return createClient(url, supabaseAnonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        storageKey: "xbook-admin-control-center-auth",
      },
    });
  } catch (error) {
    console.error("Failed to initialize Supabase client.", error);
    return null;
  }
}

export const supabase = createBrowserClient();

export function adminFunctionUrl(): string {
  const override = (import.meta.env.VITE_ADMIN_FUNCTION_URL || "").trim();
  if (override) return override.replace(/\/$/, "");
  return `${url.replace(/\/$/, "")}/functions/v1/admin-control-center`;
}

export function supabaseConfigError(): string | null {
  if (supabase && isSupabaseConfigured()) return null;
  return "Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to .env.local (publishable key only), then restart the Vite server.";
}
