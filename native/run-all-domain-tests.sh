#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Registration guard (Phase 10 final review I3): every native/run-*-tests.sh
# runner must be invoked below, or this aggregate fails before running
# anything. A runner only counts when an uncommented line invokes it.
# Helpers that are not runners (run-appstore-sources-common.sh,
# run-import-tests-common.sh, run-doc-reference-check.sh and the
# run-phase-N-device-preflight.sh wrappers) do not match *-tests.sh.
AGGREGATE="$ROOT_DIR/native/run-all-domain-tests.sh"
UNREGISTERED=""
for RUNNER in "$ROOT_DIR"/native/run-*-tests.sh; do
  NAME=$(basename "$RUNNER")
  [ "$NAME" = "run-all-domain-tests.sh" ] && continue
  if ! grep -Eq "^[[:space:]]*(sh[[:space:]]+)?\"\\\$ROOT_DIR/native/$NAME\"" "$AGGREGATE"; then
    UNREGISTERED="$UNREGISTERED $NAME"
  fi
done
if [ -n "$UNREGISTERED" ]; then
  echo "run-all-domain-tests.sh: unregistered runner(s):$UNREGISTERED" >&2
  echo "Register each one below (or rename a non-runner helper so it does not end in -tests.sh)." >&2
  exit 1
fi

"$ROOT_DIR/native/run-domain-tests.sh"
sh "$ROOT_DIR/native/run-canonical-tests.sh"
"$ROOT_DIR/native/run-snapshot-tests.sh"
"$ROOT_DIR/native/run-repository-tests.sh"
"$ROOT_DIR/native/run-money-card-tests.sh"
"$ROOT_DIR/native/run-expense-editor-tests.sh"
"$ROOT_DIR/native/run-mileage-log-tests.sh"
"$ROOT_DIR/native/run-pricebook-ui-tests.sh"
"$ROOT_DIR/native/run-export-import-ui-tests.sh"
"$ROOT_DIR/native/run-phase9-qualification-tests.sh"
"$ROOT_DIR/native/run-legacy-import-tests.sh"
"$ROOT_DIR/native/run-migration-coordinator-tests.sh"
"$ROOT_DIR/native/run-auxiliary-activation-tests.sh"
"$ROOT_DIR/native/run-authenticated-identity-tests.sh"
"$ROOT_DIR/native/run-build-environment-tests.sh"
"$ROOT_DIR/native/run-supabase-auth-tests.sh"
"$ROOT_DIR/native/run-initial-sync-tests.sh"
"$ROOT_DIR/native/run-delta-sync-tests.sh"
"$ROOT_DIR/native/run-mutation-queue-tests.sh"
sh "$ROOT_DIR/native/run-record-deletion-tests.sh"
"$ROOT_DIR/native/run-mutation-push-tests.sh"
"$ROOT_DIR/native/run-sync-coordinator-tests.sh"
sh "$ROOT_DIR/native/run-background-refresh-tests.sh"
sh "$ROOT_DIR/native/run-job-photo-transfer-tests.sh"
"$ROOT_DIR/native/run-two-device-convergence-tests.sh"
"$ROOT_DIR/native/run-sync-backfill-tests.sh"
"$ROOT_DIR/native/run-subscription-tests.sh"
"$ROOT_DIR/native/run-account-deletion-tests.sh"
"$ROOT_DIR/native/run-typed-account-state-tests.sh"
"$ROOT_DIR/native/run-app-group-pending-open-url-tests.sh"
"$ROOT_DIR/native/run-widget-snapshot-tests.sh"
sh "$ROOT_DIR/native/run-app-intent-queue-tests.sh"
  "$ROOT_DIR/native/run-appointment-messaging-tests.sh"
  "$ROOT_DIR/native/run-appointment-notification-tests.sh"
