import Foundation

// Task 11.11 host tests: iPad layouts, multitasking and rotation (H2), plus the
// hardware-keyboard row A11 handed over by 11.10a (contract §12.1).
//
// - Width math: `NativeLayoutMetrics` (RN `layout.contentColumn`, 700pt) for
//   phone, iPad, Split View, Slide Over, Stage Manager and landscape-phone
//   geometries, including safe-area insets. The constant is checked against
//   RN `utils/theme.ts`.
// - Source scans over every `.swift` file under `N/` (widget views excluded):
//   * every vertical `List`/`Form`/`ScrollView` is a known screen root and
//     carries `.nativeContentColumn(<kind>)` on its own top-level modifier
//     chain (each construct is read to the end of its trailing closures and
//     modifier chain, never a fixed window). The inventory is exact: a missing
//     target screen or an unknown new scroll root fails loudly;
//   * fixed chrome (composer, header controls, banners, bottom bars) is capped
//     with `.nativeContentColumnFrame()`;
//   * navigation: one `TabView`, no split view, and every view that hosts a
//     `NavigationStack` is only a tab root, an auth-gate root or a presented
//     sheet (never pushed), so no rotation or size-class change can show two
//     navigation bars;
//   * multitasking manifest: `UIRequiresFullScreen` absent, all four iPad
//     orientations, launch screen, universal device family;
//   * no `UIScreen` sizing, no keyboard safe-area opt-out, no fixed width that
//     cannot fit Slide Over, no hand-rolled width cap outside the allowlist;
//   * hardware keyboard: Esc on every Cancel/Done/Close, ⌘S on save, ⌘N on the
//     existing toolbar "new" actions, nothing on destructive actions, and no
//     custom command menus.
// Split View, Slide Over, Stage Manager, rotation and hardware-keyboard proof
// on a device stays Phase 12 (runsheet rows in the plan's 11.11 entry).
// Run with TZ=America/Phoenix.

// MARK: - Harness

var failures = 0
var checks = 0

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(label)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func expectClose(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001, _ label: String) {
    checks += 1
    guard let actual, abs(actual - expected) <= tolerance else {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected)\n  actual:   \(String(describing: actual))")
        return
    }
}

typealias Metrics = NativeLayoutMetrics
typealias Geometry = NativeLayoutMetrics.Geometry

// MARK: - Construct model (on `SourceFile` from native/HostTestSupport)

/// One call-like construct (`List { }`, `Button("x") { } label: { }`,
/// `.sheet(isPresented:) { }`) read from its keyword to the end of its
/// trailing closures and top-level modifier chain.
struct Construct {
    let file: SourceFile
    let keyword: String
    let start: Int
    let argsRange: Range<Int>?
    let closures: [(label: String?, range: Range<Int>)]
    let chainStart: Int
    let end: Int
    /// The construct's own modifiers, depth 0 only: a modifier inside a
    /// closure of another modifier (`.sheet { Form { }.x() }`) belongs to the
    /// nested view and is not listed.
    let modifiers: [(name: String, args: String)]

    var location: String { "N/\(file.relativePath):\(file.line(of: start))" }
    var rawArgs: String { argsRange.map { file.rawSlice($0) } ?? "" }
    var codeArgs: String { argsRange.map { file.codeSlice($0) } ?? "" }
    func hasModifier(_ name: String, args: String? = nil) -> Bool {
        modifiers.contains { $0.name == name && (args == nil || $0.args == args) }
    }
}

/// Parses the construct whose keyword starts at `start`, or nil when the
/// keyword is not followed by `(` or `{` (a type position, a comment).
func construct(in file: SourceFile, at start: Int, keyword: String) -> Construct? {
    let open = file.skipSpace(start + keyword.count)
    guard open < file.code.count, file.code[open] == "(" || file.code[open] == "{" else { return nil }
    var k = open
    var argsRange: Range<Int>? = nil
    if file.code[open] == "(" {
        guard let close = file.matching(open) else { return nil }
        argsRange = (open + 1)..<close
        k = close + 1
    }
    let trailing = file.trailingClosuresEnd(from: k)
    let chainStart = trailing.end
    // Walk the modifier chain exactly as `chainEnd` does, recording names.
    var modifiers: [(String, String)] = []
    var j = chainStart
    var end = chainStart
    while true {
        let next = file.skipSpace(j)
        guard next < file.code.count, file.code[next] == ".",
              let (name, afterName) = file.identifier(at: next + 1) else { break }
        var m = afterName
        var args = ""
        let paren = file.skipSpace(m)
        if paren < file.code.count, file.code[paren] == "(", let close = file.matching(paren) {
            args = file.rawSlice((paren + 1)..<close).trimmingCharacters(in: .whitespacesAndNewlines)
            m = close + 1
        }
        m = file.trailingClosuresEnd(from: m).end
        modifiers.append((name, args))
        j = m
        end = m
    }
    return Construct(file: file, keyword: keyword, start: start, argsRange: argsRange,
                     closures: trailing.closures, chainStart: chainStart, end: end,
                     modifiers: modifiers.map { (name: $0.0, args: $0.1) })
}

/// Every construct for `keyword` that is not member access (`.sheet` is found
/// with `memberAccess: true`).
func constructs(in file: SourceFile, keyword: String, memberAccess: Bool = false) -> [Construct] {
    file.occurrences(of: keyword).compactMap { hit in
        let isMember = hit > 0 && file.code[hit - 1] == "."
        guard isMember == memberAccess else { return nil }
        return construct(in: file, at: hit, keyword: keyword)
    }
}

/// `struct`/`class`/`enum`/`extension` declarations and their brace ranges.
struct TypeScope { let name: String; let range: Range<Int> }

