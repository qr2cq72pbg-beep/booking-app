import { useEffect, useMemo, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useAuth } from "../auth/AuthProvider";
import { fetchBusiness, fetchBusinessCustomers } from "../lib/adminApi";
import {
  approvalLabel,
  displayOrDash,
  formatCalendarDate,
  formatDate,
  formatDateTime,
  formatExpiration,
  formatNumber,
  identityLabel,
  subscriptionStatusClass,
  subscriptionStatusLabel,
} from "../lib/format";
import type { BusinessCustomer, BusinessDetail } from "../lib/types";
import { AdminApiError } from "../lib/types";

function statusClass(status: string): string {
  const value = status.toLowerCase();
  if (value === "approved") return "pill pill-ok";
  if (value === "pending") return "pill pill-pending";
  if (value === "rejected" || value === "blocked") return "pill pill-danger";
  return "pill pill-navy";
}

export function BusinessDetailPage() {
  const { businessId = "" } = useParams();
  const { accessToken } = useAuth();
  const [business, setBusiness] = useState<BusinessDetail | null>(null);
  const [customers, setCustomers] = useState<BusinessCustomer[] | null>(null);
  const [query, setQuery] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!accessToken || !businessId) return;
    let cancelled = false;
    Promise.all([
      fetchBusiness(accessToken, businessId),
      fetchBusinessCustomers(accessToken, businessId),
    ])
      .then(([detail, list]) => {
        if (cancelled) return;
        setBusiness(detail);
        setCustomers(list);
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof AdminApiError ? err.message || err.code : "Failed to load business.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken, businessId]);

  const filtered = useMemo(() => {
    if (!customers) return [];
    const needle = query.trim().toLowerCase();
    if (!needle) return customers;
    return customers.filter((row) =>
      [row.display_name, row.email, row.phone, String(row.customer_number ?? ""), row.identity_kind]
        .join(" ")
        .toLowerCase()
        .includes(needle),
    );
  }, [customers, query]);

  if (error) {
    return (
      <div>
        <Link to="/businesses">Back to businesses</Link>
        <div className="error-banner" style={{ marginTop: 16 }}>{error}</div>
      </div>
    );
  }
  if (!business || !customers) return <div className="loading">Loading business…</div>;

  const initial = (business.business_name || "B").slice(0, 1).toUpperCase();

  return (
    <div>
      <p className="muted" style={{ marginTop: 0 }}>
        <Link to="/businesses">Businesses</Link> / {business.business_name}
      </p>
      <div className="detail-hero">
        {business.business_logo_url ? (
          <img className="avatar" src={business.business_logo_url} alt="" />
        ) : (
          <div className="avatar">{initial}</div>
        )}
        <div>
          <h1>{business.business_name}</h1>
          <p className="lede" style={{ marginBottom: 0 }}>
            {displayOrDash(business.business_slug)}
            {business.business_category ? ` · ${business.business_category}` : ""}
          </p>
        </div>
      </div>

      <div className="meta-grid">
        <div className="meta-item">
          <span>Owner</span>
          <strong>{displayOrDash(business.owner.display_name)}</strong>
          <div className="muted">{displayOrDash(business.owner.email)}</div>
          <div className="muted">{displayOrDash(business.owner.phone)}</div>
          {!business.owner.profile_present ? (
            <div className="muted">No user_profiles row for this owner account.</div>
          ) : null}
        </div>
        <div className="meta-item">
          <span>Registration date</span>
          <strong>{formatDate(business.owner.registered_at)}</strong>
          <div className="muted">From the owner account profile created_at. business_settings has no verified created_at column in repo SQL.</div>
        </div>
        <div className="meta-item">
          <span>Business contact</span>
          <div>{displayOrDash(business.business_email)}</div>
          <div>{displayOrDash(business.business_phone)}</div>
          <div className="muted">{displayOrDash(business.business_address)}</div>
        </div>
        <div className="meta-item">
          <span>Activity</span>
          <div>{formatNumber(business.customer_counts.crm_records)} CRM records</div>
          <div>{formatNumber(business.customer_counts.linked_members)} registered members</div>
          <div>{formatNumber(business.customer_counts.guest_records)} guest CRM</div>
          <div className="muted">
            Bookings: {business.bookings_available ? formatNumber(business.booking_count) : "unavailable"}
          </div>
        </div>
        <div className="meta-item">
          <span>Subscription</span>
          {business.subscriptions_available === false ? (
            <div className="muted">Subscription schema is not applied yet.</div>
          ) : (
            <>
              <div>
                <span className={subscriptionStatusClass(business.subscription?.status || "unconfigured")}>
                  {subscriptionStatusLabel(business.subscription?.status || "unconfigured")}
                </span>
              </div>
              <div style={{ marginTop: 8 }}>
                {displayOrDash(business.subscription?.package_label)}
                {business.subscription?.access_kind === "complimentary" ||
                business.subscription?.access_kind === "trial"
                  ? " · not revenue"
                  : ""}
              </div>
              <div className="muted">
                {business.subscription?.starts_at
                  ? formatDateTime(business.subscription.starts_at)
                  : formatCalendarDate(business.subscription?.starts_on)}{" "}
                →{" "}
                {business.subscription?.expires_at
                  ? formatDateTime(business.subscription.expires_at)
                  : formatExpiration(
                      business.subscription?.expires_on,
                      business.subscription?.unlimited === true,
                    )}
              </div>
              <div style={{ marginTop: 8 }}>
                <Link to={`/subscriptions?business=${business.business_id}`}>Manage subscription</Link>
              </div>
            </>
          )}
        </div>
      </div>

      <div className="panel">
        <div className="panel-head">
          <h2>Customers at this business</h2>
          <input
            className="search"
            placeholder="Search customers"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        {filtered.length === 0 ? (
          <div className="empty">No customers for this business.</div>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>Name</th>
                  <th>Contact</th>
                  <th>Identity</th>
                  <th>Status</th>
                  <th>First seen</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((row) => (
                  <tr key={row.id}>
                    <td>{row.customer_number != null ? String(row.customer_number).padStart(3, "0") : "—"}</td>
                    <td>{displayOrDash(row.display_name)}</td>
                    <td>
                      <div className="stack-cell">
                        <span>{displayOrDash(row.email)}</span>
                        <span className="muted">{displayOrDash(row.phone)}</span>
                      </div>
                    </td>
                    <td>
                      <span className={row.is_registered_user ? "pill pill-navy" : "pill pill-guest"}>
                        {identityLabel(row.identity_kind, row.is_registered_user)}
                      </span>
                    </td>
                    <td>
                      <span className={statusClass(row.approval_status)}>
                        {approvalLabel(row.approval_status)}
                      </span>
                    </td>
                    <td>{formatDate(row.first_seen_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  );
}
