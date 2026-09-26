import Foundation

// Tax set-aside settings + card tests (task 9.02).
//
// Ports the summarizeTaxWindow vectors from __tests__/taxEstimate.test.js and
// the settings-sheet rules from TaxSettingsModal.tsx, plus the TaxSetAsideCard
// copy. Engine math is already covered by native/DomainTests; these checks pin
// the settings mapping, optional semantics, and displayed strings. 12.00b.3
// (G2) adds the settings sheet: its JS number parsing, its state and copy, and
// the Money tax card → sheet route (a source scan; the runner passes the root).

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(label)")
    }
}

private func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label) — expected \(expected), got \(String(describing: actual))")
    }
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func settings(_ extra: String = "") -> Canonical.Settings {
    let tail = extra.isEmpty ? "" : ",\(extra)"
    let base = """
    {"businessName":"B","contactName":"","phone":"","email":"","address":"","trade":"Plumbing",
     "laborRate":85,"materialMarkup":20,"overheadPercent":15,"marginPercent":20,"minimumJobFee":75,
     "travelFeePerMile":0,"emergencyMultiplier":1.5,"paymentNotes":"","provider":"stripe","rules":[]\(tail)}
    """
    return try! JSONDecoder().decode(Canonical.Settings.self, from: Data(base.utf8))
}

private func invoice(_ json: String) -> LedgerInvoice {
    try! JSONDecoder().decode(LedgerInvoice.self, from: Data(json.utf8))
}

// MARK: - canonical mapping + optional semantics

