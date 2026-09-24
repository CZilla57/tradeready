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
    var location: String { "N/\(file.relativePath):\(line)" }

    static let nonTextViews: Set<String> = [
        "Image", "HStack", "VStack", "ZStack", "Group", "Spacer", "Circle", "Rectangle",
        "RoundedRectangle", "Capsule", "ProgressView", "Color", "EmptyView", "Divider", "AnyView",
        "UIImage", "Font", "CGSize", "EdgeInsets", "Animation", "LinearGradient", "Angle",
    ]

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
    ]
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
    let known: [(file: String, kind: String, marker: String)] = [
        ("InvoicesView.swift", "Button", "Image(systemName: \"plus\")"),
        ("JobsView.swift", "Button", "Image(systemName: \"plus\")"),
        ("NativeRecurringInvoicesView.swift", "Button", "Image(systemName: \"plus\")"),
        ("CustomersView.swift", "Button", "Image(systemName: \"plus\")"),
        ("NativeBookingRequestsView.swift", "Button", "contactIcon(target.action)"),
        ("NativeRouteView.swift", "Menu", "arrow.up.arrow.down"),
    ]
    for site in known {
        let matches = constructs.filter {
            $0.file.relativePath == site.file && $0.kind == site.kind && ($0.labelCode ?? "").contains(site.marker)
        }
        guard let match = matches.first else {
            expect(false, "known finding not found: \(site.kind) with \(site.marker) in N/\(site.file)"); continue
        }
        expectEqual(matches.count, 1, "known finding unique: \(site.file) \(site.marker)")
        expect(match.isIconOnly, "known finding classified icon-only: \(match.location)")
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
                expect(tail.contains(".tint(summary.isClocked ? .red : .tradeReadyFill)"),
                       "time tracking prominent button re-tints to tradeReadyFill")
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

// MARK: - Entry

@main
struct AccessibilityAuditTests {
    static func main() {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let sources = loadSources(root: root)

        testContrastMath()
        testContrastRequirements()
        testPaletteLiteralsShipped(root: root)
        testAccentColorAsset(root: root)
        testLabelCatalog(root: root, sources: sources)
        testIconOnlyControls(sources: sources)
        testReduceMotion(sources: sources)
        testDynamicType(sources: sources)
        testTouchTargets(sources: sources)
        testFills(sources: sources)
        testFocusOrder(sources: sources)
        testTranslucentWhite(sources: sources)
        testMoneyCardLabels(root: root, sources: sources)

        if failures > 0 {
            print("accessibility-audit tests: \(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("accessibility-audit tests: \(checks)/\(checks) checks passed")
    }
}
