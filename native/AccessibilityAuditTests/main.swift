import Foundation

// Task 11.10a host tests: accessibility audit and remediation (H1; contract
// §12 "Accessibility baseline (H1)" and its 11.10a follow-up).
//
// - Contrast: WCAG luminance math, every pairing in
//   `NativeAccessibilityAudit.contrastRequirements`, and the palette literals
//   actually shipped in `N/Models.swift` and the `AccentColor` asset.
// - Labels: the icon-only label catalog matches RN `accessibilityLabel` text in
//   the working tree, and every catalog entry is used by a native view.
// - Source scans over every `.swift` file under `N/`:
//   * no icon-only Button/Menu/NavigationLink/ShareLink/Link without an
//     accessibilityLabel (each construct is scanned to its end, including its
//     modifier chain);
//   * every custom animation honors Reduce Motion;
//   * no fixed-point `.font(.system(size:))` outside the widget views;
//   * white text never sits on the dark-mode tint (prominent buttons and
//     opaque tint fills use `tradeReadyFill`);
//   * the fixed-frame, touch-target and focus-order fixes are in place.
// Known sites are looked up by marker; a missing marker fails loudly.
// VoiceOver order, AX5 layout and Switch Control stay Phase 12 device rows.
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

func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.01, _ label: String) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        print("FAIL: \(label)\n  expected: \(expected) ± \(tolerance)\n  actual:   \(actual)")
    }
}

typealias Audit = NativeAccessibilityAudit
typealias RGB = NativeAccessibilityAudit.RGB

// MARK: - Source model

// `SourceFile`, `SourceMasker`, `loadSources`, `read`, `functionBody` and
// `structText` live in `native/HostTestSupport/SwiftSourceScan.swift`
// (shared with the 11.11 layout-metrics suite).

// MARK: - Control scan

/// One interactive construct (`Button`, `Menu`, `NavigationLink`, `ShareLink`,
/// `Link`) scanned from its keyword to the end of its modifier chain.
struct ControlConstruct {
    let file: SourceFile
    let kind: String
    let start: Int
    /// Where the construct's own modifier chain begins (after its trailing
    /// closures): content-closure modifiers belong to nested views.
    let chainStart: Int
    let end: Int
    let hasTitle: Bool
    let labelCode: String?
    let labelRange: Range<Int>?

    var line: Int { file.line(of: start) }
    var code: String { file.codeSlice(start..<end) }
    var raw: String { file.rawSlice(start..<end) }
    var location: String { "\(displayPath(file)):\(line)" }

    static let nonTextViews: Set<String> = [
        "Image", "HStack", "VStack", "ZStack", "Group", "Spacer", "Circle", "Rectangle",
        "RoundedRectangle", "Capsule", "ProgressView", "Color", "EmptyView", "Divider", "AnyView",
        "UIImage", "Font", "CGSize", "EdgeInsets", "Animation", "LinearGradient", "Angle",
    ]

    /// A text title the control can be announced and listed by: a string or
    /// value title, or a `Text`/`Label` in its label closure. The iPad
    /// keyboard-shortcut HUD lists a shortcut under this title (11.10b).
    var hasTextTitle: Bool {
        if hasTitle { return true }
        guard let labelCode else { return false }
        return labelCode.contains("Text(") || labelCode.contains("Label(")
    }

    /// Label is only images/shapes (no text-bearing or custom view).
    var isIconOnly: Bool {
        guard !hasTitle, let labelCode else { return false }
        guard labelCode.contains("Image(") else { return false }
        let label = SourceFile(relativePath: "", text: labelCode)
        // Capitalized identifiers followed by `(` or ` {` are view calls.
        var k = 0
        let chars = label.code
        while k < chars.count {
            if chars[k].isUppercase, k == 0 || !(chars[k - 1].isLetter || chars[k - 1].isNumber || chars[k - 1] == "_" || chars[k - 1] == ".") ,
               let (name, after) = label.identifier(at: k) {
                let next = label.skipSpace(after)
                if next < chars.count, chars[next] == "(" || chars[next] == "{" {
                    if !ControlConstruct.nonTextViews.contains(name) { return false }
                }
                k = after
                continue
            }
            k += 1
        }
        return true
    }

    /// A non-empty `.accessibilityLabel(...)` on the construct's own modifier
    /// chain or inside its label closure. A label on a view nested in the
    /// action or content closure (a `Button` inside a `Menu`) does not label
    /// the construct, and `.accessibilityLabel("")` labels nothing.
    var hasAccessibilityLabel: Bool {
        var regions: [Range<Int>] = [chainStart..<end]
        if let labelRange { regions.append(labelRange) }
        for hit in file.occurrences(of: "accessibilityLabel") where hit > 0 && file.code[hit - 1] == "." {
            guard regions.contains(where: { $0.contains(hit) }) else { continue }
            let open = file.skipSpace(hit + "accessibilityLabel".count)
            guard open < file.code.count, file.code[open] == "(", let close = file.matching(open) else { continue }
            let argument = file.rawSlice((open + 1)..<close).trimmingCharacters(in: .whitespacesAndNewlines)
            if argument.isEmpty || argument == "\"\"" || argument == "Text(\"\")" { continue }
            return true
        }
        return false
    }
}

func scanControls(_ file: SourceFile) -> [ControlConstruct] {
    var result: [ControlConstruct] = []
    for kind in ["Button", "Menu", "NavigationLink", "ShareLink", "Link"] {
        for start in file.occurrences(of: kind) {
            // Skip member access (`.Button`) and type positions.
            if start > 0, file.code[start - 1] == "." { continue }
            var k = start + kind.count
            let open = file.skipSpace(k)
            guard open < file.code.count, file.code[open] == "(" || file.code[open] == "{" else { continue }
            var args = ""
            var argsRange: Range<Int>? = nil
            if file.code[open] == "(" {
                guard let close = file.matching(open) else { continue }
                args = file.codeSlice((open + 1)..<close)
                argsRange = (open + 1)..<close
                k = close + 1
            } else {
                k = open
            }
            let trailing = file.trailingClosuresEnd(from: k)
            let end = file.chainEnd(from: trailing.end)

            // Title: a string literal or an unlabelled non-closure first argument.
            let trimmedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
            var hasTitle = false
            if !trimmedArgs.isEmpty {
                let argFile = SourceFile(relativePath: "", text: trimmedArgs)
                if trimmedArgs.hasPrefix("\"") {
                    hasTitle = true
                } else if let (_, after) = argFile.identifier(at: 0) {
                    let next = argFile.skipSpace(after)
                    let isLabelled = next < argFile.code.count && argFile.code[next] == ":"
                    hasTitle = !isLabelled
                } else if !trimmedArgs.hasPrefix("{") {
                    hasTitle = true
                }
            }

            // Label closure.
            var labelRange: Range<Int>? = nil
            if let labelled = trailing.closures.first(where: { $0.label == "label" }) {
                labelRange = labelled.range
            } else if let argsRange, let labelIndex = args.range(of: "label:") {
                let offset = args.distance(from: args.startIndex, to: labelIndex.lowerBound)
                let brace = file.skipSpace(argsRange.lowerBound + offset + "label:".count)
                if brace < file.code.count, file.code[brace] == "{", let close = file.matching(brace) {
                    labelRange = (brace + 1)..<close
                }
            } else if !trimmedArgs.isEmpty, !hasTitle, let first = trailing.closures.first, first.label == nil {
                labelRange = first.range
            }
            if trailing.closures.isEmpty && argsRange == nil { continue }
            let labelCode = labelRange.map { file.rawSlice($0) }
            result.append(ControlConstruct(
                file: file, kind: kind, start: start, chainStart: trailing.end, end: end,
                hasTitle: hasTitle, labelCode: labelCode, labelRange: labelRange
            ))
        }
    }
    return result.sorted { $0.start < $1.start }
}

// MARK: - Tests: contrast

func testContrastMath() {
    let black = RGB(red: 0, green: 0, blue: 0)
    let white = Audit.Palette.white
    expectClose(Audit.contrastRatio(white, black), 21, "white on black is 21:1")
    expectClose(Audit.contrastRatio(black, white), 21, "contrast is symmetric")
    expectClose(Audit.contrastRatio(white, white), 1, "same color is 1:1")
    expectClose(Audit.relativeLuminance(white), 1, tolerance: 0.0001, "white luminance")
    expectClose(Audit.relativeLuminance(black), 0, tolerance: 0.0001, "black luminance")
    // WCAG reference: #777777 on white is 4.48:1.
    expectClose(Audit.contrastRatio(RGB(hex: "#777777")!, white), 4.48, "#777 on white (WCAG reference)")
    expectEqual(RGB(hex: "#1d5c9e"), RGB(red: 29.0 / 255, green: 92.0 / 255, blue: 158.0 / 255), "hex parse")
    expectEqual(RGB(hex: "5b9bdb"), RGB(red: 91.0 / 255, green: 155.0 / 255, blue: 219.0 / 255), "hex parse without #")
    expect(RGB(hex: "#12345") == nil, "short hex rejected")
    expect(RGB(hex: "#zzzzzz") == nil, "non-hex rejected")
    let half = Audit.composite(white, alpha: 0.5, over: black)
    expectClose(half.red, 0.5, tolerance: 0.0001, "composite red")
    expectClose(half.blue, 0.5, tolerance: 0.0001, "composite blue")

    // Contract §12 baseline, reproduced from the same literals.
    let p = Audit.Palette.self
    expectClose(Audit.contrastRatio(p.tradeReadyLight, p.white), 6.82, "baseline: tradeReady on white 6.82")
    expectClose(Audit.contrastRatio(p.tradeReadyLight, p.tradeCanvasLight), 6.24, "baseline: tradeReady on light canvas 6.24")
    let legacyDark = Audit.contrastRatio(p.tradeReadyLight, p.tradeCanvasDark)
    expectClose(legacyDark, 2.61, "baseline: old tradeReady on dark canvas 2.61 (the finding)")
    expect(legacyDark < Audit.Threshold.nonText, "baseline finding fails even the 3:1 UI minimum")
    // Why a separate fill exists: RN's dark accent under white text.
    let rnDarkUnderWhite = Audit.contrastRatio(p.white, p.tradeReadyDark)
    expect(rnDarkUnderWhite < Audit.Threshold.text, "white on RN dark accent fails text AA (\(rnDarkUnderWhite))")
    // The dark tint is RN `darkColors.accent` to three decimals.
    let rnDark = RGB(hex: "#5b9bdb")!
    expectClose(p.tradeReadyDark.red, rnDark.red, tolerance: 0.001, "dark tint red = RN")
    expectClose(p.tradeReadyDark.green, rnDark.green, tolerance: 0.001, "dark tint green = RN")
    expectClose(p.tradeReadyDark.blue, rnDark.blue, tolerance: 0.001, "dark tint blue = RN")
    expectEqual(p.tradeReadyFillLight, p.tradeReadyLight, "light fill is the unchanged light tint")
}

func testContrastRequirements() {
    let requirements = Audit.contrastRequirements
    expect(requirements.count >= 20, "contrast requirement table is populated (\(requirements.count))")
    expectEqual(Set(requirements.map(\.name)).count, requirements.count, "requirement names are unique")
    for requirement in requirements {
        let ratio = Audit.contrastRatio(requirement.foreground, requirement.background)
        expect(
            ratio >= requirement.role.minimum,
            "\(requirement.name): \(String(format: "%.2f", ratio)):1 ≥ \(requirement.role.minimum):1"
        )
    }
    // Both roles are covered in dark mode.
    expect(requirements.contains { $0.role == .text && $0.name.contains("dark canvas") }, "dark canvas text row present")
    expect(requirements.contains { $0.role == .nonText && $0.name.contains("dark canvas") }, "dark canvas UI row present")
    expect(requirements.contains { $0.name == "white text on fill (dark)" }, "white-on-fill dark row present")
    expect(requirements.contains { $0.name == "Today hero subtitle: white caption on fill (dark)" }, "hero subtitle row present")
    expect(requirements.contains { $0.name == "Today hero icon: white on 18% white disc over fill (dark)" }, "hero icon row present")
    // Fix round 1 (I2): the old 85% white subtitle failed on the dark fill.
    let p = Audit.Palette.self
    let oldSubtitle = Audit.composite(p.white, alpha: 0.85, over: p.tradeReadyFillDark)
    let oldRatio = Audit.contrastRatio(oldSubtitle, p.tradeReadyFillDark)
    expectClose(oldRatio, 3.76, "baseline: 85% white caption on the dark fill measured 3.76")
    expect(oldRatio < Audit.Threshold.text, "85% white text fails on the dark fill (why the subtitle is solid)")
}

/// No translucent white text or glyph outside the widget canvas: every white
/// foreground in `N/` sits on the fill or a photo scrim and must be solid, or be
/// added to `contrastRequirements` with its composite.
func testTranslucentWhite(sources: [SourceFile]) {
    let pattern = try! NSRegularExpression(pattern: #"foreground(?:Style|Color)\((?:Color)?\.white\.opacity\("#)
    for source in sources where !source.relativePath.hasPrefix("Widgets/") {
        let text = source.codeText
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            expect(false, "translucent white foreground at N/\(source.relativePath):\(source.line(of: match.range.location))")
        }
    }
    if let today = file(sources, "NativeTodayComponents.swift") {
        expect(String(today.raw).contains("Text(hero.subtitle).font(.caption).foregroundStyle(.white)"),
               "Today hero subtitle is solid white")
    }
}

// MARK: - Tests: Money card VoiceOver (fix round 1, I3)