func typeScopes(_ file: SourceFile) -> [TypeScope] {
    var scopes: [TypeScope] = []
    for keyword in ["struct", "class", "enum", "extension"] {
        for hit in file.occurrences(of: keyword) {
            let nameStart = file.skipSpace(hit + keyword.count)
            guard let (name, after) = file.identifier(at: nameStart),
                  let brace = (after..<file.code.count).first(where: { file.code[$0] == "{" }),
                  let close = file.matching(brace) else { continue }
            scopes.append(TypeScope(name: name, range: brace..<(close + 1)))
        }
    }
    return scopes
}

/// The innermost type declaration containing `index`.
func enclosingType(_ scopes: [TypeScope], _ index: Int) -> String {
    scopes.filter { $0.range.contains(index) }.min { $0.range.count < $1.range.count }?.name ?? "<file scope>"
}

func scanSources(_ sources: [SourceFile]) -> [SourceFile] {
    sources.filter { !$0.relativePath.hasPrefix("Widgets/") }
}

func file(_ sources: [SourceFile], _ path: String) -> SourceFile? {
    let found = sources.first { $0.relativePath == path }
    expect(found != nil, "N/\(path) exists")
    return found
}

// MARK: - Scroll-root scan

struct ScrollRoot {
    let construct: Construct
    let type: String
    var keyword: String { construct.keyword }
    var isHorizontal: Bool { keyword == "ScrollView" && construct.codeArgs.contains(".horizontal") }
    var expectedKind: String { keyword == "ScrollView" ? ".scroll" : ".list" }
    var appliedKinds: [String] { construct.modifiers.filter { $0.name == "nativeContentColumn" }.map(\.args) }
    var isFramed: Bool { construct.hasModifier("nativeContentColumnFrame") }
}

func scanScrollRoots(_ file: SourceFile) -> [ScrollRoot] {
    let scopes = typeScopes(file)
    var roots: [ScrollRoot] = []
    for keyword in ["List", "Form", "ScrollView"] {
        for c in constructs(in: file, keyword: keyword) where !c.closures.isEmpty {
            roots.append(ScrollRoot(construct: c, type: enclosingType(scopes, c.start)))
        }
    }
    return roots.sorted { $0.construct.start < $1.construct.start }
}

// MARK: - Presentation scan

/// Ranges (arguments and closures) of `.sheet`, `.fullScreenCover` and
/// `.popover` in `file`: a view instantiated there is presented modally.
func presentationRanges(_ file: SourceFile) -> [Range<Int>] {
    var ranges: [Range<Int>] = []
    for name in ["sheet", "fullScreenCover", "popover"] {
        for c in constructs(in: file, keyword: name, memberAccess: true) {
            if let args = c.argsRange { ranges.append(args) }
            ranges.append(contentsOf: c.closures.map(\.range))
        }
    }
    return ranges
}

/// Instantiation sites of `type` (`Type(` or `Type {`), excluding its declaration.
func instantiations(of type: String, in file: SourceFile) -> [Int] {
    file.occurrences(of: type).filter { hit in
        if hit > 0, file.code[hit - 1] == "." { return false }
        let next = file.skipSpace(hit + type.count)
        guard next < file.code.count, file.code[next] == "(" || file.code[next] == "{" else { return false }
        let before = file.codeSlice(max(0, hit - 16)..<hit)
        return !before.hasSuffix("struct ") && !before.hasSuffix("class ") && !before.hasSuffix("extension ")
    }
}

// MARK: - Toolbar scan

struct ToolbarButton {
    let placement: String
    let button: Construct
    var title: String {
        let raw = button.rawArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("\""), let close = raw.dropFirst().firstIndex(of: "\"") {
            return String(raw[raw.index(after: raw.startIndex)..<close])
        }
        return raw.isEmpty ? "<label closure>" : raw
    }
    var isDestructive: Bool { button.codeArgs.contains("role: .destructive") }
    var shortcuts: [String] { button.modifiers.filter { $0.name == "keyboardShortcut" }.map(\.args) }
}

func toolbarButtons(_ file: SourceFile) -> [ToolbarButton] {
    var result: [ToolbarButton] = []
    for item in constructs(in: file, keyword: "ToolbarItem") {
        let args = item.codeArgs
        let placement: String
        if args.contains("placement: .cancellationAction") { placement = "cancellationAction" }
        else if args.contains("placement: .confirmationAction") { placement = "confirmationAction" }
        else { continue }
        guard let body = item.closures.first?.range else { continue }
        for button in constructs(in: file, keyword: "Button") where body.contains(button.start) {
            result.append(ToolbarButton(placement: placement, button: button))
        }
    }
    return result
}

enum Shortcut {
    static let cancel = ".cancelAction"
    static let save = "\"s\", modifiers: .command"
    static let new = "\"n\", modifiers: .command"
    static let confirm = ".return, modifiers: .command"
}

/// The shortcut policy (contract §12.1 A11): what a toolbar button must carry.
func expectedShortcut(_ button: ToolbarButton) -> String? {
    if button.isDestructive { return nil }
    if button.placement == "cancellationAction" { return Shortcut.cancel }
    switch button.title {
    case "Done", "Close": return Shortcut.cancel
    case "Confirm": return Shortcut.confirm
    default: return Shortcut.save
    }
}

// MARK: - Tests: width math

