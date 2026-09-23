import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

private func customer(
    id: String,
    name: String,
    email: String = "",
    phone: String = "",
    address: String = "",
    notes: String = "",
    createdAt: Date = Date(timeIntervalSince1970: 0),
    archivedAt: String? = nil
) -> Customer {
    Customer(id: id, name: name, email: email, phone: phone, address: address,
             notes: notes, createdAt: createdAt, archivedAt: archivedAt)
}

private func invoice(
    id: String,
    customerID: String = "",
    name: String,
    amount: Double,
    email: String = "",
    phone: String = "",
    payments: [Payment] = [],
    paid: Bool = false
) -> Invoice {
    Invoice(id: id, customerId: customerID, customer: name, number: "INV", amount: amount,
            due: Date(timeIntervalSince1970: 0), email: email, phone: phone,
            payments: payments, legacyPaid: paid,
            legacyPaidAt: paid ? Date(timeIntervalSince1970: 0) : nil)
}

do {
    let list = NativeCustomerIdentity.buildList(
        invoices: [
            invoice(id: "i1", customerID: "c1", name: "Acme", amount: 100, paid: true),
            invoice(id: "i2", customerID: "c1", name: "Acme", amount: 50)
        ],
        customers: [customer(id: "c1", name: "Acme", notes: "hi")]
    )
    expect(list.count == 1, "id-linked invoices produce one customer")
    expect(list.first?.totalSpent == 100 && list.first?.totalOwed == 50,
           "paid and unpaid invoices roll up separately")
    expect(list.first?.isManual == true && list.first?.notes == "hi",
           "manual customer metadata survives rollup")
    expect(list.first?.invoices.count == 2, "all linked invoices are retained")
}

do {
    let list = NativeCustomerIdentity.buildList(
        invoices: [invoice(id: "i1", name: "  ACME ", amount: 200, paid: true)],
        customers: [customer(id: "c1", name: "Acme")]
    )
    expect(list.first?.id == "c1" && list.first?.totalSpent == 200,
           "missing customer id falls back to normalized name")
}

do {
    let payment = Payment(id: "p1", amount: 400, date: Date(timeIntervalSince1970: 0), method: "cash")
    let list = NativeCustomerIdentity.buildList(
        invoices: [invoice(id: "i1", name: "Bob", amount: 1_000, payments: [payment])],
        customers: []
    )
    expect(list.first?.id == "bob" && list.first?.name == "Bob" && list.first?.isManual == false,
           "invoice-only customer uses the normalized name key")
    expect(list.first?.totalSpent == 400 && list.first?.totalOwed == 600,
           "part payment splits spent and owed totals")
}

do {
    let list = NativeCustomerIdentity.buildList(
        invoices: [
            invoice(id: "i1", customerID: "a", name: "A", amount: 300, paid: true),
            invoice(id: "i2", customerID: "b", name: "B", amount: 500, paid: true)
        ],
        customers: [customer(id: "a", name: "A"), customer(id: "b", name: "B")]
    )
    expect(list.map(\.id) == ["b", "a"], "customer list sorts by lifetime spend")
    let empty = NativeCustomerIdentity.buildList(invoices: [], customers: [customer(id: "c", name: "Empty")])
    expect(empty.count == 1 && empty[0].totalSpent == 0 && empty[0].totalOwed == 0,
           "manual customer with no invoices remains visible")
    expect(NativeCustomerIdentity.buildList(
        invoices: [invoice(id: "blank", name: "", amount: 100)], customers: []
    ).isEmpty, "invoice without customer identity is skipped")
}

