import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

private enum SubscriptionActionTestError: LocalizedError {
    case failed

    var errorDescription: String? { "private purchase diagnostic" }
}

private enum StoreTestError: Error {
    case missingFixture
}

/// A deterministic decodable JPEG for the 9.10 receipt-storage assertions.
private enum StoreTestImage {
    static func noisyJPEG(width: Int, height: Int) -> Data? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in bytes.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8((seed >> 33) & 0xFF)
        }
        bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress { context.data?.copyMemory(from: base, byteCount: bytes.count) }
        }
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
        #else
        return nil
        #endif
    }
}

/// Advisory OCR stub: a fixed reviewed draft, never a network call.
private struct StoreTestOCRTransport: NativeAdvisoryAITransport {
    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int, imageBase64: String, mediaType: String) -> String? {
        #"{"merchant":"Home Depot","amount":84.17,"date":"2026-07-18","category":"fuel","confidence":"high"}"#
    }

    func backendExtract(imageBase64: String, mediaType: String) -> String? {
        #"{"merchant":"Home Depot","amount":84.17,"date":"2026-07-18","category":"fuel","confidence":"high"}"#
    }

    func claudeMessage(prompt: String, apiKey: String, maxTokens: Int) -> String? { nil }

    func backendSuggest(payload: [String: Canonical.JSONValue]) -> String? { nil }
}

@MainActor
private final class StoreSubscriptionServiceStub: NativeSubscriptionServing {
    var purchaseResult = Result<NativeSubscriptionPurchaseResult, Error>.success(
        .init(
            entitlement: .init(isActive: false, isTrialing: false),
            userCancelled: false
        )
    )
    var restoreResult = Result<NativeSubscriptionEntitlement, Error>.success(
        .init(isActive: false, isTrialing: false)
    )

    func prepare(
        appUserID: String,
        apiKey: String,
        entitlementID: String
    ) async throws -> NativeSubscriptionEntitlement {
        .init(isActive: false, isTrialing: false)
    }

    func loadOffering() async throws -> NativeSubscriptionOffering {
        .init(packages: [])
    }

    func purchase(packageID: String) async throws -> NativeSubscriptionPurchaseResult {
        try purchaseResult.get()
    }

    func restore() async throws -> NativeSubscriptionEntitlement {
        try restoreResult.get()
    }

    func logOut() async {}
}

/// Records every `track` call verbatim (event name + properties) — task
/// 10.12's analytics-seam tests inject this in place of `NativeNoOpAnalytics`.
@MainActor
private final class RecordingAnalytics: NativeAnalytics {
    var calls: [(event: String, properties: [String: String])] = []
    /// Task 11.08 (m1): the protocol requires only the typed `track`; the
    /// legacy string view keeps these 10.12 assertions readable.
    func track(_ event: String, _ properties: [String: NativeAnalyticsValue]) {
        calls.append((event, properties.mapValues(\.legacyStringValue)))
    }
}

@main
struct StoreIntegrationTests {
    @MainActor
    static func main() async throws {
        var failures = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { failures += 1; print("FAIL: \(label)") }
        }

        expect(nativeShouldPreserveSignedInGateDuringTemporaryOutage(
            isInitialCheck: false,
            accountState: .verified,
            gateState: .signedIn(email: "owner@example.com"),
            hasVerifiedSubject: true,
            hasVerifiedBinding: true
        ), "a foreground transport outage cannot replace an established signed-in gate")
        expect(!nativeShouldPreserveSignedInGateDuringTemporaryOutage(
            isInitialCheck: true,
            accountState: .verified,
            gateState: .signedIn(email: nil),
            hasVerifiedSubject: true,
            hasVerifiedBinding: true
        ), "cold launch still requires exact persisted offline evidence")

