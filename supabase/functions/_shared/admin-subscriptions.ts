import type { AdminClient } from "./admin-guard.ts";
import { asTrimmed, isMissingColumnError, isMissingRelationError } from "./admin-guard.ts";

type JsonMap = Record<string, unknown>;

export const PAID_OPERATIONS = ["activate", "extend", "convert_to_paid"] as const;
export const COMPLIMENTARY_OPERATIONS = [
  "grant_complimentary",
  "extend_complimentary",
  "replace_complimentary",
  "revoke_complimentary",
  "convert_to_complimentary",
] as const;
export const SUBSCRIPTION_OPERATIONS = [
  ...PAID_OPERATIONS,
  ...COMPLIMENTARY_OPERATIONS,
] as const;
export type SubscriptionOperation = (typeof SUBSCRIPTION_OPERATIONS)[number];
export type AccessKind = "paid" | "complimentary" | "trial";

export function isComplimentaryOperation(operation: string): boolean {
  return (COMPLIMENTARY_OPERATIONS as readonly string[]).includes(operation);
}

export function isPaidOperation(operation: string): boolean {
  return (PAID_OPERATIONS as readonly string[]).includes(operation);
}

export function complimentaryLabel(expiresOn: string | null): string {
  return expiresOn ? "FREE" : "FREE UNTIL CHANGED";
}

const DATE_ONLY_RE = /^\d{4}-\d{2}-\d{2}$/;

export function isMissingFunctionError(
  error: { message?: string; code?: string } | null,
): boolean {
  if (!error) return false;
  const code = String(error.code || "");
  const message = String(error.message || "").toLowerCase();
  return (
    code === "42883" ||
    code === "PGRST202" ||
    (message.includes("function") && message.includes("does not exist")) ||
    (message.includes("could not find") && message.includes("function"))
  );
}

export function parseDateOnly(value: unknown): string | null {
  const raw = asTrimmed(value);
  if (!DATE_ONLY_RE.test(raw)) return null;
  const [year, month, day] = raw.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  if (
    date.getUTCFullYear() !== year ||
    date.getUTCMonth() !== month - 1 ||
    date.getUTCDate() !== day
  ) {
    return null;
  }
  return raw;
}

export function utcToday(): string {
  return new Date().toISOString().slice(0, 10);
}

function asDateString(value: unknown): string | null {
  if (value == null) return null;
  const raw = asTrimmed(value);
  if (!raw) return null;
  if (DATE_ONLY_RE.test(raw)) return raw;
  const prefix = raw.slice(0, 10);
  return DATE_ONLY_RE.test(prefix) ? prefix : null;
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
}

function asIso(value: unknown): string | null {
  const raw = asTrimmed(value);
  return raw || null;
}

export function deriveSubscriptionStatus(
  expiresOn: string | null | undefined,
  asOfDate: string,
  hasRow = false,
  opts?: {
    access_kind?: string | null;
    expires_at?: string | null;
    as_of_ts?: string | null;
  },
): "unconfigured" | "active" | "expired" {
  if (!hasRow) return "unconfigured";
  if (opts?.access_kind === "trial" && opts.expires_at) {
    const exp = Date.parse(opts.expires_at);
    const asOf = Date.parse(opts.as_of_ts || new Date().toISOString());
    if (Number.isFinite(exp) && Number.isFinite(asOf)) {
      return exp > asOf ? "active" : "expired";
    }
  }
  if (expiresOn == null || expiresOn === "") return "active";
  return expiresOn >= asOfDate ? "active" : "expired";
}

export type SubscriptionPackageRow = {
  package_id: string;
  label: string;
  paid_months: number;
  bonus_months: number;
  access_months: number;
  price_eur: number;
  sort_order: number;
  is_active: boolean;
  description: string | null;
  is_best_value: boolean;
  effective_monthly_eur: number | null;
  savings_vs_flex_pct: number | null;
};

function roundMoney(value: number): number {
  return Math.round((value + Number.EPSILON) * 100) / 100;
}

function savingsVsFlex(flexPrice: number, packagePrice: number, months: number): number | null {
  const flexTotal = flexPrice * months;
  if (!(flexTotal > 0) || months <= 1) return null;
  return Math.round(((flexTotal - packagePrice) / flexTotal) * 1000) / 10;
}

export function decoratePackages(packages: SubscriptionPackageRow[]): SubscriptionPackageRow[] {
  const flex = packages.find((pkg) => pkg.package_id === "flex_monthly" && pkg.is_active)
    || packages.find((pkg) => pkg.is_active && pkg.access_months === 1);
  return packages.map((pkg) => {
    const effective = pkg.effective_monthly_eur != null
      ? pkg.effective_monthly_eur
      : (pkg.access_months > 0 ? roundMoney(pkg.price_eur / pkg.access_months) : pkg.price_eur);
    const savings = pkg.savings_vs_flex_pct != null
      ? pkg.savings_vs_flex_pct
      : (flex && pkg.package_id !== flex.package_id
        ? savingsVsFlex(flex.price_eur, pkg.price_eur, pkg.access_months)
        : null);
    return {
      ...pkg,
      effective_monthly_eur: effective,
      savings_vs_flex_pct: savings,
    };
  });
}

