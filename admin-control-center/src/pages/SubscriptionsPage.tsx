import { useEffect, useMemo, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { ComplimentaryAccessDialog } from "../components/ComplimentaryAccessDialog";
import { SubscriptionChangeDialog } from "../components/SubscriptionChangeDialog";
import { useAuth } from "../auth/AuthProvider";
import { fetchSubscriptionHistory, fetchSubscriptions } from "../lib/adminApi";
import {
  displayOrDash,
  formatCalendarDate,
  formatDateTime,
  formatDurationMonths,
  formatEur,
  formatExpiration,
  formatNumber,
  formatSavingsPct,
  operationLabel,
  packageSummary,
  subscriptionStatusClass,
  subscriptionStatusLabel,
} from "../lib/format";
import type {
  BusinessSubscription,
  SubscriptionHistoryEntry,
  SubscriptionOperation,
  SubscriptionStatus,
  SubscriptionWorkspace,
} from "../lib/types";
import { AdminApiError } from "../lib/types";

type StatusFilter = "all" | SubscriptionStatus;

export function SubscriptionsPage() {
  const { accessToken } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();
  const [workspace, setWorkspace] = useState<SubscriptionWorkspace | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [historyFor, setHistoryFor] = useState<BusinessSubscription | null>(null);
  const [history, setHistory] = useState<SubscriptionHistoryEntry[] | null>(null);
  const [historyError, setHistoryError] = useState<string | null>(null);
  const [dialog, setDialog] = useState<{
    business: BusinessSubscription;
    operation: Extract<SubscriptionOperation, "activate" | "extend" | "convert_to_paid">;
  } | null>(null);
  const [freeDialog, setFreeDialog] = useState<{
    business: BusinessSubscription;
    operation: Extract<
      SubscriptionOperation,
      | "grant_complimentary"
      | "extend_complimentary"
      | "replace_complimentary"
      | "revoke_complimentary"
      | "convert_to_complimentary"
    >;
  } | null>(null);
  const [flash, setFlash] = useState<string | null>(null);

  function loadWorkspace() {
    if (!accessToken) return;
    return fetchSubscriptions(accessToken)
      .then((data) => {
        setWorkspace(data);
        setError(null);
      })
      .catch((err) => {
        setError(err instanceof AdminApiError ? err.message || err.code : "Failed to load subscriptions.");
      });
  }

  useEffect(() => {
    if (!accessToken) return;
    let cancelled = false;
    void fetchSubscriptions(accessToken)
      .then((data) => {
        if (!cancelled) {
          setWorkspace(data);
          setError(null);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof AdminApiError ? err.message || err.code : "Failed to load subscriptions.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken]);

  useEffect(() => {
    const focusId = searchParams.get("business");
    if (!focusId || !workspace) return;
    const match = workspace.subscriptions.find((row) => row.business_id === focusId);
    if (match) setHistoryFor(match);
  }, [searchParams, workspace]);

  useEffect(() => {
    if (!accessToken || !historyFor) {
      setHistory(null);
      setHistoryError(null);
      return;
    }
    let cancelled = false;
    void fetchSubscriptionHistory(accessToken, historyFor.business_id)
      .then((rows) => {
        if (!cancelled) {
          setHistory(rows);
          setHistoryError(null);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setHistoryError(err instanceof AdminApiError ? err.message || err.code : "Failed to load history.");
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken, historyFor]);

  const rows = useMemo(() => {
    if (!workspace) return [];
    const needle = query.trim().toLowerCase();
    return workspace.subscriptions.filter((row) => {
      if (statusFilter !== "all" && row.status !== statusFilter) return false;
      if (!needle) return true;
      return [row.business_name, row.business_slug, row.package_label, row.status]
        .join(" ")
        .toLowerCase()
        .includes(needle);
    });
  }, [workspace, query, statusFilter]);

  if (error) {
    return (
      <div>
        <h1>Subscriptions</h1>
        <div className="error-banner">{error}</div>
      </div>
    );
  }
  if (!workspace) return <div className="loading">Loading subscriptions…</div>;

  const cards = [
    ["Active access", workspace.summary.active, "Paid or FREE currently valid, including FREE UNTIL CHANGED"],
    ["Paid active", workspace.summary.paid_active ?? 0, "FLEX / PLUS / MAX only — the revenue count"],
    ["Complimentary", workspace.summary.complimentary ?? 0, "Active FREE rows — not revenue"],
    ["Trials", workspace.summary.trial_active ?? 0, "Automatic 7-day trials currently within 168 hours"],
    ["Expired", workspace.summary.expired, "Paid/FREE date is before today, or trial expires_at has passed"],
    ["Unconfigured", workspace.summary.unconfigured, "No entitlement row — not expired"],
    ["Businesses", workspace.summary.total_businesses, "Every business_settings row"],
  ] as const;

  return (
    <div>
      <h1>Subscriptions</h1>
      <p className="lede">
        Manual XBOOK entitlements. FLEX, PLUS, and MAX include the same features and differ only in
        price and duration. FREE is admin-only complimentary access and is never counted as paid
        revenue. Existing businesses without a row are unconfigured, not expired.
      </p>
      <p className="notice" style={{ marginBottom: 18 }}>
        Automatic 7-day trials start when a new business is first created. This screen can inspect
        them and replace them with paid or complimentary access. Booking restrictions are still not
        enforced. Do not change Angel Touch or Test Barber unless that change is explicitly approved.
      </p>
      {flash ? <div className="ok-banner">{flash}</div> : null}

      {workspace.packages.length > 0 ? (
        <div className="plan-grid">
          {workspace.packages.map((pkg) => {
            const savings = formatSavingsPct(pkg.savings_vs_flex_pct);
            return (
              <article
                key={pkg.package_id}
                className={`plan-card ${pkg.is_best_value ? "best-value" : ""}`}
              >
                <div className="plan-card-head">
                  <h3>{pkg.label}</h3>
                  {pkg.is_best_value ? <span className="best-value-pill">Best Value</span> : null}
                </div>
                <strong>{formatEur(pkg.price_eur)}</strong>
                <span>{formatDurationMonths(pkg.access_months)}</span>
                {pkg.effective_monthly_eur != null ? (
                  <span className="muted">{formatEur(pkg.effective_monthly_eur)} / month</span>
                ) : null}
                {savings ? <span className="muted">Save {savings} versus FLEX</span> : null}
                <p>{pkg.description || "Same XBOOK features as every other plan."}</p>
              </article>
            );
          })}
        </div>
      ) : null}

      <article className="plan-card complimentary-card" style={{ marginBottom: 22 }}>
        <div className="plan-card-head">
          <h3>FREE access</h3>
          <span className="pill pill-navy">Admin only</span>
        </div>
        <strong>Not revenue</strong>
        <span>FREE UNTIL CHANGED or FREE until a selected date</span>
        <p>
          Complimentary access is granted, replaced, revoked, or converted here. It is not a public
          package. Angel Touch is intended for FREE UNTIL CHANGED after a separate approval. Test
          Barber stays available for paid tests.
        </p>
      </article>

      <div className="stat-grid">
        {cards.map(([label, value, hint]) => (
          <article className="stat-card" key={label}>
            <strong>{formatNumber(value)}</strong>
            <span>{label}</span>
            <em>{hint}</em>
          </article>
        ))}
      </div>
      <p className="muted" style={{ marginTop: -8, marginBottom: 18 }}>
        Dates as of {formatCalendarDate(workspace.as_of_date)} (UTC calendar date).
      </p>

      <div className="panel">
        <div className="panel-head">
          <h2>{rows.length} businesses</h2>
          <div className="toolbar">
            <div className="filter-pills">
              {(["all", "active", "expired", "unconfigured"] as const).map((value) => (
                <button
                  key={value}
                  type="button"
                  className={`filter-pill ${statusFilter === value ? "active" : ""}`}
                  onClick={() => setStatusFilter(value)}
                >
                  {value === "all" ? "All" : subscriptionStatusLabel(value)}
                </button>
              ))}
            </div>
            <input
              className="search"
              placeholder="Search business or package"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>
        </div>
        {rows.length === 0 ? (
          <div className="empty">No businesses match this filter.</div>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Business</th>
                  <th>Package</th>
                  <th>Status</th>
                  <th>Start</th>
                  <th>Expiration</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => (
                  <tr key={row.business_id}>
                    <td>
                      <div className="stack-cell">
                        <Link to={`/businesses/${row.business_id}`}>{row.business_name}</Link>
                        <span className="muted">{displayOrDash(row.business_slug)}</span>
                      </div>
                    </td>
                    <td>
                      {row.package_label ? (
                        <div className="stack-cell">
                          <span>{row.package_label}</span>
                          <span className="muted">
                            {row.access_kind === "complimentary" || row.access_kind === "trial"
                              ? "Not revenue"
                              : `${formatDurationMonths(row.access_months)} · ${formatEur(row.price_eur)}`}
                          </span>
                        </div>
                      ) : (
                        <span className="muted">None</span>
                      )}
                    </td>
                    <td>
                      <span className={subscriptionStatusClass(row.status)}>
                        {subscriptionStatusLabel(row.status)}
                      </span>
                      {row.access_kind === "complimentary" && row.status === "active" ? (
                        <div className="muted" style={{ marginTop: 6 }}>Complimentary</div>
                      ) : null}
                      {row.access_kind === "trial" ? (
                        <div className="muted" style={{ marginTop: 6 }}>Automatic trial</div>
                      ) : null}
                      {row.starts_in_future ? (
                        <div className="muted" style={{ marginTop: 6 }}>Starts later</div>
                      ) : null}
                    </td>
                    <td>
                      {row.starts_at ? formatDateTime(row.starts_at) : formatCalendarDate(row.starts_on)}
                    </td>
                    <td>
                      {row.expires_at
                        ? formatDateTime(row.expires_at)
                        : formatExpiration(row.expires_on, row.unlimited === true)}
                    </td>
                    <td>
                      <div className="row-actions">
                        {row.status === "active" && row.access_kind === "paid" ? (
                          <button
                            type="button"
                            className="secondary-btn compact"
                            onClick={() => setDialog({ business: row, operation: "extend" })}
                          >
                            Extend
                          </button>
                        ) : null}
                        {row.status !== "active" || row.access_kind === "trial" ? (
                          <button
                            type="button"
                            className="primary-btn compact"
                            onClick={() => setDialog({ business: row, operation: "activate" })}
                          >
                            Activate
                          </button>
                        ) : null}
                        {row.access_kind === "complimentary" && row.status === "active" ? (
                          <>
                            {row.unlimited ? null : (
                              <button
                                type="button"
                                className="secondary-btn compact"
                                onClick={() => setFreeDialog({ business: row, operation: "extend_complimentary" })}
                              >
                                Extend FREE
                              </button>
                            )}
                            <button
                              type="button"
                              className="secondary-btn compact"
                              onClick={() => setFreeDialog({ business: row, operation: "replace_complimentary" })}
                            >
                              Replace FREE
                            </button>
                            <button
                              type="button"
                              className="primary-btn compact"
                              onClick={() => setDialog({ business: row, operation: "convert_to_paid" })}
                            >
                              Convert to paid
                            </button>
                            <button
                              type="button"
                              className="text-btn compact"
                              onClick={() => setFreeDialog({ business: row, operation: "revoke_complimentary" })}
                            >
                              Revoke FREE
                            </button>
                          </>
                        ) : (
                          <button
                            type="button"
                            className="secondary-btn compact"
                            onClick={() =>
                              setFreeDialog({
                                business: row,
                                operation: row.access_kind === "paid"
                                  ? "convert_to_complimentary"
                                  : "grant_complimentary",
                              })
                            }
                          >
                            {row.access_kind === "paid" ? "Convert to FREE" : "Grant FREE"}
                          </button>
                        )}
                        <button
                          type="button"
                          className="text-btn compact"
                          onClick={() => {
                            setHistoryFor(row);
                            setSearchParams({ business: row.business_id });
                          }}
                        >
                          History
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {historyFor ? (
        <div className="panel" style={{ marginTop: 18 }}>
          <div className="panel-head">
            <h2>History · {historyFor.business_name}</h2>
            <button
              type="button"
              className="text-btn"
              onClick={() => {
                setHistoryFor(null);
                setSearchParams({});
              }}
            >
              Close
            </button>
          </div>
          {historyError ? <div className="error-banner" style={{ margin: 16 }}>{historyError}</div> : null}
          {!history && !historyError ? <div className="loading">Loading history…</div> : null}
          {history && history.length === 0 ? (
            <div className="empty">No subscription changes have been recorded for this business.</div>
          ) : null}
          {history && history.length > 0 ? (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>When</th>
                    <th>Action</th>
                    <th>Package</th>
                    <th>Dates</th>
                    <th>Administrator</th>
                  </tr>
                </thead>
                <tbody>
                  {history.map((entry) => (
                    <tr key={entry.id}>
                      <td>{formatDateTime(entry.created_at)}</td>
                      <td>{operationLabel(entry.operation)}</td>
                      <td>
                        <div className="stack-cell">
                          <span>{packageSummary(entry)}</span>
                          <span className="muted">
                            {entry.access_kind === "complimentary" || entry.access_kind === "trial"
                              ? "Not revenue"
                              : formatEur(entry.price_eur)}
                          </span>
                        </div>
                      </td>
                      <td>
                        <div className="stack-cell">
                          <span>
                            {entry.new_starts_at || entry.new_expires_at
                              ? `${entry.new_starts_at ? formatDateTime(entry.new_starts_at) : formatCalendarDate(entry.new_starts_on)} → ${entry.new_expires_at ? formatDateTime(entry.new_expires_at) : formatExpiration(entry.new_expires_on, false)}`
                              : `${formatCalendarDate(entry.new_starts_on)} → ${formatExpiration(
                                  entry.new_expires_on,
                                  entry.access_kind === "complimentary" && !entry.new_expires_on,
                                )}`}
                          </span>
                          {entry.previous_expires_on ? (
                            <span className="muted">
                              Was {formatCalendarDate(entry.previous_expires_on)}
                            </span>
                          ) : (
                            <span className="muted">First grant</span>
                          )}
                          {entry.note ? <span className="muted">{entry.note}</span> : null}
                        </div>
                      </td>
                      <td>{displayOrDash(entry.actor_email)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : null}
        </div>
      ) : null}

      {dialog && accessToken ? (
        <SubscriptionChangeDialog
          accessToken={accessToken}
          business={dialog.business}
          operation={dialog.operation}
          packages={workspace.packages}
          onClose={() => setDialog(null)}
          onApplied={(replayed) => {
            const verb = operationLabel(dialog.operation).toLowerCase();
            setFlash(
              replayed
                ? `${dialog.business.business_name} already recorded this ${verb} request. No extra change was applied.`
                : `${dialog.business.business_name}: ${operationLabel(dialog.operation)} saved.`,
            );
            setDialog(null);
            void loadWorkspace();
            if (historyFor?.business_id === dialog.business.business_id) {
              setHistoryFor({ ...historyFor });
            }
          }}
        />
      ) : null}

      {freeDialog && accessToken ? (
        <ComplimentaryAccessDialog
          accessToken={accessToken}
          business={freeDialog.business}
          operation={freeDialog.operation}
          onClose={() => setFreeDialog(null)}
          onApplied={(replayed) => {
            setFlash(
              replayed
                ? `${freeDialog.business.business_name} already recorded this FREE request. No extra change was applied.`
                : `${freeDialog.business.business_name}: ${operationLabel(freeDialog.operation)} saved.`,
            );
            setFreeDialog(null);
            void loadWorkspace();
            if (historyFor?.business_id === freeDialog.business.business_id) {
              setHistoryFor({ ...historyFor });
            }
          }}
        />
      ) : null}
    </div>
  );
}
