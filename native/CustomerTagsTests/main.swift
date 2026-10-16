import Foundation

// Phase 33 (customer tags and the marketing opt-out) host tests:
// `N/Domain/NativeCustomerTags.swift` (normalization, the stored list, the
// vocabulary, merge, the sticky opt-out, the Customers list filter) and the
// CSV import mapping + engine for the `tags` and `marketingOptOut` columns.
// Spec: docs/superpowers/specs/2026-10-03-campaigns-tags-design.md §3, §4, §12.

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func customer(
    _ id: String,
    _ name: String,
    phone: String = "",
    email: String = "",
    tags: [String]? = nil,
    optOutOn: String? = nil,
    optOutVia: String? = nil
) -> Canonical.Customer {
    var fields: [String: Canonical.JSONValue] = [
        "id": .string(id), "name": .string(name), "email": .string(email),
        "phone": .string(phone), "address": .string(""), "notes": .string(""),
    ]
    if let tags { fields["tags"] = .array(tags.map { .string($0) }) }
    if let optOutOn { fields["marketingOptOutOn"] = .string(optOutOn) }
    if let optOutVia { fields["marketingOptOutVia"] = .string(optOutVia) }
    return NativeImportEngine.decode(Canonical.Customer.self, fields)!
}

// MARK: - Normalization (spec §3.1)

func testNormalize() {
    typealias T = NativeCustomerTags
    expectEqual(T.normalize(nil), nil, "normalize: nil")
    expectEqual(T.normalize(""), nil, "normalize: empty is nil")
    expectEqual(T.normalize("   \n\t "), nil, "normalize: whitespace is nil")
    expectEqual(T.normalize("#"), nil, "normalize: a lone # is nil")
    expectEqual(T.normalize("#VIP"), "VIP", "normalize: a leading # is dropped")
    expectEqual(T.normalize("  ## gate code "), "gate code", "normalize: repeated leading # and spaces")
    expectEqual(T.normalize("AC, heat pump"), "AC heat pump", "normalize: a comma becomes a space")
    expectEqual(T.normalize("AC;heat"), "AC heat", "normalize: a semicolon becomes a space")
    expectEqual(T.normalize("AC|heat"), "AC heat", "normalize: a pipe (the third import separator) becomes a space")
    expectEqual(T.normalize("|#a || b|"), "a b", "normalize: leading, doubled and trailing separators collapse")
    expectEqual(T.normalize("|;,"), nil, "normalize: separators only is nil")
    expectEqual(T.normalize("Spring\u{0007} AC"), "Spring AC", "normalize: control characters are stripped")
    expectEqual(T.normalize("Line\none"), "Line one", "normalize: a newline separates words")
    expectEqual(T.normalize("Gate    code"), "Gate code", "normalize: whitespace collapses")
    expectEqual(T.normalize(String(repeating: "x", count: 30)), String(repeating: "x", count: 24),
                "normalize: cut to 24 characters")
    expectEqual(T.normalize(String(repeating: "a", count: 23) + " b"), String(repeating: "a", count: 23),
                "normalize: a cut that ends in a space is trimmed")
    let family = "👨‍👩‍👧‍👦"
    let emoji = String(repeating: "a", count: 23) + family + "b"
    expectEqual(T.normalize(emoji), String(repeating: "a", count: 23) + family,
                "normalize: the 24-character cut keeps a whole grapheme (ZWJ family)")
    expectEqual(T.normalize(emoji)?.count, 24, "normalize: the grapheme counts as one character")

    expectEqual(T.key("Spring AC"), "spring ac", "key: case-folded")
    expectEqual(T.key("spring ac"), T.key("Spríng AC"), "key: diacritics fold")
    expectEqual(T.key("  #Spring   AC "), "spring ac", "key: normalized first")
    expectEqual(T.key("   "), "", "key: empty for nothing")
}

