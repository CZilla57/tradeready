import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func job(
    status: String = "in_progress",
    estimateTotal: String = "2400",
    changeOrders: [Canonical.ChangeOrder]? = nil,
    preservation: Canonical.Preservation = .init()
) throws -> Canonical.Job {
    let data = Data("""
    {
      "id":"j1","customerId":"c1","customerName":"Dana","title":"Bath remodel",
      "description":"","status":"\(status)","address":"","estimateTotal":\(estimateTotal),
      "laborHours":4,"laborRate":85,"materials":[],"materialMarkup":20,
      "overhead":15,"margin":20,"notes":"","createdAt":"2026-08-01"
    }
    """.utf8)
    var value = try JSONDecoder().decode(Canonical.Job.self, from: data)
    value.changeOrders = changeOrders
    value.preservation = preservation
    return value
}

private func order(
    id: String = "co1",
    amount: String = "850",
    manualDecision: String? = nil,
    cancelledAt: String? = nil,
    preservation: Canonical.Preservation = .init()
) -> Canonical.ChangeOrder {
    .init(
        id: id,
        title: "Rotted subfloor",
        description: "Whole-home unit",
        amount: decimal(amount),
        createdAt: "2026-08-05",
        manualDecision: manualDecision.map {
            .init(decision: $0, decidedAt: "2026-08-05")
        },
        cancelledAt: cancelledAt,
        preservation: preservation
    )
}

private func orderWithApproval(
    decision: String? = nil,
    manualDecision: String? = nil,
    cancelledAt: String? = nil
) throws -> Canonical.ChangeOrder {
    var fields = "\"token\":\"T\",\"sentAt\":\"2026-08-05\",\"snapshot\":{\"businessName\":\"Rivera Plumbing\",\"customerName\":\"Dana\",\"jobTitle\":\"Bath remodel\",\"lineItems\":[],\"total\":850,\"currency\":\"USD\"},\"serverFuture\":true"
    if let decision { fields += ",\"decision\":\"\(decision)\"" }
    var root = "\"id\":\"co1\",\"title\":\"Rotted subfloor\",\"amount\":850,\"createdAt\":\"2026-08-05\",\"approval\":{\(fields)},\"orderFuture\":\"keep\""
    if let manualDecision {
        root += ",\"manualDecision\":{\"decision\":\"\(manualDecision)\",\"decidedAt\":\"2026-08-05\"}"
    }
    if let cancelledAt { root += ",\"cancelledAt\":\"\(cancelledAt)\"" }
    return try JSONDecoder().decode(Canonical.ChangeOrder.self, from: Data("{\(root)}".utf8))
}

