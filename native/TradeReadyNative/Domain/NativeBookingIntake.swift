import Foundation

/// Pure booking/portal intake planner (Phase 8, task 8.02; requirements B3, P3).
///
/// Ports `utils/storage/bookingConversion.ts` onto the loss-preserving
/// canonical records (`Canonical.BookingRequest/Job/Customer/Settings`) and
/// applies only the explicit task 8.00 intake decisions D-B3-1…D-B3-4 from
/// `docs/native-phase-8-contract-decisions.md`:
///
/// - D-B3-1 (intentional RN difference, chosen): unconverted slot bookings
///   with `status` in `booked/confirmed/reschedule_requested`
///   (`kind == "booked"`, no `convertedJobId`) convert on the first pass and
///   keep their server status. Current RN converts only `new` and unconverted
///   `booked`; rows skipped there must still surface via
///   `NativeBookingAttention` so a confirmed booking never disappears.
/// - D-B3-2 (limitation L3, retained): job identity is deterministic
///   (`jbk_<requestId>`, never overwritten on replay) but customer creation
///   stays time-based through the injected `makeCustomerID`, exactly like RN's
///   `c<Date.now()>_<counter>`. Two devices converting the same request
///   concurrently can therefore each create a Customer for the same person;
///   the existing duplicate-detection/merge flow (`NativeCustomerIdentity`)
///   surfaces the pair. No server-side customer dedupe is attempted here.
/// - D-B3-3: `portal_change_requested` never converts (handled/stamp only).
///   Portal follow-up `new` rows convert and retain `sourceCustomerId`.
///   Unknown statuses stay intact and inert.
/// - D-B3-4: conversion merges owned fields only (`convertedJobId`,
///   `convertedCustomerId`, `new → converted`). Server lifecycle, `history`,
///   slot and every unknown/preserved field ride along untouched on the
///   struct copy, so late-arriving server state survives.
///
/// This planner performs no I/O: it returns a `Plan` describing the expected
/// source records and the changed customers/jobs/requests plus queue-ready
/// `Canonical.MutationDraft`s. The AppStore integration (task 8.08) applies a
/// plan after a verified pull, rechecks current records, and persists +
/// enqueues atomically. A no-op plan carries no drafts, so the caller must
/// not write (a save re-enqueues the whole collection).
public enum NativeBookingIntake {
    /// Convertible slot-booking statuses per D-B3-1. `new` is handled
    /// separately (free-text shape, status flips to `converted`).
    public static let convertibleSlotStatuses: Set<String> = [
        "booked", "confirmed", "reschedule_requested",
    ]

    /// One explicit canonical mutation plan. `requests/jobs/customers` are
    /// the full post-plan collections; the `changed*` flags and id sets say
    /// exactly what the integration must persist and enqueue. Nothing here
    /// is a second store — it is a single atomic transaction proposal.
    public struct Plan {
        public var requests: [Canonical.BookingRequest]
        public var jobs: [Canonical.Job]
        public var customers: [Canonical.Customer]
        public var requestsChanged: Bool
        public var jobsChanged: Bool
        public var customersChanged: Bool
        /// Request ids stamped by this plan, in input order.
        public var convertedRequestIDs: [String]
        /// Deterministic job ids created by this plan (`jbk_<requestId>`).
        public var createdJobIDs: [String]
        /// Customer ids created by this plan (time-based, see L3 above).
        public var createdCustomerIDs: [String]
        /// Request ids left untouched (already converted, inert, malformed).
        public var untouchedRequestIDs: [String]
        /// Queue-ready drafts for exactly the changed records above.
        public var drafts: [Canonical.MutationDraft]

        public var changed: Bool { requestsChanged || jobsChanged || customersChanged }
    }

    /// True when at least one request is convertible. Mirrors the
    /// `applyBookingRequests` early-out so the integration can skip the
    /// snapshot round trip entirely.
    public static func needsIntake(_ requests: [Canonical.BookingRequest]) -> Bool {
        requests.contains { isConvertible($0) }
    }

    public static func isConvertible(_ request: Canonical.BookingRequest) -> Bool {
        guard !request.id.isEmpty else { return false }
        if request.status == "new" { return true }
        return convertibleSlotStatuses.contains(request.status)
            && request.kind == "booked"
            && request.convertedJobId == nil
    }

