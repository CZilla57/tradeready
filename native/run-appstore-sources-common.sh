#!/bin/sh
# Shared source list for host-test runners that compile AppStore.swift
# standalone. AppStore.swift pulls in most of the domain layer, so every such
# runner needs the same dependency closure; keeping it here means a new
# AppStore dependency is added once instead of in every runner.
#
# Sourced (after ROOT_DIR is set) by the run-calendar-editor,
# run-export-import-ui, run-phase9-qualification, run-pricebook-ui,
# run-schedule-booking-settings and run-store-integration runners. Each runner
# appends only its own extras (views, presentation models) and its main.swift.
#
# Phase 12.00b.2-A review M6: the list also carries the host-only in-memory
# Keychain (`HostTestSupport/HostInMemoryKeychain.swift`); every host-test
# `AppStore` is built on `hostTestSecureSettingsStore()` unless it injects a
# fake, so no runner reads or writes the real login Keychain.
#
# Phase 12 (12.00b.2-L): `NativeBookingOwnerResponses.swift` extends AppStore
# (the owner-response outcomes and their notices), so it follows AppStore.swift.
APPSTORE_TEST_SOURCES="
$ROOT_DIR/native/HostTestSupport/HostInMemoryKeychain.swift
$ROOT_DIR/native/TradeReadyNative/Domain/FinancialDomain.swift
$ROOT_DIR/native/TradeReadyNative/Domain/BusinessRules.swift
$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalModels.swift
$ROOT_DIR/native/TradeReadyNative/Domain/CanonicalSnapshot.swift
$ROOT_DIR/native/TradeReadyNative/Domain/SnapshotRepository.swift
$ROOT_DIR/native/TradeReadyNative/Models.swift
$ROOT_DIR/native/TradeReadyNative/Domain/JobInvoiceDomain.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceList.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceEditing.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoicePaymentLinks.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceNotifications.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeAppRatingPrompt.swift
$ROOT_DIR/native/TradeReadyNative/NativeStripeConnect.swift
$ROOT_DIR/native/TradeReadyNative/Domain/UIModelAdapters.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringJobs.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeRecurringInvoices.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeSchedule.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCalendar.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeAvailability.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingIntake.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeBookingAttention.swift
$ROOT_DIR/native/TradeReadyNative/NativeBookingAdministration.swift
$ROOT_DIR/native/TradeReadyNative/NativeBookingResponse.swift
$ROOT_DIR/native/TradeReadyNative/NativePortalAdministration.swift
$ROOT_DIR/native/TradeReadyNative/NativeScheduleBookingStore.swift
$ROOT_DIR/native/TradeReadyNative/LegacyDataImporter.swift
$ROOT_DIR/native/TradeReadyNative/LegacyMigrationCoordinator.swift
$ROOT_DIR/native/TradeReadyNative/NativePasswordRecovery.swift
$ROOT_DIR/native/TradeReadyNative/NativeOnboarding.swift
$ROOT_DIR/native/TradeReadyNative/NativeAuxiliaryStateActivation.swift
$ROOT_DIR/native/TradeReadyNative/NativeCustomerIdentity.swift
$ROOT_DIR/native/TradeReadyNative/NativeCustomerDuplicateDismissals.swift
$ROOT_DIR/native/TradeReadyNative/NativeGlobalSearch.swift
$ROOT_DIR/native/TradeReadyNative/NativeJobList.swift
$ROOT_DIR/native/TradeReadyNative/NativeAuthenticatedIdentity.swift
$ROOT_DIR/native/TradeReadyNative/NativeSupabaseAuth.swift
$ROOT_DIR/native/TradeReadyNative/NativeAppleSignIn.swift
$ROOT_DIR/native/TradeReadyNative/NativeGoogleSignIn.swift
$ROOT_DIR/native/TradeReadyNative/NativeSyncCursor.swift
$ROOT_DIR/native/TradeReadyNative/NativeInitialSync.swift
$ROOT_DIR/native/TradeReadyNative/NativeMutationQueue.swift
$ROOT_DIR/native/TradeReadyNative/NativeRecordDeletion.swift
$ROOT_DIR/native/TradeReadyNative/NativeSyncBackfill.swift
$ROOT_DIR/native/TradeReadyNative/NativeMutationPushClassification.swift
$ROOT_DIR/native/TradeReadyNative/NativeSupabasePush.swift
$ROOT_DIR/native/TradeReadyNative/NativeRejectedChangeStore.swift
$ROOT_DIR/native/TradeReadyNative/NativeSyncCoordinator.swift
$ROOT_DIR/native/TradeReadyNative/NativeBackgroundRefresh.swift
$ROOT_DIR/native/TradeReadyNative/NativeDerivedStatePublisher.swift
$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoTransfer.swift
$ROOT_DIR/native/TradeReadyNative/NativeJobPhotoImport.swift
$ROOT_DIR/native/TradeReadyNative/NativeEstimateApprovalLink.swift
$ROOT_DIR/native/TradeReadyNative/NativeChangeOrderApprovalLink.swift
$ROOT_DIR/native/TradeReadyNative/NativeJobProfitability.swift
$ROOT_DIR/native/TradeReadyNative/NativeTimeTracking.swift
$ROOT_DIR/native/TradeReadyNative/NativeReviewRequests.swift
$ROOT_DIR/native/TradeReadyNative/NativeReviewRequestStore.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeSetupChecklist.swift
$ROOT_DIR/native/TradeReadyNative/NativeSetupChecklistStore.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInsightMutes.swift
$ROOT_DIR/native/TradeReadyNative/NativeInsightMuteStore.swift
$ROOT_DIR/native/TradeReadyNative/NativeInvoiceDelivery.swift
$ROOT_DIR/native/TradeReadyNative/NativeInvoicePDF.swift
$ROOT_DIR/native/TradeReadyNative/NativeEstimateDelivery.swift
$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUp.swift
$ROOT_DIR/native/TradeReadyNative/NativeEstimateFollowUpNotifications.swift
$ROOT_DIR/native/TradeReadyNative/NativeNotificationCategories.swift
$ROOT_DIR/native/TradeReadyNative/NativeAppointmentNotifications.swift
$ROOT_DIR/native/TradeReadyNative/NativeChangeOrders.swift
$ROOT_DIR/native/TradeReadyNative/NativeSubscription.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCashBasis.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReports.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsJobs.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyReportsReadModels.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeMoneyCardModels.swift
$ROOT_DIR/native/TradeReadyNative/NativeTaxBreakdown.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVExport.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeZipArchive.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCSVImport.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportMapping.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeImportEngine.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeMileage.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeExpenseComposer.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeReceiptMedia.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeLogoMedia.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativePricebook.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeTaxSettings.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeBusinessSnapshot.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachPrompt.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachQuickPrompts.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeChatMarkdown.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeCoachTranscript.swift
$ROOT_DIR/native/TradeReadyNative/NativeCoachTransport.swift
$ROOT_DIR/native/TradeReadyNative/NativeReceiptOCR.swift
$ROOT_DIR/native/TradeReadyNative/NativePricebookAI.swift
$ROOT_DIR/native/TradeReadyNative/NativeAITransport.swift
$ROOT_DIR/native/TradeReadyNative/NativeAIProviderKeyPolicy.swift
$ROOT_DIR/native/TradeReadyNative/NativeAIProviderKeyStore.swift
$ROOT_DIR/native/TradeReadyNative/NativeAIProviderKeyOwnerTag.swift
$ROOT_DIR/native/TradeReadyNative/NativeAccountBoundaryStepRecord.swift
$ROOT_DIR/native/TradeReadyNative/NativeImportHistory.swift
$ROOT_DIR/native/TradeReadyNative/NativeAccountDeletion.swift
$ROOT_DIR/native/TradeReadyNative/NativeTypedAccountState.swift
$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkParser.swift
$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetAppGroup.swift
$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetSnapshot.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeWidgetSnapshot.swift
$ROOT_DIR/native/TradeReadyNative/NativeWidgetMirror.swift
$ROOT_DIR/native/TradeReadyNative/NativeAppGroupInbox.swift
$ROOT_DIR/native/TradeReadyNative/Widgets/Shared/WidgetActionFieldRules.swift
$ROOT_DIR/native/TradeReadyNative/NativeWidgetOwnerGate.swift
$ROOT_DIR/native/TradeReadyNative/NativeDeepLinkRouting.swift
$ROOT_DIR/native/TradeReadyNative/NativeWidgetActionReplay.swift
$ROOT_DIR/native/TradeReadyNative/BuildEnvironment.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayInsights.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInsightsCardPolicy.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeTodayBriefing.swift
$ROOT_DIR/native/TradeReadyNative/NativeErrorRedaction.swift
$ROOT_DIR/native/TradeReadyNative/NativeCrashReporting.swift
$ROOT_DIR/native/TradeReadyNative/NativeAnalytics.swift
$ROOT_DIR/native/TradeReadyNative/Domain/NativeInvoiceBulk.swift
$ROOT_DIR/native/TradeReadyNative/NativeAnalyticsEvents.swift
$ROOT_DIR/native/TradeReadyNative/NativePerformanceMetrics.swift
$ROOT_DIR/native/TradeReadyNative/NativeSupportDiagnostics.swift
$ROOT_DIR/native/TradeReadyNative/NativeRunMarker.swift
$ROOT_DIR/native/TradeReadyNative/AppStore.swift
$ROOT_DIR/native/TradeReadyNative/NativeBookingOwnerResponses.swift
"
