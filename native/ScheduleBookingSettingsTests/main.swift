import Foundation

// Focused tests for task 8.10 (requirements S4, B2): the schedule/booking
// settings UI lane's seams. The views stay thin: every behavior below is
// exercised through the same typed entry points the views call
// (`NativeScheduleSettingsView.validate/canonicalBlackout/isoDayLabels`,
// `NativeScheduleBookingPolicy.applyScheduleSettings`,
// `NativeAvailability.validateSlotConfiguration`,
// `NativeBookingAdministrationService.bookingURL`,
// `NativeBookingAdminMirror`). Cancel-without-write holds by construction
// (Cancel never calls commit); per-action busy protection and share-sheet
// cancellation are view-state that performs no store write by construction.

private func decode10Settings(_ json: String) -> Canonical.Settings {
    try! JSONDecoder().decode(Canonical.Settings.self, from: Data(json.utf8))
}

private func settings10Base() -> String {
    """
    {"businessName":"Ada Electric","contactName":"Ada","phone":"p","email":"e","address":"a",
     "trade":"electrical","laborRate":95,"materialMarkup":25,"overheadPercent":10,
     "marginPercent":30,"minimumJobFee":0,"travelFeePerMile":0,"emergencyMultiplier":1,
     "rules":[],"paymentNotes":"","provider":"none"}
    """
}

private func settings10(schedule: String? = nil, bookingLink: String? = nil, extra: String? = nil) -> Canonical.Settings {
    var json = String(settings10Base().dropLast())
    if let schedule { json += ",\"schedule\":\(schedule)" }
    if let bookingLink { json += ",\"bookingLink\":\(bookingLink)" }
    if let extra { json += ",\(extra)" }
    json += "}"
    return decode10Settings(json)
}

private let token10A = String(repeating: "a", count: 48)
private let token10B = String(repeating: "b", count: 48)

private func validate10(
    workDays: Set<Int> = [1, 2, 3, 4, 5], start: String = "08:30", end: String = "17:45",
    duration: String = "60", buffer: String = "0", lead: String = "24", horizon: String = "14",
    slots: Bool = false, zone: String = ""
) -> [String] {
    NativeScheduleSettingsView.validate(
        workDays: workDays, startText: start, endText: end,
        durationText: duration, bufferText: buffer,
        leadText: lead, horizonText: horizon,
        slotsEnabled: slots, timeZoneText: zone)
}

@main
struct ScheduleBookingSettingsTests {
    static func main() {
        var failures = 0
        func expect(_ actual: Bool, _ label: String) {
            if actual { return }
            failures += 1
            print("FAIL: \(label)")
        }
        func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
            if actual != expected {
                failures += 1
                print("FAIL: \(label) — expected \(expected), got \(actual)")
            }
        }

        // MARK: - A. ISO day labels (Mon=1 … Sun=7)

        do {
            let labels = NativeScheduleSettingsView.isoDayLabels
            expectEqual(labels.map(\.day), [1, 2, 3, 4, 5, 6, 7], "A1 days are ISO Mon=1..Sun=7 in order")
            expectEqual(labels.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "A2 labels are unambiguous ISO names")
        }

        // MARK: - B. Minute-precise hours

        do {
            expect(validate10().isEmpty, "B1 minute-precise 08:30–17:45 validates")
            expect(!validate10(start: "08:00", end: "08:00").isEmpty, "B2 zero-length window refuses")
            expect(!validate10(start: "18:00", end: "09:00").isEmpty, "B3 inverted window refuses")
            expect(!validate10(start: "8:30").isEmpty, "B4 non-padded hour refuses (strict HH:MM)")
            expect(!validate10(start: "24:00").isEmpty, "B5 out-of-range hour refuses")
            let resolved = NativeSchedule.resolveSchedule(settings10(
                schedule: "{\"workDays\":[1],\"workDayStart\":\"08:30\",\"workDayEnd\":\"17:45\"}").schedule)
            expectEqual(resolved.workDayStart, "08:30", "B6 resolution preserves start minutes (no rounding)")
            expectEqual(resolved.workDayEnd, "17:45", "B7 resolution preserves end minutes (no rounding)")
        }

        // MARK: - C. Duration / buffer / lead / horizon / zone

