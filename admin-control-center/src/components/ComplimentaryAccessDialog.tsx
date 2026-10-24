import { useEffect, useRef, useState, type FormEvent } from "react";
import { applySubscription, previewSubscription } from "../lib/adminApi";
import {
  formatCalendarDate,
  formatExpiration,
  operationLabel,
  todayIsoDate,
} from "../lib/format";
import type {
  BusinessSubscription,
  SubscriptionOperation,
  SubscriptionPreview,
} from "../lib/types";
import { AdminApiError } from "../lib/types";

type ComplimentaryOperation = Extract<
  SubscriptionOperation,
  | "grant_complimentary"
  | "extend_complimentary"
  | "replace_complimentary"
  | "revoke_complimentary"
  | "convert_to_complimentary"
>;

type Props = {
  accessToken: string;
  business: BusinessSubscription;
  operation: ComplimentaryOperation;
  onClose: () => void;
  onApplied: (replayed: boolean) => void;
};

export function ComplimentaryAccessDialog({
  accessToken,
  business,
  operation,
  onClose,
  onApplied,
}: Props) {
  const untilChangedDefault =
    operation === "grant_complimentary" ||
    operation === "replace_complimentary" ||
    operation === "convert_to_complimentary";
  const [untilChanged, setUntilChanged] = useState(untilChangedDefault);
  const [startsOn, setStartsOn] = useState(business.starts_on || todayIsoDate());
  const [expiresOn, setExpiresOn] = useState(business.expires_on || todayIsoDate());
  const [note, setNote] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [preview, setPreview] = useState<SubscriptionPreview | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const idempotencyRef = useRef<string>(crypto.randomUUID());
  const title = operationLabel(operation);
  const needsDates = operation !== "revoke_complimentary";
  const needsStart =
    operation === "grant_complimentary" ||
    operation === "replace_complimentary" ||
    operation === "convert_to_complimentary";

  useEffect(() => {
    if (!accessToken) return;
    let cancelled = false;
    setPreview(null);
    setPreviewError(null);
    const payload: {
      business_id: string;
      operation: ComplimentaryOperation;
      starts_on?: string | null;
      expires_on?: string | null;
    } = {
      business_id: business.business_id,
      operation,
    };
    if (needsStart) payload.starts_on = startsOn;
    if (operation === "extend_complimentary") payload.expires_on = expiresOn;
    if (
      operation === "grant_complimentary" ||
      operation === "replace_complimentary" ||
      operation === "convert_to_complimentary"
    ) {
      payload.expires_on = untilChanged ? null : expiresOn;
    }
    void previewSubscription(accessToken, payload)
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
  }, [accessToken, business.business_id, expiresOn, needsStart, operation, startsOn, untilChanged]);

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    if (!confirmed || submitting || !preview) return;
    setSubmitting(true);
    setSubmitError(null);
    try {
      const result = await applySubscription(accessToken, {
        business_id: business.business_id,
        operation,
        starts_on: needsStart ? startsOn : undefined,
        expires_on:
          operation === "revoke_complimentary"
            ? null
            : operation === "extend_complimentary"
              ? expiresOn
              : untilChanged
                ? null
                : expiresOn,
        idempotency_key: idempotencyRef.current,
        note: note.trim() || undefined,
      });
      onApplied(result.replayed === true);
    } catch (err) {
      setSubmitError(
        err instanceof AdminApiError ? err.message || err.code : "Could not save complimentary access.",
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
        aria-labelledby="complimentary-dialog-title"
        onClick={(event) => event.stopPropagation()}
      >
        <form onSubmit={(event) => void onSubmit(event)}>
          <div className="modal-head">
            <div>
              <h2 id="complimentary-dialog-title">{title}</h2>
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
              FREE is an admin-only access type. It is not a public package and never counts as paid
              revenue. Booking restrictions are not enabled yet.
            </p>

            {needsDates ? (
              <>
                {needsStart ? (
                  <label className="field-label">
                    Access start date
                    <input
                      type="date"
                      className="search"
                      value={startsOn}
                      onChange={(event) => setStartsOn(event.target.value)}
                      required
                    />
                  </label>
                ) : null}

                {operation === "extend_complimentary" ? (
                  <label className="field-label">
                    New FREE end date
                    <input
                      type="date"
                      className="search"
                      value={expiresOn}
                      onChange={(event) => setExpiresOn(event.target.value)}
                      required
                    />
                  </label>
                ) : (
                  <fieldset className="package-fieldset">
                    <legend>FREE duration</legend>
                    <label className={`package-option ${untilChanged ? "selected" : ""}`}>
                      <input
                        type="radio"
                        name="free_mode"
                        checked={untilChanged}
                        onChange={() => setUntilChanged(true)}
                      />
                      <span>
                        <strong>FREE UNTIL CHANGED</strong>
                        <span className="muted">No expiration. Revoke or convert later to change this.</span>
                      </span>
                    </label>
                    <label className={`package-option ${!untilChanged ? "selected" : ""}`}>
                      <input
                        type="radio"
                        name="free_mode"
                        checked={!untilChanged}
                        onChange={() => setUntilChanged(false)}
                      />
                      <span>
                        <strong>FREE until a date</strong>
                        <span className="muted">Inclusive UTC calendar date. Access stays valid on that day.</span>
                      </span>
                    </label>
                  </fieldset>
                )}

                {!untilChanged && operation !== "extend_complimentary" ? (
                  <label className="field-label">
                    FREE end date
                    <input
                      type="date"
                      className="search"
                      value={expiresOn}
                      onChange={(event) => setExpiresOn(event.target.value)}
                      required
                    />
                  </label>
                ) : null}
              </>
            ) : null}

            {operation === "revoke_complimentary" ? (
              <p className="notice">
                Revoking marks complimentary access as expired. Existing bookings and business data
                stay. New booking restrictions are not enabled in this phase.
              </p>
            ) : null}

            <label className="field-label">
              Internal note (optional)
              <input
                className="search"
                maxLength={500}
                value={note}
                onChange={(event) => setNote(event.target.value)}
                placeholder="Reason for complimentary access"
              />
            </label>

            {previewError ? <div className="error-banner">{previewError}</div> : null}
            {!preview && !previewError ? <div className="muted">Calculating access…</div> : null}
            {preview ? (
              <div className="preview-card">
                <h3>Confirm this FREE access</h3>
                <dl className="preview-grid">
                  <div>
                    <dt>Access</dt>
                    <dd>{preview.package.label}</dd>
                  </div>
                  <div>
                    <dt>Revenue</dt>
                    <dd>{preview.is_revenue ? "Paid" : "Not counted as revenue"}</dd>
                  </div>
                  <div>
                    <dt>New start</dt>
                    <dd>{formatCalendarDate(preview.new_starts_on)}</dd>
                  </div>
                  <div>
                    <dt>New expiration</dt>
                    <dd>{formatExpiration(preview.new_expires_on, preview.unlimited === true)}</dd>
                  </div>
                </dl>
              </div>
            ) : null}

            <label className="confirm-row">
              <input
                type="checkbox"
                checked={confirmed}
                onChange={(event) => setConfirmed(event.target.checked)}
              />
              I confirm {title.toLowerCase()} for {business.business_name}. This is not a paid
              subscription.
            </label>

            {submitError ? <div className="error-banner">{submitError}</div> : null}
          </div>

          <div className="modal-actions">
            <button type="button" className="secondary-btn" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              className={operation === "revoke_complimentary" ? "danger-btn" : "primary-btn"}
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
