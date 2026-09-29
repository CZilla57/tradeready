import Foundation

// MARK: - Coach system prompt (task 10.10, requirement C2)
//
// Byte-for-byte port of `screens/ChatScreen.tsx#buildSystemPrompt`. There is
// no RN unit-test oracle for this function (it lives inside a screen
// component); the fixtures pinned in `CoachPromptTests` were captured by
// running the exact function body — copied verbatim, including the
// `utils/pricingEngine.ts` `TRADE_TYPES` table — through a scratch Node probe
// and recording its output (see the 10.10 report for the probe transcript).
//
// Two behaviors worth flagging because they read as bugs on first glance but
// are exactly what RN does:
//  - The `BUSINESS DATA` block is built as its own template literal starting
//    with "\n\n" and then `.trim()`-ed BEFORE being appended — the leading
//    "\n\n" is trimmed away, so "USD only." is followed immediately by
//    "BUSINESS DATA" with no separator at all. The tax block, appended after
//    with its own leading "\n" (never trimmed), does keep a line break.
//  - `s.laborRate || 85` etc. is a JS truthy fallback (0 is falsy), and the
//    values are interpolated as plain JS numbers (no `toFixed`) — so `87.5`
//    prints as "87.5", not "87.50" or "88". The money fields inside the
//    BUSINESS DATA/tax blocks DO call `.toFixed(0)` in RN and are ported with
//    whole-dollar rounding here.
//
// Native difference (recorded, not a defect): `activeJobsByStatus` is a plain
// RN object whose `Object.entries()` order is "first job status encountered
// while iterating the jobs array" — an ordering `NativeBusinessSnapshotEngine`
// (10.01) does not preserve, because its `activeJobsByStatus` is a Swift
// `[String: Int]` (unordered) built the same way RN's partial-record contract
// requires (only non-zero statuses present). No RN oracle test pins the
// status-line order in the prompt text itself (`businessSnapshot.test.js`
// only asserts the count map with `toEqual`, which is order-insensitive), so
// this file renders statuses in the fixed pipeline order
// (`lead, estimate_sent, approved, scheduled, in_progress`) rather than an
// unrecoverable "first encountered" order.

enum NativeCoachPrompt {
    /// `utils/pricingEngine.ts` `TRADE_TYPES` — id -> display label.
    static let tradeLabels: [String: String] = [
        "plumbing": "Plumbing",
        "electrical": "Electrical",
        "hvac": "HVAC",
        "carpenter": "Carpentry",
        "bricklayer": "Bricklaying",
        "plasterer": "Plastering",
        "landscaping": "Landscaping",
        "cleaning": "Cleaning",
        "painting": "Painting",
        "handyman": "Handyman",
        "other": "Other",
    ]

    /// Fixed, documented rendering order for `activeJobsByStatus` (see the
    /// native-difference note above).
    static let statusOrder = ["lead", "estimate_sent", "approved", "scheduled", "in_progress"]