        let fixtureRoot = ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
        let richData = try Data(contentsOf: URL(fileURLWithPath: fixtureRoot).appendingPathComponent("canonical-rich.json"))
        let rich = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: richData)
        func field<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONEncoder().encode(rich[key]!))
        }
        func legacyValue(_ key: String, array: Bool = true) throws -> Data {
            let value: Canonical.JSONValue = array ? .array([rich[key]!]) : rich[key]!
            return try JSONEncoder().encode(value)
        }

        let imported = try LegacyDataImporter.decodeSnapshot(values: [
            "invoices": legacyValue("invoice"),
            "jobs": legacyValue("job"),
            "customers": legacyValue("customer"),
            "settings": legacyValue("settings", array: false),
            "expenses": legacyValue("expense"),
            "customerNotes": legacyValue("customerNotes", array: false),
            "recurringJobs": legacyValue("recurringJob"),
            "recurringInvoices": legacyValue("recurringInvoice"),
            "trips": legacyValue("trip"),
            "pricebook": legacyValue("pricebookEntry"),
            "bookingRequests": legacyValue("bookingRequest"),
            "jobPhotos": legacyValue("jobPhoto")
        ], currentSettings: BusinessSettings())
        expect(imported.importedCount == 13, "legacy importer counts every plain-storage family")
        expect(imported.snapshot.payload.jobs?.first?.jobCosts?.first?.notes == "Paid at counter",
               "legacy importer retains canonical-only nested fields")
        expect(imported.snapshot.payload.bookingRequests?.first?.manageToken == "manage-token",
               "legacy importer retains backend-managed booking fields")
        expect(imported.snapshot.payload.settings?.providerKey == "secure-fixture",
               "legacy importer retains secure values in memory for secure-store migration")
        let settingsOnly = try LegacyDataImporter.decodeSnapshot(
            values: ["settings": legacyValue("settings", array: false)],
            currentSettings: BusinessSettings()
        )
        expect(settingsOnly.importedCount == 1 && settingsOnly.snapshot.payload.settings?.businessName == "Ada Electric",
               "settings-only legacy data is importable")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tradeready-store-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let richStoreURL = directory.appendingPathComponent("RichJob/store.json")
        try Canonical.SnapshotRepository(primaryURL: richStoreURL).save(imported.snapshot)
        let richStore = AppStore(fileURL: richStoreURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let richListItem = richStore.jobListItems.first
        expect(richListItem?.isRecurring == true && richListItem?.isArchived == true,
               "job list projects recurrence and archive state from canonical truth")
        expect(abs((richListItem?.billableTotal ?? 0) - 1434.57) < 0.000_001,
               "job list total rounds the approved subtotal before the final billable amount")
        if var richJob = richStore.jobs.first {
            richJob.title = "Edited without flattening"
            expect(richStore.upsert(richJob), "job edits durably commit before returning success")
            let preserved = try Canonical.SnapshotRepository(primaryURL: richStoreURL)
                .load()?.snapshot.payload.jobs?.first
            expect(preserved?.recurringJobId == "rj-9"
                   && preserved?.changeOrders?.count == 2
                   && preserved?.jobCosts?.first?.notes == "Paid at counter",
                   "ordinary job edits preserve canonical-only recurrence, change orders, and costs")

            let duplicateDate = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
            if let draft = richStore.duplicateJobDraft(sourceID: richJob.id, createdAt: duplicateDate) {
                expect(draft.job.id != richJob.id
                       && draft.job.status == .lead
                       && draft.job.scheduledAt == nil
                       && draft.job.invoiceId == nil,
                       "duplicate draft starts a fresh unscheduled lead lifecycle")
                var editedDuplicate = draft.job
                editedDuplicate.title = "Second panel job"
                expect(richStore.createDuplicatedJob(editedDuplicate, template: draft.canonicalTemplate),
                       "reviewed duplicate commits through its canonical template")
                let afterDuplicate = try Canonical.SnapshotRepository(primaryURL: richStoreURL)
                    .load()?.snapshot.payload.jobs ?? []
                let savedDuplicate = afterDuplicate.first { $0.id == editedDuplicate.id }
                let unchangedSource = afterDuplicate.first { $0.id == richJob.id }
                expect(afterDuplicate.count == 2
                       && savedDuplicate?.title == "Second panel job"
                       && savedDuplicate?.materials.count == 1
                       && savedDuplicate?.jobCosts == nil
                       && savedDuplicate?.changeOrders == nil
                       && savedDuplicate?.recurringJobId == nil
                       && savedDuplicate?.photos == nil
                       && savedDuplicate?.archivedAt == nil,
                       "saved duplicate carries pricing but clears source lifecycle and field metadata")
                expect(unchangedSource?.recurringJobId == "rj-9"
                       && unchangedSource?.changeOrders?.count == 2
                       && unchangedSource?.jobCosts?.count == 2,
                       "saving a duplicate leaves the source canonical job untouched")
                expect(!richStore.createDuplicatedJob(editedDuplicate, template: draft.canonicalTemplate),
                       "reusing a committed duplicate draft refuses to overwrite its ID")
                let afterCollision = try Canonical.SnapshotRepository(primaryURL: richStoreURL)
                    .load()?.snapshot.payload.jobs ?? []
                expect(afterCollision.count == 2,
                       "duplicate ID collision leaves the canonical collection unchanged")
            } else {
                expect(false, "rich canonical job can prepare a duplicate draft")
            }

            if var pricing = richStore.jobPricingDraft(jobID: richJob.id) {
                pricing.laborHours = 9
                pricing.marginPercent = 18
                pricing.travelMiles = 15
                pricing.taxPercent = 4
                pricing.laborBreakdown = try CanonicalUIAdapters.newLaborBreakdown(onSiteHours: 7)
                pricing.laborBreakdown?.driveHours = 1
                pricing.laborBreakdown?.setupCleanupHours = 1
                pricing.laborBreakdown?.nonBillableNote = "Customer access delay"
                expect(richStore.saveJobPricing(pricing),
                       "pricing draft durably commits through the canonical job")
                let priced = try Canonical.SnapshotRepository(primaryURL: richStoreURL)
                    .load()?.snapshot.payload.jobs?.first { $0.id == richJob.id }
                expect(priced?.laborHours == 9
                       && priced?.laborBreakdown?.onSiteHours == 7
                       && priced?.laborBreakdown?.driveHours == 1
                       && priced?.laborBreakdown?.nonBillableNote == "Customer access delay"
                       && priced?.estimateTotal == PricingEngine.calculate(pricing.input).total,
                       "pricing save publishes the Decimal engine total")
                expect(priced?.title == "Edited without flattening"
                       && priced?.recurringJobId == "rj-9"
                       && priced?.approval?.token == "approve-token"
                       && priced?.changeOrders?.count == 2
                       && priced?.jobCosts?.first?.notes == "Paid at counter",
                       "pricing save preserves current descriptive, recurrence, approval, change-order, and nested metadata")
            } else {
                expect(false, "canonical job can open a pricing draft")
            }
        } else {
            expect(false, "rich canonical job projects into the UI")
        }

        let changeOrderURL = directory.appendingPathComponent("ChangeOrders/store.json")
        var changeOrderJob: Canonical.Job = try field("job")
        changeOrderJob.status = "in_progress"
        changeOrderJob.preservation.unknownFields["futureJob"] = .string("keep")
        changeOrderJob.changeOrders?[0].preservation.unknownFields["futureOrder"] = .bool(true)
        let originalEstimateTotal = changeOrderJob.estimateTotal
        try Canonical.SnapshotRepository(primaryURL: changeOrderURL).save(
            .init(payload: .init(jobs: [changeOrderJob]))
        )
        let changeOrderStore = AppStore(fileURL: changeOrderURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let changeOrderDate = ISO8601DateFormatter().date(from: "2026-09-19T02:00:00Z")!

        let createdChangeOrderID = changeOrderStore.createChangeOrder(
            jobID: changeOrderJob.id,
            title: "  Add dedicated circuit  ",
            description: "  Customer-requested outlet  ",
            amountText: "125.555",
            on: changeOrderDate
        )
        expect(createdChangeOrderID?.hasPrefix("co") == true,
               "change-order create returns the durable wire-compatible identifier")
        if let createdChangeOrderID {
            let createdRecord = try Canonical.SnapshotRepository(primaryURL: changeOrderURL)
                .load()?.snapshot.payload.jobs?.first
            let createdOrder = createdRecord?.changeOrders?.first { $0.id == createdChangeOrderID }
            expect(createdOrder?.title == "Add dedicated circuit"
                   && createdOrder?.description == "Customer-requested outlet"
                   && createdOrder?.amount == Decimal(string: "125.56")
                   && createdOrder?.createdAt == "2026-09-19",
                   "change-order create commits trimmed, cent-rounded canonical values")
            expect(createdRecord?.estimateTotal == originalEstimateTotal
                   && createdRecord?.preservation.unknownFields["futureJob"] == .string("keep")
                   && createdRecord?.changeOrders?.first?.preservation.unknownFields["futureOrder"] == .bool(true),
                   "change-order create preserves estimate baseline and existing unknown fields")

            expect(changeOrderStore.updateChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: createdChangeOrderID,
                title: "Dedicated circuit and outlet",
                description: "Revised on site",
                amountText: "140"
            ), "pending change order can be edited through a fresh canonical lookup")
            expect(changeOrderStore.recordManualChangeOrderDecision(
                jobID: changeOrderJob.id,
                changeOrderID: createdChangeOrderID,
                decision: .approved,
                note: "  Verbal approval on site  ",
                on: changeOrderDate
            ), "pending change order accepts a separate on-site decision record")
            expect(!changeOrderStore.updateChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: createdChangeOrderID,
                title: "Stale overwrite",
                description: "",
                amountText: "1"
            ), "stale edit cannot overwrite a newer decision")
            expect(!changeOrderStore.cancelChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: createdChangeOrderID,
                on: changeOrderDate
            ), "approved change order cannot be cancelled by a stale action")
        } else {
            expect(false, "eligible canonical job creates a change order")
        }

        let cancellableID = changeOrderStore.createChangeOrder(
            jobID: changeOrderJob.id,
            title: "Alternate fixture",
            description: "",
            amountText: "75",
            on: changeOrderDate
        )
        if let cancellableID {
            expect(changeOrderStore.cancelChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: cancellableID,
                on: changeOrderDate
            ), "pending change order can be cancelled")
            expect(!changeOrderStore.deletePendingChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: cancellableID
            ), "cancelled change order remains as immutable history")
        } else {
            expect(false, "second eligible change order is created")
        }

        let deletableID = changeOrderStore.createChangeOrder(
            jobID: changeOrderJob.id,
            title: "Temporary option",
            description: "",
            amountText: "25",
            on: changeOrderDate
        )
        if let deletableID {
            expect(changeOrderStore.deletePendingChangeOrder(
                jobID: changeOrderJob.id,
                changeOrderID: deletableID
            ), "pending change order can be deleted before it is sent or decided")
            expect(!changeOrderStore.changeOrders(for: changeOrderJob.id).contains { $0.id == deletableID },
                   "deleted pending change order is absent from the canonical read model")
        } else {
            expect(false, "deletable change order is created")
        }

        let finalChangeOrderJob = try Canonical.SnapshotRepository(primaryURL: changeOrderURL)
            .load()?.snapshot.payload.jobs?.first
        expect(finalChangeOrderJob?.changeOrders?.count == 4
               && finalChangeOrderJob?.changeOrders?.first { $0.id == createdChangeOrderID }?.manualDecision?.note == "Verbal approval on site"
               && finalChangeOrderJob?.changeOrders?.first { $0.id == createdChangeOrderID }?.title == "Dedicated circuit and outlet",
               "durable change-order history retains the accepted edit and one manual decision")
        if let finalChangeOrderJob {
            expect(NativeChangeOrders.billableTotal(for: finalChangeOrderJob) == Decimal(string: "1574.57"),
                   "billable reconciliation includes approved deltas and excludes cancellation")
        }
        let changeOrderQueue = Canonical.NativeMutationQueue(
            fileURL: changeOrderURL.deletingLastPathComponent().appendingPathComponent("mutation-queue.json")
        ).load().filter { $0.table == "jobs" && $0.recordId == changeOrderJob.id }
        expect(changeOrderQueue.count == 1 && changeOrderQueue.first?.op == .upsert,
               "successive change-order commits deduplicate to one queued canonical job upsert")
        if let queuedPayload = changeOrderQueue.first?.payload {
            let queuedJob = try JSONDecoder().decode(
                Canonical.Job.self,
                from: JSONEncoder().encode(queuedPayload)
            )
            expect(queuedJob.changeOrders == nil ? false : queuedJob.changeOrders!.count == 4,
                   "queued job payload matches the complete durable change-order history")
        } else {
            expect(false, "change-order mutation publishes a queued job payload")
        }

        let editorURL = directory.appendingPathComponent("ChangeOrderEditor/store.json")
        var editorJob: Canonical.Job = try field("job")
        editorJob.status = "approved"
        editorJob.changeOrders = []
        editorJob.preservation.unknownFields["futureJob"] = .string("keep")
        try Canonical.SnapshotRepository(primaryURL: editorURL).save(.init(payload: .init(jobs: [editorJob])))
        let editorStore = AppStore(fileURL: editorURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())

        expect(editorStore.changeOrderSectionState(jobID: editorJob.id)?.isVisible == true,
               "an addable job with no orders still shows the change-order section")
        expect(editorStore.changeOrderSectionState(jobID: "missing") == nil,
               "an unknown job has no change-order section")

        if case let .success(newDraft) = editorStore.changeOrderDraft(jobID: editorJob.id) {
            expect(newDraft.editingID == nil && newDraft.title.isEmpty && newDraft.amountText.isEmpty,
                   "a new change-order draft starts blank")
            let createdEditorOrder = editorStore.commitChangeOrder(.init(
                jobID: editorJob.id,
                editingID: nil,
                title: "  Replace shutoff  ",
                description: "  On-site add  ",
                amountText: "310.555"
            ))
            if case let .created(editorOrderID) = createdEditorOrder {
                expect(editorOrderID.hasPrefix("co"), "commit returns a wire-compatible change-order id")
                let saved = editorStore.changeOrders(for: editorJob.id).first { $0.id == editorOrderID }
                expect(saved?.title == "Replace shutoff"
                       && saved?.description == "On-site add"
                       && saved?.amount == Decimal(string: "310.56"),
                       "commit trims text and cent-rounds the canonical order")
                expect(editorStore.changeOrderSectionState(jobID: editorJob.id)?.rows.count == 1,
                       "the section reflects the committed order immediately")
            } else {
                expect(false, "the editor draft creates a change order")
            }
        } else {
            expect(false, "an addable job opens a blank change-order draft")
        }

        let editorOrderID = editorStore.changeOrders(for: editorJob.id).first?.id
        if let editorOrderID,
           case let .success(editDraft) = editorStore.changeOrderDraft(
               jobID: editorJob.id, changeOrderID: editorOrderID
           ) {
            expect(editDraft.editingID == editorOrderID && editDraft.amountText == "310.56",
                   "an edit draft prefills the pending order")
            expect(editorStore.commitChangeOrder(.init(
                jobID: editorJob.id,
                editingID: editorOrderID,
                title: "Replace shutoff and trap",
                description: "",
                amountText: "325"
            )) == .updated, "commit edits a still-pending order in place")
            expect(editorStore.recordManualChangeOrderDecision(
                jobID: editorJob.id,
                changeOrderID: editorOrderID,
                decision: .approved,
                note: "  Verbal OK on site  "
            ), "the section records an on-site decision without an approval link")
            expect(editorStore.changeOrderSectionState(jobID: editorJob.id)?.rows.first?.status == .approved,
                   "the section shows the derived approved status")
            expect(editorStore.changeOrderDraft(jobID: editorJob.id, changeOrderID: editorOrderID)
                   == .failure(.changeOrderNotPending),
                   "a decided order no longer opens an editor")
            expect(editorStore.commitChangeOrder(.init(
                jobID: editorJob.id,
                editingID: editorOrderID,
                title: "Stale overwrite",
                description: "",
                amountText: "1"
            )) == .refused(.changeOrderNotPending),
                   "a draft that went stale while the sheet was open fails closed")
            expect(editorStore.changeOrders(for: editorJob.id).first?.title == "Replace shutoff and trap"
                   && editorStore.changeOrders(for: editorJob.id).first?.manualDecision?.note == "Verbal OK on site",
                   "a refused commit writes nothing and keeps the trimmed decision note")
        } else {
            expect(false, "editing a pending order opens a prefilled draft")
        }

        expect(editorStore.changeOrderDraft(jobID: editorJob.id, changeOrderID: "missing")
               == .failure(.changeOrderNotFound),
               "a missing order cannot open an editor")
        expect(editorStore.commitChangeOrder(.init(
            jobID: editorJob.id, editingID: nil, title: "   ", description: "", amountText: "5"
        )) == .refused(.invalidInput("Please give this change a short title.")),
               "blank input is refused with the React Native form copy")
        expect(editorStore.commitChangeOrder(.init(
            jobID: "missing", editingID: nil, title: "X", description: "", amountText: "5"
        )) == .refused(.jobNotFound), "committing against a missing job is refused")

        let leadEditorURL = directory.appendingPathComponent("ChangeOrderEditorLead/store.json")
        var leadEditorJob: Canonical.Job = try field("job")
        leadEditorJob.status = "lead"
        leadEditorJob.changeOrders = []
        try Canonical.SnapshotRepository(primaryURL: leadEditorURL)
            .save(.init(payload: .init(jobs: [leadEditorJob])))
        let leadEditorStore = AppStore(fileURL: leadEditorURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(leadEditorStore.changeOrderSectionState(jobID: leadEditorJob.id)?.isVisible == false,
               "a lead job with no orders renders no section")
        expect(leadEditorStore.changeOrderDraft(jobID: leadEditorJob.id) == .failure(.jobNotEligible),
               "a job before approval cannot open a create draft")
        expect(leadEditorStore.commitChangeOrder(.init(
            jobID: leadEditorJob.id, editingID: nil, title: "Nope", description: "", amountText: "10"
        )) == .refused(.jobNotEligible), "a create that went stale fails closed")
        expect(leadEditorStore.changeOrders(for: leadEditorJob.id).isEmpty,
               "a refused create writes nothing")

        let subscriptionService = StoreSubscriptionServiceStub()
        let subscriptionStore = AppStore(
            fileURL: directory.appendingPathComponent("Subscription/store.json"),
            seedIfMissing: false,
            subscriptionService: subscriptionService,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        var googleCredentialClearCount = 0
        await subscriptionStore.useAnotherAccount {
            googleCredentialClearCount += 1
        }
        expect(
            googleCredentialClearCount == 1
                && subscriptionStore.authenticationGateState == .signedOut,
            "using another account clears the local Google credential on the signed-out path"
        )
        subscriptionService.purchaseResult = .success(.init(
            entitlement: .init(isActive: false, isTrialing: false),
            userCancelled: true
        ))
        let cancelledPurchase = await subscriptionStore.purchaseSubscription(packageID: "$rc_annual")
        expect(cancelledPurchase == .cancelled,
               "subscription purchase cancellation is silent and leaves the gate closed")
        subscriptionService.purchaseResult = .success(.init(
            entitlement: .init(isActive: false, isTrialing: false),
            userCancelled: false
        ))
        let inactivePurchase = await subscriptionStore.purchaseSubscription(packageID: "$rc_annual")
        expect(inactivePurchase == .noActiveSubscription,
               "purchase without the configured entitlement cannot open the gate")
        subscriptionService.purchaseResult = .success(.init(
            entitlement: .init(isActive: true, isTrialing: true),
            userCancelled: false
        ))
        let activePurchase = await subscriptionStore.purchaseSubscription(packageID: "$rc_annual")
        expect(activePurchase == .completed
               && subscriptionStore.isSubscriptionTrialing,
               "active purchased trial is retained in the app subscription state")
        subscriptionService.restoreResult = .success(.init(isActive: false, isTrialing: false))
        let inactiveRestore = await subscriptionStore.restoreSubscription()
        expect(inactiveRestore == .noActiveSubscription
               && !subscriptionStore.isSubscriptionTrialing,
               "restore without the configured entitlement cannot open the gate")
        subscriptionService.restoreResult = .success(.init(isActive: true, isTrialing: true))
        let activeRestore = await subscriptionStore.restoreSubscription()
        expect(activeRestore == .completed
               && subscriptionStore.isSubscriptionTrialing,
               "restore carries active trial state into Settings")
        subscriptionService.restoreResult = .failure(SubscriptionActionTestError.failed)
        let failedRestore = await subscriptionStore.restoreSubscription()
        expect(failedRestore == .failed(
            message: NativeSubscriptionError.unavailable.localizedDescription
        ), "restore errors use bounded copy instead of third-party diagnostics")

        let onboardingURL = directory.appendingPathComponent("Onboarding/store.json")
        let onboardingStore = NativeOnboardingStore(snapshotURL: onboardingURL)
        let ownerBinding = String(repeating: "a", count: 64)
        do {
            _ = try onboardingStore.establish(
                accountBinding: ownerBinding,
                imported: nil,
                hasPersonalizedSettings: true,
                allowCreation: false
            )
            expect(false, "a new login cannot claim unbound retained account data")
        } catch NativeOnboardingError.accountMismatch {}
        var onboarding = try onboardingStore.establish(
            accountBinding: ownerBinding,
            imported: nil,
            hasPersonalizedSettings: false
        )
        expect(onboarding.stage == .drafting && onboarding.draft.step == 0,
               "new verified accounts begin with an empty onboarding draft")
        onboarding.draft = .init(
            businessName: "Safe Electric",
            contactName: "Avery",
            trade: .electrical,
            step: 1
        )
        try onboardingStore.save(onboarding)
        onboarding.stage = .personalizationCommit
        try onboardingStore.save(onboarding)
        try Data("corrupt-onboarding".utf8).write(to: onboardingStore.primaryURL, options: .atomic)
        let recoveredOnboarding = try onboardingStore.load()
        expect(recoveredOnboarding?.draft.businessName == "Safe Electric"
               && recoveredOnboarding?.stage == .drafting,
               "onboarding corruption restores the last verified draft")
        do {
            _ = try onboardingStore.establish(
                accountBinding: String(repeating: "b", count: 64),
                imported: nil,
                hasPersonalizedSettings: false
            )
            expect(false, "another account cannot claim retained onboarding state")
        } catch NativeOnboardingError.accountMismatch {}

        let launchAsyncStorage = directory.appendingPathComponent("Launch/RCTAsyncLocalStorage_V1", isDirectory: true)
        let launchDocuments = directory.appendingPathComponent("Launch/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAsyncStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: launchDocuments, withIntermediateDirectories: true)
        let launchManifest = try JSONSerialization.data(withJSONObject: [
            "customers": String(decoding: try legacyValue("customer"), as: UTF8.self),
            "settings": String(decoding: try legacyValue("settings", array: false), as: UTF8.self)
        ])
        try launchManifest.write(
            to: launchAsyncStorage.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let launchSource = LegacyMigrationSource(
            asyncStorageDirectory: launchAsyncStorage,
            documentsDirectory: launchDocuments,
            secureSettings: .init(),
            appGroupValues: [:]
        )
        let cleanURL = directory.appendingPathComponent("CleanLaunch/store.json")
        let cleanStore = AppStore(
            fileURL: cleanURL,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: .init(
                asyncStorageDirectory: nil,
                documentsDirectory: launchDocuments,
                secureSettings: .init(),
                appGroupValues: [:]
            ),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(cleanStore.customers.count == 3 && cleanStore.launchMigrationNotice == nil,
               "clean launch seeds only after legacy migration reports no data")
        let launchURL = directory.appendingPathComponent("LaunchNative/store.json")
        let launchStore = AppStore(
            fileURL: launchURL,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: launchSource,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(launchStore.customers.count == 1 && launchStore.customers.first?.name == "Ada Lovelace",
               "launch migration imports Expo data before demo seeding")
        let launchNoticeCount: Int? = if case let .migrated(count, _, _)? = launchStore.launchMigrationNotice {
            count
        } else {
            nil
        }
        expect(launchNoticeCount == 2, "launch migration exposes a typed success notice")
        let launchJournal = Canonical.MigrationJournal(
            fileURL: launchURL.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        let launchMigrationComplete = try launchJournal.isComplete(.reactNativeAsyncStorage)
        expect(launchMigrationComplete,
               "automatic launch migration completes its journal")

        let replayBytes = try Data(contentsOf: launchURL)
        let replayStore = AppStore(
            fileURL: launchURL,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: launchSource,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(replayStore.customers.count == 1 && replayStore.launchMigrationNotice == nil,
               "completed launch migration reloads silently")
        let replayedBytes = try Data(contentsOf: launchURL)
        expect(replayedBytes == replayBytes,
               "completed launch replay does not rewrite the snapshot")

        // Phase 12.00b.2-E fix round 2 (L267.a, Important 1): once a migration
        // has completed, this automatic launch path never calls
        // `coordinator.migrate` again (`hadNativeSnapshot` is true and the
        // journal status is `.completed`, exactly like `replayStore` above),
        // so the `.alreadyCompleted` re-protect hook inside `migrate` is
        // unreachable here — a protection failure from the original pass
        // would otherwise never heal on a later launch. A counting
        // `legacyFileEnumerator`, injected through the new `repository:`
        // parameter, proves the launch path re-protects the already-published
        // legacy backup copy directly instead.
        final class LaunchReprotectCallCounter { var count = 0 }
        let launchReprotectCounter = LaunchReprotectCallCounter()
        let launchReprotectRepository = Canonical.SnapshotRepository(
            primaryURL: launchURL,
            legacyFileEnumerator: { url in
                launchReprotectCounter.count += 1
                return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            }
        )
        let reprotectedLaunchStore = AppStore(
            fileURL: launchURL,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: launchSource,
            repository: launchReprotectRepository,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(reprotectedLaunchStore.customers.count == 1 && reprotectedLaunchStore.launchMigrationNotice == nil,
               "L267.a fix round 2 fixture: a steady-state launch with an injected repository still reloads silently")
        expect(launchReprotectCounter.count == 1,
               "L267.a fix round 2: an automatic launch that skips migration because it is already complete still re-protects the published legacy backup copy exactly once")

        // Companion case: a launch blocked on account-scrub recovery must not
        // run the re-protect hook either — `accountScrubRecoveryError != nil`
        // skips the entire migration block, both the `shouldAttempt` branch
        // and this fix's new `else` branch.
        let scrubBlockedURL = directory.appendingPathComponent("LaunchScrubBlocked/store.json")
        try Canonical.SnapshotRepository(primaryURL: scrubBlockedURL).beginAccountScrub(scope: .live)
        final class ScrubBlockedReprotectCallCounter { var count = 0 }
        let scrubBlockedCounter = ScrubBlockedReprotectCallCounter()
        let scrubBlockedRepository = Canonical.SnapshotRepository(
            primaryURL: scrubBlockedURL,
            legacyFileEnumerator: { url in
                scrubBlockedCounter.count += 1
                return FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            }
        )
        let scrubBlockedStore = AppStore(
            fileURL: scrubBlockedURL,
            automaticallyMigrateLegacyData: true,
            repository: scrubBlockedRepository,
            appGroupAccountScrubber: NativeAppGroupAccountScrubber(lockFile: nil),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(scrubBlockedStore.isAccountScrubBlocked,
               "L267.a fix round 2 fixture: sanity, the scrub is genuinely blocked")
        expect(scrubBlockedCounter.count == 0,
               "L267.a fix round 2: a launch blocked on account-scrub recovery does not re-protect the legacy backup copy")

        let conflictURL = directory.appendingPathComponent("Conflict/store.json")
        let conflictSeed = AppStore(fileURL: conflictURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let nativeCustomer = Customer(name: "Native Sentinel")
        conflictSeed.upsert(nativeCustomer)
        let conflictBytes = try Data(contentsOf: conflictURL)
        let conflictRepository = Canonical.SnapshotRepository(primaryURL: conflictURL)
        let conflictJournal = Canonical.MigrationJournal(
            fileURL: conflictURL.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        let conflictOutcome = try LegacyMigrationCoordinator(
            repository: conflictRepository,
            journal: conflictJournal
        ).migrate(currentSettings: conflictSeed.settings, source: launchSource)
        expect(conflictOutcome.status == .nativeSnapshotConflict,
               "migration coordinator refuses to overwrite unrelated native data")
        let conflictStore = AppStore(
            fileURL: conflictURL,
            seedIfMissing: false,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: launchSource,
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(conflictStore.customers.map(\.id) == [nativeCustomer.id]
               && conflictStore.launchMigrationNotice == nil,
               "automatic launch keeps existing native data without re-running import")
        let afterConflictBytes = try Data(contentsOf: conflictURL)
        expect(afterConflictBytes == conflictBytes,
               "launch conflict leaves native bytes unchanged")

        let brokenAsyncStorage = directory.appendingPathComponent("Broken/RCTAsyncLocalStorage_V1", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenAsyncStorage, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: brokenAsyncStorage.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        let brokenLaunchURL = directory.appendingPathComponent("BrokenNative/store.json")
        let brokenLaunch = AppStore(
            fileURL: brokenLaunchURL,
            automaticallyMigrateLegacyData: true,
            legacyMigrationSource: .init(
                asyncStorageDirectory: brokenAsyncStorage,
                documentsDirectory: launchDocuments,
                secureSettings: .init(),
                appGroupValues: [:]
            ),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        expect(brokenLaunch.isLegacyMigrationBlocked && brokenLaunch.customers.isEmpty,
               "failed first-launch migration blocks editing instead of seeding demo data")
        expect(!FileManager.default.fileExists(atPath: brokenLaunchURL.path),
               "failed first-launch migration leaves the native destination absent")

        let empty = AppStore(fileURL: url, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(empty.customers.isEmpty && empty.jobs.isEmpty && empty.invoices.isEmpty,
               "empty store has empty projections")

        let customer = Customer(name: "Canonical Customer", email: "owner@example.com")
        let job = Job(customerId: customer.id, customerName: customer.name, title: "Service call", laborRate: 95)
        let invoice = Invoice(customerId: customer.id, customer: customer.name, number: "INV-0100", amount: 250)
        let expense = Expense(merchant: "Supply House", amount: 42.75)
        expect(empty.upsert(customer), "saving a customer commits its canonical snapshot")
        empty.upsert(job); empty.upsert(invoice); empty.upsert(expense)
        empty.settings.businessName = "Canonical Plumbing"

        func pendingMutations(_ storeURL: URL) -> [Canonical.MutationItem] {
            Canonical.NativeMutationQueue(
                fileURL: storeURL.deletingLastPathComponent().appendingPathComponent("mutation-queue.json")
            ).load()
        }
        let queuedAfterSave = pendingMutations(url)
        func queuedItem(_ table: String, _ id: String) -> Canonical.MutationItem? {
            queuedAfterSave.first { $0.table == table && $0.recordId == id }
        }
        expect(queuedItem("customers", customer.id)?.op == .upsert, "saving a customer enqueues an upsert")
        expect(queuedItem("jobs", job.id)?.op == .upsert, "saving a job enqueues an upsert")
        expect(queuedItem("invoices", invoice.id)?.op == .upsert, "saving an invoice enqueues an upsert")
        expect(queuedItem("expenses", expense.id)?.op == .upsert, "saving an expense enqueues an upsert")
        let queuedSettings = queuedAfterSave.first { $0.table == "settings" }
        expect(queuedSettings?.op == .upsert, "changing settings enqueues a settings upsert")
        if case let .object(settingsPayload)? = queuedSettings?.payload {
            expect(Canonical.SnapshotCodec.secureSettingsKeys.allSatisfy { settingsPayload[$0] == nil },
                   "queued settings payload never carries secure credential keys")
        } else { expect(false, "queued settings payload is an object") }

        // Task 11.06 (contract §6.2): before sign-in a valid link parks and
        // routes nothing; the exact owner signing in applies it.
        empty.handle(url: URL(string: "tradeready://job/\(job.id)")!)
        expect(empty.selectedTab == .today && empty.deepLinkedJobID == nil
               && empty.parkedDeepLink?.route == .job(id: job.id),
               "a direct deep link before sign-in parks and routes nothing")
        empty.scheduleBookingTestSeedSignedInOwner(subject: "user-11.06", binding: "bind-11.06")
        expect(empty.selectedTab == .jobs && empty.deepLinkedJobID == job.id && empty.parkedDeepLink == nil,
               "strict direct deep link routes an existing job once the exact owner is signed in")
        empty.deepLinkedJobID = nil
        empty.handle(url: URL(string: "tradeready://onmyway/\(job.id)")!)
        expect(empty.selectedTab == .jobs && empty.deepLinkedJobID == job.id
               && empty.pendingOnMyWayJobID == job.id,
               "on-my-way deep link routes to a one-shot reviewed action")
        empty.dismissPendingOnMyWay(jobID: job.id)
        expect(empty.pendingOnMyWayJobID == nil,
               "reviewed action can be acknowledged exactly for its job")
        empty.selectedTab = .today
        empty.deepLinkedJobID = nil
        empty.handle(url: URL(string: "tradeready://job/\(job.id)/extra")!)
        expect(empty.selectedTab == .today && empty.deepLinkedJobID == nil,
               "direct deep link rejects extra path segments")
        empty.handle(url: URL(string: "tradeready://job/missing-job")!)
        expect(empty.selectedTab == .today && empty.deepLinkedJobID == nil,
               "direct deep link cannot route a missing local job")
        expect(empty.deepLinkUnavailableNotice?.reason == .missingRecord,
               "a missing job shows the existing not-found state")
        empty.dismissDeepLinkUnavailableNotice()
        // Restore the signed-out identity the checks below rely on.
        empty.scheduleBookingTestClearOwner()

        empty.routeToGlobalSearchResult(.customer(customer.id))
        expect(empty.selectedTab == .customers && empty.deepLinkedCustomerID == customer.id
               && empty.deepLinkedJobID == nil && empty.deepLinkedInvoiceID == nil,
               "global search routes an exact customer ID to the Customers tab")
        empty.routeToGlobalSearchResult(.invoice(invoice.id))
        expect(empty.selectedTab == .invoices && empty.deepLinkedInvoiceID == invoice.id
               && empty.deepLinkedCustomerID == nil,
               "global search routes an exact invoice ID to the Invoices tab")
        empty.routeToGlobalSearchResult(.job(job.id))
        expect(empty.selectedTab == .jobs && empty.deepLinkedJobID == job.id
               && empty.deepLinkedInvoiceID == nil,
               "global search routes an exact job ID to the Jobs tab")
        empty.selectedTab = .today
        empty.routeToGlobalSearchResult(.customer("missing-customer"))
        expect(empty.selectedTab == .today && empty.deepLinkedCustomerID == nil,
               "global search refuses to route a missing record")

        let storedBytes = try Data(contentsOf: url)
        let stored = try Canonical.SnapshotCodec.decode(storedBytes)
        expect(stored.schemaVersion == Canonical.Snapshot.currentSchemaVersion, "store writes current canonical schema")
        expect(stored.payload.customers?.first?.id == customer.id, "customer persisted canonically")
        expect(stored.payload.jobs?.first?.id == job.id, "job persisted canonically")
        expect(stored.payload.invoices?.first?.id == invoice.id, "invoice persisted canonically")
        expect(stored.payload.expenses?.first?.id == expense.id, "expense persisted canonically")

        let raw = try JSONDecoder().decode(Canonical.JSONValue.self, from: storedBytes)
        if case let .object(envelope) = raw,
           case let .object(payload)? = envelope["payload"],
           case let .object(settings)? = payload["settings"] {
            expect(Canonical.SnapshotCodec.secureSettingsKeys.allSatisfy { settings[$0] == nil },
                   "plain AppStore snapshot contains no secure settings")
        } else { expect(false, "stored canonical envelope shape") }

        let paymentInvoice = Invoice(
            customerId: customer.id,
            customer: customer.name,
            number: "INV-0101",
            amount: 200
        )
        let paymentJob = Job(
            customerId: customer.id,
            customerName: customer.name,
            title: "Payment workflow",
            status: .invoiced,
            invoiceId: paymentInvoice.id
        )
        empty.upsert(paymentInvoice)
        empty.upsert(paymentJob)
        var ratingWins: [NativeAppRatingWin] = []
        empty.onAppRatingWin = { ratingWins.append($0) }
        empty.recordPayment(
            invoiceID: paymentInvoice.id,
            payment: Payment(id: "payment-partial", amount: 75, method: "Cash")
        )
        expect(empty.invoices.first(where: { $0.id == paymentInvoice.id })?.balance == 125,
               "ID-based payment workflow records a partial payment")
        empty.recordPayment(
            invoiceID: paymentInvoice.id,
            payment: Payment(id: "payment-over", amount: 150, method: "Cheque")
        )
        let overpaid = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        expect(overpaid?.isPaid == true && overpaid?.overpaidAmount == 25,
               "payment workflow accepts and reports overpayment")
        expect(empty.jobs.first(where: { $0.id == paymentJob.id })?.status == .paid,
               "settlement advances an eligible linked job")
        empty.voidPayment(invoiceID: paymentInvoice.id, paymentID: "payment-over", on: paymentInvoice.due)
        let corrected = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        expect(corrected?.balance == 125 && corrected?.payments.last?.voidedAt != nil,
               "void correction retains history and restores the balance")
        expect(empty.jobs.first(where: { $0.id == paymentJob.id })?.status == .paid,
               "void correction never regresses an already-paid job")

        // Phase 7.03 — stable-ID resubmission is idempotent.
        empty.recordPayment(invoiceID: paymentInvoice.id,
                            payment: Payment(id: "payment-retry", amount: 25, method: "Cash"))
        let afterFirstSubmit = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        empty.recordPayment(invoiceID: paymentInvoice.id,
                            payment: Payment(id: "payment-retry", amount: 25, method: "Cash"))
        let afterSecondSubmit = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        expect(afterFirstSubmit?.balance == afterSecondSubmit?.balance
               && afterSecondSubmit?.effectivePayments.filter({ $0.id == "payment-retry" }).count == 1,
               "retrying the same payment ID records exactly one payment")
        _ = empty.settleInvoice(invoiceID: paymentInvoice.id, paymentID: "payment-settle-7")
        let settledOnce = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        _ = empty.settleInvoice(invoiceID: paymentInvoice.id, paymentID: "payment-settle-7b")
        let settledTwice = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        expect(settledOnce?.isPaid == true && settledTwice?.isPaid == true && settledTwice?.balance == 0,
               "repeated settlement is a safe no-op")
        expect(ratingWins == [.invoicePaid, .invoicePaid],
               "only the payment that settles an invoice and the first settle are rating wins; partial, deduped, and repeat settles are not")
        _ = empty.voidPayment(invoiceID: paymentInvoice.id, paymentID: "payment-settle-7", on: paymentInvoice.due)
        let voidedOnce = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        _ = empty.voidPayment(invoiceID: paymentInvoice.id, paymentID: "payment-settle-7", on: paymentInvoice.due)
        let voidedTwice = empty.invoices.first(where: { $0.id == paymentInvoice.id })
        expect(voidedOnce?.balance == voidedTwice?.balance,
               "voiding an already-voided payment changes nothing")
        let missingResult = empty.recordPayment(
            invoiceID: "missing-invoice",
            payment: Payment(id: "payment-ghost", amount: 1))
        switch missingResult {
        case .failure(.missingRecord): break
        default: expect(false, "payment against a missing invoice fails closed")
        }

        // Phase 7.11 — bulk settlement commits every applicable invoice at once.
        let bulkA = Invoice(customer: "Bulk A", number: "INV-BULK-A", amount: 120)
        let bulkB = Invoice(customer: "Bulk B", number: "INV-BULK-B", amount: 80)
        empty.upsert(bulkA)
        empty.upsert(bulkB)
        let bulkAId = empty.invoices.first(where: { $0.number == "INV-BULK-A" })?.id ?? bulkA.id
        let bulkBId = empty.invoices.first(where: { $0.number == "INV-BULK-B" })?.id ?? bulkB.id
        let bulk = empty.commitBulkSettleInvoices(ids: [bulkAId, bulkBId, "missing-invoice"])
        expect(bulk.settled.count == 2 && bulk.skipped == 1, "bulk settles applicable and reports skips")
        expect(empty.invoices.first(where: { $0.id == bulkAId })?.isPaid == true
               && empty.invoices.first(where: { $0.id == bulkBId })?.isPaid == true,
               "bulk-settled invoices read paid")
        let bulkRepeat = empty.commitBulkSettleInvoices(ids: [bulkAId, bulkBId])
        expect(bulkRepeat.settled.isEmpty && bulkRepeat.skipped == 2, "repeating a bulk run settles nothing")

        // Phase 7.12 — maintenance-plan rules and coordinated generation.
        let planRule = Canonical.RecurringInvoice(
            id: "rinv-test-1", customerId: customer.id, customerName: customer.name,
            description: "Maintenance", amount: 150, dueDays: 30,
            cadence: "monthly", endCondition: "never", endCount: nil, endDate: nil,
            occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: "2026-09-01",
            isActive: true, createdAt: "2026-09-01", autoSendEnabled: false)
        let prePlanCount = empty.invoices.count
        expect(empty.createRecurringInvoice(planRule), "maintenance plan creates")
        expect(empty.createRecurringInvoice(planRule) == false, "duplicate plan id refused")
        expect(empty.runRecurringInvoiceGeneration(today: "2026-09-15"), "generation runs")
        expect(empty.invoices.count == prePlanCount + 1, "one due occurrence generates")
        expect(empty.recurringInvoiceRules.first(where: { $0.id == "rinv-test-1" })?.nextDueDate == "2026-10-01",
               "rule advances past the generated occurrence")
        expect(empty.setRecurringInvoiceActive(id: "rinv-test-1", isActive: false), "plan pauses")
        expect(empty.runRecurringInvoiceGeneration(today: "2026-12-01") == false, "paused plan generates nothing")
        expect(empty.setRecurringInvoiceActive(id: "rinv-test-1", isActive: true, today: "2026-12-01"), "plan resumes")
        expect(empty.recurringInvoiceRules.first(where: { $0.id == "rinv-test-1" })?.nextDueDate == "2027-01-01",
               "resume fast-forwards past elapsed periods without billing them")
        expect(empty.deleteRecurringInvoice(id: "rinv-test-1"), "plan deletes")
        expect(empty.invoices.count == prePlanCount + 1, "generated invoices survive rule deletion")

        // Task 10.06 (N6) — `inv_`/outreach tap routing fails closed before an
        // exact-owner binding exists, resolves an existing invoice for the
        // verified owner, and fails closed again for a record that isn't
        // there. `requestInvoiceReminderReview` is the same method
        // `TradeReadyNativeApp`'s `openOwnedRoute` calls for a decoded
        // `.invoiceReminder` notification payload.
        empty.selectedTab = .today
        empty.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: false)
        expect(empty.selectedTab == .today,
               "invoice reminder tap is inert before an exact-owner workspace is bound")
        empty.scheduleBookingTestSeedSignedInOwner(subject: "user-10.06", binding: "bind-10.06")
        empty.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: false)
        expect(empty.selectedTab == .invoices && empty.deepLinkedInvoiceID == invoice.id
               && empty.deepLinkedOutreachInvoiceID == nil,
               "plain reminder tap routes to the exact-owner invoice without opening outreach")
        expect(empty.consumeOutreachDeepLink(invoiceID: invoice.id) == false,
               "plain reminder tap never arms the outreach sheet")
        empty.selectedTab = .today
        empty.deepLinkedInvoiceID = nil
        empty.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: true)
        expect(empty.selectedTab == .invoices && empty.deepLinkedInvoiceID == invoice.id
               && empty.deepLinkedOutreachInvoiceID == invoice.id,
               "auto-outreach tap routes to the invoice and arms the outreach sheet")
        expect(empty.consumeOutreachDeepLink(invoiceID: invoice.id),
               "auto-outreach tap opens the outreach review exactly once")
        expect(empty.consumeOutreachDeepLink(invoiceID: invoice.id) == false,
               "the outreach arm is one-shot — it never re-fires or auto-sends on its own")
        empty.selectedTab = .today
        empty.deepLinkedInvoiceID = nil
        empty.requestInvoiceReminderReview(invoiceID: "no-such-invoice", opensOutreach: true)
        expect(empty.selectedTab == .today && empty.deepLinkedInvoiceID == nil
               && empty.deepLinkedOutreachInvoiceID == nil,
               "a missing invoice fails closed instead of inventing a destination")
        empty.scheduleBookingTestClearOwner()
        empty.requestInvoiceReminderReview(invoiceID: invoice.id, opensOutreach: false)
        expect(empty.selectedTab == .today && empty.deepLinkedInvoiceID == nil,
               "signing out revokes routing even for a previously-valid invoice ID")

        let reloaded = AppStore(fileURL: url, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(reloaded.customers.first?.name == customer.name, "customer reload projection")
        expect(reloaded.jobs.first?.title == job.title, "job reload projection")
        expect(reloaded.settings.businessName == "Canonical Plumbing", "settings binding persists through canonical merge")

        // Phase 7.06 — provider settings round-trip instead of clobbering.
        empty.settings.paymentProvider = "paypal"
        empty.settings.setProviderKey("acme-shop", for: "paypal")
        let providerReloaded = AppStore(fileURL: url, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(providerReloaded.settings.paymentProvider == "paypal", "selected provider persists")
        expect(providerReloaded.settings.providerKey(for: "paypal") == "acme-shop", "per-provider key persists")
        expect(providerReloaded.settings.providerKey() == "acme-shop", "default key resolves the active provider")

        // Phase 7.06 — offline link generation persists against its amount.
        let linkInvoice = Invoice(customer: "Link Customer", number: "INV-LINK", amount: 400)
        empty.upsert(linkInvoice)
        let storedLinkID = empty.invoices.first(where: { $0.number == "INV-LINK" })?.id ?? linkInvoice.id
        let offlineURL = try await empty.generateInvoicePaymentLink(
            invoiceID: storedLinkID, amount: 400, provider: .paypal)
        expect(offlineURL.absoluteString == "https://paypal.me/acme-shop/400.00", "offline provider link mints from settings")
        let cachedURL = try await empty.generateInvoicePaymentLink(
            invoiceID: storedLinkID, amount: 400, provider: .paypal)
        expect(cachedURL == offlineURL, "amount-valid cached link is reused")
        let partialURL = try await empty.generateInvoicePaymentLink(
            invoiceID: storedLinkID, amount: 200, provider: .paypal)
        expect(partialURL.absoluteString == "https://paypal.me/acme-shop/200.00", "changed amount mints fresh, never reuses stale")

        let canonicalCustomer: Canonical.Customer = try field("customer")
        let canonicalSettings: Canonical.Settings = try field("settings")
        var preservedSnapshot = Canonical.Snapshot(
            payload: .init(customers: [canonicalCustomer], settings: canonicalSettings,
                           unknownFields: ["futurePayload": .bool(true)]),
            unknownFields: ["futureEnvelope": .string("retained")]
        )
        preservedSnapshot.schemaVersion = Canonical.Snapshot.currentSchemaVersion
        try Canonical.SnapshotCodec.encode(preservedSnapshot).write(to: url, options: .atomic)

        let preservingStore = AppStore(fileURL: url, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        var editedCustomer = preservingStore.customers[0]
        editedCustomer.name = "Edited without loss"
        preservingStore.upsert(editedCustomer)
        let afterEdit = try Canonical.SnapshotCodec.decode(Data(contentsOf: url))
        expect(afterEdit.payload.customers?.first?.name == "Edited without loss", "UI edit reaches canonical record")
        expect(afterEdit.payload.customers?.first?.portal?.token == canonicalCustomer.portal?.token,
               "canonical-only nested customer data survives edit")
        expect(afterEdit.payload.customers?.first?.preservation.unknownFields == canonicalCustomer.preservation.unknownFields,
               "unknown customer fields survive edit")
        expect(afterEdit.payload.unknownFields["futurePayload"] == .bool(true), "unknown payload field survives")
        expect(afterEdit.unknownFields["futureEnvelope"] == .string("retained"), "unknown envelope field survives")

        let legacyURL = directory.appendingPathComponent("legacy-store.json")
        let legacy = LegacyNativeStoreSnapshot(
            customers: [customer], jobs: [job], invoices: [invoice], expenses: [expense],
            settings: BusinessSettings(businessName: "Legacy Native")
        )
        let legacyEncoder = JSONEncoder(); legacyEncoder.dateEncodingStrategy = .iso8601
        let encodedLegacy = try legacyEncoder.encode(legacy)
        try encodedLegacy.write(to: legacyURL, options: .atomic)
        let upgraded = AppStore(fileURL: legacyURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(upgraded.settings.businessName == "Legacy Native", "legacy native snapshot loads")
        let upgradedBytes = try Data(contentsOf: legacyURL)
        let upgradedSnapshot = try Canonical.SnapshotCodec.decode(upgradedBytes)
        expect(upgradedSnapshot.schemaVersion == 1, "legacy native snapshot upgrades on disk")
        let legacyBackupURL = legacyURL.deletingLastPathComponent()
            .appendingPathComponent("LegacyBackups", isDirectory: true)
            .appendingPathComponent("legacy-native-snapshot-to-v1.json")
        expect((try? Data(contentsOf: legacyBackupURL)) == encodedLegacy, "legacy native source is retained byte-for-byte")
        let migrationJournal = Canonical.MigrationJournal(
            fileURL: legacyURL.deletingLastPathComponent().appendingPathComponent("migration-journal.json")
        )
        let legacyMigrationComplete = try migrationJournal.isComplete(.legacyNativeSnapshot)
        expect(legacyMigrationComplete, "legacy native migration is journaled complete")

        let recoveryURL = directory.appendingPathComponent("recovery-store.json")
        let recoveryStore = AppStore(fileURL: recoveryURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let retainedCustomer = Customer(name: "Retained Customer")
        recoveryStore.upsert(retainedCustomer)
        recoveryStore.upsert(Customer(name: "Lost Latest Customer"))
        try Data("corrupt-current-snapshot".utf8).write(to: recoveryURL, options: .atomic)
        let recoveredStore = AppStore(fileURL: recoveryURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(recoveredStore.customers.map(\.id) == [retainedCustomer.id],
               "AppStore recovers the last-known-good snapshot")
        expect(recoveredStore.migrationMessage?.contains("Recovered local data") == true,
               "AppStore reports backup recovery")
        let diagnostics = try recoveredStore.persistenceDiagnostics()
        expect(diagnostics.snapshotStatus == .primary && diagnostics.counts.customers == 1,
               "AppStore exposes privacy-safe persistence diagnostics")
        let supportReportURL = try recoveredStore.createPersistenceSupportReport(appVersion: "test-version")
        let supportReportBytes = try Data(contentsOf: supportReportURL)
        let expectedSupportReportBytes = try diagnostics.encodedSupportReport(appVersion: "test-version")
        expect(supportReportURL.lastPathComponent == "tradeready-support-report.json",
               "AppStore prepares a predictably named support attachment")
        // Phase 12 (12.02; 12.06: v4): the v4 report nests the closed v2 diagnostics
        // report under `persistence`, unchanged.
        let supportReportObject = try JSONSerialization.jsonObject(with: supportReportBytes) as? [String: Any]
        let expectedPersistence = try JSONSerialization.jsonObject(with: expectedSupportReportBytes) as? NSDictionary
        expect(supportReportObject?["reportSchemaVersion"] as? Int == 4
               && (supportReportObject?["persistence"] as? NSDictionary).map { $0 == expectedPersistence } == true,
               "AppStore support attachment uses the closed diagnostics schema")
        let supportReportText = String(decoding: supportReportBytes, as: UTF8.self)
        expect(!supportReportText.contains(retainedCustomer.name) && !supportReportText.contains(retainedCustomer.id),
               "AppStore support attachment excludes customer records and identifiers")

        let unreadableURL = directory.appendingPathComponent("unreadable-store.json")
        let unreadableBytes = Data("unrecognized-private-source".utf8)
        try unreadableBytes.write(to: unreadableURL, options: .atomic)
        let unreadableStore = AppStore(fileURL: unreadableURL, seedIfMissing: true, secureSettingsStore: hostTestSecureSettingsStore())
        expect(unreadableStore.customers.isEmpty, "unreadable store is not replaced with demo projections")
        expect(!unreadableStore.upsert(Customer(name: "Must Not Replace Recovery Source")),
               "customer save reports a blocked unreadable snapshot")
        let retainedUnreadableBytes = try Data(contentsOf: unreadableURL)
        expect(retainedUnreadableBytes == unreadableBytes,
               "unreadable source remains recoverable even after an attempted edit")

        let projectionDirectory = directory.appendingPathComponent("projection-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: projectionDirectory, withIntermediateDirectories: true)
        let projectionURL = projectionDirectory.appendingPathComponent("store.json")
        var invalidProjectionCustomer = canonicalCustomer
        invalidProjectionCustomer.createdAt = "not-a-date"
        let invalidProjectionSnapshot = Canonical.Snapshot(
            payload: .init(customers: [invalidProjectionCustomer])
        )
        let invalidProjectionBytes = try Canonical.SnapshotCodec.encode(invalidProjectionSnapshot)
        try invalidProjectionBytes.write(to: projectionURL, options: .atomic)
        let projectionBlockedStore = AppStore(fileURL: projectionURL, seedIfMissing: true, secureSettingsStore: hostTestSecureSettingsStore())
        expect(projectionBlockedStore.customers.isEmpty,
               "unprojectable canonical records remain hidden")
        expect(projectionBlockedStore.migrationMessage?.contains("could not be projected") == true,
               "canonical projection failures are not mislabeled as legacy decoding failures")
        expect(!projectionBlockedStore.upsert(Customer(name: "Must Not Replace Unprojectable Source")),
               "customer save reports a blocked unprojectable snapshot")
        let retainedProjectionBytes = try Data(contentsOf: projectionURL)
        expect(retainedProjectionBytes == invalidProjectionBytes,
               "unprojectable canonical source remains byte-for-byte intact")
        let falseLegacyBackup = projectionDirectory
            .appendingPathComponent("LegacyBackups", isDirectory: true)
            .appendingPathComponent("legacy-native-snapshot-to-v1.json")
        expect(!FileManager.default.fileExists(atPath: falseLegacyBackup.path),
               "canonical projection failures never enter the legacy migration path")

        let futureURL = directory.appendingPathComponent("future-store.json")
        let futureSnapshot = Canonical.Snapshot(
            schemaVersion: Canonical.Snapshot.currentSchemaVersion + 1,
            payload: .init(unknownFields: ["futurePayload": .string("retain")])
        )
        let futureBytes = try Canonical.SnapshotCodec.encode(futureSnapshot)
        try futureBytes.write(to: futureURL, options: .atomic)
        let futureStore = AppStore(fileURL: futureURL, seedIfMissing: true, secureSettingsStore: hostTestSecureSettingsStore())
        expect(!futureStore.upsert(Customer(name: "Must Not Downgrade")),
               "customer save reports a blocked future snapshot")
        let retainedFutureBytes = try Data(contentsOf: futureURL)
        expect(retainedFutureBytes == futureBytes,
               "newer snapshot schema is readable but cannot be overwritten")

        let queueDirectory = directory.appendingPathComponent("QueueBehaviour", isDirectory: true)
        let queueURL = queueDirectory.appendingPathComponent("store.json")
        let queueStore = AppStore(
            fileURL: queueURL,
            seedIfMissing: false,
            subscriptionService: StoreSubscriptionServiceStub(),
            secureSettingsStore: hostTestSecureSettingsStore()
        )
        let queuedCustomer = Customer(name: "Queue Customer")
        queueStore.upsert(queuedCustomer)
        var editedQueuedCustomer = queuedCustomer
        editedQueuedCustomer.name = "Queue Customer v2"
        queueStore.upsert(editedQueuedCustomer)
        let afterReupsert = pendingMutations(queueURL).filter {
            $0.table == "customers" && $0.recordId == queuedCustomer.id
        }
        expect(afterReupsert.count == 1 && afterReupsert.first?.op == .upsert,
               "re-saving the same record dedups to a single queued upsert")

        let archiveDate = ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z")!
        queueStore.setCustomerArchived(id: queuedCustomer.id, archived: true, on: archiveDate)
        let afterArchive = pendingMutations(queueURL).filter {
            $0.table == "customers" && $0.recordId == queuedCustomer.id
        }
        let archivedPayload: Canonical.Customer? = afterArchive.first.flatMap { item in
            guard let payload = item.payload,
                  let data = try? JSONEncoder().encode(payload)
            else { return nil }
            return try? JSONDecoder().decode(Canonical.Customer.self, from: data)
        }
        expect(queueStore.customers.first?.archivedAt == "2026-08-17",
               "archiving a customer updates the local canonical projection")
        expect(afterArchive.count == 1 && archivedPayload?.archivedAt == "2026-08-17",
               "archiving replaces the queued upsert with the latest canonical payload")

        queueStore.setCustomerArchived(id: queuedCustomer.id, archived: false, on: archiveDate)
        let afterRestore = pendingMutations(queueURL).filter {
            $0.table == "customers" && $0.recordId == queuedCustomer.id
        }
        let restoredPayload: Canonical.Customer? = afterRestore.first.flatMap { item in
            guard let payload = item.payload,
                  let data = try? JSONEncoder().encode(payload)
            else { return nil }
            return try? JSONDecoder().decode(Canonical.Customer.self, from: data)
        }
        expect(queueStore.customers.first?.archivedAt == nil,
               "restoring a customer clears the local archive marker")
        expect(afterRestore.count == 1 && restoredPayload?.archivedAt == nil,
               "restoring replaces the queued archive with the current canonical payload")

        let queuedJob = Job(title: "Archive-safe job")
        expect(queueStore.upsert(queuedJob), "job save reports a durable local commit")
        expect(queueStore.setJobArchived(id: queuedJob.id, archived: true, on: archiveDate),
               "job archive reports a durable local commit")
        expect(queueStore.jobs.first(where: { $0.id == queuedJob.id })?.archivedAt == "2026-08-17",
               "archiving a job updates its local canonical projection")
        let archivedJobItem = pendingMutations(queueURL).first {
            $0.table == "jobs" && $0.recordId == queuedJob.id
        }
        let archivedJobPayload: Canonical.Job? = archivedJobItem.flatMap { item in
            guard let payload = item.payload,
                  let data = try? JSONEncoder().encode(payload)
            else { return nil }
            return try? JSONDecoder().decode(Canonical.Job.self, from: data)
        }
        expect(archivedJobPayload?.archivedAt == "2026-08-17",
               "job archive replaces the pending upsert with the latest canonical payload")
        expect(queueStore.setJobArchived(id: queuedJob.id, archived: false, on: archiveDate),
               "job restore reports a durable local commit")
        expect(queueStore.jobs.first(where: { $0.id == queuedJob.id })?.archivedAt == nil,
               "restoring a job clears its local archive marker")

        let estimateCustomer = Customer(
            name: "Estimate Customer",
            email: "estimate@example.test",
            phone: "555-0199",
            address: "10 Customer Way"
        )
        queueStore.upsert(estimateCustomer)
        queueStore.settings.businessName = "Queue Plumbing"
        queueStore.settings.contactName = "Quinn"
        queueStore.settings.phone = "555-0100"
        queueStore.settings.email = "hello@queue.example"
        queueStore.settings.address = "20 Trade Ave"
        let estimateJob = Job(
            customerId: estimateCustomer.id,
            customerName: estimateCustomer.name,
            title: "Reviewed estimate",
            status: .lead,
            estimateTotal: 250,
            laborHours: 2,
            laborRate: 100
        )
        expect(queueStore.upsert(estimateJob), "estimate fixture saves durably")
        let review = queueStore.estimateReviewDraft(jobID: estimateJob.id)
        expect(review?.snapshot.businessName == "Queue Plumbing"
               && review?.snapshot.customerName == "Estimate Customer"
               && review?.customerEmail == "estimate@example.test"
               && review?.customerAddress == "10 Customer Way"
               && review?.businessEmail == "hello@queue.example"
               && review?.businessAddress == "20 Trade Ave",
               "estimate review freezes canonical pricing and complete PDF contact fields")
        let estimateSentDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 8, day: 18)
        )!
        var estimateRatingWins: [NativeAppRatingWin] = []
        queueStore.onAppRatingWin = { estimateRatingWins.append($0) }
        expect(queueStore.markEstimateSent(id: estimateJob.id, from: .lead, on: estimateSentDate),
               "reviewed lead estimate stamps sent through a durable canonical commit")
        let sentEstimate = try Canonical.SnapshotRepository(primaryURL: queueURL)
            .load()?.snapshot.payload.jobs?.first { $0.id == estimateJob.id }
        expect(sentEstimate?.status == JobStatus.estimateSent.rawValue
               && sentEstimate?.estimateSentAt == "2026-08-18",
               "sent estimate persists the exact status and local follow-up date")
        expect(!queueStore.markEstimateSent(id: estimateJob.id, from: .lead, on: estimateSentDate),
               "stale estimate review cannot overwrite a newer job status")
        expect(estimateRatingWins == [.estimateSent],
               "a sent estimate is one rating win; the refused stale send is none")
        let sentMutation = pendingMutations(queueURL).first {
            $0.table == "jobs" && $0.recordId == estimateJob.id
        }
        let sentPayload: Canonical.Job? = sentMutation.flatMap { item in
            guard let payload = item.payload,
                  let data = try? JSONEncoder().encode(payload)
            else { return nil }
            return try? JSONDecoder().decode(Canonical.Job.self, from: data)
        }
        expect(sentPayload?.status == JobStatus.estimateSent.rawValue
               && sentPayload?.estimateSentAt == "2026-08-18",
               "sent estimate replaces its queued upsert with the committed canonical payload")

        let deliveredJob = Job(
            customerId: estimateCustomer.id,
            customerName: estimateCustomer.name,
            title: "Composer-confirmed estimate",
            status: .lead,
            estimateTotal: 325,
            laborHours: 2.5,
            laborRate: 100
        )
        expect(queueStore.upsert(deliveredJob), "composer delivery fixture saves durably")
        guard let deliveredReview = queueStore.estimateReviewDraft(jobID: deliveredJob.id) else {
            expect(false, "composer delivery fixture produces a frozen review")
            throw StoreTestError.missingFixture
        }
        let deliveredDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 8, day: 19)
        )!
        expect(queueStore.recordEstimateDelivery(for: deliveredReview, on: deliveredDate) == .recorded,
               "composer-confirmed delivery commits the reviewed lead as sent")
        expect(queueStore.jobs.first(where: { $0.id == deliveredJob.id })?.status == .estimateSent,
               "composer-confirmed delivery publishes estimate-sent status")
        guard let resendReview = queueStore.estimateReviewDraft(jobID: deliveredJob.id) else {
            expect(false, "sent estimate remains reviewable for resend")
            throw StoreTestError.missingFixture
        }
        let resentDate = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: 8, day: 20)
        )!
        expect(queueStore.recordEstimateDelivery(for: resendReview, on: resentDate) == .recorded,
               "a composer-confirmed resend re-arms the delivery date")
        let resentCanonical = try Canonical.SnapshotRepository(primaryURL: queueURL)
            .load()?.snapshot.payload.jobs?.first { $0.id == deliveredJob.id }
        expect(resentCanonical?.estimateSentAt == "2026-08-20",
               "resend stores the latest confirmed delivery date")

        let staleDeliveryJob = Job(
            customerId: estimateCustomer.id,
            customerName: estimateCustomer.name,
            title: "Stale composer estimate",
            status: .lead,
            estimateTotal: 400,
            laborHours: 4,
            laborRate: 100
        )
        expect(queueStore.upsert(staleDeliveryJob), "stale composer fixture saves durably")
        guard let staleDeliveryReview = queueStore.estimateReviewDraft(jobID: staleDeliveryJob.id),
              var changedDeliveryJob = queueStore.jobs.first(where: { $0.id == staleDeliveryJob.id })
        else {
            expect(false, "stale composer fixture produces a review and current job")
            throw StoreTestError.missingFixture
        }
        changedDeliveryJob.estimateTotal = 450
        expect(queueStore.upsert(changedDeliveryJob), "newer estimate pricing saves while composer is open")
        expect(queueStore.recordEstimateDelivery(for: staleDeliveryReview, on: deliveredDate) == .preservedNewerState,
               "delayed composer callback refuses to claim newer pricing was delivered")
        expect(queueStore.jobs.first(where: { $0.id == staleDeliveryJob.id })?.status == .lead,
               "stale delivery callback preserves the newer canonical job status")

        let revisionURL = directory.appendingPathComponent("EstimateRevision/store.json")
        let revisionSeedStore = AppStore(fileURL: revisionURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let revisionCustomer = Customer(name: "Revision Customer", email: "revision@example.com")
        let revisionJob = Job(
            customerId: revisionCustomer.id,
            customerName: revisionCustomer.name,
            title: "Declined estimate",
            status: .lead,
            estimateTotal: 500,
            laborHours: 5,
            laborRate: 100
        )
        expect(revisionSeedStore.upsert(revisionCustomer), "revision customer saves")
        expect(revisionSeedStore.upsert(revisionJob), "revision job saves")
        guard let declinedReview = revisionSeedStore.estimateReviewDraft(jobID: revisionJob.id),
              var revisionSnapshot = try Canonical.SnapshotRepository(primaryURL: revisionURL).load()?.snapshot,
              let revisionIndex = revisionSnapshot.payload.jobs?.firstIndex(where: { $0.id == revisionJob.id })
        else {
            expect(false, "revision fixture produces a canonical reviewed estimate")
            throw StoreTestError.missingFixture
        }
        var declinedArtifact = try CanonicalUIAdapters.estimateApprovalAfterLink(
            existing: nil,
            snapshot: declinedReview.snapshot,
            token: String(repeating: "r", count: 48),
            sentAt: "2026-09-16T12:00:00.000Z"
        )
        declinedArtifact.decision = "declined"
        declinedArtifact.consentAt = "2026-09-16T13:00:00.000Z"
        declinedArtifact.declineReason = "Please reduce the scope"
        revisionSnapshot.payload.jobs?[revisionIndex].approval = nil
        revisionSnapshot.payload.jobs?[revisionIndex].approvalHistory = [declinedArtifact]
        revisionSnapshot.payload.jobs?[revisionIndex].status = JobStatus.lead.rawValue
        revisionSnapshot.payload.jobs?[revisionIndex].estimateSentAt = nil
        try Canonical.SnapshotRepository(primaryURL: revisionURL).save(revisionSnapshot)

        let revisionStore = AppStore(fileURL: revisionURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        expect(revisionStore.estimateReviewDraft(jobID: revisionJob.id) == nil,
               "a reset declined estimate cannot be resent before its customer-facing snapshot changes")
        guard var revisedPricing = revisionStore.jobPricingDraft(jobID: revisionJob.id) else {
            expect(false, "reset declined estimate remains editable")
            throw StoreTestError.missingFixture
        }
        revisedPricing.laborHours = 4
        expect(revisionStore.saveJobPricing(revisedPricing),
               "revised declined pricing saves through the canonical merge")
        expect(revisionStore.estimateReviewDraft(jobID: revisionJob.id) != nil,
               "a materially revised customer snapshot becomes eligible for a new send")
        let revisedCanonical = try Canonical.SnapshotRepository(primaryURL: revisionURL)
            .load()?.snapshot.payload.jobs?.first { $0.id == revisionJob.id }
        expect(revisedCanonical?.approvalHistory?.first?.declineReason == "Please reduce the scope",
               "pricing revision preserves the archived customer decision exactly")

        let lifecycleJob = Job(title: "Lifecycle job", status: .estimateSent)
        expect(queueStore.upsert(lifecycleJob), "lifecycle fixture saves durably")
        expect(queueStore.advanceJobLifecycle(id: lifecycleJob.id, from: .estimateSent)
               && queueStore.jobs.first(where: { $0.id == lifecycleJob.id })?.status == .approved,
               "estimate-sent job advances exactly one step to approved")
        expect(!queueStore.advanceJobLifecycle(id: lifecycleJob.id, from: .estimateSent)
               && queueStore.jobs.first(where: { $0.id == lifecycleJob.id })?.status == .approved,
               "stale lifecycle action cannot overwrite a newer status")
        if var scheduledJob = queueStore.jobs.first(where: { $0.id == lifecycleJob.id }) {
            scheduledJob.status = .scheduled
            expect(queueStore.upsert(scheduledJob), "scheduled lifecycle fixture saves durably")
            expect(queueStore.advanceJobLifecycle(id: lifecycleJob.id, from: .scheduled)
                   && queueStore.jobs.first(where: { $0.id == lifecycleJob.id })?.status == .inProgress,
                   "scheduled job advances exactly one step to in progress")
            expect(queueStore.advanceJobLifecycle(id: lifecycleJob.id, from: .inProgress)
                   && queueStore.jobs.first(where: { $0.id == lifecycleJob.id })?.status == .complete,
                   "in-progress job advances exactly one step to complete")
            expect(!queueStore.advanceJobLifecycle(id: lifecycleJob.id, from: .complete),
                   "completion cannot skip the dependent invoice workflow")
        } else {
            expect(false, "saved lifecycle job remains available")
        }

        let autoInvoiceURL = directory.appendingPathComponent("AutoInvoice/store.json")
        let autoInvoiceSeed = AppStore(fileURL: autoInvoiceURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let autoCustomer = Customer(name: "Auto Customer", email: "auto@example.test", phone: "555-0110")
        let autoJob = Job(
            customerId: autoCustomer.id,
            customerName: autoCustomer.name,
            title: "Automatically billed work",
            status: .inProgress,
            estimateTotal: 966,
            laborHours: 4,
            laborRate: 85
        )
        expect(autoInvoiceSeed.upsert(autoCustomer), "auto-invoice customer fixture saves")
        expect(autoInvoiceSeed.upsert(autoJob), "auto-invoice job fixture saves")
        autoInvoiceSeed.settings.invoicePrefix = "AUTO-"
        autoInvoiceSeed.settings.autoInvoiceOnComplete = true

        var autoSnapshot = try Canonical.SnapshotRepository(primaryURL: autoInvoiceURL).load()!.snapshot
        let openSessionData = #"{"start":"2026-09-19T08:00:00.000Z","end":null}"#.data(using: .utf8)!
        let openSession = try JSONDecoder().decode(Canonical.TimeSession.self, from: openSessionData)
        let autoJobIndex = autoSnapshot.payload.jobs!.firstIndex { $0.id == autoJob.id }!
        autoSnapshot.payload.jobs![autoJobIndex].timeSessions = [openSession]
        // The native delivery foundation stamps the RN-compatible request gate;
        // network delivery remains post-commit and best-effort.
        autoSnapshot.payload.settings?.autoEmailInvoiceOnComplete = true
        try Canonical.SnapshotRepository(primaryURL: autoInvoiceURL).save(autoSnapshot)

        let autoInvoiceStore = AppStore(fileURL: autoInvoiceURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        let autoCompleteDate = ISO8601DateFormatter().date(from: "2026-09-19T10:00:00Z")!
        let autoOutcome = autoInvoiceStore.completeJob(id: autoJob.id, on: autoCompleteDate)
        guard case .autoInvoiced(let autoInvoiceID) = autoOutcome else {
            expect(false, "eligible completion atomically creates an invoice")
            throw StoreTestError.missingFixture
        }
        expect(autoInvoiceStore.jobs.first(where: { $0.id == autoJob.id })?.status == .invoiced
               && autoInvoiceStore.jobs.first(where: { $0.id == autoJob.id })?.invoiceId == autoInvoiceID,
               "automatic completion advances the job directly to its linked invoice")
        let autoCreatedInvoice = try Canonical.SnapshotRepository(primaryURL: autoInvoiceURL)
            .load()?.snapshot.payload.invoices?.first { $0.id == autoInvoiceID }
        let autoCompletedJob = try Canonical.SnapshotRepository(primaryURL: autoInvoiceURL)
            .load()?.snapshot.payload.jobs?.first { $0.id == autoJob.id }
        expect(autoCreatedInvoice?.number == "AUTO-0001"
               && autoCreatedInvoice?.amount == 796
               && autoCreatedInvoice?.jobId == autoJob.id,
               "automatic invoice uses shared numbering, tracked-time math, and job linkage")
        expect(autoCreatedInvoice?.autoEmailRequestedAt != nil,
               "automatic creation records the gated unattended delivery request")
        expect(autoCompletedJob?.timeSessions?.last?.end == "2026-09-19T10:00:00.000Z",
               "automatic completion clocks out the final running session before billing")
        expect(autoInvoiceStore.completeJob(id: autoJob.id, on: autoCompleteDate) == .failed
               && autoInvoiceStore.invoices.filter { $0.id == autoInvoiceID }.count == 1,
               "a stale completion retry cannot create a duplicate invoice")
        let autoQueueURL = autoInvoiceURL.deletingLastPathComponent().appendingPathComponent("mutation-queue.json")
        let autoMutations = pendingMutations(autoQueueURL)
        expect(autoMutations.contains { $0.table == "jobs" && $0.recordId == autoJob.id }
               && autoMutations.contains { $0.table == "invoices" && $0.recordId == autoInvoiceID },
               "automatic completion queues the atomic job and invoice result")

        let missingCustomerURL = directory.appendingPathComponent("AutoInvoiceMissingCustomer/store.json")
        let missingCustomerStore = AppStore(fileURL: missingCustomerURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        missingCustomerStore.settings.autoInvoiceOnComplete = true
        let unlinkedJob = Job(
            customerName: "New Auto Customer",
            title: "Unlinked customer work",
            status: .inProgress,
            estimateTotal: 125
        )
        expect(missingCustomerStore.upsert(unlinkedJob), "unlinked auto-invoice fixture saves")
        let unlinkedOutcome = missingCustomerStore.completeJob(id: unlinkedJob.id, on: autoCompleteDate)
        guard case .autoInvoiced(let unlinkedInvoiceID) = unlinkedOutcome else {
            expect(false, "eligible unlinked customer auto-invoices")
            throw StoreTestError.missingFixture
        }
        let createdCustomer = missingCustomerStore.customers.first { $0.name == "New Auto Customer" }
        expect(createdCustomer != nil
               && missingCustomerStore.invoices.first(where: { $0.id == unlinkedInvoiceID })?.customerId == createdCustomer?.id,
               "automatic completion creates and links the missing customer through canonical storage")

        let mergeWinner = Customer(name: "Keep Me", email: "keep@example.com")
        let mergeLoser = Customer(name: "Merge Me", phone: "555-0100", notes: "Side gate")
        let mergeJob = Job(
            customerId: mergeLoser.id,
            customerName: mergeLoser.name,
            title: "Linked job"
        )
        let mergeInvoice = Invoice(
            customerId: mergeLoser.id,
            customer: mergeLoser.name,
            number: "INV-MERGE",
            amount: 125
        )
        queueStore.upsert(mergeWinner)
        queueStore.upsert(mergeLoser)
        queueStore.upsert(mergeJob)
        queueStore.upsert(mergeInvoice)
        expect(queueStore.mergeCustomer(loserID: mergeLoser.id, into: mergeWinner.id),
               "AppStore commits a valid customer merge")
        expect(queueStore.customers.contains(where: { $0.id == mergeWinner.id && $0.phone == mergeLoser.phone })
               && !queueStore.customers.contains(where: { $0.id == mergeLoser.id }),
               "AppStore publishes the merged customer projection")
        expect(queueStore.jobs.first(where: { $0.id == mergeJob.id })?.customerId == mergeWinner.id
               && queueStore.invoices.first(where: { $0.id == mergeInvoice.id })?.customerId == mergeWinner.id,
               "AppStore publishes re-pointed job and invoice projections")
        let mergeQueue = pendingMutations(queueURL)
        expect(mergeQueue.first(where: { $0.table == "customers" && $0.recordId == mergeLoser.id })?.op == .delete,
               "AppStore queues the merged-away customer tombstone")
        expect(mergeQueue.first(where: { $0.table == "jobs" && $0.recordId == mergeJob.id })?.op == .upsert
               && mergeQueue.first(where: { $0.table == "invoices" && $0.recordId == mergeInvoice.id })?.op == .upsert,
               "AppStore queues every re-pointed dependent record")
        expect(queueStore.pendingCustomerMergeUndo?.loserName == mergeLoser.name,
               "AppStore exposes a short-lived merge undo")

        queueStore.undoCustomerMerge()
        expect(queueStore.customers.contains(where: { $0.id == mergeLoser.id })
               && queueStore.customers.first(where: { $0.id == mergeWinner.id })?.phone.isEmpty == true,
               "merge undo restores both original customer records")
        expect(queueStore.jobs.first(where: { $0.id == mergeJob.id })?.customerId == mergeLoser.id
               && queueStore.invoices.first(where: { $0.id == mergeInvoice.id })?.customerId == mergeLoser.id,
               "merge undo restores original dependent references")
        let undoQueue = pendingMutations(queueURL)
        expect(undoQueue.first(where: { $0.table == "customers" && $0.recordId == mergeLoser.id })?.op == .upsert,
               "merge undo replaces a pending or synced tombstone with the original customer upsert")
        expect(queueStore.pendingCustomerMergeUndo == nil,
               "successful merge undo consumes its token exactly once")

        let undoableJob = Job(
            customerId: mergeWinner.id,
            customerName: mergeWinner.name,
            title: "Undoable job"
        )
        queueStore.upsert(undoableJob)
        expect(queueStore.deleteJob(id: undoableJob.id),
               "AppStore commits an existing job deletion")
        expect(!queueStore.jobs.contains(where: { $0.id == undoableJob.id })
               && queueStore.pendingRecordDeleteUndo?.recordID == undoableJob.id,
               "job deletion publishes a short-lived exact-record undo")
        expect(pendingMutations(queueURL).first(where: {
            $0.table == "jobs" && $0.recordId == undoableJob.id
        })?.op == .delete,
               "job deletion replaces its queued upsert with a tombstone")
        queueStore.undoRecordDeletion()
        expect(queueStore.jobs.contains(where: {
            $0.id == undoableJob.id && $0.title == undoableJob.title
        }), "job delete undo restores the canonical projection")
        expect(pendingMutations(queueURL).first(where: {
            $0.table == "jobs" && $0.recordId == undoableJob.id
        })?.op == .upsert,
               "job delete undo replaces the pending tombstone with an upsert")

        let undoableInvoice = Invoice(
            customerId: mergeWinner.id,
            customer: mergeWinner.name,
            number: "INV-UNDO",
            amount: 300,
            payments: [Payment(id: "payment-undo", amount: 75, method: "Cash")]
        )
        queueStore.upsert(undoableInvoice)
        expect(queueStore.deleteInvoice(id: undoableInvoice.id),
               "AppStore commits an existing invoice deletion")
        queueStore.undoRecordDeletion()
        expect(queueStore.invoices.first(where: {
            $0.id == undoableInvoice.id
        })?.payments.first?.id == "payment-undo",
               "invoice delete undo restores its complete payment history")
        expect(pendingMutations(queueURL).first(where: {
            $0.table == "invoices" && $0.recordId == undoableInvoice.id
        })?.op == .upsert,
               "invoice delete undo replaces the pending tombstone with an upsert")

        let conflictedUndoJob = Job(title: "Original before deletion")
        queueStore.upsert(conflictedUndoJob)
        expect(queueStore.deleteJob(id: conflictedUndoJob.id),
               "conflict fixture deletes before recreation")
        var recreatedJob = conflictedUndoJob
        recreatedJob.title = "Newer recreation"
        queueStore.upsert(recreatedJob)
        queueStore.undoRecordDeletion()
        expect(queueStore.jobs.first(where: { $0.id == conflictedUndoJob.id })?.title == "Newer recreation",
               "delete undo never overwrites a record recreated after deletion")
        expect(queueStore.pendingRecordDeleteUndo == nil,
               "conflicted delete undo consumes the stale token")

        expect(queueStore.deleteCustomer(id: queuedCustomer.id),
               "AppStore commits an existing customer deletion")
        let afterDelete = pendingMutations(queueURL).filter { $0.recordId == queuedCustomer.id }
        expect(afterDelete.count == 1 && afterDelete.first?.op == .delete,
               "deleting a record collapses its queued upsert into a single delete")
        expect(queueStore.pendingRecordDeleteUndo?.kind == .customer,
               "customer deletion exposes the shared exact-record undo")
        queueStore.undoRecordDeletion()
        expect(queueStore.customers.first(where: { $0.id == queuedCustomer.id })?.name == editedQueuedCustomer.name,
               "customer delete undo restores the exact canonical projection")
        expect(pendingMutations(queueURL).first(where: {
            $0.table == "customers" && $0.recordId == queuedCustomer.id
        })?.op == .upsert,
               "customer delete undo replaces the pending tombstone with an upsert")
        expect(!queueStore.deleteCustomer(id: "never-existed"),
               "deleting a missing customer fails closed")
        expect(pendingMutations(queueURL).allSatisfy { $0.recordId != "never-existed" },
               "deleting a record that never existed enqueues nothing")


        // MARK: - Phase 8 task 8.08 canonical integration (S3, S4, B2-B4, P1, P3)

        func decode08Job(_ json: String) -> Canonical.Job {
            try! JSONDecoder().decode(Canonical.Job.self, from: Data(json.utf8))
        }
        func decode08Request(_ json: String) -> Canonical.BookingRequest {
            try! JSONDecoder().decode(Canonical.BookingRequest.self, from: Data(json.utf8))
        }
        func decode08Customer(_ json: String) -> Canonical.Customer {
            try! JSONDecoder().decode(Canonical.Customer.self, from: Data(json.utf8))
        }
        func decode08Settings(_ json: String) -> Canonical.Settings {
            try! JSONDecoder().decode(Canonical.Settings.self, from: Data(json.utf8))
        }
        let settings08Base = """
        {"businessName":"Ada Electric","contactName":"Ada","phone":"p","email":"e","address":"a",
         "trade":"electrical","laborRate":95,"materialMarkup":25,"overheadPercent":10,
         "marginPercent":30,"minimumJobFee":0,"travelFeePerMile":0,"emergencyMultiplier":1,
         "rules":[],"paymentNotes":"","provider":"none"}
        """
        func settings08(schedule: String? = nil, bookingLink: String? = nil) -> Canonical.Settings {
            var json = String(settings08Base.dropLast())
            if let schedule { json += ",\"schedule\":\(schedule)" }
            if let bookingLink { json += ",\"bookingLink\":\(bookingLink)" }
            json += "}"
            return decode08Settings(json)
        }
        func job08(id: String, status: String = "approved", date: String? = "2026-09-22",
                   start: String? = "09:00", end: String? = "10:00") -> Canonical.Job {
            var json = """
            {"id":"\(id)","customerId":"c1","customerName":"Nora","title":"Panel swap",
             "description":"d","status":"\(status)","address":"1 Main",
             "estimateTotal":400,"laborHours":2,"laborRate":95,"materials":[],
             "materialMarkup":25,"overhead":10,"margin":30,"notes":"keep-me",
             "createdAt":"2026-09-01T00:00:00.000Z"
            """
            let tail = "}"
            if let date { json += ",\"scheduledDate\":\"\(date)\"" } 
            if let start { json += ",\"scheduledStartTime\":\"\(start)\"" }
            if let end { json += ",\"scheduledEndTime\":\"\(end)\"" }
            return decode08Job(json + tail)
        }
        func slot08(date: String = "2026-09-23", start: String = "09:00") -> String {
            "{\"date\":\"\(date)\",\"start\":\"\(start)\",\"end\":\"10:00\",\"timeZone\":\"America/Chicago\","
                + "\"startUtc\":\"\(date)T14:00:00.000Z\",\"endUtc\":\"\(date)T15:00:00.000Z\"}"
        }
        func request08(id: String, status: String, kind: String? = "booked",
                       slot: String? = nil, extra: String = "") -> Canonical.BookingRequest {
            var json = """
            {"id":"\(id)","status":"\(status)","name":"Sam Ortiz","phone":"555-0177",
             "email":"sam@example.com","address":"9 Oak Ave","details":"Panel inspection",
             "preferredTiming":"","createdAt":"2026-09-10T00:00:00.000Z"\(extra)
            """
            if let kind { json += ",\"kind\":\"\(kind)\"" }
            if let slot { json += ",\"slot\":\(slot)" }
            return decode08Request(json + "}")
        }
        func seed08Store(jobs: [Canonical.Job] = [], customers: [Canonical.Customer] = [],
                         requests: [Canonical.BookingRequest] = [],
                         settings: Canonical.Settings? = nil,
                         delta: ScheduleBookingTestDelta? = nil,
                         tag: String = "t") throws -> (store: AppStore, dir: URL) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-808-\(tag)-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            let snapshot = Canonical.Snapshot(payload: Canonical.SnapshotPayload(
                jobs: jobs, customers: customers, settings: settings, bookingRequests: requests))
            try Canonical.SnapshotRepository(primaryURL: url).save(snapshot)
            // Task 11.05 fix round 1: `useAnotherAccount()` now wipes the App
            // Group (an account boundary for widgets/Siri). A host-test process
            // must never touch the real App Group container (it can block on
            // it, and would wipe the developer machine's suite), so every
            // store here gets a throwaway suite + lock file.
            let suite = "com.tradeready.phase10.tests.\(UUID().uuidString)"
            let store = AppStore(fileURL: url, seedIfMissing: false,
                                 appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                                     suiteName: suite,
                                     defaults: UserDefaults(suiteName: suite) ?? .standard,
                                     lockFile: dir.appendingPathComponent("app-group.lock")
                                 ),
                                 initialSyncService: delta,
                                 subscriptionService: StoreSubscriptionServiceStub(),
                                 secureSettingsStore: hostTestSecureSettingsStore())
            return (store, dir)
        }
        func snapshot08(_ url: URL) throws -> Canonical.Snapshot {
            try Canonical.SnapshotRepository(primaryURL: url).load()!.snapshot
        }
        func queueCount08(_ dir: URL) -> Int {
            Canonical.NativeMutationQueue(
                fileURL: dir.appendingPathComponent("mutation-queue.json")).load().count
        }
        func seed08Owner(_ store: AppStore, subject: String = "user-1", binding: String = "bind-1") {
            let session = Data("{\"access_token\":\"test-session-token\"}".utf8)
            store.scheduleBookingTestSeedSignedInOwner(subject: subject, binding: binding)
            store.scheduleBookingTestCredentials = NativeSyncCredentials(subject: subject, sessionBytes: session)
            store.scheduleBookingSessionOverride = session
        }
        func wait08For(_ flag: @autoclosure () -> Bool) async {
            for _ in 0..<200 {
                if flag() { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        let token48A = String(repeating: "a", count: 48)
        let token48B = String(repeating: "b", count: 48)
        let op08 = "550e8400-e29b-41d4-a716-446655440000"

        // S3: schedule-only commit saves, warns, preserves unrelated fields.
        do {
            let (store, dir) = try seed08Store(jobs: [job08(id: "j1")], tag: "sched")
            let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-23", start: "10:00", end: "11:00")
            let outcome = store.commitScheduleOnly(draft)
            if case let .saved(conflicts) = outcome {
                expect(conflicts.isEmpty, "8.08 schedule-only save reports no conflict on a free slot")
            } else {
                expect(false, "8.08 schedule-only commit saves a clean edit")
            }
            let saved = try snapshot08(dir.appendingPathComponent("store.json")).payload.jobs!.first!
            expect(saved.scheduledDate == "2026-09-23" && saved.scheduledStartTime == "10:00",
                   "8.08 schedule-only commit writes the new slot")
            expect(saved.status == "scheduled", "8.08 only approved→scheduled is automatic")
            expect(saved.notes == "keep-me" && saved.estimateTotal == 400,
                   "8.08 schedule-only commit preserves unrelated pricing/contact fields")
            expect(queueCount08(dir) == 1, "8.08 schedule-only save enqueues exactly one job upsert")
        }

        // S3: conflict warns but still saves; baseline mismatch refuses.
        do {
            let (store, dir) = try seed08Store(
                jobs: [job08(id: "j1"), job08(id: "j2", status: "scheduled")], tag: "conflict")
            let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-22", start: "09:30", end: "10:30")
            let outcome = store.commitScheduleOnly(draft)
            if case let .saved(conflicts) = outcome {
                expect(conflicts == ["j2"], "8.08 overlapping edit warns with the affected job")
            } else {
                expect(false, "8.08 conflicting edit still saves (warn-only parity)")
            }
            let stale = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-24", start: "08:00", end: "09:00")
            expect(store.commitScheduleOnly(stale) == .baselineConflict,
                   "8.08 concurrent schedule change refuses instead of replacing")
            let kept = try snapshot08(dir.appendingPathComponent("store.json")).payload.jobs!
                .first(where: { $0.id == "j1" })!
            expect(kept.scheduledDate == "2026-09-22" && kept.scheduledStartTime == "09:30",
                   "8.08 refused edit leaves the latest schedule untouched")
            expect(store.commitScheduleOnly(NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "gone", date: "2026-09-24")) == .missing,
                   "8.08 schedule commit on a deleted record rejects rather than recreates")
        }

        // S3: clearing stays untimed; booked leads stay leads.
        do {
            let (store, dir) = try seed08Store(jobs: [job08(id: "j1", status: "lead")], tag: "clear")
            let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j1", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "lead",
                date: "2026-09-25", start: nil, end: nil)
            expect(store.commitScheduleOnly(draft) == .saved(conflictingJobIDs: []),
                   "8.08 clearing time commits as an untimed dated job")
            let kept = try snapshot08(dir.appendingPathComponent("store.json")).payload.jobs!.first!
            expect(kept.scheduledDate == "2026-09-25" && kept.scheduledStartTime == nil
                   && kept.status == "lead",
                   "8.08 untimed jobs are not midnight appointments and booked leads stay leads")
        }

        // S4: settings merge preserves credentials; blackout add/remove is exact.
        do {
            let schedule = "{\"workDays\":[1,2,3,4,5],\"workDayStart\":\"08:00\",\"workDayEnd\":\"17:00\","
                + "\"defaultDurationMinutes\":60,\"bufferMinutes\":0,\"slotLeadHours\":24,\"slotWindowDays\":14,"
                + "\"bookableSlotsEnabled\":false,\"blackouts\":[{\"id\":\"b1\",\"start\":\"2026-12-24\",\"end\":\"2026-12-26\"}]}"
            let settings = settings08(schedule: schedule,
                                      bookingLink: "{\"token\":\"\(token48A)\",\"enabled\":true}")
            let (store, dir) = try seed08Store(settings: settings, tag: "settings")
            let baseline = try snapshot08(dir.appendingPathComponent("store.json")).payload.settings!
            var draft = NativeScheduleBookingPolicy.ScheduleSettingsDraft(
                baselineSchedule: baseline.schedule, workDayStart: "09:00")
            draft.blackoutsToAdd = [try! JSONDecoder().decode(Canonical.ScheduleBlackout.self,
                from: Data("{\"id\":\"b2\",\"start\":\"2026-12-31\",\"end\":\"2027-01-01\"}".utf8))]
            draft.blackoutIDsToRemove = ["b1"]
            expect(store.commitScheduleSettings(draft) == .saved,
                   "8.08 settings save merges owned fields")
            let saved = try snapshot08(dir.appendingPathComponent("store.json")).payload.settings!
            expect(saved.bookingLink?.token == token48A && saved.bookingLink?.enabled == true,
                   "8.08 settings save preserves booking credentials")
            expect(saved.schedule?.workDayStart == "09:00" && saved.schedule?.workDayEnd == "17:00"
                   && saved.schedule?.workDays == [1, 2, 3, 4, 5],
                   "8.08 settings save changes one field without rounding the rest")
            expect(saved.schedule?.blackouts?.map(\.id) == ["b2"],
                   "8.08 blackout Add inserts and single remove preserves the others")
            var stale = NativeScheduleBookingPolicy.ScheduleSettingsDraft(workDayStart: "07:00")
            stale.baselineSchedule = baseline.schedule
            expect(store.commitScheduleSettings(stale) == .baselineConflict,
                   "8.08 concurrent settings edit refuses instead of replacing")
        }

        // P3 handled: field-scoped stamp, history preserved, repeat is a no-op.
        do {
            let portal = request08(id: "p1", status: "portal_change_requested", kind: "followup",
                                   extra: ",\"jobRef\":\"j9\",\"source\":\"portal\"")
            let (store, dir) = try seed08Store(requests: [portal], tag: "handled")
            let before = queueCount08(dir)
            expect(store.stampBookingRequestHandled(requestID: "p1", nowISO: "2026-09-20T12:00:00.000Z") == .handled,
                   "8.08 portal Done stamps handledAt")
            let stamped = try snapshot08(dir.appendingPathComponent("store.json")).payload.bookingRequests!.first!
            expect(stamped.handledAt == "2026-09-20T12:00:00.000Z" && stamped.status == "portal_change_requested"
                   && stamped.jobRef == "j9",
                   "8.08 handled stamp merges only handledAt and preserves server fields")
            expect(queueCount08(dir) == before + 1, "8.08 handled stamp enqueues its request upsert")
            expect(store.stampBookingRequestHandled(requestID: "p1") == .alreadyHandled,
                   "8.08 repeat handled stamp is a no-op")
            expect(queueCount08(dir) == before + 1, "8.08 handled no-op enqueues nothing")
            expect(store.stampBookingRequestHandled(requestID: "missing") == .missing,
                   "8.08 handled stamp on a deleted request reports missing")
        }

        // B3/P3 intake after verified pull: converts, preserves, stays inert.
        do {
            let delta = ScheduleBookingTestDelta()
            let booked = request08(id: "bk1", status: "booked", slot: slot08())
            let confirmed = request08(id: "bk2", status: "confirmed", slot: slot08(start: "11:00"))
            let fresh = request08(id: "bk3", status: "new", kind: "quote")
            let change = request08(id: "p2", status: "portal_change_requested", kind: "followup")
            let unknown = request08(id: "x1", status: "weird_future", kind: "booked", slot: slot08())
            let settings = settings08()
            let (store, dir) = try seed08Store(
                requests: [booked, confirmed, fresh, change, unknown],
                settings: settings, delta: delta, tag: "intake")
            seed08Owner(store)
            let before = queueCount08(dir)
            var counter = 0
            let outcome = await store.runBookingIntakeAfterVerifiedPull(
                makeCustomerID: { counter += 1; return "c_fixed_\(counter)" },
                nowISO: { "2026-09-20T12:00:00.000Z" })
            if case let .applied(ids) = outcome {
                expect(Set(ids) == ["bk1", "bk2", "bk3"],
                       "8.08 intake converts new/booked/confirmed and leaves portal-change/unknown inert")
            } else {
                expect(false, "8.08 intake applies after a verified pull")
            }
            let snap = try snapshot08(dir.appendingPathComponent("store.json"))
            expect(snap.payload.jobs!.contains(where: { $0.id == "jbk_bk1" })
                   && snap.payload.jobs!.contains(where: { $0.id == "jbk_bk2" }),
                   "8.08 intake creates deterministic jbk_ jobs without overwriting")
            expect(snap.payload.bookingRequests!.first(where: { $0.id == "bk2" })?.status == "confirmed",
                   "8.08 confirmed-before-conversion keeps its server status (D-B3-1)")
            expect(snap.payload.bookingRequests!.first(where: { $0.id == "p2" })?.convertedJobId == nil
                   && snap.payload.bookingRequests!.first(where: { $0.id == "x1" })?.convertedJobId == nil,
                   "8.08 portal-change and unknown statuses stay intact and inert")
            expect(queueCount08(dir) > before, "8.08 intake publishes exactly its changed records")
                               let check08_1 = await store.runBookingIntakeAfterVerifiedPull() == .noChange
                   expect(check08_1, "8.08 intake replay is a no-op that writes nothing")
            let rows = store.bookingAttentionRows()
            expect(!rows.contains(where: { $0.request.id == "bk1" }),
                   "8.08 converted requests leave the attention set")
        }

        // Intake: late server lifecycle during conversion survives (D-B3-4).
        do {
            let delta = ScheduleBookingTestDelta()
            let booked = request08(id: "bk9", status: "booked", slot: slot08())
            let (store, dir) = try seed08Store(requests: [booked], settings: settings08(),
                                               delta: delta, tag: "lifecycle")
            seed08Owner(store)
            delta.handler = { local, cursor in
                var snap = local
                if var row = snap.payload.bookingRequests?.first(where: { $0.id == "bk9" }) {
                    row.status = "confirmed"
                    row.history = [try! JSONDecoder().decode(Canonical.BookingHistoryEntry.self,
                        from: Data("{\"at\":\"2026-09-20T11:00:00.000Z\",\"actor\":\"customer\",\"event\":\"confirm\"}".utf8))]
                    snap.payload.bookingRequests = [row]
                }
                return NativeDeltaPullOutcome(snapshot: snap, cursor: cursor,
                                              failedTables: [], lastDiagnosticCode: nil)
            }
            let outcome = await store.runBookingIntakeAfterVerifiedPull(
                makeCustomerID: { "c_late_1" }, nowISO: { "2026-09-20T12:00:00.000Z" })
            if case .applied = outcome {
                let row = try snapshot08(dir.appendingPathComponent("store.json"))
                    .payload.bookingRequests!.first(where: { $0.id == "bk9" })!
                expect(row.convertedJobId == "jbk_bk9" && row.status == "confirmed"
                       && row.history?.count == 1,
                       "8.08 conversion merges owned fields only; late server lifecycle survives")
            } else {
                expect(false, "8.08 intake applies when the server confirms mid-pull")
            }
        }

        // Intake: deleted source customer falls back; simultaneous refresh serializes.
        do {
            let delta = ScheduleBookingTestDelta()
            let orphan = request08(id: "bk8", status: "new", kind: "quote",
                                   extra: ",\"sourceCustomerId\":\"deleted-customer\"")
            let (store, dir) = try seed08Store(requests: [orphan], settings: settings08(),
                                               delta: delta, tag: "orphan")
            seed08Owner(store)
            let outcome = await store.runBookingIntakeAfterVerifiedPull(
                makeCustomerID: { "c_orphan_1" }, nowISO: { "2026-09-20T12:00:00.000Z" })
            if case .applied = outcome {
                let snap = try snapshot08(dir.appendingPathComponent("store.json"))
                expect(snap.payload.bookingRequests!.first?.convertedCustomerId == "c_orphan_1",
                       "8.08 intake with a deleted source customer falls back to upsert")
            } else {
                expect(false, "8.08 orphan intake applies")
            }
            let gated = ScheduleBookingTestDelta()
            gated.gatePull = true
            let (store2, dir2) = try seed08Store(
                requests: [request08(id: "bk7", status: "new", kind: "quote")],
                settings: settings08(), delta: gated, tag: "simultaneous")
            seed08Owner(store2)
            let dir2StoreURL = dir2.appendingPathComponent("store.json")
            let first = Task {
                await store2.runBookingIntakeAfterVerifiedPull(
                    makeCustomerID: { "c_sim_1" }, nowISO: { "2026-09-20T12:00:00.000Z" })
            }
            await wait08For(gated.enteredPull)
                               let check08_2 = await store2.runBookingIntakeAfterVerifiedPull() == .alreadyRunning
                   expect(check08_2, "8.08 overlapping refreshes serialize instead of double-converting")
            gated.resumePull?.resume(returning: NativeDeltaPullOutcome(
                snapshot: try snapshot08(dir2StoreURL),
                cursor: Canonical.NativeSyncCursor(version: 2, tables: [:]),
                failedTables: [], lastDiagnosticCode: nil))
            let check08_sim = await first.value
            expect(check08_sim == .applied(convertedRequestIDs: ["bk7"]),
                   "8.08 the serialized first refresh still converts exactly once")
        }

        // Intake: owner change across the pull refuses without writing.
        do {
            let gated = ScheduleBookingTestDelta()
            gated.gatePull = true
            let convertible = request08(id: "bk6", status: "new", kind: "quote")
            let (store, dir) = try seed08Store(requests: [convertible], settings: settings08(),
                                               delta: gated, tag: "ownerchange")
            seed08Owner(store)
            // 10.09 fix round 1 (finding 5): this is the REAL, deterministic
            // pre-commit failure — "owner changed during the network await"
            // — that `pullDeltaIfPossible` guards against
            // (`guard subject == authenticatedUserSubject ... else { return .skipped }`,
            // strictly before the publish call). Prove it never publishes.
            var notifyCalls = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            var observed = 0
            store.registerDerivedStateObserver { _ in observed += 1 }
            let flight = Task {
                await store.runBookingIntakeAfterVerifiedPull(
                    makeCustomerID: { "c_acct_1" }, nowISO: { "2026-09-20T12:00:00.000Z" })
            }
            await wait08For(gated.enteredPull)
            store.scheduleBookingTestClearOwner()
            store.scheduleBookingTestCredentials = nil
            gated.resumePull?.resume(returning: NativeDeltaPullOutcome(
                snapshot: try snapshot08(dir.appendingPathComponent("store.json")),
                cursor: Canonical.NativeSyncCursor(version: 2, tables: [:]),
                failedTables: [], lastDiagnosticCode: nil))
            let outcome = await flight.value
            if case .skipped = outcome {
                expect(true, "8.08 intake after an account switch refuses without writing")
            } else {
                expect(false, "8.08 intake after an account switch refuses without writing")
            }
            let kept = try snapshot08(dir.appendingPathComponent("store.json")).payload.bookingRequests!.first!
            expect(kept.convertedJobId == nil, "8.08 refused intake converts nothing")
            expect(notifyCalls == 0,
                   "10.09 fix1: a pre-commit failure (owner changed during the network await) never publishes")
            expect(observed == 0,
                   "10.09 fix1: a pre-commit failure never notifies a registered observer")
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 fix1: a pre-commit failure never populates the cache")
        }

        // B4 decline: merges status only; stale owner never publishes.
        do {
            let loader = ScheduleBookingTestLoader()
            let booked = request08(id: "bkd", status: "booked", slot: slot08(),
                                   extra: ",\"history\":[{\"at\":\"2026-09-19T00:00:00.000Z\",\"actor\":\"system\",\"event\":\"created\"}]")
            let (store, dir) = try seed08Store(requests: [booked], tag: "decline")
            seed08Owner(store)
            loader.handler = { _ in
                (Data("{\"ok\":true,\"status\":\"declined\"}".utf8), 200)
            }
            let service = NativeBookingResponseService(
                endpoint: URL(string: "https://example.com/api/booking/respond")!, loader: loader)
            let outcome = await store.declineBookingRequest(requestID: "bkd", responseService: service)
            expect(outcome == .applied(status: "declined", alreadyApplied: false),
                   "8.08 owner decline applies the server status")
            let kept = try snapshot08(dir.appendingPathComponent("store.json")).payload.bookingRequests!.first!
            expect(kept.status == "declined" && kept.history?.count == 1 && kept.slot?.date == "2026-09-23",
                   "8.08 decline merges only the status; history and slot survive")
            // Success-equivalent: 409 invalid_state echoing the target is a retry-after-commit.
            loader.handler = { _ in
                (Data("{\"error\":\"invalid_state\",\"status\":\"declined\"}".utf8), 409)
            }
            let retry = await store.declineBookingRequest(requestID: "bkd", responseService: service)
            expect(retry == .applied(status: "declined", alreadyApplied: true),
                   "8.08 retried decline after commit reports success without a second write")
            // Account switch during the await: no publish for another owner.
            let (store2, dir2) = try seed08Store(requests: [booked], tag: "declinestale")
            seed08Owner(store2)
            loader.handler = { [weak store2] _ in
                store2?.scheduleBookingTestClearOwner()
                return (Data("{\"ok\":true,\"status\":\"declined\"}".utf8), 200)
            }
            let stale = await store2.declineBookingRequest(requestID: "bkd", responseService: service)
            expect(stale == .failed(reason: "owner-changed"),
                   "8.08 stale response after suspension never applies to another owner")
            let kept2 = try snapshot08(dir2.appendingPathComponent("store.json")).payload.bookingRequests!.first!
            expect(kept2.status == "booked", "8.08 stale response publishes nothing locally")
                               let check08_3 = await store2.declineBookingRequest(requestID: "missing", responseService: service) == .missing
                   expect(check08_3, "8.08 decline of a deleted request reports missing")
        }

        // B4 reschedule two-phase: exact-ack gate, superseding refusal, 409 review.
        do {
            let loader = ScheduleBookingTestLoader()
            var calls = 0
            let req = request08(id: "bkr", status: "reschedule_requested", slot: slot08())
            let (store, dir) = try seed08Store(jobs: [job08(id: "j9")], requests: [req], tag: "resched")
            seed08Owner(store, binding: "bind-resched")
            let draft = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j9", baselineDate: "2026-09-22", baselineStart: "09:00",
                baselineEnd: "10:00", baselineStatus: "approved",
                date: "2026-09-24", start: "13:00", end: "14:00")
            let prepared = await store.prepareBookingReschedule(requestID: "bkr", scheduleDraft: draft,
                                                                writeStamp: "2026-09-20T12:00:00.000Z")
            if case let .proofReady(proof) = prepared {
                expect(proof.jobId == "j9" && proof.date == "2026-09-24" && proof.start == "13:00",
                       "8.08 reschedule proof identifies the exact intended job mutation")
            } else if case .awaitingAck = prepared {
                expect(true, "8.08 reschedule waits for the exact job-mutation acknowledgment")
            } else {
                expect(false, "8.08 reschedule prepare stages proof or waits for ack")
            }
            let staged = store.pendingScheduleBookingWorkStore().load()
            expect(staged.contains(where: {
                if case .rescheduleProof("bkr", _, _) = $0.kind { return $0.ownerBinding == "bind-resched" }
                return false
            }), "8.08 reschedule proof persists as owner-bound pending work")
            // Superseding edit refuses without touching the network.
            let supersede = NativeScheduleBookingPolicy.ScheduleOnlyDraft(
                jobID: "j9", baselineDate: "2026-09-24", baselineStart: "13:00",
                baselineEnd: "14:00", baselineStatus: "scheduled",
                date: "2026-09-25", start: "08:00", end: "09:00")
            expect(store.commitScheduleOnly(supersede) == .saved(conflictingJobIDs: []),
                   "8.08 superseding schedule edit saves locally")
            loader.handler = { _ in
                calls += 1
                return (Data("{\"ok\":true,\"status\":\"confirmed\"}".utf8), 200)
            }
            let service = NativeBookingResponseService(
                endpoint: URL(string: "https://example.com/api/booking/respond")!, loader: loader)
            let staleProof = NativeScheduleProof(jobId: "j9", updatedAt: "2026-09-20T12:00:00.000Z",
                                                 date: "2026-09-24", start: "13:00")
                               let check08_101 = await store.resolveBookingReschedule(requestID: "bkr", proof: staleProof, responseService: service) == .superseded
                   expect(check08_101, "8.08 superseded schedule refuses instead of resolving the wrong slot")
            expect(calls == 0, "8.08 superseded resolve sends no request")
            // schedule_changed refreshes into review; unknown outcome never resends.
            let fresh = NativeScheduleProof(jobId: "j9", updatedAt: "2026-09-20T12:00:00.000Z",
                                            date: "2026-09-25", start: "08:00")
            loader.handler = { _ in
                (Data("{\"error\":\"schedule_changed\",\"status\":\"reschedule_requested\"}".utf8), 409)
            }
            let check08_105 = await store.resolveBookingReschedule(requestID: "bkr", proof: fresh,
                                                        responseService: service)
            expect(check08_105 == .needsReview(currentStatus: "reschedule_requested"),
                   "8.08 schedule_changed refreshes into owner review")
            loader.handler = { _ in
                (Data("oops".utf8), 500)
            }
            let check08_106 = await store.resolveBookingReschedule(requestID: "bkr", proof: fresh,
                                                        responseService: service)
            expect(check08_106 == .unknownOutcome,
                   "8.08 timeout after resolve is unknown outcome, never an automatic resend")
            let check08_107 = await store.declineBookingRequest(requestID: "bkr", responseService: service)
            expect(check08_107 == .unknownOutcome,
                   "8.08 timeout after decline is unknown outcome, never an automatic resend")
            expect(store.pendingScheduleBookingWorkStore().load().contains(where: {
                if case .rescheduleProof("bkr", _, _) = $0.kind { return true }
                return false
            }), "8.08 unknown outcome keeps the staged proof for explicit retry")
            _ = dir
        }

        // B2 booking-link admin: server-first, field-scoped mirror, stale reconcile.
        do {
            let loader = ScheduleBookingTestLoader()
            let (store, dir) = try seed08Store(settings: settings08(), tag: "badmin")
            seed08Owner(store, binding: "bind-book")
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":false,\"revision\":3,\"tokenValid\":false}".utf8), 200)
                }
                return (Data("{\"ok\":true,\"enabled\":true,\"token\":\"\(token48A)\",\"revision\":4,\"operationId\":\"\(op08)\"}".utf8), 200)
            }
            let service = NativeBookingAdministrationService(
                endpoint: URL(string: "https://example.com/api/booking/admin")!, loader: loader)
            let outcome = await store.administerBookingLink(action: .mint, operationId: op08,
                                                            adminService: service)
            if case let .applied(revision, sharesURL) = outcome {
                expect(revision == 4 && sharesURL,
                       "8.08 booking mint applies the acknowledged revision with a shareable URL")
            } else {
                expect(false, "8.08 booking mint applies after server acknowledgment")
            }
            let saved = try snapshot08(dir.appendingPathComponent("store.json")).payload.settings!
            expect(saved.bookingLink?.token == token48A && saved.bookingLink?.enabled == true
                   && saved.businessName == "Ada Electric",
                   "8.08 booking mirror merges only display fields and preserves the rest")
            // Stale revision adopts authority instead of forcing intent.
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":true,\"revision\":9,\"tokenValid\":true}".utf8), 200)
                }
                return (Data("{\"error\":\"stale_revision\",\"enabled\":false,\"revision\":10}".utf8), 409)
            }
                               let check08_103 = await store.administerBookingLink(action: .setEnabled, enabled: true, adminService: service) == .stale(currentEnabled: false)
                   expect(check08_103, "8.08 concurrent link change reconciles instead of forcing")
            // Reconcile-before-share: stale display copy never becomes a URL.
            loader.handler = { _ in
                (Data("{\"ok\":true,\"enabled\":false,\"revision\":10,\"tokenValid\":false}".utf8), 200)
            }
            let reconciled = await store.reconcileBookingLinkForSharing(adminService: service)
            expect(reconciled.shareURL == nil,
                   "8.08 present-but-stale token takes recovery, never a share URL")
            loader.handler = { _ in
                (Data("{\"ok\":true,\"enabled\":true,\"revision\":10,\"tokenValid\":true}".utf8), 200)
            }
            let freshLink = await store.reconcileBookingLinkForSharing(adminService: service)
            expect(freshLink.shareURL?.absoluteString.contains("b=\(token48A)") == true,
                   "8.08 fresh tokenValid read adopts the display copy for sharing")
            // set_enabled with no link fails closed into staged recovery work.
            let (store2, _) = try seed08Store(settings: settings08(), tag: "badminrecovery")
            seed08Owner(store2, binding: "bind-recover")
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":false,\"revision\":1,\"tokenValid\":false}".utf8), 200)
                }
                return (Data("{\"ok\":true,\"enabled\":true,\"revision\":2,\"operationId\":\"\(op08)\"}".utf8), 200)
            }
                               let check08_104 = await store2.administerBookingLink(action: .setEnabled, enabled: true, adminService: service) == .recoveryStaged
                   expect(check08_104, "8.08 server success with local-save failure stages recovery, never repeats the mutation")
            let pending = store2.pendingScheduleBookingWorkStore().load()
            expect(pending.count == 1 && pending.first?.ownerBinding == "bind-recover",
                   "8.08 incomplete mirror persists as owner-bound pending work")
            let recovery = store2.recoverScheduleBookingPendingWork(ownerBinding: "bind-recover")
            expect(recovery.retained == 1 && recovery.reappliedMirrors == 0,
                   "8.08 token-less mirror recovery fails closed and stays staged")
            store2.scrubScheduleBookingPendingWork(binding: "bind-recover")
            expect(store2.pendingScheduleBookingWorkStore().load().isEmpty,
                   "8.08 account boundary scrubs owner-bound pending work")
        }

        // P1 portal admin: saved-customer guard, server-first merge, already_exists adoption.
        do {
            let loader = ScheduleBookingTestLoader()
            let customer = decode08Customer(
                "{\"id\":\"cust1\",\"name\":\"Nora\",\"email\":\"n@example.com\",\"phone\":\"p\",\"address\":\"a\",\"notes\":\"n\"}")
            let (store, dir) = try seed08Store(customers: [customer], tag: "padmin")
            seed08Owner(store, binding: "bind-portal")
                               let check08_105 = await store.administerPortalLink(customerID: "ghost", action: .mint, portalService: NativePortalAdministrationService( endpoint: URL(string: "https://example.com/api/estimate/portal-manage")!, loader: loader)) == .missingCustomer
                   expect(check08_105, "8.08 portal admin requires a saved customer first")
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":false,\"tokenValid\":false,\"adopted\":false}".utf8), 200)
                }
                return (Data("{\"ok\":true,\"token\":\"\(token48B)\",\"enabled\":true,\"operationId\":\"\(op08)\"}".utf8), 200)
            }
            let service = NativePortalAdministrationService(
                endpoint: URL(string: "https://example.com/api/estimate/portal-manage")!, loader: loader)
                               let check08_106 = await store.administerPortalLink(customerID: "cust1", action: .mint, operationId: op08, portalService: service) == .applied
                   expect(check08_106, "8.08 portal mint applies server-first")
            let kept = try snapshot08(dir.appendingPathComponent("store.json")).payload.customers!.first!
            expect(kept.portal?.token == token48B && kept.portal?.enabled == true && kept.name == "Nora",
                   "8.08 portal merge touches only display fields on the latest record")
            // already_exists with a matching current copy adopts; stale needs explicit rotate.
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":true,\"tokenValid\":true,\"adopted\":true}".utf8), 200)
                }
                return (Data("{\"error\":\"already_exists\"}".utf8), 409)
            }
                               let check08_107 = await store.administerPortalLink(customerID: "cust1", action: .mint, portalService: service) == .alreadyExists(adoptedCurrent: true)
                   expect(check08_107, "8.08 stale Create adopts only a matching current display copy")
            loader.handler = { request in
                let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                if body.contains("\"status\"") {
                    return (Data("{\"ok\":true,\"enabled\":true,\"tokenValid\":false,\"adopted\":true}".utf8), 200)
                }
                return (Data("{\"error\":\"already_exists\"}".utf8), 409)
            }
                               let check08_108 = await store.administerPortalLink(customerID: "cust1", action: .mint, portalService: service) == .needsExplicitRotate
                   expect(check08_108, "8.08 stale display copy needs explicit confirmed rotate, never silent re-mint")
        }

        // Boundaries: snapshot/queue failure injection, relaunch, attention.
        do {
            var enqueued = false
            var staged = false
            expect(NativeScheduleBookingPolicy.commitLocal(
                saveSnapshot: { throw StoreTestError.missingFixture },
                publishToQueue: { enqueued = true },
                stageRecovery: { staged = true }) == .snapshotFailed,
                   "8.08 snapshot failure publishes nothing to the queue")
            expect(!enqueued && !staged, "8.08 snapshot failure enqueues nothing and stages nothing")
            expect(NativeScheduleBookingPolicy.commitLocal(
                saveSnapshot: {},
                publishToQueue: { throw StoreTestError.missingFixture },
                stageRecovery: { staged = true }) == .queueFailedRecoveryStaged,
                   "8.08 queue failure stages recovery instead of rolling back local truth")
            expect(staged, "8.08 queue failure recovery is staged, never silently dropped")

            // Relaunch: staged work survives the process boundary, keyed by owner.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-808-relaunch-\(UUID().uuidString)", isDirectory: true)
            let pendingURL = dir.appendingPathComponent("schedule-booking-pending-work.json")
            let pendingStore = NativeScheduleBookingPendingWorkStore(fileURL: pendingURL)
            try pendingStore.stage(.init(kind: .bookingMirror(token: token48A, enabled: true,
                                                              revision: 7, operationId: op08),
                                         ownerBinding: "bind-a"))
            try pendingStore.stage(.init(kind: .portalMirror(customerId: "cust9", token: nil,
                                                             enabled: false, operationId: op08),
                                         ownerBinding: "bind-b"))
            let relaunched = NativeScheduleBookingPendingWorkStore(fileURL: pendingURL)
            expect(relaunched.load().count == 2, "8.08 pending work survives relaunch")
            try relaunched.scrubOwnerBoundWork(binding: "bind-a")
            let kept = relaunched.load()
            expect(kept.count == 1 && kept.first?.ownerBinding == "bind-b",
                   "8.08 account switch scrubs exactly the departing account's work")

            // Attention: converted rows leave; actionable and inspection rows surface.
            let resched = request08(id: "att1", status: "reschedule_requested", slot: slot08(),
                                    extra: ",\"convertedJobId\":\"jbk_att1\"")
            let holder = job08(id: "jbk_att1", status: "lead", date: "2026-09-23", start: "09:00", end: "10:00")
            let fresh = request08(id: "att2", status: "new", kind: "quote")
            let (store, _) = try seed08Store(jobs: [holder], requests: [resched, fresh], tag: "attention")
            let rows = store.bookingAttentionRows()
            expect(rows.first?.kind == .rescheduleRequested && rows.first?.request.id == "att1",
                   "8.08 reschedule requests surface as actionable attention")
            expect(rows.contains(where: { $0.kind == .unconvertedActive && $0.request.id == "att2" }),
                   "8.08 unconverted bookings surface for inspection so confirmed work never disappears")
        }

        // MARK: Phase 9 (task 9.08) money-record store integration

        func canonicalRecord<T: Decodable>(_ json: String) throws -> T {
            try JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
        func succeed<T>(_ result: Result<T, NativeMoneyRecordRefusal>, _ label: String) -> T? {
            switch result {
            case .success(let value): return value
            case .failure(let refusal):
                expect(false, "\(label) (refused: \(refusal))")
                return nil
            }
        }
        func refusal<T>(_ result: Result<T, NativeMoneyRecordRefusal>) -> NativeMoneyRecordRefusal? {
            if case let .failure(error) = result { return error }
            return nil
        }

        let phase9Directory = directory.appendingPathComponent("Phase9", isDirectory: true)
        let phase9URL = phase9Directory.appendingPathComponent("store.json")
        let phase9Store = AppStore(fileURL: phase9URL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
        func snapshot9(_ url: URL) throws -> Canonical.Snapshot {
            guard let outcome = try Canonical.SnapshotRepository(primaryURL: url).load() else {
                throw StoreTestError.missingFixture
            }
            return outcome.snapshot
        }

        // Expenses: create, edit, job link + receipt, durable boundaries.
        do {
            var draft = Expense(merchant: "Supply House", amount: 42.75)
            draft.notes = "copper fittings"
            draft.jobId = "job-42"
            draft.receiptUri = "receipts/r-42.jpg"
            guard let created = succeed(
                phase9Store.commitExpenseEdit(id: nil, opened: nil, draft: draft),
                "9.08 creating an expense commits durably"
            ) else { throw StoreTestError.missingFixture }
            expect(created.receiptUri == "receipts/r-42.jpg" && created.jobId == "job-42",
                   "9.08 the created expense keeps its receipt reference and job link")
            let canonical = try snapshot9(phase9URL)
            let stored = canonical.payload.expenses?.first { $0.id == created.id }
            expect(stored?.receiptUri == "receipts/r-42.jpg" && stored?.jobId == "job-42"
                   && stored?.amount == Decimal(string: "42.75") && stored?.importBatchId == nil,
                   "9.08 the canonical expense carries the link/receipt and no import provenance")
            expect(pendingMutations(phase9URL).contains {
                $0.table == "expenses" && $0.recordId == created.id && $0.op == .upsert
            }, "9.08 creating an expense enqueues exactly its upsert")
            guard let newest = succeed(
                phase9Store.commitExpenseEdit(
                    id: nil, opened: nil, draft: Expense(merchant: "Second Stop", amount: 12)
                ),
                "9.08 a second expense commits"
            ) else { throw StoreTestError.missingFixture }
            let newestStored = try snapshot9(phase9URL).payload.expenses!.first
            expect(newestStored?.id == newest.id,
                   "9.08 a new expense is prepended, matching the RN money hook")

            // Seed a synced record carrying import provenance and an unknown field,
            // then edit one editor-owned scalar through a fresh store (relaunch).
            let seededJSON = """
            {"id":"e-seed","createdAt":"2026-09-01T10:00:00.000Z","description":"Old Merchant",
             "amount":10.5,"category":"fuel","date":"2026-09-02","notes":"seeded",
             "jobId":"job-7","receiptUri":"receipts/old.jpg","importBatchId":"imp_seed",
             "forwardCompat":"keep-me"}
            """
            var seeded = canonical
            seeded.payload.expenses = [try canonicalRecord(seededJSON)]
            try Canonical.SnapshotRepository(primaryURL: phase9URL).save(seeded)
            let relaunched = AppStore(fileURL: phase9URL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let opened = relaunched.expenses.first { $0.id == "e-seed" }
            expect(opened?.receiptUri == "receipts/old.jpg" && opened?.importBatchId == "imp_seed",
                   "9.08 the expense projection exposes receipt and import provenance after relaunch")
            var edit = opened!
            edit.notes = "edited notes"
            guard let edited = succeed(
                relaunched.commitExpenseEdit(id: "e-seed", opened: opened, draft: edit),
                "9.08 editing an expense commits"
            ) else { throw StoreTestError.missingFixture }
            expect(edited.notes == "edited notes", "9.08 the edit publishes the new value")
            let afterEdit = try snapshot9(phase9URL)
            let merged = afterEdit.payload.expenses!.first { $0.id == "e-seed" }!
            expect(merged.createdAt == "2026-09-01T10:00:00.000Z" && merged.importBatchId == "imp_seed"
                   && merged.preservation.unknownFields["forwardCompat"] == .string("keep-me")
                   && merged.jobId == "job-7" && merged.receiptUri == "receipts/old.jpg",
                   "9.08 an expense edit preserves createdAt, import provenance and unknown fields")

            // A concurrent owned-scalar change fails closed and writes nothing.
            var stale = edited
            stale.amount = 99
            var drift = merged
            drift.notes = "moved by another device"
            var driftSnapshot = afterEdit
            driftSnapshot.payload.expenses = [drift]
            try Canonical.SnapshotRepository(primaryURL: phase9URL).save(driftSnapshot)
            let beforeQueue = pendingMutations(phase9URL).count
            expect(refusal(relaunched.commitExpenseEdit(id: "e-seed", opened: opened, draft: stale))
                   == .staleEditorCopy,
                   "9.08 an expense edit refuses when another device moved an owned scalar")
            expect(pendingMutations(phase9URL).count == beforeQueue,
                   "9.08 a refused expense edit publishes nothing")

            // Injected queue failure: the local write must still be durable.
            let blockedURL = phase9Directory.appendingPathComponent("blocked/store.json")
            let blockedStore = AppStore(fileURL: blockedURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            try FileManager.default.createDirectory(
                at: phase9Directory.appendingPathComponent("blocked/mutation-queue.json"),
                withIntermediateDirectories: true
            )
            expect(succeed(
                blockedStore.commitExpenseEdit(
                    id: nil, opened: nil, draft: Expense(merchant: "Queue Down", amount: 5)
                ),
                "9.08 an expense save survives an unwritable queue file"
            ) != nil, "9.08 the expense save reports success despite the queue failure")
            let blockedSnapshot = try snapshot9(blockedURL)
            expect(blockedSnapshot.payload.expenses?.contains { $0.description == "Queue Down" } == true,
                   "9.08 the durable expense survives the queue failure for the next edit to re-enqueue")

            expect(relaunched.deleteExpenseRecord(id: "e-seed"), "9.08 deleting a present expense reports true")
            expect(!relaunched.deleteExpenseRecord(id: "e-seed"), "9.08 deleting an absent expense reports false")
            let afterDelete = try snapshot9(phase9URL)
            expect(afterDelete.payload.expenses?.contains { $0.id == "e-seed" } == false
                   && pendingMutations(phase9URL).contains {
                       $0.table == "expenses" && $0.recordId == "e-seed" && $0.op == .delete
                   },
                   "9.08 an expense delete removes the record and queues the delete")
        } catch { expect(false, "9.08 expense block aborted: \(error)") }

        // Receipts + advisory OCR (task 9.10, requirement E2).
        do {
            let receiptDirectory = phase9Directory.appendingPathComponent("Receipts", isDirectory: true)
            let receiptURL = receiptDirectory.appendingPathComponent("store.json")
            let receiptStore = AppStore(fileURL: receiptURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())

            // Persist real bytes at the deterministic path.
            guard let jpeg = StoreTestImage.noisyJPEG(width: 900, height: 600) else {
                throw StoreTestError.missingFixture
            }
            guard let receiptUri = receiptStore.persistReceipt(sourceData: jpeg) else {
                expect(false, "9.10 a real photo persists")
                throw StoreTestError.missingFixture
            }
            expect(receiptUri.contains("/receipts/r") && receiptUri.hasSuffix(".jpg"),
                   "9.10 the receipt reference is the native receipts path")
            let storedReceipt = URL(string: receiptUri)
            expect(storedReceipt.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                   "9.10 receipt bytes are on disk")
            expect(receiptStore.persistReceipt(sourceData: Data("not an image".utf8)) == nil,
                   "9.10 undecodable bytes are refused")
            expect(receiptStore.receiptDataUri(receiptUri: receiptUri)?.hasPrefix("data:image/jpeg;base64,") == true,
                   "9.10 a persisted receipt round-trips to a jpeg data URI")
            expect(receiptStore.receiptDataUri(
                receiptUri: receiptDirectory.appendingPathComponent("missing.jpg").path
            ) == nil, "9.10 a missing receipt has no data URI")

            // The OCR path is advisory: it fills the editor, and a transport
            // failure is a typed nil rather than an error.
            var draft = Expense(merchant: "Supply House", amount: 42.75)
            draft.receiptUri = receiptUri
            draft.jobId = "job-42"
            guard let created = succeed(
                receiptStore.commitExpenseEdit(id: nil, opened: nil, draft: draft),
                "9.10 an expense with a receipt saves"
            ) else { throw StoreTestError.missingFixture }
            expect(receiptStore.expenseRecord(id: created.id)?.receiptUri == receiptUri,
                   "9.10 the editor baseline exposes the receipt reference")
            expect(receiptStore.expenseRecord(id: "missing") == nil,
                   "9.10 an unknown id has no editor baseline")

            let scanStore = AppStore(
                fileURL: receiptURL, seedIfMissing: false, advisoryAITransport: StoreTestOCRTransport(),
                secureSettingsStore: hostTestSecureSettingsStore()
            )
            let mutationsBeforeScan = pendingMutations(receiptURL).count
            let scan = await scanStore.scanReceipt(receiptUri: receiptUri)
            expect(scan?.extraction.merchant == "Home Depot" && scan?.route == "backend",
                   "9.10 a transport result is returned for review")
            let failedScan = await scanStore.scanReceipt(
                receiptUri: receiptDirectory.appendingPathComponent("missing.jpg").path
            )
            expect(failedScan == nil, "9.10 an unreadable receipt scans to nil")
            expect(pendingMutations(receiptURL).count == mutationsBeforeScan,
                   "9.10 a scan writes no canonical record of its own")
        } catch { expect(false, "9.10 receipt block aborted: \(error)") }

        // Mileage: create ordering, validation, edit preservation.
        do {
            let tripURL = phase9Directory.appendingPathComponent("Trips/store.json")
            let tripStore = AppStore(fileURL: tripURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            var draft = NativeTripDraft(
                date: "2026-09-10",
                odometerStartText: "1000",
                odometerEndText: "1012.4",
                from: .home,
                to: NativeTripEndpoint(jobId: "job-9", label: "Ada's Kitchen"),
                purpose: "  Supply run  "
            )
            guard let trip = succeed(
                tripStore.commitTripEdit(id: nil, opened: nil, draft: draft),
                "9.08 logging a trip commits"
            ) else { throw StoreTestError.missingFixture }
            expect(trip.miles == Decimal(string: "12.4") && trip.purpose == "Supply run"
                   && trip.toJobId == "job-9" && !trip.createdAt.isEmpty,
                   "9.08 a logged trip stores 0.1-rounded miles and a trimmed purpose")
            expect(tripStore.trips.first?.id == trip.id, "9.08 a new trip is prepended to the log")
            expect(pendingMutations(tripURL).contains {
                $0.table == "trips" && $0.recordId == trip.id && $0.op == .upsert
            }, "9.08 logging a trip enqueues its upsert")

            let seededTripJSON = """
            {"id":"t-seed","date":"2026-09-01","odometerStart":10,"odometerEnd":20,"miles":10,
             "fromJobId":null,"fromLabel":"Home / Shop","toJobId":null,"toLabel":"Home / Shop",
             "purpose":"seeded","createdAt":"2026-09-01T08:00:00.000Z","forwardCompat":"keep"}
            """
            let seeded = Canonical.Snapshot(payload: .init(trips: [try canonicalRecord(seededTripJSON)]))
            try Canonical.SnapshotRepository(primaryURL: tripURL).save(seeded)
            let reopened = AppStore(fileURL: tripURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let openedTrip = reopened.trips.first { $0.id == "t-seed" }
            draft.date = "2026-09-03"
            draft.odometerStartText = "10"
            draft.odometerEndText = "24"
            draft.purpose = "Edited purpose"
            guard let editedTrip = succeed(
                reopened.commitTripEdit(id: "t-seed", opened: openedTrip, draft: draft),
                "9.08 editing a trip commits"
            ) else { throw StoreTestError.missingFixture }
            expect(editedTrip.createdAt == "2026-09-01T08:00:00.000Z"
                   && editedTrip.miles == Decimal(string: "14") && editedTrip.date == "2026-09-03",
                   "9.08 a trip edit preserves createdAt and recomputes miles")
            var tripSnapshot = try snapshot9(tripURL)
            expect(tripSnapshot.payload.trips!.first { $0.id == "t-seed" }!
                    .preservation.unknownFields["forwardCompat"] == .string("keep"),
                   "9.08 a trip edit preserves unknown fields")
            let tripsBeforeInvalid = tripSnapshot.payload.trips!.count
            var invalid = draft
            invalid.odometerEndText = "3"
            expect(refusal(reopened.commitTripEdit(id: nil, opened: nil, draft: invalid))
                   == .invalidDraft("End reading must be greater than or equal to the start reading."),
                   "9.08 an end-before-start trip is refused with the RN copy")
            var badDate = draft
            badDate.date = "03/10/2026"
            expect(refusal(reopened.commitTripEdit(id: nil, opened: nil, draft: badDate))
                   == .invalidDraft("Enter the trip date as YYYY-MM-DD."),
                   "9.08 a non-ISO trip date is refused with the RN copy")
            tripSnapshot = try snapshot9(tripURL)
            expect(tripSnapshot.payload.trips!.count == tripsBeforeInvalid, "9.08 refused trips write nothing")
            expect(reopened.deleteTripRecord(id: "t-seed"), "9.08 deleting a trip reports true")
            expect(!reopened.deleteTripRecord(id: "t-seed"), "9.08 deleting an absent trip reports false")
        } catch { expect(false, "9.08 trip block aborted: \(error)") }

        // Pricebook: create, nested preservation, delete.
        do {
            let pricebookURL = phase9Directory.appendingPathComponent("Pricebook/store.json")
            let pricebookStore = AppStore(fileURL: pricebookURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let draft = NativePricebookEntryDraft(
                name: "  Drain clearing  ", description: "Standard", category: "Plumbing",
                laborHours: 2, laborBreakdown: nil, laborRate: 95, materials: [],
                materialMarkup: 20, jobCosts: [], overhead: 15, margin: 20
            )
            var nameless = draft
            nameless.name = "   "
            expect(refusal(pricebookStore.commitPricebookEdit(id: nil, opened: nil, draft: nameless))
                   == .invalidDraft("Give this service a name so you can find it later."),
                   "9.08 a nameless pricebook entry is refused with the RN copy")
            guard let created = succeed(
                pricebookStore.commitPricebookEdit(id: nil, opened: nil, draft: draft),
                "9.08 saving a pricebook entry commits"
            ) else { throw StoreTestError.missingFixture }
            var trimmed = draft
            trimmed.name = "Drain clearing"
            expect(created.name == "Drain clearing"
                   && created.estimateTotal == NativePricebook.estimateTotal(trimmed)
                   && created.createdAt == created.updatedAt,
                   "9.08 a created pricebook entry is trimmed and carries the engine total")

            let seededJSON = """
            {"id":"\(created.id)","name":"Drain clearing","description":"Standard","category":"Plumbing",
             "laborHours":2,"laborRate":95,"materials":[],"materialMarkup":20,"jobCosts":[],
             "overhead":15,"margin":20,"estimateTotal":\(created.estimateTotal),
             "createdAt":"2026-09-01T08:00:00.000Z","updatedAt":"2026-09-01T08:00:00.000Z",
             "nestedUnknown":{"keep":true}}
            """
            let seeded = Canonical.Snapshot(payload: .init(pricebook: [try canonicalRecord(seededJSON)]))
            try Canonical.SnapshotRepository(primaryURL: pricebookURL).save(seeded)
            let reopened = AppStore(fileURL: pricebookURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let openedEntry = reopened.pricebookEntries.first { $0.id == created.id }
            var editedDraft = draft
            editedDraft.laborHours = 3
            guard let applied = succeed(
                reopened.commitPricebookEdit(id: created.id, opened: openedEntry, draft: editedDraft),
                "9.08 editing a pricebook entry commits"
            ) else { throw StoreTestError.missingFixture }
            expect(applied.createdAt == "2026-09-01T08:00:00.000Z" && applied.updatedAt != applied.createdAt
                   && applied.laborHours == 3,
                   "9.08 a pricebook edit preserves createdAt and restamps updatedAt")
            let afterEdit = try snapshot9(pricebookURL)
            expect(afterEdit.payload.pricebook!.first!.preservation.unknownFields["nestedUnknown"] != nil,
                   "9.08 a pricebook edit preserves unknown nested fields")
            expect(reopened.deletePricebookEntry(id: created.id), "9.08 deleting a pricebook entry reports true")
            expect(!reopened.deletePricebookEntry(id: created.id), "9.08 deleting an absent entry reports false")
        } catch { expect(false, "9.08 pricebook block aborted: \(error)") }

        // Tax set-aside settings: present stays present, absent stays absent.
        do {
            let settingsURL = phase9Directory.appendingPathComponent("Tax/store.json")
            let settingsJSON = """
            {"businessName":"Ada Electric","contactName":"","phone":"","email":"","address":"",
             "trade":"Plumbing","laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,
             "minimumJobFee":75,"travelFeePerMile":0,"emergencyMultiplier":1.5,"mileageRate":0.7,
             "paymentNotes":"","provider":"stripe","providerKey":"","providerKeys":{},"rules":[],
             "autoOutreachEnabled":false,"autoSendEmailEnabled":false,"appointmentRemindersEnabled":false,
             "appointmentConfirmTemplate":"","onMyWayTemplate":"","estimateFollowUpsEnabled":true,
             "autoInvoiceOnComplete":false,"autoEmailInvoiceOnComplete":false,"anthropicKey":"","groqKey":"",
             "reviewRequestEnabled":false,"reviewRequestTemplate":"","googleReviewLink":"",
             "reviewRequestDelayHours":3,"forwardCompat":"keep"}
            """
            let seeded = Canonical.Snapshot(payload: .init(settings: try canonicalRecord(settingsJSON)))
            try Canonical.SnapshotRepository(primaryURL: settingsURL).save(seeded)
            let store = AppStore(fileURL: settingsURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            expect(store.settings.taxIncomeRate == nil && store.settings.vehicleDeductionMethod == nil,
                   "9.08 an unset tax rate and vehicle election surface as unset, not zero")
            expect(store.taxSettingsValues.taxIncomeRate == nil,
                   "9.08 the estimator sees an absent rate as unset")
            let beforeNoop = pendingMutations(settingsURL).count
            expect(store.commitTaxSettings(
                NativeTaxSettingsDraft(taxIncomeRate: nil, vehicleDeductionMethod: nil)
            ), "9.08 an unset tax draft is an accepted no-op")
            let afterNoop = try snapshot9(settingsURL).payload.settings!
            expect(afterNoop.taxIncomeRate == nil && afterNoop.vehicleDeductionMethod == nil
                   && pendingMutations(settingsURL).count == beforeNoop,
                   "9.08 an unset tax draft never coerces absent into a value or null")
            expect(store.commitTaxSettings(
                NativeTaxSettingsDraft(taxIncomeRate: Decimal(string: "22"), vehicleDeductionMethod: .mileage)
            ), "9.08 the tax settings commit is durable")
            let saved = try snapshot9(settingsURL).payload.settings!
            expect(saved.taxIncomeRate == Decimal(string: "22") && saved.vehicleDeductionMethod == "mileage"
                   && saved.preservation.unknownFields["forwardCompat"] == .string("keep"),
                   "9.08 the tax settings commit merges only its two fields")
            expect(store.taxSettingsValues == NativeTaxSettingsValues(
                taxIncomeRate: Decimal(string: "22"), vehicleDeductionMethod: .mileage
            ), "9.08 the estimator reads the committed values back")
            expect(pendingMutations(settingsURL).count == beforeNoop + 1,
                   "9.08 only the real tax write enqueues a settings upsert")
            // 12.00b.3 (G2): the sheet seeds from the live record and its draft
            // commits through the same path.
            var editor = store.taxSettingsEditor
            expect(editor.rateText == "22" && editor.selectedMethod == .mileage
                   && editor.mileageRate == Decimal(string: "0.7"),
                   "12.00b.3 the tax sheet seeds String(rate), the stored method and the mileage rate")
            editor.rateText = " 12.5% "
            editor.select(.actual)
            if case .success(let draft) = editor.save() {
                expect(store.commitTaxSettings(draft), "12.00b.3 the sheet's draft commits")
            } else {
                expect(false, "12.00b.3 the sheet accepts \" 12.5% \" as parseFloat does")
            }
            let edited = try snapshot9(settingsURL).payload.settings!
            expect(edited.taxIncomeRate == Decimal(string: "12.5") && edited.vehicleDeductionMethod == "actual"
                   && edited.preservation.unknownFields["forwardCompat"] == .string("keep"),
                   "12.00b.3 the sheet's save writes the parsed rate and the new method only")
            expect(store.taxSettingsEditor.rateText == "12.5", "12.00b.3 the next open re-seeds from the saved rate")
            // Review M1: the blank-rate save also changes the method, so a skipped
            // or no-op commit fails here.
            var blankRate = store.taxSettingsEditor
            blankRate.rateText = ""
            blankRate.select(.mileage)
            if case .success(let draft) = blankRate.save() {
                expect(store.commitTaxSettings(draft), "12.00b.3 the blank-rate draft commits")
            } else {
                expect(false, "12.00b.3 a blank rate is not a refusal (RN leaves the rate out of the draft)")
            }
            let blankSaved = try snapshot9(settingsURL).payload.settings!
            expect(blankSaved.taxIncomeRate == Decimal(string: "12.5") && blankSaved.vehicleDeductionMethod == "mileage",
                   "12.00b.3 a blank rate keeps the stored rate and saves the new method (RN merges { ...full, ...draft })")
            // Restore the values the rest of this block asserts on.
            store.commitTaxSettings(NativeTaxSettingsDraft(taxIncomeRate: Decimal(string: "22"), vehicleDeductionMethod: .mileage))
            // The full settings write path must not drop the two fields.
            store.settings.businessName = "Ada Electric LLC"
            let rewritten = try snapshot9(settingsURL).payload.settings!
            expect(rewritten.businessName == "Ada Electric LLC"
                   && rewritten.taxIncomeRate == Decimal(string: "22")
                   && rewritten.vehicleDeductionMethod == "mileage",
                   "9.08 the settings edit path round-trips the tax fields")
        } catch { expect(false, "9.08 tax settings block aborted: \(error)") }

        // 12.00b.3 (G2, review M2): `tax_settings_saved` fires once per committed
        // sheet save with RN's properties (TaxSetAsideCard.tsx:61-64), including
        // the empty draft, and never for a blocked write, a refused rate or a
        // cancel. Each step mirrors the sheet: commit only after `save()` succeeds.
        do {
            let taxJSON = """
            {"businessName":"Ada Electric","contactName":"","phone":"","email":"","address":"",
             "trade":"Plumbing","laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,
             "minimumJobFee":75,"travelFeePerMile":0,"emergencyMultiplier":1.5,"mileageRate":0.7,
             "paymentNotes":"","provider":"stripe","providerKey":"","providerKeys":{},"rules":[],
             "autoOutreachEnabled":false,"autoSendEmailEnabled":false,"appointmentRemindersEnabled":false,
             "appointmentConfirmTemplate":"","onMyWayTemplate":"","estimateFollowUpsEnabled":true,
             "autoInvoiceOnComplete":false,"autoEmailInvoiceOnComplete":false,"anthropicKey":"","groqKey":"",
             "reviewRequestEnabled":false,"reviewRequestTemplate":"","googleReviewLink":"",
             "reviewRequestDelayHours":3}
            """
            let recorder = RecordingAnalytics()
            let taxURL = phase9Directory.appendingPathComponent("TaxAnalytics/store.json")
            try Canonical.SnapshotRepository(primaryURL: taxURL).save(
                Canonical.Snapshot(payload: .init(settings: try canonicalRecord(taxJSON)))
            )
            let store = AppStore(fileURL: taxURL, seedIfMissing: false, analytics: recorder,
                                 secureSettingsStore: hostTestSecureSettingsStore())
            func taxEvents() -> [[String: String]] {
                recorder.calls.filter { $0.event == "tax_settings_saved" }.map(\.properties)
            }
            let untouched = try Data(contentsOf: taxURL)

            // A refused rate raises the alert; the sheet never commits.
            var refused = store.taxSettingsEditor
            refused.rateText = "75"
            refused.select(.actual)
            let refusedResult = refused.save()
            expect(refusedResult == .failure(.rateOutOfRange), "12.00b.3 a 75% rate is refused before any commit")
            if case .success(let draft) = refusedResult { store.commitTaxSettings(draft) }
            // Cancel drops the edited copy; the sheet never commits.
            var cancelled = store.taxSettingsEditor
            cancelled.rateText = "20"
            cancelled.select(.mileage)
            _ = cancelled
            expect(taxEvents().isEmpty, "12.00b.3 a refused rate and a cancel emit no tax_settings_saved")
            let afterRefusedAndCancel = try Data(contentsOf: taxURL)
            expect(afterRefusedAndCancel == untouched, "12.00b.3 a refused rate and a cancel write nothing")

            // Blank rate, no method: the empty draft writes nothing but is tracked.
            if case .success(let draft) = store.taxSettingsEditor.save() {
                expect(draft == NativeTaxSettingsDraft(), "12.00b.3 an untouched unset sheet is the empty draft")
                expect(store.commitTaxSettings(draft), "12.00b.3 the empty draft is accepted")
            } else {
                expect(false, "12.00b.3 an untouched unset sheet saves")
            }
            expect(taxEvents() == [["hasIncomeRate": "false", "vehicleMethod": "unset"]],
                   "12.00b.3 the empty draft emits exactly one {hasIncomeRate: false, vehicleMethod: unset}")
            let afterEmptyDraft = try Data(contentsOf: taxURL)
            expect(afterEmptyDraft == untouched, "12.00b.3 the empty draft writes nothing")

            // A real sheet save.
            var sheet = store.taxSettingsEditor
            sheet.rateText = "15"
            sheet.select(.actual)
            if case .success(let draft) = sheet.save() {
                expect(store.commitTaxSettings(draft), "12.00b.3 the sheet save commits")
            } else {
                expect(false, "12.00b.3 15 + actual saves")
            }
            expect(taxEvents() == [
                ["hasIncomeRate": "false", "vehicleMethod": "unset"],
                ["hasIncomeRate": "true", "vehicleMethod": "actual"],
            ], "12.00b.3 the sheet save emits exactly one {hasIncomeRate: true, vehicleMethod: actual}")

            // Writes blocked (a newer snapshot schema): ensurePersistenceWritable
            // refuses before anything is written or tracked, empty draft included.
            let blockedURL = phase9Directory.appendingPathComponent("TaxAnalyticsBlocked/store.json")
            try FileManager.default.createDirectory(at: blockedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let blockedBytes = try Canonical.SnapshotCodec.encode(Canonical.Snapshot(
                schemaVersion: Canonical.Snapshot.currentSchemaVersion + 1,
                payload: .init(settings: try canonicalRecord(taxJSON))
            ))
            try blockedBytes.write(to: blockedURL, options: .atomic)
            let blockedRecorder = RecordingAnalytics()
            let blocked = AppStore(fileURL: blockedURL, seedIfMissing: false, analytics: blockedRecorder,
                                   secureSettingsStore: hostTestSecureSettingsStore())
            expect(!blocked.commitTaxSettings(NativeTaxSettingsDraft(taxIncomeRate: 15, vehicleDeductionMethod: .actual)),
                   "12.00b.3 a blocked store refuses the tax save")
            expect(!blocked.commitTaxSettings(NativeTaxSettingsDraft()), "12.00b.3 a blocked store refuses the empty draft too")
            expect(!blockedRecorder.calls.contains { $0.event == "tax_settings_saved" },
                   "12.00b.3 a blocked write emits no tax_settings_saved")
            let afterBlocked = try Data(contentsOf: blockedURL)
            expect(afterBlocked == blockedBytes, "12.00b.3 a blocked write leaves the snapshot bytes alone")
        } catch { expect(false, "12.00b.3 tax_settings_saved block aborted: \(error)") }

        // Import: commit report, provenance, history, same-file warning, undo.
        do {
            let importURL = phase9Directory.appendingPathComponent("Import/store.json")
            let customerJSON = """
            {"id":"c-seed","name":"Ada Electric","email":"ada@example.com","phone":"","address":"",
             "notes":"","createdAt":"2026-01-01"}
            """
            let seeded = Canonical.Snapshot(payload: .init(customers: [try canonicalRecord(customerJSON)]))
            try Canonical.SnapshotRepository(primaryURL: importURL).save(seeded)
            let store = AppStore(fileURL: importURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let rows = [
                ["Ada Electric", "ada@example.com"],
                ["New Co", "new@example.com"],
            ]
            guard let report = succeed(
                store.commitImport(
                    entity: .customers, rows: rows, mapping: ["name", "email"],
                    dateFormat: nil, fileHash: "hash-abc"
                ),
                "9.08 a customer import commits"
            ) else { throw StoreTestError.missingFixture }
            expect(report.counts.ok == 2 && report.counts.created == 1 && report.counts.matched == 1,
                   "9.08 the import report separates created from matched rows")
            let imported = try snapshot9(importURL)
            let createdCustomer = imported.payload.customers!.first { $0.name == "New Co" }!
            let matchedCustomer = imported.payload.customers!.first { $0.id == "c-seed" }!
            expect(createdCustomer.importBatchId == report.batchID && matchedCustomer.importBatchId == nil,
                   "9.08 import provenance is stamped on created records only")
            let importQueue = pendingMutations(importURL).filter { $0.table == "customers" }
            expect(importQueue.count == 1 && importQueue.first?.recordId == createdCustomer.id,
                   "9.08 only the created customer is published")
            expect(store.importHistory.count == 1 && store.importHistory.first?.batchId == report.batchID
                   && store.importHistory.first?.entity == "customers",
                   "9.08 the import records device-local history")
            expect(store.importBatch(entity: .customers, fileHash: "hash-abc")?.batchId == report.batchID,
                   "9.08 a same-file re-import is detectable by hash")
            expect(store.importBatch(entity: .customers, fileHash: "other-hash") == nil,
                   "9.08 a different file is not flagged")
            expect(store.undoImport(batchID: report.batchID), "9.08 undoing the import reports success")
            let undone = try snapshot9(importURL)
            expect(undone.payload.customers!.contains { $0.id == createdCustomer.id } == false
                   && undone.payload.customers!.contains { $0.id == "c-seed" },
                   "9.08 undo strips only the batch's own records")
            expect(pendingMutations(importURL).contains {
                $0.table == "customers" && $0.recordId == createdCustomer.id && $0.op == .delete
            }, "9.08 undo queues deletes for exactly the stripped records")
            expect(store.importHistory.isEmpty, "9.08 undo forgets the batch from local history")
            expect(!store.undoImport(batchID: report.batchID), "9.08 undoing an unknown batch reports false")
        } catch { expect(false, "9.08 import block aborted: \(error)") }

        // Invoice import joins the current customers; undo is per entity.
        do {
            let editURL = phase9Directory.appendingPathComponent("ImportEdit/store.json")
            let store = AppStore(fileURL: editURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            guard let customerReport = succeed(
                store.commitImport(
                    entity: .customers,
                    rows: [["From CSV", "csv@example.com"]],
                    mapping: ["name", "email"], dateFormat: nil, fileHash: "hash-csv"
                ),
                "9.08 the customer fixture import commits"
            ) else { throw StoreTestError.missingFixture }
            expect(customerReport.counts.created == 1, "9.08 the fixture customer is created")
            guard let invoiceReport = succeed(
                store.commitImport(
                    entity: .invoices,
                    rows: [["From CSV", "1250.50", "2026-04-10"]],
                    mapping: ["customer", "amount", "date"], dateFormat: .ymd, fileHash: "hash-inv"
                ),
                "9.08 an invoice import commits against the current customers"
            ) else { throw StoreTestError.missingFixture }
            let afterInvoiceImport = try snapshot9(editURL)
            let invoice = afterInvoiceImport.payload.invoices!.first!
            let joined = afterInvoiceImport.payload.customers!.first { $0.name == "From CSV" }!
            expect(invoice.importBatchId == invoiceReport.batchID && invoice.customerId == joined.id
                   && invoice.amount == Decimal(string: "1250.50"),
                   "9.08 an imported invoice carries its batch provenance and customer join")
            expect(store.undoImport(batchID: invoiceReport.batchID), "9.08 the invoice import can be undone")
            let afterUndo = try snapshot9(editURL)
            expect(afterUndo.payload.invoices!.isEmpty
                   && afterUndo.payload.customers!.contains { $0.name == "From CSV" },
                   "9.08 undoing the invoice import strips only invoices")
        } catch { expect(false, "9.08 invoice import block aborted: \(error)") }

        // The account boundary scrubs device-local import history.
        do {
            let scrubURL = phase9Directory.appendingPathComponent("Scrub/store.json")
            let store = AppStore(fileURL: scrubURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            _ = store.commitImport(
                entity: .expenses,
                rows: [["40", "2026-05-01", "fuel"]],
                mapping: ["amount", "date", "category"], dateFormat: .ymd, fileHash: "hash-scrub"
            )
            expect(store.importHistory.count == 1, "9.08 the scrub fixture records import history")
            try Canonical.SnapshotRepository(primaryURL: scrubURL).beginAccountScrub(scope: .live)
            // The App Group container is unavailable to a host-test process, so
            // the boundary runs against an injected suite + lock file.
            let suite = "com.tradeready.phase9.tests.\(UUID().uuidString)"
            let scrubbed = AppStore(
                fileURL: scrubURL,
                seedIfMissing: false,
                appGroupAccountScrubber: NativeAppGroupAccountScrubber(
                    suiteName: suite,
                    defaults: UserDefaults(suiteName: suite) ?? .standard,
                    lockFile: phase9Directory.appendingPathComponent("scrub.lock")
                ),
                secureSettingsStore: hostTestSecureSettingsStore()
            )
            expect(scrubbed.importHistory.isEmpty,
                   "9.08 the account boundary scrubs device-local import history")
        } catch { expect(false, "9.08 account boundary block aborted: \(error)") }

        // Task 10.07 (N3/N4/N6/B2) — appointment and review-request tap
        // routing, plus the review_ sweep-preservation guarantee. Same
        // pattern as the 10.06 inv_/rinv_ block above: fails closed before an
        // exact-owner binding exists, resolves an existing record for the
        // verified owner, and fails closed again for a record that isn't
        // there.
        do {
            let apptDirectory = directory.appendingPathComponent("AppointmentReview10_07", isDirectory: true)
            let apptURL = apptDirectory.appendingPathComponent("store.json")
            let apptStore = AppStore(fileURL: apptURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let apptCustomer = Customer(name: "Review Customer", email: "review@example.test", phone: "555-0177")
            let apptJob = Job(
                customerId: apptCustomer.id, customerName: apptCustomer.name,
                title: "Drain cleaning", status: .inProgress, laborRate: 95
            )
            expect(apptStore.upsert(apptCustomer), "10.07 appointment/review fixture customer saves")
            expect(apptStore.upsert(apptJob), "10.07 appointment/review fixture job saves")

            // Tap routing is inert before an exact-owner workspace is bound —
            // fails closed rather than opening a stale or foreign job.
            apptStore.selectedTab = .today
            apptStore.requestAppointmentConfirmationReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .today && apptStore.pendingAppointmentConfirmationJobID == nil,
                   "10.07 appointment tap is inert before an exact-owner workspace is bound")
            apptStore.requestReviewRequestReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .today && apptStore.pendingReviewRequestJobID == nil,
                   "10.07 review tap is inert before an exact-owner workspace is bound")

            let apptBinding = String(repeating: "7", count: 64)
            apptStore.scheduleBookingTestSeedSignedInOwner(subject: "user-10.07", binding: apptBinding)

            // `requestAppointmentConfirmationReview` is the same method
            // `TradeReadyNativeApp`'s `openOwnedRoute` calls for a decoded
            // `.appointmentConfirm` notification payload.
            apptStore.requestAppointmentConfirmationReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .jobs && apptStore.deepLinkedJobID == apptJob.id
                   && apptStore.pendingAppointmentConfirmationJobID == apptJob.id,
                   "10.07 an appointment tap routes to the exact-owner job and opens the editable confirmation sheet")
            apptStore.dismissPendingAppointmentConfirmation(jobID: apptJob.id)
            expect(apptStore.pendingAppointmentConfirmationJobID == nil,
                   "10.07 the appointment confirmation sheet can be acknowledged exactly for its job — nothing auto-sends")

            apptStore.selectedTab = .today
            apptStore.requestAppointmentConfirmationReview(jobID: "no-such-job")
            expect(apptStore.selectedTab == .today && apptStore.pendingAppointmentConfirmationJobID == nil,
                   "10.07 a missing job fails closed instead of inventing a destination")

            // Review tap routing needs a resolvable draft (contact info) —
            // `requestReviewRequestReview` is the same method `openOwnedRoute`
            // calls for a decoded `.reviewRequest` payload.
            apptStore.requestReviewRequestReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .jobs && apptStore.deepLinkedJobID == apptJob.id
                   && apptStore.pendingReviewRequestJobID == apptJob.id,
                   "10.07 a review tap routes to the exact-owner job and opens the editable draft sheet")
            expect(apptStore.reviewRequestDraft(jobID: apptJob.id) != nil,
                   "10.07 the review sheet resolves a live-customer draft — nothing is pre-sent")
            apptStore.dismissPendingReviewRequest(jobID: apptJob.id)
            expect(apptStore.pendingReviewRequestJobID == nil,
                   "10.07 the review sheet can be acknowledged exactly for its job")

            apptStore.selectedTab = .today
            apptStore.requestReviewRequestReview(jobID: "no-such-job")
            expect(apptStore.selectedTab == .today && apptStore.pendingReviewRequestJobID == nil,
                   "10.07 a missing job fails closed for the review tap too")

            apptStore.scheduleBookingTestClearOwner()
            apptStore.requestAppointmentConfirmationReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .today && apptStore.pendingAppointmentConfirmationJobID == nil,
                   "10.07 signing out revokes appointment routing even for a previously-valid job")
            apptStore.requestReviewRequestReview(jobID: apptJob.id)
            expect(apptStore.selectedTab == .today && apptStore.pendingReviewRequestJobID == nil,
                   "10.07 signing out revokes review routing even for a previously-valid job")
        }

        // Task 10.07 (N4, B2) — the critical review_ rebuild guarantee,
        // combined at ONE layer: arm the one-shot, sweep it mid-window on the
        // ARMING store (proving the sweep never re-arms from the sweep
        // time), then go through a REAL simulated relaunch — a second
        // AppStore over the same persisted file, seeded through the real
        // `activateReviewRequests` reload path (`scheduleBookingTestReloadReviewRequests`,
        // not a bypass) — and sweep the RELAUNCHED store at a mid-window
        // `now` too, asserting the identical identifier and fire date. Then
        // prove it drops after firing, and after being marked sent.
        do {
            let sweepDirectory = directory.appendingPathComponent("ReviewSweep10_07", isDirectory: true)
            let sweepURL = sweepDirectory.appendingPathComponent("store.json")
            let sweepStore = AppStore(fileURL: sweepURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let sweepBinding = String(repeating: "9", count: 64)
            sweepStore.scheduleBookingTestSeedSignedInOwner(subject: "user-10.07-sweep", binding: sweepBinding)

            let sweepCustomer = Customer(name: "Sweep Customer", email: "sweep@example.test", phone: "555-0188")
            let sweepJob = Job(
                customerId: sweepCustomer.id, customerName: sweepCustomer.name,
                title: "Water heater swap", status: .inProgress, laborRate: 95
            )
            expect(sweepStore.upsert(sweepCustomer), "10.07 sweep fixture customer saves")
            expect(sweepStore.upsert(sweepJob), "10.07 sweep fixture job saves")
            sweepStore.settings.reviewRequestEnabled = true
            sweepStore.settings.reviewRequestDelayHours = 2

            // 1. Arm the one-shot.
            let armedAt = Date(timeIntervalSince1970: 1_800_000_000)
            let outcome = sweepStore.completeJob(id: sweepJob.id, from: .inProgress, on: armedAt)
            expect(outcome == .completed, "10.07 completing the job arms the review_ one-shot")

            let expectedFire = armedAt.addingTimeInterval(2 * 3600)
            let identifier = "review_\(sweepJob.id)"
            let midWindow = armedAt.addingTimeInterval(3600) // 1h into the 2h window

            // 3a. Sweep the ARMING store at a mid-window `now` — a
            // cancel-all-then-rebuild sweep before any relaunch happens.
            let armingSweep = sweepStore.reviewRequestNotifications(now: midWindow)
            let armingItem = armingSweep.first(where: { $0.identifier == identifier })
            expect(armingItem != nil, "10.07 a mid-window sweep on the arming store still finds the pending review_ nudge")
            expect(armingItem?.fireDate == expectedFire,
                   "10.07 a mid-window sweep on the arming store rebuilds the SAME fire instant, never one re-armed from the sweep time")

            // 2. Simulate a relaunch: a NEW AppStore instance over the same
            // persisted store file, activated through the REAL
            // `activateReviewRequests` reload path (not the identity-only
            // seed) — this is the exact method a live launch's
            // `applyAuthenticatedIdentityOutcome` calls to repopulate
            // `reviewRequestRecords` from the on-disk
            // NativeReviewRequestStore for the verified owner.
            let relaunched = AppStore(fileURL: sweepURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-10.07-sweep", binding: sweepBinding)
            expect(relaunched.jobs.first(where: { $0.id == sweepJob.id })?.status == .complete,
                   "10.07 the completed job's canonical status survives the simulated relaunch")
            relaunched.scheduleBookingTestReloadReviewRequests(accountBinding: sweepBinding)

            // 3b + 4. Sweep the RELAUNCHED store at the SAME mid-window
            // `now` — the identical review_ identifier and fire date must
            // survive the relaunch AND the sweep together, at one layer.
            let relaunchedSweep = relaunched.reviewRequestNotifications(now: midWindow)
            let relaunchedItem = relaunchedSweep.first(where: { $0.identifier == identifier })
            expect(relaunchedItem != nil,
                   "10.07 a mid-window sweep on the RELAUNCHED store still finds the pending review_ nudge")
            expect(relaunchedItem?.fireDate == expectedFire,
                   "10.07 a mid-window sweep on the RELAUNCHED store rebuilds the identical fire instant as before the relaunch")

            // 5a. A sweep landing AFTER the fire instant must not re-nag
            // late — it drops out of the plan entirely rather than firing on
            // the next sweep, even on the relaunched store.
            let afterFire = relaunched.reviewRequestNotifications(now: expectedFire.addingTimeInterval(60))
            expect(afterFire.first(where: { $0.identifier == identifier }) == nil,
                   "10.07 a sweep after the fire instant never re-nags late, including after a relaunch")

            // 5b. Marking the request sent clears it from the plan for
            // good — the toggle-off/sent semantics are not sweep-rebuilt.
            sweepStore.markReviewRequestSent(jobID: sweepJob.id, fallback: nil, channel: .sms, now: expectedFire.addingTimeInterval(-60))
            let afterSent = sweepStore.reviewRequestNotifications(now: midWindow)
            expect(afterSent.first(where: { $0.identifier == identifier }) == nil,
                   "10.07 marking the request sent removes it from every subsequent sweep")
        }

        // Task 10.08 (N6), DELIBERATELY REVERSED by the final-review fix
        // wave (I1, RN parity option (a), contract §9.6): 10.08 made the
        // appt_/review_ taps fail closed for an archived job, but the
        // selectors still schedule appt_/review_ for archived jobs (RN
        // `utils/archive.ts`: notifications deliberately still see archived
        // records) and RN's `appointment_confirm`/`review_request` taps
        // navigate with no archive check — so every delivered notification
        // for an archived job was a dead tap. Now: an archived job's
        // notification is SCHEDULED and its tap ROUTES; only a missing job
        // or a non-exact workspace fails closed. (est_ keeps its own recorded
        // estimate_sent + not-archived rule.)
        do {
            let archivedDirectory = directory.appendingPathComponent("ArchivedRouting10_08", isDirectory: true)
            let archivedURL = archivedDirectory.appendingPathComponent("store.json")
            let archivedStore = AppStore(fileURL: archivedURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let archivedBinding = String(repeating: "8", count: 64)
            archivedStore.scheduleBookingTestSeedSignedInOwner(subject: "user-10.08-archived", binding: archivedBinding)

            let archivedCustomer = Customer(name: "Archived Customer", email: "archived@example.test", phone: "555-0199")
            let archivedJob = Job(
                customerId: archivedCustomer.id, customerName: archivedCustomer.name,
                title: "Roof patch", status: .inProgress, laborRate: 95
            )
            expect(archivedStore.upsert(archivedCustomer), "10.08 archived-routing fixture customer saves")
            expect(archivedStore.upsert(archivedJob), "10.08 archived-routing fixture job saves")

            // Baseline: both routes succeed for the live, non-archived job.
            archivedStore.requestAppointmentConfirmationReview(jobID: archivedJob.id)
            expect(archivedStore.pendingAppointmentConfirmationJobID == archivedJob.id,
                   "10.08 appointment tap succeeds for a live job before archiving")
            archivedStore.dismissPendingAppointmentConfirmation(jobID: archivedJob.id)
            archivedStore.requestReviewRequestReview(jobID: archivedJob.id)
            expect(archivedStore.pendingReviewRequestJobID == archivedJob.id,
                   "10.08 review tap succeeds for a live job before archiving")
            archivedStore.dismissPendingReviewRequest(jobID: archivedJob.id)

            // Archive the job (same record id, archivedAt now stamped).
            var archivedRecord = archivedJob
            archivedRecord.archivedAt = "2026-09-23T00:00:00.000Z"
            expect(archivedStore.upsert(archivedRecord), "10.08 archiving the job saves")

            // Final-review I1: the archived job still routes for both taps.
            archivedStore.selectedTab = .today
            archivedStore.deepLinkedJobID = nil
            archivedStore.requestAppointmentConfirmationReview(jobID: archivedJob.id)
            expect(archivedStore.selectedTab == .jobs
                       && archivedStore.deepLinkedJobID == archivedJob.id
                       && archivedStore.pendingAppointmentConfirmationJobID == archivedJob.id,
                   "I1: an archived job's appointment tap routes to the job (RN parity), not a dead tap")
            archivedStore.dismissPendingAppointmentConfirmation(jobID: archivedJob.id)

            archivedStore.selectedTab = .today
            archivedStore.deepLinkedJobID = nil
            archivedStore.requestReviewRequestReview(jobID: archivedJob.id)
            expect(archivedStore.selectedTab == .jobs
                       && archivedStore.deepLinkedJobID == archivedJob.id
                       && archivedStore.pendingReviewRequestJobID == archivedJob.id,
                   "I1: an archived job's review tap routes to the review draft (RN parity), not a dead tap")
            archivedStore.dismissPendingReviewRequest(jobID: archivedJob.id)

            // Missing record still fails closed for both taps.
            archivedStore.selectedTab = .today
            archivedStore.requestAppointmentConfirmationReview(jobID: "job-does-not-exist")
            archivedStore.requestReviewRequestReview(jobID: "job-does-not-exist")
            expect(archivedStore.selectedTab == .today
                       && archivedStore.pendingAppointmentConfirmationJobID == nil
                       && archivedStore.pendingReviewRequestJobID == nil,
                   "I1: a missing job id still fails closed for the appointment and review taps")

            // Foreign / non-exact workspace still fails closed: the same
            // archived job id under a signed-out (non-owner) session routes
            // nowhere.
            archivedStore.scheduleBookingTestClearOwner()
            archivedStore.selectedTab = .today
            archivedStore.requestAppointmentConfirmationReview(jobID: archivedJob.id)
            archivedStore.requestReviewRequestReview(jobID: archivedJob.id)
            expect(archivedStore.selectedTab == .today
                       && archivedStore.pendingAppointmentConfirmationJobID == nil
                       && archivedStore.pendingReviewRequestJobID == nil,
                   "I1: without the exact owner workspace the archived job's taps still fail closed")
        }

        // Task 10.08 (N6) — rinv_ tap routing had NO coverage at all before
        // this task. Mirrors the inv_/appt_/review_ pattern: inert before an
        // exact-owner binding, resolves the exact record for the verified
        // owner (here: the latest GENERATED invoice for the rule, matching
        // `App.tsx`'s `recurring_invoice` handler — not just a tab switch),
        // falls back to the plain Invoices tab when nothing has generated
        // yet, and fails closed for a deleted rule or a signed-out session.
        do {
            let rinvDirectory = directory.appendingPathComponent("RecurringRouting10_08", isDirectory: true)
            let rinvURL = rinvDirectory.appendingPathComponent("store.json")
            let rinvStore = AppStore(fileURL: rinvURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let rinvCustomer = Customer(name: "Maintenance Customer", email: "maint@example.test")
            expect(rinvStore.upsert(rinvCustomer), "10.08 rinv fixture customer saves")

            // Inert before an exact-owner workspace is bound.
            rinvStore.selectedTab = .today
            rinvStore.requestRecurringInvoiceReview(ruleID: "rinv-10-08")
            expect(rinvStore.selectedTab == .today,
                   "10.08 recurring-invoice tap is inert before an exact-owner workspace is bound")

            let rinvBinding = String(repeating: "6", count: 64)
            rinvStore.scheduleBookingTestSeedSignedInOwner(subject: "user-10.08-rinv", binding: rinvBinding)

            let rule = Canonical.RecurringInvoice(
                id: "rinv-10-08", customerId: rinvCustomer.id, customerName: rinvCustomer.name,
                description: "Quarterly service", amount: 200, dueDays: 30,
                cadence: "monthly", endCondition: "never", endCount: nil, endDate: nil,
                occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: "2026-10-01",
                isActive: true, createdAt: "2026-09-01", autoSendEnabled: false)
            expect(rinvStore.createRecurringInvoice(rule), "10.08 rinv fixture plan creates")

            // Success, but nothing has generated yet: routes to the plain
            // Invoices tab (RN's `InvoiceList` with no `openInvoiceId`)
            // rather than inventing a destination.
            rinvStore.deepLinkedInvoiceID = nil
            rinvStore.selectedTab = .today
            rinvStore.requestRecurringInvoiceReview(ruleID: rule.id)
            expect(rinvStore.selectedTab == .invoices && rinvStore.deepLinkedInvoiceID == nil,
                   "10.08 a recurring-invoice tap with no generated occurrence yet falls back to the plain Invoices tab")

            // Generate two occurrences; the tap must resolve the LATEST one
            // (highest occurrenceNumber), matching App.tsx's `reduce` over
            // `occurrenceNumber`.
            expect(rinvStore.runRecurringInvoiceGeneration(today: "2026-10-01"), "10.08 first occurrence generates")
            expect(rinvStore.runRecurringInvoiceGeneration(today: "2026-11-01"), "10.08 second occurrence generates")
            let latestID = rinvStore.scheduleBookingTestLatestGeneratedInvoiceID(ruleID: rule.id)
            expect(latestID != nil, "10.08 two occurrences exist ahead of the routing assertion")

            rinvStore.selectedTab = .today
            rinvStore.deepLinkedInvoiceID = nil
            rinvStore.requestRecurringInvoiceReview(ruleID: rule.id)
            expect(rinvStore.selectedTab == .invoices && rinvStore.deepLinkedInvoiceID == latestID
                   && rinvStore.deepLinkedOutreachInvoiceID == nil,
                   "10.08 a recurring-invoice tap resolves the exact latest generated invoice, not just the tab")

            // A deleted rule fails closed instead of inventing a destination.
            rinvStore.selectedTab = .today
            rinvStore.deepLinkedInvoiceID = nil
            rinvStore.requestRecurringInvoiceReview(ruleID: "no-such-rule")
            expect(rinvStore.selectedTab == .today && rinvStore.deepLinkedInvoiceID == nil,
                   "10.08 a missing recurring-invoice rule fails closed instead of inventing a destination")

            // Signing out revokes routing even for a previously-valid rule.
            rinvStore.scheduleBookingTestClearOwner()
            rinvStore.selectedTab = .today
            rinvStore.deepLinkedInvoiceID = nil
            rinvStore.requestRecurringInvoiceReview(ruleID: rule.id)
            expect(rinvStore.selectedTab == .today && rinvStore.deepLinkedInvoiceID == nil,
                   "10.08 signing out revokes recurring-invoice routing even for a previously-valid rule")
        }

        // Task 10.08 (N5) — schedule-key audit: every field the five
        // notification selectors read must change
        // `estimateFollowUpNotificationScheduleKey`, and fields the
        // selectors never read (expenses; insight mutes and setup-checklist
        // state are separate 10.03 stores the key never touches at all —
        // confirmed by inspection, not exercised here) must NOT change it.
        do {
            let keyDirectory = directory.appendingPathComponent("ScheduleKey10_08", isDirectory: true)
            let keyURL = keyDirectory.appendingPathComponent("store.json")
            let keyStore = AppStore(fileURL: keyURL, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let keyBinding = String(repeating: "5", count: 64)
            keyStore.scheduleBookingTestSeedSignedInOwner(subject: "user-10.08-key", binding: keyBinding)

            let keyCustomer = Customer(name: "Key Customer", email: "key@example.test", phone: "555-0111")
            expect(keyStore.upsert(keyCustomer), "10.08 schedule-key fixture customer saves")

            // est_: job id/status already covered pre-10.08; customerName and
            // title (both read into the notification's title/body) were
            // missing from the key before this task's fix.
            var estimateJob = Job(
                customerId: keyCustomer.id, customerName: keyCustomer.name,
                title: "Water heater estimate", status: .lead, laborRate: 90
            )
            expect(keyStore.upsert(estimateJob), "10.08 schedule-key estimate fixture saves")
            expect(keyStore.markEstimateSent(id: estimateJob.id, from: .lead), "10.08 schedule-key estimate marks sent")
            let keyAfterEstimateSent = keyStore.estimateFollowUpNotificationScheduleKey

            estimateJob.status = .estimateSent
            estimateJob.title = "Water heater estimate — revised scope"
            expect(keyStore.upsert(estimateJob), "10.08 schedule-key estimate title edit saves")
            let keyAfterEstimateTitle = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterEstimateTitle != keyAfterEstimateSent,
                   "10.08 an est_ job's title (used in the notification body) changes the schedule key")

            // review_: the record's customerName/job title feed the body,
            // and settings.reviewRequestDelayHours feeds the rebuilt fire
            // date — none were in the key before this task's fix.
            let reviewJob = Job(
                customerId: keyCustomer.id, customerName: keyCustomer.name,
                title: "Gutter cleanup", status: .inProgress, laborRate: 90
            )
            expect(keyStore.upsert(reviewJob), "10.08 schedule-key review fixture saves")
            keyStore.settings.reviewRequestEnabled = true
            let outcome = keyStore.completeJob(id: reviewJob.id, from: .inProgress)
            expect(outcome == .completed, "10.08 schedule-key review fixture completes (arms review_)")
            let keyAfterReviewArmed = keyStore.estimateFollowUpNotificationScheduleKey

            keyStore.settings.reviewRequestDelayHours = keyStore.settings.reviewRequestDelayHours + 5
            let keyAfterDelayChange = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterDelayChange != keyAfterReviewArmed,
                   "10.08 reviewRequestDelayHours (feeds the rebuilt review_ fire date) changes the schedule key")

            // inv_: invoice.customer/number feed the title/body, and the
            // LINKED JOB'S STATUS drives dunning eligibility — none were in
            // the key before this task's fix.
            var invoiceJob = Job(
                customerId: keyCustomer.id, customerName: keyCustomer.name,
                title: "Deposit job", status: .inProgress, laborRate: 90
            )
            expect(keyStore.upsert(invoiceJob), "10.08 schedule-key invoice-linked job saves")
            var keyInvoice = Invoice(
                customerId: keyCustomer.id, customer: keyCustomer.name, number: "INV-KEY-1",
                amount: 300, due: Date(timeIntervalSince1970: 1_800_000_000)
            )
            keyStore.upsert(keyInvoice)
            expect(keyStore.scheduleBookingTestLinkInvoiceToJob(invoiceID: keyInvoice.id, jobID: invoiceJob.id),
                   "10.08 schedule-key invoice links to its job")
            let keyAfterInvoiceCreated = keyStore.estimateFollowUpNotificationScheduleKey

            keyInvoice.customer = "Key Customer (renamed)"
            keyStore.upsert(keyInvoice)
            let keyAfterInvoiceCustomerRename = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterInvoiceCustomerRename != keyAfterInvoiceCreated,
                   "10.08 an invoice's customer name (used in the reminder title) changes the schedule key")

            invoiceJob.status = .complete
            expect(keyStore.upsert(invoiceJob), "10.08 schedule-key invoice-linked job completes")
            let keyAfterLinkedJobComplete = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterLinkedJobComplete != keyAfterInvoiceCustomerRename,
                   "10.08 the linked job's status (drives inv_ dunning eligibility) changes the schedule key")

            // rinv_: rule.customerName feeds the body — was missing before
            // this task's fix.
            let rinvRule = Canonical.RecurringInvoice(
                id: "rinv-key-1", customerId: keyCustomer.id, customerName: keyCustomer.name,
                description: "Key plan", amount: 150, dueDays: 30,
                cadence: "monthly", endCondition: "never", endCount: nil, endDate: nil,
                occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: "2026-12-01",
                isActive: true, createdAt: "2026-09-01", autoSendEnabled: false)
            expect(keyStore.createRecurringInvoice(rinvRule), "10.08 schedule-key rinv fixture saves")
            let keyAfterRinvCreated = keyStore.estimateFollowUpNotificationScheduleKey

            var renamedRule = rinvRule
            renamedRule.customerName = "Key Customer (rinv renamed)"
            expect(keyStore.updateRecurringInvoice(renamedRule), "10.08 schedule-key rinv rename saves")
            let keyAfterRinvRename = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterRinvRename != keyAfterRinvCreated,
                   "10.08 a recurring rule's customerName (used in the rinv_ body) changes the schedule key")

            // Fields the selectors never read must NOT change the key —
            // folding them in would only cause redundant reconciles.
            let keyBeforeExpense = keyStore.estimateFollowUpNotificationScheduleKey
            keyStore.upsert(Expense(amount: 42, date: .now, category: .fuel))
            let keyAfterExpense = keyStore.estimateFollowUpNotificationScheduleKey
            expect(keyAfterExpense == keyBeforeExpense,
                   "10.08 adding an expense (not read by any notification selector) leaves the schedule key unchanged")
        }

        // MARK: - Task 10.09 (B1): AppStore's derived-state seam wiring.
        //
        // The full network sync path is not exercisable in this host-test
        // binary: `BuildEnvironment.supabaseURL`/`supabasePublishableKey`
        // read `Bundle.main`'s Info.plist, which is empty here, so
        // `syncCoordinatorIfConfigured()` always returns `nil` and
        // `syncNowAndWait`/`performBackgroundRefresh` short-circuit before
        // ever reaching a pull. The seam's own gating (never invoked on
        // offline/signed-out/a failed push, since the pull closure itself is
        // never called in those cases) is instead proven by
        // `native/run-sync-coordinator-tests.sh`'s existing
        // `offlinePullCount == 0` / `signedOutPullCount == 0` /
        // `environmentPullCount == 0` assertions around `.offline`,
        // `.notAuthenticated`, and `.failed` outcomes — every one of those
        // guards runs, in `AppStore.pullDeltaIfPossible`, strictly before the
        // `derivedStatePublisher.publish` call this task added. The
        // publisher's own failure-isolation/owner-race/reset contract is
        // unit-tested directly in `native/run-background-refresh-tests.sh`.
        //
        // This block instead proves AppStore's wiring of the seam: the
        // cached business snapshot builds from real canonical data, the
        // notification hook is reached through `derivedStatePublisher`, a
        // registered (Phase 11 widget mirror stand-in) observer receives the
        // exact committed snapshot, and owner-binding gating uses the
        // store's real `verifiedAccountBinding`.
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1009-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            let snapshot = Canonical.Snapshot(payload: Canonical.SnapshotPayload())
            try Canonical.SnapshotRepository(primaryURL: url).save(snapshot)
            let store = AppStore(fileURL: url, seedIfMissing: false,
                                 subscriptionService: StoreSubscriptionServiceStub(),
                                 secureSettingsStore: hostTestSecureSettingsStore())
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-10.09", binding: "bind-10.09")

            var notifyCalls = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            var observed: [NativeBusinessSnapshot] = []
            store.registerDerivedStateObserver { observed.append($0) }

            expect(store.cachedBusinessSnapshot == nil, "10.09 the cache is empty before any commit")
            await store.derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: "bind-10.09")
            expect(notifyCalls == 1, "10.09 publish reaches the notification hook exactly once")
            expect(store.cachedBusinessSnapshot != nil, "10.09 publish refreshes the cached business snapshot")
            expect(observed.count == 1 && observed.first == store.cachedBusinessSnapshot,
                   "10.09 a registered observer receives the exact committed snapshot")

            // Owner mismatch: no output runs, and the prior good cache and
            // notify/observer call counts are left completely untouched.
            await store.derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: "someone-else")
            expect(notifyCalls == 1 && observed.count == 1,
                   "10.09 a mismatched owner binding skips every output and leaves prior outputs intact")

            // `applyCompletedSignOutState` (private; exercised end-to-end by
            // the account-deletion/sign-out suites) calls
            // `derivedStatePublisher.reset()` on the exact same instance
            // exposed here. Prove that call clears the cache at the account
            // boundary, so a later signed-in owner's coach cold start can
            // never read a prior owner's cached snapshot.
            store.scheduleBookingTestClearOwner()
            store.derivedStatePublisher.reset()
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 resetting the seam at the account boundary clears the cached snapshot")
        }

        // MARK: - Task 10.09 (B1) fix round 1: real call-site coverage.
        //
        // The controller's review found the "exactly once" claim was not
        // structural (`pullDeltaIfPossible` has several direct callers) and
        // that the cache leaked across account boundaries. The contract is
        // now "exactly once per committed canonical sync commit" (several
        // legitimate commit sites, ordered by a generation guard — see
        // `native/run-background-refresh-tests.sh`), the cache clears at
        // every account boundary and reads fail-closed by owner, and
        // observers are app-lifetime. These tests drive the REAL call sites
        // (`runBookingIntakeAfterVerifiedPull`, `cancelPasswordRecovery`)
        // through the `ScheduleBookingTestDelta` harness rather than calling
        // `derivedStatePublisher` directly. The real `signOut()` is NOT
        // exercised here — see the inline comment at its test below for why
        // (it hangs in this host-test binary on App Group container scrub).

        // A committed delta pull with nothing for intake to convert
        // publishes exactly once — from the pull's own commit.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "1009-pull-once")
            seed08Owner(store)
            var notifyCalls = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            var observed = 0
            store.registerDerivedStateObserver { _ in observed += 1 }
            let outcome = await store.runBookingIntakeAfterVerifiedPull()
            expect(outcome == .noChange,
                   "10.09 fix1: sanity — no booking requests, so the pull is the only commit this call makes")
            expect(notifyCalls == 1,
                   "10.09 fix1: a committed delta pull with no intake follow-up publishes exactly once")
            expect(observed == 1,
                   "10.09 fix1: exactly one observer notification for the one commit")
            expect(store.cachedBusinessSnapshot != nil,
                   "10.09 fix1: the cache reflects the committed pull")
        }

        // A partial pull (some tables failed, but others committed) still
        // publishes from what it DID commit — it is not a pre-commit
        // failure, since `apply`/`save`/cursor-save all already succeeded
        // before `outcome.failedTables` is even inspected.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "1009-partial")
            seed08Owner(store)
            delta.handler = { local, cursor in
                NativeDeltaPullOutcome(snapshot: local, cursor: cursor,
                                      failedTables: ["invoices"], lastDiagnosticCode: "pull/invoices-500")
            }
            var notifyCalls = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(notifyCalls == 1,
                   "10.09 fix1: a partial pull (failedTables non-empty) still publishes from its committed snapshot")
            expect(store.cachedBusinessSnapshot != nil,
                   "10.09 fix1: a partial pull still refreshes the cache")
        }

        // The booking-intake local commit is its OWN commit, distinct from
        // the pull's — it must publish a second time, from the post-intake
        // snapshot, not leave the widget/coach cache on the pre-intake data.
        do {
            let delta = ScheduleBookingTestDelta()
            let booked = request08(id: "bk-1009r", status: "booked", slot: slot08())
            let (store, _) = try seed08Store(requests: [booked], settings: settings08(),
                                             delta: delta, tag: "1009-intake-republish")
            seed08Owner(store)
            var observed: [NativeBusinessSnapshot] = []
            store.registerDerivedStateObserver { observed.append($0) }
            let outcome = await store.runBookingIntakeAfterVerifiedPull(
                makeCustomerID: { "c_1009_1" }, nowISO: { "2026-09-20T12:00:00.000Z" })
            if case .applied = outcome {
                expect(true, "10.09 fix1: sanity — intake applies for a convertible booked request")
            } else {
                expect(false, "10.09 fix1: sanity — intake applies for a convertible booked request")
            }
            expect(observed.count == 2,
                   "10.09 fix1: the intake commit publishes a SECOND time, after the pull's own first publish")
            expect(observed.first?.totalCustomers == 0,
                   "10.09 fix1: the pull's own (first) publish reflects the PRE-intake snapshot — no customer yet")
            expect(observed.last?.totalCustomers == 1,
                   "10.09 fix1: the intake commit's (second) publish reflects the POST-intake snapshot — the converted customer exists")
            expect(store.cachedBusinessSnapshot == observed.last,
                   "10.09 fix1: the cache reflects the latest (post-intake) commit, not the pull's stale one")
        }

        // Account boundary: a REAL sign-out and a REAL recovery-signed-out
        // transition each clear the cache; a registered (11.01 widget
        // mirror stand-in) observer survives both and still receives the
        // next publish after the next sign-in, per the controller's ruling
        // that reset() clears owner data only, never observer registrations.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "1009-signout-boundary")
            seed08Owner(store)
            var observed = 0
            store.registerDerivedStateObserver { _ in observed += 1 }
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(store.cachedBusinessSnapshot != nil, "10.09 fix1: sanity — the cache is populated before sign-out")
            expect(observed == 1, "10.09 fix1: sanity — the observer saw the pre-sign-out publish")

            // The REAL `signOut()` is not safely callable in this host-test
            // binary: it runs `NativeAppGroupAccountScrubber.scrub()`, which
            // tries to create/scrub the App Group container directory —
            // with no App Group entitlement in a plain `swiftc` binary that
            // call hangs indefinitely (`mkdirat` never returns; verified by
            // sampling a stuck process during this fix round — see the
            // report addendum). `applyCompletedSignOutState` — the private
            // method that call eventually reaches — is exercised end-to-end
            // by the real account-deletion/sign-out suites elsewhere;
            // here we instead call the exact one line it added
            // (`derivedStatePublisher.reset()`, on this same store instance)
            // directly, which is the established pattern this file already
            // uses for account-boundary coverage (see the pre-existing
            // "resetting the seam at the account boundary" case above).
            store.scheduleBookingTestClearOwner()
            store.derivedStatePublisher.reset()
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 fix1: the account-boundary reset() clears the cached snapshot")

            // Sign back in (test seam) and publish again: the SAME observer
            // registered before sign-out must still be called — it was
            // never unregistered by reset().
            seed08Owner(store, subject: "user-1b", binding: "bind-1b")
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(observed == 2,
                   "10.09 fix1: the observer registered before sign-out still receives the next publish after sign-in")
            expect(store.cachedBusinessSnapshot != nil,
                   "10.09 fix1: the cache repopulates for the new owner after sign-in")
        }
        do {
            let (store, dir) = try seed08Store(tag: "1009-recovery-boundary")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-r1", binding: "bind-r1")
            var observed = 0
            store.registerDerivedStateObserver { _ in observed += 1 }
            let snapshot = try snapshot08(dir.appendingPathComponent("store.json"))
            await store.derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: "bind-r1")
            expect(store.cachedBusinessSnapshot != nil, "10.09 fix1: sanity — the cache is populated before recovery sign-out")
            expect(observed == 1, "10.09 fix1: sanity — the observer saw the pre-recovery-sign-out publish")

            // `cancelPasswordRecovery()` is the real production entry point
            // that calls `applyRecoverySignedOutState()`. With no live
            // Supabase session/config in this host-test binary it takes the
            // local-only branch (`sessionStore.clearSupabaseSession()`) but
            // unconditionally still reaches `applyRecoverySignedOutState()`,
            // including the seam's `reset()` call, exactly as production does.
            await store.cancelPasswordRecovery()
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 fix1: a real recovery-signed-out transition clears the cached snapshot")

            store.scheduleBookingTestSeedSignedInOwner(subject: "user-r2", binding: "bind-r2")
            await store.derivedStatePublisher.publish(canonical: snapshot, expectedOwnerBinding: "bind-r2")
            expect(observed == 2,
                   "10.09 fix1: the observer registered before the recovery sign-out still receives the next publish")
        }

        // A real `useAnotherAccount()`, on its success path (an injected
        // identity activator — see `scheduleBookingTestSeedIdentityActivator`,
        // which only needs `activator.clearSession()` to be reachable, a
        // Keychain-only call with no network/App-Group filesystem access),
        // clears the cache; the registered observer survives it exactly
        // like the other two account-boundary transitions above.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "1009-useanother-boundary")
            seed08Owner(store)
            store.scheduleBookingTestSeedIdentityActivator()
            var observed = 0
            store.registerDerivedStateObserver { _ in observed += 1 }
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(store.cachedBusinessSnapshot != nil,
                   "10.09 fix1: sanity — the cache is populated before useAnotherAccount")
            expect(observed == 1, "10.09 fix1: sanity — the observer saw the pre-boundary publish")

            var googleCredentialClearCount = 0
            await store.useAnotherAccount { googleCredentialClearCount += 1 }
            expect(googleCredentialClearCount == 1 && store.authenticationGateState == .signedOut,
                   "10.09 fix1: sanity — useAnotherAccount reached its success path (Google credential cleared, signed out)")
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 fix1: a real useAnotherAccount() clears the cached snapshot at the account boundary")

            seed08Owner(store, subject: "user-1c", binding: "bind-1c")
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(observed == 2,
                   "10.09 fix1: the observer registered before useAnotherAccount still receives the next publish after sign-in")
        }

        // MARK: - Task 10.09 (B1) fix round 2: initial-sync publish ordering.
        //
        // Round 2 review: `beginInitialSyncGate`'s Task closure awaited
        // `derivedStatePublisher.publish(...)` BEFORE `markInitialSyncCompleted`/
        // `advancePastInitialSync`. `publish` genuinely suspends in production
        // (it awaits `notifySynchronize`), so a concurrent identity change
        // landing during that await (sign-out, `useAnotherAccount`, recovery
        // cancel, or another foreground `activateMigratedAuthenticatedIdentity`
        // bumping `initialSyncGateGeneration`) would let `publish` correctly
        // bail on its own owner/generation guard, but the STALE task would
        // then resume past the await and still run the gate-completion work
        // for a subject/generation that was no longer current. The fix moves
        // the publish to run AFTER gate completion, so there is no suspension
        // point between the closure's subject/generation guard and
        // `markInitialSyncCompleted`/`advancePastInitialSync` — nothing for a
        // concurrent identity change to race against there any more.
        //
        // This exact Task closure is NOT drivable end-to-end in this swiftc
        // host-test binary: `beginInitialSyncGate` itself is only reachable
        // through `applyAuthenticatedIdentityOutcome`, whose every real call
        // site (`activateMigratedAuthenticatedIdentity`, `signIn`, `signUp`,
        // `verifyEmail`, `completePasswordRecovery`, ...) is gated by a
        // `BuildEnvironment.supabaseURL`/`supabasePublishableKey` guard that
        // runs BEFORE any of them reach `applyAuthenticatedIdentityOutcome` —
        // confirmed by inspection of every call site in AppStore.swift, not
        // merely `beginInitialSyncGate`'s own (redundant, in this harness)
        // guard at its top. `BuildEnvironment` reads `Bundle.main`'s
        // Info.plist, which is empty in a plain `swiftc`-compiled binary, so
        // every one of those guards is always `nil` here — there is no
        // reachable production path in this harness that ever constructs the
        // Task whose reordering this round fixes, whether driven directly or
        // through any test seam (the seams that reach a signed-in state,
        // `scheduleBookingTestSeedSignedInOwner`/`scheduleBookingTestSeedIdentityActivator`,
        // both bypass `applyAuthenticatedIdentityOutcome` entirely — they set
        // identity fields directly, exactly so tests are NOT accidentally
        // routed through the network-sync gate).
        //
        // What this test pins instead: the exact entry point the finding
        // named as a race trigger — a foreground re-activation via
        // `activateMigratedAuthenticatedIdentity()` — really does stop at its
        // `BuildEnvironment` guard in this harness and never reaches
        // `applyAuthenticatedIdentityOutcome` (so it can never construct a
        // second, concurrent `beginInitialSyncGate` Task here either). That is
        // the guard the round-1 fix and this reordering both depend on to be
        // the *only* other synchronization boundary in play; this confirms it
        // still holds. What remains genuinely unproven by any automated test
        // in this repository: the reordering's actual runtime effect inside
        // `beginInitialSyncGate`'s Task body (i.e., that a real concurrent
        // identity change during the real `notifySynchronize` await no longer
        // corrupts `authenticationGateState`/`initialSyncCompletedSubject`)
        // remains verified by static reading of the diff (no `await` now sits
        // between the closure's subject/generation guard and
        // `markInitialSyncCompleted`/`advancePastInitialSync`) and by the
        // pre-existing generation-guard coverage of `publish` itself in
        // `native/run-background-refresh-tests.sh`, not by a dynamic test
        // exercising `beginInitialSyncGate` end to end. Device-level
        // verification of this path remains deferred to Phase 12 per the
        // roadmap, same as the rest of network sync.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "1009-initial-sync-guard-pin")
            var notifyCalls = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            await store.activateMigratedAuthenticatedIdentity()
            expect(store.authenticationGateState == .unavailable,
                   "10.09 fix2: activateMigratedAuthenticatedIdentity() stops at its BuildEnvironment guard in this harness (never reaches applyAuthenticatedIdentityOutcome / beginInitialSyncGate)")
            expect(notifyCalls == 0,
                   "10.09 fix2: since the gate was never reached, no publish's notifySynchronize ran either")
            expect(store.cachedBusinessSnapshot == nil,
                   "10.09 fix2: no cache write can have happened without the gate ever running")
        }

        // MARK: - 10.11 Today destination router, selected-day/week nav

        do {
            let dir1011 = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1011-router-\(UUID().uuidString)", isDirectory: true)
            let url1011 = dir1011.appendingPathComponent("store.json")
            let store = AppStore(fileURL: url1011, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())

            let job = Job(customerId: "c1011", customerName: "Nora", title: "Panel swap", laborRate: 95)
            var archivedJob = Job(customerId: "c1011", customerName: "Nora", title: "Old job", laborRate: 95)
            archivedJob.archivedAt = "2026-09-02T00:00:00.000Z"
            let invoice = Invoice(customerId: "c1011", customer: "Nora", number: "INV-1011", amount: 250)
            let customer = Customer(name: "Nora", email: "nora@example.com")
            var archivedCustomer = Customer(name: "Old Customer", email: "old@example.com")
            archivedCustomer.archivedAt = "2026-09-02T00:00:00.000Z"

            _ = store.upsert(job)
            _ = store.upsert(archivedJob)
            _ = store.upsert(customer)
            _ = store.upsert(archivedCustomer)
            store.upsert(invoice)

            // .job: exists and not archived -> handled, tab + one-shot deep link set.
            expect(store.routeToToday(.job(jobId: job.id)) == .handled,
                   "10.11 router: .job(existing) is handled")
            expect(store.selectedTab == .jobs && store.deepLinkedJobID == job.id,
                   "10.11 router: .job(existing) switches tab and sets the one-shot job id")

            // .job: missing id fails closed and does not disturb prior state.
            expect(store.routeToToday(.job(jobId: "does-not-exist")) == .none,
                   "10.11 router: .job(missing) fails closed")
            expect(store.deepLinkedJobID == job.id,
                   "10.11 router: a failed-closed route leaves the prior one-shot target untouched")

            // .job: an archived job ROUTES (final-review I1, RN parity —
            // Today still shows archived jobs, so the tap must not be dead).
            // Deliberately reverses the 10.11 "archived fails closed" pin.
            expect(store.routeToToday(.job(jobId: archivedJob.id)) == .handled
                       && store.deepLinkedJobID == archivedJob.id && store.selectedTab == .jobs,
                   "I1 router: .job(archived) routes to the job like RN's JobDetail navigation")

            // .invoice: one-shot semantics clear the PRIOR job target.
            expect(store.routeToToday(.invoice(invoiceId: invoice.id)) == .handled,
                   "10.11 router: .invoice(existing) is handled")
            expect(store.selectedTab == .invoices && store.deepLinkedInvoiceID == invoice.id,
                   "10.11 router: .invoice(existing) switches tab and sets the one-shot invoice id")
            expect(store.deepLinkedJobID == nil,
                   "10.11 router: routing to a new one-shot target clears the prior one (routeToGlobalSearchResult parity)")

            expect(store.routeToToday(.invoice(invoiceId: "missing")) == .none,
                   "10.11 router: .invoice(missing) fails closed")

            // .customer: archived fails closed; existing succeeds.
            expect(store.routeToToday(.customer(customerId: archivedCustomer.id)) == .none,
                   "10.11 router: .customer(archived) fails closed")
            expect(store.routeToToday(.customer(customerId: customer.id)) == .handled,
                   "10.11 router: .customer(existing) is handled")
            expect(store.selectedTab == .customers && store.deepLinkedCustomerID == customer.id,
                   "10.11 router: .customer(existing) switches tab and sets the one-shot customer id")

            // Tab-only destinations always succeed (no id to verify).
            expect(store.routeToToday(.jobs) == .handled && store.selectedTab == .jobs,
                   "10.11 router: .jobs always switches tab")
            expect(store.routeToToday(.invoices) == .handled && store.selectedTab == .invoices,
                   "10.11 router: .invoices always switches tab")
            expect(store.routeToToday(.customers) == .handled && store.selectedTab == .customers,
                   "10.11 router: .customers always switches tab")
            expect(store.routeToToday(.money) == .handled && store.selectedTab == .money,
                   "10.11 router: .money always switches tab")

            // .selectDate: valid date updates todaySelectedDate; malformed is a no-op.
            expect(store.routeToToday(.selectDate(date: "2026-09-01")) == .handled,
                   "10.11 router: .selectDate(valid) is handled")
            expect(store.todaySelectedDate == "2026-09-01",
                   "10.11 router: .selectDate(valid) updates todaySelectedDate")
            expect(store.routeToToday(.selectDate(date: "not-a-date")) == .none,
                   "10.11 router: .selectDate(malformed) fails closed")
            expect(store.todaySelectedDate == "2026-09-01",
                   "10.11 router: a failed .selectDate leaves todaySelectedDate untouched")

            // View-presentation destinations: no store-state mutation, just the
            // typed instruction the view acts on. Existence is still checked
            // for the two that carry a job id.
            expect(store.routeToToday(.createInvoice(jobId: job.id)) == .presentInvoiceFromJob(jobID: job.id),
                   "10.11 router: .createInvoice(existing) presents the invoice-from-job sheet")
            expect(store.routeToToday(.createInvoice(jobId: "missing")) == .none,
                   "10.11 router: .createInvoice(missing) fails closed")
            expect(store.routeToToday(.createInvoice(jobId: archivedJob.id)) == .presentInvoiceFromJob(jobID: archivedJob.id),
                   "I1 router: .createInvoice(archived) presents the invoice-from-job sheet (RN parity; reverses the 10.11 pin)")
            expect(store.routeToToday(.schedule(jobId: job.id)) == .presentJobEditor(jobID: job.id),
                   "10.11 router: .schedule(existing) presents the job editor")
            expect(store.routeToToday(.schedule(jobId: "missing")) == .none,
                   "10.11 router: .schedule(missing) fails closed")
            expect(store.routeToToday(.schedule(jobId: archivedJob.id)) == .presentJobEditor(jobID: archivedJob.id),
                   "I1 router: .schedule(archived) presents the job editor (RN parity; reverses the 10.11 pin)")
            expect(store.routeToToday(.newJob) == .presentNewJobEditor,
                   "10.11 router: .newJob presents a blank job editor")
            expect(store.routeToToday(.newCustomer) == .presentNewCustomerEditor,
                   "10.11 router: .newCustomer presents a blank customer editor")
            expect(store.routeToToday(.calendar) == .presentCalendar, "10.11 router: .calendar presents the calendar")
            expect(store.routeToToday(.search) == .presentSearch, "10.11 router: .search presents global search")
            expect(store.routeToToday(.settings) == .presentSettings, "10.11 router: .settings presents settings")
            expect(store.routeToToday(.route) == .presentRoute, "10.11 router: .route presents the route planner")

            // .onMyWay: reuses the existing notification-tap review flow
            // (`requestOnMyWayReview`) rather than a silent inline send.
            expect(store.routeToToday(.onMyWay(jobId: job.id)) == .handled,
                   "10.11 router: .onMyWay(existing) is handled")
            expect(store.pendingOnMyWayJobID == job.id,
                   "10.11 router: .onMyWay(existing) stages the same on-my-way review sheet the notification-tap path uses")
            expect(store.routeToToday(.onMyWay(jobId: "missing")) == .none,
                   "10.11 router: .onMyWay(missing) fails closed")
            let pendingBeforeMissingOnMyWay = store.pendingOnMyWayJobID
            expect(store.routeToToday(.onMyWay(jobId: "missing-2")) == .none,
                   "10.11 router: .onMyWay(missing) fails closed")
            expect(store.pendingOnMyWayJobID == pendingBeforeMissingOnMyWay,
                   "10.11 router: a failed-closed .onMyWay leaves pendingOnMyWayJobID untouched")
            expect(store.routeToToday(.onMyWay(jobId: archivedJob.id)) == .handled
                       && store.pendingOnMyWayJobID == archivedJob.id,
                   "I1 router: .onMyWay(archived) stages the review sheet (RN parity; reverses the 10.11 pin)")

            // Selected-day/week navigation (RN's setSelectedDate/prevWeek/nextWeek).
            store.selectTodayDate("2026-09-10")
            expect(store.todaySelectedDate == "2026-09-10", "10.11 nav: selectTodayDate adopts a valid date")
            store.selectTodayDate("garbage")
            expect(store.todaySelectedDate == "2026-09-10", "10.11 nav: selectTodayDate refuses a malformed date")
            store.shiftTodaySelectedWeek(by: 7)
            expect(store.todaySelectedDate == "2026-09-17", "10.11 nav: shiftTodaySelectedWeek(+7) advances one week")
            store.shiftTodaySelectedWeek(by: -7)
            expect(store.todaySelectedDate == "2026-09-10", "10.11 nav: shiftTodaySelectedWeek(-7) returns to the prior week")
        }

        // Pull-to-refresh `.alreadyRunning` handling: `TodayView.body` calls
        // `await store.performPullToRefresh()` directly in `.refreshable` with
        // no local success shortcut — `performPullToRefresh` forwards to the
        // pre-existing `syncNowAndWait`, whose `.alreadyRunning` branch awaits
        // `coordinator.waitUntilIdle()` rather than returning early (see
        // `AppStore.swift`'s `syncNowAndWait`). This harness's
        // `syncCoordinatorIfConfigured()` always returns `nil` (no network/
        // auth configuration here — the same boundary the 10.09 tests above
        // hit), so the real coordinator's `.alreadyRunning` transition cannot
        // be driven end-to-end from this process; it is exercised by the
        // analogous already-running guard on `runBookingIntakeAfterVerifiedPull`
        // above (`10.09`/`8.x` tests, `gatePull`/`.alreadyRunning`) and is
        // unchanged by this task. What IS pinned here is that
        // `performPullToRefresh` does not fabricate a success when no
        // coordinator is configured — it returns `nil`, so `TodayView` never
        // reports a refresh as complete when nothing actually synced.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "1011-pull-to-refresh")
            let outcome = await store.performPullToRefresh()
            expect(outcome == nil,
                   "10.11 pull-to-refresh: with no coordinator configured, performPullToRefresh reports no outcome rather than a fabricated success")
        }

        // MARK: - Task 10.12: setup checklist, hero state, insights card.

        func customer1012(id: String, name: String = "Real Customer") -> Canonical.Customer {
            try! JSONDecoder().decode(Canonical.Customer.self, from: Data("""
            {"id":"\(id)","name":"\(name)","email":"","phone":"","address":"","notes":""}
            """.utf8))
        }
        func insight1012(_ kind: NativeInsightKind, id: String) -> NativeTodayInsight {
            NativeTodayInsight(kind: kind, id: id, title: "t-\(id)", target: .jobs, reason: "r-\(id)")
        }
        // `NativeInsightMuteStore`/`NativeSetupChecklistStore` fail-closed on
        // any account binding that is not exactly 64 lowercase hex chars —
        // deterministically expand a short readable tag into one so these
        // tests both read cleanly and satisfy that validation.
        func hexBinding(_ tag: String) -> String {
            let safe = tag.lowercased().compactMap { ch -> Character in
                ("0"..."9").contains(ch) || ("a"..."f").contains(ch) ? ch : "0"
            }
            var s = String(safe)
            while s.count < 64 { s += "0" }
            return String(s.prefix(64))
        }

        // --- S5 (pure policy): top-three-after-mute, per-kind mute
        // availability, and fail-closed mute rendering. Exercised directly
        // against `NativeInsightsCardPolicy` — no store I/O needed for the
        // pure slicing/filtering contract.
        do {
            let now = Date()
            let five = [
                insight1012(.laborOverrun, id: "labor_overrun:j1"),
                insight1012(.lowMarginEstimate, id: "low_margin_estimate:j2"),
                insight1012(.uninvoicedComplete, id: "uninvoiced_complete:j3"),
                insight1012(.dueSoon, id: "due_soon:i1"),
                insight1012(.openSlot, id: "open_slot:2026-09-23"),
            ]
            expect(NativeInsightsCardPolicy.visibleInsights(all: five, mutes: [], now: now).map(\.id) == five.prefix(3).map(\.id),
                   "10.12 with no mutes, the top-3 slice is the first 3 insights in priority order")

            let muteFirst = [NativeInsightMutes.makeMute(id: five[0].id, now: now)]
            let afterMute = NativeInsightsCardPolicy.visibleInsights(all: five, mutes: muteFirst, now: now)
            expect(afterMute.map(\.id) == [five[1].id, five[2].id, five[3].id],
                   "10.12 top-three-after-mute: muting the first row promotes the 4th into the visible 3 (mute filter runs before the slice)")

            for kind: NativeInsightKind in [.lowMarginEstimate, .maintenanceDue, .expenseAnomaly] {
                expect(NativeInsightsCardPolicy.isMuteable(kind), "10.12 \(kind.rawValue) is muteable (MUTEABLE_KINDS)")
            }
            for kind: NativeInsightKind in [.laborOverrun, .uninvoicedComplete, .dueSoon, .openSlot, .unscheduledApproved] {
                expect(!NativeInsightsCardPolicy.isMuteable(kind), "10.12 \(kind.rawValue) is NOT muteable (self-resolving)")
            }
            expect(NativeInsightsCardPolicy.snoozeDays(for: .maintenanceDue) == 30,
                   "10.12 maintenance_due offers a 30-day snooze")
            expect(NativeInsightsCardPolicy.snoozeDays(for: .lowMarginEstimate) == nil,
                   "10.12 low_margin_estimate is dismiss-only, no snooze option")
            expect(NativeInsightsCardPolicy.snoozeDays(for: .expenseAnomaly) == nil,
                   "10.12 expense_anomaly is dismiss-only, no snooze option")

            // Fail-closed (brief step 5, decision row 17): mutes == nil (the
            // store was unreadable) renders ONLY the five non-muteable kinds,
            // never an unfiltered muteable row that might resurrect a
            // dismissal.
            let mixedWithMuteable = five + [insight1012(.maintenanceDue, id: "maintenance_due:eq1")]
            let failClosed = NativeInsightsCardPolicy.visibleInsights(all: mixedWithMuteable, mutes: nil, now: now)
            expect(failClosed.allSatisfy { !NativeInsightsCardPolicy.isMuteable($0.kind) },
                   "10.12 fail-closed: an unreadable mute store renders only non-muteable kinds")
            expect(failClosed.count == 3, "10.12 fail-closed rendering still respects the top-3 limit")
            expect(!NativeInsightsCardPolicy.mutesReadable(nil), "10.12 mutesReadable(nil) is false — controls hidden")
            expect(NativeInsightsCardPolicy.mutesReadable([]), "10.12 mutesReadable([]) is true — an empty but loaded store still shows controls")

            // Gate ordering (decision row 18 + row 6): hero suppresses
            // insights regardless of setup completion; setup incompleteness
            // suppresses insights regardless of hero; an empty result
            // (post-mute) suppresses the card even when both gates pass.
            let hero = NativeTodayHero(kind: .createJob, title: "t", subtitle: "s", destination: .newJob)
            expect(!NativeInsightsCardPolicy.isVisible(setupComplete: true, hero: hero, insights: five),
                   "10.12 gate ordering: a shown hero suppresses the insights card even when setup is complete")
            expect(!NativeInsightsCardPolicy.isVisible(setupComplete: false, hero: nil, insights: five),
                   "10.12 gate ordering: incomplete setup suppresses the insights card even with no hero")
            expect(!NativeInsightsCardPolicy.isVisible(setupComplete: true, hero: nil, insights: []),
                   "10.12 gate ordering: zero visible insights suppresses the card even when otherwise eligible")
            expect(NativeInsightsCardPolicy.isVisible(setupComplete: true, hero: nil, insights: five),
                   "10.12 gate ordering: setup complete + no hero + insights present shows the card")
        }

        // --- Every checklist destination (pure `NativeSetupChecklist.route`).
        do {
            expect(NativeSetupChecklist.route(for: .contact) == .business, "10.12 contact task routes to Business settings")
            expect(NativeSetupChecklist.route(for: .logo) == .business, "10.12 logo task routes to Business settings")
            expect(NativeSetupChecklist.route(for: .rate) == .pricing, "10.12 rate task routes to Pricing settings")
            expect(NativeSetupChecklist.route(for: .stripe) == .payments, "10.12 stripe task routes to Payments settings")
            expect(NativeSetupChecklist.route(for: .notifications) == .settings,
                   "10.12 notifications task's route is total (handled in-card before this map is consulted in practice)")
        }

        // --- AppStore wiring: fail-closed default, checklist derivation,
        // dismiss/mark-done persistence, hero gate wiring (R3), prefill
        // install (R4), settings routing, and the analytics seam (R5)
        // including `insight_shown` de-dup.
        do {
            let recorder = RecordingAnalytics()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1012-wiring-\(UUID().uuidString)", isDirectory: true)
            let wiringURL = dir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: wiringURL).save(Canonical.Snapshot(payload: Canonical.SnapshotPayload(
                jobs: [job08(id: "j1", status: "approved", date: "2026-09-22")], settings: settings08())))
            let store = AppStore(fileURL: wiringURL, seedIfMissing: false,
                                 subscriptionService: StoreSubscriptionServiceStub(), analytics: recorder,
                                 secureSettingsStore: hostTestSecureSettingsStore())
            // Seed a verified owner without going through activation — this
            // proves the FAIL-CLOSED default:
            // an owner is signed in but `activateInsightMutes`/
            // `activateSetupChecklist` have not run yet (matches a real
            // in-flight launch before identity activation completes).
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-1012", binding: hexBinding("bind-1012"))

            expect(store.todaySetupTasks == nil,
                   "10.12 fail-closed: before checklist activation, the checklist is hidden (nil), not an empty/complete list")
            expect(!store.todaySetupComplete,
                   "10.12 fail-closed: before checklist activation, setup reads as incomplete (never wrongly reveals insights)")

            // Reload the real activation path (the test seam calls the exact
            // production `activateInsightMutes`/`activateSetupChecklist`).
            store.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-1012"))
            expect(store.todaySetupTasks?.count == 5, "10.12 activation yields all 5 checklist tasks")
            let contactTask = store.todaySetupTasks?.first { $0.id == .contact }
            expect(contactTask?.done == true, "10.12 contact/address are non-empty in settings08() — contact task derives done")
            let logoTask = store.todaySetupTasks?.first { $0.id == .logo }
            expect(logoTask?.done == false, "10.12 no logoPhoto in settings08() — logo task derives not-done")
            expect(!store.todaySetupComplete, "10.12 setup is not complete while logo/rate/stripe/notifications are outstanding")

            // markSetupTaskDone persists through the real owner-bound store —
            // prove it with a genuine relaunch reading the file back, not
            // just the in-memory flag.
            store.markSetupTaskDone(.rate)
            expect(store.todaySetupTasks?.first { $0.id == .rate }?.done == true,
                   "10.12 markSetupTaskDone(.rate) flips the in-memory rate task done")
            let relaunched = AppStore(fileURL: dir.appendingPathComponent("store.json"), seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(),
                                      secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-1012", binding: hexBinding("bind-1012"))
            relaunched.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-1012"))
            expect(relaunched.todaySetupTasks?.first { $0.id == .rate }?.done == true,
                   "10.12 a real relaunch reads the persisted rate completion back from disk")

            // dismissSetupChecklist: optimistic in-memory flip + analytics +
            // persistence.
            expect(recorder.calls.isEmpty, "10.12 sanity: no analytics fired yet")
            let doneCountBeforeDismiss = store.todaySetupTasks?.filter(\.done).count
            store.dismissSetupChecklist()
            expect(store.todaySetupComplete, "10.12 dismissSetupChecklist optimistically marks setup complete (dismissed short-circuits the gate)")
            expect(recorder.calls.contains {
                $0.event == "setup_checklist_dismissed" && $0.properties["doneCount"] == String(doneCountBeforeDismiss ?? 0)
            }, "10.12 dismissSetupChecklist fires setup_checklist_dismissed with the exact pre-dismiss doneCount property")

            // Hero gate wiring (R3): `todayHero` reads `sampleTourDone` from
            // the real activated checklist state, not a hardcoded placeholder.
            let sampleRecorder = RecordingAnalytics()
            let sampleDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1012-hero-\(UUID().uuidString)", isDirectory: true)
            let sampleURL = sampleDir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: sampleURL).save(Canonical.Snapshot(payload: Canonical.SnapshotPayload(
                jobs: [job08(id: "j1", status: "lead", date: nil, start: nil, end: nil)], settings: settings08())))
            let sampleStore = AppStore(fileURL: sampleURL, seedIfMissing: false,
                                       subscriptionService: StoreSubscriptionServiceStub(), analytics: sampleRecorder,
                                       secureSettingsStore: hostTestSecureSettingsStore())
            sampleStore.scheduleBookingTestSeedSignedInOwner(subject: "user-hero", binding: hexBinding("bind-hero"))
            sampleStore.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-hero"))
            expect(sampleStore.todayHero?.kind == .sampleTour,
                   "10.12 a fresh account with only a sample job and no real customers shows the sample-tour hero")
            sampleStore.markSampleTourDoneIfNeeded(for: sampleStore.todayHero!)
            expect(sampleStore.todayHero == nil,
                   "10.12 markSampleTourDoneIfNeeded persists sampleTourDone, and todayHero reflects it immediately (no hero re-shown)")
            expect(sampleRecorder.calls.contains { $0.event == "sample_job_opened" },
                   "10.12 the sample-tour hero tap fires sample_job_opened")
            let relaunchedSample = AppStore(fileURL: sampleDir.appendingPathComponent("store.json"), seedIfMissing: false,
                                            subscriptionService: StoreSubscriptionServiceStub(),
                                            secureSettingsStore: hostTestSecureSettingsStore())
            relaunchedSample.scheduleBookingTestSeedSignedInOwner(subject: "user-hero", binding: hexBinding("bind-hero"))
            relaunchedSample.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-hero"))
            expect(relaunchedSample.todayHero == nil,
                   "10.12 sampleTourDone persists across a real relaunch")

            // A non-sample-tour hero tap is a no-op for the checklist store
            // (only the sample tour records `sampleTourDone`/fires
            // `sample_job_opened`).
            let (customerStore, _) = try seed08Store(customers: [customer1012(id: "real-cust-1")],
                                                      settings: settings08(), tag: "1012-hero-addcustomer")
            customerStore.scheduleBookingTestSeedSignedInOwner(subject: "user-hero2", binding: hexBinding("bind-hero2"))
            customerStore.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-hero2"))
            expect(customerStore.todayHero?.kind == .createJob,
                   "10.12 sanity: a real customer with no jobs shows the createJob hero, not addCustomer")
            let statusBefore = customerStore.todaySetupTasks?.first { $0.id == .rate }?.done
            customerStore.markSampleTourDoneIfNeeded(for: customerStore.todayHero!)
            expect(customerStore.todaySetupTasks?.first { $0.id == .rate }?.done == statusBefore,
                   "10.12 markSampleTourDoneIfNeeded is a no-op for a non-sampleTour hero kind — no spurious checklist write")
            let heroRouteResult = customerStore.handleTodayHeroTap(customerStore.todayHero!)
            expect(heroRouteResult == .presentNewJobEditor,
                   "10.12 handleTodayHeroTap routes the createJob hero's .newJob destination to presentNewJobEditor")

            // Prefill handoff (R4): one-shot value + tab switch, for 10.13 to
            // consume. This task installs and switches tabs; it does not
            // consume/clear the value (10.13 owns that).
            expect(store.pendingCoachPrefill == nil, "10.12 sanity: no prefill installed yet")
            expect(store.selectedTab == .today, "10.12 sanity: starts on the Today tab")
            store.installPendingCoachPrefill("Why is this job low margin?")
            expect(store.pendingCoachPrefill == "Why is this job low margin?",
                   "10.12 installPendingCoachPrefill sets the one-shot prefill value")
            expect(store.selectedTab == .coach, "10.12 installPendingCoachPrefill switches to the Coach tab")

            // Settings routing (checklist task tap).
            expect(store.pendingSettingsDestination == nil, "10.12 sanity: no pending settings destination yet")
            store.routeToTodaySettings(.pricing)
            expect(store.pendingSettingsDestination == .pricing, "10.12 routeToTodaySettings installs the one-shot settings route")
            store.trackSetupChecklistTaskOpened(.rate)
            expect(recorder.calls.contains { $0.event == "setup_checklist_task_opened" && $0.properties["task"] == "rate" },
                   "10.12 trackSetupChecklistTaskOpened fires setup_checklist_task_opened with the task id")

            // Insight tap routing reuses the exact 10.04 destination mapping,
            // including the sheet-presentation cases (`.schedule` →
            // `.presentJobEditor`) that only `TodayView`'s `onRoute` handler
            // can present — not just the tab-switch `.handled` cases.
            let jobTargetInsight = NativeTodayInsight(kind: .laborOverrun, id: "labor_overrun:j1",
                                                      title: "t", target: .schedule(jobId: "j1"), reason: "r")
            let routeResult = store.handleTodayInsightTap(jobTargetInsight)
            expect(routeResult == .presentJobEditor(jobID: "j1"),
                   "10.12 handleTodayInsightTap routes a .schedule target through the exact 10.04 destination mapping to a sheet-presentation result")

            // Dismiss vs snooze + per-kind mute availability, end to end
            // through the real owner-bound mute store.
            let dismissTarget = insight1012(.lowMarginEstimate, id: "low_margin_estimate:j9")
            store.applyInsightMute(dismissTarget, days: nil)
            expect(store.insightMutes?.contains(where: { $0.id == dismissTarget.id && $0.until == nil }) == true,
                   "10.12 applyInsightMute(days: nil) optimistically records a permanent dismiss (no `until`) immediately, in-memory")
            expect(recorder.calls.contains { $0.event == "insight_dismissed" && $0.properties["insightId"] == dismissTarget.id },
                   "10.12 a permanent dismiss fires insight_dismissed with the exact insightId")

            let snoozeTarget = insight1012(.maintenanceDue, id: "maintenance_due:eq2")
            store.applyInsightMute(snoozeTarget, days: 30)
            expect(store.insightMutes?.contains(where: { $0.id == snoozeTarget.id && $0.until != nil }) == true,
                   "10.12 applyInsightMute(days: 30) optimistically records a snooze WITH an `until` date, distinct from a dismiss")
            expect(recorder.calls.contains { $0.event == "insight_snoozed" && $0.properties["days"] == "30" },
                   "10.12 a snooze fires insight_snoozed with the exact days property")

            // Analytics dedup: `insight_shown` fires once per distinct visible
            // id SET, not once per render.
            let shownSet = [insight1012(.dueSoon, id: "due_soon:i9")]
            let shownCallsBefore = recorder.calls.filter { $0.event == "insight_shown" }.count
            store.trackTodayInsightsShownIfNeeded(shownSet)
            store.trackTodayInsightsShownIfNeeded(shownSet)
            let shownCallsAfterRepeat = recorder.calls.filter { $0.event == "insight_shown" }.count
            expect(shownCallsAfterRepeat == shownCallsBefore + 1,
                   "10.12 insight_shown de-dup: calling with the SAME visible id set twice fires analytics only once")
            store.trackTodayInsightsShownIfNeeded([insight1012(.dueSoon, id: "due_soon:i10")])
            let shownCallsAfterChange = recorder.calls.filter { $0.event == "insight_shown" }.count
            expect(shownCallsAfterChange == shownCallsAfterRepeat + 1,
                   "10.12 insight_shown fires again once the visible id set actually changes")

            store.trackInsightTapped(jobTargetInsight)
            expect(recorder.calls.contains { $0.event == "insight_tapped" && $0.properties["kind"] == "labor_overrun" },
                   "10.12 trackInsightTapped fires insight_tapped with the kind property")
            store.trackInsightCoachOpened(jobTargetInsight)
            expect(recorder.calls.contains { $0.event == "insight_coach_opened" },
                   "10.12 trackInsightCoachOpened fires insight_coach_opened")
            store.trackInsightReasonViewed(jobTargetInsight)
            expect(recorder.calls.contains { $0.event == "insight_reason_viewed" },
                   "10.12 trackInsightReasonViewed fires insight_reason_viewed")
        }

        // --- Account-boundary scrub: all three real boundaries wipe the
        // owner-bound insight-mute and setup-checklist stores, and reset the
        // in-memory published state + one-shot values, matching the pattern
        // already established for review requests/reminder prompts.
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-scrub-signout")
            let scrubBinding = hexBinding("bind-scrub-1")
            seed08Owner(store, binding: scrubBinding)
            store.testActivateInsightAndChecklistStores(accountBinding: scrubBinding)
            store.markSetupTaskDone(.rate)
            store.installPendingCoachPrefill("keep me?")
            store.routeToTodaySettings(.pricing)
            expect(store.setupChecklistState != nil, "10.12 scrub sanity: checklist state is populated before the boundary")
            expect(store.pendingCoachPrefill != nil, "10.12 scrub sanity: a pending prefill is installed before the boundary")

            // `derivedStatePublisher.reset()` alone (the established
            // lightweight stand-in for the real, App-Group-touching
            // `signOut()`/`applyCompletedSignOutState()` used throughout the
            // 10.09 tests above) does not itself clear these NEW 10.12
            // stores — that clearing lives in the real
            // `applyCompletedSignOutState`/`useAnotherAccount`/
            // `applyRecoverySignedOutState` bodies. Drive a REAL
            // `useAnotherAccount()` (already proven callable in this host
            // binary above) to exercise one of those three real code paths
            // end-to-end.
            store.scheduleBookingTestSeedIdentityActivator()
            await store.useAnotherAccount { }
            expect(store.setupChecklistState == nil,
                   "10.12 a real useAnotherAccount() scrubs setupChecklistState at the account boundary")
            expect(store.insightMutes == nil,
                   "10.12 a real useAnotherAccount() scrubs insightMutes at the account boundary")
            expect(store.pendingCoachPrefill == nil,
                   "10.12 a real useAnotherAccount() clears the one-shot pending coach prefill")
            expect(store.pendingSettingsDestination == nil,
                   "10.12 a real useAnotherAccount() clears the one-shot pending settings destination")

            // The on-disk stores are wiped too, not just the in-memory
            // published values — prove it with a fresh relaunch + reload for
            // the SAME (now-departed) binding: activation must come back
            // empty/fresh, not resurrect the pre-scrub data.
            let relaunched = AppStore(fileURL: dir.appendingPathComponent("store.json"), seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(),
                                      secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-1", binding: scrubBinding)
            relaunched.testActivateInsightAndChecklistStores(accountBinding: scrubBinding)
            // Fix round 1 (I7c): assert non-nil first — the store came back
            // readable (a fresh, empty state), not that the check was simply
            // vacuous against a still-nil/unreadable store.
            let relaunchedRateTask = relaunched.todaySetupTasks?.first { $0.id == .rate }
            expect(relaunchedRateTask != nil,
                   "10.12 the relaunched, re-activated store reads back a real (non-nil) rate task")
            expect(relaunchedRateTask?.done == false,
                   "10.12 the on-disk setup-checklist store was actually removed by the scrub, not just the in-memory copy")
        }
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-scrub-recovery")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-r1012", binding: hexBinding("bind-r1012"))
            store.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-r1012"))
            store.markSetupTaskDone(.stripe)
            expect(store.setupChecklistState?.isDone(.stripe) == true, "10.12 scrub sanity: stripe recorded before recovery cancel")

            await store.cancelPasswordRecovery()
            expect(store.setupChecklistState == nil,
                   "10.12 a real applyRecoverySignedOutState() (via cancelPasswordRecovery) scrubs setupChecklistState")
            expect(store.insightMutes == nil,
                   "10.12 a real applyRecoverySignedOutState() (via cancelPasswordRecovery) scrubs insightMutes")

            let relaunched = AppStore(fileURL: dir.appendingPathComponent("store.json"), seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(),
                                      secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-r1012", binding: hexBinding("bind-r1012"))
            relaunched.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-r1012"))
            // Fix round 1 (I7c): assert non-nil first, then the value — a
            // still-nil/unreadable state would make `!= true` vacuously pass.
            expect(relaunched.setupChecklistState != nil,
                   "10.12 the relaunched, re-activated store reads back a real (non-nil) checklist state")
            expect(relaunched.setupChecklistState?.isDone(.stripe) == false,
                   "10.12 the on-disk setup-checklist store was actually removed by the recovery-boundary scrub")
        }

        // MARK: - Task 10.12 fix round 1

        // --- I1: contract §1.5 `checklistState == nil -> no hero`, and every
        // checklist mutator is a no-op while the store is nil/unreadable —
        // not just `todayHero`. Uses a signed-in-but-not-yet-activated store
        // (the same fail-closed default already proven above for
        // `todaySetupTasks`/`todaySetupComplete`).
        do {
            let (store, _) = try seed08Store(jobs: [job08(id: "j1", status: "lead", date: nil, start: nil, end: nil)],
                                              settings: settings08(), tag: "1012-fix1-i1")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-i1", binding: hexBinding("bind-i1"))
            expect(store.setupChecklistState == nil, "10.12 fix1 I1 sanity: checklist store is nil before activation")

            expect(store.todayHero == nil,
                   "10.12 fix1 I1: checklistState == nil -> no hero (contract §1.5), even though the job data alone would otherwise show the sample-tour hero")

            let syntheticHero = NativeTodayHero(kind: .sampleTour, title: "t", subtitle: "s", destination: .job(jobId: "j1"))
            store.markSampleTourDoneIfNeeded(for: syntheticHero)
            expect(store.setupChecklistState == nil,
                   "10.12 fix1 I1: markSampleTourDoneIfNeeded is a no-op while setupChecklistState is nil")

            store.markSetupTaskDone(.rate)
            expect(store.setupChecklistState == nil,
                   "10.12 fix1 I1: markSetupTaskDone is a no-op while setupChecklistState is nil")

            store.dismissSetupChecklist()
            expect(store.setupChecklistState == nil,
                   "10.12 fix1 I1: dismissSetupChecklist is a no-op while setupChecklistState is nil")

            expect(!store.todayInsightsVisible,
                   "10.12 fix1 I1: the insights card stays hidden while the checklist store is nil (setup reads as incomplete, which gates the card regardless of hero)")
        }

        // --- I2: `applyInsightMute` is fail-closed AT THE STORE LAYER, and
        // the owner-binding guard runs BEFORE the optimistic in-memory
        // mutation.
        do {
            // (a) insightMutes == nil (unreadable/pre-activation): a no-op,
            // not a `?? []` fabrication.
            let (nilMutesStore, _) = try seed08Store(settings: settings08(), tag: "1012-fix1-i2-nil")
            nilMutesStore.scheduleBookingTestSeedSignedInOwner(subject: "user-i2a", binding: hexBinding("bind-i2a"))
            expect(nilMutesStore.insightMutes == nil, "10.12 fix1 I2 sanity: insightMutes is nil before activation")
            nilMutesStore.applyInsightMute(insight1012(.lowMarginEstimate, id: "low_margin_estimate:i2a"), days: nil)
            expect(nilMutesStore.insightMutes == nil,
                   "10.12 fix1 I2: applyInsightMute is a no-op when insightMutes is nil — it never fabricates `[]` and writes into it")

            // (b) the binding guard runs BEFORE the optimistic mutation: a
            // readable (non-nil) mute list with NO verified binding must not
            // be mutated in memory at all.
            let recorder = RecordingAnalytics()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1012-fix1-i2b-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: url).save(Canonical.Snapshot(payload: Canonical.SnapshotPayload(settings: settings08())))
            let boundStore = AppStore(fileURL: url, seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(), analytics: recorder,
                                      secureSettingsStore: hostTestSecureSettingsStore())
            boundStore.scheduleBookingTestSeedSignedInOwner(subject: "user-i2b", binding: hexBinding("bind-i2b"))
            boundStore.testActivateInsightAndChecklistStores(accountBinding: hexBinding("bind-i2b"))
            expect(boundStore.insightMutes != nil, "10.12 fix1 I2 sanity: insightMutes is readable (non-nil, empty) after activation")
            boundStore.scheduleBookingTestClearOwner()
            let mutesBeforeUnboundAttempt = boundStore.insightMutes
            boundStore.applyInsightMute(insight1012(.maintenanceDue, id: "maintenance_due:i2b"), days: 30)
            expect(boundStore.insightMutes == mutesBeforeUnboundAttempt,
                   "10.12 fix1 I2: with insightMutes readable but no verified account binding, applyInsightMute makes NO optimistic in-memory mutation — the binding guard runs first")
            expect(!recorder.calls.contains(where: { $0.event == "insight_snoozed" }),
                   "10.12 fix1 I2: no analytics fires for an applyInsightMute call the guard rejected")
        }

        // --- I4: the stripe-task write is a pure, directly testable
        // predicate (`AppStore.stripeTaskWriteAllowed`) requiring BOTH a
        // connected status AND an unchanged account binding across the
        // await. `configuredStripeConnectService()` performs real network
        // I/O with no injectable seam, so the full async race through
        // `refreshStripeStatus()` is not driven end-to-end here — this is
        // exactly the predicate that guard makes its decision from, and it
        // is what determines whether the account-switch-mid-await race is
        // closed.
        do {
            expect(AppStore.stripeTaskWriteAllowed(connected: true, bindingBeforeAwait: "b1", currentBinding: "b1"),
                   "10.12 fix1 I4: connected + unchanged binding -> write allowed")
            expect(!AppStore.stripeTaskWriteAllowed(connected: true, bindingBeforeAwait: "b1", currentBinding: "b2"),
                   "10.12 fix1 I4: connected but the binding changed during the await (account switch) -> write REJECTED")
            expect(!AppStore.stripeTaskWriteAllowed(connected: false, bindingBeforeAwait: "b1", currentBinding: "b1"),
                   "10.12 fix1 I4: unchanged binding but not connected -> write rejected")
            expect(!AppStore.stripeTaskWriteAllowed(connected: true, bindingBeforeAwait: nil, currentBinding: nil),
                   "10.12 fix1 I4: never had a verified binding before the await -> write rejected, not vacuously allowed by nil == nil")
        }

        // --- I5: seed adoption is REALLY exercised (the pre-fix-round-1
        // report's claim that this was covered was wrong — every existing
        // `testActivateInsightAndChecklistStores` call passed `migrated:
        // nil`, which only exercises the "no seed" branch of `mergeSeeded`).
        // Drives the real migration-seed adoption path with actual seed
        // content for both stores and asserts the live stores adopted it.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "1012-fix1-i5")
            let binding = hexBinding("bind-i5-seed")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-i5", binding: binding)
            store.testActivateInsightAndChecklistStores(
                accountBinding: binding,
                migratedInsightMutes: [
                    NativeTypedAccountState.InsightMute(id: "low_margin_estimate:seed-dismiss", mutedAt: nil, until: nil),
                    NativeTypedAccountState.InsightMute(id: "maintenance_due:seed-snooze", mutedAt: nil, until: "2099-01-01"),
                ],
                migratedSetupChecklistState: NativeTypedAccountState.SetupChecklistState(
                    dismissed: true,
                    done: NativeTypedAccountState.SetupChecklistState.Done(
                        contact: true, logo: true, rate: nil, stripe: nil, notifications: nil
                    ),
                    sampleTourDone: true
                )
            )
            expect(store.insightMutes?.contains(where: { $0.id == "low_margin_estimate:seed-dismiss" && $0.until == nil }) == true,
                   "10.12 fix1 I5: the seeded permanent dismiss was adopted into the live insight-mute store")
            expect(store.insightMutes?.contains(where: { $0.id == "maintenance_due:seed-snooze" && $0.until == "2099-01-01" }) == true,
                   "10.12 fix1 I5: the seeded snooze (with its `until`) was adopted into the live insight-mute store")
            expect(store.setupChecklistState?.isDone(.contact) == true,
                   "10.12 fix1 I5: the seeded `done.contact` was adopted into the live setup-checklist store")
            expect(store.setupChecklistState?.isDone(.logo) == true,
                   "10.12 fix1 I5: the seeded `done.logo` was adopted into the live setup-checklist store")
            expect(store.setupChecklistState?.sampleTourDone == true,
                   "10.12 fix1 I5: the seeded `sampleTourDone` was adopted into the live setup-checklist store")
            expect(store.setupChecklistState?.dismissed == true,
                   "10.12 fix1 I5: the seeded `dismissed` was adopted into the live setup-checklist store")
        }

        // --- I6: the fail-closed diagnostic is bounded, once-per-session,
        // and observable via `recordedDiagnostics` (a Release-safe seam —
        // production also emits it through `os.Logger`, not `#if DEBUG
        // print(...)`, so it survives Release builds too).
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-fix1-i6")
            let binding = hexBinding("bind-i6-diag")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-i6", binding: binding)
            // Corrupt the setup-checklist file so activation fails closed.
            try Data("not valid json".utf8).write(to: dir.appendingPathComponent("setup-checklist.json"))
            store.testActivateInsightAndChecklistStores(accountBinding: binding)
            expect(store.setupChecklistState == nil, "10.12 fix1 I6 sanity: the corrupt file made activation fail closed")
            expect(store.recordedDiagnostics.contains("setupChecklistState"),
                   "10.12 fix1 I6: the fail-closed diagnostic code was recorded")
            let countAfterFirst = store.recordedDiagnostics.filter { $0 == "setupChecklistState" }.count
            // Re-activating against the SAME still-corrupt file must not
            // re-emit — once per session per code.
            store.testActivateInsightAndChecklistStores(accountBinding: binding)
            let countAfterSecond = store.recordedDiagnostics.filter { $0 == "setupChecklistState" }.count
            expect(countAfterSecond == countAfterFirst,
                   "10.12 fix1 I6: the diagnostic is emitted at most once per session per code, even after a second failure")
        }

        // --- I7(a): drive `applyCompletedSignOutState()` for real (not just
        // `useAnotherAccount()`/`applyRecoverySignedOutState()`, already
        // covered above) and assert both owner-bound stores are scrubbed.
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-fix1-i7a")
            let binding = hexBinding("bind-i7a")
            seed08Owner(store, binding: binding)
            store.testActivateInsightAndChecklistStores(accountBinding: binding)
            store.markSetupTaskDone(.rate)
            expect(store.setupChecklistState?.isDone(.rate) == true, "10.12 fix1 I7a sanity: rate recorded before sign-out")

            store.testApplyCompletedSignOutState()
            expect(store.setupChecklistState == nil,
                   "10.12 fix1 I7a: a real applyCompletedSignOutState() scrubs setupChecklistState")
            expect(store.insightMutes == nil,
                   "10.12 fix1 I7a: a real applyCompletedSignOutState() scrubs insightMutes")

            let relaunched = AppStore(fileURL: dir.appendingPathComponent("store.json"), seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(),
                                      secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-i7a", binding: binding)
            relaunched.testActivateInsightAndChecklistStores(accountBinding: binding)
            expect(relaunched.setupChecklistState != nil,
                   "10.12 fix1 I7a: the relaunched, re-activated store reads back a real (non-nil) checklist state")
            expect(relaunched.setupChecklistState?.isDone(.rate) == false,
                   "10.12 fix1 I7a: the on-disk setup-checklist store was actually removed by applyCompletedSignOutState, not just the in-memory copy")
        }

        // --- I7(b): apply a mute, cross a boundary, relaunch/reactivate, and
        // assert the on-disk mute is gone (mirrors the I7(a)/existing scrub
        // tests' relaunch pattern, for the mute store specifically).
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-fix1-i7b")
            let binding = hexBinding("bind-i7b")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-i7b", binding: binding)
            store.testActivateInsightAndChecklistStores(accountBinding: binding)
            store.applyInsightMute(insight1012(.lowMarginEstimate, id: "low_margin_estimate:i7b"), days: nil)
            expect(store.insightMutes?.isEmpty == false, "10.12 fix1 I7b sanity: a mute was recorded before the boundary")

            store.testApplyCompletedSignOutState()

            let relaunched = AppStore(fileURL: dir.appendingPathComponent("store.json"), seedIfMissing: false,
                                      subscriptionService: StoreSubscriptionServiceStub(),
                                      secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-i7b", binding: binding)
            relaunched.testActivateInsightAndChecklistStores(accountBinding: binding)
            expect(relaunched.insightMutes != nil,
                   "10.12 fix1 I7b: the relaunched, re-activated store reads back a real (non-nil) mute list")
            expect(relaunched.insightMutes?.isEmpty == true,
                   "10.12 fix1 I7b: the on-disk insight-mute store was actually wiped by the boundary scrub, not just the in-memory copy")
        }

        // --- I7(d): the unreadable/corrupt-file path AND a wrong-owner file
        // both fail closed identically — non-muteable kinds only, no mute
        // controls, checklist hidden, insights gated.
        do {
            let (store, dir) = try seed08Store(settings: settings08(), tag: "1012-fix1-i7d-corrupt")
            let binding = hexBinding("bind-i7d-corrupt")
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-i7d", binding: binding)
            try Data("not valid json".utf8).write(to: dir.appendingPathComponent("insight-mutes.json"))
            try Data("not valid json".utf8).write(to: dir.appendingPathComponent("setup-checklist.json"))
            store.testActivateInsightAndChecklistStores(accountBinding: binding)
            expect(store.insightMutes == nil, "10.12 fix1 I7d: a corrupt mute file activates to nil (fail-closed)")
            expect(store.setupChecklistState == nil, "10.12 fix1 I7d: a corrupt checklist file activates to nil (fail-closed)")
            expect(store.todaySetupTasks == nil, "10.12 fix1 I7d: the checklist card stays hidden")
            expect(!store.todayInsightsVisible, "10.12 fix1 I7d: the insights card stays gated (setup reads as incomplete)")
            let fromCorrupt = NativeInsightsCardPolicy.visibleInsights(
                all: [insight1012(.laborOverrun, id: "labor_overrun:i7d"), insight1012(.maintenanceDue, id: "maintenance_due:i7d")],
                mutes: store.insightMutes, now: Date()
            )
            expect(fromCorrupt.map(\.id) == ["labor_overrun:i7d"],
                   "10.12 fix1 I7d: with mutes nil, only the non-muteable kind renders — no mute controls are possible without a readable store")
            expect(!NativeInsightsCardPolicy.muteControlsAvailable(for: .maintenanceDue, mutes: store.insightMutes),
                   "10.12 fix1 I7d: mute controls are unavailable when the store is unreadable")

            // A file bound to a DIFFERENT owner is the other unreadable-store
            // shape (accountBindingMismatch, not unsupportedSchema/decode
            // failure) — same fail-closed outcome.
            let (wrongOwnerStore, wrongOwnerDir) = try seed08Store(settings: settings08(), tag: "1012-fix1-i7d-wrongowner")
            let realBinding = hexBinding("bind-i7d-real")
            let otherBinding = hexBinding("bind-i7d-other")
            wrongOwnerStore.scheduleBookingTestSeedSignedInOwner(subject: "user-i7d-owner", binding: otherBinding)
            wrongOwnerStore.testActivateInsightAndChecklistStores(accountBinding: otherBinding)
            wrongOwnerStore.markSetupTaskDone(.rate)
            // Also write the mute file — an insight-mutes.json that never
            // existed loads as `[]` (a genuinely empty but READABLE store,
            // not unreadable), which wouldn't exercise the mismatch path.
            wrongOwnerStore.applyInsightMute(insight1012(.lowMarginEstimate, id: "low_margin_estimate:i7d-wrongowner"), days: nil)
            // Now "sign in" as a DIFFERENT owner over the same on-disk files.
            let impersonating = AppStore(fileURL: wrongOwnerDir.appendingPathComponent("store.json"), seedIfMissing: false,
                                         subscriptionService: StoreSubscriptionServiceStub(),
                                         secureSettingsStore: hostTestSecureSettingsStore())
            impersonating.scheduleBookingTestSeedSignedInOwner(subject: "user-i7d-real", binding: realBinding)
            impersonating.testActivateInsightAndChecklistStores(accountBinding: realBinding)
            expect(impersonating.setupChecklistState == nil,
                   "10.12 fix1 I7d: a setup-checklist file bound to a DIFFERENT owner activates to nil (accountBindingMismatch fails closed)")
            expect(impersonating.insightMutes == nil,
                   "10.12 fix1 I7d: an insight-mute file bound to a DIFFERENT owner activates to nil (accountBindingMismatch fails closed)")
        }

        // --- I7(e): snooze expiry — once `until` has passed, the row comes
        // back (pure policy, `NativeInsightsCardPolicy`/`NativeInsightMutes`).
        do {
            let now = ISO8601DateFormatter().date(from: "2026-09-23T12:00:00Z")!
            let insight = insight1012(.maintenanceDue, id: "maintenance_due:i7e")
            let expiredSnooze = [NativeInsightMute(id: insight.id, mutedAt: "2026-08-01T00:00:00.000Z", until: "2026-09-01")]
            let stillVisible = NativeInsightsCardPolicy.visibleInsights(all: [insight], mutes: expiredSnooze, now: now)
            expect(stillVisible.map(\.id) == [insight.id],
                   "10.12 fix1 I7e: once `until` (2026-09-01) has passed relative to `now` (2026-09-23), the snoozed row is visible again")

            let activeSnooze = [NativeInsightMute(id: insight.id, mutedAt: "2026-09-20T00:00:00.000Z", until: "2099-01-01")]
            let stillHidden = NativeInsightsCardPolicy.visibleInsights(all: [insight], mutes: activeSnooze, now: now)
            expect(stillHidden.isEmpty,
                   "10.12 fix1 I7e sanity: a snooze whose `until` has NOT yet passed still hides the row")
        }

        // --- Minor: the notifications checklist task also fires
        // `setup_checklist_task_opened` with `task: "notifications"`, as RN
        // does — it was previously skipped by the early return in
        // `NativeSetupChecklistCardView.handleTap`. `AppStore` doesn't know
        // which task id triggered the in-card notifications flow, so this
        // exercises the exact call the view now makes before that flow.
        do {
            let recorder = RecordingAnalytics()
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1012-fix1-notif-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: url).save(Canonical.Snapshot(payload: Canonical.SnapshotPayload(settings: settings08())))
            let store = AppStore(fileURL: url, seedIfMissing: false,
                                 subscriptionService: StoreSubscriptionServiceStub(), analytics: recorder,
                                 secureSettingsStore: hostTestSecureSettingsStore())
            store.trackSetupChecklistTaskOpened(.notifications)
            expect(recorder.calls.contains { $0.event == "setup_checklist_task_opened" && $0.properties["task"] == "notifications" },
                   "10.12 fix1 minor: the notifications task also fires setup_checklist_task_opened, matching RN")
        }

        // MARK: - Task 10.13: Coach UI and contextual prefill.

        // Prefill fill-and-clear (ruling R4): one atomic read-and-clear that
        // both call sites (`.onAppear`, `.onChange`) can call unconditionally.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "1013-prefill")
            expect(store.consumePendingCoachPrefill() == nil,
                   "10.13 consumePendingCoachPrefill returns nil when nothing is pending")
            store.installPendingCoachPrefill("Why is this job low margin?")
            expect(store.pendingCoachPrefill == "Why is this job low margin?",
                   "10.13 sanity: installPendingCoachPrefill (10.12) still sets the published value")
            let consumed = store.consumePendingCoachPrefill()
            expect(consumed == "Why is this job low margin?",
                   "10.13 consumePendingCoachPrefill returns the installed prompt")
            expect(store.pendingCoachPrefill == nil,
                   "10.13 consumePendingCoachPrefill clears the one-shot value immediately")
            expect(store.consumePendingCoachPrefill() == nil,
                   "10.13 a second consume (simulating both .onAppear AND .onChange firing) returns nil — it never re-fires")
        }

        // Business-snapshot cold start (10.09 ruling): fails closed to nil
        // with no verified owner; builds one on demand — reflecting the
        // ACTUAL seeded canonical data, not a static empty shell — when an
        // owner exists but no sync pass has published `cachedBusinessSnapshot`
        // yet.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "1013-snapshot-noowner")
            expect(store.cachedBusinessSnapshot == nil,
                   "10.13 sanity: no committed sync pass has published a cached snapshot yet")
            expect(store.coachBusinessSnapshot() == nil,
                   "10.13 coachBusinessSnapshot fails closed to nil with no verified owner, rather than building on demand for an unauthenticated session")

            let (ownedStore, _) = try seed08Store(
                customers: [customer1012(id: "cust-1013", name: "Snapshot Co")],
                settings: settings08(), tag: "1013-snapshot-owner"
            )
            seed08Owner(ownedStore, subject: "user-1013", binding: "bind-1013")
            expect(ownedStore.cachedBusinessSnapshot == nil,
                   "10.13 sanity: still no committed sync pass on the owned store")
            let onDemand = ownedStore.coachBusinessSnapshot()
            expect(onDemand != nil,
                   "10.13 coachBusinessSnapshot builds one on demand for a verified owner instead of showing no quick prompts")
            expect(onDemand?.aggregate.totalCustomers == 1,
                   "10.13 the on-demand snapshot reflects the ACTUAL seeded canonical data (1 customer), not a static empty shell")
        }

        // System-prompt wiring: `coachTestSystemPrompt()` proves
        // `sendCoachMessage` actually threads the live canonical settings +
        // on-demand snapshot into 10.10's `NativeCoachPrompt` — the format
        // itself is 10.10's own pinned fixture, not re-verified here.
        do {
            let (store, _) = try seed08Store(
                customers: [customer1012(id: "cust-prompt", name: "Prompt Co")],
                settings: settings08(), tag: "1013-system-prompt"
            )
            seed08Owner(store, subject: "user-prompt", binding: "bind-prompt")
            let prompt = store.coachTestSystemPrompt()
            expect(prompt?.contains("Ada Electric") == true,
                   "10.13 coachTestSystemPrompt threads the live canonical businessName into NativeCoachPrompt")
            expect(prompt?.contains("BUSINESS DATA") == true,
                   "10.13 coachTestSystemPrompt passes a non-nil on-demand snapshot, so the BUSINESS DATA block is present")
        }

        // Provider-routing + transport wiring end to end through
        // `sendCoachMessage`, using the coach-key/session TEST OVERRIDES
        // (never the real Keychain) and an injected fake loader — 10.10
        // already pins the per-provider request/response fixtures; this
        // proves `AppStore` actually reaches that transport with the right
        // provider selected, not a re-derivation of the format rules.
        do {
            let loader = CoachTestLoader()
            loader.responseData = Data(#"{"text":"Backend reply"}"#.utf8)
            let coachTransport = NativeCoachTransport(
                backendBaseURL: URL(string: "https://backend.invalid")!, loader: loader
            )
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1013-backend-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: url).save(
                Canonical.Snapshot(payload: Canonical.SnapshotPayload(settings: settings08()))
            )
            let recorder = RecordingAnalytics()
            let store = AppStore(fileURL: url, seedIfMissing: false,
                                 subscriptionService: StoreSubscriptionServiceStub(),
                                 coachTransport: coachTransport, analytics: recorder,
                                 secureSettingsStore: hostTestSecureSettingsStore())
            seed08Owner(store, subject: "user-backend", binding: "bind-backend")
            // Force the backend branch deterministically regardless of what
            // (if anything) the real Keychain holds on the machine running
            // this test.
            store.coachAdvisoryAnthropicKeyOverride = ""
            store.coachAdvisoryGroqKeyOverride = ""

            let reply = try await store.sendCoachMessage(
                history: [NativeCoachMessage(role: .user, text: "How's my month?")]
            )
            expect(reply == "Backend reply", "10.13 sendCoachMessage returns the backend transport's reply verbatim")
            expect(loader.lastRequest?.url?.path.contains("api/ai-chat") == true,
                   "10.13 sendCoachMessage routes to the backend proxy when no client key is set")
            expect(loader.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer test-session-token",
                   "10.13 sendCoachMessage authenticates the backend call with the current session bearer token")

            store.trackCoachMessageSent(sourceIsInsightPrefill: true)
            expect(recorder.calls.contains {
                $0.event == "ai_chat_sent" && $0.properties["source"] == "insight_prefill" && $0.properties["provider"] == "backend"
            }, "10.13 trackCoachMessageSent(sourceIsInsightPrefill: true) fires ai_chat_sent with source=insight_prefill and the exact routed provider")

            store.trackCoachMessageSent(sourceIsInsightPrefill: false)
            expect(recorder.calls.contains {
                $0.event == "ai_chat_sent" && $0.properties["source"] == "organic" && $0.properties["provider"] == "backend"
            }, "10.13 trackCoachMessageSent(sourceIsInsightPrefill: false) fires ai_chat_sent with source=organic")
        }

        // The Anthropic-key branch, still through the same `sendCoachMessage`
        // seam — proves the override actually changes which provider is
        // selected, not just that the backend path works.
        do {
            let loader = CoachTestLoader()
            loader.responseData = Data(#"{"content":[{"type":"text","text":"Hello from Claude"}]}"#.utf8)
            let coachTransport = NativeCoachTransport(backendBaseURL: nil, loader: loader)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-1013-anthropic-\(UUID().uuidString)", isDirectory: true)
            let url = dir.appendingPathComponent("store.json")
            try Canonical.SnapshotRepository(primaryURL: url).save(
                Canonical.Snapshot(payload: Canonical.SnapshotPayload(settings: settings08()))
            )
            let anthropicStore = AppStore(fileURL: url, seedIfMissing: false,
                                          subscriptionService: StoreSubscriptionServiceStub(),
                                          coachTransport: coachTransport,
                                          secureSettingsStore: hostTestSecureSettingsStore())
            anthropicStore.scheduleBookingTestSeedSignedInOwner(subject: "user-anthropic", binding: "bind-anthropic")
            anthropicStore.coachAdvisoryAnthropicKeyOverride = "test-anthropic-key"
            anthropicStore.coachAdvisoryGroqKeyOverride = ""

            let reply = try await anthropicStore.sendCoachMessage(
                history: [NativeCoachMessage(role: .user, text: "Help me price a job")]
            )
            expect(reply == "Hello from Claude", "10.13 sendCoachMessage routes to Anthropic when an Anthropic key override is set")
            expect(loader.lastRequest?.url?.host == "api.anthropic.com",
                   "10.13 sendCoachMessage's Anthropic branch hits the Anthropic endpoint, not the backend proxy")
        }

        // Pure transcript/limit/error-bubble policy (this task's own module,
        // `NativeCoachTranscript.swift`) — no AppStore/network involvement.
        do {
            let longInput = String(repeating: "a", count: 2500)
            expect(NativeCoachInputLimit.clamp(longInput).count == 2000,
                   "10.13 NativeCoachInputLimit.clamp truncates to RN's TextInput maxLength={2000}")
            let shortInput = "hi there"
            expect(NativeCoachInputLimit.clamp(shortInput) == shortInput,
                   "10.13 NativeCoachInputLimit.clamp leaves input under the limit untouched")

            expect(NativeCoachErrorBubble.text(for: .missingAnthropicKey)
                   == "Something went wrong: No AI key set. Add your Anthropic API key in Settings → AI Assistant.",
                   "10.13 NativeCoachErrorBubble mirrors RN's `Something went wrong: ${msg}` catch-block copy exactly")
            expect(NativeCoachErrorBubble.text(for: .unavailable) == "Something went wrong: AI error",
                   "10.13 NativeCoachErrorBubble covers the transport-level .unavailable case too")

            let userMessage = NativeCoachTranscriptMessage(id: "1", role: .user, text: "**not bold for me**")
            expect(NativeCoachTranscriptDisplay.displayText(for: userMessage) == "**not bold for me**",
                   "10.13 the user's own words are rendered verbatim, never markdown-formatted")
            let aiMessage = NativeCoachTranscriptMessage(id: "2", role: .assistant, text: "**bold** and\n- a bullet")
            expect(NativeCoachTranscriptDisplay.displayText(for: aiMessage) == "bold and\n\u{2022} a bullet",
                   "10.13 an assistant reply is rendered through NativeChatMarkdown.formatChatText (10.10) — bold stripped, and a LINE-LEADING bullet becomes \u{2022}")

            expect(NativeCoachTranscriptDisplay.shouldShowNewChat(messageCount: 0) == false,
                   "10.13 New chat stays hidden with an empty transcript")
            expect(NativeCoachTranscriptDisplay.shouldShowNewChat(messageCount: 1) == true,
                   "10.13 New chat appears once any message exists, matching RN's messages.length > 0")
        }

        // MARK: - Task 10.13 fix round 1: stale coach replies.
        //
        // The bug: `CoachView.send()` used to append a reply after its await
        // unconditionally, so a reply resolving after "New chat" (or a
        // sign-out/account-switch) landed in a transcript — or account — it
        // no longer belonged to. The fix: capture a
        // `NativeCoachConversationTicket` (generation + verified account
        // binding) before the await, and only append if
        // `AppStore.coachReplyStillValid(_:)` still says yes after.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "1013-fix1-guard")
            seed08Owner(store, subject: "user-guard", binding: "bind-guard-a")

            // Positive case: neither the generation nor the owner binding
            // moved between capturing the ticket and re-checking it — the
            // reply is still valid to append.
            let ticket = store.coachConversationTicket()
            expect(store.coachReplyStillValid(ticket),
                   "10.13 fix1: a reply is valid to append when neither generation nor owner binding changed")

            // "New chat" bumps the generation — a ticket captured before the
            // bump must never validate again, matching the coordinator's
            // required case: "send, bump the generation, resolve, and
            // assert no append."
            store.bumpCoachConversationGeneration()
            expect(!store.coachReplyStillValid(ticket),
                   "10.13 fix1: New chat bumping the generation invalidates an in-flight reply's ticket")

            // A freshly captured ticket AFTER the bump is valid again — the
            // guard rejects only STALE tickets, not every send after a
            // "New chat".
            let freshTicket = store.coachConversationTicket()
            expect(store.coachReplyStillValid(freshTicket),
                   "10.13 fix1: a freshly captured ticket after the bump is valid")

            // Account-binding change (sign-out/account-switch) invalidates
            // too, even with the generation bumped again by the same
            // account-boundary path (`resetTodayOwnerState()`) — the
            // "Same for a binding change" required case.
            let bindingTicket = store.coachConversationTicket()
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-guard-2", binding: "bind-guard-b")
            expect(!store.coachReplyStillValid(bindingTicket),
                   "10.13 fix1: an account-binding change invalidates an in-flight reply's ticket")
        }

        // MARK: - Phase 10 final-review fix wave

        // I1 (RN parity option (a), contract §9.6): an ARCHIVED job is still
        // shown on Today and still gets appt_/review_ notifications (RN
        // `utils/archive.ts`), so every one of those surfaces must route on
        // tap. Pairs "row shown / notification scheduled" with "tap routes"
        // on the same store, then proves missing/foreign still fail closed.
        do {
            let dirI1 = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-fw-i1-\(UUID().uuidString)", isDirectory: true)
            let store = AppStore(fileURL: dirI1.appendingPathComponent("store.json"), seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-fw-i1", binding: String(repeating: "f", count: 64))
            store.settings.appointmentRemindersEnabled = true
            store.settings.reviewRequestEnabled = true
            store.settings.reviewRequestDelayHours = 2

            let customer = Customer(name: "Archie Vance", email: "archie@example.test", phone: "555-0142")
            expect(store.upsert(customer), "I1 fixture customer saves")
            let now = Date()
            var scheduled = Job(customerId: customer.id, customerName: customer.name,
                                title: "Archived panel swap", status: .scheduled, laborRate: 95)
            scheduled.scheduledAt = Calendar.current.date(byAdding: .day, value: 3, to: now)
            expect(store.upsert(scheduled), "I1 fixture scheduled job saves")
            expect(store.setJobArchived(id: scheduled.id, archived: true), "I1 archiving the scheduled job commits")
            let canonicalScheduled = store.canonicalJobs.first(where: { $0.id == scheduled.id })
            expect(!(canonicalScheduled?.archivedAt ?? "").isEmpty, "I1 sanity: the job is archived in canonical truth")

            // Row shown ...
            if let date = canonicalScheduled?.scheduledDate { store.selectTodayDate(date) }
            expect(store.todaySelectedDaySchedule.contains(where: { $0.id == scheduled.id }),
                   "I1 an archived scheduled job is still a Today schedule row (RN archive.ts: Today still sees archived)")
            // ... and its tap routes.
            store.selectedTab = .today
            expect(store.routeToToday(.job(jobId: scheduled.id)) == .handled
                       && store.selectedTab == .jobs && store.deepLinkedJobID == scheduled.id,
                   "I1 tapping the archived job's Today row routes to the job, never a dead tap")

            // Notification scheduled ...
            expect(store.appointmentConfirmationNotifications(now: now)
                       .contains(where: { $0.identifier == "appt_\(scheduled.id)" }),
                   "I1 an archived scheduled job still gets its appt_ notification")
            // ... and its tap routes.
            store.selectedTab = .today
            store.deepLinkedJobID = nil
            store.requestAppointmentConfirmationReview(jobID: scheduled.id)
            expect(store.selectedTab == .jobs && store.pendingAppointmentConfirmationJobID == scheduled.id,
                   "I1 tapping the archived job's appt_ notification opens the confirmation review")
            store.dismissPendingAppointmentConfirmation(jobID: scheduled.id)

            // review_: complete a job (arms the one-shot), archive it, and
            // pair the scheduled request with a routing tap.
            var working = Job(customerId: customer.id, customerName: customer.name,
                              title: "Archived water heater", status: .inProgress, laborRate: 95)
            working.scheduledAt = now
            expect(store.upsert(working), "I1 fixture in-progress job saves")
            expect(store.completeJob(id: working.id, from: .inProgress, on: now) == .completed,
                   "I1 completing the job arms review_")
            expect(store.setJobArchived(id: working.id, archived: true), "I1 archiving the completed job commits")
            expect(store.reviewRequestNotifications(now: now)
                       .contains(where: { $0.identifier == "review_\(working.id)" }),
                   "I1 an archived completed job still has its review_ notification scheduled")
            store.selectedTab = .today
            store.requestReviewRequestReview(jobID: working.id)
            expect(store.selectedTab == .jobs && store.pendingReviewRequestJobID == working.id,
                   "I1 tapping the archived job's review_ notification opens the review draft")
            store.dismissPendingReviewRequest(jobID: working.id)

            // Missing id: every route still fails closed.
            store.selectedTab = .today
            expect(store.routeToToday(.job(jobId: "missing-i1")) == .none, "I1 a missing job id still fails closed on Today")
            store.requestAppointmentConfirmationReview(jobID: "missing-i1")
            store.requestReviewRequestReview(jobID: "missing-i1")
            expect(store.selectedTab == .today, "I1 a missing job id still fails closed for appt_/review_ taps")

            // Foreign / non-owned: a signed-in gate with no verified owner
            // binding is not an exact workspace, so the same archived job's
            // notification taps must not route.
            store.scheduleBookingTestClearOwner()
            store.testSetAuthenticationGateState(.signedIn(email: nil))
            store.selectedTab = .today
            store.requestAppointmentConfirmationReview(jobID: scheduled.id)
            store.requestReviewRequestReview(jobID: working.id)
            expect(store.selectedTab == .today
                       && store.pendingAppointmentConfirmationJobID == nil
                       && store.pendingReviewRequestJobID == nil,
                   "I1 a foreign/non-exact workspace still fails closed for the archived job's taps")
        }

        // I2: the coach snapshot is always built from LIVE canonical data.
        // Publish once through a real committed pull (so the sync-time cache
        // exists), then make a LOCAL edit with no pull — mark the invoice
        // paid — and prove the coach sees it while the cache is still stale.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(customers: [customer1012(id: "cust-fw-i2", name: "Paid Later Co")],
                                             settings: settings08(), delta: delta, tag: "fw-i2")
            seed08Owner(store, subject: "user-fw-i2", binding: "bind-fw-i2")
            let invoice = Invoice(customerId: "cust-fw-i2", customer: "Paid Later Co", number: "INV-FW-I2", amount: 250)
            store.upsert(invoice)
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(store.cachedBusinessSnapshot?.outstandingTotal == 250,
                   "I2 sanity: the committed pull published a cache with $250 outstanding")
            expect(store.coachBusinessSnapshot()?.outstandingTotal == 250,
                   "I2 sanity: before the edit the coach also sees $250 outstanding")

            _ = store.settleInvoice(invoiceID: invoice.id, paymentID: "payment-fw-i2")
            expect(store.cachedBusinessSnapshot?.outstandingTotal == 250,
                   "I2 sanity: with no pull the sync-time cache is still stale ($250)")
            expect(store.coachBusinessSnapshot()?.outstandingTotal == 0,
                   "I2 after marking the invoice paid locally (no pull) the coach snapshot shows $0 outstanding")
            expect(store.coachTestSystemPrompt()?.contains("Outstanding: $0") == true,
                   "I2 the coach system prompt sendCoachMessage builds cites the live $0 outstanding, not the stale cache")
        }

        // I4: Settings › AI Assistant shows the provider the coach actually
        // routes to, from the same precedence sendCoachMessage uses.
        do {
            let (store, _) = try seed08Store(settings: settings08(), tag: "fw-i4")
            seed08Owner(store, subject: "user-fw-i4", binding: "bind-fw-i4")
            store.coachAdvisoryAnthropicKeyOverride = ""
            store.coachAdvisoryGroqKeyOverride = ""
            expect(store.coachProviderSummary.service == "TradeReady AI"
                       && store.coachProviderSummary.connection == "Backend managed",
                   "I4 no client key: Settings shows the backend-managed TradeReady AI provider")
            store.coachAdvisoryGroqKeyOverride = "test-groq-key"
            expect(store.coachProviderSummary.service == "Groq" && store.coachProviderSummary.analyticsName == "groq",
                   "I4 a Groq key: Settings shows Groq")
            store.coachAdvisoryAnthropicKeyOverride = "test-anthropic-key"
            expect(store.coachProviderSummary.service == "Anthropic (Claude)"
                       && store.coachProviderSummary.analyticsName == "anthropic",
                   "I4 an Anthropic key wins precedence: Settings shows Anthropic, matching the transport routing")
            expect(!store.coachProviderSummary.service.contains("test-anthropic-key")
                       && !store.coachProviderSummary.connection.contains("test-anthropic-key"),
                   "I4 the provider summary never carries the key")
        }

        // I6: a gate that lands in `.accountMismatch` / `.unavailable` while
        // a real pull is suspended must not publish — no notification
        // synchronize, no observer call, no cache write — through the real
        // `pullDeltaIfPossible` commit path. Positive control first.
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "fw-i6-control")
            seed08Owner(store, subject: "user-fw-i6", binding: "bind-fw-i6")
            var notifyCalls = 0
            var observed = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            store.registerDerivedStateObserver { _ in observed += 1 }
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(notifyCalls == 1 && observed == 1 && store.cachedBusinessSnapshot != nil,
                   "I6 control: an exact signed-in workspace publishes once from the committed pull")
        }
        for (label, gate) in [("accountMismatch", NativeAuthenticationGateState.accountMismatch),
                              ("unavailable", NativeAuthenticationGateState.unavailable)] {
            let delta = ScheduleBookingTestDelta()
            delta.gatePull = true
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "fw-i6-\(label)")
            seed08Owner(store, subject: "user-fw-i6", binding: "bind-fw-i6")
            var notifyCalls = 0
            var observed = 0
            store.notificationSynchronizeHook = { _ in notifyCalls += 1 }
            store.registerDerivedStateObserver { _ in observed += 1 }
            let run = Task { await store.runBookingIntakeAfterVerifiedPull() }
            await wait08For(delta.enteredPull)
            expect(delta.enteredPull, "I6 \(label): sanity — the real pull is suspended in flight")
            // Same subject, so `pullDeltaIfPossible` still commits; only the
            // gate moved (exactly what `advancePastInitialSync` does).
            store.testSetAuthenticationGateState(gate)
            delta.resumePull?.resume(returning: NativeDeltaPullOutcome(
                snapshot: Canonical.Snapshot(payload: Canonical.SnapshotPayload(settings: settings08())),
                cursor: Canonical.NativeSyncCursor(version: 2, tables: [:]), failedTables: [], lastDiagnosticCode: nil))
            _ = await run.value
            expect(store.derivedStatePublishBinding == nil,
                   "I6 \(label): the exact-workspace publish predicate is nil")
            expect(notifyCalls == 0, "I6 \(label): the committed pull does NOT reach notification synchronize")
            expect(observed == 0, "I6 \(label): no registered observer (the 11.01 widget mirror) is called")
            expect(store.cachedBusinessSnapshot == nil, "I6 \(label): no cache write")
        }
        // A cache published for the exact workspace is unreadable once the
        // gate falls to `.accountMismatch` (the publisher's owner re-check
        // uses the same predicate).
        do {
            let delta = ScheduleBookingTestDelta()
            let (store, _) = try seed08Store(settings: settings08(), delta: delta, tag: "fw-i6-read")
            seed08Owner(store, subject: "user-fw-i6r", binding: "bind-fw-i6r")
            _ = await store.runBookingIntakeAfterVerifiedPull()
            expect(store.cachedBusinessSnapshot != nil, "I6 sanity: the exact workspace cached a snapshot")
            store.testSetAuthenticationGateState(.accountMismatch)
            expect(store.cachedBusinessSnapshot == nil,
                   "I6 the cache read fails closed once the gate is .accountMismatch")
        }

        // m3: a duplicate job id in the persisted snapshot must not trap the
        // schedule key (evaluated on every root render) or the inv_ selector.
        do {
            let dirM3 = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-fw-m3-\(UUID().uuidString)", isDirectory: true)
            let urlM3 = dirM3.appendingPathComponent("store.json")
            let seeded = AppStore(fileURL: urlM3, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            let dupJob = Job(customerId: "c-m3", customerName: "Dup Co", title: "Duplicated", status: .scheduled, laborRate: 95)
            expect(seeded.upsert(dupJob), "m3 fixture job saves")
            var persisted = try Canonical.SnapshotRepository(primaryURL: urlM3).load()!.snapshot
            let original = persisted.payload.jobs!.first(where: { $0.id == dupJob.id })!
            var shadow = original
            shadow.title = "Duplicated (second copy)"
            persisted.payload.jobs!.append(shadow)
            try Canonical.SnapshotRepository(primaryURL: urlM3).save(persisted)

            let relaunched = AppStore(fileURL: urlM3, seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            relaunched.scheduleBookingTestSeedSignedInOwner(subject: "user-fw-m3", binding: String(repeating: "3", count: 64))
            expect(relaunched.canonicalJobs.filter { $0.id == dupJob.id }.count == 2,
                   "m3 sanity: the relaunched store really holds two jobs with the same id")
            let key = relaunched.estimateFollowUpNotificationScheduleKey
            expect(key != "inactive" && key.contains(dupJob.id),
                   "m3 the schedule key builds (no trap) with a duplicate job id")
            _ = relaunched.invoiceReminderNotifications()
            expect(true, "m3 the inv_ selector builds (no trap) with a duplicate job id")
        }

        // m5: a recurring-rule tap with nothing generated yet must clear an
        // earlier one-shot invoice/outreach target so the Invoices tab opens
        // its list, not an unrelated invoice.
        do {
            let dirM5 = FileManager.default.temporaryDirectory
                .appendingPathComponent("tradeready-fw-m5-\(UUID().uuidString)", isDirectory: true)
            let store = AppStore(fileURL: dirM5.appendingPathComponent("store.json"), seedIfMissing: false, secureSettingsStore: hostTestSecureSettingsStore())
            store.scheduleBookingTestSeedSignedInOwner(subject: "user-fw-m5", binding: String(repeating: "5", count: 64))
            let customer = Customer(name: "Stale Link Co", email: "stale@example.test")
            expect(store.upsert(customer), "m5 fixture customer saves")
            let unrelated = Invoice(customerId: customer.id, customer: customer.name, number: "INV-M5", amount: 90)
            store.upsert(unrelated)
            let rule = Canonical.RecurringInvoice(
                id: "rinv-fw-m5", customerId: customer.id, customerName: customer.name,
                description: "Monthly service", amount: 120, dueDays: 30,
                cadence: "monthly", endCondition: "never", endCount: nil, endDate: nil,
                occurrenceCount: 0, lastGeneratedDate: nil, nextDueDate: "2026-12-01",
                isActive: true, createdAt: "2026-09-01", autoSendEnabled: false)
            expect(store.createRecurringInvoice(rule), "m5 fixture plan creates")
            expect(store.scheduleBookingTestLatestGeneratedInvoiceID(ruleID: rule.id) == nil,
                   "m5 sanity: nothing has generated for the rule yet")

            // An earlier inv_ tap left a one-shot outreach target armed.
            store.requestInvoiceReminderReview(invoiceID: unrelated.id, opensOutreach: true)
            expect(store.deepLinkedInvoiceID == unrelated.id && store.deepLinkedOutreachInvoiceID == unrelated.id,
                   "m5 sanity: the earlier invoice/outreach target is armed")
            store.selectedTab = .today
            store.requestRecurringInvoiceReview(ruleID: rule.id)
            expect(store.selectedTab == .invoices
                       && store.deepLinkedInvoiceID == nil && store.deepLinkedOutreachInvoiceID == nil,
                   "m5 the rinv_ fallback clears the stale invoice/outreach target and opens the plain Invoices list")
        }

        // Task 11.13 fix round 2 (G4/G5): a Square access token is never
        // persisted from Settings, and RN's `scrubLegacySquareToken` heal runs
        // on the synced settings a pull delivers.
        do {
            let squareToken = "EAAAEOuLQObrVwJvCvoio3qx9Bi7MEZ2Ymv2nUx8m2cVYzAh8Kx5yGQZ"
            let squareLink = "https://square.link/u/abc123"
            func diskContains(_ dir: URL, _ needle: String) -> Bool {
                let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL } ?? []
                return files.contains { (try? Data(contentsOf: $0)).map { String(decoding: $0, as: UTF8.self).contains(needle) } ?? false }
            }
            func persistedSquare(_ dir: URL) -> String? {
                (try? Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json")).load())?
                    .snapshot.payload.settings?.providerKeys["square"]
            }
            func settingsUpserts(_ dir: URL) -> [Canonical.MutationItem] {
                pendingMutations(dir.appendingPathComponent("store.json")).filter { $0.table == "settings" && $0.op == .upsert }
            }
            func queuedSquare(_ item: Canonical.MutationItem?) -> Canonical.JSONValue? {
                guard case let .object(fields)? = item?.payload, case let .object(keys)? = fields["providerKeys"] else { return nil }
                return keys["square"]
            }

            // Pasted tokens are rejected and never reach the snapshot, disk or queue.
            for token in [squareToken, "sq0atp-3_Wb0zJnNx7lzM1nb2eP0g", "  \(squareToken) "] {
                let (store, dir) = try seed08Store(settings: settings08(), tag: "sq-reject")
                seed08Owner(store, subject: "user-sq", binding: "bind-sq")
                let queuedBefore = pendingMutations(dir.appendingPathComponent("store.json")).count
                let result = store.setPaymentProviderKey(token, for: "square")
                expect(result == .rejected(NativeSquareProviderKeyPolicy.rejectionMessage),
                       "G5 a pasted Square token is rejected with the RN hint copy")
                expect(store.settings.providerKey(for: "square").isEmpty, "G5 a rejected token never reaches the settings projection")
                expect(persistedSquare(dir) == nil, "G5 a rejected token never reaches the persisted snapshot")
                expect(pendingMutations(dir.appendingPathComponent("store.json")).count == queuedBefore,
                       "G5 a rejected token queues nothing")
                expect(!diskContains(dir, token.trimmingCharacters(in: .whitespaces)), "G5 a rejected token is nowhere on disk")
            }
            // A write that bypasses the validated save (any direct settings
            // edit) is still stripped before the snapshot, disk and queue.
            do {
                let (store, dir) = try seed08Store(settings: settings08(), tag: "sq-bypass")
                seed08Owner(store, subject: "user-sq", binding: "bind-sq")
                store.settings.paymentProviderKeys["square"] = squareToken
                expect(store.settings.paymentProviderKeys["square"] == nil, "G5 a direct Square token write is stripped from the projection")
                expect(persistedSquare(dir) == nil, "G5 a direct Square token write never reaches the snapshot")
                expect(!diskContains(dir, squareToken), "G5 a direct Square token write is nowhere on disk (snapshot or queue)")
            }
            // A valid payment link saves, persists and queues; empty clears.
            do {
                let (store, dir) = try seed08Store(settings: settings08(), tag: "sq-link")
                seed08Owner(store, subject: "user-sq", binding: "bind-sq")
                expect(store.setPaymentProviderKey(squareLink, for: "square") == .saved(squareLink), "G5 a Square payment link saves")
                expect(store.settings.providerKey(for: "square") == squareLink && persistedSquare(dir) == squareLink,
                       "G5 the saved link is projected and persisted")
                expect(queuedSquare(settingsUpserts(dir).last) == .string(squareLink), "G5 the saved link is queued for sync")
                expect(store.setPaymentProviderKey("   ", for: "square") == .saved(""), "G5 an empty Square entry saves")
                expect(persistedSquare(dir) == "", "G5 an empty Square entry clears the stored link")
                expect(store.setPaymentProviderKey("johndoe", for: "venmo") == .saved("johndoe")
                           && store.settings.providerKey(for: "venmo") == "johndoe",
                       "G5 other providers keep RN's unvalidated save")
            }
            // The heal: a pulled settings blob carrying a token is scrubbed on
            // commit, and the cleaned blob is queued so the cloud copy heals.
            do {
                let delta = ScheduleBookingTestDelta()
                var poisoned = settings08()
                poisoned.providerKeys = ["square": squareToken, "venmo": "@me"]
                delta.handler = { local, cursor in
                    var pulled = local
                    pulled.payload.settings = poisoned
                    return NativeDeltaPullOutcome(snapshot: pulled, cursor: cursor, failedTables: [], lastDiagnosticCode: nil)
                }
                let (store, dir) = try seed08Store(settings: settings08(), delta: delta, tag: "sq-heal")
                seed08Owner(store, subject: "user-sq", binding: "bind-sq")
                _ = await store.runBookingIntakeAfterVerifiedPull()
                expect(delta.enteredPull, "G5 heal sanity: the real delta pull ran")
                expect(persistedSquare(dir) == nil
                           && (try? Canonical.SnapshotRepository(primaryURL: dir.appendingPathComponent("store.json")).load())?
                               .snapshot.payload.settings?.providerKeys["venmo"] == "@me",
                       "G5 the pulled Square token is scrubbed from the committed snapshot; other providers stay")
                expect(store.settings.providerKey(for: "square").isEmpty, "G5 the pulled token never reaches the Settings projection")
                let upserts = settingsUpserts(dir)
                expect(upserts.count == 1 && queuedSquare(upserts.first) == nil,
                       "G5 the scrub queues one settings upsert without the Square entry (the cloud copy heals)")
                expect(!diskContains(dir, squareToken), "G5 after the heal the token is nowhere on disk")
                // Idempotent: a second pull that finds nothing writes nothing.
                delta.handler = nil
                _ = await store.runBookingIntakeAfterVerifiedPull()
                expect(settingsUpserts(dir).count == 1, "G5 a heal that finds nothing queues nothing")
            }
            // Gate: never heals (so never queues) outside the exact signed-in workspace.
            do {
                var poisoned = settings08()
                poisoned.providerKeys = ["square": squareToken]
                let (store, dir) = try seed08Store(settings: poisoned, tag: "sq-gate")
                expect(!store.scrubLegacySquareToken() && settingsUpserts(dir).isEmpty,
                       "G5 the heal is gated on the exact signed-in workspace")
                seed08Owner(store, subject: "user-sq", binding: "bind-sq")
                expect(store.scrubLegacySquareToken(), "G5 the heal runs once signed in")
                expect(persistedSquare(dir) == nil && settingsUpserts(dir).count == 1
                           && queuedSquare(settingsUpserts(dir).first) == nil,
                       "G5 the signed-in heal clears the stored token and queues the scrub")
                expect(!store.scrubLegacySquareToken() && settingsUpserts(dir).count == 1,
                       "G5 a second heal finds nothing and writes nothing")
            }
        }

        if failures == 0 { print("PASS: canonical AppStore integration tests") }
        else { print("FAILED: \(failures) canonical AppStore integration test(s)"); exit(1) }
    }
}