private func testCanonicalMapping() {
    let unset = NativeTaxSettingsValues(from: settings())
    expect(unset.taxIncomeRate == nil, "absent rate stays absent (not zero)")
    expect(unset.vehicleDeductionMethod == nil, "absent method stays absent")

    let configured = NativeTaxSettingsValues(from: settings(#""taxIncomeRate":12.5,"vehicleDeductionMethod":"actual""#))
    expectEqual(configured.taxIncomeRate, decimal("12.5"), "rate read from canonical")
    expectEqual(configured.vehicleDeductionMethod, .actual, "method read from canonical")

    let zeroRate = NativeTaxSettingsValues(from: settings(#""taxIncomeRate":0"#))
    expect(NativeTaxSettings.incomeRateSet(zeroRate), "0 counts as set")
    expect(!NativeTaxSettings.incomeRateSet(unset), "absent is not set")

    let engineSettings = configured.taxWindowSettings
    expectEqual(engineSettings.incomeRatePercent, decimal("12.5"), "engine rate")
    expectEqual(engineSettings.vehicleDeductionMethod, .actual, "engine method")
    expectEqual(engineSettings.mileageRate, decimal("0.70"), "engine mileage default")
}

// MARK: - sheet validation + merge semantics

private func testDraftRules() {
    expectEqual(NativeTaxSettings.parseRateInput(""), .success(nil), "blank rate means no change")
    expectEqual(NativeTaxSettings.parseRateInput("   "), .success(nil), "whitespace rate means no change")
    expectEqual(NativeTaxSettings.parseRateInput("0"), .success(0), "zero is valid")
    expectEqual(NativeTaxSettings.parseRateInput("60"), .success(60), "sixty is the upper bound")
    expectEqual(NativeTaxSettings.parseRateInput("12.5"), .success(decimal("12.5")), "decimal rate")
    expectEqual(NativeTaxSettings.parseRateInput("60.5"), .failure(.rateOutOfRange), "above 60 refused")
    expectEqual(NativeTaxSettings.parseRateInput("-1"), .failure(.rateOutOfRange), "negative refused")
    expectEqual(NativeTaxSettings.parseRateInput("abc"), .failure(.rateOutOfRange), "non-numeric refused")

    let noChange = NativeTaxSettings.applying(NativeTaxSettingsDraft(), to: ["businessName": .string("B")])
    expect(!noChange.keys.contains("taxIncomeRate"), "no-change draft does not invent the rate key")
    expect(!noChange.keys.contains("vehicleDeductionMethod"), "no-change draft does not invent the method key")
    expectEqual(noChange["businessName"], .string("B"), "unrelated fields survive")

    let withRate = NativeTaxSettings.applying(NativeTaxSettingsDraft(taxIncomeRate: 18), to: [:])
    expectEqual(withRate["taxIncomeRate"], .number(18), "rate written")
    expect(!withRate.keys.contains("vehicleDeductionMethod"), "method still absent")

    let existing = NativeTaxSettings.applying(
        NativeTaxSettingsDraft(vehicleDeductionMethod: .mileage),
        to: ["taxIncomeRate": .number(9), "trade": .string("Plumbing")]
    )
    expectEqual(existing["vehicleDeductionMethod"], .string("mileage"), "method written")
    expectEqual(existing["taxIncomeRate"], .number(9), "existing rate preserved")

    let fullFields = NativeTaxSettings.canonicalFields(NativeTaxSettingsValues(taxIncomeRate: 0))
    expectEqual(fullFields["taxIncomeRate"], .number(0), "explicit zero is written")
    expect(!fullFields.keys.contains("vehicleDeductionMethod"), "absent method not written in a full write")
}

// MARK: - summarizeTaxWindow + card copy (taxEstimate.test.js)

private func summarize(settings taxSettings: TaxWindowSettings) -> TaxWindowSummary {
    let invoices = [
        invoice(#"{"id":"i1","amount":5000,"due":"2026-07-01","paid":false,"payments":[{"id":"p1","amount":1000,"date":"2026-06-15","method":"cash"},{"id":"p2","amount":500,"date":"2026-02-10","method":"cash"}]}"#),
        invoice(#"{"id":"i2","amount":800,"due":"2026-04-20","paid":true,"paidAt":"2026-04-20"}"#),
    ]
    let expenses = [
        TaxExpense(amount: 300, category: "materials", date: "2026-07-02"),
        TaxExpense(amount: 200, category: "fuel", date: "2026-07-01"),
        TaxExpense(amount: 100, category: "tools", date: "2026-03-01"),
    ]
    let trips = [
        TaxTrip(date: "2026-06-20", miles: 100),
        TaxTrip(date: "2026-01-15", miles: 50),
    ]
    return TaxEstimateEngine.summarize(
        invoices: invoices, expenses: expenses, trips: trips, settings: taxSettings, on: "2026-07-18"
    )
}

private func testTaxWindowAndCopy() {
    let values = NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .mileage)
    let mileage = summarize(settings: values.taxWindowSettings)
    expectEqual(mileage.period.quarter, 3, "July 18 2026 is period 3")
    expectEqual(mileage.current.netProfit, decimal("630"), "Q3 net profit with mileage deduction")
    expectEqual(mileage.yearToDate.netProfit, decimal("1795"), "YTD net profit")
    expect(!mileage.needsVehicleChoice, "mileage chosen")
    expect(mileage.incomeRateSet, "rate set")
    expectEqual(mileage.yearToDateTripCount, 2, "YTD trip count")

    let actual = summarize(settings: NativeTaxSettingsValues(taxIncomeRate: 10, vehicleDeductionMethod: .actual).taxWindowSettings)
    expectEqual(actual.current.netProfit, decimal("500"), "actual method deducts fuel instead")

    let unset = summarize(settings: NativeTaxSettingsValues().taxWindowSettings)
    expectEqual(unset.current.netProfit, decimal("700"), "unset method deducts neither")
    expect(unset.needsVehicleChoice, "unset method flags the choice")
    expect(!unset.incomeRateSet, "unset rate flagged")
    expectEqual(unset.current.incomeTax, 0, "unset rate yields no income tax")

    let card = NativeTaxBreakdown.make(summary: unset, values: NativeTaxSettingsValues())
    expectEqual(card.periodRangeText, "Jun 1 – Aug 31", "period range text")
    expectEqual(card.deadlineText, "Sep 15", "deadline text")
    expectEqual(card.periodSummaryText, "Jun 1 – Aug 31 · set aside by Sep 15", "period summary line")
    expectEqual(card.vehiclePrompt, NativeTaxBreakdownCopy.vehiclePrompt, "vehicle prompt shown")
    expectEqual(card.incomeRatePrompt, NativeTaxBreakdownCopy.incomeRatePrompt, "income-rate prompt shown")
    expect(card.staleRatesNote == nil, "rates are known for 2026")
    expect(card.yearToDateText.hasSuffix(" for the year so far"), "YTD line formats money and labels the year")
    expectEqual(card.disclaimer, "Estimate only — not tax advice. Assumes net profit under $200k.", "disclaimer")
    expectEqual(card.mileageDisclosure, "Mileage from this device's trip log (2 trips this year) — not synced.", "disclosure plural")
    expectEqual(NativeTaxBreakdownCopy.mileageDisclosure(tripCount: 1), "Mileage from this device's trip log (1 trip this year) — not synced.", "disclosure singular")

    let configured = NativeTaxBreakdown.make(summary: mileage, values: values)
    expect(configured.vehiclePrompt == nil, "no vehicle prompt once chosen")
    expect(configured.incomeRatePrompt == nil, "no rate prompt once set")
    expectEqual(configured.currentReserve, mileage.current.reserve, "reserve surfaced")

    // A Q4 date in an unknown tax year: the deadline lands in the next year and
    // the versioned wage-base table has no entry, so the stale-rates note shows.
    let unknown = TaxEstimateEngine.summarize(
        invoices: [], expenses: [], trips: [],
        settings: NativeTaxSettingsValues(taxIncomeRate: 0).taxWindowSettings,
        on: "2030-10-05"
    )
    let unknownCard = NativeTaxBreakdown.make(summary: unknown, values: NativeTaxSettingsValues(taxIncomeRate: 0))
    expectEqual(unknownCard.staleRatesNote, NativeTaxBreakdownCopy.staleRatesNote, "stale rates note for unknown year")
    expectEqual(unknownCard.deadlineText, "Jan 15, 2031", "Q4 deadline carries the year")
    expectEqual(unknownCard.periodRangeText, "Sep 1 – Dec 31", "Q4 period range")

    let voided = TaxEstimateEngine.summarize(
        invoices: [invoice(#"{"id":"i3","amount":1000,"due":"2026-07-01","paid":false,"payments":[{"id":"p9","amount":1000,"date":"2026-06-15","method":"cash","voidedAt":"2026-06-16"}]}"#)],
        expenses: [], trips: [],
        settings: TaxWindowSettings(), on: "2026-07-18"
    )
    expectEqual(voided.current.netProfit, 0, "voided payment excluded")
    expectEqual(voided.current.reserve, 0, "voided payment yields a zero reserve")
}

// MARK: - JS number parity (12.00b.3)
//
// The sheet runs `rate.trim()` then `parseFloat` and checks the JS double
// against 0…60 (TaxSettingsModal.tsx:66-77). Every row below was produced by
// node v26 running that exact expression (task 10 evidence
// `rn-parsefloat-vectors.node.txt`). A money input, so each edge is pinned.

private enum RateOutcome: Equatable {
    case blank
    case alert
    case value(String)
}

private let rateVectors: [(input: String, outcome: RateOutcome)] = [
    ("", .blank), ("   ", .blank), ("\t\u{B}\u{C}\n\r", .blank), ("\u{FEFF}\u{A0}\u{3000}", .blank),
    ("15", .value("15")), ("0", .value("0")), ("60", .value("60")), ("12.5", .value("12.5")),
    // -0 passes `parsed < 0` and JSON.stringify writes it as 0.
    ("-0", .value("0")), ("-1e-400", .value("0")), ("1e-400", .value("0")),
    ("75", .alert), ("abc", .alert), ("60.0001", .alert), ("-0.5", .alert),
    ("Infinity", .alert), ("-Infinity", .alert), ("+Infinity", .alert), ("1e400", .alert),
    // The bound is checked on the rounded double, not the typed text.
    ("60.00000000000000001", .value("60")), ("59.99999999999999999", .value("60")),
    ("6.0000000000000001e1", .value("60")), ("60e0", .value("60")), ("6e1", .value("60")),
    // parseFloat keeps the longest numeric prefix and ignores the rest.
    ("15%", .value("15")), ("12,5", .value("12")), ("1_000", .value("1")), ("0x10", .value("0")),
    ("5e", .value("5")), ("5e+", .value("5")), ("5e-1x", .value("0.5")), ("5..", .value("5")),
    ("5\u{301}", .value("5")),
    ("1e1", .value("10")), (".5", .value("0.5")), ("5.", .value("5")), ("+5", .value("5")),
    ("+.5", .value("0.5")), ("00012.50", .value("12.5")), ("0.1e-5", .value("0.000001")),
    ("1e-7", .value("0.0000001")),
    ("12.345678901234567890", .value("12.345678901234567")),
    (".", .alert), ("-", .alert), ("..5", .alert), ("１５", .alert),
    // String.prototype.trim: BOM, NBSP, ideographic space, LS/PS are trimmed;
    // NEL, ZWSP and U+180E are not, so they block the parse.
    ("\u{FEFF}15", .value("15")), ("\u{A0}15\u{3000}", .value("15")), ("\u{2028} 18 \u{2029}", .value("18")),
    (" 7 ", .value("7")), ("\u{85}15", .alert), ("\u{85}", .alert), ("\u{200B}15", .alert), ("\u{180E}15", .alert),
    // Below Decimal's range (1e-128): RN stores 1e-130 / 5e-324; the native
    // canonical number cannot hold them and stores 0, which yields the same
    // income-tax figure to the cent. Pinned so the fallback stays deliberate.
    ("1e-130", .value("0")), ("5e-324", .value("0")),
]

private func testJSNumberParity() {
    for (input, outcome) in rateVectors {
        let label = "rate input \(input.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))"
        let result = NativeTaxSettings.parseRateInput(input)
        switch outcome {
        case .blank: expectEqual(result, .success(nil), "\(label) is blank")
        case .alert: expectEqual(result, .failure(.rateOutOfRange), "\(label) raises the alert")
        case .value(let text): expectEqual(result, .success(decimal(text)), "\(label) stores \(text)")
        }
    }

    expect(NativeTaxSettings.jsParseFloat("abc").isNaN, "parseFloat with no numeric prefix is NaN")
    expectEqual(NativeTaxSettings.jsParseFloat("-0").sign, .minus, "parseFloat keeps -0")
    expectEqual(NativeTaxSettings.jsParseFloat("Infinityx"), .infinity, "parseFloat reads the Infinity prefix")
    expectEqual(NativeTaxSettings.jsTrim("\u{85} 1 \u{FEFF}"), "\u{85} 1", "trim keeps NEL, drops space and BOM")

    // Number::toString — what `String(settings.taxIncomeRate)` shows (node v26).
    let toString: [(Double, String)] = [
        (18, "18"), (12.5, "12.5"), (0, "0"), (-0.0, "0"), (1e-7, "1e-7"), (0.000001, "0.000001"),
        (1e21, "1e+21"), (1.2345678901234568e20, "123456789012345680000"), (0.1 + 0.2, "0.30000000000000004"),
        (5e-324, "5e-324"), (1.5e-127, "1.5e-127"), (60, "60"), (0.7, "0.7"), (1.25e-7, "1.25e-7"),
        (100, "100"), (1234.5, "1234.5"), (-12.5, "-12.5"), (.nan, "NaN"), (.infinity, "Infinity"),
    ]
    for (value, text) in toString {
        expectEqual(NativeTaxSettings.jsNumberString(value), text, "Number::toString(\(value))")
    }
}

// MARK: - editor model (12.00b.3, TaxSettingsModal.tsx)

private func editor(_ extra: String = "") -> NativeTaxSettingsEditor {
    NativeTaxSettingsEditor(settings: settings(extra))
}

private func testEditorModel() {
    // Re-seed on open (:55-63): String(rate) or '' and the stored method.
    let prefilled = editor(#""taxIncomeRate":18,"vehicleDeductionMethod":"mileage""#)
    expectEqual(prefilled.rateText, "18", "rate seeds as String(18) (TaxSettingsModal.test.js prefill)")
    expectEqual(prefilled.selectedMethod, .mileage, "stored method is selected")
    expect(!prefilled.showsMethodUnsetNote, "no unset note once a method is stored")

    for (json, text) in [
        (#""taxIncomeRate":12.5"#, "12.5"), (#""taxIncomeRate":0"#, "0"), (#""taxIncomeRate":1e-7"#, "1e-7"),
        (#""taxIncomeRate":0.30000000000000004"#, "0.30000000000000004"), (#""taxIncomeRate":60"#, "60"),
        (#""taxIncomeRate":null"#, ""), ("", ""),
    ] {
        expectEqual(editor(json).rateText, text, "rate seed for \(json.isEmpty ? "absent" : json)")
    }

    let blank = editor()
    expect(blank.selectedMethod == nil, "never pre-selects a method")
    expect(blank.showsMethodUnsetNote, "unset note shows with no method (:153-155)")
    expectEqual(blank.mileageRate, decimal("0.70"), "mileage rate falls back to DEFAULT_MILEAGE_RATE")
    expectEqual(NativeTaxSettingsEditor(settings: nil).rateText, "", "no settings record seeds blank")
    expectEqual(NativeTaxSettingsEditor(settings: nil).mileageRate, decimal("0.70"), "no settings record uses 0.70")
    expectEqual(editor(#""mileageRate":0.655"#).mileageRate, decimal("0.655"), "stored mileage rate shown")

    // TaxSettingsModal.test.js: blank save → {}.
    expectEqual(blank.save(), .success(NativeTaxSettingsDraft()), "blank save is the empty draft")

    // TaxSettingsModal.test.js: type 15, choose actual → {15, actual}.
    var edited = blank
    edited.rateText = "15"
    edited.select(.actual)
    expectEqual(edited.save(), .success(NativeTaxSettingsDraft(taxIncomeRate: 15, vehicleDeductionMethod: .actual)),
                "rate and method saved")
    expect(!edited.showsMethodUnsetNote, "choosing a method hides the unset note")
    edited.select(.mileage)
    expectEqual(edited.selectedMethod, .mileage, "switching methods is allowed")

    // TaxSettingsModal.test.js: 75 and abc alert and save nothing.
    for bad in ["75", "abc"] {
        var refused = prefilled
        refused.rateText = bad
        expectEqual(refused.save(), .failure(.rateOutOfRange), "\(bad) refused before any save")
    }

    // `if (method) draft.vehicleDeductionMethod = method` (:79) includes the seeded
    // method; a blank rate leaves the stored rate alone (merge, TaxSetAsideCard :57).
    var keepRate = prefilled
    keepRate.rateText = "  "
    expectEqual(keepRate.save(), .success(NativeTaxSettingsDraft(vehicleDeductionMethod: .mileage)),
                "blank rate + seeded method")
    expectEqual(prefilled.save(), .success(NativeTaxSettingsDraft(taxIncomeRate: 18, vehicleDeductionMethod: .mileage)),
                "untouched prefill re-saves its own values")

    // A stored string outside the union: RN holds it (truthy, so no unset
    // note) and writes it back unchanged; natively the draft leaves it unchanged.
    let unknown = editor(#""vehicleDeductionMethod":"both""#)
    expect(unknown.selectedMethod == nil, "unknown stored method selects no chip")
    expect(!unknown.showsMethodUnsetNote, "unknown stored method is truthy in RN: no unset note")
    expectEqual(unknown.save(), .success(NativeTaxSettingsDraft()), "unknown stored method is left unchanged")
    let emptyMethod = editor(#""vehicleDeductionMethod":"""#)
    expect(emptyMethod.showsMethodUnsetNote, "empty stored method is falsy in RN: unset note shows")

    // Copy (TaxSettingsModal.tsx; JSX joins wrapped lines with one space).
    expectEqual(NativeTaxBreakdownCopy.settingsTitle, "Tax set-aside settings", "title (:91)")
    expectEqual(NativeTaxBreakdownCopy.rateLabel, "Income-tax rate (%)", "rate label (:93)")
    expectEqual(
        NativeTaxBreakdownCopy.settingsHelp,
        "Your effective federal + state income-tax rate. Self-employment tax (15.3%) is always included; "
            + "this adds the income-tax layer on top. Leave blank to estimate with self-employment tax only.",
        "rate help (:94-98)"
    )
    expectEqual(NativeTaxBreakdownCopy.ratePlaceholder, "e.g. 15", "placeholder (:103)")
    expectEqual(NativeTaxBreakdownCopy.vehicleLabel, "Vehicle deduction", "vehicle label (:110)")
    expectEqual(
        NativeTaxBreakdownCopy.vehicleHelp(mileageRateText: "$0.70"),
        "The IRS allows standard mileage ($0.70/mi from your trip log) OR actual costs (your fuel expenses) — "
            + "never both. Until you choose, the estimate deducts neither, which reserves a little extra.",
        "vehicle help (:111-116)"
    )
    expectEqual(NativeTaxBreakdownCopy.standardMileageLabel, "Standard mileage", "mileage chip (:122)")
    expectEqual(NativeTaxBreakdownCopy.actualFuelLabel, "Actual fuel costs", "actual chip (:139)")
    expectEqual(NativeTaxBreakdownCopy.methodUnsetNote, "No method chosen yet.", "unset note (:154)")
    expectEqual(
        NativeTaxBreakdownCopy.settingsDisclaimer,
        "Estimates only — not tax advice. Talk to a tax professional about which method suits your situation.",
        "disclaimer (:157-160)"
    )
    expectEqual(NativeTaxBreakdownCopy.rateValidationTitle, "Check the rate", "alert title (:72)")
    expectEqual(
        NativeTaxBreakdownCopy.rateValidationMessage,
        "Enter your effective income-tax rate as a percentage between 0 and 60 — most solo trades land between 10 and 25.",
        "alert message (:73)"
    )
}

// MARK: - card → editor route (12.00b.3, source scan)
//
// RN TaxSetAsideCard.tsx:71-75 makes the whole card a button that opens the
// modal (:119-124). Natively the Money tax card must take an `onOpen` that
// raises a sheet presenting `NativeTaxSettingsView`, and the view must commit
// through `AppStore.commitTaxSettings` and close only when that succeeds.

private func testCardOpensEditor(_ root: URL?) {
    guard let root else {
        expect(false, "route scan needs the repository root as the first argument")
        return
    }
    guard let moneyText = read(root, "native/TradeReadyNative/MoneyView.swift") else {
        expect(false, "MoneyView.swift readable")
        return
    }
    let money = SourceFile(relativePath: "MoneyView.swift", text: moneyText)

    let cards = money.occurrences(of: "NativeMoneyTaxCardView")
    expectEqual(cards.count, 1, "MoneyView builds the tax card once")
    if let card = cards.first,
       let paren = (card..<money.code.count).first(where: { money.code[$0] == "(" }),
       let close = money.matching(paren) {
        let closures = money.trailingClosuresEnd(from: close + 1).closures
        let opens = closures.first.map { money.rawSlice($0.range) } ?? ""
        expect(opens.contains("showingTaxSettings = true"), "tax card onOpen raises the settings sheet")
    } else {
        expect(false, "tax card call parsed")
    }

    let sheets = money.occurrences(of: "sheet").filter { hit in
        money.rawSlice(hit..<min(money.code.count, hit + 40)).hasPrefix("sheet(isPresented: $showingTaxSettings)")
    }
    expectEqual(sheets.count, 1, "one sheet is bound to showingTaxSettings")
    if let sheet = sheets.first,
       let paren = (sheet..<money.code.count).first(where: { money.code[$0] == "(" }),
       let close = money.matching(paren) {
        let body = money.trailingClosuresEnd(from: close + 1).closures.first.map { money.rawSlice($0.range) } ?? ""
        expect(body.contains("NativeTaxSettingsView(editor: store.taxSettingsEditor)"),
               "the sheet presents NativeTaxSettingsView seeded from the live settings (:55-63)")
    }
    expect(money.codeText.contains("@State private var showingTaxSettings = false"), "sheet flag is view state")

    guard let viewText = read(root, "native/TradeReadyNative/NativeTaxSettingsView.swift") else {
        expect(false, "NativeTaxSettingsView.swift exists")
        return
    }
    let view = SourceFile(relativePath: "NativeTaxSettingsView.swift", text: viewText)
    let viewStruct = structText(view, "NativeTaxSettingsView")
    expect(viewStruct.contains("_editor = State(initialValue: editor)"), "the sheet edits its own copy of the seed")
    expect(viewStruct.contains(".keyboardType(.decimalPad)"), "rate field uses the decimal pad (:105)")
    expect(viewStruct.contains(".nativeKeyboardDoneBar()"), "decimal pad gets the Done bar (:106, A24)")
    let save = functionBody(view, "save")
    expect(save.contains("editor.save()"), "save validates through the editor model")
    expect(save.contains("if store.commitTaxSettings(draft)"), "save commits through AppStore.commitTaxSettings")
    expect(save.contains("dismiss()"), "a successful save closes the sheet (TaxSetAsideCard :60)")
}

// MARK: - run

let rootArgument = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1]) : nil

testCanonicalMapping()
testDraftRules()
testTaxWindowAndCopy()
testJSNumberParity()
testEditorModel()
testCardOpensEditor(rootArgument)

if failures == 0 {
    print("TaxSettingsTests: all checks passed")
} else {
    print("TaxSettingsTests: \(failures) failure(s)")
    exit(1)
}
