import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Expense editor tests (task 9.10, requirements E1, E2).
//
// Ports the behavior the RN modal + `ExpenseRow` own, cross-checked against
// `components/money/AddExpenseModal.tsx`, `__tests__/AddExpenseModal.test.js`, and
// `utils/profitabilityDisplay.ts` (`selectLinkableJobs`):
//
//   * a scan only lands in fields the user has not touched,
//   * an unusable extract never disturbs manual entry,
//   * the job-link candidate list and its ordering,
//   * the save guards and the amount text contract,
//   * the deterministic receipt path with local-bytes-win,
//   * the OCR size contract (downscale under the cap, honest nil otherwise).

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

private let decoder = JSONDecoder()

private func job(_ id: String, status: String, createdAt: String, archivedAt: String? = nil, title: String? = nil) -> Canonical.Job {
    let archived = archivedAt.map { "\"archivedAt\":\"\($0)\"," } ?? ""
    let json = """
    {"id":"\(id)","customerId":"c1","customerName":"Test","title":"\(title ?? id)","description":"",
     "status":"\(status)",\(archived)"address":"","estimateTotal":1000,"laborHours":4,"laborRate":100,
     "materials":[],"materialMarkup":0,"overhead":15,"margin":20,"notes":"","createdAt":"\(createdAt)"}
    """
    return try! decoder.decode(Canonical.Job.self, from: Data(json.utf8))
}

private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

private func extraction(
    merchant: String? = nil,
    amount: Decimal? = nil,
    date: String? = nil,
    category: String? = nil,
    confidence: String = "high"
) -> NativeReceiptExtraction {
    NativeReceiptExtraction(merchant: merchant, amount: amount, date: date, category: category, confidence: confidence)
}

private func calendarDate(_ text: String) -> Date {
    NativeCashBasis.parseLocalDate(text)!
}

// MARK: - Job link (`selectLinkableJobs`)

private func testLinkableJobs() {
    let jobs = [
        job("lead", status: "lead", createdAt: "2026-03-05"),
        job("declined", status: "declined", createdAt: "2026-03-04"),
        job("approved", status: "approved", createdAt: "2026-03-03"),
        job("complete", status: "complete", createdAt: "2026-03-02"),
        job("archived", status: "approved", createdAt: "2026-03-06", archivedAt: "2026-03-07"),
        job("paid", status: "paid", createdAt: "2026-03-01"),
    ]
    let linkable = NativeExpenseComposer.linkableJobs(jobs).map(\.id)
    expectEqual(linkable, ["approved", "complete", "paid"], "leads, declines, and archived jobs are not linkable")

    // `alwaysIncludeId` keeps a pre-linked job even when the filter would drop it.
    let including = NativeExpenseComposer.linkableJobs(jobs, alwaysIncludeID: "lead").map(\.id)
    expectEqual(including, ["lead", "approved", "complete", "paid"], "an always-included job stays in the list")
    let archivedIncluded = NativeExpenseComposer.linkableJobs(jobs, alwaysIncludeID: "archived").map(\.id)
    expectEqual(archivedIncluded, ["archived", "approved", "complete", "paid"], "an archived pre-linked job is still offered")

    // Newest first by `createdAt`, code-unit compare (never localeCompare).
    let ordered = NativeExpenseComposer.linkableJobs([
        job("a", status: "paid", createdAt: "2026-03-05"),
        job("b", status: "paid", createdAt: "2026-03-10"),
        job("c", status: "paid", createdAt: "2026-03-01"),
    ]).map(\.id)
    expectEqual(ordered, ["b", "a", "c"], "newest first by createdAt")

    expectEqual(NativeExpenseComposer.jobTitle(id: "lead", in: jobs), "lead", "job title resolves by exact id")
    expect(NativeExpenseComposer.jobTitle(id: "missing", in: jobs) == nil, "unknown job id has no title")
    expect(NativeExpenseComposer.jobTitle(id: nil, in: jobs) == nil, "no job link has no title")
    expect(NativeExpenseComposer.jobTitle(id: "", in: jobs) == nil, "empty job id has no title")
}

// MARK: - Amount + save guards