        do {
            expect(validate10(buffer: "0", lead: "0").isEmpty, "C1 valid zero lead/buffer survives")
            expect(!validate10(duration: "0").isEmpty, "C2 zero duration refuses, never a silent default")
            expect(!validate10(buffer: "-5").isEmpty, "C3 negative buffer refuses")
            expect(!validate10(horizon: "0").isEmpty, "C4 zero horizon refuses")
            expect(!validate10(workDays: []).isEmpty, "C5 removing the final working day refuses")
            expect(!validate10(slots: true, zone: "Not/AZone").isEmpty, "C6 slots require a valid IANA zone")
            expect(!validate10(slots: true, zone: "").isEmpty, "C7 slots require a non-empty zone")
            expect(validate10(slots: true, zone: "America/Phoenix").isEmpty, "C8 valid IANA zone enables slots")
            expect(validate10(slots: false, zone: "bogus").isEmpty, "C9 slots-off never gates on the zone (link/slot separation)")
            let gate = NativeAvailability.validateSlotConfiguration(NativeSchedule.resolveSchedule(
                settings10(schedule: "{\"bookableSlotsEnabled\":true}").schedule))
            expectEqual(gate, .some(.invalidTimeZone), "C10 slots-enabled without a zone surfaces a configuration error, never fabricated offers")
        }

        // MARK: - D. Blackout Add-only / remove-preserves / credential preservation

        do {
            let entry = NativeSchedule.ScheduleBlackout(id: "blk_1", start: "2026-12-24", end: "2026-12-26", reason: "Holidays")
            let canonical = NativeScheduleSettingsView.canonicalBlackout(entry)
            expectEqual(canonical?.id, .some("blk_1"), "D1 blackout ID survives the canonical bridge")
            expectEqual(canonical?.start, .some("2026-12-24"), "D2 blackout start survives the bridge")
            expectEqual(canonical?.reason ?? nil, .some("Holidays"), "D3 blackout reason survives the bridge")

            // Add-only: an existing stable ID is never replaced implicitly.
            let current = settings10(
                schedule: "{\"workDays\":[1,2,3],\"blackouts\":[{\"id\":\"blk_1\",\"start\":\"2026-12-24\",\"end\":\"2026-12-26\",\"reason\":\"Holidays\"}]}",
                bookingLink: "{\"token\":\"\(token10A)\",\"enabled\":true}")
            let draft = NativeScheduleBookingPolicy.ScheduleSettingsDraft(
                baselineSchedule: current.schedule,
                workDays: [1, 2, 3],
                blackoutsToAdd: [
                    NativeScheduleSettingsView.canonicalBlackout(
                        NativeSchedule.ScheduleBlackout(id: "blk_1", start: "2026-01-01", end: "2026-01-02", reason: "hijack"))!,
                    NativeScheduleSettingsView.canonicalBlackout(
                        NativeSchedule.ScheduleBlackout(id: "blk_2", start: "2026-12-31", end: "2027-01-01"))!,
                ],
                blackoutIDsToRemove: [])
            if case let .apply(settings) = NativeScheduleBookingPolicy.applyScheduleSettings(current: current, draft: draft) {
                let ids = (settings.schedule?.blackouts ?? []).map(\.id).sorted()
                expectEqual(ids, ["blk_1", "blk_2"], "D4 Add inserts by stable ID without replacing the existing entry")
                expectEqual(settings.schedule?.blackouts?.first(where: { $0.id == "blk_1" })?.reason ?? nil, .some("Holidays"), "D5 the existing entry keeps its reason (no silent replace)")
                expectEqual(settings.bookingLink?.token, .some(token10A), "D6 settings save preserves the booking token")
                expectEqual(settings.bookingLink?.enabled, .some(true), "D7 settings save preserves link enablement")
            } else {
                expect(false, "D4 settings draft applies")
            }

            // Remove-by-ID preserves every other entry plus unknown fields.
            let withUnknown = settings10(
                schedule: "{\"workDays\":[1,2,3],\"blackouts\":[{\"id\":\"blk_1\",\"start\":\"2026-12-24\",\"end\":\"2026-12-26\"},{\"id\":\"blk_2\",\"start\":\"2026-12-31\",\"end\":\"2027-01-01\",\"nasa\":\"classified\"}]}",
                bookingLink: "{\"token\":\"\(token10A)\",\"enabled\":false}",
                extra: "\"futureFlag\":\"keep-me\"")
            let removal = NativeScheduleBookingPolicy.ScheduleSettingsDraft(
                baselineSchedule: withUnknown.schedule,
                blackoutIDsToRemove: ["blk_1"])
            if case let .apply(settings) = NativeScheduleBookingPolicy.applyScheduleSettings(current: withUnknown, draft: removal) {
                expectEqual((settings.schedule?.blackouts ?? []).map(\.id), ["blk_2"], "D8 removing one blackout preserves the other")
                expectEqual(settings.bookingLink?.token, .some(token10A), "D9 removal preserves the booking token")
                let encoded = try! JSONEncoder().encode(settings)
                let fields = try! JSONDecoder().decode([String: Canonical.JSONValue].self, from: encoded)
                expect(fields["futureFlag"] == .string("keep-me"), "D10 unknown top-level fields survive a settings save")
            } else {
                expect(false, "D8 removal draft applies")
            }

            // Baseline conflict: a concurrent owned-field change refuses.
            let staleBaseline = settings10(schedule: "{\"workDays\":[1,2,3]}").schedule
            let diverged = settings10(
                schedule: "{\"workDays\":[1,2,3,4]}",
                bookingLink: "{\"token\":\"\(token10B)\",\"enabled\":true}")
            let conflictDraft = NativeScheduleBookingPolicy.ScheduleSettingsDraft(
                baselineSchedule: staleBaseline, workDays: [1, 2])
            if case .baselineConflict = NativeScheduleBookingPolicy.applyScheduleSettings(current: diverged, draft: conflictDraft) {
                expect(true, "D11 concurrent owned-field change refuses instead of silently replacing")
            } else {
                expect(false, "D11 concurrent owned-field change refuses instead of silently replacing")
            }
        }