    /// Builds the conversion plan. `makeCustomerID` must be time-based and
    /// unique per call (RN parity: `c<Date.now()>_<counter>`); `nowISO`
    /// stamps `createdAt` on new customers. Both are injected so tests stay
    /// deterministic and production stays clock-driven.
    public static func plan(
        requests: [Canonical.BookingRequest],
        jobs: [Canonical.Job],
        customers: [Canonical.Customer],
        settings: Canonical.Settings,
        makeCustomerID: () -> String,
        nowISO: () -> String
    ) -> Plan {
        var nextCustomers = customers
        var nextJobs = jobs
        var customersChanged = false
        var jobsChanged = false
        var requestsChanged = false
        var convertedIDs: [String] = []
        var createdJobs: [String] = []
        var createdCustomers: [String] = []
        var untouchedIDs: [String] = []
        var drafts: [Canonical.MutationDraft] = []

        let nextRequests: [Canonical.BookingRequest] = requests.map { request in
            guard isConvertible(request) else {
                untouchedIDs.append(request.id)
                return request
            }
            let isSlotBooking = request.status != "new"

            // Portal requests carry the customer's record id — the portal
            // copied contact fields FROM that record, so link it directly
            // (no upsert, no backfill churn). A dangling id (deleted or
            // merged-away record) falls back to the name-keyed upsert.
            var customer: Canonical.Customer?
            if let sourceID = request.sourceCustomerId, !sourceID.isEmpty {
                customer = nextCustomers.first { $0.id == sourceID }
            }
            if customer == nil {
                let upserted = upsertCustomer(
                    in: nextCustomers,
                    name: request.name,
                    email: request.email,
                    phone: request.phone,
                    address: request.address,
                    makeCustomerID: makeCustomerID,
                    nowISO: nowISO
                )
                if upserted.changed {
                    nextCustomers = upserted.customers
                    customersChanged = true
                    if let fresh = upserted.customer {
                        drafts.append(mutationDraft(table: "customers", id: fresh.id, record: fresh))
                        if upserted.didCreate { createdCustomers.append(fresh.id) }
                    }
                }
                customer = upserted.customer
            }
            guard let linked = customer else {
                // Unusable name (blank after trim) — leave the request for
                // owner inspection rather than inventing a customer.
                untouchedIDs.append(request.id)
                return request
            }

            let jobID = "jbk_\(request.id)"
            if nextJobs.first(where: { $0.id == jobID }) == nil {
                let lead = makeLeadJob(
                    id: jobID,
                    request: request,
                    customer: linked,
                    isSlotBooking: isSlotBooking,
                    settings: settings
                )
                nextJobs.append(lead)
                jobsChanged = true
                createdJobs.append(jobID)
                drafts.append(mutationDraft(table: "jobs", id: jobID, record: lead))
            }

            var stamped = request
            if !isSlotBooking { stamped.status = "converted" }
            stamped.convertedJobId = jobID
            stamped.convertedCustomerId = linked.id
            requestsChanged = true
            convertedIDs.append(request.id)
            drafts.append(mutationDraft(table: "bookingRequests", id: stamped.id, record: stamped))
            return stamped
        }

        return Plan(
            requests: requestsChanged ? nextRequests : requests,
            jobs: jobsChanged ? nextJobs : jobs,
            customers: customersChanged ? nextCustomers : customers,
            requestsChanged: requestsChanged,
            jobsChanged: jobsChanged,
            customersChanged: customersChanged,
            convertedRequestIDs: convertedIDs,
            createdJobIDs: createdJobs,
            createdCustomerIDs: createdCustomers,
            untouchedRequestIDs: untouchedIDs,
            drafts: drafts
        )
    }

    // MARK: - Customer linking (RN `upsertCustomerInList` parity)

    public struct CustomerUpsert {
        public var customer: Canonical.Customer?
        public var customers: [Canonical.Customer]
        public var changed: Bool
        /// True only when a fresh record was appended (a blank-field
        /// backfill of an existing row changes it without creating one).
        public var didCreate: Bool
    }

