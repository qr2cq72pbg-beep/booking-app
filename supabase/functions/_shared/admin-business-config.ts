// GT Termin Control Center — prepared businesses, configuration and owner activation.
// Every action here runs after requirePlatformAdmin (index.ts) with the service_role
// client, operates on ONE explicitly selected business, accepts only whitelisted
// fields, and writes an audit row (no secrets, tokens or passwords).
//
// Owner/customer RLS is untouched: these writes happen server-side only.
// Staff rules and employee access reuse the F1/F3 *_core SQL functions.
import {
  asTrimmed,
  jsonResponse,
  UUID_RE,
  writeAdminAudit,
  type AdminClient,
} from "./admin-guard.ts";
import { deriveSubscriptionStatus, loadCurrentSubscriptions, utcToday } from "./admin-subscriptions.ts";
import { CODE_HMAC_PREFIX, CODE_TTL_MS, formatCode, hmacHex, randomNineDigitCode } from "../staff-access/logic.ts";

type JsonMap = Record<string, unknown>;
type Ctx = { admin: AdminClient; userId: string };

const ACTIVATION_URL = (Deno.env.get("APP_ACTIVATION_URL") || "https://booking-app-fawn-five.vercel.app/activate/").trim();
const LOGO_BUCKET = "business-logos";
const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{1,58}[a-z0-9])$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const HEX_RE = /^#[0-9a-fA-F]{6}$/;

// Same keys as the app's SERVICE_VISUALS (index.html, assets/service-visuals/).
const SERVICE_VISUAL_KEYS = [
  "barber_haircut_01", "barber_hair_beard_01", "barber_shave_01", "hair_women_cut_01", "hair_coloring_01", "hair_styling_01",
  "hair_blowdry_01", "hair_treatment_01", "nails_manicure_01", "nails_gel_01", "nails_art_01", "nails_extensions_01",
  "nails_pedicure_01", "nails_advanced_pedicure_01", "beauty_makeup_01", "beauty_lashes_01", "beauty_eyebrows_01",
  "beauty_facial_01", "beauty_skin_01", "beauty_peeling_01", "beauty_waxing_01", "beauty_laser_hair_removal_01",
  "massage_relax_01", "massage_sports_01", "body_lymphatic_01", "body_anticellulite_01", "body_maderotherapy_01",
  "body_sculpting_01", "dentist_whitening_01", "dentist_treatment_01",
];

// Same ids as the app's selectable XBOOK_BUSINESS_CATEGORIES (index.html).
const BUSINESS_CATEGORIES = ["barber", "hair-salon", "beauty-salon", "nail-studio", "makeup-artist", "massage-therapy", "dental-clinic", "other"];

class Invalid extends Error {
  constructor(public code: string, message: string, public status = 400) {
    super(message);
  }
}

const category = (v: unknown): string => {
  const id = asTrimmed(v).toLowerCase();
  if (!BUSINESS_CATEGORIES.includes(id)) throw new Invalid("invalid_input", "Choose a business category.");
  return id;
};

const str = (v: unknown, max: number, label: string, required = false): string | null => {
  const s = asTrimmed(v);
  if (!s) {
    if (required) throw new Invalid("invalid_input", `${label} is required.`);
    return null;
  }
  if (s.length > max) throw new Invalid("invalid_input", `${label} is too long.`);
  return s;
};
const int = (v: unknown, min: number, max: number, label: string): number => {
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw new Invalid("invalid_input", `${label} must be ${min}–${max}.`);
  return n;
};
const bool = (v: unknown, label: string): boolean => {
  if (typeof v !== "boolean") throw new Invalid("invalid_input", `${label} must be true or false.`);
  return v;
};
const time = (v: unknown, label: string, nullable = false): string | null => {
  const s = asTrimmed(v).slice(0, 5);
  if (!s && nullable) return null;
  if (!TIME_RE.test(s)) throw new Invalid("invalid_input", `${label} must be HH:MM.`);
  return s;
};
export function normalizeSlug(value: unknown): string {
  return asTrimmed(value).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60);
}
const requireId = (v: unknown, label = "business_id"): string => {
  const id = asTrimmed(v);
  if (!UUID_RE.test(id)) throw new Invalid("invalid_input", `${label} is invalid.`);
  return id;
};

// ---------------------------------------------------------------------------
// Whitelisted business_settings fields (exactly what the owner app edits)
// ---------------------------------------------------------------------------
const SETTINGS_FIELDS: Record<string, (v: unknown) => unknown> = {
  business_name: (v) => str(v, 80, "Business name", true),
  business_category: (v) => category(v),
  business_description: (v) => str(v, 1000, "Description"),
  public_tagline: (v) => str(v, 140, "Tagline"),
  business_phone: (v) => str(v, 40, "Phone"),
  business_email: (v) => {
    const s = str(v, 120, "E-mail");
    if (s && !EMAIL_RE.test(s)) throw new Invalid("invalid_input", "E-mail is invalid.");
    return s;
  },
  business_website: (v) => str(v, 200, "Website"),
  business_address: (v) => str(v, 200, "Address"),
  business_instagram_url: (v) => str(v, 200, "Instagram"),
  business_facebook_url: (v) => str(v, 200, "Facebook"),
  business_accent_color: (v) => {
    const s = str(v, 7, "Accent colour");
    if (s && !HEX_RE.test(s)) throw new Invalid("invalid_input", "Accent colour must be #RRGGBB.");
    return s;
  },
  business_logo_url: (v) => str(v, 500, "Logo"),
  business_cover_url: (v) => str(v, 500, "Cover"),
  timezone: (v) => {
    const s = asTrimmed(v);
    if (!/^[A-Za-z_]+\/[A-Za-z_\/-]+$/.test(s)) throw new Invalid("invalid_input", "Timezone is invalid.");
    return s;
  },
  work_start: (v) => time(v, "Opening time"),
  work_end: (v) => time(v, "Closing time"),
  break_start: (v) => time(v, "Break start", true),
  break_end: (v) => time(v, "Break end", true),
  working_days: (v) => {
    if (!Array.isArray(v) || !v.length) throw new Invalid("invalid_input", "Choose at least one working day.");
    const days = [...new Set(v.map((d) => int(d, 0, 6, "Working day")))].sort();
    return days.map(String);
  },
  booking_window_weeks: (v) => int(v, 1, 52, "Booking window"),
  minimum_notice_minutes: (v) => int(v, 0, 10080, "Minimum notice"),
  booking_limits_enabled: (v) => bool(v, "Booking limits"),
  max_bookings_per_day: (v) => int(v, 1, 50, "Bookings per day"),
  max_bookings_per_week: (v) => int(v, 1, 100, "Bookings per week"),
  require_client_approval: (v) => bool(v, "Client approval"),
  accept_new_clients: (v) => bool(v, "Accept new clients"),
  allow_recurring_appointments: (v) => bool(v, "Recurring appointments"),
  public_show_logo: (v) => bool(v, "Show logo"),
  public_show_prices: (v) => bool(v, "Show prices"),
  public_show_staff: (v) => bool(v, "Show staff"),
  public_show_address: (v) => bool(v, "Show address"),
  public_show_about: (v) => bool(v, "Show about"),
  block_public_holidays: (v) => bool(v, "Public holidays"),
  holiday_country: (v) => {
    const s = asTrimmed(v).toUpperCase();
    if (!/^[A-Z]{2}$/.test(s)) throw new Invalid("invalid_input", "Holiday country must be a 2-letter code.");
    return s;
  },
  business_slug: (v) => {
    const s = normalizeSlug(v);
    if (!SLUG_RE.test(s)) throw new Invalid("invalid_input", "Business code: 3–60 letters, digits or dashes.");
    return s;
  },
};

