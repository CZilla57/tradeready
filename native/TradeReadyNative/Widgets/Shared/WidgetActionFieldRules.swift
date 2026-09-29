import Foundation

// Task 11.04 fix round 1 (I1): the ONE copy of the action-queue string field
// rules (contract §4.1). Compiled into both targets (`N/Widgets/Shared/`):
// the extension-side writer (`WidgetIntentEngine.validate`) and the app-side
// replay planner (`NativeWidgetActionBatchPlanner`) both call these, so a
// value the writer accepts can never be one the planner rejects.
// Numeric ranges stay with each side (Double in the writer, Decimal in the
// planner); `native/AppIntentQueueTests` pins their boundaries together.

enum WidgetActionFieldRules {
    /// Longest `id` / `type` / `jobId`, in UTF-8 bytes.
    static let maximumIdentifierLength = 128

    /// Non-empty, at most 128 UTF-8 bytes, and no control characters.
    static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumIdentifierLength
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Strict `yyyy-MM-dd` made of ASCII digits that names a real Gregorian
    /// day. The digit check refuses signed pieces such as `+026-08-03`,
    /// which `Int(_:)` would otherwise read as year 26.
    static func isValidLocalDate(_ value: String) -> Bool {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            return false
        }
        let rebuilt = calendar.dateComponents([.year, .month, .day], from: date)
        return rebuilt.year == year && rebuilt.month == month && rebuilt.day == day
    }
}
