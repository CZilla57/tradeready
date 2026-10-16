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

    // Phase 27: the editor's "Other…" text is normalized on save.
    func savedSource(_ raw: String?) -> String? {
        var draft = customer(id: "new", name: "Lead Source Draft")
        draft.leadSource = raw
        return NativeCustomerIdentity.editorSavePlan(for: draft, existingCustomers: existing, mode: .create)
            .customer.leadSource
    }
    expect(savedSource("  google ads ") == "google", "a typed preset alias saves as its preset key")
    expect(savedSource("nextdoor") == "nextdoor", "a picked preset key saves unchanged")
    expect(savedSource(" Home   Show ") == "Home Show", "a custom label saves trimmed and collapsed")
    expect(savedSource("   ") == nil && savedSource(nil) == nil, "a blank source saves as Not set")

    // Phase 34 (R1): the editor keeps a referrer only for a Referral source
    // that is not the customer itself.
    func savedReferrer(source: String?, referrer: String?, id: String = "new") -> String? {
        var draft = customer(id: id, name: "Referred Draft")
        draft.leadSource = source
        draft.referredByCustomerId = referrer
        return NativeCustomerIdentity.editorSavePlan(for: draft, existingCustomers: existing, mode: .create)
            .customer.referredByCustomerId
    }
    expect(savedReferrer(source: "referral", referrer: "c-sam") == "c-sam", "a Referral source keeps its referrer")
    expect(savedReferrer(source: "Word of mouth", referrer: "c-sam") == "c-sam", "a referral alias keeps its referrer")
    expect(savedReferrer(source: "google", referrer: "c-sam") == nil, "another source clears the referrer")
    expect(savedReferrer(source: nil, referrer: "c-sam") == nil, "no source clears the referrer")
    expect(savedReferrer(source: "referral", referrer: "new", id: "new") == nil, "a customer cannot refer themself")
    expect(savedReferrer(source: "referral", referrer: "  ") == nil, "a blank referrer saves as none")
    // Phase 33: the editor saves tags in their stored form; a blank opt-out
    // date is no opt-out and drops its reason.
    var tagDraft = customer(id: "new-tags", name: "Tag Draft")
    tagDraft.tags = ["#vip", "VIP", " pool ", ""]
    tagDraft.marketingOptOutOn = "  "
    tagDraft.marketingOptOutVia = "asked"
    let tagPlan = NativeCustomerIdentity.editorSavePlan(for: tagDraft, existingCustomers: existing, mode: .create).customer
    expect(tagPlan.tags == ["pool", "vip"], "editor save: tags normalized, de-duplicated and sorted")
    expect(tagPlan.marketingOptOutOn == nil && tagPlan.marketingOptOutVia == nil, "editor save: a blank opt-out date is cleared")
    tagDraft.tags = ["", " "]
    tagDraft.marketingOptOutOn = "2026-03-04"
    let optPlan = NativeCustomerIdentity.editorSavePlan(for: tagDraft, existingCustomers: existing, mode: .create).customer
    expect(optPlan.tags == nil && optPlan.marketingOptOutOn == "2026-03-04" && optPlan.marketingOptOutVia == "asked",
           "editor save: no tags is nil; the opt-out and its reason are kept")
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

    // Phase 27 first touch (spec 2026-10-02-lead-source-design.md §3): the
    // winner keeps its source and fills from the loser only when blank.
    expect(winner.leadSource == "referral" && mergedWinner?.leadSource == "referral",
           "merge keeps the winner's lead source")
    func mergedSource(winner winnerSource: String?, loser loserSource: String?) throws -> String? {
        var sourcedWinner = winner
        sourcedWinner.leadSource = winnerSource
        var sourcedLoser = loser
        sourcedLoser.leadSource = loserSource
        let snapshot = Canonical.Snapshot(payload: .init(customers: [sourcedLoser, sourcedWinner]))
        let result = try NativeCustomerIdentity.merge(snapshot: snapshot, winnerID: winner.id, loserID: loser.id)
        let mergedCustomer = result.snapshot.payload.customers?.first { $0.id == winner.id }
        let upsert = result.mutations.first { $0.table == "customers" && $0.recordId == winner.id && $0.op == .upsert }
        guard case let .object(payload)? = upsert?.payload else { return "missing upsert" }
        let wireSource: String?
        if case let .string(value)? = payload["leadSource"] { wireSource = value } else { wireSource = nil }
        expect(wireSource == mergedCustomer?.leadSource, "the winner upsert carries the merged source")
        return mergedCustomer?.leadSource
    }
    let filledFromLoser = try mergedSource(winner: nil, loser: "nextdoor")
    expect(filledFromLoser == "nextdoor", "a blank winner source fills from the loser")
    let whitespaceWinner = try mergedSource(winner: "  ", loser: "Home Show")
    expect(whitespaceWinner == "Home Show", "a whitespace winner source counts as blank")
    let keptWinner = try mergedSource(winner: "google", loser: "yelp")
    expect(keptWinner == "google", "a winner source is never replaced by the loser's")
    let bothBlank = try mergedSource(winner: nil, loser: nil)
    expect(bothBlank == nil, "two blank sources stay blank")

    // Phase 34 (spec 2026-10-03-referral-program-design.md §5.4): codes carry
    // over as aliases, everyone the loser referred is re-pointed to the
    // winner, a self-reference is dropped and the reward carries.
    func referralMerge(
        winner configureWinner: (inout Canonical.Customer) -> Void,
        loser configureLoser: (inout Canonical.Customer) -> Void,
        others: [Canonical.Customer] = []
    ) throws -> (result: NativeCustomerMergeResult, winner: Canonical.Customer?, snapshot: Canonical.Snapshot) {
        var w = winner
        w.referralCode = nil; w.referralCodeAliases = nil; w.referredByCustomerId = nil; w.referralReward = nil
        var l = loser
        l.referralCode = nil; l.referralCodeAliases = nil; l.referredByCustomerId = nil; l.referralReward = nil
        configureWinner(&w)
        configureLoser(&l)
        let snapshot = Canonical.Snapshot(payload: .init(customers: [l, w] + others))
        let result = try NativeCustomerIdentity.merge(snapshot: snapshot, winnerID: winner.id, loserID: loser.id)
        return (result, result.snapshot.payload.customers?.first { $0.id == winner.id }, snapshot)
    }
    let codes = try referralMerge(
        winner: { $0.referralCode = "wwwwwwwwwwwwwwww" },
        loser: { $0.referralCode = "llllllllllllllll"; $0.referralCodeAliases = ["aaaaaaaaaaaaaaaa", "wwwwwwwwwwwwwwww"] }
    )
    expect(codes.winner?.referralCode == "wwwwwwwwwwwwwwww", "merge: the winner keeps its referral code")
    expect(codes.winner?.referralCodeAliases == ["aaaaaaaaaaaaaaaa", "llllllllllllllll"],
           "merge: the loser's code and aliases become the winner's aliases, deduped and sorted")
    let takenCode = try referralMerge(
        winner: { _ in },
        loser: { $0.referralCode = "llllllllllllllll"; $0.referralCodeAliases = ["aaaaaaaaaaaaaaaa"] }
    )
    expect(takenCode.winner?.referralCode == "llllllllllllllll" && takenCode.winner?.referralCodeAliases == ["aaaaaaaaaaaaaaaa"],
           "merge: a winner with no code takes the loser's")
    let noCodes = try referralMerge(winner: { _ in }, loser: { _ in })
    expect(noCodes.winner?.referralCode == nil && noCodes.winner?.referralCodeAliases == nil, "merge: no codes stay no codes")

    var referredByLoser = winner
    referredByLoser.id = "friend"
    referredByLoser.name = "Friend Of Loser"
    referredByLoser.referredByCustomerId = loser.id
    var referredElsewhere = referredByLoser
    referredElsewhere.id = "stranger"
    referredElsewhere.name = "Stranger"
    referredElsewhere.referredByCustomerId = "someone-else"
    let repoint = try referralMerge(winner: { _ in }, loser: { _ in }, others: [referredByLoser, referredElsewhere])
    let movedFriend = repoint.result.snapshot.payload.customers?.first { $0.id == "friend" }
    expect(movedFriend?.referredByCustomerId == winner.id, "merge: a customer the loser referred now credits the winner")
    expect(repoint.result.snapshot.payload.customers?.first { $0.id == "stranger" }?.referredByCustomerId == "someone-else",
           "merge: other referrals are untouched")
    expect(repoint.result.mutations.contains { $0.table == "customers" && $0.recordId == "friend" && $0.op == .upsert }
           && !repoint.result.mutations.contains { $0.recordId == "stranger" },
           "merge: each re-pointed customer is one upsert")
    let repointUndone = try NativeCustomerIdentity.undo(snapshot: repoint.result.snapshot, token: repoint.result.undo)
    // Customers only: undo writes `[]` for a collection the snapshot never had.
    let repointUndoneBytes = try wireEncoder.encode(repointUndone.snapshot.payload.customers ?? [])
    let repointOriginalBytes = try wireEncoder.encode(repoint.snapshot.payload.customers ?? [])
    expect(repointUndoneBytes == repointOriginalBytes, "merge undo restores re-pointed customers exactly")
    expect(repointUndone.mutations.contains { $0.table == "customers" && $0.recordId == "friend" && $0.op == .upsert },
           "merge undo queues the restored re-pointed customer")
    var friendEdited = repoint.result.snapshot
    if let index = friendEdited.payload.customers?.firstIndex(where: { $0.id == "friend" }) {
        friendEdited.payload.customers?[index].notes = "Edited after the merge"
    }
    do {
        _ = try NativeCustomerIdentity.undo(snapshot: friendEdited, token: repoint.result.undo)
        expect(false, "merge undo conflicts when a re-pointed customer changed")
    } catch NativeCustomerMergeError.undoConflict {}

    let selfReference = try referralMerge(
        winner: { $0.leadSource = "referral"; $0.referredByCustomerId = loser.id }, loser: { _ in }
    )
    expect(selfReference.winner?.referredByCustomerId == nil, "merge: a winner 'referred' by its own duplicate drops it")
    let loserPointsAtWinner = try referralMerge(
        winner: { $0.leadSource = "referral" }, loser: { $0.referredByCustomerId = winner.id }
    )
    expect(loserPointsAtWinner.winner?.referredByCustomerId == nil, "merge: a loser referred by the winner fills nothing")
    let filledReferrer = try referralMerge(
        winner: { $0.leadSource = nil }, loser: { $0.leadSource = "referral"; $0.referredByCustomerId = "c-9" }
    )
    expect(filledReferrer.winner?.leadSource == "referral" && filledReferrer.winner?.referredByCustomerId == "c-9",
           "merge: a blank winner takes the loser's referral and referrer")
    let otherSource = try referralMerge(
        winner: { $0.leadSource = "google" }, loser: { $0.leadSource = "referral"; $0.referredByCustomerId = "c-9" }
    )
    expect(otherSource.winner?.referredByCustomerId == nil, "merge: no referrer is filled when the merged source is not Referral")
    let keptReferrer = try referralMerge(
        winner: { $0.leadSource = "referral"; $0.referredByCustomerId = "c-1" },
        loser: { $0.leadSource = "referral"; $0.referredByCustomerId = "c-9" }
    )
    expect(keptReferrer.winner?.referredByCustomerId == "c-1", "merge: the winner's referrer is kept (first touch)")

    let rewardJSON = try JSONSerialization.data(withJSONObject: ["kind": "gift_card", "amount": 20, "recordedOn": "2026-09-01"])
    let loserReward = try JSONDecoder().decode(Canonical.Customer.ReferralReward.self, from: rewardJSON)
    let rewardCarry = try referralMerge(
        winner: { $0.leadSource = "referral"; $0.referredByCustomerId = "c-1" },
        loser: { $0.referralReward = loserReward }
    )
    expect(rewardCarry.winner?.referralReward?.kind == "gift_card", "merge: a winner with a referrer takes the loser's reward")
    let rewardDropped = try referralMerge(winner: { $0.leadSource = "google" }, loser: { $0.referralReward = loserReward })
    expect(rewardDropped.winner?.referralReward == nil, "merge: a winner without a referrer does not take a reward")

    // Phase 21 (spec 2026-10-02-properties-equipment-design.md §3): the rich
    // winner and loser are copies of one fixture customer, so they share
    // property and equipment ids. The winner keeps its properties; the
    // loser's (at the backfilled, same address) merge in with fresh ids.
    expect((try? NativePropertiesEquipment.validate(mergedWinner?.properties)) != nil,
           "merged properties keep one primary and unique ids (P1, P2)")
    expect(mergedWinner?.properties?.prefix(2).map(\.id) == winner.properties?.map(\.id),
           "the winner keeps its own properties first")
    expect(mergedWinner?.properties?.first?.equipment?.count == 4,
           "the loser's primary equipment joins the winner's primary at the same address")
    expect(merged.snapshot.payload.jobs?.first { $0.id == linkedJob.id }?.propertyId == linkedJob.propertyId,
           "a re-pointed job keeps its property link")
    let mergeUpsert = merged.mutations.first { $0.table == "customers" && $0.op == .upsert }
    if case let .object(payload)? = mergeUpsert?.payload, case let .array(list)? = payload["properties"] {
        expect(list.count == mergedWinner?.properties?.count, "the winner upsert carries the merged properties")
    } else {
        expect(false, "the winner upsert carries the merged properties")
    }

    // A different-address loser: its primary becomes a property and its
    // legacy jobs there link to it; undo restores everything exactly.
    var farLoser = loser
    farLoser.properties = nil
    farLoser.address = "9 Far Rd"
    var farWinner = winner
    farWinner.address = "1 Main St"
    var farJob = orphanJob
    farJob.propertyId = nil
    farJob.address = "9 far rd."
    let farOriginal = Canonical.Snapshot(payload: .init(
        invoices: [], jobs: [farJob], customers: [farWinner, farLoser], recurringJobs: [], recurringInvoices: []
    ))
    var nextID = 0
    let far = try NativeCustomerIdentity.merge(
        snapshot: farOriginal, winnerID: winner.id, loserID: loser.id,
        makePropertyID: { nextID += 1; return "pr_far\(nextID)" }
    )
    let farMerged = far.snapshot.payload.customers?.first
    expect(farMerged?.properties?.last?.address == "9 Far Rd" && farMerged?.properties?.last?.primary == nil,
           "a different-address loser becomes a property at its address")
    expect(far.snapshot.payload.jobs?.first?.propertyId == farMerged?.properties?.last?.id,
           "the loser's unlinked job at that address links to it")
    let farUndone = try NativeCustomerIdentity.undo(snapshot: far.snapshot, token: far.undo)
    let farUndoneBytes = try wireEncoder.encode(farUndone.snapshot)
    let farOriginalBytes = try wireEncoder.encode(farOriginal)
    expect(farUndoneBytes == farOriginalBytes, "undo restores both customers and the job exactly")
    // Phase 33 (campaigns spec §4.4): tags union (the winner's first, cap 10)
    // and a sticky opt-out (either record's, the earlier date and its reason).
    // They are typed fields, so merge copies them; undo restores both records.
    func mergedMarketing(
        winnerTags: [String]?, loserTags: [String]?,
        winnerOptOut: (String?, String?), loserOptOut: (String?, String?)
    ) throws -> (customer: Canonical.Customer?, payload: [String: Canonical.JSONValue], undoExact: Bool) {
        var taggedWinner = winner
        taggedWinner.tags = winnerTags
        taggedWinner.marketingOptOutOn = winnerOptOut.0
        taggedWinner.marketingOptOutVia = winnerOptOut.1
        var taggedLoser = loser
        taggedLoser.tags = loserTags
        taggedLoser.marketingOptOutOn = loserOptOut.0
        taggedLoser.marketingOptOutVia = loserOptOut.1
        let snapshot = Canonical.Snapshot(payload: .init(customers: [taggedLoser, taggedWinner]))
        let result = try NativeCustomerIdentity.merge(snapshot: snapshot, winnerID: winner.id, loserID: loser.id)
        let mergedCustomer = result.snapshot.payload.customers?.first { $0.id == winner.id }
        let upsert = result.mutations.first { $0.table == "customers" && $0.recordId == winner.id && $0.op == .upsert }
        guard case let .object(payload)? = upsert?.payload else { return (nil, [:], false) }
        let undone = try NativeCustomerIdentity.undo(snapshot: result.snapshot, token: result.undo)
        let undoExact = try wireEncoder.encode(undone.snapshot.payload.customers) == wireEncoder.encode(snapshot.payload.customers)
        return (mergedCustomer, payload, undoExact)
    }
    let unioned = try mergedMarketing(winnerTags: ["VIP"], loserTags: ["vip", "Pool", "AC"], winnerOptOut: (nil, nil), loserOptOut: (nil, nil))
    expect(unioned.customer?.tags == ["AC", "Pool", "VIP"], "merge: tags union by key, the winner's spelling kept")
    expect(unioned.payload["tags"] == .array([.string("AC"), .string("Pool"), .string("VIP")]), "merge: the winner upsert carries the tags")
    expect(unioned.customer?.isMarketingOptedOut == false && unioned.payload["marketingOptOutOn"] == nil,
           "merge: no opt-out is invented")
    expect(unioned.undoExact, "merge undo restores both tagged records exactly")
    let capped = try mergedMarketing(winnerTags: (1...9).map { "w\($0)" }, loserTags: ["b", "a"], winnerOptOut: (nil, nil), loserOptOut: (nil, nil))
    expect(capped.customer?.tags?.count == 10 && capped.customer?.tags?.contains("a") == true
           && capped.customer?.tags?.contains("b") == false, "merge: the loser's tags join in key order until 10")
    let sticky = try mergedMarketing(winnerTags: nil, loserTags: nil, winnerOptOut: (nil, nil), loserOptOut: ("2026-02-01", "text_stop"))
    expect(sticky.customer?.marketingOptOutOn == "2026-02-01" && sticky.customer?.marketingOptOutVia == "text_stop"
           && sticky.payload["marketingOptOutOn"] == .string("2026-02-01"), "merge: the loser's opt-out carries over (sticky)")
    expect(sticky.undoExact, "merge undo restores the loser's opt-out record exactly")
    let earlier = try mergedMarketing(winnerTags: nil, loserTags: nil,
                                      winnerOptOut: ("2026-05-01", "asked"), loserOptOut: ("2026-02-01", "email_reply"))
    expect(earlier.customer?.marketingOptOutOn == "2026-02-01" && earlier.customer?.marketingOptOutVia == "email_reply",
           "merge: the earlier opt-out date wins with its reason")
    let kept = try mergedMarketing(winnerTags: nil, loserTags: nil, winnerOptOut: ("2026-01-01", "asked"), loserOptOut: (nil, nil))
    expect(kept.customer?.marketingOptOutOn == "2026-01-01" && kept.customer?.marketingOptOutVia == "asked",
           "merge: never clears the winner's opt-out")
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