private func testAmount() {
    expectEqual(NativeExpenseComposer.amountValue("40"), 40, "plain integer amount")
    expectEqual(NativeExpenseComposer.amountValue("40.50"), 40.5, "decimal amount")
    expectEqual(NativeExpenseComposer.amountValue("  12  "), 12, "surrounding whitespace is tolerated")
    expectEqual(NativeExpenseComposer.amountValue("40abc"), 40, "parseFloat keeps the leading numeric prefix")
    expect(NativeExpenseComposer.amountValue("abc") == nil, "non-numeric text is rejected")
    expect(NativeExpenseComposer.amountValue("0") == nil, "zero is rejected")
    expect(NativeExpenseComposer.amountValue("-5") == nil, "negative is rejected")
    expect(NativeExpenseComposer.amountValue("") == nil, "empty is rejected")
    expect(NativeExpenseComposer.amountValue("   ") == nil, "whitespace-only is rejected")

    // `Number.isInteger(n) ? String(n) : n.toFixed(2)`
    expectEqual(NativeExpenseComposer.amountText(decimal("84")), "84", "integer amount has no decimals")
    expectEqual(NativeExpenseComposer.amountText(decimal("84.5")), "84.50", "half amount pads to cents")
    expectEqual(NativeExpenseComposer.amountText(decimal("84.17")), "84.17", "cents round-trip")
    expectEqual(NativeExpenseComposer.amountText(decimal("84.567")), "84.57", "cents round half away from zero")
    expectEqual(NativeExpenseComposer.amountText(decimal("0.1")), "0.10", "tenth pads to cents")

    var draft = NativeExpenseEditorDraft.newExpense()
    expectEqual(NativeExpenseComposer.validation(draft), .missingMerchant, "empty description blocks save")
    draft.merchant = "   "
    expectEqual(NativeExpenseComposer.validation(draft), .missingMerchant, "whitespace-only description blocks save")
    draft.merchant = "Copper pipe"
    expectEqual(NativeExpenseComposer.validation(draft), .invalidAmount, "missing amount blocks save")
    draft.amountText = "0"
    expectEqual(NativeExpenseComposer.validation(draft), .invalidAmount, "zero amount blocks save")
    draft.amountText = "84.17"
    expect(NativeExpenseComposer.validation(draft) == nil, "a complete draft saves")

    // RN's alert copy, in RN's check order.
    expectEqual(NativeExpenseValidation.missingMerchant.message, "Please enter a description.", "description alert copy")
    expectEqual(NativeExpenseValidation.invalidAmount.message, "Please enter a valid amount.", "amount alert copy")
}

// MARK: - Scan application