func testWidthMath(root: URL) {
    expectEqual(Metrics.contentMaxWidth, 700, "contentMaxWidth is RN layout.contentMaxWidth")
    if let theme = try? String(contentsOf: root.appendingPathComponent("utils/theme.ts"), encoding: .utf8) {
        expect(theme.contains("contentMaxWidth: 700"), "RN utils/theme.ts still declares contentMaxWidth: 700")
        expect(theme.range(of: #"contentColumn:\s*\{\s*width:\s*"100%",\s*maxWidth:\s*700,\s*alignSelf:\s*"center""#,
                           options: .regularExpression) != nil,
               "RN contentColumn is { width: 100%, maxWidth: 700, alignSelf: center }")
    } else {
        expect(false, "RN utils/theme.ts is readable")
    }

    // ScrollView: margin inside the safe area; nil (system 0) at or below 700.
    let scroll: [(String, Geometry, Double?)] = [
        ("iPhone SE portrait 375", Geometry(width: 375), nil),
        ("iPhone Pro Max portrait 440", Geometry(width: 440), nil),
        ("Slide Over 320", Geometry(width: 320), nil),
        ("exactly the column 700", Geometry(width: 700), nil),
        ("one point wider 701", Geometry(width: 701), 0.5),
        ("iPad mini portrait 744", Geometry(width: 744), 22),
        ("iPad 11-inch portrait 834", Geometry(width: 834), 67),
        ("iPad 11-inch landscape 1210", Geometry(width: 1210), 255),
        ("iPad 13-inch landscape 1376", Geometry(width: 1376), 338),
        ("iPad 13-inch half split 678", Geometry(width: 678), nil),
        ("Pro Max landscape 832 inside 62pt safe areas", Geometry(width: 832, leadingSafeArea: 62, trailingSafeArea: 62), 66),
    ]
    for (name, geometry, expected) in scroll {
        let margin = Metrics.horizontalContentMargin(for: .scroll, in: geometry)
        if let expected {
            expectClose(margin, expected, "scroll margin: \(name)")
            expectClose(Metrics.columnWidth(for: .scroll, in: geometry), 700, "scroll column is 700: \(name)")
        } else {
            expect(margin == nil, "scroll keeps the system margin: \(name) (got \(String(describing: margin)))")
            expect(Metrics.columnWidth(for: .scroll, in: geometry) == nil, "scroll column is full width: \(name)")
        }
    }

    // List/Form: margin from the outer edge, used only once it clears the safe
    // area plus the 20pt system row inset (so the row edge never jumps inward).
    let list: [(String, Geometry, Double?)] = [
        ("iPhone portrait 393", Geometry(width: 393), nil),
        ("Slide Over 320", Geometry(width: 320), nil),
        ("exactly the column 700", Geometry(width: 700), nil),
        ("below the inset floor 739", Geometry(width: 739), nil),
        ("at the inset floor 740", Geometry(width: 740), 20),
        ("iPad mini portrait 744", Geometry(width: 744), 22),
        ("iPad 11-inch portrait 834 (simulator-measured row 67..767)", Geometry(width: 834), 67),
        ("iPad 13-inch landscape 1376", Geometry(width: 1376), 338),
        ("Stage Manager window 900", Geometry(width: 900), 100),
        ("Pro Max landscape 956 with 62pt safe areas (simulator-measured row 128..828)",
         Geometry(width: 832, leadingSafeArea: 62, trailingSafeArea: 62), 128),
        ("iPhone 17 Pro landscape 874 with 62pt safe areas", Geometry(width: 750, leadingSafeArea: 62, trailingSafeArea: 62), 87),
        ("iPhone SE landscape 667", Geometry(width: 667), nil),
        ("asymmetric safe area during rotation", Geometry(width: 894, leadingSafeArea: 62, trailingSafeArea: 0), 128),
        ("safe areas eat the floor", Geometry(width: 700, leadingSafeArea: 50, trailingSafeArea: 50), nil),
    ]
    for (name, geometry, expected) in list {
        let margin = Metrics.horizontalContentMargin(for: .list, in: geometry)
        if let expected {
            expectClose(margin, expected, "list margin: \(name)")
            expectClose(Metrics.columnWidth(for: .list, in: geometry), 700, "list row column is 700: \(name)")
            expect((margin ?? 0) >= max(geometry.leadingSafeArea, geometry.trailingSafeArea) + Metrics.listMinimumSideInset,
                   "list rows stay clear of the safe area plus the system inset: \(name)")
        } else {
            expect(margin == nil, "list keeps the system inset: \(name) (got \(String(describing: margin)))")
        }
    }

    // Degenerate geometry (first layout pass, bad input) keeps the system default.
    for (name, geometry) in [("zero", Geometry.zero), ("negative", Geometry(width: -10)),
                             ("NaN", Geometry(width: .nan)), ("infinite", Geometry(width: .infinity)),
                             ("negative safe area", Geometry(width: 1000, leadingSafeArea: -1))] {
        for container in Metrics.Container.allCases {
            expect(Metrics.horizontalContentMargin(for: container, in: geometry) == nil,
                   "\(container) margin is nil for \(name) geometry")
        }
    }

    // Sweep every width from 300 to 1400: the column never exceeds 700, the
    // margin is never negative, and the list row edge never moves inward past
    // the system inset when the column engages.
    var sweepOK = true
    for w in stride(from: 300.0, through: 1400.0, by: 0.5) {
        for safe in [0.0, 47, 62] {
            let g = Geometry(width: w, leadingSafeArea: safe, trailingSafeArea: safe)
            for container in Metrics.Container.allCases {
                if let m = Metrics.horizontalContentMargin(for: container, in: g) {
                    let column = Metrics.columnWidth(for: container, in: g) ?? -1
                    if m < 0 || abs(column - 700) > 0.0001 { sweepOK = false }
                    if container == .list, m < safe + Metrics.listMinimumSideInset { sweepOK = false }
                } else if container == .scroll, w > 700 {
                    sweepOK = false
                }
            }
        }
    }
    expect(sweepOK, "300–1400pt sweep: column ≤ 700, margins ≥ 0, list rows clear the safe area + 20pt")
}