export function mapPackage(row: JsonMap): SubscriptionPackageRow | null {
  const packageId = asTrimmed(row.package_id);
  const paid = asNumber(row.paid_months);
  const bonus = asNumber(row.bonus_months);
  const access = asNumber(row.access_months);
  const price = asNumber(row.price_eur);
  const sort = asNumber(row.sort_order);
  if (!packageId || paid == null || bonus == null || access == null || price == null) {
    return null;
  }
  const isActive = row.is_active === false ? false : true;
  return {
    package_id: packageId,
    label: asTrimmed(row.label) || packageId,
    paid_months: paid,
    bonus_months: bonus,
    access_months: access,
    price_eur: price,
    sort_order: sort ?? 0,
    is_active: isActive,
    description: asTrimmed(row.description) || null,
    is_best_value: row.is_best_value === true,
    effective_monthly_eur: asNumber(row.effective_monthly_eur),
    savings_vs_flex_pct: asNumber(row.savings_vs_flex_pct),
  };
}

const PACKAGE_SELECT_FULL =
  "package_id, label, paid_months, bonus_months, access_months, price_eur, sort_order, is_active, description, is_best_value, effective_monthly_eur, savings_vs_flex_pct";

const PACKAGE_SELECT_CORE =
  "package_id, label, paid_months, bonus_months, access_months, price_eur, sort_order, is_active";

export async function loadPackageCatalog(
  admin: AdminClient,
): Promise<{ all: SubscriptionPackageRow[]; active: SubscriptionPackageRow[] } | "missing"> {
  let query = await admin
    .from("subscription_packages")
    .select(PACKAGE_SELECT_FULL)
    .order("sort_order", { ascending: true });
  if (query.error && isMissingColumnError(query.error)) {
    query = await admin
      .from("subscription_packages")
      .select(PACKAGE_SELECT_CORE)
      .order("sort_order", { ascending: true });
  }
  if (query.error) {
    if (isMissingRelationError(query.error)) return "missing";
    throw new Error("query_failed");
  }
  const rows = Array.isArray(query.data) ? query.data as JsonMap[] : [];
  const all = decoratePackages(
    rows.map(mapPackage).filter((row): row is SubscriptionPackageRow => Boolean(row)),
  );
  const active = all.filter((pkg) => pkg.is_active);
  return { all, active };
}

export async function loadPackages(
  admin: AdminClient,
): Promise<SubscriptionPackageRow[] | "missing"> {
  const catalog = await loadPackageCatalog(admin);
  if (catalog === "missing") return "missing";
  return catalog.active;
}

type CurrentSubRow = {
  business_id: string;
  access_kind: AccessKind;
  package_id: string | null;
  starts_on: string;
  expires_on: string | null;
  starts_at: string | null;
  expires_at: string | null;
  activated_at: string | null;
  updated_at: string | null;
  updated_by: string | null;
  last_history_id: string | null;
};

function asAccessKind(value: unknown): AccessKind {
  const raw = asTrimmed(value);
  if (raw === "complimentary" || raw === "trial") return raw;
  return "paid";
}

export async function loadCurrentSubscriptions(
  admin: AdminClient,
): Promise<Map<string, CurrentSubRow> | "missing"> {
  let query = await admin
    .from("business_subscriptions")
    .select(
      "business_id, access_kind, package_id, starts_on, expires_on, starts_at, expires_at, activated_at, updated_at, updated_by, last_history_id",
    );
  if (query.error && isMissingColumnError(query.error)) {
    query = await admin
      .from("business_subscriptions")
      .select(
        "business_id, access_kind, package_id, starts_on, expires_on, activated_at, updated_at, updated_by, last_history_id",
      );
  }
  if (query.error && isMissingColumnError(query.error)) {
    query = await admin
      .from("business_subscriptions")
      .select(
        "business_id, package_id, starts_on, expires_on, activated_at, updated_at, updated_by, last_history_id",
      );
  }
  if (query.error) {
    if (isMissingRelationError(query.error)) return "missing";
    throw new Error("query_failed");
  }
  const map = new Map<string, CurrentSubRow>();
  for (const row of Array.isArray(query.data) ? query.data as JsonMap[] : []) {
    const businessId = asTrimmed(row.business_id);
    const startsOn = asDateString(row.starts_on);
    if (!businessId || !startsOn) continue;
    map.set(businessId, {
      business_id: businessId,
      access_kind: asAccessKind(row.access_kind),
      package_id: asTrimmed(row.package_id) || null,
      starts_on: startsOn,
      expires_on: asDateString(row.expires_on),
      starts_at: asIso(row.starts_at),
      expires_at: asIso(row.expires_at),
      activated_at: asIso(row.activated_at),
      updated_at: asIso(row.updated_at),
      updated_by: asTrimmed(row.updated_by) || null,
      last_history_id: asTrimmed(row.last_history_id) || null,
    });
  }
  return map;
}

