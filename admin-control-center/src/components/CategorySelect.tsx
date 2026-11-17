import { BUSINESS_CATEGORIES, categoryLabel, isSelectableCategory, normalizeCategoryId } from "../lib/configApi";

/** Business type dropdown with the app's categories. An older, no longer offered value stays visible and selected. */
export function CategorySelect({ value, onChange, id }: { value: string | null | undefined; onChange: (id: string) => void; id?: string }) {
  const current = normalizeCategoryId(value);
  const keepCurrent = current && !isSelectableCategory(current);
  return (
    <select id={id} className="search" required value={keepCurrent ? String(value) : current} onChange={(e) => onChange(e.target.value)}>
      <option value="" disabled>Изберете тип на бизнис</option>
      {keepCurrent ? <option value={String(value)}>{categoryLabel(value)} (постоечка)</option> : null}
      {BUSINESS_CATEGORIES.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
    </select>
  );
}
