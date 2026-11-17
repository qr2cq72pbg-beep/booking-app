import { useState, type FormEvent } from "react";
import { createDraftBusiness, errorText, type NewBusinessInput } from "../lib/configApi";
import { CategorySelect } from "./CategorySelect";

function slugify(value: string): string {
  return value
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 60);
}

const EMPTY: NewBusinessInput = {
  business_name: "",
  business_category: "",
  owner_name: "",
  owner_email: "",
  owner_phone: "",
  business_address: "",
  business_slug: "",
  preferred_language: "mk",
};

export function NewBusinessDialog({
  accessToken,
  onClose,
  onCreated,
}: {
  accessToken: string;
  onClose: () => void;
  onCreated: (businessId: string) => void;
}) {
  const [form, setForm] = useState<NewBusinessInput>(EMPTY);
  const [slugTouched, setSlugTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const set = (key: keyof NewBusinessInput, value: string) => {
    setForm((prev) => {
      const next = { ...prev, [key]: value } as NewBusinessInput;
      if (key === "business_name" && !slugTouched) next.business_slug = slugify(value);
      return next;
    });
  };

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (!form.business_name.trim() || !form.owner_name.trim() || !form.owner_email.trim()) {
      setError("Внесете име на бизнисот, име и е-пошта на сопственикот.");
      return;
    }
    if (!form.business_category) {
      setError("Изберете категорија на бизнисот.");
      return;
    }
    if (!/^[a-z0-9](?:[a-z0-9-]{1,58}[a-z0-9])$/.test(form.business_slug)) {
      setError("Кодот на бизнисот: 3–60 мали латинични букви, бројки или цртички.");
      return;
    }
    setBusy(true);
    try {
      const id = await createDraftBusiness(accessToken, form);
      onCreated(id);
    } catch (err) {
      setError(errorText(err));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onClick={onClose}>
      <div className="modal" role="dialog" aria-modal="true" aria-labelledby="new-business-title" onClick={(e) => e.stopPropagation()}>
        <form onSubmit={(e) => void onSubmit(e)}>
          <div className="modal-head">
            <div>
              <h2 id="new-business-title">Нов бизнис</h2>
              <p className="muted" style={{ margin: "4px 0 0" }}>
                Се креира како нацрт. Пробниот период не започнува и не се праќа покана.
              </p>
            </div>
            <button type="button" className="text-btn" onClick={onClose}>Затвори</button>
          </div>
          <div className="modal-body">
            <div className="form-grid">
              <label className="field-label">
                Име на бизнисот *
                <input className="search" value={form.business_name} onChange={(e) => set("business_name", e.target.value)} required maxLength={80} />
              </label>
              <label className="field-label">
                Категорија *
                <CategorySelect value={form.business_category} onChange={(id) => set("business_category", id)} />
              </label>
              <label className="field-label">
                Име и презиме на сопственикот *
                <input className="search" value={form.owner_name} onChange={(e) => set("owner_name", e.target.value)} required maxLength={120} />
              </label>
              <label className="field-label">
                Е-пошта на сопственикот *
                <input className="search" type="email" value={form.owner_email} onChange={(e) => set("owner_email", e.target.value)} required maxLength={120} />
              </label>
              <label className="field-label">
                Телефон за контакт
                <input className="search" type="tel" value={form.owner_phone} onChange={(e) => set("owner_phone", e.target.value)} maxLength={40} />
              </label>
              <label className="field-label">
                Адреса
                <input className="search" value={form.business_address} onChange={(e) => set("business_address", e.target.value)} maxLength={200} />
              </label>
              <label className="field-label">
                Код на бизнисот (линк за закажување) *
                <input
                  className="search"
                  value={form.business_slug}
                  onChange={(e) => {
                    setSlugTouched(true);
                    set("business_slug", slugify(e.target.value));
                  }}
                  required
                  maxLength={60}
                />
              </label>
              <label className="field-label">
                Јазик на поканата
                <select className="search" value={form.preferred_language} onChange={(e) => set("preferred_language", e.target.value)}>
                  <option value="mk">Македонски</option>
                  <option value="en">English</option>
                  <option value="sq">Shqip</option>
                </select>
              </label>
            </div>
            <p className="muted" style={{ margin: 0 }}>
              Логото и насловната слика ги додавате во следниот чекор (Изглед).
            </p>
            {error ? <div className="error-banner">{error}</div> : null}
          </div>
          <div className="modal-actions">
            <button type="button" className="secondary-btn" onClick={onClose}>Откажи</button>
            <button type="submit" className="primary-btn" disabled={busy}>{busy ? "Се креира…" : "Креирај нацрт"}</button>
          </div>
        </form>
      </div>
    </div>
  );
}