const SETTINGS_SELECT = ["business_id", "onboarding_completed_at", ...Object.keys(SETTINGS_FIELDS)].join(", ");

async function slugTaken(admin: AdminClient, slug: string, exceptId?: string): Promise<boolean> {
  let q = admin.from("business_settings").select("business_id").eq("business_slug", slug);
  if (exceptId) q = q.neq("business_id", exceptId);
  const { data } = await q.limit(1);
  return Array.isArray(data) && data.length > 0;
}

async function requireBusiness(admin: AdminClient, businessId: string): Promise<JsonMap> {
  const { data, error } = await admin.from("business_settings").select(SETTINGS_SELECT).eq("business_id", businessId).maybeSingle();
  if (error) throw new Invalid("query_failed", "Could not load the business.", 500);
  if (!data) throw new Invalid("not_found", "Business not found.", 404);
  return data as unknown as JsonMap;
}

async function requireStaff(admin: AdminClient, businessId: string, staffId: string): Promise<JsonMap> {
  const { data } = await admin.from("staff_members").select("id, business_id, name").eq("id", staffId).eq("business_id", businessId).maybeSingle();
  if (!data) throw new Invalid("not_found", "Staff member not found for this business.", 404);
  return data as JsonMap;
}

async function onboardingRow(admin: AdminClient, businessId: string): Promise<JsonMap | null> {
  const { data } = await admin.from("business_onboarding").select("*").eq("business_id", businessId).maybeSingle();
  return (data as JsonMap) || null;
}

async function rpcCore(admin: AdminClient, name: string, args: JsonMap): Promise<JsonMap> {
  const { data, error } = await admin.rpc(name, args);
  if (error) {
    const msg = String(error.message || "");
    const notFound = /not found/i.test(msg);
    throw new Invalid(notFound ? "not_found" : "invalid_input", msg || "Operation failed.", notFound ? 404 : 400);
  }
  return (data && typeof data === "object" ? data : { ok: true, value: data }) as JsonMap;
}

// ---------------------------------------------------------------------------
// Status per business (draft / invited / active trial / active / expired / …)
// ---------------------------------------------------------------------------
type StatusRow = { onboarding: string | null; subscription: string; access_kind: string | null; expires: string | null };