func testNormalizeList() {
    typealias T = NativeCustomerTags
    expectEqual(T.normalizeList(nil), nil, "list: nil stays nil")
    expectEqual(T.normalizeList([]), nil, "list: empty is nil (key absent)")
    expectEqual(T.normalizeList(["", " #", "\u{0001}"]), nil, "list: all-blank is nil")
    expectEqual(T.normalizeList(["VIP", "vip", "Ví́p"]), ["VIP"], "list: de-duplicated by key, first spelling wins")
    expectEqual(T.normalizeList(["Zeta", "alpha", "Mid"]), ["alpha", "Mid", "Zeta"], "list: sorted by key")
    let twelve = (1...12).map { "tag\(String(format: "%02d", $0))" }
    expectEqual(T.normalizeList(twelve), Array(twelve.prefix(10)), "list: the first 10 are kept")
    let reversed = Array(twelve.reversed())
    expectEqual(T.normalizeList(reversed), Array(reversed.prefix(10)).sorted(), "list: the first 10 in input order, then sorted")
    expectEqual(T.split("AC, VIP; gate|Spring"), ["AC", "VIP", "gate", "Spring"], "split: , ; and |")
    expectEqual(T.caption(["AC", "Gate code", "VIP", "Zone 2", "Pool"]), "AC · Gate code · Pool +2", "caption: three then +N")
    expectEqual(T.caption(nil), nil, "caption: none")
}

func testVocabulary() {
    typealias T = NativeCustomerTags
    let customers = [
        customer("a", "A", tags: ["VIP", "AC"]),
        customer("b", "B", tags: ["vip", "AC"]),
        customer("c", "C", tags: ["vip"]),
        customer("d", "D", tags: ["Gate code"]),
        customer("e", "E", tags: ["Pool"]),
    ]
    let vocabulary = T.vocabulary(customers)
    expectEqual(vocabulary.map(\.key), ["vip", "ac", "gate code", "pool"], "vocabulary: count desc, then display")
    expectEqual(vocabulary.first?.display, "vip", "vocabulary: the spelling on the most customers wins")
    expectEqual(vocabulary.first?.count, 3, "vocabulary: counts customers")
    let tied = T.vocabulary([customer("a", "A", tags: ["Spring"]), customer("b", "B", tags: ["spring"])])
    expectEqual(tied.first?.display, "Spring", "vocabulary: a spelling tie breaks alphabetically")
    expectEqual(T.snapped("VIP", vocabulary: vocabulary), "vip", "snap: a typed tag takes the existing spelling")
    expectEqual(T.snapped("New one", vocabulary: vocabulary), "New one", "snap: a new tag keeps its spelling")
    expectEqual(T.suggestions(prefix: "g", vocabulary: vocabulary, excluding: []).map(\.key), ["gate code"],
                "suggestions: prefix by key")
    expectEqual(T.suggestions(prefix: "", vocabulary: vocabulary, excluding: ["VIP"]).map(\.key), ["ac", "gate code", "pool"],
                "suggestions: tags already on the customer are left out")
    let many = (1...12).map { customer("m\($0)", "M", tags: ["t\(String(format: "%02d", $0))"]) }
    expectEqual(T.suggestions(prefix: "", vocabulary: T.vocabulary(many), excluding: []).count, 8, "suggestions: top 8")
}

func testMerged() {
    typealias T = NativeCustomerTags
    expectEqual(T.merged(winner: nil, loser: nil), nil, "merged: none stays absent")
    expectEqual(T.merged(winner: ["VIP"], loser: ["vip", "AC"]), ["AC", "VIP"], "merged: union by key, winner spelling")
    let winner = (1...8).map { "w\($0)" }
    let loser = ["z", "b", "a", "c"]
    let merged = T.merged(winner: winner, loser: loser) ?? []
    expectEqual(merged.count, 10, "merged: capped at 10")
    expect(merged.contains("a") && merged.contains("b") && !merged.contains("c") && !merged.contains("z"),
           "merged: the loser's tags join in key order until 10")
    expect(Set(winner).isSubset(of: Set(merged)), "merged: every winner tag is kept")
}