        // MARK: - E. Slot availability vs link enablement; truthful URLs

        do {
            expect(NativeBookingAdministrationService.bookingURL(token: token10A) != nil, "E1 a valid capability token builds a share URL")
            expect(NativeBookingAdministrationService.bookingURL(token: "stale-display-copy") == nil, "E2 a stale display copy never becomes a share URL")
            expect(NativeBookingAdministrationService.bookingURL(token: "") == nil, "E3 an empty token never becomes a share URL")
            let stale = NativeBookingLinkStatus(enabled: true, revision: 3, tokenValid: false)
            expect(!NativeScheduleBookingPolicy.mayAdoptDisplayToken(displayToken: token10A, status: stale), "E4 a present-but-stale token takes the recovery path, never a share URL")
            let fresh = NativeBookingLinkStatus(enabled: true, revision: 4, tokenValid: true)
            expect(NativeScheduleBookingPolicy.mayAdoptDisplayToken(displayToken: token10A, status: fresh), "E5 a freshly validated token may be shared")
            expect(!NativeScheduleBookingPolicy.mayAdoptDisplayToken(displayToken: nil, status: fresh), "E6 a missing token never shares even when the server is enabled")
            // Mirror: set_enabled results (no token) preserve the token; a
            // missing link with no token fails closed.
            let linked = settings10(bookingLink: "{\"token\":\"\(token10A)\",\"enabled\":true}")
            let disabled = try! NativeBookingAdminMirror.apply(to: linked, token: nil, enabled: false)
            expectEqual(disabled.bookingLink?.token, .some(token10A), "E7 disable preserves the token in the display mirror")
            expectEqual(disabled.bookingLink?.enabled, .some(false), "E8 disable flips only the flag")
            let unlinked = settings10()
            do {
                _ = try NativeBookingAdminMirror.apply(to: unlinked, token: nil, enabled: false)
                expect(false, "E9 mirror with no token and no link fails closed")
            } catch {
                expect(true, "E9 mirror with no token and no link fails closed")
            }
        }

        if failures == 0 {
            print("ScheduleBookingSettingsTests: all checks passed")
        } else {
            print("ScheduleBookingSettingsTests: \(failures) failure(s)")
            exit(1)
        }
    }
}