private func testScanApply() {
    var draft = NativeExpenseEditorDraft.newExpense(now: calendarDate("2026-07-01"))
    let result = extraction(
        merchant: "Home Depot", amount: decimal("84.17"), date: "2026-07-18", category: "fuel"
    )
    let application = NativeExpenseComposer.applyingScan(result, to: &draft, touched: .init())
    expectEqual(application.applied, 4, "all four extractable fields fill")
    expectEqual(application.state, .filled, "filling anything reports 'filled'")
    expect(!application.blurry, "high confidence is not blurry")
    expectEqual(draft.merchant, "Home Depot", "merchant filled")
    expectEqual(draft.amountText, "84.17", "amount filled as text")
    expectEqual(draft.date, calendarDate("2026-07-18"), "date filled in the local frame")
    expectEqual(draft.categoryID, "fuel", "category filled")
    expectEqual(NativeExpenseComposer.validation(draft) == nil, true, "a scanned draft is saveable")

    // User typing is never clobbered.
    var typed = NativeExpenseEditorDraft.newExpense(now: calendarDate("2026-07-01"))
    typed.merchant = "Copper pipe run"
    var touched = NativeExpenseTouchedFields()
    touched.merchant = true
    let partial = NativeExpenseComposer.applyingScan(result, to: &typed, touched: touched)
    expectEqual(typed.merchant, "Copper pipe run", "typed description survives the scan")
    expectEqual(partial.applied, 3, "only the untouched fields fill")
    expectEqual(typed.amountText, "84.17", "untouched amount still fills")

    // Every field is touched → "nothing new to fill in".
    var allTouched = typed
    allTouched.amountText = "40"
    allTouched.categoryID = "materials"
    let touchedAll = NativeExpenseTouchedFields(merchant: true, amount: true, date: true, category: true)
    let empty = NativeExpenseComposer.applyingScan(result, to: &allTouched, touched: touchedAll)
    expectEqual(empty.applied, 0, "no untouched field is left to fill")
    expectEqual(empty.state, .empty, "an application with nothing to fill reports 'empty'")
    expectEqual(allTouched.amountText, "40", "touched amount is untouched by the scan")
    expectEqual(allTouched.categoryID, "materials", "touched category is untouched by the scan")

    // A junk field cannot sink the rest (the parser guarantees independence; the
    // composer must preserve it when applying).
    var independent = NativeExpenseEditorDraft.newExpense(now: calendarDate("2026-07-01"))
    let junk = extraction(amount: decimal("12.5"), date: "2026-02-31", category: "not-a-category")
    let applied = NativeExpenseComposer.applyingScan(junk, to: &independent, touched: .init())
    expectEqual(applied.applied, 1, "only the valid field lands")
    expectEqual(independent.amountText, "12.50", "the amount still fills")
    expectEqual(independent.categoryID, "materials", "an unknown category is ignored")
    expectEqual(independent.date, calendarDate("2026-07-01"), "a rollover date is ignored")

    // Low confidence rides along as the blurry warning.
    let blurry = NativeExpenseComposer.applyingScan(
        extraction(merchant: "Acme", confidence: "low"), to: &draft, touched: .init()
    )
    expect(blurry.blurry, "low confidence is flagged blurry")
    expectEqual(blurry.state, .filled, "a blurry fill is still a fill")

    // No scan at all: the draft is exactly what the user typed.
    var manual = NativeExpenseEditorDraft.newExpense(now: calendarDate("2026-07-01"))
    manual.merchant = "Manual entry"
    manual.amountText = "19.99"
    let failed = NativeExpenseScanState.failed
    expectEqual(NativeExpenseComposer.scanBanner(failed), "Couldn't read the receipt — enter the details manually", "failure copy")
    expectEqual(manual.merchant, "Manual entry", "manual entry survives an unavailable scan")
    expectEqual(NativeExpenseComposer.validation(manual) == nil, true, "manual save works with OCR unavailable")
}

private func testScanBanner() {
    expect(NativeExpenseComposer.scanBanner(.idle) == nil, "idle shows no banner")
    expectEqual(NativeExpenseComposer.scanBanner(.reading), "Reading receipt…", "reading copy")
    expectEqual(
        NativeExpenseComposer.scanBanner(.filled),
        "Filled from receipt — double-check the details",
        "filled copy"
    )
    expectEqual(
        NativeExpenseComposer.scanBanner(.filled, blurry: true),
        "Filled from receipt — the photo looks blurry, double-check the details",
        "blurry filled copy"
    )
    expectEqual(NativeExpenseComposer.scanBanner(.empty), "Receipt read — nothing new to fill in", "empty copy")
    expectEqual(NativeExpenseComposer.scanBanner(.failed), "Couldn't read the receipt — enter the details manually", "failed copy")
}

// MARK: - Receipt storage

private func testReceiptIdentity() {
    expectEqual(
        NativeReceiptMedia.makeReceiptID(now: Date(timeIntervalSince1970: 1_700_000_000), randomValue: 1_295),
        "r1700000000000_zz",
        "receipt id shape is r<millis>_<base36>"
    )
    expect(NativeReceiptMedia.makeReceiptID(now: Date(timeIntervalSince1970: 0), randomValue: 0) == "r0_0", "empty suffix falls back to 0")

    expect(NativeReceiptMedia.isValidReceiptID("r1700000000000_zz"), "a minted id is valid")
    expect(!NativeReceiptMedia.isValidReceiptID(""), "empty id is invalid")
    expect(!NativeReceiptMedia.isValidReceiptID("../escape"), "traversal is invalid")
    expect(!NativeReceiptMedia.isValidReceiptID("a/b"), "separator is invalid")
    expect(!NativeReceiptMedia.isValidReceiptID(" spaced "), "padding is invalid")
    expect(!NativeReceiptMedia.isValidReceiptID(String(repeating: "a", count: 129)), "overlong id is invalid")

    let root = URL(fileURLWithPath: "/tmp/receipt-root")
    let url = try! NativeReceiptMedia.receiptURL(root: root, receiptID: "r1_ab")
    expectEqual(url.path, "/tmp/receipt-root/receipts/r1_ab.jpg", "receipts live at the deterministic path")
    expectEqual(NativeReceiptMedia.base64Length(0), 0, "empty base64 length")
    expectEqual(NativeReceiptMedia.base64Length(1), 4, "one byte pads to four chars")
    expectEqual(NativeReceiptMedia.base64Length(3), 4, "three bytes are four chars")
    expectEqual(NativeReceiptMedia.base64Length(4), 8, "four bytes are eight chars")
}