async function statusMap(admin: AdminClient, ids: string[]): Promise<Map<string, StatusRow>> {
  const [subs, onboard] = await Promise.all([
    loadCurrentSubscriptions(admin),
    admin.from("business_onboarding").select("business_id, status").in("business_id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]),
  ]);
  const ob = new Map<string, string>();
  for (const r of (onboard.data || []) as JsonMap[]) ob.set(asTrimmed(r.business_id), asTrimmed(r.status));
  const today = utcToday();
  const out = new Map<string, StatusRow>();
  for (const id of ids) {
    const cur = subs === "missing" ? undefined : subs.get(id);
    out.set(id, {
      onboarding: ob.get(id) || null,
      subscription: deriveSubscriptionStatus(cur?.expires_on, today, Boolean(cur), {
        access_kind: cur?.access_kind, expires_at: cur?.expires_at ?? null,
      }),
      access_kind: cur?.access_kind || null,
      expires: (cur?.expires_at as string) || (cur?.expires_on as string) || null,
    });
  }
  return out;
}

/** draft | invited | trial | active | expired | unconfigured */
function lifecycle(s: StatusRow | undefined): string {
  if (!s) return "unconfigured";
  if (s.onboarding === "draft" || s.onboarding === "invited") return s.onboarding;
  if (s.subscription === "active") return s.access_kind === "trial" ? "trial" : "active";
  return s.subscription;
}

// One head-count / one-row query per business: avoids the PostgREST row cap on large tables.
async function countBy(admin: AdminClient, table: string, ids: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  await Promise.all(ids.map(async (id) => {
    const { count } = await admin.from(table).select("id", { count: "exact", head: true }).eq("business_id", id);
    out.set(id, count || 0);
  }));
  return out;
}

async function lastBookingAt(admin: AdminClient, ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  await Promise.all(ids.map(async (id) => {
    const { data } = await admin.from("bookings").select("created_at").eq("business_id", id)
      .order("created_at", { ascending: false }).limit(1);
    const row = (data || [])[0] as JsonMap | undefined;
    if (row?.created_at) out.set(id, String(row.created_at));
  }));
  return out;
}

/** Adds lifecycle status, counts and last booking time to the existing business list rows. */
export async function enrichBusinessList(admin: AdminClient, rows: JsonMap[]): Promise<JsonMap[]> {
  const ids = rows.map((r) => asTrimmed(r.business_id)).filter(Boolean);
  const [status, staff, services, bookings, last] = await Promise.all([
    statusMap(admin, ids), countBy(admin, "staff_members", ids), countBy(admin, "services", ids),
    countBy(admin, "bookings", ids), lastBookingAt(admin, ids),
  ]);
  return rows.map((r) => {
    const id = asTrimmed(r.business_id);
    const s = status.get(id);
    return {
      ...r,
      lifecycle: lifecycle(s),
      subscription_expires: s?.expires || null,
      staff_count: staff.get(id) || 0,
      service_count: services.get(id) || 0,
      bookings_total: bookings.get(id) || 0,
      last_booking_at: last.get(id) || null,
    };
  });
}

async function onboardingOverview(admin: AdminClient): Promise<JsonMap> {
  const { data: biz } = await admin.from("business_settings").select("business_id");
  const ids = ((biz || []) as JsonMap[]).map((r) => asTrimmed(r.business_id));
  const status = await statusMap(admin, ids);
  const counts: Record<string, number> = { draft: 0, invited: 0, trial: 0, active: 0, expired: 0, unconfigured: 0 };
  for (const id of ids) counts[lifecycle(status.get(id))] = (counts[lifecycle(status.get(id))] || 0) + 1;
  return { total: ids.length, ...counts, pending_invitations: counts.invited };
}

// ---------------------------------------------------------------------------
// Configuration snapshot of one business
// ---------------------------------------------------------------------------
async function businessConfig(admin: AdminClient, businessId: string): Promise<JsonMap> {
  const settings = await requireBusiness(admin, businessId);
  const today = utcToday();
  const [services, staff, staffServices, staffHours, closed, onboarding, account, status, bookingCount] = await Promise.all([
    admin.from("services").select("id, name, duration, price, icon_key, service_visual_key, created_at").eq("business_id", businessId).order("created_at"),
    admin.from("staff_members").select("id, name, role, active, photo_url, all_services, uses_business_hours, access_enabled, access_scope, access_user_id, can_create_bookings, created_at").eq("business_id", businessId).order("created_at"),
    admin.from("staff_services").select("staff_id, service_id").eq("business_id", businessId),
    admin.from("staff_working_hours").select("staff_id, dow, start_time, end_time, break_start, break_end").eq("business_id", businessId),
    admin.from("business_closed_days").select("date, reason, source").eq("business_id", businessId).gte("date", today).order("date"),
    onboardingRow(admin, businessId),
    admin.rpc("_admin_owner_account", { p_user_id: businessId }),
    statusMap(admin, [businessId]),
    admin.from("bookings").select("id", { count: "exact", head: true }).eq("business_id", businessId),
  ]);
  const svcByStaff = new Map<string, string[]>();
  for (const r of (staffServices.data || []) as JsonMap[]) {
    const k = asTrimmed(r.staff_id);
    svcByStaff.set(k, [...(svcByStaff.get(k) || []), asTrimmed(r.service_id)]);
  }
  const hoursByStaff = new Map<string, JsonMap[]>();
  for (const r of (staffHours.data || []) as JsonMap[]) {
    const k = asTrimmed(r.staff_id);
    hoursByStaff.set(k, [...(hoursByStaff.get(k) || []), {
      dow: r.dow, start: String(r.start_time || "").slice(0, 5), end: String(r.end_time || "").slice(0, 5),
      break_start: r.break_start ? String(r.break_start).slice(0, 5) : null, break_end: r.break_end ? String(r.break_end).slice(0, 5) : null,
    }]);
  }
  const s = status.get(businessId);
  return {
    settings: { ...settings, working_days: ((settings.working_days as unknown[]) || []).map((d) => Number(d)) },
    services: services.data || [],
    staff: ((staff.data || []) as JsonMap[]).map((m) => ({
      id: m.id, name: m.name, role: m.role, active: m.active !== false, photo_url: m.photo_url,
      all_services: m.all_services !== false, service_ids: svcByStaff.get(asTrimmed(m.id)) || [],
      uses_business_hours: m.uses_business_hours !== false,
      weekly_hours: (hoursByStaff.get(asTrimmed(m.id)) || []).sort((a, b) => Number(a.dow) - Number(b.dow)),
      access_enabled: m.access_enabled === true, access_scope: m.access_scope === "full" ? "full" : m.access_scope === "all" ? "all" : "own",
      access_connected: !!m.access_user_id,
      can_create_bookings: m.can_create_bookings === true,
    })),
    closed_days: closed.data || [],
    onboarding,
    owner_account: account.data || null,
    lifecycle: lifecycle(s),
    subscription_expires: s?.expires || null,
    booking_count: bookingCount.count ?? 0,
    public_url: settings.business_slug ? `https://booking-app-fawn-five.vercel.app/?business=${settings.business_slug}` : null,
    invite_delivery: await lastInviteAttempt(admin, businessId),
  };
}

/** Result of the latest activation e-mail attempt (from the audit log). */
async function lastInviteAttempt(admin: AdminClient, businessId: string): Promise<JsonMap | null> {
  const { data } = await admin.from("platform_admin_audit_log").select("action, metadata, created_at")
    .eq("business_id", businessId).in("action", ["send_invitation", "send_invitation_failed"])
    .order("created_at", { ascending: false }).limit(1);
  const row = (data || [])[0] as JsonMap | undefined;
  if (!row) return null;
  const ok = row.action === "send_invitation";
  const meta = (row.metadata || {}) as JsonMap;
  const delivery = ok && meta.email_id ? await resendDeliveryStatus(String(meta.email_id)).catch(() => ({ last_event: null })) : null;
  return { ok, at: row.created_at, channel: ok ? (meta.channel || "resend") : null, delivery_event: delivery?.last_event || null, message: ok ? null : (meta.provider_status || meta.provider_error ? emailFailureText(meta) : "Е-поштата за активација не е испратена.") };
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------
async function createDraft(ctx: Ctx, body: JsonMap): Promise<JsonMap> {
  const { admin, userId } = ctx;
  const name = str(body.business_name, 80, "Business name", true)!;
  const ownerEmail = (str(body.owner_email, 120, "Owner e-mail", true) || "").toLowerCase();
  if (!EMAIL_RE.test(ownerEmail)) throw new Invalid("invalid_input", "Owner e-mail is invalid.");
  const ownerName = str(body.owner_name, 120, "Owner name", true);
  const phone = str(body.owner_phone, 40, "Phone");
  const businessCategory = category(body.business_category);
  const address = str(body.business_address, 200, "Address");
  const lang = ["mk", "en", "sq"].includes(asTrimmed(body.preferred_language)) ? asTrimmed(body.preferred_language) : "mk";
  const slug = normalizeSlug(body.business_slug || name);
  if (!SLUG_RE.test(slug)) throw new Invalid("invalid_input", "Business code: 3–60 letters, digits or dashes.");
  if (await slugTaken(admin, slug)) throw new Invalid("slug_taken", "This business code is already used.", 409);

  const { data: emailState, error: emailErr } = await admin.rpc("_admin_owner_email_status", { p_email: ownerEmail });
  if (emailErr) throw new Invalid("query_failed", "Could not check the e-mail.", 500);
  const es = (emailState || {}) as JsonMap;
  if (es.auth_user_id) throw new Invalid("email_in_use", "An account with this e-mail already exists. Use another e-mail.", 409);
  if (es.open_draft_business_id) throw new Invalid("email_in_use", "A prepared business already uses this e-mail.", 409);

  const businessId = crypto.randomUUID();
  // service_role insert: no auth.uid(), so the existing trigger creates the business WITHOUT a trial.
  const { error: insErr } = await admin.from("business_settings").insert({
    business_id: businessId, business_slug: slug, business_name: name, business_category: businessCategory,
    business_phone: phone, business_address: address,
    onboarding_completed_at: null, onboarding_step: 1,
  });
  if (insErr) {
    if (/business_slug/i.test(insErr.message || "")) throw new Invalid("slug_taken", "This business code is already used.", 409);
    throw new Invalid("create_failed", "Could not create the business.", 500);
  }
  const { error: obErr } = await admin.from("business_onboarding").insert({
    business_id: businessId, status: "draft", owner_email: ownerEmail, owner_name: ownerName,
    owner_phone: phone, preferred_language: lang, created_by: userId,
  });
  if (obErr) {
    await admin.from("business_settings").delete().eq("business_id", businessId);
    throw new Invalid(/duplicate|unique/i.test(obErr.message || "") ? "email_in_use" : "create_failed",
      /duplicate|unique/i.test(obErr.message || "") ? "A prepared business already uses this e-mail." : "Could not create the business.", 409);
  }
  await writeAdminAudit(admin, { actorUserId: userId, action: "create_draft_business", businessId, metadata: { slug, language: lang } });
  return { business_id: businessId };
}

async function updateSettings(ctx: Ctx, businessId: string, patch: unknown): Promise<JsonMap> {
  if (!patch || typeof patch !== "object" || Array.isArray(patch)) throw new Invalid("invalid_input", "Nothing to save.");
  const current = await requireBusiness(ctx.admin, businessId);
  const update: JsonMap = {};
  for (const [key, value] of Object.entries(patch as JsonMap)) {
    const validate = SETTINGS_FIELDS[key];
    if (!validate) throw new Invalid("invalid_input", `Field ${key} cannot be changed here.`);
    update[key] = validate(value);
  }
  const ws = (update.work_start ?? current.work_start) as string;
  const we = (update.work_end ?? current.work_end) as string;
  if (ws && we && String(we).slice(0, 5) <= String(ws).slice(0, 5)) throw new Invalid("invalid_input", "Closing time must be after opening time.");
  const bs = "break_start" in update ? update.break_start : current.break_start;
  const be = "break_end" in update ? update.break_end : current.break_end;
  if ((bs == null) !== (be == null)) throw new Invalid("invalid_input", "Set both break times or none.");
  if (bs && be && String(be).slice(0, 5) <= String(bs).slice(0, 5)) throw new Invalid("invalid_input", "Break end must be after break start.");
  if (typeof update.business_slug === "string" && await slugTaken(ctx.admin, update.business_slug, businessId)) {
    throw new Invalid("slug_taken", "This business code is already used.", 409);
  }
  if (!Object.keys(update).length) return { ok: true };
  const { error } = await ctx.admin.from("business_settings").update(update).eq("business_id", businessId);
  if (error) throw new Invalid("save_failed", error.message || "Could not save.", 400);
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: "update_business_settings", businessId, metadata: { fields: Object.keys(update) } });
  return { ok: true };
}

