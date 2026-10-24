export type AdminSession = {
  user_id: string;
  email: string | null;
};

export type OverviewMetrics = {
  total_businesses: number;
  total_business_owners: number;
  unique_registered_customers: number;
  unique_customers_linked_to_businesses: number;
  customer_memberships: number;
  crm_customer_records: number;
  guest_crm_records: number;
  total_bookings: number | null;
  bookings_available: boolean;
  subscriptions_available?: boolean;
  active_subscriptions?: number;
  expired_subscriptions?: number;
  complimentary_subscriptions?: number;
  paid_active_subscriptions?: number;
  unconfigured_subscriptions?: number;
  definitions: Record<string, string>;
};

export type OwnerSummary = {
  user_id: string;
  display_name: string | null;
  email: string | null;
  phone: string | null;
  registered_at: string | null;
  profile_present: boolean;
};

export type CustomerCounts = {
  crm_records: number;
  linked_members: number;
  guest_records: number;
};

export type BusinessListItem = {
  business_id: string;
  business_slug: string | null;
  business_name: string;
  business_description: string | null;
  public_tagline: string | null;
  business_category: string | null;
  business_logo_url: string | null;
  business_cover_url: string | null;
  business_address: string | null;
  business_phone: string | null;
  business_email: string | null;
  business_website: string | null;
  onboarding_completed_at: string | null;
  onboarding_step: number | null;
  owner: OwnerSummary;
  customer_counts: CustomerCounts;
};

export type BusinessDetail = BusinessListItem & {
  booking_count: number | null;
  bookings_available: boolean;
  subscription?: BusinessSubscription | null;
  subscriptions_available?: boolean;
};

export type SubscriptionPackage = {
  package_id: string;
  label: string;
  paid_months: number;
  bonus_months: number;
  access_months: number;
  price_eur: number;
  sort_order: number;
  is_active?: boolean;
  description?: string | null;
  is_best_value?: boolean;
  effective_monthly_eur?: number | null;
  savings_vs_flex_pct?: number | null;
};

export type SubscriptionStatus = "unconfigured" | "active" | "expired";

export type AccessKind = "paid" | "complimentary" | "trial";

export type SubscriptionOperation =
  | "activate"
  | "extend"
  | "convert_to_paid"
  | "grant_complimentary"
  | "extend_complimentary"
  | "replace_complimentary"
  | "revoke_complimentary"
  | "convert_to_complimentary";

export type BusinessSubscription = {
  business_id: string;
  business_name: string;
  business_slug: string | null;
  status: SubscriptionStatus;
  access_kind?: AccessKind | null;
  package_id: string | null;
  package_label: string | null;
  paid_months: number | null;
  bonus_months: number | null;
  access_months: number | null;
  price_eur: number | null;
  is_revenue?: boolean;
  unlimited?: boolean;
  starts_on: string | null;
  expires_on: string | null;
  starts_at?: string | null;
  expires_at?: string | null;
  activated_at: string | null;
  updated_at: string | null;
  updated_by: string | null;
  last_history_id: string | null;
  starts_in_future: boolean;
};

export type SubscriptionSummary = {
  total_businesses: number;
  active: number;
  expired: number;
  complimentary?: number;
  paid_active?: number;
  trial_active?: number;
  unconfigured: number;
  as_of_date: string;
};

export type SubscriptionWorkspace = {
  as_of_date: string;
  packages: SubscriptionPackage[];
  subscriptions: BusinessSubscription[];
  summary: SubscriptionSummary;
};

export type SubscriptionHistoryEntry = {
  id: string;
  business_id: string;
  operation: string;
  access_kind?: AccessKind | null;
  previous_access_kind?: string | null;
  package_id: string | null;
  package_label: string | null;
  paid_months: number | null;
  bonus_months: number | null;
  access_months: number | null;
  price_eur: number | null;
  is_revenue?: boolean;
  requested_starts_on: string | null;
  requested_expires_on?: string | null;
  previous_package_id: string | null;
  previous_starts_on: string | null;
  previous_expires_on: string | null;
  new_starts_on: string | null;
  new_expires_on: string | null;
  new_starts_at?: string | null;
  new_expires_at?: string | null;
  actor_user_id: string | null;
  actor_email: string | null;
  note: string | null;
  created_at: string | null;
};

export type SubscriptionPreview = {
  as_of_date: string;
  operation: SubscriptionOperation;
  access_kind?: AccessKind;
  previous_access_kind?: AccessKind | null;
  is_revenue?: boolean;
  unlimited?: boolean;
  package: SubscriptionPackage & { package_id: string | null };
  current_status: SubscriptionStatus;
  previous_starts_on: string | null;
  previous_expires_on: string | null;
  new_starts_on: string;
  new_expires_on: string | null;
  resulting_status: SubscriptionStatus;
  preserves_remaining_access: boolean;
};

export type SubscriptionApplyResult = {
  replayed?: boolean;
  as_of_date?: string;
  history_id?: string;
  subscription?: {
    business_id: string;
    access_kind?: AccessKind;
    package_id: string | null;
    starts_on: string;
    expires_on: string | null;
  };
};

export type BusinessCustomer = {
  id: string;
  customer_number: number | null;
  display_name: string | null;
  phone: string | null;
  email: string | null;
  approval_status: string;
  first_seen_at: string | null;
  identity_kind: string;
  is_registered_user: boolean;
  is_guest_crm: boolean;
  customer_user_id: string | null;
};

export type AdminApiErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not_configured"
  | "not_found"
  | "invalid_business_id"
  | "invalid_package_id"
  | "invalid_operation"
  | "invalid_starts_on"
  | "invalid_expires_on"
  | "invalid_idempotency_key"
  | "invalid_note"
  | "already_active"
  | "already_revoked"
  | "no_subscription"
  | "no_complimentary"
  | "no_paid_subscription"
  | "not_paid_subscription"
  | "no_active_complimentary"
  | "cannot_extend_unlimited"
  | "idempotency_conflict"
  | "invalid_action"
  | "method_not_allowed"
  | "authorization_failed"
  | "internal_error"
  | "network"
  | "missing_session";

export class AdminApiError extends Error {
  status: number;
  code: AdminApiErrorCode;

  constructor(code: AdminApiErrorCode, status: number, message?: string) {
    super(message || code);
    this.name = "AdminApiError";
    this.code = code;
    this.status = status;
  }
}
