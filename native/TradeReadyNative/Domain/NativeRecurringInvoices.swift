import Foundation

/// Pure recurring-invoice (maintenance plan) generation, mirroring
/// `utils/recurringInvoices.ts checkAndGenerateRecurringInvoices`.
///
/// Takes the stored rules plus the stored invoices and returns every
/// occurrence due through `today`, with the rules already advanced past what
/// was generated. The caller (AppStore) commits both collections atomically
/// and queues both for sync; this type never touches persistence itself so
/// the swiftc domain harness can compile it standalone.
///
/// Behavior contract (pinned by `__tests__/recurringInvoices.test.ts`):
/// - Generates all occurrences with `nextDueDate <= today` (catch-up).
/// - Dedupes by `(recurringInvoiceId, occurrenceNumber)` so an occurrence
///   pulled from another device is never recreated; the rule still advances
///   so devices converge to the same `nextDueDate`.
/// - Due date is occurrence date + net terms (local frame, not generation
///   date): catch-up invoices date from when the money was owed.
/// - Numbers every generated invoice against the full working batch.
/// - Snapshots current customer contacts (blank when the customer is gone).
/// - Paused rules (`isActive == false`) generate nothing.
/// - Resume fast-forwarding (no back-billing for elapsed paused periods)
///   lives in `RecurrenceRules.fastForwardedInvoiceDate`, applied by the
///   rule manager — never here.
/// - Only the newest invoice created for a rule in this run may be stamped
///   for auto-send, gated by the rule opt-in, the master setting, and a
///   plausible customer email. Catch-up backlog never auto-sends.
struct NativeRecurringInvoiceContact: Equatable {
    var email: String
    var phone: String
}

struct NativeRecurringInvoiceGeneration {
    /// Occurrences created by this run, in generation order.
    var newInvoices: [Canonical.Invoice]
    /// Only the rules that changed (advanced or deactivated), by copy.
    var updatedRules: [Canonical.RecurringInvoice]
    /// IDs stamped with `autoEmailRequestedAt` this run (at most one per rule).
    var autoSendInvoiceIDs: [String]
    /// Whether anything changed. When false the caller must skip its save.
    var didChange: Bool
}