async function saveService(ctx: Ctx, businessId: string, svc: JsonMap): Promise<JsonMap> {
  await requireBusiness(ctx.admin, businessId);
  const row: JsonMap = {
    name: str(svc.name, 80, "Service name", true),
    duration: int(svc.duration, 5, 480, "Duration (min)"),
    price: svc.price === null || svc.price === "" || svc.price === undefined ? null : Number(svc.price),
  };
  if (row.price !== null && !(Number.isFinite(row.price as number) && (row.price as number) >= 0)) throw new Invalid("invalid_input", "Price must be 0 or more.");
  if (svc.icon_key !== undefined) row.icon_key = str(svc.icon_key, 60, "Icon");
  if (svc.service_visual_key !== undefined) {
    const key = asTrimmed(svc.service_visual_key);
    if (key && !SERVICE_VISUAL_KEYS.includes(key)) throw new Invalid("invalid_input", "Unknown service picture.");
    row.service_visual_key = key || null;
  }
  const id = asTrimmed(svc.id);
  if (id) {
    requireId(id, "service id");
    const { data, error } = await ctx.admin.from("services").update(row).eq("id", id).eq("business_id", businessId).select("id");
    if (error || !data?.length) throw new Invalid("not_found", "Service not found for this business.", 404);
  } else {
    const { error } = await ctx.admin.from("services").insert({ ...row, business_id: businessId });
    if (error) throw new Invalid("save_failed", error.message || "Could not save the service.");
  }
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: id ? "update_service" : "create_service", businessId, metadata: { service_id: id || null } });
  return { ok: true };
}

