import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { Link, useParams } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";
import {
  addClosedDays,
  assignServiceToAll,
  cancelInvitation,
  DAY_NAMES,
  DAY_ORDER,
  deleteClosedDay,
  deleteService,
  deleteStaff,
  errorText,
  fetchAudit,
  fetchBusinessConfig,
  fetchStaffConflicts,
  issueStaffCode,
  LIFECYCLE_CLASS,
  LIFECYCLE_LABEL,
  revokeStaffAccess,
  saveService,
  saveStaff,
  sendInvitation,
  setStaffAccessScope,
  setStaffHours,
  setStaffServices,
  updateBusinessSettings,
  uploadBusinessImage,
  type AuditEntry,
  type BusinessConfig,
  type BusinessSettings,
  type DayHours,
  type ServiceRow,
  type StaffRow,
} from "../lib/configApi";
import { formatDateTime } from "../lib/format";
import { CategorySelect } from "../components/CategorySelect";
import { SERVICE_VISUALS, suggestedVisualKeys, suggestVisualFromName, visualByKey, VISUAL_TABS } from "../lib/serviceVisuals";

type Tab = "profile" | "services" | "staff" | "schedule" | "appearance" | "activation" | "subscription" | "audit";
const TABS: Array<[Tab, string]> = [
  ["profile", "Профил"],
  ["services", "Услуги"],
  ["staff", "Вработени"],
  ["schedule", "Распоред"],
  ["appearance", "Изглед"],
  ["activation", "Активација"],
  ["subscription", "Претплата"],
  ["audit", "Историја"],
];

type Runner = (fn: () => Promise<unknown>, okText: string) => Promise<boolean>;

export function BusinessConfigPage() {
  const { businessId = "" } = useParams();
  const { accessToken } = useAuth();
  const [config, setConfig] = useState<BusinessConfig | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("profile");
  const [toast, setToast] = useState<{ ok: boolean; text: string } | null>(null);

  const reload = useCallback(async () => {
    if (!accessToken || !businessId) return;
    try {
      setConfig(await fetchBusinessConfig(accessToken, businessId));
      setLoadError(null);
    } catch (err) {
      setLoadError(errorText(err, "Бизнисот не може да се вчита."));
    }
  }, [accessToken, businessId]);

  useEffect(() => {
    void reload();
  }, [reload]);

  useEffect(() => {
    if (!toast) return;
    const h = window.setTimeout(() => setToast(null), 4500);
    return () => window.clearTimeout(h);
  }, [toast]);

  const run: Runner = async (fn, okText) => {
    try {
      await fn();
      setToast({ ok: true, text: okText });
      await reload();
      return true;
    } catch (err) {
      setToast({ ok: false, text: errorText(err) });
      await reload();
      return false;
    }
  };

  if (loadError) {
    return (
      <div>
        <Link to="/businesses">← Бизниси</Link>
        <div className="error-banner" style={{ marginTop: 16 }}>{loadError}</div>
      </div>
    );
  }
  if (!config || !accessToken) return <div className="loading">Се вчитува бизнисот…</div>;
  const s = config.settings;

  return (
    <div className="config-page">
      <div className="admin-mode-banner" role="note">
        <div>
          <strong>Администраторски режим</strong>
          <span> — ги уредувате поставките на „{s.business_name}“ преку Control Center. Сопственикот не е најавен и неговата лозинка не се користи.</span>
        </div>
        <Link className="secondary-btn" to={`/businesses/${businessId}`}>← Назад кон Super Admin</Link>
      </div>

      <div className="detail-hero">
        {s.business_logo_url ? <img className="avatar" src={s.business_logo_url} alt="" /> : <div className="avatar">{(s.business_name || "B").slice(0, 1).toUpperCase()}</div>}
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 style={{ marginBottom: 4 }}>{s.business_name}</h1>
          <p className="lede" style={{ margin: 0 }}>
            <span className={LIFECYCLE_CLASS[config.lifecycle]}>{LIFECYCLE_LABEL[config.lifecycle]}</span>{" "}
            {s.business_slug} · {config.services.length} услуги · {config.staff.length} вработени · {config.booking_count} термини
          </p>
        </div>
        {config.public_url ? (
          <a className="secondary-btn" href={config.public_url} target="_blank" rel="noreferrer">Преглед за клиенти ↗</a>
        ) : null}
      </div>

      <nav className="tabs" role="tablist" aria-label="Поставки на бизнисот">
        {TABS.map(([key, label]) => (
          <button key={key} type="button" role="tab" aria-selected={tab === key} className={`tab ${tab === key ? "active" : ""}`} onClick={() => setTab(key)}>
            {label}
          </button>
        ))}
      </nav>

      {toast ? <div className={toast.ok ? "ok-banner toast" : "error-banner toast"} role="status">{toast.text}</div> : null}

      {tab === "profile" ? <ProfileTab settings={s} token={accessToken} run={run} /> : null}
      {tab === "services" ? <ServicesTab config={config} token={accessToken} run={run} /> : null}
      {tab === "staff" ? <StaffTab config={config} token={accessToken} run={run} /> : null}
      {tab === "schedule" ? <ScheduleTab config={config} token={accessToken} run={run} /> : null}
      {tab === "appearance" ? <AppearanceTab config={config} token={accessToken} run={run} /> : null}
      {tab === "activation" ? <ActivationTab config={config} token={accessToken} run={run} /> : null}
      {tab === "subscription" ? <SubscriptionTab config={config} /> : null}
      {tab === "audit" ? <AuditTab businessId={businessId} token={accessToken} /> : null}
    </div>
  );
}