    static func buildSystemPrompt(settings: Canonical.Settings, snapshot: NativeBusinessSnapshot?) -> String {
        let trade = tradeLabels[settings.trade] ?? "Trades"
        let who = [settings.businessName, trade, settings.contactName]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let region = settings.region ?? ""
        let regionStr = region.isEmpty ? "" : " Region: \(region)."

        let laborRate = settings.laborRate != 0 ? settings.laborRate : 85
        let materialMarkup = settings.materialMarkup != 0 ? settings.materialMarkup : 20
        let overheadPercent = settings.overheadPercent != 0 ? settings.overheadPercent : 15
        let marginPercent = settings.marginPercent != 0 ? settings.marginPercent : 20
        let minimumJobFee = settings.minimumJobFee != 0 ? settings.minimumJobFee : 75

        var prompt = "Assistant for \(who).\(regionStr) Rates: $\(jsNumber(laborRate))/hr labor, " +
            "\(jsNumber(materialMarkup))% materials markup, \(jsNumber(overheadPercent))% overhead, " +
            "\(jsNumber(marginPercent))% margin, $\(jsNumber(minimumJobFee)) min fee. " +
            "Be brief. Itemize estimates. USD only."

        if let snapshot {
            let statusLines = statusOrder
                .compactMap { status -> String? in
                    guard let count = snapshot.activeJobsByStatus[status], count > 0 else { return nil }
                    return "\(count) \(status.replacingFirstOccurrence(of: "_", with: " "))"
                }
                .joined(separator: ", ")

            let custLines = snapshot.topCustomers
                .map { customer -> String in
                    let owed = customer.amountOwed > 0 ? ", owes $\(toFixed0(customer.amountOwed))" : ""
                    return "\(customer.name) ($\(toFixed0(customer.lifetimeSpend)) lifetime\(owed))"
                }
                .joined(separator: "; ")

            let overdueStr: String
            if snapshot.overdueCount > 0 {
                let plural = snapshot.overdueCount == 1 ? "" : "s"
                overdueStr = " ($\(toFixed0(snapshot.overdueTotal)) overdue, \(snapshot.overdueCount) invoice\(plural))"
            } else {
                overdueStr = ""
            }

            let avgLine = snapshot.avgCompletedJobValue > 0
                ? "Avg completed job: $\(toFixed0(snapshot.avgCompletedJobValue))."
                : ""

            let block = """


            BUSINESS DATA (\(snapshot.asOf)):
            Revenue: $\(toFixed0(snapshot.revenueThisMonth)) this month, $\(toFixed0(snapshot.revenueLastMonth)) last month.
            Outstanding: $\(toFixed0(snapshot.outstandingTotal))\(overdueStr).
            Active jobs: \(statusLines.isEmpty ? "none" : statusLines).
            Customers: \(snapshot.totalCustomers) total\(custLines.isEmpty ? "" : ". Top: \(custLines)").
            \(avgLine)
            """
            // Mirrors RN's `.trim()` on the freshly-built block BEFORE
            // concatenation — the leading "\n\n" is deliberately lost.
            prompt += block.trimmingCharacters(in: .whitespacesAndNewlines)

            if let tax = snapshot.tax {
                var caveats = ""
                if !tax.incomeRateSet { caveats += " Income-tax rate not set — figure is SE tax only." }
                if tax.needsVehicleChoice { caveats += " Vehicle deduction method not chosen." }
                prompt += "\nTax set-aside estimate: $\(toFixed0(tax.periodReserve)) for \(tax.periodLabel) " +
                    "(set aside by \(tax.dueLabel)); $\(toFixed0(tax.yearToDateReserve)) year to date.\(caveats) " +
                    "You may cite these as set-aside guidance only — for filing, deduction elections, " +
                    "eligibility, or business-entity questions, decline and refer the user to a tax professional."
            }
        }

        return prompt
    }

    // MARK: Number formatting

    /// JS's default `${number}` stringification — used for the plain rate
    /// fields, which RN never runs through `toFixed`.
    static func jsNumber(_ value: Decimal) -> String {
        let double = NSDecimalNumber(decimal: value).doubleValue
        if double.truncatingRemainder(dividingBy: 1) == 0, abs(double) < 1e15 {
            return String(Int64(double))
        }
        return String(double)
    }

    /// `value.toFixed(0)` — whole-dollar, half-away-from-zero rounding, no
    /// grouping separator (matches the `NativeCSVExport.toFixed2` precedent).
    static func toFixed0(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "0"
    }
}

private extension String {
    /// JS `String.prototype.replace(str, replacement)` (first occurrence only,
    /// not `replaceAll`) — statuses carry at most one underscore, but this
    /// matches the exact RN semantics rather than assuming that.
    func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
        guard let range = self.range(of: target) else { return self }
        return self.replacingCharacters(in: range, with: replacement)
    }
}