do {
    let stored = customer(
        id: "c-detail",
        name: "Detail Customer",
        email: "detail@example.com",
        phone: "555-0199",
        address: "1 Main St",
        notes: "Old note"
    )
    let entry = NativeCustomerIdentity.buildList(invoices: [], customers: [stored])[0]
    let due = Date(timeIntervalSince1970: 1_800_000_000)
    let draft = NativeCustomerDetailActions.invoiceDraft(
        for: entry,
        storedCustomer: stored,
        number: "INV-DETAIL",
        due: due
    )
    expect(
        draft.customerId == stored.id
            && draft.customer == stored.name
            && draft.email == stored.email
            && draft.phone == stored.phone
            && draft.number == "INV-DETAIL"
            && draft.due == due,
        "customer detail invoice action prefills the exact saved identity and contact fields"
    )

    let edited = NativeCustomerDetailActions.customerSavingNotes(
        "Gate code changed",
        for: entry,
        storedCustomer: stored
    )
    expect(
        edited.id == stored.id
            && edited.address == stored.address
            && edited.notes == "Gate code changed",
        "inline notes preserve every other saved customer field"
    )

    let derivedEntry = NativeCustomerIdentity.buildList(
        invoices: [invoice(
            id: "i-derived-detail",
            name: "Derived Customer",
            amount: 75,
            email: "derived@example.com",
            phone: "555-0111"
        )],
        customers: []
    )[0]
    let promoted = NativeCustomerDetailActions.customerSavingNotes(
        "Leave at side gate",
        for: derivedEntry,
        storedCustomer: nil
    )
    expect(
        !promoted.id.isEmpty
            && promoted.name == derivedEntry.name
            && promoted.email == derivedEntry.email
            && promoted.phone == derivedEntry.phone
            && promoted.notes == "Leave at side gate",
        "saving notes promotes an invoice-derived identity into a real customer record"
    )
    expect(derivedEntry.invoices.map(\.id) == ["i-derived-detail"],
           "invoice-derived notes promotion does not mutate historical invoice records")
}

do {
    let customers = [
        customer(id: "c1", name: "Riverside Bakery", email: "owner@example.com"),
        customer(id: "c2", name: "Tom Nguyen", email: "tom@example.com")
    ]
    expect(NativeCustomerIdentity.resolve(
        customers: customers, customerID: "c2", customerName: "Wrong Name"
    )?.email == "tom@example.com", "exact customer id wins")
    expect(NativeCustomerIdentity.resolve(
        customers: customers, customerID: "dangling", customerName: " riverside BAKERY "
    )?.id == "c1", "dangling id falls back to normalized name")
    expect(NativeCustomerIdentity.resolve(
        customers: customers, customerID: nil, customerName: "Nobody"
    ) == nil, "unresolved identity returns nil")
}

do {
    let existing = [
        customer(id: "c1", name: "Mike Smith", email: "mike@example.com", phone: "555-010-1234"),
        customer(id: "archived", name: "Old Account", archivedAt: "2026-08-01")
    ]

    let missingName = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "new", name: "  \n", notes: " keep draft spacing "),
        existingCustomers: existing,
        mode: .create
    )
    expect(missingName.issue == .nameRequired, "customer editor requires a nonblank trimmed name")

    let duplicate = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "new", name: "  MIKE SMITH  ", email: " new@example.com "),
        existingCustomers: existing,
        mode: .create
    )
    expect(duplicate.issue == .duplicateName(existingID: "c1", existingName: "Mike Smith"),
           "new customer blocks an existing trimmed case-insensitive name")

    let archivedDuplicate = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "new", name: "old account"),
        existingCustomers: existing,
        mode: .create
    )
    expect(archivedDuplicate.issue == .duplicateName(existingID: "archived", existingName: "Old Account"),
           "create parity checks every stored customer including archived records")

    let sharedContact = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "new", name: "Another Mike", email: "MIKE@example.com", phone: "(555) 010-1234"),
        existingCustomers: existing,
        mode: .create
    )
    expect(sharedContact.canSave, "phone and email similarities stay advisory during creation")

    let internalSpacing = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "new", name: "Mike  Smith"),
        existingCustomers: existing,
        mode: .create
    )
    expect(internalSpacing.canSave, "create gate does not broaden the React Native name normalization")

    let edited = NativeCustomerIdentity.editorSavePlan(
        for: customer(
            id: "c1",
            name: " Old Account ",
            email: " edited@example.com ",
            phone: " 555-0100 ",
            address: " 1 Main St ",
            notes: " Call first "
        ),
        existingCustomers: existing,
        mode: .editOrPromote
    )
    expect(edited.canSave, "editing an existing record does not invoke the create-only duplicate block")
    expect(
        edited.customer.name == "Old Account"
            && edited.customer.email == "edited@example.com"
            && edited.customer.phone == "555-0100"
            && edited.customer.address == "1 Main St"
            && edited.customer.notes == "Call first",
        "successful customer editor save trims every persisted text field"
    )

    let promoted = NativeCustomerIdentity.editorSavePlan(
        for: customer(id: "invoice-name-key", name: " Old Account "),
        existingCustomers: existing,
        mode: .editOrPromote
    )
    expect(promoted.canSave,
           "invoice-derived edit intent may promote a missing record without the create-only block")
}