private func testReceiptInstall() {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tradeready-receipt-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let first = Data([0xFF, 0xD8, 0xFF, 0x01, 0xD9])
    let second = Data([0xFF, 0xD8, 0xFF, 0x02, 0xD9])

    let installed = try! NativeReceiptMedia.installBytes(first, root: root, receiptID: "r1_a")
    expectEqual(installed, .installed, "first write installs")
    let url = try! NativeReceiptMedia.receiptURL(root: root, receiptID: "r1_a")
    expectEqual(try! Data(contentsOf: url), first, "bytes are on disk")

    let again = try! NativeReceiptMedia.installBytes(second, root: root, receiptID: "r1_a")
    expectEqual(again, .alreadyPresent, "an existing file is never overwritten")
    expectEqual(try! Data(contentsOf: url), first, "the original bytes win")

    expect(
        (try? NativeReceiptMedia.installBytes(Data(), root: root, receiptID: "r2_b")) == nil,
        "empty bytes are refused"
    )
    expect(
        (try? NativeReceiptMedia.installBytes(first, root: root, receiptID: "../escape")) == nil,
        "an invalid id is refused"
    )
    expect(!fileManager.fileExists(atPath: root.appendingPathComponent("receipts/../escape.jpg").path), "nothing escaped the receipts folder")
}

// MARK: - OCR size contract

#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
/// A deterministic noisy JPEG: big enough that the downscale loop must engage.
private func noisyJPEG(width: Int, height: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next() -> UInt8 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return UInt8((seed >> 33) & 0xFF)
    }
    let pixels = width * height * 4
    var bytes = [UInt8](repeating: 0, count: pixels)
    for index in 0 ..< pixels { bytes[index] = next() }
    bytes.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress {
            context.data?.copyMemory(from: base, byteCount: pixels)
        }
    }
    guard let image = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: 1.0,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

private func pixelWidth(_ data: Data) -> Int? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
    else { return nil }
    let properties = raw as NSDictionary
    return (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
}

private func testReceiptImageContract() {
    guard let source = noisyJPEG(width: 3200, height: 2400) else {
        expect(false, "test fixture could not be encoded")
        return
    }
    expect(NativeReceiptMedia.isJPEGMarker(source), "the fixture is a JPEG")

    guard let normalized = NativeReceiptMedia.normalizedJPEGBytes(from: source) else {
        expect(false, "a real photo normalizes under the default cap")
        return
    }
    expect(NativeReceiptMedia.isJPEGMarker(normalized), "normalized bytes are a complete JPEG")
    expect(NativeReceiptMedia.fitsOCRContract(normalized), "normalized bytes fit the OCR cap")
    expect(normalized.count < source.count, "the stored receipt is smaller than the capture")
    if let width = pixelWidth(normalized) {
        expect(width <= NativeReceiptMedia.maxDimension, "the long side is bounded to the OCR dimension")
    } else {
        expect(false, "normalized bytes are decodable")
    }

    // Unreachable cap → an honest nil, never an oversize payload.
    expect(
        NativeReceiptMedia.normalizedJPEGBytes(from: source, maxBase64Chars: 1_000) == nil,
        "a cap smaller than any readable receipt returns nil"
    )
    expect(NativeReceiptMedia.normalizedJPEGBytes(from: Data("not an image".utf8)) == nil, "undecodable bytes return nil")
    expect(NativeReceiptMedia.normalizedJPEGBytes(from: Data()) == nil, "empty bytes return nil")
}
#else
private func testReceiptImageContract() {
    expect(false, "ImageIO unavailable on this host")
}
#endif

// MARK: - Run

testLinkableJobs()
testAmount()
testScanApply()
testScanBanner()
testReceiptIdentity()
testReceiptInstall()
testReceiptImageContract()

if failures == 0 {
    print("Expense editor tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
