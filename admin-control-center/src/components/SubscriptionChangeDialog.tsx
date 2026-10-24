import { useEffect, useRef, useState, type FormEvent } from "react";
import { applySubscription, previewSubscription } from "../lib/adminApi";
import {
  formatCalendarDate,
  formatDurationMonths,
  formatEur,
  formatSavingsPct,
  operationLabel,
  packageSummary,
  todayIsoDate,
} from "../lib/format";
import type {
  BusinessSubscription,
  SubscriptionOperation,
  SubscriptionPackage,
  SubscriptionPreview,
} from "../lib/types";
import { AdminApiError } from "../lib/types";

type Props = {
  accessToken: string;
  business: BusinessSubscription;
  operation: SubscriptionOperation;
  packages: SubscriptionPackage[];
  onClose: () => void;
  onApplied: (replayed: boolean) => void;
};

export function SubscriptionChangeDialog({
  accessToken,
  business,
  operation,
  packages,
  onClose,
  onApplied,
}: Props) {
  const defaultPackage = packages[0]?.package_id || "";
  const [packageId, setPackageId] = useState(defaultPackage);
  const [startsOn, setStartsOn] = useState(todayIsoDate());
  const [note, setNote] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [preview, setPreview] = useState<SubscriptionPreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const idempotencyRef = useRef<string>(crypto.randomUUID());

  useEffect(() => {
    if (!accessToken || !packageId || !startsOn) return;
    let cancelled = false;
    setPreview(null);
    setPreviewError(null);
    void previewSubscription(accessToken, {
      business_id: business.business_id,
      operation,
      package_id: packageId,
      starts_on: startsOn,
    })
      .then((result) => {
        if (!cancelled) setPreview(result);
      })
      .catch((err) => {
        if (!cancelled) {
          setPreviewError(
            err instanceof AdminApiError ? err.message || err.code : "Could not preview this change.",
          );
        }
      });
    return () => {
      cancelled = true;
    };
  }, [accessToken, business.business_id, operation, packageId, startsOn]);

  const selected = packages.find((pkg) => pkg.package_id === packageId);
  const title = operationLabel(operation);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!confirmed || submitting || !preview) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      const result = await applySubscription(accessToken, {
        business_id: business.business_id,
        operation,
        package_id: packageId,
        starts_on: startsOn,
        idempotency_key: idempotencyRef.current,
        note: note.trim() || undefined,
      });
      onApplied(result.replayed === true);
    } catch (err) {
      setSubmitError(
        err instanceof AdminApiError ? err.message || err.code : "Could not save this subscription.",
      );
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onClick={onClose}>
      <div
        className="modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="subscription-dialog-title"
        onClick={(event) => event.stopPropagation()}
      >
        <form onSubmit={(event) => void onSubmit(event)}>
          <div className="modal-head">
            <div>
              <h2 id="subscription-dialog-title">{title}</h2>
              <p className="muted" style={{ margin: "4px 0 0" }}>
                {business.business_name}
                {business.business_slug ? ` · ${business.business_slug}` : ""}
              </p>
            </div>
            <button type="button" className="text-btn" onClick={onClose}>
              Close
            </button>
          </div>

          <div className="modal-body">
            <p className="notice">
              Every paid plan includes the same XBOOK features. They differ only in price and
              duration. Price and expiration come from the server catalog. Remaining paid access is
              kept when you extend an active FLEX, PLUS, or MAX subscription. Converting from FREE
              replaces complimentary access and does not count previous FREE time as revenue.
              Booking access is not restricted yet.
            </p>

            <fieldset className="package-fieldset">
              <legend>Plan</legend>
              {packages.map((pkg) => {
                const savings = formatSavingsPct(pkg.savings_vs_flex_pct);
                return (
                  <label
                    key={pkg.package_id}
                    className={`package-option ${packageId === pkg.package_id ? "selected" : ""} ${pkg.is_best_value ? "best-value" : ""}`}
                  >
                    <input
                      type="radio"
                      name="package_id"
                      value={pkg.package_id}
                      checked={packageId === pkg.package_id}
                      onChange={() => setPackageId(pkg.package_id)}
                    />
                    <span>
                      <strong>
                        {pkg.label}
                        {pkg.is_best_value ? <span className="best-value-pill">Best Value</span> : null}
                      </strong>
                      <span className="muted">{pkg.description || formatDurationMonths(pkg.access_months)}</span>
                      <span className="muted">
                        {formatDurationMonths(pkg.access_months)}
                        {pkg.effective_monthly_eur != null
                          ? ` · ${formatEur(pkg.effective_monthly_eur)} / month`
                          : ""}
                        {savings ? ` · Save ${savings} versus FLEX` : ""}
                      </span>
                    </span>
                    <em>{formatEur(pkg.price_eur)}</em>
                  </label>
                );
              })}
            </fieldset>

            <label className="field-label">
              Subscription start date
              <input
                type="date"
                className="search"
                value={startsOn}
                onChange={(event) => setStartsOn(event.target.value)}
                required
              />
            </label>
            {operation === "extend" && business.status === "active" ? (
              <p className="muted" style={{ marginTop: -8 }}>
                Start date is stored on the history row. The current start date stays{" "}
                {formatCalendarDate(business.starts_on)} and time is added onto{" "}
                {formatCalendarDate(business.expires_on)}.
              </p>
            ) : null}

            <label className="field-label">
              Internal note (optional)
              <input
                className="search"
                maxLength={500}
                value={note}
                onChange={(event) => setNote(event.target.value)}
                placeholder="Reason, invoice number, or payment reference"
              />
            </label>

            {previewError ? <div className="error-banner">{previewError}</div> : null}
            {!preview && !previewError ? <div className="muted">Calculating expiration…</div> : null}
            {preview ? (
              <div className="preview-card">
                <h3>Confirm these dates</h3>
                <dl className="preview-grid">
                  <div>
                    <dt>Plan</dt>
                    <dd>{packageSummary(preview.package)}</dd>
                  </div>
                  <div>
                    <dt>Price (catalog)</dt>
                    <dd>
                      {formatEur(preview.package.price_eur)}
                      {preview.package.effective_monthly_eur != null
                        ? ` · ${formatEur(preview.package.effective_monthly_eur)} / month`
                        : ""}
                    </dd>
                  </div>
                  <div>
                    <dt>New start</dt>
                    <dd>{formatCalendarDate(preview.new_starts_on)}</dd>
                  </div>
                  <div>
                    <dt>New expiration</dt>
                    <dd>{formatCalendarDate(preview.new_expires_on)}</dd>
                  </div>
                  {preview.previous_expires_on ? (
                    <div>
                      <dt>Previous expiration</dt>
                      <dd>{formatCalendarDate(preview.previous_expires_on)}</dd>
                    </div>
                  ) : null}
                  <div>
                    <dt>Remaining access</dt>
                    <dd>
                      {preview.preserves_remaining_access
                        ? "Kept — months are added to the current expiration"
                        : "None to keep — new period uses the start date"}
                    </dd>
                  </div>
                </dl>
                {preview.resulting_status === "expired" ? (
                  <p className="error-banner" style={{ marginTop: 12 }}>
                    These dates expire on or before today. The row will be saved as expired.
                  </p>
                ) : null}
              </div>
            ) : null}

            <label className="confirm-row">
              <input
                type="checkbox"
                checked={confirmed}
                onChange={(event) => setConfirmed(event.target.checked)}
              />
              I confirm {title.toLowerCase()} for {business.business_name}
              {selected ? ` with ${selected.label}` : ""} at {formatEur(selected?.price_eur ?? null)}.
            </label>

            {submitError ? <div className="error-banner">{submitError}</div> : null}
          </div>

          <div className="modal-actions">
            <button type="button" className="secondary-btn" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className="primary-btn"
              disabled={!confirmed || !preview || submitting}
            >
              {submitting ? "Saving…" : title}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