// ---------------------------------------------------------------------------
function Panel({ title, children, actions }: { title: string; children: ReactNode; actions?: ReactNode }) {
  return (
    <section className="panel">
      <div className="panel-head">
        <h2>{title}</h2>
        {actions}
      </div>
      <div className="panel-body">{children}</div>
    </section>
  );
}

function TextField({ label, value, onChange, type = "text", max = 200, placeholder }: {
  label: string; value: string; onChange: (v: string) => void; type?: string; max?: number; placeholder?: string;
}) {
  return (
    <label className="field-label">
      {label}
      <input className="search" type={type} value={value} maxLength={max} placeholder={placeholder} onChange={(e) => onChange(e.target.value)} />
    </label>
  );
}

function Check({ label, checked, onChange, disabled }: { label: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className="check-row">
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  );
}

/** Keeps a local copy of settings and sends only the changed fields. */
function useSettingsDraft(settings: BusinessSettings) {
  const [draft, setDraft] = useState<BusinessSettings>(settings);
  useEffect(() => setDraft(settings), [settings]);
  const set = <K extends keyof BusinessSettings>(key: K, value: BusinessSettings[K]) => setDraft((d) => ({ ...d, [key]: value }));
  const changed = (keys: Array<keyof BusinessSettings>): Partial<BusinessSettings> => {
    const patch: Record<string, unknown> = {};
    for (const k of keys) {
      const a = draft[k];
      const b = settings[k];
      if (JSON.stringify(a ?? null) !== JSON.stringify(b ?? null)) {
        patch[k] = typeof a === "string" && a.trim() === "" ? null : a;
      }
    }
    return patch as Partial<BusinessSettings>;
  };
  return { draft, set, changed };
}

// ---------------------------------------------------------------------------
const PROFILE_KEYS: Array<keyof BusinessSettings> = [
  "business_name", "business_category", "business_description", "public_tagline", "business_phone", "business_email",
  "business_website", "business_address", "business_instagram_url", "business_facebook_url", "business_slug",
];

function ProfileTab({ settings, token, run }: { settings: BusinessSettings; token: string; run: Runner }) {
  const { draft, set, changed } = useSettingsDraft(settings);
  const v = (k: keyof BusinessSettings) => String(draft[k] ?? "");
  return (
    <Panel
      title="Профил на бизнисот"
      actions={<button type="button" className="primary-btn" onClick={() => void run(async () => {
        if (!draft.business_category) throw new Error("Изберете категорија на бизнисот.");
        await updateBusinessSettings(token, settings.business_id, changed(PROFILE_KEYS));
      }, "Профилот е зачуван.")}>Зачувај</button>}
    >
      <div className="form-grid">
        <TextField label="Име на бизнисот *" value={v("business_name")} max={80} onChange={(x) => set("business_name", x)} />
        <label className="field-label">
          Категорија *
          <CategorySelect value={draft.business_category} onChange={(id) => set("business_category", id)} />
        </label>
        <TextField label="Код на бизнисот (линк)" value={v("business_slug")} max={60} onChange={(x) => set("business_slug", x.toLowerCase())} />
        <TextField label="Кратко мото" value={v("public_tagline")} max={140} onChange={(x) => set("public_tagline", x)} />
        <TextField label="Телефон" type="tel" value={v("business_phone")} max={40} onChange={(x) => set("business_phone", x)} />
        <TextField label="Е-пошта за клиенти" type="email" value={v("business_email")} max={120} onChange={(x) => set("business_email", x)} />
        <TextField label="Веб-страница" value={v("business_website")} onChange={(x) => set("business_website", x)} />
        <TextField label="Адреса" value={v("business_address")} onChange={(x) => set("business_address", x)} />
        <TextField label="Instagram" value={v("business_instagram_url")} onChange={(x) => set("business_instagram_url", x)} />
        <TextField label="Facebook" value={v("business_facebook_url")} onChange={(x) => set("business_facebook_url", x)} />
      </div>
      <label className="field-label" style={{ marginTop: 12 }}>
        Опис
        <textarea className="search" rows={4} maxLength={1000} value={v("business_description")} onChange={(e) => set("business_description", e.target.value)} />
      </label>
    </Panel>
  );
}