do {
    let original = invoice(id: "i1", customerID: "c1", name: "Jane", amount: 100, email: "custom@example.com")
    let result = NativeCustomerIdentity.backfillInvoiceContacts(
        invoices: [original],
        customers: [customer(id: "c1", name: "Jane", email: "jane@example.com", phone: "555-1234")]
    )
    expect(result.changed, "blank invoice contact backfill reports a change")
    expect(result.invoices[0].email == "custom@example.com" && result.invoices[0].phone == "555-1234",
           "invoice contact backfill never clobbers a nonblank value")
    let second = NativeCustomerIdentity.backfillInvoiceContacts(invoices: result.invoices, customers: [
        customer(id: "c1", name: "Jane", email: "jane@example.com", phone: "555-1234")
    ])
    expect(!second.changed, "invoice contact backfill is idempotent")
}

do {
    let duplicates = NativeCustomerIdentity.duplicatePairs(in: [
        customer(id: "a", name: "  Al   Smith "),
        customer(id: "b", name: "al smith"),
        customer(id: "c", name: "Other", phone: "(555) 010-1234"),
        customer(id: "d", name: "Different", phone: "555.010.1234"),
        customer(id: "e", name: "Archived", email: "same@example.com", archivedAt: "2026-08-01"),
        customer(id: "f", name: "Active", email: "SAME@example.com")
    ])
    expect(duplicates.map(\.key) == ["a|b", "c|d"],
           "duplicates match normalized name and phone while excluding archived records")
    expect(duplicates.map(\.reason) == [.name, .phone], "duplicate reason priority matches React Native")
    expect(NativeCustomerIdentity.pairKey("y", "x") == "x|y", "duplicate pair key is order independent")
    expect(NativeCustomerIdentity.filterUndismissed(duplicates, dismissedKeys: ["a|b"]).map(\.key) == ["c|d"],
           "dismissed duplicate suggestions are filtered")
    expect(!NativeCustomerIdentity.isArchived(customer(id: "empty", name: "Empty", archivedAt: "")),
           "empty archive value remains active like the React Native truthiness rule")
    let shortPhone = NativeCustomerIdentity.duplicatePairs(in: [
        customer(id: "g", name: "G", phone: "123"),
        customer(id: "h", name: "H", phone: "123")
    ])
    expect(shortPhone.isEmpty, "short phone fragments never match")
}

do {
    let older = customer(
        id: "older",
        name: "Older",
        email: "same@example.com",
        createdAt: Date(timeIntervalSince1970: 10)
    )
    let newer = customer(
        id: "newer",
        name: "Newer",
        email: "SAME@example.com",
        createdAt: Date(timeIntervalSince1970: 20)
    )
    let pair = NativeCustomerIdentity.duplicatePairs(in: [older, newer])[0]
    let withHistory = NativeCustomerIdentity.buildList(
        invoices: [
            invoice(id: "i1", customerID: older.id, name: older.name, amount: 10),
            invoice(id: "i2", customerID: older.id, name: older.name, amount: 20)
        ],
        customers: [older, newer]
    )
    expect(NativeCustomerIdentity.reviewCandidate(for: pair, entries: withHistory)?.id == newer.id,
           "duplicate review selects the record with less invoice history")
    let tiedHistory = NativeCustomerIdentity.buildList(invoices: [], customers: [older, newer])
    expect(NativeCustomerIdentity.reviewCandidate(for: pair, entries: tiedHistory)?.id == newer.id,
           "duplicate review breaks an invoice-count tie toward the newer record")
}