// MARK: - Tests: scroll roots

/// Exact inventory of vertical scroll roots: (file, enclosing type, keyword) →
/// count. Every one must carry `.nativeContentColumn(<kind>)`. A screen that
/// disappears, gains a root or adds a new one fails here until triaged.
let scrollRootInventory: [String: Int] = [
    "CoachView.swift|CoachView|ScrollView": 2,
    "CustomersView.swift|CustomersView|List": 1,
    "CustomersView.swift|CustomerDetailView|List": 1,
    "CustomersView.swift|NativeCustomerMergePicker|List": 1,
    "CustomersView.swift|CustomerEditor|Form": 1,
    "InvoicesView.swift|InvoicesView|List": 1,
    "InvoicesView.swift|InvoiceDetailView|List": 1,
    "InvoicesView.swift|InvoiceEditor|Form": 1,
    "InvoicesView.swift|PaymentEditor|Form": 1,
    "JobsView.swift|JobsView|List": 1,
    "JobsView.swift|JobDetailView|List": 1,
    "JobsView.swift|JobEditor|Form": 1,
    "MoneyView.swift|MoneyView|ScrollView": 1,
    "MoneyView.swift|MoneyView|List": 1,
    "NativeAuthView.swift|NativeAuthView|ScrollView": 1,
    "NativeBookingRequestsView.swift|NativeBookingRequestsView|List": 1,
    "NativeBookingSettingsView.swift|NativeBookingSettingsView|Form": 1,
    "NativeCalendarView.swift|NativeCalendarView|List": 2,
    "NativeChangeOrdersView.swift|NativeChangeOrderEditorView|Form": 1,
    "NativeChangeOrdersView.swift|ChangeOrderDecisionSheet|Form": 1,
    "NativeChangeOrdersView.swift|NativeChangeOrderReviewView|Form": 1,
    "NativeCreateInvoiceFromJobView.swift|NativeCreateInvoiceFromJobView|Form": 1,
    "NativeCustomerPortalView.swift|NativeCustomerPortalView|Form": 1,
    "NativeEstimateFollowUpView.swift|NativeEstimateFollowUpView|Form": 1,
    "NativeEstimateReview.swift|NativeEstimateReviewView|Form": 1,
    "NativeExpenseEditor.swift|NativeExpenseEditor|Form": 1,
    "NativeExportDataView.swift|NativeExportDataView|List": 1,
    "NativeGlobalSearch.swift|NativeGlobalSearchView|List": 1,
    "NativeImportView.swift|NativeImportView|List": 1,
    "NativeInvoiceOutreachView.swift|NativeInvoiceOutreachView|Form": 1,
    "NativeJobProfitabilityView.swift|NativeJobProfitabilitySection|List": 1,
    "NativeMessageComposer.swift|NativeOnMyWayReviewView|Form": 1,
    "NativeMessageComposer.swift|NativeAppointmentConfirmationReviewView|Form": 1,
    "NativeMileageLogView.swift|NativeMileageLogView|List": 1,
    "NativeOnboardingView.swift|NativeOnboardingView|ScrollView": 1,
    "NativeOnboardingView.swift|NativeStartingPointView|ScrollView": 1,
    "NativePasswordRecoveryView.swift|NativePasswordRecoveryView|ScrollView": 1,
    "NativePaywallView.swift|NativePaywallView|ScrollView": 1,
    "NativePricebookEntryView.swift|NativePricebookEntryView|Form": 1,
    "NativePricebookView.swift|NativePricebookView|List": 1,
    "NativePricingCalculator.swift|NativePricingCalculatorView|Form": 1,
    "NativeRecurringInvoicesView.swift|NativeRecurringInvoicesView|List": 1,
    "NativeRecurringInvoicesView.swift|NativeRecurringInvoiceEditor|Form": 1,
    "NativeRecurringJobsView.swift|NativeRecurringJobsView|List": 1,
    "NativeRecurringJobsView.swift|NativeRecurringJobEditor|Form": 1,
    "NativeReviewRequestView.swift|NativeReviewRequestView|Form": 1,
    "NativeRouteView.swift|NativeRouteView|List": 1,
    "NativeScheduleEditorView.swift|NativeScheduleEditorView|Form": 1,
    "NativeScheduleSettingsView.swift|NativeScheduleSettingsView|Form": 1,
    "NativeTemplatePickerView.swift|NativeTemplatePickerView|List": 1,
    "NativeTemplatePickerView.swift|NativePricebookJobPickerView|List": 1,
    "NativeTripEditor.swift|NativeTripEditor|Form": 1,
    "SettingsView.swift|SettingsView|ScrollView": 1,
    "SettingsView.swift|SettingsPage|Form": 1,
    "SettingsView.swift|AccountSettings|Form": 1,
    "TodayView.swift|TodayView|ScrollView": 1,
]

/// Horizontal chip rows nested inside a capped screen (file → count). They
/// scroll sideways inside the column and must not take a horizontal margin.
let horizontalChipRows: [String: Int] = [
    "JobsView.swift": 1, "MoneyView.swift": 1, "NativeExpenseEditor.swift": 2,
    "NativeExportDataView.swift": 1, "NativeImportView.swift": 1, "NativeJobPhotosView.swift": 1,
    "NativeMileageLogView.swift": 1, "NativeInvoiceOutreachView.swift": 1, "NativeTripEditor.swift": 1,
]