enum NativeRecurringInvoices {
    /// Generates every occurrence due through `today` ("YYYY-MM-DD").
    /// `makeInvoiceID` stamps each occurrence (`inv<ms>`, monotonic within
    /// the run — issue-date extraction depends on the digits-only shape);
    /// `resolveNumber` numbers against the full working batch.
    static func generate(
        rules: [Canonical.RecurringInvoice],
        invoices: [Canonical.Invoice],
        contactsByID: [String: NativeRecurringInvoiceContact],
        contactsByName: [String: NativeRecurringInvoiceContact],
        existingNumbers: [String?],
        today: String,
        makeInvoiceID: () -> String,
        resolveNumber: ([String?]) -> String,
        autoSendMasterEnabled: Bool,
        stampedAt: String,
        calendar: Calendar = .current
    ) -> NativeRecurringInvoiceGeneration {
        var newInvoices: [Canonical.Invoice] = []
        var updatedRules: [Canonical.RecurringInvoice] = []
        var autoSendIDs: [String] = []
        var seen: Set<String> = []
        seen.reserveCapacity(invoices.count)
        for invoice in invoices {
            guard let ruleID = invoice.recurringInvoiceId, !ruleID.isEmpty,
                  let occurrence = invoice.occurrenceNumber
            else { continue }
            seen.insert(dedupeKey(ruleID: ruleID, occurrence: occurrence))
        }
        var numbers = existingNumbers

        for var rule in rules {
            guard rule.isActive else { continue }
            var ruleChanged = false
            var ruleInvoices: [(index: Int, occurrence: Int)] = []
            while rule.nextDueDate <= today {
                if isEndConditionMet(rule) {
                    rule.isActive = false
                    ruleChanged = true
                    break
                }
                let occurrence = rule.occurrenceCount + 1
                let key = dedupeKey(ruleID: rule.id, occurrence: occurrence)
                if !seen.contains(key) {
                    let contact = contactsByID[rule.customerId]
                        ?? contactsByName[rule.customerName]
                    var generated = Canonical.Invoice(
                        fromRecurringRule: rule,
                        id: makeInvoiceID(),
                        occurrence: occurrence,
                        number: resolveNumber(numbers),
                        due: addDays(rule.nextDueDate, days: rule.dueDays, calendar: calendar),
                        email: contact?.email ?? "",
                        phone: contact?.phone ?? "")
                    if rule.autoSendEnabled == true, autoSendMasterEnabled,
                       isPlausibleEmail(contact?.email) {
                        // Stamp candidate: the newest per rule wins below; a
                        // backlog run stamps at most its current occurrence.
                        generated.autoEmailRequestedAt = stampedAt
                        ruleInvoices.append((index: newInvoices.count, occurrence: occurrence))
                    } else {
                        ruleInvoices.append((index: newInvoices.count, occurrence: -1))
                    }
                    numbers.append(generated.number)
                    newInvoices.append(generated)
                    seen.insert(key)
                }
                rule.occurrenceCount += 1
                rule.lastGeneratedDate = rule.nextDueDate
                guard let cadence = RecurrenceCadence(rawValue: rule.cadence) else { break }
                let advanced = RecurrenceRules.nextDate(
                    after: rule.nextDueDate, cadence: cadence, calendar: calendar)
                // A non-advancing step would spin forever; stop the rule's
                // loop rather than hang the sync pass.
                guard advanced > rule.nextDueDate else { break }
                rule.nextDueDate = advanced
                ruleChanged = true

                if isEndConditionMet(rule) {
                    rule.isActive = false
                    break
                }
            }
            // Newest created occurrence for this rule keeps its stamp; every
            // other stamp from this run is withdrawn so a catch-up batch can
            // never auto-email more than its current occurrence.
            let stamped = ruleInvoices.filter { $0.occurrence >= 0 }
            if let newest = stamped.max(by: { $0.occurrence < $1.occurrence }) {
                for entry in stamped where entry.index != newest.index {
                    newInvoices[entry.index].autoEmailRequestedAt = nil
                }
                autoSendIDs.append(newInvoices[newest.index].id)
            }
            if ruleChanged {
                updatedRules.append(rule)
            }
        }
        return NativeRecurringInvoiceGeneration(
            newInvoices: newInvoices,
            updatedRules: updatedRules,
            autoSendInvoiceIDs: autoSendIDs,
            didChange: !newInvoices.isEmpty || !updatedRules.isEmpty)
    }

    /// Conservative single-recipient shape (`isPlausibleEmail` parity): one
    /// local part, one @, one dot-bearing domain, none of the characters that
    /// split a recipient list or smuggle a header. Invalid → skip, never throw.
    static func isPlausibleEmail(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value.count <= 254 else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;<>\""))
        guard value.rangeOfCharacter(from: forbidden) == nil else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        return parts[1].contains(".") && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// Occurrence date + net terms in the local frame (not UTC, which loses a
    /// calendar day east of Greenwich for the same parse-vs-format skew).
    static func addDays(_ from: String, days: Int, calendar: Calendar = .current) -> String {
        let parts = from.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let start = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              let result = calendar.date(byAdding: .day, value: days, to: start)
        else { return from }
        let out = calendar.dateComponents([.year, .month, .day], from: result)
        return String(format: "%04d-%02d-%02d", out.year ?? 0, out.month ?? 0, out.day ?? 0)
    }

    private static func dedupeKey(ruleID: String, occurrence: Int) -> String {
        "\(ruleID)\u{1F}\(occurrence)"
    }

    private static func isEndConditionMet(_ rule: Canonical.RecurringInvoice) -> Bool {
        RecurrenceRules.isEndConditionMet(RecurrenceState(
            endCondition: RecurrenceEndCondition(rawValue: rule.endCondition) ?? .never,
            endCount: rule.endCount,
            endDate: rule.endDate,
            occurrenceCount: rule.occurrenceCount,
            nextDueDate: rule.nextDueDate))
    }
}