    /// Finds a record by normalized name (backfilling only *blank* contact
    /// fields — never clobbering existing data) or appends a fresh record.
    /// Pure: no I/O, so one in-memory pass can batch many conversions.
    public static func upsertCustomer(
        in customers: [Canonical.Customer],
        name: String,
        email: String,
        phone: String,
        address: String,
        makeCustomerID: () -> String,
        nowISO: () -> String
    ) -> CustomerUpsert {
        let key = normalizedName(name)
        guard !key.isEmpty else { return CustomerUpsert(customer: nil, customers: customers, changed: false, didCreate: false) }
        if let index = customers.firstIndex(where: { normalizedName($0.name) == key }) {
            var merged = customers[index]
            var touched = false
            if isBlank(merged.email), !email.isEmpty { merged.email = email; touched = true }
            if isBlank(merged.phone), !phone.isEmpty { merged.phone = phone; touched = true }
            if isBlank(merged.address), !address.isEmpty { merged.address = address; touched = true }
            guard touched else {
                return CustomerUpsert(customer: merged, customers: customers, changed: false, didCreate: false)
            }
            var next = customers
            next[index] = merged
            return CustomerUpsert(customer: merged, customers: next, changed: true, didCreate: false)
        }
        let built = decodeCustomer([
            "id": .string(makeCustomerID()),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "email": .string(email),
            "phone": .string(phone),
            "address": .string(address),
            "notes": .string(""),
            "createdAt": .string(nowISO()),
        ])
        return CustomerUpsert(customer: built, customers: customers + [built], changed: true, didCreate: true)
    }

    public static func normalizedName(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Lead construction (exact RN defaults/provenance)

    private static func makeLeadJob(
        id: String,
        request: Canonical.BookingRequest,
        customer: Canonical.Customer,
        isSlotBooking: Bool,
        settings: Canonical.Settings
    ) -> Canonical.Job {
        let requestDate = String(request.createdAt.prefix(10))
        var notes = ""
        if isSlotBooking, let slot = request.slot {
            notes += "Booked online for \(slot.date) \(slot.start)\n"
        }
        let timing = request.preferredTiming.trimmingCharacters(in: .whitespacesAndNewlines)
        if !timing.isEmpty { notes += "Preferred timing: \(timing)\n" }
        notes += "\(request.source == "portal" ? "Came in via customer portal" : "Came in via booking link") \(requestDate)"
        var fields: [String: Canonical.JSONValue] = [
            "id": .string(id),
            "customerId": .string(customer.id),
            "customerName": .string(customer.name),
            "title": .string(isSlotBooking ? "Booked appointment" : "Quote request"),
            "description": .string(request.details),
            // Owner-approved D6 parity: a slot booking enters as `lead` WITH
            // schedule fields set — it renders on the calendar and counts as
            // busy without skipping the estimate pipeline.
            "status": .string("lead"),
            "address": .string(request.address),
            "estimateTotal": .number(0),
            "laborHours": .number(0),
            "laborRate": .number(settings.laborRate),
            "materials": .array([]),
            "materialMarkup": .number(settings.materialMarkup),
            "overhead": .number(settings.overheadPercent),
            "margin": .number(settings.marginPercent),
            "notes": .string(notes),
            "createdAt": .string(requestDate),
        ]
        if isSlotBooking, let slot = request.slot {
            fields["scheduledDate"] = .string(slot.date)
            fields["scheduledStartTime"] = .string(slot.start)
            fields["scheduledEndTime"] = .string(slot.end)
        }
        return decodeJob(fields)
    }

    // MARK: - Canonical JSON bridge

    static func decodeJob(_ fields: [String: Canonical.JSONValue]) -> Canonical.Job {
        let data = try! JSONEncoder().encode(fields)
        return try! JSONDecoder().decode(Canonical.Job.self, from: data)
    }

    static func decodeCustomer(_ fields: [String: Canonical.JSONValue]) -> Canonical.Customer {
        let data = try! JSONEncoder().encode(fields)
        return try! JSONDecoder().decode(Canonical.Customer.self, from: data)
    }

    private static func mutationDraft<Record: Encodable>(
        table: String,
        id: String,
        record: Record
    ) -> Canonical.MutationDraft {
        let data = try! JSONEncoder().encode(record)
        let payload = try! JSONDecoder().decode(Canonical.JSONValue.self, from: data)
        return Canonical.MutationDraft(table: table, op: .upsert, recordId: id, payload: payload)
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