/// Every `SettingsPage` screen shares the capped `SettingsPage` Form.
let settingsPageScreens = [
    "BusinessProfileSettings", "PricingSettings", "InvoiceNumberSettings", "ImportSettings",
    "SyncSettings", "PaymentsSettings", "AppearanceSettings", "AISettings", "NotificationSettings",
    "ReviewSettings", "SubscriptionSettings", "AccountSettings",
]

func testScrollRoots(sources: [SourceFile]) {
    var found: [String: Int] = [:]
    var horizontal: [String: Int] = [:]
    var total = 0
    for file in scanSources(sources) {
        for root in scanScrollRoots(file) {
            total += 1
            if root.isHorizontal {
                horizontal[file.relativePath, default: 0] += 1
                expect(root.appliedKinds.isEmpty,
                       "horizontal chip row takes no column margin at \(root.construct.location)")
                continue
            }
            let key = "\(file.relativePath)|\(root.type)|\(root.keyword)"
            found[key, default: 0] += 1
            expect(scrollRootInventory[key] != nil,
                   "unknown scroll root \(root.keyword) in \(root.type) at \(root.construct.location): add it to the inventory and apply .nativeContentColumn(\(root.expectedKind))")
            expectEqual(root.appliedKinds, [root.expectedKind],
                        "\(root.keyword) in \(root.type) at \(root.construct.location) applies .nativeContentColumn(\(root.expectedKind)) exactly once")
            expect(!root.isFramed, "\(root.keyword) at \(root.construct.location) uses the scroll-content column, not a frame cap")
        }
    }
    for (key, count) in scrollRootInventory.sorted(by: { $0.key < $1.key }) {
        expectEqual(found[key] ?? 0, count, "target screen root present: \(key)")
    }
    expectEqual(horizontal, horizontalChipRows, "horizontal chip-row inventory")
    let expectedTotal = scrollRootInventory.values.reduce(0, +) + horizontalChipRows.values.reduce(0, +)
    expectEqual(total, expectedTotal, "scanned every List/Form/ScrollView under N/ (\(total))")
    expect(total >= 60, "scanner found the app's scroll containers (\(total))")

    // SettingsPage screens: each one really is a SettingsPage.
    if let settings = file(sources, "SettingsView.swift") {
        let scopes = typeScopes(settings)
        for screen in settingsPageScreens {
            guard let scope = scopes.first(where: { $0.name == screen }) else {
                expect(false, "Settings screen \(screen) exists"); continue
            }
            let uses = instantiations(of: "SettingsPage", in: settings).filter { scope.range.contains($0) }
            expect(!uses.isEmpty, "Settings screen \(screen) renders through the capped SettingsPage")
        }
    }

    // Retired hand-rolled cap: Settings used `.frame(maxWidth: 700)`.
    if let settings = file(sources, "SettingsView.swift") {
        expect(!settings.codeText.contains("maxWidth: 700"), "SettingsView no longer hand-rolls the 700pt cap")
    }
}

// MARK: - Tests: fixed chrome

/// Non-scrolling chrome that must be capped with `.nativeContentColumnFrame()`:
/// (file, type, raw marker, construct keyword, search backwards from marker).
let fixedChrome: [(String, String, String, String, Bool)] = [
    ("CoachView.swift", "CoachView", "private var composer", "HStack", false),
    ("MoneyView.swift", "MoneyView", "private var filterChips", "ScrollView", false),
    ("MoneyView.swift", "MoneyView", "private var tabPicker", "Picker", false),
    ("NativeCalendarView.swift", "NativeCalendarView", "Picker(\"View\"", "Picker", false),
    ("NativeCalendarView.swift", "NativeCalendarView", "private var navigationBar", "HStack", false),
    ("Components.swift", "NativeSyncBanner", "if isVisible", "HStack", false),
    ("Components.swift", "NativeUndoBanner", "private func undoRow", "HStack", false),
    ("InvoicesView.swift", "InvoicesView", ".safeAreaInset(edge: .bottom)", "HStack", false),
    ("NativeOnboardingView.swift", "NativeOnboardingView", "if draft.step > 0", "HStack", true),
    ("NativeRouteView.swift", "NativeRouteView", "MapPreviewView(preview:", "MapPreviewView", false),
    ("NativeRouteView.swift", "NativeRouteView", "ProgressView(\"Building route preview", "ProgressView", false),
    ("NativeRouteView.swift", "NativeRouteView", "Label(\"No addresses to preview\"", "ContentUnavailableView", true),
]

func testFixedChrome(sources: [SourceFile]) {
    for (path, type, marker, keyword, backwards) in fixedChrome {
        guard let file = file(sources, path) else { continue }
        guard let scope = typeScopes(file).first(where: { $0.name == type }) else {
            expect(false, "type \(type) exists in N/\(path)"); continue
        }
        let text = file.rawSlice(scope.range)
        guard let markerRange = text.range(of: marker) else {
            expect(false, "marker '\(marker)' found in \(type) (N/\(path))"); continue
        }
        let markerIndex = scope.range.lowerBound + text.distance(from: text.startIndex, to: markerRange.lowerBound)
        let hits = file.occurrences(of: keyword).filter { scope.range.contains($0) && (file.code[$0 - 1] != ".") }
        let hit = backwards ? hits.last(where: { $0 < markerIndex }) : hits.first(where: { $0 >= markerIndex })
        guard let hit, let c = construct(in: file, at: hit, keyword: keyword) else {
            expect(false, "\(keyword) near '\(marker)' found in \(type) (N/\(path))"); continue
        }
        expect(c.hasModifier("nativeContentColumnFrame"),
               "\(keyword) near '\(marker)' in \(type) is capped with .nativeContentColumnFrame() (\(c.location))")
    }
}

// MARK: - Tests: navigation structure