do {
    let fixtureRoot = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["CANONICAL_FIXTURES_PATH"]!
    )
    let fixtureData = try Data(contentsOf: fixtureRoot.appendingPathComponent("canonical-rich.json"))
    let fixture = try JSONDecoder().decode([String: Canonical.JSONValue].self, from: fixtureData)
    func field<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(fixture[key]!))
    }
    let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    var winner: Canonical.Customer = try field("customer")
    winner.id = "winner"
    winner.name = "Alex Winner"
    winner.email = "winner@example.com"
    winner.phone = ""
    winner.address = ""
    winner.notes = "Gate code 4"
    winner.createdAt = "2026-06-01"
    var loser = winner
    loser.id = "loser"
    loser.name = "Alex Duplicate"
    loser.email = "loser@example.com"
    loser.phone = "555-0100"
    loser.address = "1 Main St"
    loser.notes = "Dog in yard"
    loser.createdAt = "2026-01-01"

    var linkedJob: Canonical.Job = try field("job")
    linkedJob.id = "job-linked"
    linkedJob.customerId = loser.id
    linkedJob.customerName = loser.name
    var orphanJob = linkedJob
    orphanJob.id = "job-orphan"
    orphanJob.customerId = ""
    orphanJob.customerName = "  ALEX DUPLICATE "
    var thirdPartyJob = linkedJob
    thirdPartyJob.id = "job-third"
    thirdPartyJob.customerId = "other"

    var linkedInvoice: Canonical.Invoice = try field("invoice")
    linkedInvoice.id = "invoice-linked"
    linkedInvoice.customerId = loser.id
    linkedInvoice.customer = loser.name
    var recurringJob: Canonical.RecurringJob = try field("recurringJob")
    recurringJob.id = "recurring-job"
    recurringJob.customerId = loser.id
    recurringJob.customerName = loser.name
    var recurringInvoice: Canonical.RecurringInvoice = try field("recurringInvoice")
    recurringInvoice.id = "recurring-invoice"
    recurringInvoice.customerId = loser.id
    recurringInvoice.customerName = loser.name

    let original = Canonical.Snapshot(
        payload: .init(
            invoices: [linkedInvoice],
            jobs: [linkedJob, orphanJob, thirdPartyJob],
            customers: [loser, winner],
            recurringJobs: [recurringJob],
            recurringInvoices: [recurringInvoice],
            unknownFields: ["futureCollection": .string("preserved")]
        ),
        unknownFields: ["futureEnvelope": .bool(true)]
    )
    let merged = try NativeCustomerIdentity.merge(
        snapshot: original,
        winnerID: winner.id,
        loserID: loser.id
    )
    let mergedWinner = merged.snapshot.payload.customers?.first { $0.id == winner.id }
    expect(merged.snapshot.payload.customers?.map(\.id) == [winner.id],
           "customer merge removes only the loser and retains deterministic order")
    expect(mergedWinner?.email == winner.email
           && mergedWinner?.phone == loser.phone
           && mergedWinner?.address == loser.address,
           "merge keeps nonblank winner contacts and backfills blank fields")
    expect(mergedWinner?.notes == "Gate code 4\n\nDog in yard"
           && mergedWinner?.createdAt == "2026-01-01",
           "merge concatenates distinct notes and keeps the earliest lifetime date")
    expect(mergedWinner?.preservation.unknownFields == winner.preservation.unknownFields,
           "merge preserves winner canonical-only and unknown fields")
    expect(merged.snapshot.payload.jobs?.first { $0.id == linkedJob.id }?.customerId == winner.id
           && merged.snapshot.payload.jobs?.first { $0.id == orphanJob.id }?.customerId == winner.id,
           "merge re-points id-linked and orphan-name jobs")
    expect(merged.snapshot.payload.jobs?.first { $0.id == thirdPartyJob.id }?.customerId == "other",
           "merge leaves a third-party id-linked record unchanged despite a matching name")
    expect(merged.snapshot.payload.invoices?.first?.customerId == winner.id
           && merged.snapshot.payload.recurringJobs?.first?.customerId == winner.id
           && merged.snapshot.payload.recurringInvoices?.first?.customerId == winner.id,
           "merge re-points invoices and both recurring collections")
    expect(merged.undo.counts == .init(jobs: 2, invoices: 1, recurringJobs: 1, recurringInvoices: 1),
           "merge reports exact per-collection reference counts")
    expect(merged.mutations.count == 7
           && merged.mutations.contains { $0.table == "customers" && $0.recordId == loser.id && $0.op == .delete },
           "merge emits one complete batch of upserts plus the loser tombstone")
    expect(merged.snapshot.payload.unknownFields["futureCollection"] == .string("preserved")
           && merged.snapshot.unknownFields["futureEnvelope"] == .bool(true),
           "merge retains unknown payload and envelope fields")

    let undone = try NativeCustomerIdentity.undo(snapshot: merged.snapshot, token: merged.undo)
    let undoneBytes = try wireEncoder.encode(undone.snapshot)
    let originalBytes = try wireEncoder.encode(original)
    expect(undoneBytes == originalBytes,
           "conflict-free undo restores the exact pre-merge canonical snapshot")
    expect(undone.mutations.filter { $0.table == "customers" && $0.op == .upsert }.count == 2,
           "undo queues both original customer records for convergence")

    var editedAfterMerge = merged.snapshot
    editedAfterMerge.payload.jobs?[0].title = "Later edit"
    do {
        _ = try NativeCustomerIdentity.undo(snapshot: editedAfterMerge, token: merged.undo)
        expect(false, "undo cannot overwrite a later edit")
    } catch NativeCustomerMergeError.undoConflict {}

    do {
        _ = try NativeCustomerIdentity.merge(snapshot: original, winnerID: winner.id, loserID: winner.id)
        expect(false, "self merge is rejected")
    } catch NativeCustomerMergeError.sameCustomer {}
}