private final class ScheduleBookingTestDelta: NativeInitialSyncServing, NativeDeltaSyncServing {
    var gatePull = false
    var enteredPull = false
    var resumePull: CheckedContinuation<NativeDeltaPullOutcome, Never>?
    var handler: ((Canonical.Snapshot, Canonical.NativeSyncCursor) -> NativeDeltaPullOutcome)?

    func pull(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot
    ) async throws -> Canonical.Snapshot {
        localSnapshot
    }

    func pullDelta(
        sessionBytes: Data,
        expectedUserSubject: String,
        localSnapshot: Canonical.Snapshot,
        cursor: Canonical.NativeSyncCursor
    ) async throws -> NativeDeltaPullOutcome {
        enteredPull = true
        if gatePull {
            return await withCheckedContinuation { resumePull = $0 }
        }
        if let handler { return handler(localSnapshot, cursor) }
        return NativeDeltaPullOutcome(snapshot: localSnapshot, cursor: cursor,
                                      failedTables: [], lastDiagnosticCode: nil)
    }
}

/// Records the last request it served and returns a canned (data, status) —
/// task 10.13's `AppStore.sendCoachMessage` wiring tests inject this in
/// place of the live `URLSession` loader (same shape as 10.10's
/// `CoachTransportTests.FakeLoader`).
private final class CoachTestLoader: NativeCoachHTTPDataLoading, @unchecked Sendable {
    var responseData: Data = Data()
    var status: Int = 200
    private(set) var lastRequest: URLRequest?
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

private final class ScheduleBookingTestLoader: NativeBookingResponseHTTPDataLoading,
    NativeBookingAdministrationHTTPDataLoading, NativePortalAdministrationHTTPDataLoading {
    var handler: ((URLRequest) -> (Data, Int))?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, status) = handler?(request) ?? (Data(), 500)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status,
                                      httpVersion: nil, headerFields: nil)!)
    }
}
