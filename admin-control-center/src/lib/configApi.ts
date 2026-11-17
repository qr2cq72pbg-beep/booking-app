// Control Center: prepared businesses, configuration and owner activation.
// Thin wrappers over the admin-control-center Edge Function (server-side checks).
import { callAdmin } from "./adminApi";
import { supabase } from "./supabase";

export type Lifecycle = "draft" | "invited" | "trial" | "active" | "expired" | "unconfigured";

export type BusinessSettings = {
  business_id: string;
  business_name: string;
  business_slug: string | null;
  business_category: string | null;
  business_description: string | null;
  public_tagline: string | null;
  business_phone: string | null;
  business_email: string | null;
  business_website: string | null;
  business_address: string | null;
  business_instagram_url: string | null;
  business_facebook_url: string | null;
  business_accent_color: string | null;
  business_logo_url: string | null;
  business_cover_url: string | null;
  timezone: string | null;
  work_start: string | null;
  work_end: string | null;
  break_start: string | null;
  break_end: string | null;
  working_days: number[];
  booking_window_weeks: number | null;
  minimum_notice_minutes: number | null;
  booking_limits_enabled: boolean;
  max_bookings_per_day: number | null;
  max_bookings_per_week: number | null;
  require_client_approval: boolean;
  accept_new_clients: boolean;
  allow_recurring_appointments: boolean;
  public_show_logo: boolean;
  public_show_prices: boolean;
  public_show_staff: boolean;
  public_show_address: boolean;
  public_show_about: boolean;
  block_public_holidays: boolean;
  holiday_country: string | null;
  onboarding_completed_at: string | null;
};

export type ServiceRow = { id: string; name: string; duration: number | null; price: number | null; icon_key: string | null };
export type DayHours = { dow: number; start: string; end: string; break_start: string | null; break_end: string | null };
export type StaffRow = {
  id: string;
  name: string;
  role: string | null;
  active: boolean;
  photo_url: string | null;
  all_services: boolean;
  service_ids: string[];
  uses_business_hours: boolean;
  weekly_hours: DayHours[];
  access_enabled: boolean;
  access_scope: "own" | "all";
  access_connected: boolean;
};
export type Onboarding = {
  status: "draft" | "invited" | "active";
  owner_email: string;
  owner_name: string | null;
  owner_phone: string | null;
  preferred_language: string;
  created_at: string;
  invited_at: string | null;
  invite_count: number;
  activated_at: string | null;
} | null;
export type OwnerAccount = {
  exists: boolean;
  email: string;
  email_confirmed_at: string | null;
  invited_at: string | null;
  last_sign_in_at: string | null;
} | null;

export type BusinessConfig = {
  settings: BusinessSettings;
  services: ServiceRow[];
  staff: StaffRow[];
  closed_days: Array<{ date: string; reason: string | null; source: string | null }>;
  onboarding: Onboarding;
  owner_account: OwnerAccount;
  lifecycle: Lifecycle;
  subscription_expires: string | null;
  booking_count: number;
  public_url: string | null;
};

export type OnboardingOverview = {
  total: number;
  draft: number;
  invited: number;
  trial: number;
  active: number;
  expired: number;
  unconfigured: number;
  pending_invitations: number;
};

export type AuditEntry = { action: string; actor: string | null; metadata: Record<string, unknown> | null; created_at: string };

export type NewBusinessInput = {
  business_name: string;
  business_category: string;
  owner_name: string;
  owner_email: string;
  owner_phone: string;
  business_address: string;
  business_slug: string;
  preferred_language: "mk" | "en" | "sq";
};

const call = (token: string, action: string, body: Record<string, unknown> = {}) => callAdmin(token, action, body);

export async function fetchOnboardingOverview(token: string): Promise<OnboardingOverview> {
  const res = await call(token, "onboarding_overview");
  return (res as unknown as { onboarding: OnboardingOverview }).onboarding;
}
export async function createDraftBusiness(token: string, input: NewBusinessInput): Promise<string> {
  const res = await call(token, "create_draft_business", input);
  return String((res as unknown as { business_id: string }).business_id);
}
export async function fetchBusinessConfig(token: string, businessId: string): Promise<BusinessConfig> {
  const res = await call(token, "get_business_config", { business_id: businessId });
  return (res as unknown as { config: BusinessConfig }).config;
}
export const updateBusinessSettings = (token: string, businessId: string, patch: Partial<BusinessSettings>) =>
  call(token, "update_business_settings", { business_id: businessId, patch });
export const saveService = (token: string, businessId: string, service: Partial<ServiceRow>) =>
  call(token, "save_service", { business_id: businessId, service });