@main
struct ChangeOrderTests {
    static func main() throws {
        let pending = order()
        let awaiting = try orderWithApproval()
        let manualApproved = order(manualDecision: "approved")
        let manualDeclined = order(manualDecision: "declined")
        let linkWins = try orderWithApproval(decision: "declined", manualDecision: "approved")
        let cancelled = try orderWithApproval(decision: "approved", cancelledAt: "2026-08-06")

        expect(NativeChangeOrders.status(of: pending) == .pending, "no decision derives pending")
        expect(NativeChangeOrders.status(of: awaiting) == .awaiting, "minted undecided link derives awaiting")
        expect(NativeChangeOrders.status(of: manualApproved) == .approved, "manual approval derives approved")
        expect(NativeChangeOrders.status(of: manualDeclined) == .declined, "manual decline derives declined")
        expect(NativeChangeOrders.status(of: linkWins) == .declined, "server link decision outranks manual decision")
        expect(NativeChangeOrders.status(of: cancelled) == .cancelled, "cancellation outranks every decision")

        let totalsJob = try job(changeOrders: [
            manualApproved,
            order(id: "co2", amount: "100"),
            try orderWithApproval(),
            order(id: "co4", amount: "100", manualDecision: "declined"),
            order(id: "co5", amount: "100", manualDecision: "approved", cancelledAt: "2026-08-06")
        ])
        expect(NativeChangeOrders.approvedTotal(in: totalsJob) == 850, "only approved non-cancelled orders sum")
        expect(NativeChangeOrders.billableTotal(for: totalsJob) == 3250, "billable total adds the approved delta")
        let creditJob = try job(changeOrders: [
            manualApproved,
            order(id: "co2", amount: "-100.005", manualDecision: "approved")
        ])
        expect(NativeChangeOrders.billableTotal(for: creditJob) == 3150, "final billable total rounds to cents")

        for status in ["approved", "scheduled", "in_progress", "complete"] {
            expect(NativeChangeOrders.canAdd(to: status), "\(status) accepts a change order")
        }
        for status in ["lead", "estimate_sent", "invoiced", "paid", "declined"] {
            expect(!NativeChangeOrders.canAdd(to: status), "\(status) rejects a change order")
        }
        let utcBoundary = ISO8601DateFormatter().date(from: "2026-09-19T02:00:00Z")!
        expect(NativeChangeOrders.recordDateString(for: utcBoundary) == "2026-09-19",
               "record date uses the React Native UTC calendar boundary")

        let emptyTitle = NativeChangeOrders.validate(
            title: "  ", description: "", amountText: "850", job: totalsJob
        )
        expect(emptyTitle == .failure(.invalidInput("Please give this change a short title.")),
               "empty title returns the React Native validation copy")
        for text in ["", "abc", "0"] {
            let invalidAmount = NativeChangeOrders.validate(
                title: "Subfloor", description: "", amountText: text, job: totalsJob
            )
            expect(invalidAmount == .failure(.invalidInput("Please enter a non-zero amount (negative for a credit).")),
                   "invalid amount \(text.debugDescription) returns the React Native validation copy")
        }
        let belowZero = NativeChangeOrders.validate(
            title: "Huge credit", description: "", amountText: "-2500", job: try job()
        )
        expect(belowZero == .failure(.invalidInput("This credit would take the job's total below $0.")),
               "credit below zero is blocked")
        let exactZero = NativeChangeOrders.validate(
            title: " Credit ", description: "  Customer supplied fixture  ",
            amountText: "-2400", job: try job()
        )
        expect(exactZero == .success(.init(
            title: "Credit", description: "Customer supplied fixture", amount: -2400
        )), "credit may reduce the billable total exactly to zero and trims text")
        let negativeHalfCent = NativeChangeOrders.validate(
            title: "Credit", description: "", amountText: "-100.005", job: try job()
        )
        expect(negativeHalfCent == .success(.init(title: "Credit", description: nil, amount: -100)),
               "negative half-cent follows JavaScript Math.round toward positive infinity")
        let binaryHalfCent = NativeChangeOrders.validate(
            title: "Small add", description: "", amountText: "1.005", job: try job()
        )
        expect(binaryHalfCent == .success(.init(title: "Small add", description: nil, amount: 1)),
               "amount rounding preserves the React Native IEEE-754 boundary")
        let editedCredit = NativeChangeOrders.validate(
            title: "Credit", description: "", amountText: "-2400",
            job: try job(changeOrders: [order(id: "coE", amount: "-2400")]), editingID: "coE"
        )
        expect(editedCredit.isSuccess, "edited order is excluded from the floor calculation")

        let existingUnknown = Canonical.Preservation(unknownFields: ["futureOrder": .string("keep")])
        let jobUnknown = Canonical.Preservation(unknownFields: ["futureJob": .bool(true)])
        let base = try job(changeOrders: [order(preservation: existingUnknown)], preservation: jobUnknown)
        let added = try NativeChangeOrders.adding(
            to: base, id: "co2", title: "  Added outlet  ", description: "  ",
            amountText: "125.555", createdAt: "2026-08-07"
        )
        expect(added.changeOrders?.count == 2
               && added.changeOrders?.last?.title == "Added outlet"
               && added.changeOrders?.last?.description == nil
               && added.changeOrders?.last?.amount == decimal("125.56"),
               "create trims optional text and rounds amount to cents")
        expect(added.estimateTotal == base.estimateTotal
               && added.preservation.unknownFields == jobUnknown.unknownFields
               && added.changeOrders?.first?.preservation.unknownFields == existingUnknown.unknownFields,
               "create never mutates estimate baseline or existing unknown fields")
        do {
            _ = try NativeChangeOrders.adding(
                to: try job(status: "lead"), id: "co9", title: "X", description: "",
                amountText: "1", createdAt: "2026-08-07"
            )
            expect(false, "ineligible job refuses create")
        } catch {
            expect(error as? NativeChangeOrderError == .jobNotEligible, "ineligible job reports exact error")
        }

        let edited = try NativeChangeOrders.editing(
            "co1", in: base, title: "  New title ", description: " New detail ", amountText: "900.126"
        )
        expect(edited.changeOrders?.first?.title == "New title"
               && edited.changeOrders?.first?.description == "New detail"
               && edited.changeOrders?.first?.amount == decimal("900.13")
               && edited.changeOrders?.first?.createdAt == "2026-08-05"
               && edited.changeOrders?.first?.preservation.unknownFields == existingUnknown.unknownFields,
               "edit changes only editable fields and preserves metadata")
        do {
            _ = try NativeChangeOrders.editing(
                "co1", in: try job(changeOrders: [manualApproved]),
                title: "No", description: "", amountText: "1"
            )
            expect(false, "decided order refuses edit")
        } catch {
            expect(error as? NativeChangeOrderError == .changeOrderNotPending, "decided edit reports pending-only error")
        }

        let approved = try NativeChangeOrders.applyingManualDecision(
            .approved, to: "co1", in: base, note: "  verbal OK  ", decidedAt: "2026-08-08"
        )
        expect(approved.changeOrders?.first?.manualDecision?.decision == "approved"
               && approved.changeOrders?.first?.manualDecision?.decidedAt == "2026-08-08"
               && approved.changeOrders?.first?.manualDecision?.note == "verbal OK",
               "manual approval stores a separate trimmed decision record")
        let awaitingApproved = try NativeChangeOrders.applyingManualDecision(
            .approved, to: "co1", in: try job(changeOrders: [awaiting]), note: "  ", decidedAt: "2026-08-08"
        )
        expect(NativeChangeOrders.status(of: awaitingApproved.changeOrders!.first!) == .approved
               && awaitingApproved.changeOrders?.first?.manualDecision?.note == nil
               && awaitingApproved.changeOrders?.first?.approval?.preservation.unknownFields["serverFuture"] == .bool(true)
               && awaitingApproved.changeOrders?.first?.preservation.unknownFields["orderFuture"] == .string("keep"),
               "awaiting link accepts verbal decision without rewriting server approval or unknown fields")
        do {
            _ = try NativeChangeOrders.applyingManualDecision(
                .declined, to: "co1", in: try job(changeOrders: [manualApproved]),
                note: "", decidedAt: "2026-08-09"
            )
            expect(false, "already decided order refuses a second decision")
        } catch {
            expect(error as? NativeChangeOrderError == .changeOrderNotActionable, "re-decision reports actionable error")
        }

        let cancelledPending = try NativeChangeOrders.cancelling(
            "co1", in: base, cancelledAt: "2026-08-09"
        )
        expect(cancelledPending.changeOrders?.first?.cancelledAt == "2026-08-09"
               && NativeChangeOrders.status(of: cancelledPending.changeOrders!.first!) == .cancelled,
               "pending order can be cancelled one way")
        do {
            _ = try NativeChangeOrders.cancelling(
                "co1", in: try job(changeOrders: [manualApproved]), cancelledAt: "2026-08-09"
            )
            expect(false, "approved order refuses cancellation")
        } catch {
            expect(error as? NativeChangeOrderError == .changeOrderNotActionable, "approved cancellation reports actionable error")
        }

        let deleted = try NativeChangeOrders.deletingPending("co1", in: base)
        expect(deleted.changeOrders?.isEmpty == true, "pending order can be deleted")
        do {
            _ = try NativeChangeOrders.deletingPending(
                "co1", in: try job(changeOrders: [awaiting])
            )
            expect(false, "awaiting order cannot be deleted")
        } catch {
            expect(error as? NativeChangeOrderError == .changeOrderNotPending, "awaiting delete reports pending-only error")
        }

        let encoded = try JSONEncoder().encode(awaitingApproved.changeOrders!.first!)
        let roundTrip = try JSONDecoder().decode(Canonical.ChangeOrder.self, from: encoded)
        expect(roundTrip.approval?.preservation.unknownFields["serverFuture"] == .bool(true)
               && roundTrip.preservation.unknownFields["orderFuture"] == .string("keep"),
               "mutated order re-encodes forward-compatible approval and order fields")

        // MARK: - Job-detail section read model

        let sectionJob = try job(status: "in_progress", changeOrders: [
            order(id: "coA", amount: "150.505"),
            try orderWithApproval(),
            order(id: "coC", amount: "200", manualDecision: "approved"),
            order(id: "coD", amount: "-240", manualDecision: "declined"),
            order(id: "coE", amount: "75", manualDecision: "approved", cancelledAt: "2026-08-06")
        ])
        let section = NativeChangeOrders.sectionState(
            jobID: sectionJob.id,
            status: sectionJob.status,
            changeOrders: sectionJob.changeOrders ?? []
        )
        expect(section.jobID == "j1" && section.rows.count == 5,
               "section projects every change order")
        expect(section.rows.map(\.id) == ["coA", "co1", "coC", "coD", "coE"],
               "section preserves canonical record order")
        expect(section.rows.map(\.statusLabel) == ["Pending", "Awaiting", "Approved", "Declined", "Cancelled"],
               "section labels match the React Native badge copy")
        expect(section.rows.map(\.badgeTone) == [.muted, .accent, .success, .danger, .muted],
               "section badge tones match STATUS_BADGE")
        expect(section.rows.map(\.isActionable) == [true, true, false, false, false],
               "only pending and awaiting rows offer actions")
        expect(section.rows.map(\.canEdit) == [true, false, false, false, false],
               "only pending rows can be edited")
        expect(section.rows.map(\.canDelete) == [true, false, false, false, false],
               "only pending rows can be deleted")
        expect(section.rows[0].title == "Rotted subfloor"
               && section.rows[0].amount == decimal("150.505")
               && section.rows[0].note == nil,
               "row carries the canonical title and amount, and no note when none was recorded")
        expect(section.canAdd && section.isVisible, "an in-progress job shows the section and its add action")
        expect(section.approvedTotal == 200,
               "section total counts only approved, non-cancelled orders")

        let noted = order(id: "coF", amount: "90", manualDecision: "declined")
        var notedOrder = noted
        notedOrder.manualDecision?.note = "Owner supplied the part"
        expect(NativeChangeOrders.row(for: notedOrder).note == "Owner supplied the part",
               "a recorded decision note renders under the title")
        var blankNote = order(id: "coG", manualDecision: "approved")
        blankNote.manualDecision?.note = ""
        expect(NativeChangeOrders.row(for: blankNote).note == nil,
               "an empty decision note renders nothing, matching the oracle's falsy check")

        let emptySection = NativeChangeOrders.sectionState(jobID: "j9", status: "lead", changeOrders: [])
        expect(emptySection.rows.isEmpty && !emptySection.canAdd && !emptySection.isVisible,
               "an empty, not-addable section renders nothing at all")
        let addOnlySection = NativeChangeOrders.sectionState(jobID: "j9", status: "complete", changeOrders: [])
        expect(addOnlySection.isVisible && addOnlySection.approvedTotal == 0,
               "a job with no orders still shows the add action")
        expect(NativeChangeOrders.sectionState(
            jobID: "j9", status: "invoiced", changeOrders: sectionJob.changeOrders ?? []
        ).canAdd == false, "an invoiced job keeps its history but no longer accepts orders")

        expect(NativeChangeOrders.approvedTotal(in: sectionJob.changeOrders ?? []) == 200
               && NativeChangeOrders.approvedTotal(in: sectionJob) == 200,
               "the array and job totals share one rule")
        expect(NativeChangeOrders.approvedTotal(in: [
            order(id: "coH", amount: "199.995", manualDecision: "approved")
        ]) == decimal("200"),
               "the approved subtotal rounds once, like approvedChangeOrderTotal")

        expect(NativeChangeOrderError.jobNotEligible.closesEditorOnFailure
               && NativeChangeOrderError.changeOrderNotPending.closesEditorOnFailure,
               "stale-state refusals close the editor after acknowledgement")
        expect(!NativeChangeOrderError.invalidInput("x").closesEditorOnFailure
               && !NativeChangeOrderError.jobNotFound.closesEditorOnFailure
               && !NativeChangeOrderError.duplicateIdentifier.closesEditorOnFailure
               && !NativeChangeOrderError.changeOrderNotFound.closesEditorOnFailure
               && !NativeChangeOrderError.changeOrderNotActionable.closesEditorOnFailure,
               "correctable and retryable refusals keep the form open")

        if failures == 0 {
            print("ChangeOrderTests: PASS")
        } else {
            print("ChangeOrderTests: FAIL (\(failures))")
            exit(1)
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