export function mapSubscriptionRecord(
  business: {
    business_id: string;
    business_name: string;
    business_slug: string | null;
  },
  current: CurrentSubRow | undefined,
  pkg: SubscriptionPackageRow | undefined,
  asOfDate: string,
) {
  const status = deriveSubscriptionStatus(current?.expires_on, asOfDate, Boolean(current), {
    access_kind: current?.access_kind,
    expires_at: current?.expires_at,
  });
  const complimentary = current?.access_kind === "complimentary";
  const trial = current?.access_kind === "trial";
  return {
    business_id: business.business_id,
    business_name: business.business_name,
    business_slug: business.business_slug,
    status,
    access_kind: current?.access_kind ?? null,
    package_id: current?.package_id ?? null,
    package_label: complimentary
      ? complimentaryLabel(current?.expires_on ?? null)
      : trial
        ? "XBOOK FREE TRIAL"
        : (pkg?.label ?? null),
    paid_months: complimentary || trial ? 0 : (pkg?.paid_months ?? null),
    bonus_months: complimentary || trial ? 0 : (pkg?.bonus_months ?? null),
    access_months: complimentary || trial ? 0 : (pkg?.access_months ?? null),
    price_eur: complimentary || trial ? 0 : (pkg?.price_eur ?? null),
    is_revenue: Boolean(current) && !complimentary && !trial,
    unlimited: Boolean(current) && current?.expires_on == null && !trial,
    starts_on: current?.starts_on ?? null,
    expires_on: current?.expires_on ?? null,
    starts_at: current?.starts_at ?? null,
    expires_at: current?.expires_at ?? null,
    activated_at: current?.activated_at ?? null,
    updated_at: current?.updated_at ?? null,
    updated_by: current?.updated_by ?? null,
    last_history_id: current?.last_history_id ?? null,
    starts_in_future: Boolean(current?.starts_on && current.starts_on > asOfDate),
  };
}

export function summarizeSubscriptions(
  totalBusinesses: number,
  currents: Map<string, CurrentSubRow>,
  asOfDate: string,
) {
  let active = 0;
  let expired = 0;
  let complimentary = 0;
  let paidActive = 0;
  let trialActive = 0;
  for (const row of currents.values()) {
    const status = deriveSubscriptionStatus(row.expires_on, asOfDate, true, {
      access_kind: row.access_kind,
      expires_at: row.expires_at,
    });
    if (status === "active") {
      active += 1;
      if (row.access_kind === "complimentary") complimentary += 1;
      if (row.access_kind === "paid") paidActive += 1;
      if (row.access_kind === "trial") trialActive += 1;
    } else {
      expired += 1;
    }
  }
  return {
    total_businesses: totalBusinesses,
    active,
    expired,
    complimentary,
    paid_active: paidActive,
    trial_active: trialActive,
    unconfigured: Math.max(0, totalBusinesses - currents.size),
    as_of_date: asOfDate,
  };
}

export async function loadSubscriptionHistory(
  admin: AdminClient,
  businessId: string,
): Promise<JsonMap[] | "missing"> {
  const full =
    "id, business_id, operation, package_id, access_kind, previous_access_kind, paid_months, bonus_months, access_months, price_eur, requested_starts_on, requested_expires_on, previous_package_id, previous_starts_on, previous_expires_on, previous_starts_at, previous_expires_at, new_starts_on, new_expires_on, new_starts_at, new_expires_at, actor_user_id, note, created_at, idempotency_key";
  const core =
    "id, business_id, operation, package_id, paid_months, bonus_months, access_months, price_eur, requested_starts_on, previous_package_id, previous_starts_on, previous_expires_on, new_starts_on, new_expires_on, actor_user_id, note, created_at, idempotency_key";
  let query = await admin
    .from("business_subscription_history")
    .select(full)
    .eq("business_id", businessId)
    .order("created_at", { ascending: false })
    .limit(200);
  if (query.error && isMissingColumnError(query.error)) {
    query = await admin
      .from("business_subscription_history")
      .select(core)
      .eq("business_id", businessId)
      .order("created_at", { ascending: false })
      .limit(200);
  }
  if (query.error) {
    if (isMissingRelationError(query.error)) return "missing";
    throw new Error("query_failed");
  }
  return Array.isArray(query.data) ? query.data as JsonMap[] : [];
}