do {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("tradeready-customer-dismissals-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NativeCustomerDuplicateDismissalStore(
        fileURL: root.appendingPathComponent("dismissals.json")
    )
    let binding = String(repeating: "a", count: 64)
    let otherBinding = String(repeating: "b", count: 64)

    let missingState = try store.load(for: binding)
    expect(missingState.isEmpty, "missing dismissal state starts empty")
    try store.save(["c|d", "a|b", "a|b"], for: binding)
    let savedState = try store.load(for: binding)
    expect(savedState == ["a|b", "c|d"],
           "dismissal state persists a deterministic deduplicated list")
    try store.save(["a|b", "c|d", "e|f"], for: binding)
    expect(FileManager.default.fileExists(atPath: store.backupURL.path),
           "a valid prior dismissal file is retained as backup")

    do {
        _ = try store.load(for: otherBinding)
        expect(false, "another account binding cannot read dismissal state")
    } catch NativeCustomerDuplicateDismissalStoreError.accountBindingMismatch {}

    let primaryBytes = try Data(contentsOf: store.fileURL)
    try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)
    do {
        try store.save(["g|h"], for: binding)
        expect(false, "an unreadable primary is never overwritten")
    } catch NativeCustomerDuplicateDismissalStoreError.unreadableStore {}
    let retainedUnreadableBytes = try Data(contentsOf: store.fileURL)
    expect(retainedUnreadableBytes == Data("not-json".utf8),
           "unreadable dismissal source bytes remain preserved")
    expect(primaryBytes != Data("not-json".utf8), "the corruption test replaced a valid primary fixture")

    try store.removeAll()
    expect(!FileManager.default.fileExists(atPath: store.fileURL.path)
            && !FileManager.default.fileExists(atPath: store.backupURL.path),
           "account scrub removes primary and backup dismissal state")
}

if failures == 0 { print("PASS: native customer identity and rollup tests") }
else { print("\(failures) customer identity test(s) failed"); exit(1) }