func testMoneyCardLabels(root: URL, sources: [SourceFile]) {
    guard let money = file(sources, "NativeMoneyCards.swift") else { return }
    let text = String(money.raw)
    expect(!text.contains("\\(title), open"), "no card replaces its figures with \"{title}, open\"")
    let shell = structText(money, "NativeMoneyCard")
    let unlabelled = shell.range(of: "} else if let onOpen {").map { String(shell[$0.upperBound...].prefix(300)) } ?? ""
    expect(unlabelled.contains(".accessibilityElement(children: .combine)"), "openable card without an RN label reads its text in full")
    expect(unlabelled.contains(".accessibilityAddTraits(.isButton)"), "openable card keeps the button trait")
    let beforeElse = unlabelled.components(separatedBy: "} else {").first ?? ""
    expect(!beforeElse.contains(".accessibilityLabel("), "the read-in-full branch sets no label")
    let labelled = shell.range(of: "if let onOpen, let openLabel {").map { String(shell[$0.upperBound...].prefix(300)) } ?? ""
    expect(labelled.contains(".accessibilityLabel(openLabel)") && labelled.contains(".accessibilityValue(openValue"),
           "RN-labelled card carries the label and the figure as its value")

    for (card, rnPath) in Audit.moneyCardsReadInFull {
        guard let rn = read(root, rnPath) else { expect(false, "RN \(rnPath) readable"); continue }
        expect(!rn.contains("accessibilityLabel"), "RN parity: \(rnPath) sets no accessibilityLabel (VoiceOver reads the figures)")
        let view = structText(money, card)
        expect(!view.isEmpty, "N/NativeMoneyCards.swift: \(card) found")
        expect(view.contains("onOpen: onOpen") && !view.contains("openLabel:"), "\(card) is openable and reads in full")
    }
    let tax = structText(money, "NativeMoneyTaxCardView")
    expect(tax.contains("openLabel: NativeAccessibilityAudit.Label.taxSetAsideOpen"), "tax card uses RN's exact label")
    expect(tax.contains("openValue: card.reserveText"), "tax card exposes the reserve as the value")
}

/// Extracts `(red, green, blue)` literal triples from `UIColor(red:…)` /
/// `Color(red:…)` calls in `text`, in order.
func colorLiterals(in text: String) -> [RGB] {
    let pattern = #"(?:UI)?Color\(red: ([0-9.]+), green: ([0-9.]+), blue: ([0-9.]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
        guard let r = Double(ns.substring(with: match.range(at: 1))),
              let g = Double(ns.substring(with: match.range(at: 2))),
              let b = Double(ns.substring(with: match.range(at: 3))) else { return nil }
        return RGB(red: r, green: g, blue: b)
    }
}

/// The source line(s) that define `static let <name> =` inside the iOS branch
/// (dynamic) and the non-iOS fallback.
func paletteDefinitions(_ models: String, _ name: String) -> (ios: String?, fallback: String?) {
    guard let colorExtension = models.range(of: "extension Color {"),
          let iosStart = models.range(of: "#if os(iOS)", range: colorExtension.upperBound..<models.endIndex),
          let elseMark = models.range(of: "#else", range: iosStart.upperBound..<models.endIndex),
          let endMark = models.range(of: "#endif", range: elseMark.upperBound..<models.endIndex) else {
        return (nil, nil)
    }
    func line(in range: Range<String.Index>) -> String? {
        let block = String(models[range])
        return block.split(separator: "\n").first { $0.contains("static let \(name) =") }.map(String.init)
    }
    return (line(in: iosStart.upperBound..<elseMark.lowerBound), line(in: elseMark.upperBound..<endMark.lowerBound))
}

func testPaletteLiteralsShipped(root: URL) {
    guard let models = read(root, "native/TradeReadyNative/Models.swift") else {
        expect(false, "N/Models.swift readable"); return
    }
    let p = Audit.Palette.self
    let expectations: [(String, dark: RGB, light: RGB)] = [
        ("tradeReady", p.tradeReadyDark, p.tradeReadyLight),
        ("tradeReadyFill", p.tradeReadyFillDark, p.tradeReadyFillLight),
        ("tradeCanvas", p.tradeCanvasDark, p.tradeCanvasLight),
    ] + Audit.semanticColorTokens.map { ($0.name, dark: $0.dark, light: $0.light) }
    expect(expectations.count >= 14, "palette expectations cover the semantic tokens (\(expectations.count))")
    for (name, dark, light) in expectations {
        let defs = paletteDefinitions(models, name)
        guard let ios = defs.ios else { expect(false, "Models.swift: iOS definition of \(name) found"); continue }
        expect(ios.contains("userInterfaceStyle == .dark"), "\(name) is a dynamic (light/dark) color")
        let literals = colorLiterals(in: ios)
        expectEqual(literals.count, 2, "\(name): two literals (dark, light)")
        if literals.count == 2 {
            expectEqual(literals[0], dark, "\(name): shipped dark literal = audit palette")
            expectEqual(literals[1], light, "\(name): shipped light literal = audit palette")
        }
        guard let fallback = defs.fallback else { expect(false, "Models.swift: fallback definition of \(name) found"); continue }
        expectEqual(colorLiterals(in: fallback), [light], "\(name): non-iOS fallback is the light literal")
    }
    // The app-wide tint is the dynamic brand color.
    guard let app = read(root, "native/TradeReadyNative/TradeReadyNativeApp.swift") else {
        expect(false, "TradeReadyNativeApp.swift readable"); return
    }
    expect(app.contains(".tint(.tradeReady)"), "root view applies .tint(.tradeReady)")
}

func testAccentColorAsset(root: URL) {
    let path = "native/TradeReadyNative/Assets.xcassets/AccentColor.colorset/Contents.json"
    guard let text = read(root, path), let data = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let colors = json["colors"] as? [[String: Any]] else {
        expect(false, "AccentColor asset parses"); return
    }
    func rgb(_ entry: [String: Any]) -> RGB? {
        guard let color = entry["color"] as? [String: Any],
              let comps = color["components"] as? [String: Any],
              let r = Double(comps["red"] as? String ?? ""),
              let g = Double(comps["green"] as? String ?? ""),
              let b = Double(comps["blue"] as? String ?? "") else { return nil }
        return RGB(red: r, green: g, blue: b)
    }
    let isDark: ([String: Any]) -> Bool = { entry in
        ((entry["appearances"] as? [[String: String]]) ?? []).contains { $0["value"] == "dark" }
    }
    let light = colors.first { !isDark($0) }.flatMap(rgb)
    let dark = colors.first(where: isDark).flatMap(rgb)
    expectEqual(light, Audit.Palette.tradeReadyLight, "AccentColor any-appearance = tradeReady light")
    expectEqual(dark, Audit.Palette.tradeReadyDark, "AccentColor dark appearance = tradeReady dark")
}

// MARK: - Tests: labels

func testLabelCatalog(root: URL, sources: [SourceFile]) {
    let catalog = Audit.labelCatalog
    expectEqual(Set(catalog.map(\.key)).count, catalog.count, "catalog keys unique")
    expect(catalog.count >= 12, "catalog populated")
    let nativeCode = sources.map { String($0.raw) }.joined(separator: "\n")
    for entry in catalog {
        if let rnPath = entry.rnSource {
            guard let rn = read(root, rnPath) else { expect(false, "RN \(rnPath) readable for \(entry.key)"); continue }
            expect(rn.contains("accessibilityLabel=\"\(entry.text)\""),
                   "RN parity: \(rnPath) has accessibilityLabel=\"\(entry.text)\"")
        }
        let usesConstant = nativeCode.contains("NativeAccessibilityAudit.Label.\(entry.key)")
        let usesLiteral = nativeCode.contains(".accessibilityLabel(\"\(entry.text)\")")
        expect(usesConstant || usesLiteral, "native view uses label \(entry.key) (\"\(entry.text)\")")
    }
    // Contact actions: RN CustomerDetailScreen's `Call ${name}` / `Email ${name}`.
    if let rn = read(root, "screens/CustomerDetailScreen.tsx") {
        expect(rn.contains("accessibilityLabel={`Call ${"), "RN parity: Call ${name}")
        expect(rn.contains("accessibilityLabel={`Email ${"), "RN parity: Email ${name}")
    } else {
        expect(false, "RN CustomerDetailScreen.tsx readable")
    }
    expectEqual(Audit.Label.contact(.call, name: "Dana Ruiz"), "Call Dana Ruiz", "contact label: call")
    expectEqual(Audit.Label.contact(.text, name: " Dana "), "Text Dana", "contact label: text trims")
    expectEqual(Audit.Label.contact(.email, name: "  "), "Email customer", "contact label: empty name")
    expect(nativeCode.contains("NativeAccessibilityAudit.Label.contact("), "booking contact buttons use the contact label")
}

// MARK: - Tests: icon-only controls

func testIconOnlyControls(sources: [SourceFile]) {
    var constructs: [ControlConstruct] = []
    for file in sources { constructs.append(contentsOf: scanControls(file)) }
    expect(sources.count >= 100, "scanned every N/ swift file (\(sources.count))")
    expect(constructs.count >= 300, "scanner found the app's controls (\(constructs.count))")
    let iconOnly = constructs.filter(\.isIconOnly)
    expect(iconOnly.count >= 15, "scanner classified icon-only controls (\(iconOnly.count))")
    let unlabeled = iconOnly.filter { !$0.hasAccessibilityLabel }
    for construct in unlabeled {
        expect(false, "icon-only \(construct.kind) without accessibilityLabel at \(construct.location)")
    }
    expectEqual(unlabeled.count, 0, "no unlabeled icon-only controls in N/")

    // The six §12 findings, located by marker; each must be found, be
    // classified icon-only, and carry a label.
    // 11.10b: the four ⌘N "+" buttons carry a titled `Label` shown icon-only
    // (the shortcut HUD lists a title), so they are no longer icon-only
    // constructs; they must show only the icon and keep the RN label.
    let known: [(file: String, kind: String, marker: String, titled: Bool)] = [
        ("InvoicesView.swift", "Button", "systemImage: \"plus\"", true),
        ("JobsView.swift", "Button", "systemImage: \"plus\"", true),
        ("NativeRecurringInvoicesView.swift", "Button", "systemImage: \"plus\"", true),
        ("CustomersView.swift", "Button", "systemImage: \"plus\"", true),
        ("NativeBookingRequestsView.swift", "Button", "contactIcon(target.action)", false),
        ("NativeRouteView.swift", "Menu", "arrow.up.arrow.down", false),
    ]
    for site in known {
        let matches = constructs.filter {
            $0.file.relativePath == site.file && $0.kind == site.kind && ($0.labelCode ?? "").contains(site.marker)
        }
        guard let match = matches.first else {
            expect(false, "known finding not found: \(site.kind) with \(site.marker) in N/\(site.file)"); continue
        }
        expectEqual(matches.count, 1, "known finding unique: \(site.file) \(site.marker)")
        if site.titled {
            expect(match.hasTextTitle, "known finding has a text title: \(match.location)")
            expect(match.raw.contains(".labelStyle(.iconOnly)"), "known finding still shows only the icon: \(match.location)")
        } else {
            expect(match.isIconOnly, "known finding classified icon-only: \(match.location)")
        }
        expect(match.hasAccessibilityLabel, "known finding labelled: \(match.location)")
    }

    // Scanner self-checks on fixtures (construct end, not a fixed window).
    let fixture = SourceFile(relativePath: "Fixture.swift", text: """
    struct F: View {
        var body: some View {
            Button { go() } label: {
                // A comment with Text( and "braces { }" must not count.
                Image(systemName: "plus")
            }
            .padding()
            .sheet(isPresented: $x) { Text("x") }
            .frame(width: 44,
                   height: 44)
            .accessibilityLabel("Add")
            Button(action: go) { Image(systemName: "trash") }
            Button("Title") { go() }
            Menu { Button("A") {} } label: { Label("More", systemImage: "ellipsis") }
            Button { go() } label: { HStack { Image(systemName: "star"); Circle() } }
                .buttonStyle(.plain)
            Button(action: go, label: { Image(systemName: "gear") }).accessibilityLabel("Settings \\(name)")
            Button { go() } label: { Image(systemName: "xmark") }.accessibilityLabel("")
            Menu {
                Button { go() } label: { Image(systemName: "a") }.accessibilityLabel("A")
            } label: { Image(systemName: "ellipsis") }
            Button { go(); Text("x").accessibilityLabel("Nope") } label: { Image(systemName: "b") }
        }
    }
    """)
    let fx = scanControls(fixture)
    let fxIcon = fx.filter(\.isIconOnly)
    expectEqual(fx.count, 11, "fixture: 11 controls (9 Buttons + 2 Menus; nested menu buttons counted)")
    expectEqual(fxIcon.count, 8, "fixture: 8 icon-only")
    expectEqual(fxIcon.filter { !$0.hasAccessibilityLabel }.map(\.line), [12, 15, 18, 19, 22],
                "fixture: unlabeled at 12, 15, 18 (empty label), 19 (only its nested button is labelled), 22 (label in the action)")
    expect(fxIcon.first?.hasAccessibilityLabel == true, "fixture: label found after a multi-line chain and a trailing closure modifier")
}

// MARK: - Tests: motion