async function saveStaff(ctx: Ctx, businessId: string, m: JsonMap): Promise<JsonMap> {
  await requireBusiness(ctx.admin, businessId);
  const row: JsonMap = {
    name: str(m.name, 80, "Name", true),
    role: str(m.role, 80, "Role"),
    active: m.active === undefined ? true : bool(m.active, "Active"),
  };
  if (m.photo_url !== undefined) row.photo_url = str(m.photo_url, 500, "Photo");
  if (m.can_create_bookings !== undefined) row.can_create_bookings = bool(m.can_create_bookings, "Can create appointments");
  const id = asTrimmed(m.id);
  let newId = "";
  if (id) {
    requireId(id, "staff id");
    const { data, error } = await ctx.admin.from("staff_members").update(row).eq("id", id).eq("business_id", businessId).select("id");
    if (error || !data?.length) throw new Invalid("not_found", "Staff member not found for this business.", 404);
  } else {
    const { data, error } = await ctx.admin.from("staff_members").insert({ ...row, business_id: businessId }).select("id").single();
    if (error || !data) throw new Invalid("save_failed", error?.message || "Could not save the staff member.");
    newId = String((data as JsonMap).id);
  }
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: id ? "update_staff" : "create_staff", businessId, metadata: { staff_id: id || newId, active: row.active } });
  return { ok: true, staff_id: id || newId };
}

async function uploadUrl(ctx: Ctx, businessId: string, body: JsonMap): Promise<JsonMap> {
  await requireBusiness(ctx.admin, businessId);
  const kind = asTrimmed(body.kind);
  const type = asTrimmed(body.content_type).toLowerCase();
  const ext = ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" } as Record<string, string>)[type];
  if (!ext) throw new Invalid("invalid_input", "Use a JPG, PNG or WebP image.");
  let path: string;
  if (kind === "logo" || kind === "cover") {
    path = `${businessId}/${kind}-${Date.now()}.${ext}`;
  } else if (kind === "staff") {
    const staffId = requireId(body.staff_id, "staff id");
    await requireStaff(ctx.admin, businessId, staffId);
    path = `${businessId}/staff/${staffId}-${Date.now()}.${ext}`;
  } else {
    throw new Invalid("invalid_input", "Unknown image type.");
  }
  const { data, error } = await ctx.admin.storage.from(LOGO_BUCKET).createSignedUploadUrl(path);
  if (error || !data) throw new Invalid("upload_failed", "Could not prepare the upload.", 500);
  const { data: pub } = ctx.admin.storage.from(LOGO_BUCKET).getPublicUrl(path);
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: "upload_image", businessId, metadata: { kind } });
  return { path, token: data.token, signed_url: data.signedUrl, public_url: pub.publicUrl };
}

const esc = (v: string) => v.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));

const INVITE_TEXT: Record<string, { subject: string; title: string; hello: string; body: string; button: string; note: string }> = {
  mk: {
    subject: "Вашиот бизнис е подготвен на GT Termin", title: "Вашиот бизнис е подготвен", hello: "Здраво",
    body: "е подготвен за вас на GT Termin. Активирајте го профилот и поставете своја лозинка.",
    button: "Активирај профил", note: "Линкот работи само еднаш и има рок на важење. Ако не ја очекувавте оваа порака, игнорирајте ја.",
  },
  en: {
    subject: "Your business is ready on GT Termin", title: "Your business is ready", hello: "Hello",
    body: "has been set up for you on GT Termin. Activate your account and choose your own password.",
    button: "Activate account", note: "The link works once and expires. If you did not expect this e-mail, you can ignore it.",
  },
  sq: {
    subject: "Biznesi juaj është gati në GT Termin", title: "Biznesi juaj është gati", hello: "Përshëndetje",
    body: "është përgatitur për ju në GT Termin. Aktivizoni llogarinë dhe zgjidhni fjalëkalimin tuaj.",
    button: "Aktivizo llogarinë", note: "Lidhja funksionon një herë dhe skadon. Nëse nuk e prisnit këtë email, mund ta injoroni.",
  },
};

const INVITE_FROM_ADDRESS = "bookings@gtwebstudio.com";

class EmailSendError extends Error {
  constructor(public detail: JsonMap) {
    super("email_send_failed");
  }
}

/** Branded activation e-mail through Resend (same verified domain as booking e-mails). */
async function sendActivationEmail(to: string, lang: string, businessName: string, ownerName: string, link: string): Promise<string> {
  const key = String(Deno.env.get("RESEND_API_KEY") || "").trim();
  if (!key) throw new EmailSendError({ provider_error: "not_configured" });
  // Same verified sender as the booking e-mails (send-booking-email). BOOKING_EMAIL_FROM is not used:
  // in production it holds Resend's sandbox address, which may only send to the Resend account owner.
  const fromAddress = INVITE_FROM_ADDRESS;
  const t = INVITE_TEXT[lang] || INVITE_TEXT.mk;
  const html = `<div style="margin:0;padding:24px 12px;background:#f3f5fb;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#0f172a">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;margin:0 auto;background:#ffffff;border:1px solid #d9e0ee;border-radius:18px">
<tr><td style="padding:28px 24px 8px"><div style="font-size:18px;font-weight:800;color:#001b5e">GT Termin</div></td></tr>
<tr><td style="padding:8px 24px 24px;font-size:15px;line-height:1.55">
<h1 style="font-size:20px;margin:0 0 10px">${esc(t.title)}</h1>
<p style="margin:0 0 14px">${esc(t.hello)}${ownerName ? " " + esc(ownerName) : ""}, <strong>${esc(businessName)}</strong> ${esc(t.body)}</p>
<p style="margin:0 0 22px"><a href="${esc(link)}" style="display:inline-block;background:#001b5e;color:#ffffff;text-decoration:none;font-weight:700;padding:13px 20px;border-radius:12px">${esc(t.button)}</a></p>
<p style="margin:0;color:#5b6578;font-size:13px">${esc(t.note)}</p>
</td></tr></table></div>`;
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: `GT Termin <${fromAddress}>`, to: [to], reply_to: "gtterminsupport@gtwebstudio.com", subject: t.subject, html }),
  });
  if (!res.ok) {
    // Resend error body: { statusCode, name, message }. Contains no key; e-mail addresses are masked.
    const body = await res.json().catch(() => ({})) as JsonMap;
    const detail = {
      provider_status: res.status,
      provider_error: asTrimmed(body.name).slice(0, 60),
      provider_message: asTrimmed(body.message).replace(/[^\s@<>]+@[^\s@<>]+/g, "[e-mail]").slice(0, 240),
      from_domain: fromAddress.split("@")[1] || "",
    };
    console.error("activation e-mail rejected by Resend", JSON.stringify(detail));
    throw new EmailSendError(detail);
  }
  const sent = await res.json().catch(() => ({})) as JsonMap;
  return asTrimmed(sent.id);
}