func testOptOut() {
    typealias O = NativeMarketingOptOut
    let sam = customer("s", "Sam")
    expect(!sam.isMarketingOptedOut, "O1: no date is not opted out")
    expect(!customer("s", "Sam", optOutOn: "  ").isMarketingOptedOut, "O1: a blank date is not opted out")
    let out = O.optedOut(sam, on: "2026-03-04", via: .textStop)
    expect(out.isMarketingOptedOut && out.marketingOptOutVia == "text_stop", "opt-out: sets the date and reason")
    expectEqual(O.optedOut(out, on: "2026-05-01", via: .asked).marketingOptOutOn, "2026-03-04", "opt-out: the first date is kept")
    let cleared = O.cleared(out)
    expect(!cleared.isMarketingOptedOut && cleared.marketingOptOutVia == nil, "opt-out: clearing removes both fields")
    expectEqual(O.Via.pickable.map(\.rawValue), ["asked", "text_stop", "email_reply"], "opt-out: the reason picker")

    // Sticky merge (spec §4.4): either record, the earlier date and its via.
    let a = O.merged(winner: (nil, nil), loser: ("2026-02-01", "asked"))
    expect(a.on == "2026-02-01" && a.via == "asked", "merge: the loser's opt-out carries over")
    let b = O.merged(winner: ("2026-03-01", "text_stop"), loser: (nil, nil))
    expect(b.on == "2026-03-01" && b.via == "text_stop", "merge: the winner's opt-out stays")
    let c = O.merged(winner: ("2026-03-01", "text_stop"), loser: ("2026-01-15", "email_reply"))
    expect(c.on == "2026-01-15" && c.via == "email_reply", "merge: the earlier date wins with its reason")
    let d = O.merged(winner: ("2026-01-15", "asked"), loser: ("2026-03-01", "text_stop"))
    expect(d.on == "2026-01-15" && d.via == "asked", "merge: the winner's earlier date wins")
    let e = O.merged(winner: ("2026-01-15", "asked"), loser: ("2026-01-15", "text_stop"))
    expect(e.on == "2026-01-15" && e.via == "asked", "merge: equal dates keep the winner's")
    let f = O.merged(winner: (nil, nil), loser: (nil, nil))
    expect(f.on == nil && f.via == nil, "merge: neither stays clear")
    expect(O.detail(customer("s", "Sam", optOutOn: "2026-03-04", optOutVia: "text_stop"))?.contains("Replied STOP") == true,
           "opt-out detail line names the reason")
}

// MARK: - The Customers list filter (spec §3.3)

struct Entry: NativeCustomerListFilterable, Equatable {
    let id: String
    let phone: String
    let email: String
}

func testListFilter() {
    let customers = [
        customer("a", "Ana", phone: "555-111-2222", tags: ["AC", "VIP"]),
        customer("b", "Ben", email: "ben@x.com", tags: ["Pool"]),
        customer("c", "Cy", optOutOn: "2026-01-01", optOutVia: "asked"),
        customer("d", "Di", tags: ["vip"]),
    ]
    let entries = [
        Entry(id: "a", phone: "555-111-2222", email: ""),
        Entry(id: "b", phone: "", email: "ben@x.com"),
        Entry(id: "c", phone: "", email: ""),
        Entry(id: "d", phone: "", email: ""),
        // Invoice-derived (no stored customer), same tag text in its id.
        Entry(id: "vip", phone: "", email: ""),
    ]
    func ids(_ filter: NativeCustomerListFilter) -> [String] {
        NativeCustomerListFilter.apply(entries, customers: customers, filter: filter).map(\.id)
    }
    expectEqual(ids(.init()), ["a", "b", "c", "d", "vip"], "filter: inactive returns everything")
    expectEqual(ids(.init(tagKeys: ["vip"])), ["a", "d"], "filter: a tag matches case-insensitively")
    expectEqual(ids(.init(tagKeys: ["vip", "pool"])), ["a", "b", "d"], "filter: tags match any of")
    expectEqual(ids(.init(optedOut: true)), ["c"], "filter: Do not contact")
    expectEqual(ids(.init(noContact: true)), ["c", "d", "vip"], "filter: No phone or email")
    expectEqual(ids(.init(tagKeys: ["vip"], noContact: true)), ["d"], "filter: kinds combine with AND")
    expect(!ids(.init(tagKeys: ["vip"])).contains("vip") && !ids(.init(optedOut: true)).contains("vip"),
           "filter: an invoice-derived entry never matches a tag or opt-out filter")
    expect(NativeCustomerListFilter(tagKeys: ["x"]).isActive && !NativeCustomerListFilter().isActive, "filter: isActive")
}

// MARK: - CSV import (spec §3.4)

func environment() -> NativeImportEnvironment {
    var customerCounter = 0
    return NativeImportEnvironment(
        nowMs: { 1_772_323_200_000 },
        today: { "2026-03-01" },
        newCustomerID: { customerCounter += 1; return "c\(customerCounter)" },
        newJobID: { "j" },
        newExpenseID: { "e" }
    )
}