func testReduceMotion(sources: [SourceFile]) {
    expect(Audit.allowsCustomMotion(reduceMotion: false), "motion allowed when Reduce Motion is off")
    expect(!Audit.allowsCustomMotion(reduceMotion: true), "no custom motion when Reduce Motion is on")

    var sites: [(SourceFile, Int, String)] = []
    for file in sources {
        for start in file.occurrences(of: "withAnimation") {
            let open = file.skipSpace(start + "withAnimation".count)
            let args: String
            if open < file.code.count, file.code[open] == "(", let close = file.matching(open) {
                args = file.rawSlice((open + 1)..<close)
            } else {
                args = ""  // `withAnimation { }` uses the default animation.
            }
            sites.append((file, start, args))
        }
        for start in file.occurrences(of: "animation") where start > 0 && file.code[start - 1] == "." {
            let open = file.skipSpace(start + "animation".count)
            guard open < file.code.count, file.code[open] == "(", let close = file.matching(open) else { continue }
            sites.append((file, start, file.rawSlice((open + 1)..<close)))
        }
    }
    // The policy's argument must be the environment value, not a literal.
    let policyCall = try! NSRegularExpression(pattern: #"allowsCustomMotion\(reduceMotion: *reduceMotion *\)"#)
    for (file, start, args) in sites {
        let ns = args as NSString
        let honors = policyCall.firstMatch(in: args, range: NSRange(location: 0, length: ns.length)) != nil
        expect(honors, "animation passes the environment Reduce Motion value at N/\(file.relativePath):\(file.line(of: start))")
        expect(String(file.raw).contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"),
               "N/\(file.relativePath) binds reduceMotion to the environment")
    }
    // The two §12 findings must still be found (and so be checked above).
    for (path, marker) in [("CoachView.swift", "scrollTo"), ("NativeMoneyCards.swift", "expanded.toggle()")] {
        let found = sites.contains { site in
            guard site.0.relativePath == path else { return false }
            let tail = site.0.rawSlice(site.1..<min(site.0.raw.count, site.1 + 200))
            return tail.contains(marker)
        }
        expect(found, "known Reduce Motion site found: N/\(path) \(marker)")
    }
    expect(sites.count >= 2, "animation sites scanned (\(sites.count))")
    for path in ["CoachView.swift", "NativeMoneyCards.swift"] {
        let text = sources.first { $0.relativePath == path }.map { String($0.raw) } ?? ""
        expect(text.contains("@Environment(\\.accessibilityReduceMotion)"), "N/\(path) reads accessibilityReduceMotion")
    }
}

// MARK: - Tests: Dynamic Type, touch targets, fills, focus

func file(_ sources: [SourceFile], _ path: String) -> SourceFile? {
    let match = sources.first { $0.relativePath == path }
    expect(match != nil, "source N/\(path) found")
    return match
}

func testDynamicType(sources: [SourceFile]) {
    // No fixed-point system font outside the widget views (the widget canvas is
    // fixed; retained and recorded in contract §12).
    let fixedFont = try! NSRegularExpression(pattern: #"\.system\(size: *[0-9]"#)
    for source in sources where !source.relativePath.hasPrefix("Widgets/") {
        let text = source.codeText
        let ns = text as NSString
        for match in fixedFont.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            expect(false, "fixed-point font at N/\(source.relativePath):\(source.line(of: match.range.location))")
        }
    }
    // Every file that replaced a fixed size now scales it.
    let scaled = [
        "SettingsView.swift", "NativePaywallView.swift", "NativePasswordRecoveryView.swift",
        "NativeMoneyCards.swift", "NativeOnboardingView.swift", "NativeRouteView.swift",
        "NativeBookingRequestsView.swift", "Components.swift", "CustomersView.swift",
        "NativeTodayComponents.swift",
    ]
    for path in scaled {
        guard let source = file(sources, path) else { continue }
        expect(String(source.raw).contains("@ScaledMetric"), "N/\(path) uses @ScaledMetric")
    }

    guard let money = file(sources, "NativeMoneyCards.swift") else { return }
    let moneyText = String(money.raw)
    expect(!moneyText.contains(".frame(height: 110"), "expense trends: no fixed 110pt chart height clipping labels")
    expect(!moneyText.contains(".frame(width: 16)"), "top customers: rank column scales")
    expect(!moneyText.contains(".frame(width: 26, alignment: .leading)"), "job pipeline: count column scales")
    // Multi-column figures stack at accessibility sizes instead of truncating.
    let adaptive: [(String, Int)] = [
        ("NativeMoneyCards.swift", 7), ("NativeTodayComponents.swift", 1), ("JobsView.swift", 1), ("InvoicesView.swift", 1),
    ]
    for (path, minimum) in adaptive {
        guard let source = file(sources, path) else { continue }
        let count = source.occurrences(of: "NativeAccessibilityAdaptiveRow").count
        expect(count >= minimum, "N/\(path): \(count) adaptive rows (≥ \(minimum))")
    }
    // No hand-drawn vertical divider is left in the money cards.
    expect(!moneyText.contains("Rectangle().fill(.quaternary).frame(width: 1"), "money cards: dividers adapt when stacked")

    // Submit buttons grow with their text instead of clipping at 48pt.
    for path in ["NativeAuthView.swift", "NativePasswordRecoveryView.swift"] {
        guard let source = file(sources, path) else { continue }
        let submit = scanControls(source).filter { $0.code.hasPrefix("Button(action: submit)") }
        expectEqual(submit.count, 1, "N/\(path): submit button found")
        for construct in submit {
            expect(!construct.code.contains(".frame(height:"), "N/\(path): submit has no fixed height")
            expect(construct.code.contains("minHeight: 48"), "N/\(path): submit keeps a 48pt minimum")
        }
    }
    // Week strip day circles scale with the day number.
    if let today = file(sources, "NativeTodayComponents.swift") {
        expect(!String(today.raw).contains(".frame(width: 30, height: 30)"), "week strip circle is not a fixed 30pt")
    }
    // Customer initials are not truncated in a fixed 42pt frame.
    if let customers = file(sources, "CustomersView.swift") {
        expect(!String(customers.raw).contains(".frame(width: 42, height: 42)"), "customer initials frame scales")
    }
}

func testTouchTargets(sources: [SourceFile]) {
    guard let schedule = file(sources, "NativeScheduleSettingsView.swift") else { return }
    let days = scanControls(schedule).filter { ($0.labelCode ?? "").contains("Text(label)") }
    expectEqual(days.count, 1, "working-day toggle found")
    for construct in days {
        expect(!construct.code.contains(".frame(height: 36)"), "working-day toggle is not 36pt tall")
        expect(construct.raw.contains("minHeight: NativeAccessibilityAudit.minimumTouchTarget"),
               "working-day toggle has a 44pt minimum height")
    }
    expectEqual(Audit.minimumTouchTarget, 44, "minimum touch target is 44pt")

    // Week-strip arrows (RN used hitSlop 10) and route reorder chevrons (RN
    // hitSlop 6) were ~12–28pt glyph-sized targets.
    let minimumFrame = "minWidth: NativeAccessibilityAudit.minimumTouchTarget, minHeight: NativeAccessibilityAudit.minimumTouchTarget"
    if let today = file(sources, "NativeTodayComponents.swift") {
        for label in ["Previous week", "Next week"] {
            let matches = scanControls(today).filter { $0.raw.contains(".accessibilityLabel(\"\(label)\")") }
            expectEqual(matches.count, 1, "week strip \(label) button found")
            expect(matches.first?.raw.contains(minimumFrame) == true, "\(label) has a 44×44 target")
        }
        expect(String(today.raw).contains(".dynamicTypeSize(...DynamicTypeSize.accessibility1)"),
               "week strip caps at AX1 (seven columns cannot grow further on a phone)")
        // Fix round 1 (I1): the scaled circle must sit inside the capped subtree
        // and be clamped, or it escapes the cap and widens every column.
        let strip = structText(today, "NativeTodayWeekStripView")
        let day = structText(today, "NativeTodayWeekDayButton")
        expect(!strip.isEmpty && !day.isEmpty, "week strip and day button views found")
        expect(!strip.contains("@ScaledMetric"), "week strip itself reads no uncapped @ScaledMetric")
        if let dayCall = strip.range(of: "NativeTodayWeekDayButton("),
           let cap = strip.range(of: ".dynamicTypeSize(...DynamicTypeSize.accessibility1)") {
            expect(dayCall.lowerBound < cap.lowerBound, "day buttons are inside the capped HStack")
        } else {
            expect(false, "week strip builds day buttons under the AX1 cap")
        }
        expect(day.contains("@ScaledMetric(relativeTo: .subheadline) private var dayCircleSize"), "day circle scales inside the cap")
        expect(day.contains("NativeAccessibilityAudit.WeekStrip.dayCircleSize(scaled: dayCircleSize)"), "day circle is clamped")
        expect(day.contains(".frame(width: circle, height: circle)"), "day circle draws the clamped size")
        expect(day.contains(".accessibilityShowsLargeContentViewer()"), "day buttons offer the Large Content Viewer")
        expectEqual(strip.components(separatedBy: ".accessibilityShowsLargeContentViewer()").count - 1, 2,
                    "both week arrows offer the Large Content Viewer")
    }
    let week = Audit.WeekStrip.self
    let narrowColumn = week.dayColumnWidth(screenWidth: week.narrowestPhoneWidth)
    expect(week.dayCircleMaximum <= narrowColumn,
           "clamped circle \(week.dayCircleMaximum)pt fits a \(String(format: "%.1f", narrowColumn))pt column on a 375pt phone")
    expect(week.dayCircleMaximum <= week.dayColumnWidth(screenWidth: 393), "clamped circle fits on a 393pt phone")
    expect(week.dayCircleMaximum >= week.dayCircleDefault, "the clamp never shrinks the default circle")
    expectEqual(week.dayCircleSize(scaled: 30), 30, "default size is unchanged")
    expectEqual(week.dayCircleSize(scaled: 98), week.dayCircleMaximum, "an AX5-sized metric (~98pt) is clamped")
    expectEqual(week.horizontalChrome, 40, "chrome: TodayView padding 16×2 + card padding 4×2")

    // Fix round 1 (m3): the remaining glyph-sized icon buttons.
    for (path, marker) in [("Components.swift", "Image(systemName: \"xmark\")"), ("NativeScheduleSettingsView.swift", "Image(systemName: \"trash\")")] {
        guard let source = file(sources, path) else { continue }
        let matches = scanControls(source).filter { ($0.labelCode ?? "").contains(marker) }
        expectEqual(matches.count, 1, "N/\(path): \(marker) button found")
        expect(matches.first?.raw.contains(minimumFrame) == true, "N/\(path): \(marker) button has a 44×44 target")
    }
    if let route = file(sources, "NativeRouteView.swift") {
        for key in ["moveStopUp", "moveStopDown"] {
            let matches = scanControls(route).filter { $0.raw.contains("NativeAccessibilityAudit.Label.\(key)") }
            expectEqual(matches.count, 1, "route \(key) button found")
            expect(matches.first?.raw.contains(minimumFrame) == true, "route \(key) has a 44×44 target")
        }
    }
}

func testFills(sources: [SourceFile]) {
    // `.borderedProminent` draws a white label on the tint: only the helper
    // (which re-tints to `tradeReadyFill`) and explicitly re-tinted sites use it.
    for source in sources {
        let hits = source.occurrences(of: "borderedProminent")
        for hit in hits {
            let path = source.relativePath
            if path == "NativeAccessibilityViews.swift" { continue }
            if path == "NativeTimeTrackingView.swift" {
                let tail = source.rawSlice(hit..<min(source.raw.count, hit + 120))
                expect(tail.contains(".tint(summary.isClocked ? .tradeDangerFill : .tradeReadyFill)"),
                       "time tracking prominent button re-tints to tradeDangerFill / tradeReadyFill (A18)")
                continue
            }
            expect(false, "raw .borderedProminent at N/\(path):\(source.line(of: hit)); use tradeReadyProminentButtonStyle()")
        }
    }
    let helperUses = sources.reduce(0) { $0 + $1.occurrences(of: "tradeReadyProminentButtonStyle").count }
    expect(helperUses >= 24, "prominent buttons use the fill helper (\(helperUses))")

    // Opaque tint fills are graphics only (bars, dots); anything under white
    // text or icons uses `tradeReadyFill`.
    let allowed: [String: Int] = ["NativeMoneyCards.swift": 3, "NativeTodayComponents.swift": 2]
    let tintToken = try! NSRegularExpression(pattern: #"\.tradeReady(?![A-Za-z0-9_])(?!\s*\.opacity)"#)
    for source in sources {
        var count = 0
        var lines: [Int] = []
        for kind in ["fill", "background"] {
            for start in source.occurrences(of: kind) where start > 0 && source.code[start - 1] == "." {
                let open = source.skipSpace(start + kind.count)
                guard open < source.code.count, source.code[open] == "(", let close = source.matching(open) else { continue }
                let args = source.codeSlice((open + 1)..<close)
                let ns = args as NSString
                let n = tintToken.numberOfMatches(in: args, range: NSRange(location: 0, length: ns.length))
                if n > 0 { count += n; lines.append(source.line(of: start)) }
            }
        }
        let limit = allowed[source.relativePath] ?? 0
        expect(count <= limit, "opaque tint fills in N/\(source.relativePath): \(count) ≤ \(limit) (lines \(lines))")
    }
    // The white-foreground sites, by marker.
    let fillSites: [(String, String)] = [
        ("JobsView.swift", "selected ? Color.tradeReadyFill : Color(.secondarySystemGroupedBackground)"),
        ("NativeExpenseEditor.swift", "selected ? Color.tradeReadyFill : Color.tradeInk.opacity(0.06)"),
        ("NativeScheduleSettingsView.swift", "workDays.contains(day) ? Color.tradeReadyFill : Color(.tertiarySystemFill)"),
        ("NativeTodayComponents.swift", "day.isSelected ? Color.tradeReadyFill : Color.clear"),
        ("NativeTodayComponents.swift", ".background(Color.tradeReadyFill, in: RoundedRectangle(cornerRadius: 16"),
        ("NativeTodayComponents.swift", ".background(Color.tradeReadyFill, in: RoundedRectangle(cornerRadius: 10))"),
        ("SettingsView.swift", "LinearGradient(colors: [.tradeReadyFill, .tradeInk]"),
    ]
    for (path, marker) in fillSites {
        guard let source = file(sources, path) else { continue }
        expect(String(source.raw).contains(marker), "white-on-fill site uses tradeReadyFill: N/\(path) \(marker)")
    }
    if let expense = file(sources, "NativeExpenseEditor.swift") {
        expectEqual(expense.occurrences(of: "tradeReadyFill").count, 2, "both expense chip styles use the fill")
    }
}

func testFocusOrder(sources: [SourceFile]) {
    if let auth = file(sources, "NativeAuthView.swift") {
        let text = String(auth.raw)
        expect(text.contains("@FocusState"), "auth form tracks focus")
        expect(text.contains(".focused($focusedField, equals: .email)"), "email field is focusable")
        expect(text.components(separatedBy: ".focused($focusedField, equals: .password)").count - 1 == 2,
               "both password fields (secure and shown) share the password focus")
        // The email field's Next key moves to the password (or submits a reset).
        let email = text.range(of: "TextField(\"Email\"")
        let emailTail = email.map { String(text[$0.lowerBound...].prefix(700)) } ?? ""
        expect(emailTail.contains(".onSubmit(submitEmail)"), "email Next/Go has an action")
        // The action itself (Show/Hide also sets the password focus, so a
        // file-wide search would pass with an empty submitEmail).
        let body = functionBody(auth, "submitEmail").replacingOccurrences(of: " ", with: "")
        expect(body.contains("ifmode==.reset{submit()}else{focusedField=.password}"),
               "submitEmail: reset submits, otherwise Next focuses the password (\(body))")
        let toggle = text.range(of: "Button(showsPassword ? \"Hide\" : \"Show\")")
        let toggleTail = toggle.map { String(text[$0.lowerBound...].prefix(500)) } ?? ""
        expect(toggleTail.contains("Task { @MainActor in focusedField = .password }"),
               "Show/Hide refocuses the swapped password field on the next turn")
    }
    if let recovery = file(sources, "NativePasswordRecoveryView.swift") {
        let text = String(recovery.raw)
        expect(text.contains("@FocusState"), "recovery form tracks focus")
        let field = text.range(of: "SecureField(\"New password\"")
        let fieldTail = field.map { String(text[$0.lowerBound...].prefix(400)) } ?? ""
        let fieldChain = fieldTail.components(separatedBy: "SecureField(\"Confirm").first ?? ""
        expect(fieldChain.contains(".submitLabel(.next)"), "new password shows Next")
        expect(fieldChain.contains(".onSubmit { focusedField = .confirmation }"), "new password Next focuses confirmation")
        expect(text.contains(".focused($focusedField, equals: .confirmation)"), "confirmation field is focusable")
    }
}

// MARK: - 11.10b re-audit

/// `N/…` for app sources, `native/TradeReadyWidgets/…` for the widget
/// extension target's own files.
func displayPath(_ file: SourceFile) -> String {
    file.relativePath.hasPrefix(widgetTargetPrefix)
        ? "native/TradeReadyWidgets/" + file.relativePath.dropFirst(widgetTargetPrefix.count)
        : "N/\(file.relativePath)"
}

let widgetTargetPrefix = "@TradeReadyWidgets/"

/// The widget extension target's own sources (`native/TradeReadyWidgets`),
/// scanned with the app's so no view file escapes the audit.
func loadWidgetTargetSources(root: URL) -> [SourceFile] {
    let base = root.appendingPathComponent("native/TradeReadyWidgets")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
    return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
        guard let text = try? String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) else { return nil }
        return SourceFile(relativePath: widgetTargetPrefix + name, text: text)
    }
}