/** Delivery state of a Resend message (delivered, bounced, …) — read on the server, key never leaves it. */
async function resendDeliveryStatus(emailId: string): Promise<JsonMap> {
  const key = String(Deno.env.get("RESEND_API_KEY") || "").trim();
  if (!key || !/^[0-9a-f-]{36}$/i.test(emailId)) return { last_event: null };
  const res = await fetch(`https://api.resend.com/emails/${emailId}`, { headers: { Authorization: `Bearer ${key}` } });
  const body = await res.json().catch(() => ({})) as JsonMap;
  if (!res.ok) return { last_event: null, provider_status: res.status };
  return { last_event: asTrimmed(body.last_event) || null, created_at: body.created_at || null, from_domain: String(body.from || "").split("@")[1]?.replace(">", "") || "" };
}

/** Macedonian explanation for the admin; never includes keys, links or addresses. */
function emailFailureText(d: JsonMap): string {
  const status = Number(d.provider_status || 0);
  const msg = String(d.provider_message || "");
  const base = "Е-поштата за активација не е испратена. Поканата НЕ е доставена.";
  if (d.provider_error === "not_configured") return `${base} Сервисот за е-пошта не е поставен.`;
  if (d.provider_error === "network") return `${base} Сервисот за е-пошта не одговара. Обидете се повторно.`;
  if (/testing emails|own email address/i.test(msg)) {
    return `${base} Испраќачот (${d.from_domain || "?"}) е тест-адреса на Resend што праќа само до сопственикот на Resend сметката.`;
  }
  if (/domain.*not verified|verify.*domain/i.test(msg)) return `${base} Доменот ${d.from_domain || ""} не е потврден во Resend.`;
  if (status === 401 || status === 403) return `${base} Resend го одби праќањето (${status}: ${msg || d.provider_error}).`;
  if (status === 422) return `${base} Resend ја одби пораката (${msg || d.provider_error}).`;
  if (status === 429) return `${base} Премногу праќања одеднаш. Обидете се за една минута.`;
  return `${base} Грешка од Resend${status ? " " + status : ""}${msg ? ": " + msg : ""}.`;
}

async function sendInvitation(ctx: Ctx, businessId: string): Promise<JsonMap> {
  const { admin, userId } = ctx;
  const settings = await requireBusiness(admin, businessId);
  const ob = await onboardingRow(admin, businessId);
  if (!ob) throw new Invalid("not_prepared", "Овој бизнис не е подготвен преку Control Center.", 409);
  if (ob.status === "active") throw new Invalid("already_active", "Сопственикот веќе го активирал бизнисот.", 409);
  const email = asTrimmed(ob.owner_email).toLowerCase();

  const lang = asTrimmed(ob.preferred_language) || "mk";
  const redirectTo = `${ACTIVATION_URL}?lang=${lang}`;
  const { data: account } = await admin.rpc("_admin_owner_account", { p_user_id: businessId });
  const acc = (account || null) as JsonMap | null;
  const auditFail = (reason: string, extra: JsonMap = {}) =>
    writeAdminAudit(admin, { actorUserId: userId, action: "send_invitation_failed", businessId, metadata: { reason, ...extra } }).catch(() => {});

  // The one-time activation link is created on the server and e-mailed only to the owner
  // (Resend, same provider as booking e-mails). It is never returned to the panel or logged.
  let linkType: "invite" | "recovery" = "invite";
  if (acc?.email_confirmed_at) {
    // The owner opened the invitation but did not finish: password-setup link to the same page.
    linkType = "recovery";
  } else {
    if (!acc) {
      const { data: es } = await admin.rpc("_admin_owner_email_status", { p_email: email });
      if ((es as JsonMap | null)?.auth_user_id) {
        throw new Invalid("email_in_use", "Друга сметка веќе ја користи оваа е-пошта.", 409);
      }
      // Owner account with the SAME id as the prepared business (business_id = auth.uid()).
      // GoTrue stores a random, unknown password; the owner sets their own on activation.
      const { error } = await admin.auth.admin.createUser({
        id: businessId, email, email_confirm: false,
        user_metadata: { role: "admin", full_name: asTrimmed(ob.owner_name) || undefined, phone: asTrimmed(ob.owner_phone) || undefined },
      });
      if (error) {
        await auditFail("account");
        throw new Invalid("invite_failed", "Сметката на сопственикот не може да се создаде.", 400);
      }
    }
    // The owner lands directly on the dashboard after activation.
    if (!settings.onboarding_completed_at) {
      await admin.from("business_settings").update({ onboarding_completed_at: new Date().toISOString() }).eq("business_id", businessId);
    }
  }
  const { data: linkData, error: linkErr } = await admin.auth.admin.generateLink({ type: linkType, email, options: { redirectTo } });
  const actionLink = (linkData as { properties?: { action_link?: string } } | null)?.properties?.action_link || "";
  if (linkErr || !actionLink) {
    await auditFail("link");
    throw new Invalid("invite_failed", "Линкот за активација не може да се создаде. Поканата НЕ е испратена.", 500);
  }
  let channel = "resend";
  let resendDetail: JsonMap | null = null;
  let emailId = "";
  try {
    emailId = await sendActivationEmail(email, lang, asTrimmed(settings.business_name), asTrimmed(ob.owner_name), actionLink);
  } catch (err) {
    resendDetail = err instanceof EmailSendError ? err.detail : { provider_error: "network" };
    // Resend cannot send for this account (sandbox sender / unverified domain / no key):
    // fall back to Supabase Auth's own e-mail, which issues its own single-use link to the same page.
    const configIssue = resendDetail.provider_error === "not_configured" || Number(resendDetail.provider_status) === 403;
    let fallbackError = "";
    if (configIssue) {
      const { error } = linkType === "invite"
        ? await admin.auth.admin.inviteUserByEmail(email, { redirectTo, data: { role: "admin", gt_business_name: asTrimmed(settings.business_name), gt_language: lang } })
        : await admin.auth.resetPasswordForEmail(email, { redirectTo });
      if (!error) channel = "supabase_auth";
      else fallbackError = asTrimmed(error.message).replace(/[^\s@<>]+@[^\s@<>]+/g, "[e-mail]").slice(0, 160) || "error";
    }
    if (channel !== "supabase_auth") {
      await auditFail("email", { ...resendDetail, ...(fallbackError ? { fallback_error: fallbackError } : {}) });
      throw new Invalid("invite_email_failed", emailFailureText(resendDetail) + (fallbackError ? " Резервното праќање преку Supabase исто така не успеа." : ""), 502);
    }
  }
  await admin.from("business_onboarding").update({
    status: "invited", invited_at: new Date().toISOString(), invite_count: Number(ob.invite_count || 0) + 1,
    last_invited_by: userId, updated_at: new Date().toISOString(),
  }).eq("business_id", businessId);
  await writeAdminAudit(admin, { actorUserId: userId, action: "send_invitation", businessId, metadata: {
    count: Number(ob.invite_count || 0) + 1, channel, ...(emailId ? { email_id: emailId } : {}), ...(resendDetail ? { resend_status: resendDetail.provider_status, resend_error: resendDetail.provider_message } : {}),
  } });
  return { ok: true, channel, notice: channel === "supabase_auth"
    ? "Испратено преку Supabase (резервно), бидејќи доменот gtwebstudio.com не е потврден во Resend." : null };
}

