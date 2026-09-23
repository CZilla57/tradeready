#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH="${TMPDIR:-/tmp}/tradeready-phase9-qualification-tests"
MODULE_CACHE="${TMPDIR:-/tmp}/tradeready-phase9-qualification-module-cache"

swiftc \
  -D GLOBAL_SEARCH_PURE_TESTS \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/SnapshotRepository.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Models.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceEditing.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoicePaymentLinks.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeStripeConnect.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringInvoices.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAvailability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingIntake.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingAttention.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBookingAdministration.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBookingResponse.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativePortalAdministration.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeScheduleBookingStore.swift" \
  "$ROOT_DIR/native/TradeReadyNative/LegacyDataImporter.swift" \
  "$ROOT_DIR/native/TradeReadyNative/LegacyMigrationCoordinator.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativePasswordRecovery.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeOnboarding.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAuxiliaryStateActivation.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeCustomerDuplicateDismissals.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeGlobalSearch.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAuthenticatedIdentity.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSupabaseAuth.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppleSignIn.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeGoogleSignIn.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSyncCursor.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInitialSync.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeRecordDeletion.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSyncBackfill.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSupabasePush.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSyncCoordinator.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeBackgroundRefresh.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoTransfer.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoImport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateApprovalLink.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrderApprovalLink.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReviewRequests.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReviewRequestStore.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInvoiceDelivery.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeInvoicePDF.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateDelivery.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppointmentNotifications.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeSubscription.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeZipArchive.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeAccountingPackage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileageLog.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTradeTemplates.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePricebookPresentation.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativePricebookAI.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyCardModels.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVImport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportMapping.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportEngine.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExportImportPresentation.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeExpenseComposer.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeReceiptMedia.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativePricebook.swift" \
  "$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeReceiptOCR.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAITransport.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeImportHistory.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAccountDeletion.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeTypedAccountState.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkParser.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeAppGroupInbox.swift" \
  "$ROOT_DIR/native/TradeReadyNative/NativeWidgetActionReplay.swift" \
  "$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift" \
  "$ROOT_DIR/native/TradeReadyNative/AppStore.swift" \
  "$ROOT_DIR/native/Phase9QualificationTests/main.swift" \
  -o "$OUTPUT_PATH"


"$OUTPUT_PATH"
