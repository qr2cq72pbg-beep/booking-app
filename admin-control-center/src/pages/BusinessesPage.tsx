import { useEffect, useState } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";
import { fetchBusinesses } from "../lib/adminApi";
import { displayOrDash, formatDate, formatNumber } from "../lib/format";
import type { BusinessListItem } from "../lib/types";
import { AdminApiError } from "../lib/types";

export function BusinessesPage() {
  const { accessToken } = useAuth();
  const navigate = useNavigate();
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");
  const [rows, setRows] = useState<BusinessListItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);

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
          setError(err instanceof AdminApiError ? err.message || err.code : "Failed to load businesses.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken, debounced]);

  return (
    <div>
      <h1>Businesses</h1>
      <p className="lede">
        Every registered business. Owner identity comes from the owner account profile when one
        exists. Customer counts are per-business CRM records, not global unique users.
      </p>
      <div className="panel">
        <div className="panel-head">
          <h2>{rows ? `${rows.length} businesses` : "Businesses"}</h2>
          <input
            className="search"
            placeholder="Search name, slug, owner, email"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        {error ? <div className="error-banner" style={{ margin: 16 }}>{error}</div> : null}
        {!rows && !error ? <div className="loading">Loading businesses…</div> : null}
        {rows && rows.length === 0 ? <div className="empty">No businesses match this search.</div> : null}
        {rows && rows.length > 0 ? (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Business</th>
                  <th>Owner</th>
                  <th>Registered</th>
                  <th>Customers</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr
                    key={row.business_id}
                    className="clickable"
                    onClick={() => navigate(`/businesses/${row.business_id}`)}
                  >
                    <td>
                      <div className="stack-cell">
                        <strong>{row.business_name}</strong>
                        <span className="muted">{displayOrDash(row.business_slug)}</span>
                      </div>
                    </td>
                    <td>
                      <div className="stack-cell">
                        <span>{displayOrDash(row.owner.display_name)}</span>
                        <span className="muted">{displayOrDash(row.owner.email)}</span>
                        <span className="muted">{displayOrDash(row.owner.phone)}</span>
                      </div>
                    </td>
                    <td>{formatDate(row.owner.registered_at)}</td>
                    <td>
                      <div className="stack-cell">
                        <span>{formatNumber(row.customer_counts.crm_records)} CRM</span>
                        <span className="muted">
                          {formatNumber(row.customer_counts.linked_members)} registered · {formatNumber(row.customer_counts.guest_records)} guest
                        </span>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : null}
      </div>
    </div>
  );
}
