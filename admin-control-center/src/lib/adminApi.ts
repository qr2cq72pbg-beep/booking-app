import type {
  AdminSession,
  BusinessCustomer,
  BusinessDetail,
  BusinessListItem,
  OverviewMetrics,
  SubscriptionApplyResult,
  SubscriptionHistoryEntry,
  SubscriptionOperation,
  SubscriptionPreview,
  SubscriptionWorkspace,
} from "./types";
import { AdminApiError, type AdminApiErrorCode } from "./types";
import { adminFunctionUrl, supabaseAnonKey } from "./supabase";

type ActionResponse = {
  ok?: boolean;
  error?: string;
  message?: string;
  admin?: AdminSession;
  overview?: OverviewMetrics;
  businesses?: BusinessListItem[];
  business?: BusinessDetail;
  customers?: BusinessCustomer[];
  as_of_date?: string;
  packages?: SubscriptionWorkspace["packages"];
  subscriptions?: SubscriptionWorkspace["subscriptions"];
  summary?: SubscriptionWorkspace["summary"];
  history?: SubscriptionHistoryEntry[];
  preview?: SubscriptionPreview;
  result?: SubscriptionApplyResult;
};

function asCode(value: string | undefined, fallback: AdminApiErrorCode): AdminApiErrorCode {
  const allowed: AdminApiErrorCode[] = [
    "unauthorized",
    "forbidden",
    "not_configured",
    "not_found",
    "invalid_business_id",
    "invalid_package_id",
    "invalid_operation",
    "invalid_starts_on",
    "invalid_expires_on",
    "invalid_idempotency_key",
    "invalid_note",
    "already_active",
    "already_revoked",
    "no_subscription",
    "no_complimentary",
    "no_paid_subscription",
    "not_paid_subscription",
    "no_active_complimentary",
    "cannot_extend_unlimited",
    "idempotency_conflict",
    "invalid_action",
    "method_not_allowed",
    "authorization_failed",
    "internal_error",
    "network",
    "missing_session",
  ];
  if (value && (allowed as string[]).includes(value)) {
    return value as AdminApiErrorCode;
  }
  return fallback;
}

export async function callAdmin(
  accessToken: string,
  action: string,
  body: Record<string, unknown> = {},
): Promise<ActionResponse> {
  if (!accessToken) {
    throw new AdminApiError("missing_session", 401);
  }

  let response: Response;
  try {
    response = await fetch(adminFunctionUrl(), {
      method: "POST",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ action, ...body }),
    });
  } catch {
    throw new AdminApiError("network", 0, "Could not reach the Control Center API.");
  }

  let payload: ActionResponse = {};
  try {
    payload = (await response.json()) as ActionResponse;
  } catch {
    payload = {};
  }

  if (!response.ok || payload.ok === false) {
    throw new AdminApiError(
      asCode(payload.error, response.status === 403 ? "forbidden" : "internal_error"),
      response.status,
      payload.message,
    );
  }

  return payload;
}

export async function fetchSession(accessToken: string): Promise<AdminSession> {
  const payload = await callAdmin(accessToken, "session");
  if (!payload.admin?.user_id) {
    throw new AdminApiError("internal_error", 500);
  }
  return payload.admin;
}

export async function fetchOverview(accessToken: string): Promise<OverviewMetrics> {
  const payload = await callAdmin(accessToken, "overview");
  if (!payload.overview) throw new AdminApiError("internal_error", 500);
  return payload.overview;
}

export async function fetchBusinesses(
  accessToken: string,
  q = "",
): Promise<BusinessListItem[]> {
  const payload = await callAdmin(accessToken, "list_businesses", { q });
  return payload.businesses || [];
}

export async function fetchBusiness(
  accessToken: string,
  businessId: string,
): Promise<BusinessDetail> {
  const payload = await callAdmin(accessToken, "get_business", {
    business_id: businessId,
  });
  if (!payload.business) throw new AdminApiError("not_found", 404);
  return payload.business;
}

export async function fetchBusinessCustomers(
  accessToken: string,
  businessId: string,
  q = "",
): Promise<BusinessCustomer[]> {
  const payload = await callAdmin(accessToken, "list_business_customers", {
    business_id: businessId,
    q,
  });
  return payload.customers || [];
}

export async function fetchSubscriptions(
  accessToken: string,
): Promise<SubscriptionWorkspace> {
  const payload = await callAdmin(accessToken, "list_subscriptions");
  return {
    as_of_date: payload.as_of_date || "",
    packages: payload.packages || [],
    subscriptions: payload.subscriptions || [],
    summary: payload.summary || {
      total_businesses: 0,
      active: 0,
      expired: 0,
      complimentary: 0,
      paid_active: 0,
      unconfigured: 0,
      as_of_date: payload.as_of_date || "",
    },
  };
}

export async function fetchSubscriptionHistory(
  accessToken: string,
  businessId: string,
): Promise<SubscriptionHistoryEntry[]> {
  const payload = await callAdmin(accessToken, "list_subscription_history", {
    business_id: businessId,
  });
  return payload.history || [];
}

export async function previewSubscription(
  accessToken: string,
  input: {
    business_id: string;
    operation: SubscriptionOperation;
    package_id?: string | null;
    starts_on?: string | null;
    expires_on?: string | null;
  },
): Promise<SubscriptionPreview> {
  const payload = await callAdmin(accessToken, "preview_subscription", input);
  if (!payload.preview) throw new AdminApiError("internal_error", 500);
  return payload.preview;
}

export async function applySubscription(
  accessToken: string,
  input: {
    business_id: string;
    operation: SubscriptionOperation;
    package_id?: string | null;
    starts_on?: string | null;
    expires_on?: string | null;
    idempotency_key: string;
    note?: string;
  },
): Promise<SubscriptionApplyResult> {
  const payload = await callAdmin(accessToken, "apply_subscription", input);
  return payload.result || {};
}