async function cancelInvitation(ctx: Ctx, businessId: string): Promise<JsonMap> {
  const { admin, userId } = ctx;
  const ob = await onboardingRow(admin, businessId);
  if (!ob || ob.status !== "invited") throw new Invalid("not_invited", "Нема отворена покана.", 409);
  const { data: account } = await admin.rpc("_admin_owner_account", { p_user_id: businessId });
  const acc = (account || null) as JsonMap | null;
  if (acc && (acc.email_confirmed_at || acc.last_sign_in_at)) {
    throw new Invalid("already_used", "Сопственикот веќе го отворил линкот; поканата не може да се откаже.", 409);
  }
  // Removing the unused account voids every invitation link. The prepared business stays.
  if (acc) {
    const { error } = await admin.auth.admin.deleteUser(businessId);
    if (error) throw new Invalid("cancel_failed", "Could not cancel the invitation.", 500);
  }
  await admin.from("business_onboarding").update({ status: "draft", updated_at: new Date().toISOString() }).eq("business_id", businessId);
  await writeAdminAudit(admin, { actorUserId: userId, action: "cancel_invitation", businessId });
  return { ok: true };
}

async function issueStaffCode(ctx: Ctx, businessId: string, staffId: string): Promise<JsonMap> {
  const ob = await onboardingRow(ctx.admin, businessId);
  if (ob && ob.status !== "active") throw new Invalid("not_active", "Employee access codes are available after the owner activates the business.", 409);
  const secret = String(Deno.env.get("CUSTOMER_APP_LOGIN_HMAC_SECRET") || "").trim();
  if (secret.length < 32) throw new Invalid("not_configured", "Code secret is not configured.", 503);
  const code = randomNineDigitCode();
  const expiresAt = new Date(Date.now() + CODE_TTL_MS).toISOString();
  await rpcCore(ctx.admin, "_issue_staff_access_code_core", {
    p_business_id: businessId, p_staff_id: staffId, p_code_hmac: await hmacHex(secret, CODE_HMAC_PREFIX + code),
    p_expires_at: expiresAt, p_actor: ctx.userId,
  });
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: "issue_staff_code", businessId, metadata: { staff_id: staffId } });
  return { ok: true, code: formatCode(code), expires_at: expiresAt };
}

async function revokeStaff(ctx: Ctx, businessId: string, staffId: string): Promise<JsonMap> {
  const res = await rpcCore(ctx.admin, "_revoke_staff_access_core", { p_business_id: businessId, p_staff_id: staffId });
  const prev = asTrimmed(res.previous_user_id);
  if (UUID_RE.test(prev)) await ctx.admin.auth.admin.deleteUser(prev).catch(() => {});
  await writeAdminAudit(ctx.admin, { actorUserId: ctx.userId, action: "revoke_staff_access", businessId, metadata: { staff_id: staffId } });
  return { ok: true };
}

const HANDLED = new Set([
  "onboarding_overview", "create_draft_business", "get_business_config", "update_business_settings",
  "save_service", "delete_service", "assign_service_to_all_staff", "save_staff", "delete_staff",
  "set_staff_services", "set_staff_hours", "staff_rule_conflicts", "add_closed_days", "delete_closed_day",
  "set_staff_access_scope", "issue_staff_code", "revoke_staff_access", "create_upload_url",
  "send_invitation", "cancel_invitation", "list_audit",
]);