func testNavigationStructure(sources: [SourceFile]) {
    let scanned = scanSources(sources)
    for banned in ["NavigationSplitView", "NavigationView", "UISplitViewController", "sidebarAdaptable", "tabViewStyle"] {
        let sites = scanned.flatMap { f in f.occurrences(of: banned).map { "N/\(f.relativePath):\(f.line(of: $0))" } }
        expect(sites.isEmpty, "no \(banned) in N/ (RN is a phone-style tab app on iPad): \(sites)")
    }
    let tabViews = scanned.flatMap { f in constructs(in: f, keyword: "TabView").map(\.location) }
    expectEqual(tabViews.count, 1, "exactly one TabView in N/ (\(tabViews))")
    if let rootView = file(sources, "RootView.swift") {
        expect(tabViews.first?.hasPrefix("N/RootView.swift") == true, "the TabView is RootView's")
        let tabs = rootView.occurrences(of: "tag").filter { rootView.code[$0 - 1] == "." }.count
        expectEqual(tabs, 6, "RootView keeps six tabs in every size class")
    }

    // Views whose own body is a NavigationStack. A stack inside the type's
    // own `.sheet` closure (a confirmation sheet) is a presented stack, not a
    // host; it is covered by being presented.
    var hosts: [String] = []
    var presentedStacks = 0
    for f in scanned {
        let scopes = typeScopes(f)
        let presented = presentationRanges(f)
        for hit in f.occurrences(of: "NavigationStack") {
            if presented.contains(where: { $0.contains(hit) }) { presentedStacks += 1; continue }
            let type = enclosingType(scopes, hit)
            if !hosts.contains(type) { hosts.append(type) }
        }
    }
    expect(presentedStacks >= 3, "stacks built inside a presentation closure are recognized (\(presentedStacks))")
    expect(hosts.count >= 30, "found the NavigationStack hosts (\(hosts.count))")
    expect(hosts.contains("TodayView") && hosts.contains("NativeCalendarView") && hosts.contains("JobEditor"),
           "host scan sees tab roots and sheets")

    // Each host is only a tab root / gate root (RootView, the App scene) or
    // presented modally; never pushed onto another stack.
    var siteCount = 0
    for host in hosts {
        var hostSites = 0
        for f in scanned {
            let presented = presentationRanges(f)
            for hit in instantiations(of: host, in: f) {
                hostSites += 1
                siteCount += 1
                let isRoot = f.relativePath == "RootView.swift" || f.relativePath == "TradeReadyNativeApp.swift"
                let isPresented = presented.contains { $0.contains(hit) }
                expect(isRoot || isPresented,
                       "\(host) (hosts a NavigationStack) is presented modally or is a root, never pushed: N/\(f.relativePath):\(f.line(of: hit))")
            }
        }
        if host != "RootView" { expect(hostSites > 0 || host == "<file scope>", "NavigationStack host \(host) has an instantiation site") }
    }
    expect(siteCount >= 40, "checked every host instantiation (\(siteCount))")
}

// MARK: - Tests: multitasking manifest and fixed widths

func testManifest(root: URL) {
    let url = root.appendingPathComponent("native/Info.plist")
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
        expect(false, "native/Info.plist parses"); return
    }
    expect(plist["UIRequiresFullScreen"] == nil, "UIRequiresFullScreen is absent (Split View and Slide Over allowed)")
    expectEqual(Set(plist["UISupportedInterfaceOrientations~ipad"] as? [String] ?? []),
                Set(["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown",
                     "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]),
                "iPad declares all four orientations (required for multitasking)")
    expectEqual(Set(plist["UISupportedInterfaceOrientations"] as? [String] ?? []),
                Set(["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft",
                     "UIInterfaceOrientationLandscapeRight"]),
                "iPhone declares portrait and both landscapes")
    expect(plist["UILaunchScreen"] != nil, "a launch screen is declared (required for multitasking)")
    let scenes = plist["UIApplicationSceneManifest"] as? [String: Any]
    expectEqual(scenes?["UIApplicationSupportsMultipleScenes"] as? Bool, false,
                "one window scene, as RN (Split View and Slide Over need no second scene)")

    if let project = try? String(contentsOf: root.appendingPathComponent("native/TradeReadyNative.xcodeproj/project.pbxproj"), encoding: .utf8) {
        let families = project.components(separatedBy: "\n").filter { $0.contains("TARGETED_DEVICE_FAMILY") }
        expect(!families.isEmpty && families.allSatisfy { $0.contains("\"1,2\"") },
               "every target is universal (TARGETED_DEVICE_FAMILY = 1,2): \(families.count) settings")
        expect(!project.contains("UIRequiresFullScreen"), "no build setting forces full screen")
    } else {
        expect(false, "project.pbxproj is readable")
    }
}

/// The code of `file` with every `#if !FLAG … #endif` region removed for each
/// flag in `defined` (nested directives are balanced), so a host runner's
/// `-D` flags decide which view code it actually compiles.
func activeCode(_ file: SourceFile, defined: Set<String>) -> String {
    var kept: [Substring] = []
    var skipDepth = 0
    for line in file.codeText.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if skipDepth > 0 {
            if trimmed.hasPrefix("#if") { skipDepth += 1 }
            if trimmed.hasPrefix("#endif") { skipDepth -= 1 }
            continue
        }
        if trimmed.hasPrefix("#if !"),
           defined.contains(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)) {
            skipDepth = 1
            continue
        }
        kept.append(line)
    }
    return kept.joined(separator: "\n")
}