func testImportMapping() {
    let headers = ["Name", "Tags", "Customer Tags", "Labels", "Do Not Contact", "Email Opt-Out", "Unsubscribed",
                   "Opted out", "Marketing opt-out", "Receives marketing emails", "Do not market"]
    let mapping = NativeImportMapping.detectMapping(entity: .customers, headers: headers)
    expectEqual(mapping[1], "tags", "mapping: Tags")
    expectEqual(mapping[2], "tags", "mapping: Customer Tags")
    expectEqual(mapping[3], "tags", "mapping: Labels")
    expectEqual(mapping[4], "marketingOptOut", "mapping: Do Not Contact")
    expectEqual(mapping[5], "marketingOptOut", "mapping: Email Opt-Out")
    expectEqual(mapping[6], "marketingOptOut", "mapping: Unsubscribed")
    expectEqual(mapping[7], "marketingOptOut", "mapping: Opted out")
    expectEqual(mapping[8], "marketingOptOut", "mapping: the accountant package's Marketing opt-out header round-trips")
    expect(mapping[9] != "marketingOptOut", "mapping: an opt-IN column is never mapped to the opt-out")
    expectEqual(mapping[10], "marketingOptOut", "mapping: Do not market")
    let keys = NativeImportMapping.fieldDefs[.customers]?.map(\.key) ?? []
    expect(keys.contains("tags") && keys.contains("marketingOptOut"), "mapping: both fields are offered")

    typealias O = NativeMarketingOptOut
    for truthy in ["yes", "Y", "TRUE", "1", "x", "Unsubscribed", "opted  out", " Yes "] {
        expect(O.importValueOptsOut(truthy), "opt-out truthy: \(truthy)")
    }
    for falsy in ["no", "", "0", "false", "maybe", "subscribed"] {
        expect(!O.importValueOptsOut(falsy), "opt-out falsy: \(falsy)")
    }
    expectEqual(O.importOptOutDay("yes", importDay: "2026-03-01"), "2026-03-01", "opt-out day: a truthy value is the import date")
    expectEqual(O.importOptOutDay("2025-11-09", importDay: "2026-03-01"), "2025-11-09", "opt-out day: an exported date round-trips")
    expectEqual(O.importOptOutDay("2025-13-09", importDay: "2026-03-01"), nil, "opt-out day: an impossible month is not a date")
    expectEqual(O.importOptOutDay("no", importDay: "2026-03-01"), nil, "opt-out day: a falsy value sets nothing")
}

