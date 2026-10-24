import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.108.2";

export type AdminClient = SupabaseClient;

export type AdminContext = {
  admin: AdminClient;
  userId: string;
  email: string | null;
};

const DEFAULT_LOCAL_ORIGINS = [
  "http://localhost:5173",
  "http://127.0.0.1:5173",
];

function parseAllowedOrigins(): string[] {
  const raw = String(Deno.env.get("ADMIN_CONTROL_CENTER_ALLOWED_ORIGINS") || "").trim();
  const fromEnv = raw
    ? raw.split(",").map((item) => item.trim()).filter(Boolean)
    : [];
  if (fromEnv.length > 0) {
    return fromEnv;
  }
  return [...DEFAULT_LOCAL_ORIGINS];
}

export function corsHeadersFor(req: Request): Record<string, string> {
  const allowed = parseAllowedOrigins();
  const origin = String(req.headers.get("Origin") || "").trim();
  const allowOrigin = allowed.includes(origin) ? origin : allowed[0] || "";
  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

export function jsonResponse(
  req: Request,
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeadersFor(req),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function isMissingRelationError(error: { message?: string; code?: string } | null): boolean {
  if (!error) return false;
  const code = String(error.code || "");
  const message = String(error.message || "").toLowerCase();
  return (
    code === "42P01" ||
    code === "PGRST205" ||
    message.includes("does not exist") ||
    message.includes("could not find the table")
  );
}

function isMissingColumnError(error: { message?: string; code?: string } | null): boolean {
  if (!error) return false;
  const code = String(error.code || "");
  const message = String(error.message || "").toLowerCase();
  return (
    code === "42703" ||
    (message.includes("column") && message.includes("does not exist")) ||
    (message.includes("could not find") && message.includes("column"))
  );
}

export { isMissingColumnError };

export async function requirePlatformAdmin(
  req: Request,
): Promise<{ ok: true; ctx: AdminContext } | { ok: false; response: Response }> {
  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim();
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const anonKey = String(Deno.env.get("SUPABASE_ANON_KEY") || "").trim();

  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return {
      ok: false,
      response: jsonResponse(req, { ok: false, error: "not_configured" }, 503),
    };
  }

  const authHeader = String(req.headers.get("Authorization") || "").trim();
  if (!authHeader.toLowerCase().startsWith("bearer ")) {
    return {
      ok: false,
      response: jsonResponse(req, { ok: false, error: "unauthorized" }, 401),
    };
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await userClient.auth.getUser();
  const userId = String(userData?.user?.id || "").trim();
  const email = userData?.user?.email ? String(userData.user.email) : null;

  if (userError || !userId) {
    return {
      ok: false,
      response: jsonResponse(req, { ok: false, error: "unauthorized" }, 401),
    };
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: row, error: allowError } = await admin
    .from("platform_admins")
    .select("user_id, is_active")
    .eq("user_id", userId)
    .maybeSingle();

  if (isMissingRelationError(allowError)) {
    return {
      ok: false,
      response: jsonResponse(req, {
        ok: false,
        error: "not_configured",
        message: "platform_admins table is not applied yet.",
      }, 503),
    };
  }

  if (allowError) {
    return {
      ok: false,
      response: jsonResponse(req, { ok: false, error: "authorization_failed" }, 500),
    };
  }

  const active = row && row.is_active === true && String(row.user_id || "") === userId;
  if (!active) {
    return {
      ok: false,
      response: jsonResponse(req, { ok: false, error: "forbidden" }, 403),
    };
  }

  return { ok: true, ctx: { admin, userId, email } };
}

export async function writeAdminAudit(
  admin: AdminClient,
  input: {
    actorUserId: string;
    action: string;
    businessId?: string | null;
    metadata?: Record<string, unknown>;
  },
): Promise<void> {
  try {
    await admin.from("platform_admin_audit_log").insert({
      actor_user_id: input.actorUserId,
      action: input.action,
      business_id: input.businessId || null,
      metadata: input.metadata || {},
    });
  } catch {
    // Audit must never block a successful privileged read.
  }
}

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function asTrimmed(value: unknown): string {
  return String(value ?? "").trim();
}

export function ownerDisplayName(row: {
  full_name?: unknown;
  first_name?: unknown;
  last_name?: unknown;
  email?: unknown;
}): string | null {
  const full = asTrimmed(row.full_name);
  if (full) return full;
  const first = asTrimmed(row.first_name);
  const last = asTrimmed(row.last_name);
  const joined = `${first} ${last}`.trim();
  if (joined) return joined;
  const email = asTrimmed(row.email);
  return email || null;
}

export function identityKind(clientKey: string, customerUserId: string | null): string {
  if (customerUserId) return "registered";
  const key = clientKey.trim().toLowerCase();
  if (key.startsWith("p:")) return "guest_phone";
  if (key.startsWith("e:")) return "guest_email";
  if (key.startsWith("n:")) return "guest_name";
  if (key) return "guest_crm";
  return "guest_crm";
}
