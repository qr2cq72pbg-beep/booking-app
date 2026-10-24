import { useEffect, useState } from "react";
import { useAuth } from "../auth/AuthProvider";
import { fetchOverview } from "../lib/adminApi";
import { formatNumber } from "../lib/format";
import type { OverviewMetrics } from "../lib/types";
import { AdminApiError } from "../lib/types";

export function OverviewPage() {
  const { accessToken } = useAuth();
  const [data, setData] = useState<OverviewMetrics | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!accessToken) return;
    let cancelled = false;
    void fetchOverview(accessToken)
      .then((overview) => {
        if (!cancelled) setData(overview);
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof AdminApiError ? err.message || err.code : "Failed to load overview.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken]);

  if (error) return <div className="error-banner">{error}</div>;
  if (!data) return <div className="loading">Loading live platform metrics…</div>;

  const cards = [
    ["Total businesses", data.total_businesses, data.definitions.total_businesses],
    ["Business owners", data.total_business_owners, data.definitions.total_business_owners],
    ["Registered customer accounts", data.unique_registered_customers, data.definitions.unique_registered_customers],
    ["Unique customers linked to businesses", data.unique_customers_linked_to_businesses, data.definitions.unique_customers_linked_to_businesses],
    ["Customer memberships", data.customer_memberships, data.definitions.customer_memberships],
    ["CRM customer records", data.crm_customer_records, data.definitions.crm_customer_records],
    ["Guest CRM records", data.guest_crm_records, data.definitions.guest_crm_records],
    [
      "Total bookings",
      data.bookings_available ? data.total_bookings : null,
      data.bookings_available
        ? data.definitions.total_bookings
        : "Bookings count was not available from the live schema.",
    ],
    [
      "Active access",
      data.subscriptions_available ? data.active_subscriptions : null,
      data.subscriptions_available
        ? data.definitions.active_subscriptions
        : "Apply supabase-platform-subscriptions-v1.sql to show subscription KPIs.",
    ],
    [
      "Paid active",
      data.subscriptions_available ? data.paid_active_subscriptions : null,
      data.subscriptions_available
        ? data.definitions.paid_active_subscriptions
        : "Paid FLEX / PLUS / MAX count appears after the access migration.",
    ],
    [
      "Complimentary",
      data.subscriptions_available ? data.complimentary_subscriptions : null,
      data.subscriptions_available
        ? data.definitions.complimentary_subscriptions
        : "FREE access is not counted as revenue.",
    ],
    [
      "Expired subscriptions",
      data.subscriptions_available ? data.expired_subscriptions : null,
      data.subscriptions_available
        ? data.definitions.expired_subscriptions
        : "No subscription schema yet.",
    ],
    [
      "Unconfigured subscriptions",
      data.subscriptions_available ? data.unconfigured_subscriptions : null,
      data.subscriptions_available
        ? data.definitions.unconfigured_subscriptions
        : "Grandfathered businesses stay unconfigured until you activate them.",
    ],
  ] as const;

  return (
    <div>
      <h1>Overview</h1>
      <p className="lede">
        Live counts from the linked Supabase project. Unique people are not the same as
        memberships or CRM rows. Staff members are never counted as owners.
      </p>
      <div className="stat-grid">
        {cards.map(([label, value, hint]) => (
          <article className="stat-card" key={label}>
            <strong>{formatNumber(value)}</strong>
            <span>{label}</span>
            <em>{hint}</em>
          </article>
        ))}
      </div>
    </div>
  );
}