/// Every file that declares SwiftUI UI (a `View`, `ViewModifier`,
/// representable, toolbar, scene or widget). The re-audit (11.10b) reviewed
/// each one for labels, Dynamic Type, contrast, touch targets and keyboard
/// focus. A new view file fails the suite until it is reviewed and added.
let viewFileInventory: Set<String> = [
    "N/CoachView.swift", "N/Components.swift", "N/CustomersView.swift", "N/InvoicesView.swift",
    "N/JobsView.swift", "N/MoneyView.swift", "N/NativeAccessibilityViews.swift",
    "N/NativeAnalyticsScreenModifier.swift", "N/NativeAuthView.swift", "N/NativeBookingRequestsView.swift",
    "N/NativeBookingSettingsView.swift", "N/NativeCalendarView.swift", "N/NativeChangeOrdersView.swift",
    "N/NativeCoachComponents.swift", "N/NativeConfirmation.swift", "N/NativeCreateInvoiceFromJobView.swift",
    "N/NativeCustomerPortalView.swift", "N/NativeEstimateFollowUpView.swift", "N/NativeEstimatePDF.swift",
    "N/NativeEstimateReview.swift", "N/NativeExpenseEditor.swift", "N/NativeExportDataView.swift",
    "N/NativeGlobalSearch.swift", "N/NativeImportView.swift", "N/NativeInsightsCard.swift",
    "N/NativeInteractionState.swift", "N/NativeInvoiceOutreachView.swift", "N/NativeJobPhotosView.swift",
    "N/NativeJobProfitabilityView.swift", "N/NativeKeyboardDoneBar.swift", "N/NativeLayoutMetrics.swift",
    "N/NativeMessageComposer.swift", "N/NativeMileageLogView.swift", "N/NativeMoneyCards.swift",
    "N/NativeOnboardingView.swift", "N/NativePasswordRecoveryView.swift", "N/NativePaywallView.swift",
    "N/NativePricebookEntryView.swift", "N/NativePricebookView.swift", "N/NativePricingCalculator.swift",
    "N/NativeRecurringInvoicesView.swift", "N/NativeRecurringJobsView.swift", "N/NativeReviewRequestView.swift",
    "N/NativeRouteView.swift", "N/NativeScheduleEditorView.swift", "N/NativeScheduleSettingsView.swift",
    "N/NativeSetupChecklistCard.swift", "N/NativeTemplatePickerView.swift", "N/NativeTimeTrackingView.swift",
    "N/NativeTodayComponents.swift", "N/NativeTripEditor.swift", "N/RootView.swift", "N/SettingsView.swift",
    "N/TodayView.swift", "N/TradeReadyNativeApp.swift",
    "N/Widgets/Shared/JobTimerWidgetView.swift", "N/Widgets/Shared/NextJobWidgetView.swift",
    "native/TradeReadyWidgets/JobTimerWidget.swift", "native/TradeReadyWidgets/NextJobWidget.swift",
]

func declaresUI(_ file: SourceFile) -> Bool {
    let pattern = #"\bsome (View|Scene|WidgetConfiguration|ToolbarContent)\b|:\s*(?:[A-Za-z_.]+\s*,\s*)*(View|ViewModifier|UIViewControllerRepresentable|UIViewRepresentable|App|Widget|ToolbarContent)\b"#
    let text = file.codeText
    return text.range(of: pattern, options: .regularExpression) != nil
}

func testViewInventory(allSources: [SourceFile]) {
    let actual = Set(allSources.filter(declaresUI).map(displayPath))
    for path in actual.subtracting(viewFileInventory).sorted() {
        expect(false, "new view file \(path) is not in the 11.10b accessibility inventory: review its labels, Dynamic Type, contrast, touch targets and focus, then add it to viewFileInventory")
    }
    for path in viewFileInventory.subtracting(actual).sorted() {
        expect(false, "inventoried view file \(path) is missing or no longer declares UI (update viewFileInventory)")
    }
    expect(actual.count >= 58, "view inventory covers the app and the widget target (\(actual.count))")
    expect(allSources.contains { $0.relativePath.hasPrefix(widgetTargetPrefix) }, "widget extension target sources are scanned")
    // The detector itself.
    expect(declaresUI(SourceFile(relativePath: "a", text: "struct A: View { var body: some View { EmptyView() } }")), "detector: View")
    expect(declaresUI(SourceFile(relativePath: "b", text: "struct B: Equatable, UIViewControllerRepresentable {}")), "detector: representable")
    expect(!declaresUI(SourceFile(relativePath: "c", text: "struct C { let view = 1 } // some View\nlet s = \"some View\"")), "detector ignores comments and strings")
}

/// Every keyboard shortcut sits on a control with a text title: the iPad
/// shortcut HUD (hold ⌘) lists it by that title, and an image-only label
/// has none. VoiceOver keeps reading the control's accessibility label; a
/// `.keyboardShortcut` does not change it (11.11 regression check).
func testShortcutTitles(sources: [SourceFile]) {
    var withShortcut = 0
    for file in sources {
        for construct in scanControls(file) {
            let chain = file.codeSlice(construct.chainStart..<construct.end)
            guard chain.contains(".keyboardShortcut(") else { continue }
            withShortcut += 1
            expect(construct.hasTextTitle, "\(construct.kind) with a keyboard shortcut has a text title (shortcut HUD) at \(construct.location)")
            if construct.isIconOnly {
                expect(construct.hasAccessibilityLabel, "icon-only control with a shortcut is labelled at \(construct.location)")
            }
        }
    }
    let total = sources.reduce(0) { sum, f in sum + f.occurrences(of: "keyboardShortcut").filter { f.code[$0 - 1] == "." }.count }
    expectEqual(withShortcut, total, "every .keyboardShortcut in N/ is on a scanned control (\(total))")
    expect(total >= 46, "the 11.11 shortcuts are all scanned (\(total))")
    for (path, key) in [("JobsView.swift", "addJob"), ("InvoicesView.swift", "addInvoice"),
                        ("CustomersView.swift", "addCustomer"), ("NativeRecurringInvoicesView.swift", "addMaintenancePlan")] {
        guard let source = file(sources, path) else { continue }
        let matches = scanControls(source).filter {
            ($0.labelCode ?? "").contains("Label(NativeAccessibilityAudit.Label.\(key), systemImage: \"plus\")")
        }
        expectEqual(matches.count, 1, "N/\(path): ⌘N \"+\" is Label(Label.\(key), systemImage: \"plus\")")
        expect(matches.first?.raw.contains(".labelStyle(.iconOnly)") == true, "N/\(path): ⌘N \"+\" still shows only the icon")
    }
}

// MARK: A24 — return keys and keyboard dismissal

/// A type's name and its brace range, for the innermost-type lookups below.
struct TypeRange {
    let name: String
    let range: Range<Int>
}

func typeRanges(_ file: SourceFile) -> [TypeRange] {
    var result: [TypeRange] = []
    for hit in file.occurrences(of: "struct") {
        let nameStart = file.skipSpace(hit + "struct".count)
        guard let (name, _) = file.identifier(at: nameStart),
              let brace = (nameStart..<file.code.count).first(where: { file.code[$0] == "{" }),
              let close = file.matching(brace) else { continue }
        result.append(TypeRange(name: name, range: brace..<(close + 1)))
    }
    return result
}

func innermostType(_ ranges: [TypeRange], _ index: Int) -> String? {
    ranges.filter { $0.range.contains(index) }.min { $0.range.count < $1.range.count }?.name
}

/// Fields whose iOS keyboard has no key that dismisses it: the pad keyboards
/// and multi-line input (RN `needsDoneBar`), plus the components that wrap a
/// pad field.
let keyboardWithoutDismissMarkers = [
    #"\.keyboardType\(\.(decimalPad|numberPad|phonePad|asciiCapableNumberPad)\)"#,
    #"axis:\s*\.vertical"#, #"\bTextEditor\("#, #"\bCurrencyField\("#, #"\bDecimalInput\("#,
]
/// Components that wrap such a field; the screens that use them are covered.
let keyboardFieldComponents: Set<String> = ["CurrencyField", "DecimalInput"]
/// Type holding such a field → the screen type that carries
/// `.nativeKeyboardDoneBar()` (RN `KeyboardDoneBar`). An unlisted type fails.
let keyboardDoneBarCoverage: [String: String] = [
    "CoachView": "CoachView",
    "CustomerDetailView": "CustomerDetailView",
    "CustomerEditor": "CustomerEditor",
    "JobEditor": "JobEditor",
    "InvoiceEditor": "InvoiceEditor",
    "PaymentEditor": "PaymentEditor",
    "NativeChangeOrderEditorView": "NativeChangeOrderEditorView",
    "ChangeOrderDecisionSheet": "ChangeOrderDecisionSheet",
    "NativeChangeOrderReviewView": "NativeChangeOrderReviewView",
    "NativeCreateInvoiceFromJobView": "NativeCreateInvoiceFromJobView",
    "NativeEstimateFollowUpView": "NativeEstimateFollowUpView",
    "NativeEstimateReviewView": "NativeEstimateReviewView",
    "NativeExpenseEditor": "NativeExpenseEditor",
    "NativeInvoiceOutreachView": "NativeInvoiceOutreachView",
    "NativeOnMyWayReviewView": "NativeOnMyWayReviewView",
    "NativeAppointmentConfirmationReviewView": "NativeAppointmentConfirmationReviewView",
    "NativeMileageLogView": "NativeMileageLogView",
    "NativePricebookEntryView": "NativePricebookEntryView",
    "NativePricingCalculatorView": "NativePricingCalculatorView",
    "NativeRecurringInvoiceEditor": "NativeRecurringInvoiceEditor",
    "NativeRecurringJobEditor": "NativeRecurringJobEditor",
    "NativeReviewRequestView": "NativeReviewRequestView",
    "NativeScheduleSettingsView": "NativeScheduleSettingsView",
    "NativeTripEditor": "NativeTripEditor",
    // Settings pages share one `Form` in `SettingsPage`.
    "BusinessProfileSettings": "SettingsPage",
    "PricingSettings": "SettingsPage",
    "ReviewSettings": "SettingsPage",
]