export const deleteService = (token: string, businessId: string, serviceId: string) =>
  call(token, "delete_service", { business_id: businessId, service_id: serviceId });
export const assignServiceToAll = (token: string, businessId: string, serviceId: string) =>
  call(token, "assign_service_to_all_staff", { business_id: businessId, service_id: serviceId });
export const saveStaff = (token: string, businessId: string, staff: Partial<StaffRow>) =>
  call(token, "save_staff", { business_id: businessId, staff });
export const deleteStaff = (token: string, businessId: string, staffId: string) =>
  call(token, "delete_staff", { business_id: businessId, staff_id: staffId });
export const setStaffServices = (token: string, businessId: string, staffId: string, all: boolean, ids: string[]) =>
  call(token, "set_staff_services", { business_id: businessId, staff_id: staffId, all_services: all, service_ids: all ? null : ids });
export const setStaffHours = (token: string, businessId: string, staffId: string, usesBusiness: boolean, hours: DayHours[]) =>
  call(token, "set_staff_hours", { business_id: businessId, staff_id: staffId, uses_business_hours: usesBusiness, hours: usesBusiness ? null : hours });
export async function fetchStaffConflicts(token: string, businessId: string, staffId: string) {
  const res = await call(token, "staff_rule_conflicts", { business_id: businessId, staff_id: staffId });
  return (res as unknown as { conflicts: Array<{ booking_date: string; booking_time: string; service_name: string; reason: string }> }).conflicts;
}
export const addClosedDays = (token: string, businessId: string, dates: string[], reason: string) =>
  call(token, "add_closed_days", { business_id: businessId, dates, reason });
export const deleteClosedDay = (token: string, businessId: string, date: string) =>
  call(token, "delete_closed_day", { business_id: businessId, date });
export const setStaffAccessScope = (token: string, businessId: string, staffId: string, scope: "own" | "all") =>
  call(token, "set_staff_access_scope", { business_id: businessId, staff_id: staffId, scope });
export async function issueStaffCode(token: string, businessId: string, staffId: string) {
  const res = await call(token, "issue_staff_code", { business_id: businessId, staff_id: staffId });
  return res as unknown as { code: string; expires_at: string };
}
export const revokeStaffAccess = (token: string, businessId: string, staffId: string) =>
  call(token, "revoke_staff_access", { business_id: businessId, staff_id: staffId });
export const sendInvitation = (token: string, businessId: string) => call(token, "send_invitation", { business_id: businessId });
export const cancelInvitation = (token: string, businessId: string) => call(token, "cancel_invitation", { business_id: businessId });
export async function fetchAudit(token: string, businessId: string): Promise<AuditEntry[]> {
  const res = await call(token, "list_audit", { business_id: businessId });
  return (res as unknown as { entries: AuditEntry[] }).entries;
}

/** Signed upload into the business-logos bucket; the server chooses the path. */
export async function uploadBusinessImage(
  token: string,
  businessId: string,
  kind: "logo" | "cover" | "staff",
  file: File,
  staffId?: string,
): Promise<string> {
  const res = (await call(token, "create_upload_url", {
    business_id: businessId, kind, staff_id: staffId, content_type: file.type,
  })) as unknown as { path: string; token: string; public_url: string };
  if (!supabase) throw new Error("Supabase is not configured.");
  const { error } = await supabase.storage.from("business-logos").uploadToSignedUrl(res.path, res.token, file, {
    contentType: file.type,
  });
  if (error) throw new Error(error.message);
  return res.public_url;
}

export const LIFECYCLE_LABEL: Record<Lifecycle, string> = {
  draft: "Нацрт",
  invited: "Поканет",
  trial: "Пробен период",
  active: "Активен",
  expired: "Истечен",
  unconfigured: "Без претплата",
};
export const LIFECYCLE_CLASS: Record<Lifecycle, string> = {
  draft: "pill pill-navy",
  invited: "pill pill-pending",
  trial: "pill pill-ok",
  active: "pill pill-ok",
  expired: "pill pill-danger",
  unconfigured: "pill pill-guest",
};
export const DAY_NAMES = ["Недела", "Понеделник", "Вторник", "Среда", "Четврток", "Петок", "Сабота"];
export const DAY_ORDER = [1, 2, 3, 4, 5, 6, 0];

export function errorText(err: unknown, fallback = "Настана грешка. Обидете се повторно."): string {
  if (err && typeof err === "object" && "message" in err) {
    const msg = String((err as { message?: string }).message || "");
    if (msg && !/^[a-z_]+$/.test(msg)) return msg;
  }
  return fallback;
}
