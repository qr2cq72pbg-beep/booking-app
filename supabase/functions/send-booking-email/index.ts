// Booking notification emails via Resend (v2).
// Auth: manage_token match OR admin JWT (sub === booking.business_id).
// verify_jwt must be OFF in Supabase Dashboard / config.toml.
const FUNCTION_VERSION = "send-booking-email-v2-type-normalize";

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

type EmailType = "booking_created" | "booking_rescheduled" | "booking_cancelled";

const VALID_TYPES = new Set<EmailType>([
  "booking_created",
  "booking_rescheduled",
  "booking_cancelled",
]);

interface RequestBody {
  type?: string;
  emailType?: string;
  bookingId?: string;
  booking_id?: string;
  id?: string;
  manageToken?: string;
  manage_token?: string;
  source?: string;
  status?: string;
  previousDate?: string;
  previousTime?: string;
  body?: RequestBody;
}

interface BookingRow {
  id: string;
  business_id: string;
  manage_token: string | null;
  booking_ref: string | null;
  customer_name: string | null;
  customer_email: string | null;
  customer_phone: string | null;
  service_name: string | null;
  date: string | null;
  time: string | null;
  booking_status: string | null;
  status: string | null;
  staff_id: string | null;
  notes: string | null;
}

interface BusinessSettingsRow {
  business_name: string | null;
  business_slug: string | null;
  business_phone: string | null;
  notification_email: string | null;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function isJwt(token: string): boolean {
  return token.split(".").length === 3;
}

function normalizeDate(value: unknown): string {
  const text = String(value ?? "").trim();
  const match = text.match(/(\d{4}-\d{2}-\d{2})/);
  return match ? match[1] : text;
}

function normalizeTime(value: unknown): string {
  const text = String(value ?? "").trim();
  const match = text.match(/(\d{1,2}:\d{2})/);
  return match ? match[1] : text;
}

function getBookingStatus(booking: BookingRow): string {
  const status = booking.booking_status || booking.status || "Pending";
  return String(status);
}

function unwrapRequestBody(raw: RequestBody): RequestBody {
  if (raw?.body && typeof raw.body === "object" && !Array.isArray(raw.body)) {
    return { ...raw.body, ...raw };
  }
  return raw;
}

function normalizeNotificationType(
  rawType: unknown,
  status?: unknown,
): { type: EmailType | null; reason?: string } {
  const normalized = String(rawType || "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "_")
    .replace(/-/g, "_");

  if (normalized === "booking_status_updated") {
    const mapped = String(status || "").toLowerCase() === "cancelled"
      ? "booking_cancelled"
      : "booking_rescheduled";
    return { type: mapped };
  }

  const aliases: Record<string, EmailType> = {
    booking_created: "booking_created",
    created: "booking_created",
    new_booking: "booking_created",
    booking_rescheduled: "booking_rescheduled",
    rescheduled: "booking_rescheduled",
    reschedule: "booking_rescheduled",
    booking_cancelled: "booking_cancelled",
    cancelled: "booking_cancelled",
    canceled: "booking_cancelled",
    cancel: "booking_cancelled",
  };

  if (aliases[normalized]) {
    return { type: aliases[normalized] };
  }

  return {
    type: null,
    reason: normalized
      ? `Unknown type "${String(rawType)}"`
      : "Missing type field",
  };
}

function resolveBookingId(body: RequestBody): string {
  const candidates = [body.bookingId, body.booking_id, body.id];
  for (const value of candidates) {
    const id = String(value ?? "").trim();
    if (id && id !== "undefined" && id !== "null") return id;
  }
  return "";
}

function resolveManageToken(body: RequestBody): string | null {
  const token = String(body.manageToken ?? body.manage_token ?? "").trim();
  return token || null;
}

function buildManageLink(
  baseUrl: string,
  slug: string | null,
  businessId: string,
  manageToken: string | null,
): string | null {
  if (!manageToken || !baseUrl) return null;
  const publicId = (slug || businessId).trim();
  const separator = baseUrl.includes("?") ? "&" : "?";
  return (
    baseUrl.replace(/\/$/, "") +
    `${separator}business=${encodeURIComponent(publicId)}&manage=${encodeURIComponent(manageToken)}`
  );
}

function formatAppointmentWhen(date: unknown, time: unknown): string {
  return `${normalizeDate(date)} at ${normalizeTime(time)}`;
}

function emailShell(title: string, bodyHtml: string, preheader = ""): string {
  const preheaderHtml = preheader
    ? `<div style="display:none;max-height:0;overflow:hidden;opacity:0;">${escapeHtml(preheader)}</div>`
    : "";
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
</head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;line-height:1.5;color:#111827;">
  ${preheaderHtml}
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px;">
    <tr>
      <td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:12px;border:1px solid #e5e7eb;overflow:hidden;box-shadow:0 4px 14px rgba(15,23,42,0.06);">
          <tr>
            <td style="padding:28px 24px 8px;">
              <h1 style="margin:0;font-size:22px;font-weight:700;letter-spacing:-0.02em;color:#111827;">${escapeHtml(title)}</h1>
            </td>
          </tr>
          <tr>
            <td style="padding:8px 24px 28px;">
              ${bodyHtml}
            </td>
          </tr>
          <tr>
            <td style="padding:16px 24px;background:#f9fafb;border-top:1px solid #e5e7eb;">
              <p style="margin:0;font-size:12px;color:#6b7280;">This is an automated message from your booking system.</p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}

function introParagraph(text: string): string {
  return `<p style="margin:0 0 20px;font-size:15px;color:#374151;">${text}</p>`;
}

function manageCtaButton(manageLink: string | null, label = "Manage booking"): string {
  if (!manageLink) return "";
  return `
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 12px;">
      <tr>
        <td style="border-radius:8px;background:#111827;">
          <a href="${escapeHtml(manageLink)}" style="display:inline-block;padding:14px 22px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(label)}</a>
        </td>
      </tr>
    </table>
    <p style="margin:0;font-size:12px;color:#9ca3af;word-break:break-all;line-height:1.45;">${escapeHtml(manageLink)}</p>`;
}

function newAppointmentHighlightCard(
  date: unknown,
  time: unknown,
  serviceName: string | null,
): string {
  const when = formatAppointmentWhen(date, time);
  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;border-collapse:separate;border-spacing:0;">
      <tr>
        <td style="padding:18px 20px;background:#ecfdf5;border:1px solid #86efac;border-radius:10px;">
          <p style="margin:0 0 6px;font-size:11px;font-weight:700;letter-spacing:0.08em;text-transform:uppercase;color:#047857;">New appointment</p>
          <p style="margin:0 0 4px;font-size:20px;font-weight:700;color:#065f46;letter-spacing:-0.02em;">${escapeHtml(when)}</p>
          ${serviceName ? `<p style="margin:0;font-size:14px;color:#047857;">${escapeHtml(serviceName)}</p>` : ""}
        </td>
      </tr>
    </table>`;
}

function previousAppointmentSection(date: unknown, time: unknown): string {
  const prevDate = normalizeDate(date);
  const prevTime = normalizeTime(time);
  if (!prevDate || !prevTime) return "";
  const when = formatAppointmentWhen(prevDate, prevTime);
  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;">
      <tr>
        <td style="padding:14px 16px;background:#f9fafb;border:1px solid #e5e7eb;border-radius:8px;">
          <p style="margin:0 0 4px;font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:0.06em;color:#6b7280;">Previous appointment</p>
          <p style="margin:0;font-size:14px;color:#4b5563;text-decoration:line-through;">${escapeHtml(when)}</p>
        </td>
      </tr>
    </table>`;
}

function securityNoteHtml(): string {
  return `<p style="margin:20px 0 0;font-size:13px;color:#6b7280;">If this was not you, contact the business.</p>`;
}

function bookingDetailsHtml(
  booking: BookingRow,
  business: BusinessSettingsRow | null,
  staffName: string | null,
  manageLink: string | null,
  includeManageLink: boolean,
  suppressDateTime = false,
): string {
  const ref = booking.booking_ref || booking.id;
  const status = getBookingStatus(booking);
  let html = `
  <table role="presentation" style="width:100%;border-collapse:collapse;font-size:14px;border:1px solid #e5e7eb;border-radius:8px;overflow:hidden;">
    <tr><td colspan="2" style="padding:10px 14px;background:#f9fafb;font-size:11px;font-weight:700;letter-spacing:0.06em;text-transform:uppercase;color:#6b7280;">Booking details</td></tr>
    <tr><td style="padding:10px 14px;color:#6b7280;width:120px;border-top:1px solid #f3f4f6;">Reference</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;"><strong>${escapeHtml(ref)}</strong></td></tr>
    <tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Business</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(business?.business_name || "Business")}</td></tr>
    <tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Customer</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(booking.customer_name || "Customer")}</td></tr>
    <tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Service</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(booking.service_name || "—")}</td></tr>`;

  if (!suppressDateTime) {
    html += `<tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Date</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(normalizeDate(booking.date))}</td></tr>
    <tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Time</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(normalizeTime(booking.time))}</td></tr>`;
  }

  html += `<tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Status</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(status)}</td></tr>`;

  if (staffName) {
    html += `<tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Staff</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(staffName)}</td></tr>`;
  }
  if (booking.customer_phone) {
    html += `<tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Phone</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(booking.customer_phone)}</td></tr>`;
  }
  if (booking.notes) {
    html += `<tr><td style="padding:10px 14px;color:#6b7280;border-top:1px solid #f3f4f6;">Notes</td><td style="padding:10px 14px;border-top:1px solid #f3f4f6;">${escapeHtml(booking.notes)}</td></tr>`;
  }

  html += `</table>`;

  if (includeManageLink && manageLink) {
    html += manageCtaButton(manageLink, "Manage booking");
  }

  return html;
}

function buildRescheduledCustomerEmail(
  booking: BookingRow,
  business: BusinessSettingsRow | null,
  staffName: string | null,
  manageLink: string | null,
  previousDate: string | null,
  previousTime: string | null,
): string {
  const businessName = escapeHtml(business?.business_name || "Business");
  const customerName = escapeHtml(booking.customer_name || "there");

  let html = introParagraph(
    `Hi ${customerName}, your appointment with <strong>${businessName}</strong> has been rescheduled. Here are your updated details:`,
  );

  html += newAppointmentHighlightCard(booking.date, booking.time, booking.service_name);
  html += previousAppointmentSection(previousDate, previousTime);
  html += bookingDetailsHtml(booking, business, staffName, manageLink, false, true);
  html += manageCtaButton(manageLink, "Manage booking");
  html += securityNoteHtml();

  return html;
}

function buildRescheduledAdminEmail(
  booking: BookingRow,
  business: BusinessSettingsRow | null,
  staffName: string | null,
  manageLink: string | null,
  previousDate: string | null,
  previousTime: string | null,
): string {
  const customerName = escapeHtml(booking.customer_name || "Customer");
  const when = escapeHtml(formatAppointmentWhen(booking.date, booking.time));

  let html = introParagraph(
    `A booking for <strong>${customerName}</strong> was rescheduled to <strong>${when}</strong>.`,
  );

  html += newAppointmentHighlightCard(booking.date, booking.time, booking.service_name);
  html += previousAppointmentSection(previousDate, previousTime);
  html += bookingDetailsHtml(booking, business, staffName, manageLink, false, true);

  return html;
}

function getEmailContent(
  type: EmailType,
  booking: BookingRow,
  business: BusinessSettingsRow | null,
  staffName: string | null,
  manageLink: string | null,
): { customerSubject: string; customerTitle: string; customerIntro: string; adminSubject: string; adminTitle: string; adminIntro: string } {
  const ref = booking.booking_ref || booking.id.slice(0, 8);
  const businessName = business?.business_name || "Business";
  const when = `${normalizeDate(booking.date)} at ${normalizeTime(booking.time)}`;

  if (type === "booking_created") {
    return {
      customerSubject: `Booking confirmed — ${ref}`,
      customerTitle: "Your booking is confirmed",
      customerIntro: `Thank you for booking with ${businessName}. Your appointment is scheduled for ${when}.`,
      adminSubject: `New booking — ${ref}`,
      adminTitle: "New booking received",
      adminIntro: `A new booking was made for ${when}.`,
    };
  }

  if (type === "booking_rescheduled") {
    return {
      customerSubject: `Your appointment has been rescheduled — ${ref}`,
      customerTitle: "Your appointment has been rescheduled",
      customerIntro: "",
      adminSubject: `Booking rescheduled — ${ref}`,
      adminTitle: "Booking rescheduled",
      adminIntro: "",
    };
  }

  return {
    customerSubject: `Booking cancelled — ${ref}`,
    customerTitle: "Your booking was cancelled",
    customerIntro: `Your appointment with ${businessName} on ${when} has been cancelled.`,
    adminSubject: `Booking cancelled — ${ref}`,
    adminTitle: "Booking cancelled",
    adminIntro: `A booking for ${when} was cancelled.`,
  };
}

async function sendResendEmail(
  apiKey: string,
  from: string,
  to: string,
  subject: string,
  html: string,
): Promise<void> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from, to: [to], subject, html }),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Resend error ${res.status}: ${text}`);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ ok: false, error: "Method not allowed" }, 405);
  }

  const resendKey = Deno.env.get("RESEND_API_KEY");
  const fromAddress = "Bookings <bookings@gtwebstudio.com>";
  const publicBaseUrl = Deno.env.get("APP_PUBLIC_BASE_URL") || "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!resendKey || !fromAddress) {
    return jsonResponse(
      { ok: false, error: "Email provider is not configured." },
      503,
    );
  }

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(
      { ok: false, error: "Supabase service credentials missing." },
      503,
    );
  }

  let rawBody: RequestBody;
  try {
    rawBody = await req.json();
  } catch (parseError) {
    console.error("send-booking-email: invalid JSON body", parseError);
    return jsonResponse({
      ok: false,
      error: "Invalid JSON body.",
      reason: "json_parse_failed",
      version: FUNCTION_VERSION,
    }, 400);
  }

  const body = unwrapRequestBody(rawBody);
  const rawType = body.type ?? body.emailType;
  const typeResult = normalizeNotificationType(rawType, body.status);
  const bookingId = resolveBookingId(body);
  const manageToken = resolveManageToken(body);

  console.log("send-booking-email: incoming request", {
    version: FUNCTION_VERSION,
    rawType,
    normalizedType: typeResult.type,
    bookingId: bookingId || null,
    hasManageToken: Boolean(manageToken),
    source: body.source || null,
    keys: Object.keys(body),
  });

  if (!typeResult.type) {
    console.error("send-booking-email: validation failed — invalid type", {
      rawType,
      reason: typeResult.reason,
      validTypes: [...VALID_TYPES],
    });
    return jsonResponse({
      ok: false,
      error: "Invalid notification type.",
      reason: typeResult.reason,
      receivedType: rawType ?? null,
      validTypes: [...VALID_TYPES],
      version: FUNCTION_VERSION,
    }, 400);
  }

  const type = typeResult.type;

  if (!bookingId) {
    console.error("send-booking-email: validation failed — missing bookingId", {
      bookingId: body.bookingId ?? null,
      booking_id: body.booking_id ?? null,
      id: body.id ?? null,
    });
    return jsonResponse({
      ok: false,
      error: "bookingId is required.",
      reason: "missing_booking_id",
      version: FUNCTION_VERSION,
    }, 400);
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: booking, error: bookingError } = await supabase
    .from("bookings")
    .select("*")
    .eq("id", bookingId)
    .maybeSingle();

  if (bookingError || !booking) {
    return jsonResponse({ ok: false, error: "Booking not found." }, 404);
  }

  const row = booking as BookingRow;

  let authorized = false;

  if (manageToken && row.manage_token && manageToken === row.manage_token) {
    authorized = true;
  }

  if (!authorized) {
    const authHeader = req.headers.get("Authorization") || "";
    const bearer = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (bearer && isJwt(bearer)) {
      const { data: userData, error: userError } = await supabase.auth.getUser(
        bearer,
      );
      if (!userError && userData?.user?.id === row.business_id) {
        authorized = true;
      }
    }
  }

  if (!authorized) {
    return jsonResponse({
      ok: false,
      error: "Forbidden.",
      version: FUNCTION_VERSION,
    }, 403);
  }

  const { data: settings } = await supabase
    .from("business_settings")
    .select("business_name, business_slug, business_phone, notification_email")
    .eq("business_id", row.business_id)
    .maybeSingle();

  const business = (settings || null) as BusinessSettingsRow | null;

  let staffName: string | null = null;
  if (row.staff_id) {
    const { data: staff } = await supabase
      .from("staff_members")
      .select("name")
      .eq("id", row.staff_id)
      .maybeSingle();
    staffName = staff?.name || null;
  }

  const { data: adminUser, error: adminError } = await supabase.auth.admin
    .getUserById(row.business_id);

  const ownerEmail =
    !adminError && adminUser?.user?.email
      ? String(adminUser.user.email).trim()
      : "";

  const notificationEmail = String(business?.notification_email || "").trim();
  const adminEmail = notificationEmail || ownerEmail;
  const manageLink = buildManageLink(
    publicBaseUrl,
    business?.business_slug || null,
    row.business_id,
    row.manage_token,
  );

  const copy = getEmailContent(
    type as EmailType,
    row,
    business,
    staffName,
    manageLink,
  );

  const previousDate = body.previousDate
    ? normalizeDate(body.previousDate)
    : null;
  const previousTime = body.previousTime
    ? normalizeTime(body.previousTime)
    : null;

  const isRescheduled = type === "booking_rescheduled";

  const customerBodyHtml = isRescheduled
    ? buildRescheduledCustomerEmail(
      row,
      business,
      staffName,
      manageLink,
      previousDate,
      previousTime,
    )
    : `<p style="margin:0 0 20px;font-size:15px;color:#374151;">${escapeHtml(copy.customerIntro)}</p>${bookingDetailsHtml(row, business, staffName, manageLink, true)}`;

  const adminBodyHtml = isRescheduled
    ? buildRescheduledAdminEmail(
      row,
      business,
      staffName,
      manageLink,
      previousDate,
      previousTime,
    )
    : `<p style="margin:0 0 20px;font-size:15px;color:#374151;">${escapeHtml(copy.adminIntro)}</p>${bookingDetailsHtml(row, business, staffName, manageLink, false)}`;

  const customerPreheader = isRescheduled
    ? `New time: ${formatAppointmentWhen(row.date, row.time)}`
    : copy.customerIntro;

  const results: { recipient: string; ok: boolean; error?: string }[] = [];

  console.log("Email config:", {
    version: FUNCTION_VERSION,
    fromAddress,
    businessId: row.business_id,
    hasNotificationEmail: Boolean(notificationEmail),
    hasOwnerEmail: Boolean(ownerEmail),
    hasCustomerEmail: Boolean(row.customer_email),
  });

  const customerEmail = String(row.customer_email || "").trim();
  if (customerEmail) {
    try {
      await sendResendEmail(
        resendKey,
        fromAddress,
        customerEmail,
        copy.customerSubject,
        emailShell(copy.customerTitle, customerBodyHtml, customerPreheader),
      );
      results.push({ recipient: "customer", ok: true });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Customer email failed:", message);
      results.push({ recipient: "customer", ok: false, error: message });
    }
  }

  if (adminEmail) {
    try {
      await sendResendEmail(
        resendKey,
        fromAddress,
        adminEmail,
        copy.adminSubject,
        emailShell(copy.adminTitle, adminBodyHtml, copy.adminSubject),
      );
      results.push({ recipient: "admin", ok: true });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      console.error("Admin email failed:", message);
      results.push({ recipient: "admin", ok: false, error: message });
    }
  }

  const anySent = results.some((r) => r.ok);
  const allFailed = results.length > 0 && results.every((r) => !r.ok);

  return jsonResponse({
    ok: anySent || results.length === 0,
    version: FUNCTION_VERSION,
    type,
    bookingId,
    results,
    skipped: {
      customer: !customerEmail ? "no_customer_email" : null,
      admin: !adminEmail ? "no_admin_email" : null,
    },
  }, allFailed ? 502 : 200);
});