func testImportEngine() {
    let existing = [
        customer("c-ana", "Ana Ruiz", tags: ["VIP"]),
        customer("c-ben", "Ben Ode", optOutOn: "2025-06-01", optOutVia: "asked"),
        customer("c-cy", "Cy Park"),
    ]
    let mapping: [String?] = ["name", "tags", "tags", "marketingOptOut"]
    let rows = [
        ["Ana Ruiz", "AC; vip", "Pool", ""],        // matched: tags union, no opt-out
        ["Ben Ode", "", "", "no"],                  // matched: a falsy value never clears an opt-out
        ["Cy Park", "", "", "yes"],                 // matched: opt-out fills (absent before)
        ["Dee New", "Gate code|Spring", "", "1"],   // created: tags and opt-out
        ["Eve New", "", "", ""],                     // created: nothing extra
    ]
    let result = NativeImportEngine.buildCustomerImport(
        rows: rows, mapping: mapping, existing: existing, batchID: "imp_tags", environment: environment()
    )
    let byName = Dictionary(result.records.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    expectEqual(byName["Ana Ruiz"]?.tags, ["AC", "Pool", "VIP"], "import: matched tags union (existing spelling kept)")
    expect(byName["Ana Ruiz"]?.isMarketingOptedOut == false, "import: no opt-out on a blank cell")
    expectEqual(byName["Ben Ode"]?.marketingOptOutOn, "2025-06-01", "import: never clears an opt-out")
    expectEqual(byName["Ben Ode"]?.marketingOptOutVia, "asked", "import: keeps the existing reason")
    expectEqual(byName["Cy Park"]?.marketingOptOutOn, "2026-03-01", "import: fills an absent opt-out with the import date")
    expectEqual(byName["Cy Park"]?.marketingOptOutVia, "imported", "import: the reason is imported")
    expectEqual(byName["Dee New"]?.tags, ["Gate code", "Spring"], "import: created tags split on | and sorted")
    expectEqual(byName["Dee New"]?.marketingOptOutOn, "2026-03-01", "import: a created customer opts out")
    expectEqual(byName["Eve New"]?.tags, nil, "import: no tags key when none")
    expectEqual(byName["Eve New"]?.marketingOptOutOn, nil, "import: no opt-out key when none")
    expectEqual(result.counts.matched, 3, "import: three matched")
    expectEqual(result.counts.created, 2, "import: two created")

    // A second import with the same opt-out date leaves a match unchanged.
    let again = NativeImportEngine.upsertCustomer(
        result.records, name: "Cy Park", marketingOptOutOn: "2026-04-01", createdAt: "2026-04-01", newID: { "x" }
    )
    expect(!again.changed && again.customer?.marketingOptOutOn == "2026-03-01", "import: an existing opt-out is never moved")
    let sameTags = NativeImportEngine.upsertCustomer(
        result.records, name: "Ana Ruiz", tags: ["vip"], createdAt: "2026-04-01", newID: { "x" }
    )
    expect(!sameTags.changed, "import: tags already on the customer are no change")
}

func testAccountingColumns() {
    expectEqual(Array(NativeAccountingPackage.customersHeader.suffix(2)), ["Tags", "Marketing opt-out"],
                "export: the two trailing columns")
    let csv = NativeAccountingPackage.buildCustomersCsv([
        customer("a", "Ana", tags: ["AC", "VIP"], optOutOn: "2026-02-03", optOutVia: "asked"),
        customer("b", "Ben"),
    ])
    let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    expect(lines.count == 3, "export: header and two rows")
    expect(lines.dropFirst().contains { $0.hasSuffix(",AC; VIP,2026-02-03") }, "export: tags joined with \"; \" and the opt-out date")
    expect(lines.dropFirst().contains { $0.hasSuffix(",,") }, "export: blank columns when none")

    // Round trip: the exported headers import back onto the same fields.
    let mapping = NativeImportMapping.detectMapping(entity: .customers, headers: NativeAccountingPackage.customersHeader)
    expectEqual(Array(mapping.suffix(2)), ["tags", "marketingOptOut"], "export: the headers are import synonyms")
}

// MARK: - Separators round-trip through export and import

func testSeparatorRoundTrip() {
    let stored = NativeCustomerTags.normalizeList(["a|b", "x;y", "p,q", "plain"])
    expectEqual(stored, ["a b", "p q", "plain", "x y"], "round trip: |, ; and , become spaces in the stored form")
    for label in stored ?? [] {
        expectEqual(NativeCustomerTags.split(label), [label], "round trip: \"\(label)\" survives import's split intact")
    }
    let csv = NativeAccountingPackage.buildCustomersCsv([customer("a", "Ana", tags: stored)])
    let line = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }[1]
    let cells = line.components(separatedBy: ",")
    expectEqual(cells[cells.count - 2], "a b; p q; plain; x y", "round trip: export joins the stored tags with \"; \" unquoted")
    let imported = NativeImportEngine.buildCustomerImport(
        rows: [["Ana", cells[cells.count - 2]]], mapping: ["name", "tags"], existing: [], batchID: "imp_rt",
        environment: environment()
    )
    expectEqual(imported.records.first?.tags, stored, "round trip: importing the exported cell gives back the same tags")
    // A matched import of the exported cell is no change.
    let again = NativeImportEngine.upsertCustomer(
        imported.records, name: "Ana", tags: NativeCustomerTags.split(cells[cells.count - 2]),
        createdAt: "2026-04-01", newID: { "x" }
    )
    expect(!again.changed, "round trip: re-importing the export changes nothing")
    // A raw cell with all three separators splits into the same labels.
    expectEqual(NativeCustomerTags.split("a b|x y;p q,plain"), ["a b", "x y", "p q", "plain"],
                "round trip: a mixed-separator cell")
}

testNormalize()
testNormalizeList()
testVocabulary()
testMerged()
testOptOut()
testListFilter()
testImportMapping()
testImportEngine()
testAccountingColumns()
testSeparatorRoundTrip()

if failures == 0 {
    print("PASS: customer tags tests (\(checks) checks)")
} else {
    print("customer tags tests: \(failures) of \(checks) checks FAILED")
    exit(1)
}
