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
        /// Error and destructive text (11.10b A28, darkened by A29). Light
        /// `#a63c27` is RN's `lightColors.danger` rust `#b8432b` darkened so it
        /// holds 4.5:1 on the 13% status washes too (`#b8432b` measured 4.05:1
        /// on a 13% wash over the grouped background). System red text
        /// measured 3.55:1 on a white list row.
        static let dangerTextLight = RGB(red: 0.650, green: 0.237, blue: 0.152)
        /// Dark `#ee917a`, native only: RN's dark danger `#e06a4f` measures
        /// 4.21:1 on a sheet list row `#2c2c2e`.
        static let dangerTextDark = RGB(red: 0.934, green: 0.567, blue: 0.480)

        // Semantic text colors (11.10b A29). The system hues fail text AA in
        // light mode (system green on white measures 2.22:1), so each light
        // variant is the system hue darkened until it holds 4.5:1 on every
        // light ground and its own 13% wash. Each dark variant is the system
        // dark value where that already passes, otherwise a lighter tint of
        // the same hue. Native difference: RN uses its own palette here.

        /// Success (paid, active, synced). Dark is system green `#30d158`.
        static let successTextLight = RGB(red: 0.112, green: 0.429, blue: 0.192)
        static let successTextDark = RGB(red: 0.188, green: 0.820, blue: 0.345)
        /// Warning (overdue, pending, validation hints). Dark is system orange `#ff9f0a`.
        static let warningTextLight = RGB(red: 0.550, green: 0.321, blue: 0.000)
        static let warningTextDark = RGB(red: 1.000, green: 0.624, blue: 0.039)
        /// Information (the lead status, open invoices, portal changes). Native
        /// dark: system blue `#0a84ff` measures 3.82:1 on a sheet list row.
        static let infoTextLight = RGB(red: 0.000, green: 0.361, blue: 0.755)
        static let infoTextDark = RGB(red: 0.366, green: 0.682, blue: 1.000)
        /// The approved status. Dark is system mint `#63e6e2`.
        static let mintTextLight = RGB(red: 0.000, green: 0.421, blue: 0.402)
        static let mintTextDark = RGB(red: 0.388, green: 0.902, blue: 0.886)
        /// The scheduled status. Light system indigo `#5856d6` measures 4.25:1
        /// on its wash; native dark: system indigo `#5e5ce6` measures 2.75:1 on
        /// a sheet list row.
        static let indigoTextLight = RGB(red: 0.321, green: 0.314, blue: 0.780)
        static let indigoTextDark = RGB(red: 0.640, green: 0.636, blue: 0.944)
        /// The in-progress status and missing-job booking requests. Native dark:
        /// system purple `#bf5af2` measures 3.96:1 on a sheet list row.
        static let purpleTextLight = RGB(red: 0.525, green: 0.246, blue: 0.666)
        static let purpleTextDark = RGB(red: 0.828, green: 0.557, blue: 0.965)
        /// The invoiced status. Dark is system cyan `#64d2ff`.
        static let cyanTextLight = RGB(red: 0.116, green: 0.400, blue: 0.532)
        static let cyanTextDark = RGB(red: 0.392, green: 0.824, blue: 1.000)

        /// Swipe-action fills under white text and glyphs (A29): system green
        /// and orange measure 2.22:1 and 2.20:1 under white. Each dark variant
        /// also stays at 3:1 or better on the dark list rows.
        static let successFillLight = RGB(red: 0.135, green: 0.515, blue: 0.230)
        static let successFillDark = RGB(red: 0.139, green: 0.530, blue: 0.237)
        static let warningFillLight = RGB(red: 0.655, green: 0.383, blue: 0.000)
        static let warningFillDark = RGB(red: 0.674, green: 0.394, blue: 0.000)
    }

    // MARK: Semantic color tokens (A28, A29)

    struct SemanticColorToken: Equatable {
        enum Kind: Equatable {
            /// Text, glyphs and other foreground marks, including tinted washes.
            case text
            /// A filled surface under white text or glyphs.
            case fill
        }
        /// The `Color` token in `N/Models.swift`.
        let name: String
        let kind: Kind
        let light: RGB
        let dark: RGB
    }

    /// Every semantic token the views may use in place of a system hue. The
    /// host suite checks each one's literals in `N/Models.swift` and proves each
    /// pairing below.
    static let semanticColorTokens: [SemanticColorToken] = {
        let p = Palette.self
        return [
            .init(name: "tradeDangerText", kind: .text, light: p.dangerTextLight, dark: p.dangerTextDark),
            .init(name: "tradeSuccessText", kind: .text, light: p.successTextLight, dark: p.successTextDark),
            .init(name: "tradeWarningText", kind: .text, light: p.warningTextLight, dark: p.warningTextDark),
            .init(name: "tradeInfoText", kind: .text, light: p.infoTextLight, dark: p.infoTextDark),
            .init(name: "tradeMintText", kind: .text, light: p.mintTextLight, dark: p.mintTextDark),
            .init(name: "tradeIndigoText", kind: .text, light: p.indigoTextLight, dark: p.indigoTextDark),
            .init(name: "tradePurpleText", kind: .text, light: p.purpleTextLight, dark: p.purpleTextDark),
            .init(name: "tradeCyanText", kind: .text, light: p.cyanTextLight, dark: p.cyanTextDark),
            .init(name: "tradeDangerFill", kind: .fill, light: p.dangerFillLight, dark: p.dangerFillDark),
            .init(name: "tradeSuccessFill", kind: .fill, light: p.successFillLight, dark: p.successFillDark),
            .init(name: "tradeWarningFill", kind: .fill, light: p.warningFillLight, dark: p.warningFillDark),
        ]
    }()

    /// The strongest tinted wash a semantic text color sits on: the status
    /// badges use 12% and 13%, the Today and paywall chips 8% to 11%.
    static let maximumTextWashAlpha = 0.13

    /// The system `.bordered` button wash: its tint at 15%. The old destructive
    /// "Decline" measured 2.90:1, system red on this wash (fix round 1, I1).
    static let borderedWashAlpha = 0.15

    /// The grounds semantic text sits on, by appearance.
    static let lightTextGrounds: [(name: String, color: RGB)] = [
        ("white list row", Palette.white),
        ("light grouped background", Palette.systemGroupedLight),
        ("light canvas", Palette.tradeCanvasLight),
    ]
    static let darkTextGrounds: [(name: String, color: RGB)] = [
        ("dark system background", Palette.systemBackgroundDark),
        ("dark list row", Palette.secondaryGroupedDark),
        ("dark sheet list row", Palette.elevatedGroupedDark),
        ("dark canvas", Palette.tradeCanvasDark),
        ("RN dark surface", Palette.rnSurfaceDark),
    ]

    static let borderedDangerRequirements: [ContrastRequirement] = {
        let p = Palette.self
        let grounds: [(String, RGB, RGB, RGB)] = [
            ("white list row", p.white, p.dangerTextLight, p.systemRedLight),
            ("light grouped background", p.systemGroupedLight, p.dangerTextLight, p.systemRedLight),
            ("dark list row", p.secondaryGroupedDark, p.dangerTextDark, p.systemRedDark),
            ("dark sheet list row", p.elevatedGroupedDark, p.dangerTextDark, p.systemRedDark),
        ]
        return grounds.flatMap { name, ground, text, red in [
            ContrastRequirement(name: "danger text on its 15% .bordered wash over \(name)", foreground: text,
                                background: composite(text, alpha: borderedWashAlpha, over: ground), role: .text),
            ContrastRequirement(name: "danger text on a 15% system-red .bordered wash over \(name)", foreground: text,
                                background: composite(red, alpha: borderedWashAlpha, over: ground), role: .text),
        ] }
    }()

    /// Each text token on each ground and on its own strongest wash over that
    /// ground; each fill under white and against the list rows it sits in.
    static let semanticColorRequirements: [ContrastRequirement] = {
        let label: (String) -> String = { name in
            // "tradeSuccessText" -> "success text"
            let stem = name.dropFirst("trade".count)
            var words = ""
            for char in stem {
                if char.isUppercase, !words.isEmpty { words += " " }
                words += char.lowercased()
            }
            return words
        }
        var rows: [ContrastRequirement] = []
        for token in semanticColorTokens {
            let name = label(token.name)
            switch token.kind {
            case .text:
                for (appearance, color, grounds) in [("light", token.light, lightTextGrounds), ("dark", token.dark, darkTextGrounds)] {
                    for ground in grounds {
                        rows.append(.init(name: "\(name) on \(ground.name)", foreground: color, background: ground.color, role: .text))
                        let wash = composite(color, alpha: maximumTextWashAlpha, over: ground.color)
                        rows.append(.init(name: "\(name) on its 13% wash over \(ground.name) (\(appearance))", foreground: color, background: wash, role: .text))
                    }
                }
            case .fill:
                rows.append(.init(name: "white text on \(name) (light)", foreground: Palette.white, background: token.light, role: .text))
                rows.append(.init(name: "white text on \(name) (dark)", foreground: Palette.white, background: token.dark, role: .text))
                rows.append(.init(name: "\(name) UI on white list row", foreground: token.light, background: Palette.white, role: .nonText))
                for ground in darkTextGrounds {
                    rows.append(.init(name: "\(name) UI on \(ground.name)", foreground: token.dark, background: ground.color, role: .nonText))
                }
            }
        }
        return rows
    }()

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
            // The clock-out button (A18) and the destructive swipes (A29), white
            // on the danger fill, and every semantic text color (A28, A29):
            // `semanticColorRequirements`.
            // The bordered booking "Decline" (fix round 1, I1): danger text on the
            // 15% wash of its own tint, and on system red's in case the role
            // keeps the system wash.
        ] + borderedDangerRequirements + [
            // The coach user bubble (fix round 1, m1): primary text on an 18% tint wash.
            .init(name: "primary text on the 18% coach user bubble (light)", foreground: RGB(red: 0, green: 0, blue: 0),
                  background: composite(p.tradeReadyLight, alpha: 0.18, over: p.tradeCanvasLight), role: .text),
            .init(name: "primary text on the 18% coach user bubble (dark)", foreground: p.white,
                  background: composite(p.tradeReadyDark, alpha: 0.18, over: p.tradeCanvasDark), role: .text),
            // Route map stop number (11.10b A26): white on a fill capsule, not on the map.
            .init(name: "route map stop number: white on fill (dark)", foreground: p.white, background: p.tradeReadyFillDark, role: .text),
        ] + semanticColorRequirements
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

    /// An inline caption link inside a card (the Today "On my way"; fix round
    /// 1, m7). Like RN's `hitSlop`, the hit shape is padded outward and the
    /// padding is taken back out of layout, so the card row keeps its height.
    enum InlineLink {
        /// Outset above and below the caption line.
        static let verticalOutset: Double = 16
        /// The caption line at the smallest Dynamic Type size (11pt text,
        /// about 13pt of line); larger sizes only grow the target.
        static let smallestCaptionLineHeight: Double = 13
    }

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