func testReturnKeysAndDismissal(root: URL, sources: [SourceFile]) {
    // 1. A Next/Continue key must move somewhere (the 11.10a A7 bug class):
    //    the field's own chain carries an .onSubmit.
    var nextKeys = 0
    for source in sources {
        for hit in source.occurrences(of: "submitLabel") where source.code[hit - 1] == "." {
            let open = source.skipSpace(hit + "submitLabel".count)
            guard open < source.code.count, source.code[open] == "(", let close = source.matching(open) else { continue }
            let args = source.codeSlice((open + 1)..<close)
            guard args.contains(".next") || args.contains(".continue") else { continue }
            nextKeys += 1
            let fieldStart = (source.occurrences(of: "TextField") + source.occurrences(of: "SecureField")).filter { $0 < hit }.max() ?? hit
            let region = source.codeSlice(fieldStart..<source.chainEnd(from: close + 1))
            expect(region.contains(".onSubmit"), "a Next key has an action at N/\(source.relativePath):\(source.line(of: hit))")
        }
    }
    expect(nextKeys >= 2, "the auth and recovery Next keys are scanned (\(nextKeys))")

    // 2. RN oracle: single-line fields default to "done" (dismiss) and pad or
    //    multi-line keyboards get the "Done" bar. RN has no Next chains in the
    //    editors, so native adds none; Return in a single-line SwiftUI field
    //    ends editing, which is RN's "done".
    if let field = read(root, "components/Field.tsx") {
        expect(field.contains(#"returnKeyType ?? (multiline ? undefined : "done")"#), "RN Field: single-line inputs return \"done\"")
        expect(field.contains("KeyboardDoneBar"), "RN Field mounts the KeyboardDoneBar")
    } else { expect(false, "RN components/Field.tsx readable") }
    if let bar = read(root, "components/KeyboardDoneBar.tsx") {
        for pad in ["\"decimal-pad\"", "\"number-pad\"", "\"phone-pad\""] {
            expect(bar.contains(pad), "RN KeyboardDoneBar covers \(pad)")
        }
        expect(bar.contains("multiline === true"), "RN KeyboardDoneBar covers multi-line input")
        expect(bar.contains(">Done<"), "RN KeyboardDoneBar shows \"Done\"")
    } else { expect(false, "RN components/KeyboardDoneBar.tsx readable") }
    for editor in [("JobsView.swift", "JobEditor"), ("InvoicesView.swift", "InvoiceEditor"), ("CustomersView.swift", "CustomerEditor"),
                   ("NativeExpenseEditor.swift", "NativeExpenseEditor"), ("NativeTripEditor.swift", "NativeTripEditor"),
                   ("NativePricebookEntryView.swift", "NativePricebookEntryView"), ("NativeScheduleSettingsView.swift", "NativeScheduleSettingsView")] {
        guard let source = file(sources, editor.0) else { continue }
        let text = structText(source, editor.1)
        expect(text.contains("TextField("), "A24 editor \(editor.1) found with its fields")
        expect(!text.contains(".submitLabel(.next)"), "A24 editor \(editor.1): no Next key without a chain (RN has none)")
    }

    // 3. Every field whose keyboard cannot dismiss itself is on a screen with
    //    the Done bar (RN KeyboardDoneBar, owner requirement 2026-07-16).
    let regexes = keyboardWithoutDismissMarkers.map { try! NSRegularExpression(pattern: $0) }
    var carriersNeeded: Set<String> = []
    var fieldTypes: Set<String> = []
    for source in sources where !source.relativePath.hasPrefix("Widgets/") {
        let ranges = typeRanges(source)
        let text = source.codeText
        let ns = text as NSString
        for regex in regexes {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let type = innermostType(ranges, match.range.location) else { continue }
                if keyboardFieldComponents.contains(type) { continue }
                fieldTypes.insert(type)
                guard let carrier = keyboardDoneBarCoverage[type] else {
                    expect(false, "\(type) (N/\(source.relativePath):\(source.line(of: match.range.location))) has a pad or multi-line field: add .nativeKeyboardDoneBar() to its screen and list it in keyboardDoneBarCoverage")
                    continue
                }
                carriersNeeded.insert(carrier)
            }
        }
    }
    expectEqual(fieldTypes, Set(keyboardDoneBarCoverage.keys), "keyboardDoneBarCoverage lists exactly the types with such fields")
    var carrierCount = 0
    for carrier in carriersNeeded.sorted() {
        let text = sources.lazy.map { structText($0, carrier) }.first { !$0.isEmpty } ?? ""
        expect(!text.isEmpty, "Done-bar screen \(carrier) found")
        let bars = text.components(separatedBy: ".nativeKeyboardDoneBar()").count - 1
        expectEqual(bars, 1, "\(carrier) carries exactly one .nativeKeyboardDoneBar()")
        carrierCount += bars
    }
    let total = sources.reduce(0) { sum, f in sum + f.occurrences(of: "nativeKeyboardDoneBar").filter { f.code[$0 - 1] == "." }.count }
    expectEqual(total, carrierCount, "no .nativeKeyboardDoneBar() outside the listed screens (a nested one duplicates the Done button)")
    if let bar = file(sources, "NativeKeyboardDoneBar.swift") {
        let text = String(bar.raw)
        expect(text.contains("ToolbarItemGroup(placement: .keyboard)"), "Done bar sits above the keyboard")
        expect(text.contains("Button(\"Done\")"), "Done bar shows RN's \"Done\"")
        expect(text.contains(".accessibilityLabel(NativeAccessibilityAudit.Label.dismissKeyboard)"), "Done bar reads RN's \"Dismiss keyboard\"")
        expect(text.contains("resignFirstResponder"), "Done bar ends editing wherever focus is")
        expect(!text.contains("keyboardShortcut"), "Done bar adds no keyboard shortcut")
    }
}

/// A host runner that compiles a view using `.nativeKeyboardDoneBar()` must
/// compile its definition too, or that runner stops building.
func testRunnersCompileDoneBar(root: URL, sources: [SourceFile]) {
    let users = Set(sources.filter { source in
        source.relativePath != "NativeKeyboardDoneBar.swift"
            && source.occurrences(of: "nativeKeyboardDoneBar").contains { source.code[$0 - 1] == "." }
    }.map { "native/TradeReadyNative/\($0.relativePath)" })
    let native = root.appendingPathComponent("native")
    let runners = ((try? FileManager.default.contentsOfDirectory(atPath: native.path)) ?? [])
        .filter { $0.hasPrefix("run-") && $0.hasSuffix(".sh") }.sorted()
    var checked = 0
    for runner in runners {
        guard let script = read(root, "native/\(runner)") else { continue }
        let compiled = users.filter { script.contains($0) }
        guard !compiled.isEmpty else { continue }
        checked += 1
        expect(script.contains("native/TradeReadyNative/NativeKeyboardDoneBar.swift"),
               "native/\(runner) compiles \(compiled.sorted()) and so must compile N/NativeKeyboardDoneBar.swift")
    }
    expect(checked >= 1, "the schedule settings runner compiles a Done-bar screen (\(checked))")
}

// MARK: A15 — chart summaries

func testChartSummaries(sources: [SourceFile]) {
    typealias Point = Audit.ChartPoint
    typealias Value = Audit.ChartSeriesValue
    expectEqual(Audit.spokenMonth("Jun"), "June", "spoken month")
    expectEqual(Audit.spokenMonth("May"), "May", "spoken month (May)")
    expectEqual(Audit.spokenMonth("Q1"), "Q1", "unknown labels are unchanged")
    expectEqual(Audit.changePhrase(percent: -12), "down 12% from the previous month", "change phrase down")
    expectEqual(Audit.changePhrase(percent: 5), "up 5% from the previous month", "change phrase up")
    expectEqual(Audit.changePhrase(percent: 0), nil, "no change phrase for 0 (blank badge)")
    expectEqual(Audit.changePhrase(percent: nil), nil, "no change phrase without a previous month")
    let summary = Audit.chartSummary([
        Point(label: "Apr", values: [Value(series: "Income", value: "$1,200.00"), Value(series: "Expenses", value: "$300.00")]),
        Point(label: "May", values: [Value(series: "", value: "$80.00")], note: "down 12% from the previous month"),
    ])
    expectEqual(summary, "April: Income $1,200.00, Expenses $300.00. May: $80.00, down 12% from the previous month.", "chart summary text")
    expectEqual(Audit.chartSummary([]), "No data", "empty chart summary")
    expectEqual(Audit.Label.chart(title: "Last 6 Months"), "Last 6 Months chart", "chart label")

    guard let money = file(sources, "NativeMoneyCards.swift") else { return }
    for (card, title, legends) in [("NativeMoneyMonthlyChartCardView", "Last 6 Months", 1),
                                   ("NativeMoneySeasonalCardView", "12-Month Trend", 1),
                                   ("NativeMoneyExpenseTrendsCardView", "Expense Trends", 0)] {
        let view = structText(money, card)
        expect(!view.isEmpty, "\(card) found")
        expect(view.contains(".accessibilityElement(children: .ignore)"), "\(card): the bars and month letters are one element")
        expect(view.contains(".accessibilityLabel(NativeAccessibilityAudit.Label.chart(title: \"\(title)\"))"), "\(card): chart label")
        expect(view.contains(".accessibilityValue(NativeAccessibilityAudit.chartSummary("), "\(card): the figures are the chart's value")
        let hidden = view.components(separatedBy: ".accessibilityHidden(true)").count - 1
        expect(hidden >= legends, "\(card): the legend is hidden (the summary names each series)")
    }
    let trends = structText(money, "NativeMoneyExpenseTrendsCardView")
    expect(trends.contains("NativeAccessibilityAudit.changePhrase(percent:"), "expense trends: month-over-month badges are spoken")
}

// MARK: A16 — fixed frames

/// Literal fixed widths of 20pt or more outside the widget canvas, per file,
/// that the re-audit kept, with why. A new one fails: scale it with
/// `@ScaledMetric`, use a minimum, or record it here.
let retainedFixedWidths: [String: Int] = [
    // Numeric TextFields for a multiplier and percents (digits right-aligned; the field scrolls).
    "SettingsView.swift": 3,  // + the Appearance icon column (26pt; the glyph overflows, never clips)
    "NativeOnboardingView.swift": 1,  // feature icon column (26pt; glyph overflows, never clips)
    "NativeInsightsCard.swift": 1,  // insight icon column (22pt; glyph overflows, never clips)
    "NativeInvoiceOutreachView.swift": 1,  // "%"/"$" segmented control (UIKit caps its text size)
    "NativeCalendarView.swift": 1,  // timeline hour labels: a fixed 44pt/hour graphic hidden from VoiceOver; the accessible list below scales
    "NativeTodayComponents.swift": 1,  // schedule time column below AX sizes; it stacks at AX sizes
    "NativeBookingRequestsView.swift": 2,  // kind column below AX sizes; at AX sizes it is one full-width line
]

func testFixedFrames(sources: [SourceFile]) {
    let width = try! NSRegularExpression(pattern: #"\.frame\(width: *([0-9]+(?:\.[0-9]+)?)"#)
    let square = try! NSRegularExpression(pattern: #"\.frame\(width: *([0-9]+), *height: *([0-9]+)\)"#)
    for source in sources where !source.relativePath.hasPrefix("Widgets/") && !source.relativePath.hasPrefix(widgetTargetPrefix) {
        let text = source.codeText
        let ns = text as NSString
        var wide = 0
        var lines: [Int] = []
        for match in width.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let value = Double(ns.substring(with: match.range(at: 1))), value >= 20 else { continue }
            wide += 1
            lines.append(source.line(of: match.range.location))
        }
        let allowed = retainedFixedWidths[source.relativePath] ?? 0
        expectEqual(wide, allowed, "fixed widths ≥ 20pt in N/\(source.relativePath) (lines \(lines)) match the retained list")
        for match in square.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let side = Int(ns.substring(with: match.range(at: 1))) ?? 0
            expect(side < 20, "fixed icon frame \(side)pt at N/\(source.relativePath):\(source.line(of: match.range.location)); scale it (A16)")
        }
    }
    // The A16 sites, each scaled.
    let scaled: [(String, String, String)] = [
        ("MoneyView.swift", "NativeMoneyExpenseRowView", "@ScaledMetric(relativeTo: .callout) private var iconBadgeSize"),
        ("SettingsView.swift", "SettingsView", "@ScaledMetric(relativeTo: .title2) private var avatarSize"),
        ("SettingsView.swift", "SyncSettings", "@ScaledMetric(relativeTo: .title2) private var statusBadgeSize"),
        ("NativeTodayComponents.swift", "NativeTodayHeroCardView", "@ScaledMetric(relativeTo: .subheadline) private var discSize"),
        ("NativeJobPhotosView.swift", "PhotoThumbnail", "@ScaledMetric(relativeTo: .caption2) private var scaledSide"),
    ]
    for (path, type, metric) in scaled {
        guard let source = file(sources, path) else { continue }
        let text = structText(source, type)
        expect(!text.isEmpty, "N/\(path): \(type) found")
        expect(text.contains(metric), "N/\(path) \(type): \(metric)")
    }
    if let photos = file(sources, "NativeJobPhotosView.swift") {
        expect(structText(photos, "PhotoThumbnail").contains("NativeAccessibilityAudit.PhotoThumbnail.side(scaled: scaledSide)"), "photo thumbnail side is clamped")
    }
    let thumb = Audit.PhotoThumbnail.self
    expectEqual(thumb.side(scaled: 112), 112, "photo thumbnail default is unchanged")
    expectEqual(thumb.side(scaled: 400), thumb.sideMaximum, "an AX5 thumbnail is clamped")
    expect(thumb.sideMaximum <= 375 - 32 - 32, "clamped thumbnail fits a 375pt phone row")
    // Route index column and booking kind column grow instead of clipping.
    if let route = file(sources, "NativeRouteView.swift") {
        let row = structText(route, "StopRowView")
        expect(row.contains(".frame(minWidth: 24)"), "route stop number has a minimum, not a fixed, width")
        expect(row.contains(".frame(minWidth: NativeAccessibilityAudit.minimumTouchTarget)"), "route reorder column has a minimum width")
    }
    if let booking = file(sources, "NativeBookingRequestsView.swift") {
        let row = structText(booking, "RequestRowView")
        expect(row.contains("NativeAccessibilityAdaptiveRow(alignment: .top, spacing: 12)"), "booking request header stacks at AX sizes")
        expect(row.contains("dynamicTypeSize.isAccessibilitySize"), "booking kind column drops its fixed width at AX sizes")
    }
    if let today = file(sources, "NativeTodayComponents.swift") {
        expect(structText(today, "NativeTodayScheduleStop").contains("dynamicTypeSize.isAccessibilitySize"), "Today schedule time column stacks at AX sizes")
    }
    // A27: the route empty and loading bands grow with their text.
    if let route = file(sources, "NativeRouteView.swift") {
        expect(!String(route.raw).contains(".frame(height: 200)"), "route preview bands are not a fixed 200pt (AX5 text clipped)")
        expectEqual(route.occurrences(of: "minHeight").count >= 2, true, "route preview bands keep a 200pt minimum")
    }
}

// MARK: A28 — error and destructive text

/// No view uses system red (text measured 3.55:1 on a white row): error,
/// destructive and danger-tone text, glyphs, strokes and washes use
/// `tradeDangerText` (RN `colors.danger`), and filled buttons `tradeDangerFill`.
func testDangerText(root: URL, sources: [SourceFile]) {
    let red = try! NSRegularExpression(pattern: #"\bColor\.red\b|(?<![\w)\]])\.red\b"#)
    var uses = 0
    for source in sources where !source.relativePath.hasPrefix("Widgets/") && !source.relativePath.hasPrefix("Domain/")
        && !source.relativePath.hasPrefix(widgetTargetPrefix) {
        let text = source.codeText
        let ns = text as NSString
        for match in red.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            expect(false, "system red at N/\(source.relativePath):\(source.line(of: match.range.location)); use .tradeDangerText (A28)")
        }
        uses += source.occurrences(of: "tradeDangerText").count
    }
    expect(uses >= 28, "error and destructive text use tradeDangerText (\(uses))")
    // The detector itself.
    let fixture = "Text(e).foregroundStyle(.red)\nText(f).foregroundStyle(ok ? Color.red : .secondary)\ncase .bad: .red\nlet l = color.red + rgb().red + UIColor(red: 1)"
    expectEqual(red.numberOfMatches(in: fixture, range: NSRange(location: 0, length: (fixture as NSString).length)), 3, "system-red detector ignores RGB components")
    if let auth = read(root, "screens/AuthScreen.tsx") {
        expect(auth.contains("color: colors.danger"), "RN error text uses colors.danger")
    } else { expect(false, "RN AuthScreen.tsx readable") }
}

// MARK: A29 semantic text colors

/// The SwiftUI system hues. None may be written in an app view: each has a
/// semantic token whose light and dark literals are proven above.
let systemHuePattern = #"(?:\bColor\.|(?<![\w)\]])\.)(green|orange|mint|cyan|indigo|purple|blue|yellow|teal|pink|brown)\b"#

/// UIKit system colors (`Color(.systemGreen)`, `UIColor.systemRed`,
/// `Color(uiColor: .systemOrange)`): the same hues by another spelling (fix
/// round 1, m3).
let uikitSystemColorPattern = #"\bsystem(Red|Green|Orange|Blue|Mint|Cyan|Indigo|Purple|Yellow|Teal|Pink|Brown)\b"#

/// `.mint` also names the portal and booking-link "mint" action (an enum case,
/// not a color). Each non-color use must sit in one of these call shapes (fix
/// round 1, m4: matched per use, not counted per file).
let nonColorMintPattern = #"(?:\baction: |\baction == |\badminister\(|\bbusyAction == |\bbusyAction = |\bcase )\.mint\b(?=[,:)\s])"#

/// Locations of the `.mint` tokens that are the enum action, in `text`.
func nonColorMintLocations(in text: String) -> Set<Int> {
    let regex = try! NSRegularExpression(pattern: nonColorMintPattern)
    let ns = text as NSString
    var result = Set<Int>()
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let inner = ns.range(of: ".mint", options: [], range: match.range)
        if inner.location != NSNotFound { result.insert(inner.location) }
    }
    return result
}