sh "$ROOT_DIR/native/run-estimate-approval-link-tests.sh"
sh "$ROOT_DIR/native/run-estimate-pdf-tests.sh"
sh "$ROOT_DIR/native/run-estimate-delivery-tests.sh"
sh "$ROOT_DIR/native/run-estimate-message-draft-tests.sh"
sh "$ROOT_DIR/native/run-estimate-follow-up-tests.sh"
sh "$ROOT_DIR/native/run-estimate-follow-up-notification-tests.sh"
sh "$ROOT_DIR/native/run-review-request-tests.sh"
sh "$ROOT_DIR/native/run-change-order-tests.sh"
sh "$ROOT_DIR/native/run-job-profitability-tests.sh"
sh "$ROOT_DIR/native/run-change-order-approval-link-tests.sh"
sh "$ROOT_DIR/native/run-customer-contact-action-tests.sh"
"$ROOT_DIR/native/run-widget-action-replay-tests.sh"
"$ROOT_DIR/native/run-business-rules-tests.sh"
"$ROOT_DIR/native/run-recurring-job-tests.sh"
"$ROOT_DIR/native/run-adapter-tests.sh"
"$ROOT_DIR/native/run-customer-identity-tests.sh"
sh "$ROOT_DIR/native/run-address-lookup-tests.sh"
sh "$ROOT_DIR/native/run-global-search-tests.sh"
sh "$ROOT_DIR/native/run-interaction-state-tests.sh"
sh "$ROOT_DIR/native/run-job-list-tests.sh"
sh "$ROOT_DIR/native/run-invoice-list-tests.sh"
sh "$ROOT_DIR/native/run-invoice-editing-tests.sh"
sh "$ROOT_DIR/native/run-payment-link-tests.sh"
sh "$ROOT_DIR/native/run-stripe-connect-tests.sh"
sh "$ROOT_DIR/native/run-invoice-pdf-tests.sh"
sh "$ROOT_DIR/native/run-outreach-tests.sh"
sh "$ROOT_DIR/native/run-bulk-invoice-tests.sh"
sh "$ROOT_DIR/native/run-recurring-invoice-tests.sh"
sh "$ROOT_DIR/native/run-invoice-notification-tests.sh"
"$ROOT_DIR/native/run-invoice-from-job-tests.sh"
sh "$ROOT_DIR/native/run-invoice-delivery-tests.sh"
sh "$ROOT_DIR/native/run-time-tracking-tests.sh"
sh "$ROOT_DIR/native/run-confirmation-tests.sh"
"$ROOT_DIR/native/run-store-integration-tests.sh"
sh "$ROOT_DIR/native/run-today-insights-tests.sh"
sh "$ROOT_DIR/native/run-today-briefing-tests.sh"
sh "$ROOT_DIR/native/run-coach-transport-tests.sh"
sh "$ROOT_DIR/native/run-coach-prompt-tests.sh"
sh "$ROOT_DIR/native/run-chat-markdown-tests.sh"
sh "$ROOT_DIR/native/run-notification-permission-tests.sh"
sh "$ROOT_DIR/native/run-phase10-qualification-tests.sh"
# Phase 10 final review I3: 10.01/10.03 suites, the notification coordinator
# (60-cap / foreign-family / cleanup) and the two AppStore-closure runners.
sh "$ROOT_DIR/native/run-business-snapshot-tests.sh"
sh "$ROOT_DIR/native/run-insight-mute-tests.sh"
sh "$ROOT_DIR/native/run-setup-checklist-tests.sh"
sh "$ROOT_DIR/native/run-notification-coordinator-tests.sh"
sh "$ROOT_DIR/native/run-schedule-booking-settings-tests.sh"
sh "$ROOT_DIR/native/run-calendar-editor-tests.sh"
# Pre-existing runners found unregistered by the guard above (all passing
# when registered in the Phase 10 final fix wave).
sh "$ROOT_DIR/native/run-accounting-package-tests.sh"
sh "$ROOT_DIR/native/run-availability-tests.sh"
sh "$ROOT_DIR/native/run-booking-administration-tests.sh"
sh "$ROOT_DIR/native/run-booking-attention-tests.sh"
sh "$ROOT_DIR/native/run-booking-intake-tests.sh"
sh "$ROOT_DIR/native/run-booking-response-tests.sh"
sh "$ROOT_DIR/native/run-calendar-tests.sh"
sh "$ROOT_DIR/native/run-csv-export-tests.sh"
sh "$ROOT_DIR/native/run-csv-import-tests.sh"
sh "$ROOT_DIR/native/run-import-engine-tests.sh"
sh "$ROOT_DIR/native/run-import-history-tests.sh"
sh "$ROOT_DIR/native/run-import-mapping-tests.sh"
sh "$ROOT_DIR/native/run-job-photo-mutation-tests.sh"
sh "$ROOT_DIR/native/run-mileage-tests.sh"
sh "$ROOT_DIR/native/run-money-report-tests.sh"
sh "$ROOT_DIR/native/run-portal-administration-tests.sh"
sh "$ROOT_DIR/native/run-pricebook-ai-tests.sh"
sh "$ROOT_DIR/native/run-pricebook-tests.sh"
sh "$ROOT_DIR/native/run-receipt-ocr-tests.sh"
sh "$ROOT_DIR/native/run-route-planning-tests.sh"
sh "$ROOT_DIR/native/run-schedule-tests.sh"
sh "$ROOT_DIR/native/run-tax-settings-tests.sh"
sh "$ROOT_DIR/native/run-trade-template-tests.sh"
sh "$ROOT_DIR/native/run-zip-archive-tests.sh"
"$ROOT_DIR/native/run-phase-3-device-preflight-tests.sh"
"$ROOT_DIR/native/run-phase-4-device-preflight-tests.sh"
(cd "$ROOT_DIR/backend-workers" && npm test)
