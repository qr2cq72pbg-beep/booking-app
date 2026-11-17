import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";
import { NewBusinessDialog } from "../components/NewBusinessDialog";
import { fetchBusinesses } from "../lib/adminApi";
import { LIFECYCLE_CLASS, LIFECYCLE_LABEL, type Lifecycle } from "../lib/configApi";
import { displayOrDash, formatDate, formatNumber } from "../lib/format";
import type { BusinessListItem } from "../lib/types";
import { AdminApiError } from "../lib/types";

const FILTERS: Array<[Lifecycle | "all", string]> = [
  ["all", "Сите"],
  ["draft", "Нацрти"],
  ["invited", "Поканети"],
  ["trial", "Пробен период"],
  ["active", "Активни"],
  ["expired", "Истечени"],
  ["unconfigured", "Без претплата"],
];

export function BusinessesPage() {
  const { accessToken } = useAuth();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [rows, setRows] = useState<BusinessListItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Lifecycle | "all">("all");
  const [creating, setCreating] = useState(false);

  useEffect(() => {
    const handle = window.setTimeout(() => setDebounced(query.trim()), 250);
    return () => window.clearTimeout(handle);
  }, [query]);

  useEffect(() => {
    if (!accessToken) return;
    let cancelled = false;
    void fetchBusinesses(accessToken, debounced)
      .then((list) => {
        if (!cancelled) {
          setRows(list);
          setError(null);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof AdminApiError ? err.message || err.code : "Бизнисите не може да се вчитаат.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken, debounced]);

  const counts = useMemo(() => {
    const c: Record<string, number> = { all: rows?.length || 0 };
    for (const r of rows || []) c[r.lifecycle || "unconfigured"] = (c[r.lifecycle || "unconfigured"] || 0) + 1;
    return c;
  }, [rows]);
  const visible = (rows || []).filter((r) => filter === "all" || (r.lifecycle || "unconfigured") === filter);

  return (
    <div>
      <div className="page-head">
        <div>
          <h1>Бизниси</h1>
          <p className="lede">
            Сите бизниси на платформата. Нов бизнис се креира како нацрт: го подготвувате, па му праќате покана на сопственикот.
          </p>
        </div>
        <button type="button" className="primary-btn" onClick={() => setCreating(true)}>+ Нов бизнис</button>
      </div>
      <div className="filter-pills" role="tablist" aria-label="Статус">
        {FILTERS.map(([key, label]) => (
          <button key={key} type="button" className={`filter-pill ${filter === key ? "active" : ""}`} onClick={() => setFilter(key)}>
            {label} <span className="muted">{counts[key] || 0}</span>
          </button>
        ))}
      </div>
      <div className="panel">
        <div className="panel-head">
          <h2>{rows ? `${visible.length} бизниси` : "Бизниси"}</h2>
          <input
            className="search"
            placeholder="Барај име, код, сопственик, е-пошта"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        {error ? <div className="error-banner" style={{ margin: 16 }}>{error}</div> : null}
        {!rows && !error ? <div className="loading">Се вчитуваат бизнисите…</div> : null}
        {rows && visible.length === 0 ? <div className="empty">Нема бизниси за овој филтер.</div> : null}
        {rows && visible.length > 0 ? (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Бизнис</th>
                  <th>Статус</th>
                  <th>Сопственик</th>
                  <th>Тим</th>
                  <th>Клиенти</th>
                  <th>Последен термин</th>
                </tr>
              </thead>
              <tbody>
                {visible.map((row) => {
                  const lc = (row.lifecycle || "unconfigured") as Lifecycle;
                  return (
                    <tr key={row.business_id} className="clickable" onClick={() => navigate(`/businesses/${row.business_id}`)}>
                      <td data-label="Бизнис">
                        <div className="stack-cell">
                          <strong>{row.business_name}</strong>
                          <span className="muted">{displayOrDash(row.business_slug)}</span>
                        </div>
                      </td>
                      <td data-label="Статус">
                        <div className="stack-cell">
                          <span className={LIFECYCLE_CLASS[lc]}>{LIFECYCLE_LABEL[lc]}</span>
                          {row.subscription_expires ? <span className="muted">до {formatDate(row.subscription_expires)}</span> : null}
                        </div>
                      </td>
                      <td data-label="Сопственик">
                        <div className="stack-cell">
                          <span>{displayOrDash(row.owner.display_name)}</span>
                          <span className="muted">{displayOrDash(row.owner.email)}</span>
                        </div>
                      </td>
                      <td data-label="Тим">
                        <div className="stack-cell">
                          <span>{formatNumber(row.staff_count ?? null)} вработени</span>
                          <span className="muted">{formatNumber(row.service_count ?? null)} услуги</span>
                        </div>
                      </td>
                      <td data-label="Клиенти">
                        <div className="stack-cell">
                          <span>{formatNumber(row.customer_counts.crm_records)} клиенти</span>
                          <span className="muted">{formatNumber(row.bookings_total ?? null)} термини</span>
                        </div>
                      </td>
                      <td data-label="Последен термин">{row.last_booking_at ? formatDate(row.last_booking_at) : "—"}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : null}
      </div>
      {creating && accessToken ? (
        <NewBusinessDialog
          accessToken={accessToken}
          onClose={() => setCreating(false)}
          onCreated={(id) => navigate(`/businesses/${id}/configure`)}
        />
      ) : null}
    </div>
  );
}