/// Every call or closure owner around `index`, innermost first. A brace
/// reports the call it trails (`.confirmationDialog(…) {` gives
/// "confirmationDialog") or its label (`.swipeActions {`); a function body
/// reports "func:<name>".
func enclosingOwners(_ source: SourceFile, at index: Int) -> [String] {
    let code = source.code
    func openBefore(_ close: Int) -> Int? {
        let pairs: [Character: Character] = [")": "(", "}": "{", "]": "["]
        guard let opener = pairs[code[close]] else { return nil }
        var depth = 0
        var k = close
        while k >= 0 {
            if code[k] == code[close] { depth += 1 }
            else if code[k] == opener { depth -= 1; if depth == 0 { return k } }
            k -= 1
        }
        return nil
    }
    func identifier(endingAt end: Int) -> String {
        var b = end
        while b > 0, code[b - 1].isLetter || code[b - 1].isNumber || code[b - 1] == "_" { b -= 1 }
        return String(code[b..<end])
    }
    var owners: [String] = []
    var k = index - 1
    while k >= 0 {
        let c = code[k]
        if c == ")" || c == "}" || c == "]" {
            guard let open = openBefore(k) else { return owners }
            k = open - 1
            continue
        }
        if c == "(" || c == "[" {
            if c == "(" { owners.append(identifier(endingAt: k)) }
        } else if c == "{" {
            var j = k - 1
            while j >= 0, code[j] == " " || code[j] == "\n" || code[j] == "\t" { j -= 1 }
            if j >= 0, code[j] == ")", let open = openBefore(j) {
                owners.append(identifier(endingAt: open))
            } else if j >= 0 {
                owners.append(identifier(endingAt: j + 1))
            }
            // A function body: `func name(…) -> T {`.
            let lineStart = source.lineStarts[source.line(of: k) - 1]
            var head = String(code[max(0, lineStart - 200)..<k])
            if let range = head.range(of: "func ", options: .backwards) {
                head = String(head[range.upperBound...])
                if !head.contains("{") && !head.contains("}"), let name = head.split(separator: "(").first {
                    owners.append("func:" + name.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        k -= 1
    }
    return owners
}

/// Modifier lines of the chain that contains the line of `index`: the
/// contiguous lines starting with "." above it, plus its own line.
func chainLines(_ source: SourceFile, at index: Int) -> String {
    let lines = String(source.code).components(separatedBy: "\n")
    let line = source.line(of: index) - 1
    var collected = [lines[line]]
    var l = line - 1
    while l >= 0, lines[l].trimmingCharacters(in: .whitespaces).hasPrefix(".") {
        collected.append(lines[l]); l -= 1
    }
    return collected.joined(separator: "\n")
}

/// System-drawn containers: their destructive buttons are red text the
/// system draws on its own material (§12.1 A31, accepted).
let systemDrawnOwners: Set<String> = ["alert", "confirmationDialog", "swipeActions", "contextMenu"]

/// Helpers whose buttons are only ever placed in a system-drawn container.
/// Each call site is checked.
let dialogActionHelpers: [(file: String, function: String)] = [
    ("TodayView.swift", "bookingAlertActions"),
    ("NativeInsightsCard.swift", "optionsActions"),
    ("NativeInsightsCard.swift", "muteButtons"),
    ("NativeChangeOrdersView.swift", "actions"),
]

/// Literal washes stronger than the proven 13%, each with its reason (fix
/// round 1, m1: any context, including helpers and trailing closures).
let strongOpacityAllowlist: [(file: String, marker: String, reason: String)] = [
    ("NativePaywallView.swift", "Color.secondary.opacity(0.25)", "unselected plan border, non-text"),
    ("NativeMoneyCards.swift", "Rectangle().fill(Color.tradeReady.opacity(0.25)", "forecast bar track, non-text"),
    ("NativeTodayComponents.swift", "Circle().fill(.white.opacity(0.18)", "hero icon disc; proven row"),
    ("NativeTodayComponents.swift", "Color.tradeDangerText.opacity(0.4)", "danger card border, non-text"),
    ("NativeCoachComponents.swift", "Color.tradeDangerText.opacity(0.5)", "error bubble border, non-text"),
    ("NativeCoachComponents.swift", "Color.tradeReady.opacity(0.18)", "user bubble under primary text; proven rows"),
    ("NativeInvoiceOutreachView.swift", "Color.secondary.opacity(0.3)", "provider chip border, non-text"),
    ("NativeCalendarView.swift", "Rectangle().fill(Color.secondary.opacity(0.2)", "hour rule in the hidden timeline graphic"),
    ("NativeCalendarView.swift", "Color.tradeWarningText.opacity(0.35)", "conflict block in the hidden timeline graphic"),
    ("NativeCalendarView.swift", "Color.accentColor.opacity(0.25)", "job block in the hidden timeline graphic"),
]

/// Identifiers of the calls enclosing `index`, innermost first (skipping
/// array literals and ternaries; stops at the first enclosing brace).
func enclosingCalls(_ source: SourceFile, at index: Int) -> [String] {
    var calls: [String] = []
    var depth = 0
    var k = index - 1
    while k >= 0 {
        let c = source.code[k]
        if c == ")" || c == "]" || c == "}" { depth += 1 }
        else if c == "[" { if depth > 0 { depth -= 1 } }
        else if c == "{" { if depth > 0 { depth -= 1 } else { return calls } }
        else if c == "(" {
            if depth > 0 { depth -= 1 } else {
                var e = k
                var b = e
                while b > 0, source.code[b - 1].isLetter || source.code[b - 1].isNumber || source.code[b - 1] == "_" { b -= 1 }
                if b < e { calls.append(String(source.code[b..<e])) } else { calls.append("") }
                e = b
            }
        }
        k -= 1
    }
    return calls
}

func testSemanticColors(root: URL, sources: [SourceFile]) {
    let p = Audit.Palette.self
    let tokens = Audit.semanticColorTokens
    let textTokens = Set(tokens.filter { $0.kind == .text }.map(\.name))
    let fillTokens = Set(tokens.filter { $0.kind == .fill }.map(\.name)).union(["tradeReadyFill"])
    expectEqual(Set(tokens.map(\.name)).count, tokens.count, "semantic token names unique")
    for name in ["tradeSuccessText", "tradeWarningText", "tradeInfoText", "tradeMintText", "tradeIndigoText",
                 "tradePurpleText", "tradeCyanText", "tradeDangerText", "tradeSuccessFill", "tradeWarningFill", "tradeDangerFill"] {
        expect(tokens.contains { $0.name == name }, "semantic token \(name) declared")
    }

    // Every pairing is a proven row: each text token on each ground and its
    // 13% wash in both appearances, each fill under white in both.
    let requirements = Audit.contrastRequirements
    let byName = Dictionary(requirements.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    for token in tokens {
        let rows = requirements.filter { $0.foreground == token.light || $0.foreground == token.dark || $0.background == token.light || $0.background == token.dark }
        switch token.kind {
        case .text:
            let expected = 2 * (Audit.lightTextGrounds.count + Audit.darkTextGrounds.count)
            let textRows = rows.filter { $0.role == .text && ($0.foreground == token.light || $0.foreground == token.dark) }
            expect(textRows.count >= expected, "\(token.name): \(textRows.count) text rows ≥ \(expected)")
            for ground in Audit.lightTextGrounds {
                let wash = Audit.composite(token.light, alpha: Audit.maximumTextWashAlpha, over: ground.color)
                expect(Audit.contrastRatio(token.light, ground.color) >= Audit.Threshold.text, "\(token.name) light on \(ground.name)")
                expect(Audit.contrastRatio(token.light, wash) >= Audit.Threshold.text, "\(token.name) light on its wash over \(ground.name)")
            }
            for ground in Audit.darkTextGrounds {
                let wash = Audit.composite(token.dark, alpha: Audit.maximumTextWashAlpha, over: ground.color)
                expect(Audit.contrastRatio(token.dark, ground.color) >= Audit.Threshold.text, "\(token.name) dark on \(ground.name)")
                expect(Audit.contrastRatio(token.dark, wash) >= Audit.Threshold.text, "\(token.name) dark on its wash over \(ground.name)")
            }
            expect(token.light != token.dark, "\(token.name) is dynamic (light and dark differ)")
        case .fill:
            expect(Audit.contrastRatio(p.white, token.light) >= Audit.Threshold.text, "white text on \(token.name) (light)")
            expect(Audit.contrastRatio(p.white, token.dark) >= Audit.Threshold.text, "white text on \(token.name) (dark)")
            expect(rows.contains { $0.foreground == p.white && $0.background == token.dark && $0.role == .text }, "\(token.name): white-on-dark-fill row present")
        }
    }
    expect(byName["success text on its 13% wash over light grouped background (light)"] != nil, "generated row naming")
    expectEqual(Audit.maximumTextWashAlpha, 0.13, "wash ceiling is the status badge's 13%")

    // Baselines: why the system hues left the views (light mode, white row).
    let systemLight: [(String, String)] = [("green", "#34c759"), ("orange", "#ff9500"), ("mint", "#00c7be"), ("cyan", "#32ade6")]
    for (hue, hex) in systemLight {
        let color = RGB(hex: hex)!
        expect(Audit.contrastRatio(color, p.white) < Audit.Threshold.nonText, "baseline: system \(hue) on white fails even 3:1")
    }
    let systemWashFails: [(String, String)] = [("blue", "#007aff"), ("indigo", "#5856d6"), ("purple", "#af52de")]
    for (hue, hex) in systemWashFails {
        let color = RGB(hex: hex)!
        let wash = Audit.composite(color, alpha: Audit.maximumTextWashAlpha, over: p.systemGroupedLight)
        expect(Audit.contrastRatio(color, wash) < Audit.Threshold.text, "baseline: system \(hue) on its wash fails text AA")
    }
    let rnDanger = RGB(hex: "#b8432b")!
    expect(Audit.contrastRatio(rnDanger, Audit.composite(rnDanger, alpha: 0.13, over: p.systemGroupedLight)) < Audit.Threshold.text,
           "baseline: RN danger #b8432b on its 13% wash fails (why A29 darkened danger text)")
    for (hue, hex) in [("green", "#34c759"), ("orange", "#ff9500"), ("red", "#ff3b30")] {
        expect(Audit.contrastRatio(p.white, RGB(hex: hex)!) < Audit.Threshold.text, "baseline: white on system \(hue) swipe fails text AA")
    }

    // 1. No system hue in an app view (the widget canvas and Domain excluded).
    let hue = try! NSRegularExpression(pattern: systemHuePattern)
    let uikit = try! NSRegularExpression(pattern: uikitSystemColorPattern)
    var textTokenUses: [String: Int] = [:]
    let appSources = sources.filter { !$0.relativePath.hasPrefix("Widgets/") && !$0.relativePath.hasPrefix("Domain/") && !$0.relativePath.hasPrefix(widgetTargetPrefix) }
    for source in appSources {
        let text = source.codeText
        let ns = text as NSString
        let mintActions = nonColorMintLocations(in: text)
        for match in hue.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if ns.substring(with: match.range(at: 1)) == "mint", mintActions.contains(match.range.location) { continue }
            expect(false, "system hue \(ns.substring(with: match.range)) at N/\(source.relativePath):\(source.line(of: match.range.location)); use a semantic token (A29)")
        }
        for match in uikit.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            expect(false, "UIKit system color \(ns.substring(with: match.range)) at N/\(source.relativePath):\(source.line(of: match.range.location)); use a semantic token (A29, m3)")
        }
        for name in textTokens { textTokenUses[name, default: 0] += source.occurrences(of: name).count }
    }
    for name in textTokens.sorted() {
        expect((textTokenUses[name] ?? 0) > 0, "\(name) is used by a view")
    }

    // 2. Foreground styles carry only text tokens (or the tint): a helper
    //    that hands a fill, the ink or the canvas to text fails here.
    let allowedForeground = textTokens.union(["tradeReady"])
    let tradeIdentifier = try! NSRegularExpression(pattern: #"\btrade[A-Z]\w*"#)
    for source in appSources {
        for name in ["foregroundStyle", "foregroundColor"] {
            for index in source.occurrences(of: name) {
                let open = source.skipSpace(index + name.count)
                guard open < source.code.count, source.code[open] == "(", let close = source.matching(open) else { continue }
                let args = source.codeSlice(open..<(close + 1))
                let ns = args as NSString
                for match in tradeIdentifier.matches(in: args, range: NSRange(location: 0, length: ns.length)) {
                    let id = ns.substring(with: match.range)
                    expect(allowedForeground.contains(id), "N/\(source.relativePath):\(source.line(of: index)): \(name) uses \(id); text needs a text token (A29)")
                }
            }
        }
    }

    // 3. Fills, the ink and the canvas only fill: every use sits inside a
    //    tint, background or fill call (a helper returning one is caught too).
    for source in appSources {
        for name in fillTokens.union(["tradeInk", "tradeCanvas"]) {
            for index in source.occurrences(of: name) {
                // The declarations themselves (N/Models.swift).
                if index >= 11, String(source.code[(index - 11)..<index]) == "static let " { continue }
                let calls = enclosingCalls(source, at: index).filter { $0 != "LinearGradient" && $0 != "" }
                let first = calls.first ?? "(none)"
                // `overlay` is the tinted divider hairline in MoneyView.
                expect(["tint", "background", "fill", "overlay", "scrollContentBackground", "listRowBackground", "toolbarBackground"].contains(first),
                       "N/\(source.relativePath):\(source.line(of: index)): \(name) inside \(first); fills are surfaces only (A29)")
            }
        }
        // Tints (fix round 1, m2). A fill tints only what draws white on it:
        // a swipe action or a `.borderedProminent` chain. A text token tints
        // only a `.bordered` chain, which draws the tint as its label.
        for index in source.occurrences(of: "tint") where index > 0 && source.code[index - 1] == "." {
            let open = source.skipSpace(index + 4)
            guard open < source.code.count, source.code[open] == "(", let close = source.matching(open) else { continue }
            let args = source.codeSlice(open..<(close + 1))
            let chain = chainLines(source, at: index)
            let where_ = "N/\(source.relativePath):\(source.line(of: index))"
            if fillTokens.contains(where: { args.contains($0) }) {
                let inSwipe = enclosingOwners(source, at: index).contains("swipeActions")
                let prominent = chain.contains(".borderedProminent") || chain.contains("tradeReadyProminentButtonStyle")
                expect(inSwipe || prominent, "\(where_): .tint\(args) with a fill outside a swipe action or .borderedProminent chain (m2)")
            }
            for name in textTokens where args.contains(name) {
                expect(chain.contains("buttonStyle(.bordered)"), "\(where_): .tint(\(name)) outside a .bordered chain; a tint under white text needs a fill token (A29)")
            }
        }
    }

    // 4. Every swipe action has a fill tint (white on system red, green and
    //    orange measured 3.55, 2.22 and 2.20:1).
    var swipeButtons = 0
    for source in appSources {
        for index in source.occurrences(of: "swipeActions") {
            var open = source.skipSpace(index + "swipeActions".count)
            if open < source.code.count, source.code[open] == "(", let close = source.matching(open) { open = source.skipSpace(close + 1) }
            guard open < source.code.count, source.code[open] == "{", let close = source.matching(open) else {
                expect(false, "N/\(source.relativePath):\(source.line(of: index)): swipeActions block parsed"); continue
            }
            let block = source.codeSlice(open..<(close + 1))
            let buttons = block.components(separatedBy: "Button").count - 1
            let tints = try! NSRegularExpression(pattern: #"\.tint\(([^()]*)\)"#)
            let ns = block as NSString
            let tintArgs = tints.matches(in: block, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            expectEqual(tintArgs.count, buttons, "N/\(source.relativePath):\(source.line(of: index)): every swipe button has a tint")
            for arg in tintArgs {
                expect(fillTokens.contains { arg.contains($0) }, "N/\(source.relativePath):\(source.line(of: index)): swipe tint \(arg) is a fill token")
            }
            swipeButtons += buttons
        }
    }
    expectEqual(swipeButtons, 10, "swipe buttons audited")

    // 5. Tinted washes stay within the proven 13% (fix round 1, m1): every
    //    literal opacity in an app view, wherever it sits (a `.background(…)`,
    //    a `.background { }` closure, a helper that returns the wash), unless
    //    it is a reviewed non-text or proven use.
    let opacity = try! NSRegularExpression(pattern: #"\.opacity\(([0-9.]+)\)"#)
    var strongSeen = Array(repeating: 0, count: strongOpacityAllowlist.count)
    for source in appSources {
        let text = source.codeText
        let ns = text as NSString
        for match in opacity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let alpha = Double(ns.substring(with: match.range(at: 1))), alpha > Audit.maximumTextWashAlpha + 1e-9 else { continue }
            let lineNumber = source.line(of: match.range.location)
            // The marker must end at this opacity call.
            let end = match.range.location + match.range.length
            let allowed = strongOpacityAllowlist.firstIndex { entry in
                entry.file == source.relativePath && entry.marker.count <= end
                    && ns.substring(with: NSRange(location: end - (entry.marker as NSString).length, length: (entry.marker as NSString).length)) == entry.marker
            }
            if let allowed { strongSeen[allowed] += 1 }
            expect(allowed != nil, "N/\(source.relativePath):\(lineNumber): opacity \(alpha) exceeds the proven \(Audit.maximumTextWashAlpha) wash")
        }
    }
    for (index, entry) in strongOpacityAllowlist.enumerated() {
        expectEqual(strongSeen[index], 1, "strong-opacity allowlist entry used once: \(entry.file) \(entry.marker) (\(entry.reason))")
    }
    expect(requirements.contains { $0.name == "primary text on the 18% coach user bubble (light)" }, "coach user bubble row present")

    // 7. Destructive buttons (fix round 1, I1). The role stays for VoiceOver
    //    and the system; a button the app draws in a row sets its label to
    //    `tradeDangerText` (system red text measured 3.55:1), and one inside an
    //    alert, dialog, swipe or context menu is system-drawn (§12.1 A31).
    var inRowDestructive = 0
    for source in appSources {
        for index in source.occurrences(of: "destructive") where index >= 7 && String(source.code[(index - 7)..<index]) == "role: ." {
            let owners = enclosingOwners(source, at: index)
            let where_ = "N/\(source.relativePath):\(source.line(of: index))"
            if owners.contains(where: { systemDrawnOwners.contains($0) }) { continue }
            if let helper = dialogActionHelpers.first(where: { $0.file == source.relativePath && owners.contains("func:" + $0.function) }) {
                // Every call of the helper sits in a system-drawn container or another listed helper.
                for call in source.occurrences(of: helper.function) {
                    let next = source.skipSpace(call + helper.function.count)
                    guard next < source.code.count, source.code[next] == "(" else { continue }
                    if call >= 5, String(source.code[(call - 5)..<call]) == "func " { continue }
                    let callOwners = enclosingOwners(source, at: call)
                    let placed = callOwners.contains { systemDrawnOwners.contains($0) }
                        || dialogActionHelpers.contains { $0.file == source.relativePath && callOwners.contains("func:" + $0.function) }
                    expect(placed, "N/\(source.relativePath):\(source.line(of: call)): \(helper.function)(…) used outside an alert, dialog or menu")
                }
                continue
            }
            // An in-row button: `Button(…, role: .destructive) … label: { … .nativeDestructiveText() }`.
            inRowDestructive += 1
            guard let button = owners.firstIndex(of: "Button") else {
                expect(false, "\(where_): in-row role: .destructive outside a Button; give it a text-token label"); continue
            }
            _ = button
            let window = source.codeSlice(index..<min(source.code.count, index + 700))
            let labelStart = window.range(of: "label: {")
            let nextButton = window.range(of: "Button(")
            let hasLabel = labelStart != nil && (nextButton == nil || labelStart!.lowerBound < nextButton!.lowerBound)
            expect(hasLabel, "\(where_): in-row destructive button has no label closure; use label: { … .nativeDestructiveText() } (I1)")
            if let labelStart {
                let body = String(window[labelStart.upperBound...].prefix(300))
                let closing = body.firstIndex(of: "}") ?? body.endIndex
                expect(body[..<closing].contains(".nativeDestructiveText()"),
                       "\(where_): in-row destructive label lacks .nativeDestructiveText(); system red text measures 3.55:1 (I1)")
            }
        }
    }
    expectEqual(inRowDestructive, 12, "in-row destructive buttons audited")
    if let views = file(sources, "NativeAccessibilityViews.swift") {
        let raw = String(views.raw)
        expect(raw.contains("func nativeDestructiveText() -> some View {\n        modifier(NativeDestructiveText())"),
               "nativeDestructiveText is the modifier")
        expect(raw.contains("content.foregroundStyle(isEnabled ? Color.tradeDangerText : Color.secondary)"),
               "nativeDestructiveText applies tradeDangerText, and the secondary color when disabled")
    }
    if let booking = file(sources, "NativeBookingRequestsView.swift") {
        let text = String(booking.raw)
        let decline = text.range(of: "Button(role: .destructive) { Task { await onDecline() } }").map { String(text[$0.lowerBound...].prefix(300)) } ?? ""
        expect(decline.contains("Text(\"Decline\").nativeDestructiveText()"), "bordered Decline label is tradeDangerText")
        expect(decline.contains(".buttonStyle(.bordered)") && decline.contains(".tint(Color.tradeDangerText)"),
               "bordered Decline washes its own text token, proven at 15%")
    }
    for ground in ["white list row", "light grouped background", "dark list row", "dark sheet list row"] {
        expect(requirements.contains { $0.name == "danger text on its 15% .bordered wash over \(ground)" }, "bordered Decline row over \(ground)")
        expect(requirements.contains { $0.name == "danger text on a 15% system-red .bordered wash over \(ground)" }, "bordered Decline system-red row over \(ground)")
    }
    // A31 baseline: the reviewer's measurement of the old Decline.
    let red = RGB(hex: "#ff3b30")!
    expectClose(Audit.contrastRatio(red, Audit.composite(red, alpha: Audit.borderedWashAlpha, over: p.white)), 2.90, tolerance: 0.01,
                "baseline: system red on its 15% .bordered wash measured 2.90")

    // 6. The helpers that carry status colors.
    if let models = read(root, "native/TradeReadyNative/Models.swift") {
        let body = models.range(of: "var color: Color {").map { String(models[$0.upperBound...].prefix(500)) } ?? ""
        for name in ["tradeInfoText", "tradeWarningText", "tradeMintText", "tradeIndigoText", "tradePurpleText", "tradeSuccessText", "tradeCyanText"] {
            expect(body.contains(name), "JobStatus.color uses \(name)")
        }
    }

    // The detectors themselves.
    let uikitFixture = "Color(.systemGreen)\nUIColor.systemRed\nColor(uiColor: .systemOrange)\nColor(.systemGroupedBackground)\nColor(.secondarySystemBackground)"
    expectEqual(uikit.numberOfMatches(in: uikitFixture, range: NSRange(location: 0, length: (uikitFixture as NSString).length)), 3,
                "UIKit system-color detector: 3 hues, not the grouped backgrounds")
    let mintFixture = "try await mutate(action: .mint, id: 1)\nif action == .mint || x\ncase .mint:\nbusyAction = .mint\nText(a).foregroundStyle(.mint)\ncase .approved: .mint"
    let mintNS = mintFixture as NSString
    let mintAll = hue.matches(in: mintFixture, range: NSRange(location: 0, length: mintNS.length)).map(\.range.location)
    let mintActions = nonColorMintLocations(in: mintFixture)
    expectEqual(mintAll.filter { !mintActions.contains($0) }.count, 2, ".mint detector: the two color uses fail, the four action uses pass")
    let dialogFixture = SourceFile(relativePath: "Fixture.swift", text: "x.confirmationDialog(\"t\", isPresented: $p) {\n  Button(\"Delete\", role: .destructive) {}\n}\nSection {\n  Button(\"Sign out\", role: .destructive) {}\n}")
    let dialogRoles = dialogFixture.occurrences(of: "destructive").map { enclosingOwners(dialogFixture, at: $0).contains("confirmationDialog") }
    expectEqual(dialogRoles, [true, false], "destructive detector: the dialog button is system-drawn, the section one is in-row")
    let fixture = "Text(a).foregroundStyle(.green)\n.tint(ok ? Color.blue : .orange)\ncase .lead: .indigo\nlet x = rgb.green + UIColor(red: 1, green: 0, blue: 0) + c.orange\nawait administer(.mint)"
    let fixtureMatches = hue.matches(in: fixture, range: NSRange(location: 0, length: (fixture as NSString).length))
    expectEqual(fixtureMatches.count, 5, "system-hue detector: 4 colors and the .mint action, not RGB components")
    let helper = SourceFile(relativePath: "Fixture.swift", text: "var c: Color { ok ? .tradeSuccessFill : .secondary }\nText(a).background(ok ? Color.tradeReadyFill : .clear, in: Capsule())")
    let helperCalls = helper.occurrences(of: "tradeSuccessFill").map { enclosingCalls(helper, at: $0).first ?? "(none)" }
    expectEqual(helperCalls, ["(none)"], "fill detector flags a helper that returns a fill")
    expectEqual(helper.occurrences(of: "tradeReadyFill").map { enclosingCalls(helper, at: $0).first ?? "(none)" }, ["background"], "fill detector allows a background")
}

// MARK: A17, A13, A25, A26 and the white-text allowlist

func testReAuditSites(root: URL, sources: [SourceFile]) {
    // A17: the job-photo error badge is announced.
    if let photos = file(sources, "NativeJobPhotosView.swift") {
        let thumb = structText(photos, "PhotoThumbnail")
        expect(thumb.contains(".accessibilityValue(error ?? \"\")"), "photo thumbnail announces its error (A17)")
        expect(thumb.contains("exclamationmark.triangle.fill"), "photo error badge found")
    }
    // A13 + A25: the Today job card's "On my way".
    if let today = file(sources, "NativeTodayComponents.swift") {
        let card = structText(today, "NativeTodayJobCard")
        let buttons = scanControls(SourceFile(relativePath: "NativeTodayComponents.swift", text: card))
            .filter { $0.raw.hasPrefix("Button(action: onOnMyWay)") }
        expectEqual(buttons.count, 1, "Today job card On my way button found")
        // Fix round 1 (m7): the 44pt target is a hit outset, like RN's hitSlop,
        // so the card's status row keeps its height.
        let raw = buttons.first?.raw ?? ""
        expect(raw.contains(".frame(minWidth: NativeAccessibilityAudit.minimumTouchTarget)"), "On my way is at least 44pt wide (A25)")
        expect(raw.contains(".padding(.vertical, NativeAccessibilityAudit.InlineLink.verticalOutset)\n")
               && raw.contains(".contentShape(Rectangle())")
               && raw.contains(".padding(.vertical, -NativeAccessibilityAudit.InlineLink.verticalOutset)"),
               "On my way pads its hit shape and takes the padding back out of layout (m7)")
        expect(!raw.contains("minHeight:"), "On my way no longer grows the card row (m7)")
        expect(Audit.InlineLink.smallestCaptionLineHeight + 2 * Audit.InlineLink.verticalOutset >= Audit.minimumTouchTarget,
               "On my way hit height ≥ 44pt at the smallest text size (A25)")
        expect(buttons.first?.raw.contains(".accessibilityLabel(NativeAccessibilityAudit.Label.onMyWay(customerName: job.customerName))") == true,
               "On my way keeps RN's label")
        expect(card.contains(".accessibilityActions {"), "the card offers On my way as a VoiceOver action (A13)")
        expect(card.contains("Button(NativeAccessibilityAudit.Label.onMyWay(customerName: job.customerName), action: onOnMyWay)"),
               "the card action uses RN's label")
    }
    if let rn = read(root, "screens/TodayScreen.tsx") {
        expect(rn.contains("accessibilityLabel={`On my way to ${job.customerName}`}"), "RN parity: On my way to ${job.customerName}")
    } else { expect(false, "RN TodayScreen.tsx readable") }
    expectEqual(Audit.Label.onMyWay(customerName: "Dana Ruiz"), "On my way to Dana Ruiz", "on my way label")

    // A26: the map stop number is white on a fill capsule.
    if let route = file(sources, "NativeRouteView.swift") {
        let text = String(route.raw)
        let number = text.range(of: "Text(\"\\(annotation.order)\")").map { String(text[$0.lowerBound...].prefix(600)) } ?? ""
        expect(number.contains(".background(Color.tradeReadyFill, in: Capsule())"), "map stop number sits on the fill, not on the map (A26)")
    }

    // White text or glyphs only where a fill under them is proven.
    let allowed: [String: Int] = ["SettingsView.swift": 1, "NativeTodayComponents.swift": 5, "NativeRouteView.swift": 1]
    let white = try! NSRegularExpression(pattern: #"\.foreground(?:Style|Color)\((?:Color)?\.white\)"#)
    for source in sources where !source.relativePath.hasPrefix("Widgets/") {
        let text = source.codeText
        let count = white.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        expectEqual(count, allowed[source.relativePath] ?? 0, "white foregrounds in N/\(source.relativePath) are the audited on-fill sites")
    }

    // A18 baseline: why the clock-out button left system red.
    let p = Audit.Palette.self
    expect(Audit.contrastRatio(p.white, p.systemRedDark) < Audit.Threshold.text, "baseline: white on dark system red fails text AA")
    expect(Audit.contrastRatio(p.white, p.systemRedLight) < Audit.Threshold.text, "baseline: white on light system red fails text AA")
    let rnDanger = RGB(hex: "#b8432b")!
    expectEqual(p.dangerFillLight, RGB(red: 0.722, green: 0.263, blue: 0.169), "light danger fill literal")
    expectClose(p.dangerFillLight.red, rnDanger.red, tolerance: 0.001, "light danger fill = RN lightColors.danger (red)")
    expectClose(p.dangerFillLight.green, rnDanger.green, tolerance: 0.001, "light danger fill = RN lightColors.danger (green)")
    expectClose(p.dangerFillLight.blue, rnDanger.blue, tolerance: 0.001, "light danger fill = RN lightColors.danger (blue)")
    if let theme = read(root, "utils/theme.ts") {
        expect(theme.contains(##"danger: "#b8432b""##), "RN lightColors.danger is #b8432b")
    }
}

// MARK: - 11.13 A30: invoice and estimate PDF contrast

/// The first `#rrggbb` after `marker` in `text`.
func hexAfter(_ marker: String, in text: String) -> RGB? {
    guard let start = text.range(of: marker) else { return nil }
    let tail = text[start.upperBound...]
    guard let hash = tail.firstIndex(of: "#") else { return nil }
    return RGB(hex: String(tail[hash...].prefix(7)))
}

func testDocumentPDFContrast(root: URL) {
    // Baseline: the literals the renderers shipped before 11.13 (contract §12.1 A30).
    let white = Audit.Palette.white
    let oldAccent = RGB(red: 0, green: 0.478, blue: 1)
    let oldBadges: [(String, RGB, RGB, Double)] = [
        ("PAID", RGB(red: 0.15, green: 0.65, blue: 0.36), RGB(red: 0.91, green: 0.98, blue: 0.94), 2.90),
        ("OUTSTANDING", RGB(red: 0.77, green: 0.48, blue: 0), RGB(red: 1, green: 0.95, blue: 0.88), 3.09),
        ("PARTLY PAID", RGB(red: 0.18, green: 0.44, blue: 0.82), RGB(red: 0.92, green: 0.95, blue: 1), 4.28),
    ]
    let oldAccentRatio = Audit.contrastRatio(oldAccent, white)
    expectClose(oldAccentRatio, 4.02, "A30 baseline: old PDF accent on white measured 4.02")
    expect(oldAccentRatio < Audit.Threshold.text, "A30 baseline: old accent fails text AA")
    for (label, text, fill, measured) in oldBadges {
        let ratio = Audit.contrastRatio(text, fill)
        expectClose(ratio, measured, "A30 baseline: old \(label) badge measured \(measured)")
        expect(ratio < Audit.Threshold.text, "A30 baseline: old \(label) badge fails text AA")
    }

    // RN's template ships the same failing hues: the fix is a native difference.
    if let rn = read(root, "utils/pdfTemplates.ts") {
        let rnPairs: [(String, RGB?, RGB?)] = [
            ("accent on white", hexAfter("const ACCENT =", in: rn), white),
            ("badge-paid", hexAfter(".badge-paid   { background: #e8f9f0; color:", in: rn), hexAfter(".badge-paid", in: rn)),
            ("badge-unpaid", hexAfter(".badge-unpaid { background: #fff3e0; color:", in: rn), hexAfter(".badge-unpaid", in: rn)),
            ("badge-partial", hexAfter(".badge-partial { background: #eaf2ff; color:", in: rn), hexAfter(".badge-partial", in: rn)),
        ]
        for (name, foreground, background) in rnPairs {
            guard let foreground, let background else {
                expect(false, "RN pdfTemplates.ts \(name) colours parse"); continue
            }
            let ratio = Audit.contrastRatio(foreground, background)
            expect(ratio < Audit.Threshold.text,
                   "RN PDF \(name) \(String(format: "%.2f", ratio)):1 still fails (A30 is a native difference)")
        }
    } else {
        expect(false, "utils/pdfTemplates.ts readable")
    }

    // The shipped document palette meets every role minimum.
    let requirements = Audit.documentContrastRequirements
    expect(requirements.count >= 12, "document contrast table is populated (\(requirements.count))")
    expectEqual(Set(requirements.map(\.name)).count, requirements.count, "document requirement names are unique")
    for requirement in requirements {
        let ratio = Audit.contrastRatio(requirement.foreground, requirement.background)
        expect(ratio >= requirement.role.minimum,
               "PDF \(requirement.name): \(String(format: "%.2f", ratio)):1 ≥ \(requirement.role.minimum):1")
    }
    let d = Audit.DocumentPalette.self
    let namedPairs: [(String, RGB, RGB)] = [
        ("accent business name on white", d.accent, d.page),
        ("accent total on the total wash", d.accent, d.totalWash),
        ("PAID badge", d.paidBadgeText, d.paidBadgeFill),
        ("OUTSTANDING badge", d.outstandingBadgeText, d.outstandingBadgeFill),
        ("PARTLY PAID badge", d.partlyPaidBadgeText, d.partlyPaidBadgeFill),
    ]
    for (name, foreground, background) in namedPairs {
        let present = requirements.contains { row in
            row.foreground == foreground && row.background == background && row.role == .text
        }
        expect(present, "document requirement row for \(name)")
    }

    // Both renderers take every colour from the palette: no literal remains.
    for path in ["native/TradeReadyNative/NativeInvoicePDF.swift", "native/TradeReadyNative/NativeEstimatePDF.swift"] {
        guard let text = read(root, path) else { expect(false, "\(path) readable"); continue }
        expect(!text.contains("UIColor(red:") && !text.contains("UIColor(white:"),
               "\(path) has no literal UIColor (A30 palette only)")
        for token in ["DocumentPalette.accent", "DocumentPalette.ink", "DocumentPalette.secondary",
                      "DocumentPalette.rule", "DocumentPalette.totalWash"] {
            expect(text.contains(token), "\(path) uses \(token)")
        }
    }
    if let invoice = read(root, "native/TradeReadyNative/NativeInvoicePDF.swift") {
        for token in ["paidBadgeFill", "paidBadgeText", "partlyPaidBadgeFill", "partlyPaidBadgeText",
                      "outstandingBadgeFill", "outstandingBadgeText"] {
            expect(invoice.contains("DocumentPalette.\(token)"), "invoice badge uses DocumentPalette.\(token)")
        }
    }
}

// MARK: - Entry

@main
struct AccessibilityAuditTests {
    static func main() {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sources = loadSources(root: root)
        // 11.10b: the widget extension target's own view files join the scans.
        let allSources = sources + loadWidgetTargetSources(root: root)

        testContrastMath()
        testContrastRequirements()
        testPaletteLiteralsShipped(root: root)
        testAccentColorAsset(root: root)
        testLabelCatalog(root: root, sources: sources)
        testIconOnlyControls(sources: allSources)
        testReduceMotion(sources: sources)
        testDynamicType(sources: sources)
        testTouchTargets(sources: sources)
        testFills(sources: sources)
        testFocusOrder(sources: sources)
        testTranslucentWhite(sources: allSources)
        testMoneyCardLabels(root: root, sources: sources)
        // 11.10b re-audit.
        testViewInventory(allSources: allSources)
        testShortcutTitles(sources: allSources)
        testReturnKeysAndDismissal(root: root, sources: sources)
        testRunnersCompileDoneBar(root: root, sources: sources)
        testChartSummaries(sources: sources)
        testFixedFrames(sources: allSources)
        testReAuditSites(root: root, sources: sources)
        testDangerText(root: root, sources: sources)
        testSemanticColors(root: root, sources: sources)
        // 11.13 A30.
        testDocumentPDFContrast(root: root)

        if failures > 0 {
            print("accessibility-audit tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("accessibility-audit tests: \(checks)/\(checks) checks passed")
    }
}