extension Canonical.Invoice {
    /// Builds one generated occurrence. Contact/address linkage comes only
    /// from the rule + contact snapshot; payment, delivery and import state
    /// are never inherited.
    /// from the rule + contact snapshot; payment, delivery and import state
    /// are never inherited.
    init(
        fromRecurringRule rule: Canonical.RecurringInvoice,
        id: String,
        occurrence: Int,
        number: String,
        due: String,
        email: String,
        phone: String
    ) {
        self.id = id
        self.customer = rule.customerName
        self.customerId = rule.customerId
        self.number = number
        self.amount = rule.amount
        self.due = due
        self.email = email
        self.phone = phone
        self.desc = rule.description
        self.paid = false
        self.paidAt = nil
        self.payments = nil
        self.depositRequest = nil
        self.paymentLinkUrl = nil
        self.paymentLinkAmount = nil
        self.autoEmailRequestedAt = nil
        self.lineItems = nil
        self.jobId = nil
        self.recurringInvoiceId = rule.id
        self.occurrenceNumber = occurrence
        self.importBatchId = nil
        self.preservation = Canonical.Preservation()
    }
}

extension Canonical.RecurringInvoice {
    /// Manual construction for rule create/edit sheets. `Canonical` models
    /// are otherwise decoder-built; every stored property is assigned here so
    /// unknown-field preservation stays intact through encode.
    init(
        id: String,
        customerId: String,
        customerName: String,
        description: String,
        amount: Decimal,
        dueDays: Int,
        cadence: Canonical.RecurrenceCadence,
        endCondition: Canonical.RecurrenceEndCondition,
        endCount: Int?,
        endDate: Canonical.DateString?,
        occurrenceCount: Int,
        lastGeneratedDate: Canonical.DateString?,
        nextDueDate: Canonical.DateString,
        isActive: Bool,
        createdAt: Canonical.DateString,
        autoSendEnabled: Bool?,
        preservation: Canonical.Preservation = Canonical.Preservation()
    ) {
        self.id = id
        self.customerId = customerId
        self.customerName = customerName
        self.description = description
        self.amount = amount
        self.dueDays = dueDays
        self.cadence = cadence
        self.endCondition = endCondition
        self.endCount = endCount
        self.endDate = endDate
        self.occurrenceCount = occurrenceCount
        self.lastGeneratedDate = lastGeneratedDate
        self.nextDueDate = nextDueDate
        self.isActive = isActive
        self.createdAt = createdAt
        self.autoSendEnabled = autoSendEnabled
        self.preservation = preservation
    }
}

/// Final review I1: the maintenance-plan screen's hand-off from the plan
/// actions dialog to a destructive confirmation ("Cancel plan", "Delete
/// plan"). SwiftUI clears the dialog's plan through its `isPresented` setter
/// as the dialog dismisses, right after a destructive button runs, so the
/// destructive target is held separately: it survives that dismissal and is
/// what the confirmation alert acts on. Foundation-only (no view policy).
struct NativeRecurringPlanActionState<Rule> {
    enum DestructiveKind: Equatable {
        case cancelPlan
        case deletePlan
    }

    struct PendingDestructive {
        let rule: Rule
        let kind: DestructiveKind
    }

    /// The plan whose actions dialog is open.
    private(set) var actionRule: Rule?
    /// The plan a destructive action awaits confirmation for.
    private(set) var pendingDestructive: PendingDestructive?

    var isDialogPresented: Bool { actionRule != nil }
    var isPresentingAnything: Bool { actionRule != nil || pendingDestructive != nil }

    func isConfirming(_ kind: DestructiveKind) -> Bool { pendingDestructive?.kind == kind }

    mutating func showActions(for rule: Rule) { actionRule = rule }

    /// The dialog's `isPresented` setter and its non-destructive buttons.
    mutating func dismissActions() { actionRule = nil }

    /// A destructive dialog button: moves the tapped plan to the
    /// confirmation. Phase 12.00b.2-E (L286.2): `rule` must come from the
    /// `confirmationDialog` closure's own `presenting:` value at the call
    /// site, not from re-reading `actionRule` here — the same coupling that
    /// caused the fixed I1 no-op bug. SwiftUI can clear or reassign
    /// `actionRule` (via `dismissActions()`/`showActions(for:)`) between the
    /// dialog opening and this handler running; the destructive request
    /// still targets exactly the plan the dialog was showing when tapped.
    mutating func requestDestructive(_ kind: DestructiveKind, for rule: Rule) {
        pendingDestructive = PendingDestructive(rule: rule, kind: kind)
        actionRule = nil
    }

    /// The alert's `isPresented` setter, its confirm and its "Keep plan".
    mutating func endConfirmation() { pendingDestructive = nil }
}
