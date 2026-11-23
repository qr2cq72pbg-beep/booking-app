// Employee push (Phase F4): texts + delivery flow with injected dependencies.
// Called by the webhook on public.staff_push_events with { record: { id } }.
// The function never trusts the request body beyond the event id: it loads the
// event, claims it once (sent_at), re-checks that the recipient still has
// active access, and only then sends. No customer data or prices are sent.

export const MAX_EVENT_AGE_MS = 15 * 60 * 1000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type StaffPushEvent = {
  id: string;
  business_id: string;
  booking_id: string;
  staff_id: string;
  event_type: string;
  payload: Record<string, unknown>;
  created_at: string;
};

export type StaffTarget = { staff_id: string; user_id: string };
export type PushToken = { id: string; device_token: string; platform: string; locale: string | null };
export type SendResult = { ok: boolean; invalidToken?: boolean; error?: string };

export type Deps = {
  now: () => number;
  loadEvent: (id: string) => Promise<StaffPushEvent | null>;
  claimEvent: (id: string) => Promise<boolean>;
  /** Recipient if the staff member still has active, linked access; else null. */
  activeRecipient: (event: StaffPushEvent) => Promise<StaffTarget | null>;
  tokensFor: (target: StaffTarget) => Promise<PushToken[]>;
  send: (token: PushToken, title: string, body: string, data: Record<string, string>) => Promise<SendResult>;
  deleteToken: (tokenId: string) => Promise<void>;
  saveResult: (id: string, result: string) => Promise<void>;
};

const TEXT: Record<string, Record<string, string>> = {
  mk: {
    new: "Нов термин",
    rescheduled: "Терминот е преместен",
    cancelled: "Терминот е откажан",
    assigned: "Ви е доделен термин",
    unassigned: "Терминот е доделен на друг член",
    reassigned: "Терминот е доделен на {staff}",
    recurring: "повторлив",
  },
  en: {
    new: "New appointment",
    rescheduled: "Appointment moved",
    cancelled: "Appointment cancelled",
    assigned: "Appointment assigned to you",
    unassigned: "Appointment moved to another team member",
    reassigned: "Appointment assigned to {staff}",
    recurring: "repeating",
  },
  sq: {
    new: "Termin i ri",
    rescheduled: "Termini u zhvendos",
    cancelled: "Termini u anulua",
    assigned: "Ju është caktuar një termin",
    unassigned: "Termini iu caktua një anëtari tjetër",
    reassigned: "Termini iu caktua {staff}",
    recurring: "i përsëritur",
  },
};

function str(v: unknown): string {
  return String(v ?? "").trim();
}

/** "2026-11-20" + "10:00" → "20.11. 10:00" */
export function formatSlot(date: unknown, time: unknown): string {
  const d = str(date);
  const t = str(time).slice(0, 5);
  const m = d.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  const day = m ? `${m[3]}.${m[2]}.` : d;
  return [day, t].filter(Boolean).join(" ");
}

export function buildMessage(event: StaffPushEvent, locale: string | null): { title: string; body: string } {
  const lang = TEXT[str(locale)] ? str(locale) : "mk";
  const tx = TEXT[lang];
  const p = event.payload || {};
  const type = TEXT.en[event.event_type] ? event.event_type : "new";
  const title = tx[type].replace("{staff}", str(p.staff_name) || "—");
  const slot = formatSlot(p.date, p.time);
  const when = type === "rescheduled" && str(p.old_date)
    ? `${formatSlot(p.old_date, p.old_time)} → ${slot}`
    : slot;
  const parts = [when, str(p.service)].filter(Boolean);
  let body = parts.join(" · ");
  if (p.recurring === true) body += ` (${tx.recurring})`;
  return { title, body };
}

export function eventIdFromBody(raw: unknown): string {
  if (!raw || typeof raw !== "object") return "";
  const body = raw as Record<string, unknown>;
  const record = body.record && typeof body.record === "object" ? body.record as Record<string, unknown> : null;
  const id = str(record?.id ?? body.event_id);
  return UUID_RE.test(id) ? id : "";
}

export async function processStaffPushEvent(eventId: string, deps: Deps): Promise<Record<string, unknown>> {
  const event = await deps.loadEvent(eventId);
  if (!event) return { ok: false, error: "not_found" };

  const age = deps.now() - new Date(event.created_at).getTime();
  if (!(age >= 0 && age <= MAX_EVENT_AGE_MS)) {
    await deps.saveResult(event.id, "expired");
    return { ok: true, skipped: "expired" };
  }

  // Claim first: a repeated webhook call finds nothing to send.
  if (!(await deps.claimEvent(event.id))) return { ok: true, skipped: "already_sent" };

  const target = await deps.activeRecipient(event);
  if (!target) {
    await deps.saveResult(event.id, "no_access");
    return { ok: true, skipped: "no_access" };
  }

  const tokens = await deps.tokensFor(target);
  if (!tokens.length) {
    await deps.saveResult(event.id, "no_device");
    return { ok: true, skipped: "no_device" };
  }

  const data: Record<string, string> = {
    type: "staff_booking",
    event: event.event_type,
    booking_id: event.booking_id,
    date: str(event.payload?.date),
  };
  let sent = 0;
  let failed = 0;
  for (const token of tokens) {
    const { title, body } = buildMessage(event, token.locale);
    let result: SendResult;
    try {
      result = await deps.send(token, title, body, data);
    } catch (err) {
      result = { ok: false, error: String((err as Error)?.message || err) };
    }
    if (result.ok) {
      sent++;
    } else {
      failed++;
      if (result.invalidToken) await deps.deleteToken(token.id);
    }
  }
  await deps.saveResult(event.id, `sent:${sent} failed:${failed}`);
  return { ok: true, sent, failed };
}
