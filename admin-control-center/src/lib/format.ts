export function formatNumber(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return "—";
  return new Intl.NumberFormat("en-GB").format(value);
}

export function formatDate(value: string | null | undefined): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  }).format(date);
}

export function formatCalendarDate(value: string | null | undefined): string {
  if (!value) return "—";
  const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(value.trim());
  if (!match) return formatDate(value);
  const date = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3])));
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    timeZone: "UTC",
  }).format(date);
}

export function formatEur(value: number | string | null | undefined): string {
  const amount = typeof value === "string" ? Number(value) : value;
  if (amount == null || Number.isNaN(amount)) return "—";
  return new Intl.NumberFormat("en-GB", {
    style: "currency",
    currency: "EUR",
  }).format(amount);
}

export function todayIsoDate(): string {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export function subscriptionStatusLabel(status: string): string {
  if (status === "active") return "Active";
  if (status === "expired") return "Expired";
  if (status === "unconfigured") return "Unconfigured";
  return status || "Unknown";
}

export function subscriptionStatusClass(status: string): string {
  if (status === "active") return "pill pill-ok";
  if (status === "expired") return "pill pill-danger";
  return "pill pill-pending";
}

export function accessKindLabel(kind: string | null | undefined, unlimited = false): string {
  if (kind === "complimentary") return unlimited ? "FREE UNTIL CHANGED" : "FREE";
  if (kind === "trial") return "XBOOK FREE TRIAL";
  if (kind === "paid") return "Paid";
  return "—";
}

export function formatExpiration(
  expiresOn: string | null | undefined,
  unlimited = false,
): string {
  if (unlimited) return "Until changed";
  if (expiresOn == null) return "—";
  return formatCalendarDate(expiresOn);
}

export function operationLabel(operation: string): string {
  switch (operation) {
    case "activate":
      return "Activate";
    case "extend":
      return "Extend";
    case "grant_complimentary":
      return "Grant FREE";
    case "extend_complimentary":
      return "Extend FREE";
    case "replace_complimentary":
      return "Replace FREE";
    case "revoke_complimentary":
      return "Revoke FREE";
    case "convert_to_paid":
      return "Convert to paid";
    case "convert_to_complimentary":
      return "Convert to FREE";
    case "grant_trial":
      return "Automatic trial";
    default:
      return operation.replace(/_/g, " ");
  }
}

export function formatDurationMonths(months: number | null | undefined): string {
  if (months == null || Number.isNaN(months)) return "—";
  return months === 1 ? "1 calendar month" : `${months} calendar months`;
}

export function formatSavingsPct(value: number | null | undefined): string | null {
  if (value == null || Number.isNaN(value) || value <= 0) return null;
  const rounded = Number.isInteger(value) ? String(value) : value.toFixed(1);
  return `${rounded}%`;
}

export function packageSummary(row: {
  label?: string | null;
  package_label?: string | null;
  access_months?: number | null;
  access_kind?: string | null;
}): string {
  const name = (row.package_label || row.label || "").trim();
  if (row.access_kind === "complimentary") return name || "FREE";
  if (row.access_kind === "trial") return name || "XBOOK FREE TRIAL";
  if (!name) return "—";
  if (!row.access_months) return name;
  return `${name} · ${formatDurationMonths(row.access_months)}`;
}

export function formatDateTime(value: string | null | undefined): string {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return new Intl.DateTimeFormat("en-GB", {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  }).format(date);
}

export function displayOrDash(value: string | null | undefined): string {
  const trimmed = (value || "").trim();
  return trimmed || "—";
}

export function approvalLabel(status: string): string {
  const value = status.trim().toLowerCase();
  if (value === "approved") return "Approved";
  if (value === "pending") return "Pending";
  if (value === "rejected") return "Rejected";
  if (value === "blocked") return "Blocked";
  return status || "Unknown";
}

export function identityLabel(kind: string, isRegistered: boolean): string {
  if (isRegistered) return "Registered user";
  if (kind === "guest_phone") return "Guest CRM · phone";
  if (kind === "guest_email") return "Guest CRM · email";
  if (kind === "guest_name") return "Guest CRM · name";
  return "Guest CRM";
}
