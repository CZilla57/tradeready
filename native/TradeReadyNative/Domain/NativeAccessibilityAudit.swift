import Foundation

// MARK: - Accessibility audit source of truth (task 11.10a, requirement H1)
//
// Pure, Foundation-only policy behind the 11.10a accessibility fixes
// (contract `docs/native-phase-11-platform-hardening-contract-decisions.md`
// §12 and its 11.10a follow-up). Views read the label text and motion policy
// from here; the host suite `native/AccessibilityAuditTests` proves the
// contrast math, the palette literals in `N/Models.swift` and the asset
// catalog, the RN label parity, and the source scans.
//
// No SwiftUI here: colors are plain sRGB triples, and the views map them to
// `Color` in `N/Models.swift`.

enum NativeAccessibilityAudit {

    // MARK: Contrast (WCAG 2.x relative luminance)

    /// An opaque sRGB color with components in 0...1.
    struct RGB: Equatable, CustomStringConvertible {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `#rrggbb` (the leading `#` is optional). Returns nil for anything else.
        init?(hex: String) {
            var text = hex.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") { text.removeFirst() }
            guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }

        var description: String {
            String(format: "(%.3f, %.3f, %.3f)", red, green, blue)
        }
    }

    /// WCAG 2.x relative luminance of an sRGB color.
    static func relativeLuminance(_ color: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG contrast ratio, symmetric, in 1...21.
    static func contrastRatio(_ first: RGB, _ second: RGB) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `foreground` at `alpha` composited over an opaque `background` (the
    /// `Color.opacity` washes such as `tradeReady.opacity(0.12)`).
    static func composite(_ foreground: RGB, alpha: Double, over background: RGB) -> RGB {
        RGB(
            red: foreground.red * alpha + background.red * (1 - alpha),
            green: foreground.green * alpha + background.green * (1 - alpha),
            blue: foreground.blue * alpha + background.blue * (1 - alpha)
        )
    }

    /// WCAG 1.4.3 (text) and 1.4.11 (non-text UI) minimums.
    enum Threshold {
        static let text = 4.5
        static let nonText = 3.0
    }

    /// The app palette as plain triples. `N/Models.swift` and
    /// `Assets.xcassets/AccentColor.colorset` must carry exactly these literals
    /// (the host suite parses both).
    enum Palette {
        /// RN `lightColors.accent` `#1d5c9e`. Unchanged for RN parity.
        static let tradeReadyLight = RGB(red: 0.114, green: 0.361, blue: 0.620)
        /// RN `darkColors.accent` `#5b9bdb` ("blueprint blue, brightened for
        /// dark ground"). Text, icon and outline use on dark grounds.
        static let tradeReadyDark = RGB(red: 0.357, green: 0.608, blue: 0.859)
        /// Filled surfaces that carry white text or icons (selected chips, the
        /// Today hero, prominent buttons). Light keeps `#1d5c9e`.
        static let tradeReadyFillLight = RGB(red: 0.114, green: 0.361, blue: 0.620)
        /// Dark fill `#2f78c4`: white text stays at 4.5:1 or better, and the fill
        /// stays at 3:1 or better against the dark grounds. RN's dark accent
        /// `#5b9bdb` measures 2.93:1 under white text, so the fill is a native
        /// difference recorded in contract §12.
        static let tradeReadyFillDark = RGB(red: 0.184, green: 0.471, blue: 0.769)
        static let tradeCanvasLight = RGB(red: 0.961, green: 0.961, blue: 0.945)
        static let tradeCanvasDark = RGB(red: 0.063, green: 0.094, blue: 0.149)
        static let white = RGB(red: 1, green: 1, blue: 1)
        /// iOS dark `systemBackground` / `systemGroupedBackground`.
        static let systemBackgroundDark = RGB(red: 0, green: 0, blue: 0)
        /// iOS dark `secondarySystemGroupedBackground` (list rows) and the
        /// elevated `systemBackground` (sheets), `#1c1c1e`.
        static let secondaryGroupedDark = RGB(hex: "#1c1c1e")!
        /// iOS dark elevated `secondarySystemGroupedBackground` (list rows in a
        /// sheet), `#2c2c2e`.
        static let elevatedGroupedDark = RGB(hex: "#2c2c2e")!
        /// iOS light `systemGroupedBackground`, `#f2f2f7`.
        static let systemGroupedLight = RGB(hex: "#f2f2f7")!
        /// RN `darkColors.surface`, `#182238`.
        static let rnSurfaceDark = RGB(hex: "#182238")!
        /// Filled destructive surfaces under white text (the clock-out button;
        /// 11.10b A18). Light is RN `lightColors.danger` `#b8432b`.
        static let dangerFillLight = RGB(red: 0.722, green: 0.263, blue: 0.169)
        /// Dark `#cc4a30`, native only: white text stays at 4.5:1 or better and
        /// the fill stays at 3:1 or better on the dark grounds. RN's dark danger
        /// `#e06a4f` measures 3.31:1 under white text.
        static let dangerFillDark = RGB(red: 0.800, green: 0.290, blue: 0.188)
        /// iOS `systemRed` (light `#ff3b30`, dark `#ff453a`): what the clock-out
        /// button used before 11.10b. Recorded as the A18 baseline only.
        static let systemRedLight = RGB(hex: "#ff3b30")!
        static let systemRedDark = RGB(hex: "#ff453a")!
        /// Error and destructive text (11.10b A28). Light is RN
        /// `lightColors.danger` `#b8432b`, the color RN gives error text.
        /// System red text measured 3.55:1 on a white list row.
        static let dangerTextLight = RGB(red: 0.722, green: 0.263, blue: 0.169)
        /// Dark `#eb7d63`, native only: RN's dark danger `#e06a4f` measures
        /// 4.21:1 on a sheet list row `#2c2c2e`.
        static let dangerTextDark = RGB(red: 0.922, green: 0.490, blue: 0.388)
    }

    enum ContrastRole: String {
        case text
        case nonText
        var minimum: Double { self == .text ? Threshold.text : Threshold.nonText }
    }

    struct ContrastRequirement: Equatable {
        let name: String
        let foreground: RGB
        let background: RGB
        let role: ContrastRole
    }

    /// Every pairing the 11.10a contrast fix relies on. Each must meet its
    /// role's minimum; the host suite computes them all.
    static let contrastRequirements: [ContrastRequirement] = {
        let p = Palette.self
        let tintWashDarkCanvas = composite(p.tradeReadyDark, alpha: 0.12, over: p.tradeCanvasDark)
        let tintWashDarkRow = composite(p.tradeReadyDark, alpha: 0.12, over: p.secondaryGroupedDark)
        let borderedDark = composite(p.tradeReadyDark, alpha: 0.15, over: p.tradeCanvasDark)
        let tintWashLight = composite(p.tradeReadyLight, alpha: 0.12, over: p.white)
        let heroDiscLight = composite(p.white, alpha: 0.18, over: p.tradeReadyFillLight)
        let heroDiscDark = composite(p.white, alpha: 0.18, over: p.tradeReadyFillDark)
        return [
            // Tint as text/icon (links, toolbar items, `.foregroundStyle(Color.tradeReady)`).
            .init(name: "tint text on light canvas", foreground: p.tradeReadyLight, background: p.tradeCanvasLight, role: .text),
            .init(name: "tint text on white", foreground: p.tradeReadyLight, background: p.white, role: .text),
            .init(name: "tint text on light grouped background", foreground: p.tradeReadyLight, background: p.systemGroupedLight, role: .text),
            .init(name: "tint text on 12% tint wash (light)", foreground: p.tradeReadyLight, background: tintWashLight, role: .text),
            .init(name: "tint text on dark canvas", foreground: p.tradeReadyDark, background: p.tradeCanvasDark, role: .text),
            .init(name: "tint text on dark system background", foreground: p.tradeReadyDark, background: p.systemBackgroundDark, role: .text),
            .init(name: "tint text on dark list row", foreground: p.tradeReadyDark, background: p.secondaryGroupedDark, role: .text),
            .init(name: "tint text on dark sheet list row", foreground: p.tradeReadyDark, background: p.elevatedGroupedDark, role: .text),
            .init(name: "tint text on RN dark surface", foreground: p.tradeReadyDark, background: p.rnSurfaceDark, role: .text),
            .init(name: "tint text on 12% tint wash over dark canvas", foreground: p.tradeReadyDark, background: tintWashDarkCanvas, role: .text),
            .init(name: "tint text on 12% tint wash over dark list row", foreground: p.tradeReadyDark, background: tintWashDarkRow, role: .text),
            .init(name: "tint text on .bordered button wash (dark)", foreground: p.tradeReadyDark, background: borderedDark, role: .text),
            // Tint as non-text UI (toggles, chart bars, dots, strokes, map route).
            .init(name: "tint UI on dark canvas", foreground: p.tradeReadyDark, background: p.tradeCanvasDark, role: .nonText),
            .init(name: "tint UI on dark list row", foreground: p.tradeReadyDark, background: p.secondaryGroupedDark, role: .nonText),
            .init(name: "tint UI on light canvas", foreground: p.tradeReadyLight, background: p.tradeCanvasLight, role: .nonText),
            // Fill under white text/icons.
            .init(name: "white text on fill (light)", foreground: p.white, background: p.tradeReadyFillLight, role: .text),
            .init(name: "white text on fill (dark)", foreground: p.white, background: p.tradeReadyFillDark, role: .text),
            // The fill itself is the selected-state cue in dark mode.
            .init(name: "fill UI on dark canvas", foreground: p.tradeReadyFillDark, background: p.tradeCanvasDark, role: .nonText),
            .init(name: "fill UI on dark system background", foreground: p.tradeReadyFillDark, background: p.systemBackgroundDark, role: .nonText),
            .init(name: "fill UI on dark list row", foreground: p.tradeReadyFillDark, background: p.secondaryGroupedDark, role: .nonText),
            .init(name: "fill UI on dark sheet list row", foreground: p.tradeReadyFillDark, background: p.elevatedGroupedDark, role: .nonText),
            .init(name: "fill UI on light canvas", foreground: p.tradeReadyFillLight, background: p.tradeCanvasLight, role: .nonText),
            // Today hero card (fix round 1, I2): the subtitle is solid white;
            // at 85% it measured 3.76:1 on the dark fill.
            .init(name: "Today hero subtitle: white caption on fill (light)", foreground: p.white, background: p.tradeReadyFillLight, role: .text),
            .init(name: "Today hero subtitle: white caption on fill (dark)", foreground: p.white, background: p.tradeReadyFillDark, role: .text),
            // Today hero icon: a white glyph on an 18% white disc over the fill.
            .init(name: "Today hero icon: white on 18% white disc over fill (light)", foreground: p.white, background: heroDiscLight, role: .nonText),
            .init(name: "Today hero icon: white on 18% white disc over fill (dark)", foreground: p.white, background: heroDiscDark, role: .nonText),
            // Clock-out button (11.10b A18): white label on the danger fill.
            .init(name: "white text on danger fill (light)", foreground: p.white, background: p.dangerFillLight, role: .text),
            .init(name: "white text on danger fill (dark)", foreground: p.white, background: p.dangerFillDark, role: .text),
            .init(name: "danger fill UI on light list row", foreground: p.dangerFillLight, background: p.white, role: .nonText),
            .init(name: "danger fill UI on dark canvas", foreground: p.dangerFillDark, background: p.tradeCanvasDark, role: .nonText),
            .init(name: "danger fill UI on dark list row", foreground: p.dangerFillDark, background: p.secondaryGroupedDark, role: .nonText),
            .init(name: "danger fill UI on dark sheet list row", foreground: p.dangerFillDark, background: p.elevatedGroupedDark, role: .nonText),
            // Error and destructive text (11.10b A28): RN's danger color, on
            // every ground a message or destructive row sits on.
            .init(name: "danger text on white list row", foreground: p.dangerTextLight, background: p.white, role: .text),
            .init(name: "danger text on light grouped background", foreground: p.dangerTextLight, background: p.systemGroupedLight, role: .text),
            .init(name: "danger text on light canvas", foreground: p.dangerTextLight, background: p.tradeCanvasLight, role: .text),
            .init(name: "danger text on dark system background", foreground: p.dangerTextDark, background: p.systemBackgroundDark, role: .text),
            .init(name: "danger text on dark canvas", foreground: p.dangerTextDark, background: p.tradeCanvasDark, role: .text),
            .init(name: "danger text on dark list row", foreground: p.dangerTextDark, background: p.secondaryGroupedDark, role: .text),
            .init(name: "danger text on dark sheet list row", foreground: p.dangerTextDark, background: p.elevatedGroupedDark, role: .text),
            .init(name: "danger text on RN dark surface", foreground: p.dangerTextDark, background: p.rnSurfaceDark, role: .text),
            // Route map stop number (11.10b A26): white on a fill capsule, not on the map.
            .init(name: "route map stop number: white on fill (dark)", foreground: p.white, background: p.tradeReadyFillDark, role: .text),
        ]
    }()

    // MARK: Motion

    /// Reduce Motion policy for custom animations: with the setting on, a
    /// custom animation or animated scroll is applied without motion (the
    /// state change still happens). System transitions are left to UIKit.
    static func allowsCustomMotion(reduceMotion: Bool) -> Bool {
        !reduceMotion
    }

    // MARK: Touch targets

    /// Apple HIG minimum hit target, in points.
    static let minimumTouchTarget: Double = 44

    /// The Today week strip (fix round 1, I1). Seven day columns and two
    /// 44pt arrows share one row, so the strip is capped at AX1 and the day
    /// circle is clamped: an `@ScaledMetric` reaches ~98pt at AX5 and would
    /// widen every column past the card.
    enum WeekStrip {
        static let dayColumns: Double = 7
        static let arrowCount: Double = 2
        /// `TodayView`'s `.padding()` (16pt each side) plus the strip card's
        /// 4pt horizontal padding each side.
        static let horizontalChrome: Double = 16 * 2 + 4 * 2
        /// The narrowest supported iPhone width (iPhone SE 2nd/3rd generation,
        /// 12/13 mini), in points.
        static let narrowestPhoneWidth: Double = 375
        /// Default (Large) circle size; the `@ScaledMetric` base value.
        static let dayCircleDefault: Double = 30
        /// The largest circle that still fits seven columns beside both arrows
        /// on the narrowest phone.
        static let dayCircleMaximum: Double = 34

        /// The width one day column gets on a phone `screenWidth` points wide.
        static func dayColumnWidth(screenWidth: Double) -> Double {
            (screenWidth - horizontalChrome - arrowCount * minimumTouchTarget) / dayColumns
        }

        /// The circle size to draw for a scaled metric value.
        static func dayCircleSize(scaled: Double) -> Double {
            min(scaled, dayCircleMaximum)
        }
    }

    /// Job-photo thumbnails (11.10b A16). The side scales with the caption so
    /// the "Waiting for download" text is not clipped, and is clamped so a
    /// thumbnail stays well inside a 375pt phone at AX5.
    enum PhotoThumbnail {
        static let sideDefault: Double = 112
        static let sideMaximum: Double = 168

        static func side(scaled: Double) -> Double {
            min(max(scaled, sideDefault), sideMaximum)
        }
    }

    // MARK: Chart summaries (11.10b A15)

    /// One value of one series at one chart position ("Income", "$1,200.00").
    struct ChartSeriesValue: Equatable {
        let series: String
        let value: String
    }

    /// One chart position: its axis label ("Apr"), the series values drawn
    /// there, and an optional trailing note ("down 12% from the previous month").
    struct ChartPoint: Equatable {
        let label: String
        let values: [ChartSeriesValue]
        var note: String? = nil
    }

    private static let spokenMonths: [String: String] = [
        "Jan": "January", "Feb": "February", "Mar": "March", "Apr": "April",
        "May": "May", "Jun": "June", "Jul": "July", "Aug": "August",
        "Sep": "September", "Oct": "October", "Nov": "November", "Dec": "December",
    ]

    /// The full month name for a chart's three-letter axis label (RN
    /// `monthNames`), so VoiceOver does not spell "Jun" or read "May" as a verb
    /// in isolation. Anything else is returned unchanged.
    static func spokenMonth(_ label: String) -> String {
        spokenMonths[label.trimmingCharacters(in: .whitespaces)] ?? label
    }

    /// The VoiceOver value for a bar chart: every position in order, with
    /// each series named, for example
    /// "April: Income $1,200.00, Expenses $300.00. May: …". A chart whose
    /// individual bars and month letters are read one by one tells a
    /// VoiceOver user nothing; this reads the same figures the bars draw.
    static func chartSummary(_ points: [ChartPoint]) -> String {
        guard !points.isEmpty else { return "No data" }
        return points.map { point in
            let values = point.values.map { $0.series.isEmpty ? $0.value : "\($0.series) \($0.value)" }
            var text = "\(spokenMonth(point.label)): \(values.joined(separator: ", "))"
            if let note = point.note, !note.isEmpty { text += ", \(note)" }
            return text
        }.joined(separator: ". ") + "."
    }

    /// Spoken form of a month-over-month badge ("↓12" → "down 12% from the
    /// previous month"); nil for no change, like the blank badge.
    static func changePhrase(percent: Int?) -> String? {
        guard let percent, percent != 0 else { return nil }
        return "\(percent < 0 ? "down" : "up") \(abs(percent))% from the previous month"
    }

    // MARK: Labels

    /// VoiceOver labels for icon-only controls. `rnSource` names the RN file
    /// whose `accessibilityLabel` the text must match; nil marks a native-only
    /// control with no RN counterpart (recorded in contract §12).
    struct LabelEntry: Equatable {
        let key: String
        let text: String
        let rnSource: String?
    }

    enum Label {
        static let addJob = "Add new job"
        static let addInvoice = "Add new invoice"
        static let addCustomer = "Add new customer"
        static let addMaintenancePlan = "Add maintenance plan"
        /// RN has a text "Reset to scheduled time order" button instead of a menu.
        static let routeOrderMenu = "Route order options"
        static let moveStopUp = "Move stop up"
        static let moveStopDown = "Move stop down"
        /// RN `TaxSetAsideCard` labels its settings button with this exact text
        /// and hides the figure; native keeps the label and exposes the reserve
        /// as the accessibility value (fix round 1, I3).
        static let taxSetAsideOpen = "Tax set-aside — open settings"
        /// RN `KeyboardDoneBar`'s "Done" button (11.10b A24): the bar above a
        /// pad or multi-line keyboard, which has no key that dismisses it.
        static let dismissKeyboard = "Dismiss keyboard"

        /// RN `CustomerDetailScreen` labels its contact actions
        /// `Call ${name}` / `Email ${name}`; RN has no text action there, so
        /// `Text ${name}` follows the same pattern. An empty name falls back to
        /// "customer".
        static func contact(_ verb: ContactVerb, name: String) -> String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(verb.rawValue) \(trimmed.isEmpty ? "customer" : trimmed)"
        }

        /// RN `TodayScreen` labels the job card's action `On my way to
        /// ${job.customerName}`. Native uses it for the nested button and for
        /// the card's VoiceOver custom action (11.10b A13).
        static func onMyWay(customerName: String) -> String {
            "On my way to \(customerName)"
        }

        /// A Money chart's element label (native only; RN charts have no
        /// accessibility label). The figures are the accessibility value.
        static func chart(title: String) -> String {
            "\(title) chart"
        }
    }

    /// Money cards whose RN component sets no `accessibilityLabel`, so RN
    /// VoiceOver reads their title and figures. Native combines the card's text
    /// into one button element and must not replace it with a bare title.
    static let moneyCardsReadInFull: [(card: String, rnSource: String)] = [
        ("NativeMoneyMileageCardView", "components/money/MileageCard.tsx"),
        ("NativeMoneyPricebookCardView", "components/money/PricebookCard.tsx"),
    ]

    enum ContactVerb: String, CaseIterable {
        case call = "Call"
        case text = "Text"
        case email = "Email"
    }

    static let labelCatalog: [LabelEntry] = [
        .init(key: "addJob", text: Label.addJob, rnSource: "screens/JobsScreen.tsx"),
        .init(key: "addInvoice", text: Label.addInvoice, rnSource: "screens/InvoicesScreen.tsx"),
        .init(key: "addCustomer", text: Label.addCustomer, rnSource: "screens/CustomersScreen.tsx"),
        .init(key: "addMaintenancePlan", text: Label.addMaintenancePlan, rnSource: "screens/RecurringInvoicesScreen.tsx"),
        .init(key: "routeOrderMenu", text: Label.routeOrderMenu, rnSource: nil),
        .init(key: "moveStopUp", text: Label.moveStopUp, rnSource: "screens/RouteScreen.tsx"),
        .init(key: "moveStopDown", text: Label.moveStopDown, rnSource: "screens/RouteScreen.tsx"),
        .init(key: "taxSetAsideOpen", text: Label.taxSetAsideOpen, rnSource: "components/money/TaxSetAsideCard.tsx"),
        .init(key: "dismissKeyboard", text: Label.dismissKeyboard, rnSource: "components/KeyboardDoneBar.tsx"),
        // Labelled before 11.10a; kept in the catalog so parity stays proven.
        .init(key: "openCalendar", text: "Open calendar", rnSource: "screens/TodayScreen.tsx"),
        .init(key: "searchEverything", text: "Search everything", rnSource: "screens/TodayScreen.tsx"),
        .init(key: "openSettings", text: "Open settings", rnSource: "screens/TodayScreen.tsx"),
        .init(key: "previousWeek", text: "Previous week", rnSource: "screens/TodayScreen.tsx"),
        .init(key: "nextWeek", text: "Next week", rnSource: "screens/TodayScreen.tsx"),
        .init(key: "chatInput", text: "Chat message input", rnSource: "screens/ChatScreen.tsx"),
        .init(key: "sendMessage", text: "Send message", rnSource: "screens/ChatScreen.tsx"),
    ]
}
