// Run: node supabase/functions/send-staff-booking-push/logic.test.ts   (Node 23.6+)
import { buildMessage, eventIdFromBody, formatSlot, processStaffPushEvent, type Deps, type StaffPushEvent } from "./logic.ts";

let passed = 0;
let failed = 0;
function ok(label: string, cond: boolean, detail = "") {
  if (cond) { passed++; console.log("ok - " + label); } else { failed++; console.log("FAIL - " + label + (detail ? " (" + detail + ")" : "")); }
}

const NOW = Date.parse("2026-11-20T10:00:00Z");
const ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const baseEvent = (over: Partial<StaffPushEvent> = {}): StaffPushEvent => ({
  id: ID, business_id: "b", booking_id: "bk", staff_id: "s", event_type: "new",
  payload: { date: "2026-11-21", time: "10:00", duration: 60, service: "Шминка", staff_name: "Мирјана", recurring: false },
  created_at: new Date(NOW - 5000).toISOString(), ...over,
});

ok("formatSlot", formatSlot("2026-11-21", "10:00:00") === "21.11. 10:00");
ok("MK new", JSON.stringify(buildMessage(baseEvent(), "mk")) === JSON.stringify({ title: "Нов термин", body: "21.11. 10:00 · Шминка" }));
ok("EN rescheduled shows old → new",
  buildMessage(baseEvent({ event_type: "rescheduled", payload: { ...baseEvent().payload, old_date: "2026-11-20", old_time: "09:00" } }), "en").body
    === "20.11. 09:00 → 21.11. 10:00 · Шминка");
ok("SQ cancelled", buildMessage(baseEvent({ event_type: "cancelled" }), "sq").title === "Termini u anulua");
ok("reassigned names the new member", buildMessage(baseEvent({ event_type: "reassigned" }), "mk").title === "Терминот е доделен на Мирјана");
ok("recurring marker", buildMessage(baseEvent({ payload: { ...baseEvent().payload, recurring: true } }), "mk").body.endsWith("(повторлив)"));
ok("unknown locale falls back to MK", buildMessage(baseEvent(), "de").title === "Нов термин");
ok("no customer data in texts", !JSON.stringify(buildMessage(baseEvent(), "mk")).includes("customer"));
ok("event id from webhook body", eventIdFromBody({ record: { id: ID } }) === ID && eventIdFromBody({ record: { id: "x" } }) === "");

function world(over: Partial<{ event: StaffPushEvent | null; claimed: boolean; access: boolean; tokens: number; invalid: boolean }> = {}) {
  const w = { results: [] as string[], deleted: [] as string[], sends: [] as Array<{ title: string; data: Record<string, string> }>, claims: 0 };
  const deps: Deps = {
    now: () => NOW,
    loadEvent: async () => (over.event === undefined ? baseEvent() : over.event),
    claimEvent: async () => { w.claims++; return over.claimed !== false && w.claims === 1; },
    activeRecipient: async () => (over.access === false ? null : { staff_id: "s", user_id: "u" }),
    tokensFor: async () => Array.from({ length: over.tokens ?? 2 }, (_, i) => ({
      id: "t" + i, device_token: "tok" + i, platform: i ? "ios" : "android", locale: i ? "en" : "mk" })),
    send: async (_t, title, _b, data) => { w.sends.push({ title, data }); return over.invalid ? { ok: false, invalidToken: true } : { ok: true }; },
    deleteToken: async (id) => { w.deleted.push(id); },
    saveResult: async (_id, r) => { w.results.push(r); },
  };
  return { w, deps };
}

{
  const { w, deps } = world();
  const r = await processStaffPushEvent(ID, deps);
  ok("sends to every device of the recipient, in its language", r.sent === 2 && w.sends[0].title === "Нов термин" && w.sends[1].title === "New appointment");
  ok("data payload opens the agenda (type/date/booking only)",
    JSON.stringify(Object.keys(w.sends[0].data).sort()) === JSON.stringify(["booking_id", "date", "event", "type"]) && w.sends[0].data.type === "staff_booking");
  const again = await processStaffPushEvent(ID, deps);
  ok("second webhook call sends nothing (claimed once)", again.skipped === "already_sent" && w.sends.length === 2);
}
{
  const { w, deps } = world({ access: false });
  const r = await processStaffPushEvent(ID, deps);
  ok("revoked / inactive member gets nothing", r.skipped === "no_access" && w.sends.length === 0);
}
{
  const { w, deps } = world({ event: baseEvent({ created_at: new Date(NOW - 20 * 60 * 1000).toISOString() }) });
  const r = await processStaffPushEvent(ID, deps);
  ok("stale events (>15 min) are not sent", r.skipped === "expired" && w.sends.length === 0);
}
{
  const { w, deps } = world({ tokens: 0 });
  ok("no device → recorded, nothing sent", (await processStaffPushEvent(ID, deps)).skipped === "no_device" && w.results[0] === "no_device");
}
{
  const { w, deps } = world({ invalid: true });
  await processStaffPushEvent(ID, deps);
  ok("invalid device tokens are removed", w.deleted.length === 2 && w.results[0] === "sent:0 failed:2");
}
{
  const { deps } = world({ event: null });
  ok("unknown event → not_found", (await processStaffPushEvent(ID, deps)).error === "not_found");
}

console.log(`passed=${passed} failed=${failed}`);
if (failed) process.exit(1);