/// Every host runner that compiles a file using the column modifiers must also
/// compile `NativeLayoutMetrics.swift`, or the aggregate breaks (the calendar
/// editor and schedule/booking settings runners compile view files on macOS).
func testHostRunners(root: URL, sources: [SourceFile]) {
    let native = root.appendingPathComponent("native")
    let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: native.path)) ?? [])
        .filter { $0.hasPrefix("run-") && $0.hasSuffix(".sh") }.sorted()
    expect(scripts.count >= 40, "found the native host runners (\(scripts.count))")
    guard let common = read(root, "native/run-appstore-sources-common.sh") else {
        expect(false, "native/run-appstore-sources-common.sh is readable"); return
    }
    func compiledFiles(_ script: String) -> Set<String> {
        var names = Set<String>()
        for token in script.split(whereSeparator: { " \n\t\"\\".contains($0) })
        where token.contains("native/TradeReadyNative/") && token.hasSuffix(".swift") {
            let path = String(token.components(separatedBy: "native/TradeReadyNative/").last!)
            let parts = path.components(separatedBy: "*")
            if parts.count == 2 {
                // A shell glob (`Domain/Canonical*.swift`): expand it over N/.
                let matches = sources.map(\.relativePath).filter {
                    $0.hasPrefix(parts[0]) && $0.hasSuffix(parts[1]) && $0.count >= path.count - 1
                }
                expect(!matches.isEmpty, "glob N/\(path) matches files")
                names.formUnion(matches)
            } else {
                names.insert(path)
            }
        }
        return names
    }
    let byPath = Dictionary(uniqueKeysWithValues: sources.map { ($0.relativePath, $0) })
    var runnersCompilingUsers = 0
    for name in scripts where name != "run-appstore-sources-common.sh" {
        guard let script = read(root, "native/\(name)") else { expect(false, "\(name) is readable"); continue }
        var files = compiledFiles(script)
        if script.contains("APPSTORE_TEST_SOURCES") { files.formUnion(compiledFiles(common)) }
        var defined = Set<String>()
        let words = script.split(whereSeparator: { " \n\t\\".contains($0) }).map(String.init)
        for (index, word) in words.enumerated() where word == "-D" && index + 1 < words.count {
            defined.insert(words[index + 1])
        }
        let users = files.sorted().filter { path in
            guard path != "NativeLayoutMetrics.swift" else { return false }
            guard let file = byPath[path] else { return false }
            return activeCode(file, defined: defined).contains("nativeContentColumn")
        }
        for missing in files.sorted() where byPath[missing] == nil {
            expect(false, "\(name) compiles N/\(missing), which exists")
        }
        guard !users.isEmpty else { continue }
        runnersCompilingUsers += 1
        expect(files.contains("NativeLayoutMetrics.swift"),
               "\(name) compiles NativeLayoutMetrics.swift for \(users.joined(separator: ", "))")
    }
    // The calendar editor and schedule/booking settings runners compile column users.
    expect(runnersCompilingUsers >= 2, "host runners compiling column users found (\(runnersCompilingUsers))")
}

/// Literal hand-rolled width caps that are allowed (file → literals). They are
/// narrower than the column (a single form card) and predate 11.11.
let allowedMaxWidthLiterals: [String: [Int]] = [
    "NativeAuthView.swift": [520], "NativePasswordRecoveryView.swift": [520],
    "NativePaywallView.swift": [560], "NativeOnboardingView.swift": [560, 560],
]

func testFixedWidths(sources: [SourceFile]) {
    let scanned = scanSources(sources)
    var maxWidthLiterals: [String: [Int]] = [:]
    var frames = 0
    for f in scanned {
        for id in ["UIScreen"] {
            for hit in f.occurrences(of: id) {
                expect(false, "no \(id) sizing (wrong under Split View/Slide Over): N/\(f.relativePath):\(f.line(of: hit))")
            }
        }
        let code = f.codeText
        expect(!code.contains("ignoresSafeArea(.keyboard"), "keyboard avoidance kept in N/\(f.relativePath)")
        for c in constructs(in: f, keyword: "frame", memberAccess: true) {
            frames += 1
            let args = c.codeArgs
            for key in ["width", "minWidth", "idealWidth", "maxWidth"] {
                guard let range = args.range(of: #"(^|[^A-Za-z])"# + key + #":\s*([0-9]+(\.[0-9]+)?)"#, options: .regularExpression) else { continue }
                let match = String(args[range])
                guard let number = match.split(separator: ":").last.flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) else { continue }
                if key == "maxWidth" {
                    if number >= 300 { maxWidthLiterals[f.relativePath, default: []].append(Int(number)) }
                } else {
                    expect(number < 320, "\(key): \(Int(number)) fits Slide Over (320pt) at \(c.location)")
                }
            }
        }
    }
    expect(frames >= 100, "scanned the app's frame modifiers (\(frames))")
    expectEqual(maxWidthLiterals, allowedMaxWidthLiterals,
                "hand-rolled maxWidth caps ≥ 300pt are only the allowlisted form cards (use .nativeContentColumn instead)")
}

// MARK: - Tests: hardware keyboard (contract §12.1 A11)

/// Existing toolbar "new" actions that get ⌘N: (file, marker inside the
/// Button's own label or modifiers).
let newShortcutSites: [(String, String)] = [
    ("JobsView.swift", "Label.addJob"),
    ("InvoicesView.swift", "Label.addInvoice"),
    ("CustomersView.swift", "Label.addCustomer"),
    ("NativeRecurringInvoicesView.swift", "Label.addMaintenancePlan"),
    ("CoachView.swift", "\"New chat\""),
]