export async function emailsForUsers(
  admin: AdminClient,
  userIds: string[],
): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  const ids = [...new Set(userIds.filter(Boolean))];
  if (!ids.length) return map;
  const { data, error } = await admin
    .from("platform_admins")
    .select("user_id, email")
    .in("user_id", ids);
  if (error) return map;
  for (const row of Array.isArray(data) ? data as JsonMap[] : []) {
    const id = asTrimmed(row.user_id);
    const email = asTrimmed(row.email);
    if (id && email) map.set(id, email);
  }
  return map;
}

export function mapHistoryRow(
  row: JsonMap,
  packageLabel: string | null,
  actorEmail: string | null,
) {
  const accessKind = asAccessKind(row.access_kind || (asTrimmed(row.package_id) ? "paid" : "complimentary"));
  const newExpires = asDateString(row.new_expires_on);
  const complimentary = accessKind === "complimentary";
  const trial = accessKind === "trial";
  return {
    id: asTrimmed(row.id),
    business_id: asTrimmed(row.business_id),
    operation: asTrimmed(row.operation),
    access_kind: accessKind,
    previous_access_kind: asTrimmed(row.previous_access_kind) || null,
    package_id: asTrimmed(row.package_id) || null,
    package_label: complimentary
      ? complimentaryLabel(newExpires)
      : trial
        ? "XBOOK FREE TRIAL"
        : packageLabel,
    paid_months: asNumber(row.paid_months),
    bonus_months: asNumber(row.bonus_months),
    access_months: asNumber(row.access_months),
    price_eur: complimentary || trial ? 0 : asNumber(row.price_eur),
    is_revenue: !complimentary && !trial && accessKind === "paid",
    new_starts_at: asIso(row.new_starts_at),
    new_expires_at: asIso(row.new_expires_at),
    requested_starts_on: asDateString(row.requested_starts_on),
    requested_expires_on: asDateString(row.requested_expires_on),
    previous_package_id: asTrimmed(row.previous_package_id) || null,
    previous_starts_on: asDateString(row.previous_starts_on),
    previous_expires_on: asDateString(row.previous_expires_on),
    new_starts_on: asDateString(row.new_starts_on),
    new_expires_on: newExpires,
    actor_user_id: asTrimmed(row.actor_user_id) || null,
    actor_email: actorEmail,
    note: asTrimmed(row.note) || null,
    created_at: asIso(row.created_at),
  };
}

export function rpcErrorStatus(code: string): number {
  switch (code) {
    case "invalid_business_id":
    case "invalid_package_id":
    case "invalid_operation":
    case "invalid_starts_on":
    case "invalid_idempotency_key":
    case "invalid_actor":
    case "invalid_note":
    case "invalid_expires_on":
      return 400;
    case "not_found":
      return 404;
    case "already_active":
    case "already_revoked":
    case "idempotency_conflict":
      return 409;
    case "no_subscription":
    case "no_complimentary":
    case "no_paid_subscription":
    case "not_paid_subscription":
    case "no_active_complimentary":
    case "cannot_extend_unlimited":
      return 422;
    case "not_configured":
      return 503;
    default:
      return 400;
  }
}

export function rpcErrorMessage(code: string): string {
  switch (code) {
    case "invalid_business_id":
      return "Business id is not a valid UUID.";
    case "invalid_package_id":
      return "That package is not available.";
    case "invalid_operation":
      return "That access operation is not allowed.";
    case "invalid_starts_on":
      return "Start date must be a real calendar date within the allowed range.";
    case "invalid_expires_on":
      return "Choose a valid FREE end date later than the current expiration, or FREE UNTIL CHANGED.";
    case "invalid_idempotency_key":
      return "A unique request key is required.";
    case "already_active":
      return "This business already has active access. Use Extend, Replace, or Convert.";
    case "already_revoked":
      return "Complimentary access is already expired or revoked.";
    case "no_subscription":
      return "This business has no paid subscription yet. Activate one first.";
    case "no_complimentary":
      return "This business has no complimentary access to change.";
    case "no_paid_subscription":
      return "This business has no paid subscription to convert.";
    case "not_paid_subscription":
      return "Paid extend only works on FLEX, PLUS, or MAX. Use Replace or Convert for FREE access.";
    case "no_active_complimentary":
      return "Complimentary access is not currently active.";
    case "cannot_extend_unlimited":
      return "FREE UNTIL CHANGED has no end date to extend. Replace it to set a date.";
    case "idempotency_conflict":
      return "That request key was already used with different details.";
    case "not_found":
      return "Business not found.";
    case "not_configured":
      return "Subscription tables are not applied yet.";
    default:
      return code;
  }
}

export function asRpcObject(data: unknown): JsonMap | null {
  if (data && typeof data === "object" && !Array.isArray(data)) {
    return data as JsonMap;
  }
  return null;
}