// ---------------------------------------------------------------------------
function ServicesTab({ config, token, run }: { config: BusinessConfig; token: string; run: Runner }) {
  const id = config.settings.business_id;
  const empty = { id: "", name: "", duration: "30", price: "", visual: "", visualTouched: false };
  const [form, setForm] = useState(empty);
  const category = config.settings.business_category;
  const anyCustomList = config.staff.some((m) => !m.all_services);
  const currency = "MKD";

  async function submit() {
    const ok = await run(
      () => saveService(token, id, {
        id: form.id || undefined, name: form.name, duration: Number(form.duration),
        price: form.price === "" ? null : Number(form.price), service_visual_key: form.visual || null,
      } as Partial<ServiceRow>),
      form.id ? "Услугата е изменета." : "Услугата е додадена.",
    );
    if (ok) setForm(empty);
  }

  return (
    <>
      <Panel title={form.id ? "Измени услуга" : "Нова услуга"}>
        <div className="form-grid">
          <TextField label="Име на услугата *" value={form.name} max={80} onChange={(x) => setForm({
            ...form, name: x, visual: form.visualTouched ? form.visual : suggestVisualFromName(x, category) || form.visual,
          })} />
          <TextField label="Времетраење (минути) *" type="number" value={form.duration} onChange={(x) => setForm({ ...form, duration: x })} />
          <TextField label={`Цена (${currency})`} type="number" value={form.price} onChange={(x) => setForm({ ...form, price: x })} />
        </div>
        <VisualPicker category={category} value={form.visual} onChange={(key) => setForm({ ...form, visual: key, visualTouched: true })} />
        <div className="row-actions" style={{ marginTop: 12 }}>
          {form.id ? <button type="button" className="secondary-btn" onClick={() => setForm(empty)}>Откажи</button> : null}
          <button type="button" className="primary-btn" onClick={() => void submit()}>{form.id ? "Зачувај" : "Додај услуга"}</button>
        </div>
        <p className="muted" style={{ marginBottom: 0 }}>
          Опис, категорија и активирање на услуга не постојат во апликацијата GT Termin, затоа не се прикажуваат тука.
        </p>
      </Panel>
      <Panel title={`Услуги (${config.services.length})`}>
        {config.services.length === 0 ? <div className="empty">Сè уште нема услуги.</div> : (
          <div className="table-wrap">
            <table>
              <thead><tr><th>Услуга</th><th>Времетраење</th><th>Цена</th><th></th></tr></thead>
              <tbody>
                {config.services.map((svc) => (
                  <tr key={svc.id}>
                    <td data-label="Услуга">
                      <div className="svc-cell">
                        {visualByKey(svc.service_visual_key) ? <img className="svc-thumb" src={visualByKey(svc.service_visual_key)!.src} alt="" /> : <span className="svc-thumb empty" />}
                        <strong>{svc.name}</strong>
                      </div>
                    </td>
                    <td data-label="Времетраење">{svc.duration ?? 30} мин</td>
                    <td data-label="Цена">{svc.price == null ? "—" : `${svc.price} ${currency}`}</td>
                    <td>
                      <div className="row-actions">
                        <button type="button" className="text-btn" onClick={() => setForm({ id: svc.id, name: svc.name, duration: String(svc.duration ?? 30), price: svc.price == null ? "" : String(svc.price), visual: svc.service_visual_key || "", visualTouched: true })}>Уреди</button>
                        {anyCustomList ? (
                          <button type="button" className="text-btn" onClick={() => void run(() => assignServiceToAll(token, id, svc.id), "Услугата е доделена на сите вработени.")}>Додели на сите</button>
                        ) : null}
                        <button type="button" className="text-btn danger-text" onClick={() => {
                          if (window.confirm(`Да се избрише „${svc.name}“? Постоечките термини остануваат.`)) void run(() => deleteService(token, id, svc.id), "Услугата е избришана.");
                        }}>Избриши</button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>
    </>
  );
}

function VisualPicker({ category, value, onChange }: { category: string | null; value: string; onChange: (key: string) => void }) {
  const [tab, setTab] = useState<(typeof VISUAL_TABS)[number]["id"]>("suggested");
  const keys = tab === "suggested" ? suggestedVisualKeys(category)
    : tab === "all" ? SERVICE_VISUALS.map((x) => x.key)
    : SERVICE_VISUALS.filter((x) => x.pack === tab).map((x) => x.key);
  const current = visualByKey(value);
  return (
    <div className="visual-picker">
      <div className="visual-head">
        <span className="field-label" style={{ margin: 0 }}>Слика на услугата</span>
        <span className="muted">{current ? current.label : "Без визуел"}</span>
      </div>
      <div className="filter-pills">
        {VISUAL_TABS.map((t) => (
          <button key={t.id} type="button" className={`filter-pill ${tab === t.id ? "active" : ""}`} onClick={() => setTab(t.id)}>{t.label}</button>
        ))}
      </div>
      <div className="visual-grid">
        <button type="button" className={`visual-tile none ${!value ? "active" : ""}`} onClick={() => onChange("")}>
          <span className="visual-none">—</span><span>Без визуел</span>
        </button>
        {keys.map((key) => {
          const vis = visualByKey(key)!;
          return (
            <button key={key} type="button" className={`visual-tile ${value === key ? "active" : ""}`} onClick={() => onChange(key)} aria-pressed={value === key}>
              <img src={vis.src} alt="" loading="lazy" />
              <span>{vis.label}</span>
            </button>
          );
        })}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
function StaffTab({ config, token, run }: { config: BusinessConfig; token: string; run: Runner }) {
  const id = config.settings.business_id;
  const [selected, setSelected] = useState<string | null>(config.staff[0]?.id || null);
  const [newName, setNewName] = useState("");
  const [newRole, setNewRole] = useState("");
  const [newPhoto, setNewPhoto] = useState<File | null>(null);
  const newPhotoUrl = useMemo(() => (newPhoto ? URL.createObjectURL(newPhoto) : ""), [newPhoto]);
  useEffect(() => () => { if (newPhotoUrl) URL.revokeObjectURL(newPhotoUrl); }, [newPhotoUrl]);
  const member = config.staff.find((m) => m.id === selected) || null;

  return (
    <div className="split">
      <Panel title={`Вработени (${config.staff.length})`}>
        <div className="staff-list">
          {config.staff.map((m) => (
            <button key={m.id} type="button" className={`staff-item ${m.id === selected ? "active" : ""}`} onClick={() => setSelected(m.id)}>
              <strong>{m.name}</strong>
              <span className="muted">
                {m.active ? "" : "Неактивен · "}
                {m.all_services ? "Сите услуги" : `${m.service_ids.length} услуги`} · {m.uses_business_hours ? "работно време на бизнисот" : "свое работно време"}
                {m.access_connected ? " · има пристап" : ""}
              </span>
            </button>
          ))}
          {config.staff.length === 0 ? <div className="empty">Сè уште нема вработени.</div> : null}
        </div>
        <div className="form-grid" style={{ marginTop: 12 }}>
          <TextField label="Име на нов вработен" value={newName} max={80} onChange={setNewName} />
          <TextField label="Улога" value={newRole} max={80} onChange={setNewRole} placeholder="пр. Фризер" />
        </div>
        <div className="photo-row">
          {newPhotoUrl ? <img className="avatar" src={newPhotoUrl} alt="" /> : <div className="avatar">{(newName || "?").slice(0, 1)}</div>}
          <ImagePicker label={newPhoto ? "Промени фотографија" : "Фотографија (изборно)"} onPick={setNewPhoto} />
          {newPhoto ? <button type="button" className="text-btn danger-text" onClick={() => setNewPhoto(null)}>Отстрани</button> : null}
        </div>
        <button type="button" className="primary-btn" style={{ marginTop: 10 }} onClick={() => void run(async () => {
          const name = newName;
          const role = newRole || null;
          const staffId = await saveStaff(token, id, { name, role, active: true });
          if (newPhoto && staffId) {
            const url = await uploadBusinessImage(token, id, "staff", newPhoto, staffId);
            await saveStaff(token, id, { id: staffId, name, role, active: true, photo_url: url });
          }
          setNewName("");
          setNewRole("");
          setNewPhoto(null);
        }, "Вработениот е додаден.")}>Додај вработен</button>
      </Panel>
      {member ? <StaffEditor key={member.id} member={member} config={config} token={token} run={run} /> : null}
    </div>
  );
}

function StaffEditor({ member, config, token, run }: { member: StaffRow; config: BusinessConfig; token: string; run: Runner }) {
  const id = config.settings.business_id;
  const [name, setName] = useState(member.name);
  const [role, setRole] = useState(member.role || "");
  const [active, setActive] = useState(member.active);
  const [allServices, setAllServices] = useState(member.all_services);
  const [serviceIds, setServiceIds] = useState<string[]>(member.service_ids);
  const [usesBusiness, setUsesBusiness] = useState(member.uses_business_hours);
  const defaultHours = useMemo(() => buildHoursFromBusiness(config.settings), [config.settings]);
  const [hours, setHours] = useState<Record<number, DayHours | null>>(() => {
    const map: Record<number, DayHours | null> = {};
    for (const d of DAY_ORDER) map[d] = member.uses_business_hours ? defaultHours[d] : member.weekly_hours.find((h) => h.dow === d) || null;
    return map;
  });
  const [code, setCode] = useState<{ code: string; expires_at: string } | null>(null);
  const [conflicts, setConflicts] = useState<Array<{ booking_date: string; booking_time: string; service_name: string; reason: string }>>([]);
  const canIssueCodes = config.lifecycle !== "draft" && config.lifecycle !== "invited";

  async function afterRuleChange() {
    try {
      setConflicts(await fetchStaffConflicts(token, id, member.id));
    } catch {
      setConflicts([]);
    }
  }

  return (
    <div className="stack">
      <Panel title={`Профил — ${member.name}`} actions={
        <button type="button" className="primary-btn" onClick={() => void run(() => saveStaff(token, id, { id: member.id, name, role: role || null, active }), "Вработениот е зачуван.")}>Зачувај</button>
      }>
        <div className="form-grid">
          <TextField label="Име" value={name} max={80} onChange={setName} />
          <TextField label="Улога" value={role} max={80} onChange={setRole} />
        </div>
        <Check label="Активен (може да се закажува кај него)" checked={active} onChange={setActive} />
        <div className="photo-row">
          {member.photo_url ? <img className="avatar" src={member.photo_url} alt="" /> : <div className="avatar">{member.name.slice(0, 1)}</div>}
          <ImagePicker label="Фотографија" onPick={(file) => void run(async () => {
            const url = await uploadBusinessImage(token, id, "staff", file, member.id);
            await saveStaff(token, id, { id: member.id, name, role: role || null, active, photo_url: url });
          }, "Фотографијата е зачувана.")} />
        </div>
        <button type="button" className="text-btn danger-text" onClick={() => {
          if (window.confirm(`Да се избрише „${member.name}“? Ако има термини, ќе биде одбиено — тогаш деактивирајте го.`)) {
            void run(() => deleteStaff(token, id, member.id), "Вработениот е избришан.");
          }
        }}>Избриши вработен</button>
      </Panel>

      <Panel title="Услуги" actions={
        <button type="button" className="primary-btn" onClick={() => void run(async () => {
          await setStaffServices(token, id, member.id, allServices, serviceIds);
          await afterRuleChange();
        }, "Услугите се зачувани.")}>Зачувај услуги</button>
      }>
        <Check label="Ги изведува сите услуги" checked={allServices} onChange={(v) => {
          setAllServices(v);
          if (!v && serviceIds.length === 0) setServiceIds(config.services.map((x) => x.id));
        }} />
        {!allServices ? (
          <>
            <div className="check-list">
              {config.services.map((svc) => (
                <Check key={svc.id} label={`${svc.name} · ${svc.duration ?? 30} мин`} checked={serviceIds.includes(svc.id)}
                  onChange={(v) => setServiceIds((ids) => (v ? [...ids, svc.id] : ids.filter((x) => x !== svc.id)))} />
              ))}
            </div>
            <label className="field-label">
              Копирај од друг вработен
              <select className="search" value="" onChange={(e) => {
                const src = config.staff.find((m) => m.id === e.target.value);
                if (!src) return;
                setAllServices(src.all_services);
                setServiceIds(src.all_services ? config.services.map((x) => x.id) : src.service_ids);
              }}>
                <option value="">Изберете…</option>
                {config.staff.filter((m) => m.id !== member.id).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
              </select>
            </label>
          </>
        ) : null}
      </Panel>

      <Panel title="Работно време" actions={
        <button type="button" className="primary-btn" onClick={() => void run(async () => {
          const list = DAY_ORDER.map((d) => hours[d]).filter((h): h is DayHours => !!h);
          await setStaffHours(token, id, member.id, usesBusiness, list);
          await afterRuleChange();
        }, "Работното време е зачувано.")}>Зачувај работно време</button>
      }>
        <Check label="Исто како работното време на бизнисот" checked={usesBusiness} onChange={setUsesBusiness} />
        {!usesBusiness ? (
          <div className="day-rows">
            {DAY_ORDER.map((d) => {
              const h = hours[d];
              return (
                <div key={d} className={`day-row ${h ? "" : "off"}`}>
                  <Check label={DAY_NAMES[d]} checked={!!h} onChange={(on) => setHours((m) => ({ ...m, [d]: on ? (defaultHours[d] || { dow: d, start: "09:00", end: "17:00", break_start: null, break_end: null }) : null }))} />
                  {h ? (
                    <div className="day-times">
                      <input className="search" type="time" step={900} value={h.start} onChange={(e) => setHours((m) => ({ ...m, [d]: { ...h, start: e.target.value } }))} />
                      <span>–</span>
                      <input className="search" type="time" step={900} value={h.end} onChange={(e) => setHours((m) => ({ ...m, [d]: { ...h, end: e.target.value } }))} />
                      <span className="muted">пауза</span>
                      <input className="search" type="time" step={900} value={h.break_start || ""} onChange={(e) => setHours((m) => ({ ...m, [d]: { ...h, break_start: e.target.value || null } }))} />
                      <span>–</span>
                      <input className="search" type="time" step={900} value={h.break_end || ""} onChange={(e) => setHours((m) => ({ ...m, [d]: { ...h, break_end: e.target.value || null } }))} />
                    </div>
                  ) : <span className="muted">Слободен ден</span>}
                </div>
              );
            })}
          </div>
        ) : null}
        <p className="muted" style={{ marginBottom: 0 }}>Отсуствата (одмор, боледување) ги внесува сопственикот во апликацијата.</p>
        {conflicts.length ? (
          <div className="notice">
            {conflicts.length} идни термини повеќе не одговараат на новите поставки. Останати се непроменети:
            <ul>{conflicts.slice(0, 8).map((c, i) => <li key={i}>{c.booking_date} {String(c.booking_time).slice(0, 5)} · {c.service_name}</li>)}</ul>
          </div>
        ) : null}
      </Panel>

      <Panel title="Пристап до апликацијата">
        <p className="muted" style={{ marginTop: 0 }}>
          {member.access_connected ? "Вработениот има пристап (само преглед на термини)." : member.access_enabled ? "Се чека вработениот да го внесе кодот." : "Нема пристап."}
        </p>
        <div className="check-list">
          <label className="check-row"><input type="radio" name={`scope-${member.id}`} checked={member.access_scope === "own"} onChange={() => void run(() => setStaffAccessScope(token, id, member.id, "own"), "Зачувано.")} /><span>Само свои термини</span></label>
          <label className="check-row"><input type="radio" name={`scope-${member.id}`} checked={member.access_scope === "all"} onChange={() => void run(() => setStaffAccessScope(token, id, member.id, "all"), "Зачувано.")} /><span>Сите термини на бизнисот</span></label>
          <label className="check-row"><input type="radio" name={`scope-${member.id}`} checked={member.access_scope === "full"} onChange={() => {
            if (window.confirm("Целосен преглед на бизнисот: вработениот ќе гледа извештаи, аналитика, приходи и сите клиенти со телефони и е-пошта (само читање, без измени). Да продолжам?")) {
              void run(() => setStaffAccessScope(token, id, member.id, "full"), "Зачувано.");
            }
          }} /><span>Целосен преглед на бизнисот (само читање)</span></label>
        </div>
        <p className="notice" style={{ marginTop: 0 }}>
          „Целосен преглед“ отвора извештаи, аналитика, приходи и сите клиенти со контакти (само читање). Доделете го само на партнери и менаџери.
        </p>
        <Check label="Може сам да закажува термини (само за себе)" checked={member.can_create_bookings}
          onChange={(v) => void run(() => saveStaff(token, id, { id: member.id, name: member.name, role: member.role, active: member.active, can_create_bookings: v }), "Зачувано.")} />
        <p className="muted" style={{ marginTop: 0 }}>Промените се зачувуваат веднаш. Измена и откажување на термини останува само кај сопственикот.</p>
        {code ? (
          <div className="notice">
            Код за вработениот: <strong className="code">{code.code}</strong> · важи до {formatDateTime(code.expires_at)} · само еднаш.
          </div>
        ) : null}
        <div className="row-actions">
          <button type="button" className="primary-btn" disabled={!canIssueCodes || !member.active} onClick={() => void run(async () => setCode(await issueStaffCode(token, id, member.id)), "Кодот е креиран.")}>
            Креирај код за пристап
          </button>
          {member.access_enabled || member.access_connected ? (
            <button type="button" className="danger-btn" onClick={() => {
              if (window.confirm("Да се одземе пристапот? Вработениот ќе биде одјавен на сите уреди.")) void run(async () => {
                await revokeStaffAccess(token, id, member.id);
                setCode(null);
              }, "Пристапот е одземен.");
            }}>Одземи пристап</button>
          ) : null}
        </div>
        {!canIssueCodes ? <p className="muted" style={{ marginBottom: 0 }}>Кодови за вработени може да се креираат откако сопственикот ќе го активира бизнисот.</p> : null}
      </Panel>
    </div>
  );
}

function buildHoursFromBusiness(s: BusinessSettings): Record<number, DayHours | null> {
  const out: Record<number, DayHours | null> = {};
  for (const d of DAY_ORDER) {
    out[d] = (s.working_days || []).includes(d)
      ? { dow: d, start: (s.work_start || "09:00").slice(0, 5), end: (s.work_end || "17:00").slice(0, 5), break_start: s.break_start ? s.break_start.slice(0, 5) : null, break_end: s.break_end ? s.break_end.slice(0, 5) : null }
      : null;
  }
  return out;
}

// ---------------------------------------------------------------------------
const SCHEDULE_KEYS: Array<keyof BusinessSettings> = [
  "work_start", "work_end", "break_start", "break_end", "working_days", "booking_window_weeks", "minimum_notice_minutes",
  "require_client_approval", "accept_new_clients", "allow_recurring_appointments", "booking_limits_enabled",
  "max_bookings_per_day", "max_bookings_per_week", "block_public_holidays",
];

function ScheduleTab({ config, token, run }: { config: BusinessConfig; token: string; run: Runner }) {
  const { draft, set, changed } = useSettingsDraft(config.settings);
  const id = config.settings.business_id;
  const [day, setDay] = useState("");
  const [reason, setReason] = useState("");
  const days = draft.working_days || [];
  const save = () => {
    const patch = changed(SCHEDULE_KEYS);
    for (const k of ["break_start", "break_end"] as const) if (k in patch && !patch[k]) patch[k] = null;
    return run(() => updateBusinessSettings(token, id, patch), "Распоредот е зачуван.");
  };
  return (
    <>
      <Panel title="Работно време на бизнисот" actions={<button type="button" className="primary-btn" onClick={() => void save()}>Зачувај</button>}>
        <div className="form-grid">
          <TextField label="Отвора" type="time" value={(draft.work_start || "").slice(0, 5)} onChange={(x) => set("work_start", x)} />
          <TextField label="Затвора" type="time" value={(draft.work_end || "").slice(0, 5)} onChange={(x) => set("work_end", x)} />
          <TextField label="Пауза од" type="time" value={(draft.break_start || "").slice(0, 5)} onChange={(x) => set("break_start", x || null)} />
          <TextField label="Пауза до" type="time" value={(draft.break_end || "").slice(0, 5)} onChange={(x) => set("break_end", x || null)} />
        </div>
        <div className="check-list inline">
          {DAY_ORDER.map((d) => (
            <Check key={d} label={DAY_NAMES[d]} checked={days.includes(d)} onChange={(v) => set("working_days", v ? [...days, d] : days.filter((x) => x !== d))} />
          ))}
        </div>
        <h3 className="sub-head">Закажување</h3>
        <div className="form-grid">
          <TextField label="Колку недели однапред" type="number" value={String(draft.booking_window_weeks ?? 4)} onChange={(x) => set("booking_window_weeks", Number(x))} />
          <TextField label="Минимално известување (минути)" type="number" value={String(draft.minimum_notice_minutes ?? 60)} onChange={(x) => set("minimum_notice_minutes", Number(x))} />
        </div>
        <Check label="Новите клиенти чекаат одобрување" checked={!!draft.require_client_approval} onChange={(v) => set("require_client_approval", v)} />
        <Check label="Прима нови клиенти" checked={!!draft.accept_new_clients} onChange={(v) => set("accept_new_clients", v)} />
        <Check label="Дозволи повторливи термини" checked={!!draft.allow_recurring_appointments} onChange={(v) => set("allow_recurring_appointments", v)} />
        <Check label="Ограничи број на термини по клиент" checked={!!draft.booking_limits_enabled} onChange={(v) => set("booking_limits_enabled", v)} />
        {draft.booking_limits_enabled ? (
          <div className="form-grid">
            <TextField label="Најмногу на ден" type="number" value={String(draft.max_bookings_per_day ?? 1)} onChange={(x) => set("max_bookings_per_day", Number(x))} />
            <TextField label="Најмногу неделно" type="number" value={String(draft.max_bookings_per_week ?? 5)} onChange={(x) => set("max_bookings_per_week", Number(x))} />
          </div>
        ) : null}
        <Check label="Затворено за државни празници" checked={!!draft.block_public_holidays} onChange={(v) => set("block_public_holidays", v)} />
      </Panel>
      <Panel title="Неработни денови">
        <div className="form-grid">
          <TextField label="Датум" type="date" value={day} onChange={setDay} />
          <TextField label="Причина (изборно)" value={reason} max={120} onChange={setReason} />
        </div>
        <button type="button" className="primary-btn" style={{ marginTop: 10 }} disabled={!day} onClick={() => void run(async () => {
          await addClosedDays(token, id, [day], reason);
          setDay("");
          setReason("");
        }, "Неработниот ден е додаден.")}>Додај неработен ден</button>
        {config.closed_days.length ? (
          <ul className="plain-list">
            {config.closed_days.map((c) => (
              <li key={c.date}>
                <span>{c.date}{c.reason ? ` · ${c.reason}` : ""}{c.source && c.source !== "manual" ? " (празник)" : ""}</span>
                {c.source === "manual" || !c.source ? (
                  <button type="button" className="text-btn danger-text" onClick={() => void run(() => deleteClosedDay(token, id, c.date), "Отстрането.")}>Отстрани</button>
                ) : null}
              </li>
            ))}
          </ul>
        ) : <p className="muted">Нема идни неработни денови.</p>}
      </Panel>
    </>
  );
}

// ---------------------------------------------------------------------------
function ImagePicker({ label, onPick }: { label: string; onPick: (file: File) => void }) {
  return (
    <label className="secondary-btn file-btn">
      {label}
      <input type="file" accept="image/jpeg,image/png,image/webp" hidden onChange={(e) => {
        const file = e.target.files?.[0];
        e.target.value = "";
        if (!file) return;
        if (file.size > 5 * 1024 * 1024) {
          window.alert("Сликата е преголема (најмногу 5 MB).");
          return;
        }
        onPick(file);
      }} />
    </label>
  );
}

const APPEARANCE_KEYS: Array<keyof BusinessSettings> = [
  "business_accent_color", "public_show_prices", "public_show_staff", "public_show_address", "public_show_about",
];

function AppearanceTab({ config, token, run }: { config: BusinessConfig; token: string; run: Runner }) {
  const { draft, set, changed } = useSettingsDraft(config.settings);
  const id = config.settings.business_id;
  const upload = (kind: "cover") => (file: File) => void run(async () => {
    const url = await uploadBusinessImage(token, id, kind, file);
    await updateBusinessSettings(token, id, { business_cover_url: url });
  }, "Насловната слика е зачувана.");
  return (
    <>
      <Panel title="Насловна слика">
        <div className="image-box wide cover-box">{config.settings.business_cover_url ? <img src={config.settings.business_cover_url} alt="Насловна" /> : <span className="muted">Нема насловна слика</span>}</div>
        <ImagePicker label={config.settings.business_cover_url ? "Промени насловна" : "Прикачи насловна"} onPick={upload("cover")} />
      </Panel>
      <Panel title="Страница за закажување" actions={<button type="button" className="primary-btn" onClick={() => void run(() => updateBusinessSettings(token, id, changed(APPEARANCE_KEYS)), "Изгледот е зачуван.")}>Зачувај</button>}>
        <label className="field-label" style={{ maxWidth: 220 }}>
          Боја на брендот
          <input className="search" type="color" value={draft.business_accent_color || "#001b5e"} onChange={(e) => set("business_accent_color", e.target.value)} />
        </label>
        <Check label="Прикажи цени" checked={!!draft.public_show_prices} onChange={(v) => set("public_show_prices", v)} />
        <Check label="Прикажи вработени" checked={!!draft.public_show_staff} onChange={(v) => set("public_show_staff", v)} />
        <Check label="Прикажи адреса" checked={!!draft.public_show_address} onChange={(v) => set("public_show_address", v)} />
        <Check label="Прикажи „За нас“" checked={!!draft.public_show_about} onChange={(v) => set("public_show_about", v)} />
        <p className="muted">Темите (светла, темна, Liquid Metal) ги избира секој корисник во апликацијата; тие не се поставка на бизнисот.</p>
        {config.public_url ? <a className="secondary-btn" href={config.public_url} target="_blank" rel="noreferrer">Отвори ја страницата за клиенти ↗</a> : null}
      </Panel>
    </>
  );
}

// ---------------------------------------------------------------------------
const DELIVERY_LABEL: Record<string, string> = {
  sent: "испратена, се чека достава", delivered: "доставена", delivery_delayed: "доставата доцни",
  bounced: "вратена (адресата не постои или одбива)", complained: "означена како спам", opened: "отворена", clicked: "линкот е кликнат",
  queued: "во ред за праќање", scheduled: "закажана",
};

function ActivationTab({ config, token, run }: { config: BusinessConfig; token: string; run: Runner }) {
  const id = config.settings.business_id;
  const ob = config.onboarding;
  const acc = config.owner_account;
  if (!ob) {
    return (
      <Panel title="Активација">
        <p className="muted" style={{ margin: 0 }}>Овој бизнис го регистрирал самиот сопственик. Нема покана за праќање.</p>
      </Panel>
    );
  }
  const delivery = config.invite_delivery;
  const failed = ob.status === "invited" && !!delivery && !delivery.ok;
  const step = ob.status === "draft" || failed ? 0 : ob.status === "invited" ? 1 : 2;
  const missing: string[] = [];
  if (!config.services.length) missing.push("услуги");
  if (!config.staff.length) missing.push("вработени");
  return (
    <Panel title="Активација на сопственикот">
      <ol className="steps">
        {["Нацрт", failed ? "Праќањето не успеа" : "Покана испратена", "Активиран"].map((label, i) => (
          <li key={label} className={i <= step ? "done" : failed && i === 1 ? "failed" : ""}>{label}</li>
        ))}
      </ol>
      <div className="meta-grid">
        <div className="meta-item"><span>Сопственик</span><strong>{ob.owner_name || "—"}</strong><div className="muted">{ob.owner_email}</div><div className="muted">{ob.owner_phone || ""}</div></div>
        <div className="meta-item"><span>Покана</span><strong>{failed ? "Не е доставена" : ob.invited_at ? formatDateTime(ob.invited_at) : "Не е испратена"}</strong><div className="muted">{failed && delivery ? `Неуспешен обид ${formatDateTime(delivery.at)} · ` : ""}Успешно испратена {ob.invite_count}× · јазик {ob.preferred_language.toUpperCase()}</div></div>
        <div className="meta-item"><span>Сметка</span><strong>{ob.status === "active" ? "Активна" : acc?.email_confirmed_at ? "Линкот е отворен, активацијата не е завршена" : acc ? "Чека сопственикот да го отвори линкот" : "Се креира при праќање"}</strong><div className="muted">{acc?.last_sign_in_at ? `Последна најава ${formatDateTime(acc.last_sign_in_at)}` : ""}</div></div>
      </div>
      {failed && delivery ? (
        <div className="error-banner">{delivery.message || "Е-поштата за активација не е испратена."} Претходно испратените линкови повеќе не важат — испратете повторно.</div>
      ) : null}
      {ob.status === "invited" && delivery?.ok && delivery.channel === "resend" ? (
        <div className={delivery.delivery_event === "bounced" || delivery.delivery_event === "complained" ? "error-banner" : "notice"}>
          Последна покана {formatDateTime(delivery.at)} · статус кај Resend: <strong>{DELIVERY_LABEL[delivery.delivery_event || ""] || delivery.delivery_event || "непознат"}</strong>
        </div>
      ) : null}
      {ob.status === "invited" && delivery?.ok && delivery.channel === "supabase_auth" ? (
        <div className="notice">Последната покана ({formatDateTime(delivery.at)}) е испратена преку Supabase (резервно), бидејќи доменот gtwebstudio.com не е потврден во Resend. Пораката е стандардната од Supabase, без GT Termin дизајн.</div>
      ) : null}
      {ob.status !== "active" && missing.length ? <div className="notice">Сè уште нема {missing.join(" и ")}. Поканата може да се прати, но бизнисот не е целосно подготвен.</div> : null}
      <p className="muted">
        Сопственикот добива е-пошта од GT Termin со линк за активација (еднократен, со рок на важење). Ја потврдува е-поштата, сам поставува лозинка
        и се најавува во апликацијата. Пробниот период од 14 дена започнува дури при активацијата. Вие никогаш не ја гледате неговата лозинка.
      </p>
      <div className="row-actions">
        {ob.status === "draft" ? (
          <button type="button" className="primary-btn" onClick={() => {
            if (window.confirm(`Да се испрати покана на ${ob.owner_email}?`)) void run(() => sendInvitation(token, id), "Поканата е испратена.");
          }}>Испрати активација</button>
        ) : null}
        {ob.status === "invited" ? (
          <>
            <button type="button" className="primary-btn" onClick={() => void run(() => sendInvitation(token, id), acc?.email_confirmed_at ? "Испратен е линк за поставување лозинка." : "Поканата е испратена повторно.")}>{failed ? "Обиди се повторно" : "Испрати повторно"}</button>
            <button type="button" className="danger-btn" disabled={!!acc?.email_confirmed_at} onClick={() => {
              if (window.confirm("Да се откаже поканата? Линкот престанува да важи, а подготвениот бизнис останува.")) void run(() => cancelInvitation(token, id), "Поканата е откажана.");
            }}>Откажи покана</button>
          </>
        ) : null}
        {ob.status === "active" ? <span className="pill pill-ok">Активиран {ob.activated_at ? formatDateTime(ob.activated_at) : ""}</span> : null}
      </div>
    </Panel>
  );
}

function SubscriptionTab({ config }: { config: BusinessConfig }) {
  return (
    <Panel title="Претплата">
      <p>
        Статус: <span className={LIFECYCLE_CLASS[config.lifecycle]}>{LIFECYCLE_LABEL[config.lifecycle]}</span>
        {config.subscription_expires ? ` · важи до ${formatDateTime(config.subscription_expires)}` : ""}
      </p>
      <p className="muted">
        Нацртите немаат претплата и не можат да примаат термини. При активација автоматски започнува стандардниот пробен период од 14 дена.
        Платени пакети, бесплатен пристап, продолжување и историјата се во постоечкиот дел „Претплати“.
      </p>
      <Link className="primary-btn" to="/subscriptions">Отвори Претплати</Link>
    </Panel>
  );
}

const AUDIT_LABEL: Record<string, string> = {
  create_draft_business: "Креиран нацрт",
  open_business_config: "Отворени поставки (администратор)",
  update_business_settings: "Изменети поставки",
  create_service: "Додадена услуга",
  update_service: "Изменета услуга",
  delete_service: "Избришана услуга",
  assign_service_to_all_staff: "Услуга доделена на сите",
  create_staff: "Додаден вработен",
  update_staff: "Изменет вработен",
  delete_staff: "Избришан вработен",
  set_staff_services: "Услуги на вработен",
  set_staff_hours: "Работно време на вработен",
  add_closed_days: "Неработни денови",
  delete_closed_day: "Отстранет неработен ден",
  set_staff_access_scope: "Пристап на вработен",
  issue_staff_code: "Код за вработен",
  revoke_staff_access: "Одземен пристап",
  upload_image: "Прикачена слика",
  send_invitation: "Испратена покана",
  send_invitation_failed: "Неуспешно праќање покана",
  cancel_invitation: "Откажана покана",
  apply_subscription: "Промена на претплата",
  get_business: "Прегледан бизнис",
};

function AuditTab({ businessId, token }: { businessId: string; token: string }) {
  const [rows, setRows] = useState<AuditEntry[] | null>(null);
  useEffect(() => {
    void fetchAudit(token, businessId).then(setRows).catch(() => setRows([]));
  }, [token, businessId]);
  return (
    <Panel title="Историја на администраторски промени">
      {!rows ? <div className="loading">Се вчитува…</div> : rows.length === 0 ? <div className="empty">Нема записи.</div> : (
        <div className="table-wrap">
          <table>
            <thead><tr><th>Време</th><th>Акција</th><th>Администратор</th></tr></thead>
            <tbody>
              {rows.map((r, i) => (
                <tr key={i}>
                  <td data-label="Време">{formatDateTime(r.created_at)}</td>
                  <td data-label="Акција">{AUDIT_LABEL[r.action] || r.action}</td>
                  <td data-label="Администратор">{r.actor || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
}