/** Returns a Response for the actions in this module, or null for everything else. */
export async function handleBusinessConfigAction(req: Request, action: string, body: JsonMap, ctx: Ctx): Promise<Response | null> {
  if (!HANDLED.has(action)) return null;
  const { admin, userId } = ctx;
  try {
    if (action === "onboarding_overview") {
      return jsonResponse(req, { ok: true, onboarding: await onboardingOverview(admin) });
    }
    if (action === "create_draft_business") {
      return jsonResponse(req, { ok: true, ...(await createDraft(ctx, body)) });
    }

    const businessId = requireId(body.business_id);
    switch (action) {
      case "get_business_config": {
        const config = await businessConfig(admin, businessId);
        await writeAdminAudit(admin, { actorUserId: userId, action: "open_business_config", businessId });
        return jsonResponse(req, { ok: true, config });
      }
      case "update_business_settings":
        return jsonResponse(req, await updateSettings(ctx, businessId, body.patch));
      case "save_service":
        return jsonResponse(req, await saveService(ctx, businessId, (body.service || {}) as JsonMap));
      case "delete_service": {
        const id = requireId(body.service_id, "service id");
        const { data } = await admin.from("services").delete().eq("id", id).eq("business_id", businessId).select("id");
        if (!data?.length) throw new Invalid("not_found", "Service not found for this business.", 404);
        await writeAdminAudit(admin, { actorUserId: userId, action: "delete_service", businessId, metadata: { service_id: id } });
        return jsonResponse(req, { ok: true });
      }
      case "assign_service_to_all_staff": {
        const res = await rpcCore(admin, "_assign_service_to_all_staff_core", { p_business_id: businessId, p_service_id: requireId(body.service_id, "service id") });
        await writeAdminAudit(admin, { actorUserId: userId, action: "assign_service_to_all_staff", businessId, metadata: { service_id: body.service_id } });
        return jsonResponse(req, { ok: true, result: res });
      }
      case "save_staff":
        return jsonResponse(req, await saveStaff(ctx, businessId, (body.staff || {}) as JsonMap));
      case "delete_staff": {
        const id = requireId(body.staff_id, "staff id");
        await requireStaff(admin, businessId, id);
        const { count } = await admin.from("bookings").select("id", { count: "exact", head: true }).eq("staff_id", id);
        if ((count || 0) > 0) throw new Invalid("has_bookings", "This team member has appointments. Deactivate instead of deleting.", 409);
        await revokeStaff(ctx, businessId, id).catch(() => {});
        await admin.from("staff_members").delete().eq("id", id).eq("business_id", businessId);
        await writeAdminAudit(admin, { actorUserId: userId, action: "delete_staff", businessId, metadata: { staff_id: id } });
        return jsonResponse(req, { ok: true });
      }
      case "set_staff_services": {
        const staffId = requireId(body.staff_id, "staff id");
        const res = await rpcCore(admin, "_set_staff_services_core", {
          p_business_id: businessId, p_staff_id: staffId, p_all_services: body.all_services === true,
          p_service_ids: Array.isArray(body.service_ids) ? body.service_ids.map((x) => requireId(x, "service id")) : null,
        });
        await writeAdminAudit(admin, { actorUserId: userId, action: "set_staff_services", businessId, metadata: { staff_id: staffId, all: body.all_services === true } });
        return jsonResponse(req, { ok: true, result: res });
      }
      case "set_staff_hours": {
        const staffId = requireId(body.staff_id, "staff id");
        const res = await rpcCore(admin, "_set_staff_working_hours_core", {
          p_business_id: businessId, p_staff_id: staffId, p_uses_business_hours: body.uses_business_hours === true,
          p_hours: Array.isArray(body.hours) ? body.hours : null,
        });
        await writeAdminAudit(admin, { actorUserId: userId, action: "set_staff_hours", businessId, metadata: { staff_id: staffId } });
        return jsonResponse(req, { ok: true, result: res });
      }
      case "staff_rule_conflicts": {
        const { data, error } = await admin.rpc("_list_staff_rule_conflicts_core", { p_business_id: businessId, p_staff_id: requireId(body.staff_id, "staff id") });
        if (error) throw new Invalid("query_failed", error.message, 400);
        return jsonResponse(req, { ok: true, conflicts: data || [] });
      }
      case "add_closed_days": {
        const dates = Array.isArray(body.dates) ? body.dates.map((d) => asTrimmed(d)) : [];
        if (!dates.length || dates.some((d) => !/^\d{4}-\d{2}-\d{2}$/.test(d))) throw new Invalid("invalid_input", "Choose valid dates.");
        const reason = str(body.reason, 120, "Reason");
        const { error } = await admin.from("business_closed_days").upsert(
          dates.map((date) => ({ business_id: businessId, date, reason, source: "manual" })), { onConflict: "business_id,date" });
        if (error) throw new Invalid("save_failed", error.message, 400);
        await writeAdminAudit(admin, { actorUserId: userId, action: "add_closed_days", businessId, metadata: { count: dates.length } });
        return jsonResponse(req, { ok: true });
      }
      case "delete_closed_day": {
        const date = asTrimmed(body.date);
        if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Invalid("invalid_input", "Invalid date.");
        await admin.from("business_closed_days").delete().eq("business_id", businessId).eq("date", date);
        await writeAdminAudit(admin, { actorUserId: userId, action: "delete_closed_day", businessId, metadata: { date } });
        return jsonResponse(req, { ok: true });
      }
      case "set_staff_access_scope": {
        const staffId = requireId(body.staff_id, "staff id");
        await rpcCore(admin, "_set_staff_access_scope_core", { p_business_id: businessId, p_staff_id: staffId, p_scope: asTrimmed(body.scope) });
        await writeAdminAudit(admin, { actorUserId: userId, action: "set_staff_access_scope", businessId, metadata: { staff_id: staffId, scope: body.scope } });
        return jsonResponse(req, { ok: true });
      }
      case "issue_staff_code":
        return jsonResponse(req, await issueStaffCode(ctx, businessId, requireId(body.staff_id, "staff id")));
      case "revoke_staff_access":
        return jsonResponse(req, await revokeStaff(ctx, businessId, requireId(body.staff_id, "staff id")));
      case "create_upload_url":
        return jsonResponse(req, { ok: true, ...(await uploadUrl(ctx, businessId, body)) });
      case "send_invitation":
        return jsonResponse(req, await sendInvitation(ctx, businessId));
      case "cancel_invitation":
        return jsonResponse(req, await cancelInvitation(ctx, businessId));
      case "list_audit": {
        const { data } = await admin.from("platform_admin_audit_log").select("action, actor_user_id, metadata, created_at")
          .eq("business_id", businessId).order("created_at", { ascending: false }).limit(100);
        const actors = [...new Set(((data || []) as JsonMap[]).map((r) => asTrimmed(r.actor_user_id)).filter(Boolean))];
        const { data: admins } = actors.length
          ? await admin.from("platform_admins").select("user_id, email").in("user_id", actors)
          : { data: [] };
        const emailById = new Map(((admins || []) as JsonMap[]).map((a) => [asTrimmed(a.user_id), asTrimmed(a.email)]));
        return jsonResponse(req, { ok: true, entries: ((data || []) as JsonMap[]).map((r) => ({
          action: r.action, actor: emailById.get(asTrimmed(r.actor_user_id)) || null, metadata: r.metadata, created_at: r.created_at,
        })) });
      }
    }
    return null;
  } catch (err) {
    if (err instanceof Invalid) return jsonResponse(req, { ok: false, error: err.code, message: err.message }, err.status);
    return jsonResponse(req, { ok: false, error: "internal_error" }, 500);
  }
}