func testKeyboardShortcuts(sources: [SourceFile]) {
    let scanned = scanSources(sources)
    var toolbar: [ToolbarButton] = []
    for f in scanned { toolbar.append(contentsOf: toolbarButtons(f)) }
    let cancels = toolbar.filter { $0.placement == "cancellationAction" }
    let confirms = toolbar.filter { $0.placement == "confirmationAction" }
    expect(cancels.count >= 25, "found the cancellation toolbar buttons (\(cancels.count))")
    expect(confirms.count >= 15, "found the confirmation toolbar buttons (\(confirms.count))")
    expect(confirms.contains { $0.isDestructive }, "the destructive delete-account confirmation is scanned")

    var verified = 0
    for item in toolbar {
        let expected = expectedShortcut(item)
        if let expected {
            expectEqual(item.shortcuts, [expected],
                        "\(item.placement) '\(item.title)' at \(item.button.location) has .keyboardShortcut(\(expected))")
            verified += 1
        } else {
            expectEqual(item.shortcuts, [], "destructive '\(item.title)' at \(item.button.location) has no keyboard shortcut")
        }
    }

    for (path, marker) in newShortcutSites {
        guard let f = file(sources, path) else { continue }
        let buttons = constructs(in: f, keyword: "Button").filter { f.rawSlice($0.start..<$0.end).contains(marker) }
            .filter { b in !constructs(in: f, keyword: "Button").contains { $0.start > b.start && $0.end <= b.end && f.rawSlice($0.start..<$0.end).contains(marker) } }
        expectEqual(buttons.count, 1, "one toolbar button for \(marker) in N/\(path)")
        if let button = buttons.first {
            expectEqual(button.modifiers.filter { $0.name == "keyboardShortcut" }.map(\.args), [Shortcut.new],
                        "\(marker) (N/\(path)) has ⌘N")
            verified += 1
        }
    }

    // No other shortcuts, and no custom command menus (RN has none).
    var total = 0
    for f in scanned {
        total += f.occurrences(of: "keyboardShortcut").filter { f.code[$0 - 1] == "." }.count
        for banned in ["CommandMenu", "CommandGroup", "UIKeyCommand", "commands"] {
            for hit in f.occurrences(of: banned) where banned != "commands" || f.code[hit - 1] == "." {
                expect(false, "no custom command menu (\(banned)) at N/\(f.relativePath):\(f.line(of: hit))")
            }
        }
    }
    expectEqual(total, verified, "every .keyboardShortcut in N/ is one the policy checked")
}

// MARK: - Tests: scanner fixture

func testScannerFixture() {
    let text = """
    struct Capped: View {
        var body: some View {
            NavigationStack {
                List { Text("a {") }
                    .nativeContentColumn(.list)
                    .sheet(isPresented: $x) { Pushed() }
            }
        }
    }
    struct Uncapped: View {
        var body: some View {
            Form { Text("b") }
                .navigationDestination(for: Int.self) { _ in Hosted() }
                .sheet(isPresented: $y) { Form { }.nativeContentColumn(.list) }
            ScrollView(.horizontal) { HStack { } }
        }
    }
    struct Hosted: View { var body: some View { NavigationStack { Text("") } } }
    struct Pushed: View { var body: some View { NavigationStack { Text("") }.toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { }.keyboardShortcut(.cancelAction) }
        ToolbarItem(placement: .confirmationAction) { Button("Save") { } }
        ToolbarItem(placement: .confirmationAction) { Button("Delete", role: .destructive) { } }
    } } }
    """
    let f = SourceFile(relativePath: "Fixture.swift", text: text)
    let roots = scanScrollRoots(f)
    expectEqual(roots.map(\.keyword), ["List", "Form", "Form", "ScrollView"], "fixture: scroll roots in order")
    expectEqual(roots.map(\.type), ["Capped", "Uncapped", "Uncapped", "Uncapped"], "fixture: enclosing types")
    expectEqual(roots.map(\.appliedKinds), [[".list"], [], [".list"], []],
                "fixture: a column inside a .sheet closure does not cap the outer Form")
    expectEqual(roots.map(\.isHorizontal), [false, false, false, true], "fixture: horizontal chip row")
    let presented = presentationRanges(f)
    let pushedSites = instantiations(of: "Pushed", in: f)
    let hostedSites = instantiations(of: "Hosted", in: f)
    expectEqual(pushedSites.count, 1, "fixture: one Pushed site (declaration excluded)")
    expect(pushedSites.allSatisfy { s in presented.contains { $0.contains(s) } }, "fixture: Pushed is presented in a sheet")
    expect(hostedSites.allSatisfy { s in !presented.contains { $0.contains(s) } },
           "fixture: Hosted in navigationDestination is not a presentation (would fail the host rule)")
    let buttons = toolbarButtons(f)
    expectEqual(buttons.map(\.title), ["Cancel", "Save", "Delete"], "fixture: toolbar buttons")
    expectEqual(buttons.map { expectedShortcut($0) }, [Shortcut.cancel, Shortcut.save, nil], "fixture: shortcut policy")
    expectEqual(buttons.map(\.shortcuts), [[Shortcut.cancel], [], []], "fixture: shortcuts read from each button's own chain")
}

// MARK: - Entry

@main
struct LayoutMetricsTests {
    static func main() {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sources = loadSources(root: root)
        expect(sources.count >= 100, "loaded every N/ swift file (\(sources.count))")

        testScannerFixture()
        testWidthMath(root: root)
        testScrollRoots(sources: sources)
        testFixedChrome(sources: sources)
        testNavigationStructure(sources: sources)
        testManifest(root: root)
        testHostRunners(root: root, sources: sources)
        testFixedWidths(sources: sources)
        testKeyboardShortcuts(sources: sources)

        if failures > 0 {
            print("layout-metrics tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("layout-metrics tests: \(checks)/\(checks) checks passed")
    }
}
