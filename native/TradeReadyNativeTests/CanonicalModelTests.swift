import XCTest
@testable import TradeReadyNative

final class CanonicalModelTests: XCTestCase {
    func testRepresentativeRecordFamiliesRoundTripWithoutChangingWireJSON() throws {
        let fixture = try TestSupport.fixture("canonical-rich")

        try TestSupport.assertRoundTrip(Canonical.Job.self, field: "job", fixture: fixture)
        try TestSupport.assertRoundTrip(Canonical.Invoice.self, field: "invoice", fixture: fixture)
        try TestSupport.assertRoundTrip(Canonical.Customer.self, field: "customer", fixture: fixture)
        try TestSupport.assertRoundTrip(Canonical.Settings.self, field: "settings", fixture: fixture)
    }

    func testUnknownFieldsSurviveAUserMutation() throws {
        let fixture = try TestSupport.fixture("canonical-forward-compatible")
        var job: Canonical.Job = try TestSupport.field("job", from: fixture)

        job.title = "Owner-edited title"
        let encoded = try TestSupport.object(job)

        XCTAssertEqual(encoded["title"], .string("Owner-edited title"))
        XCTAssertNotNil(encoded["futureJobField"])
        guard case let .array(costs)? = encoded["jobCosts"],
              case let .object(firstCost)? = costs.first else {
            return XCTFail("Expected encoded job-cost collection")
        }
        XCTAssertEqual(firstCost["futureNested"], .string("discarded"))
    }

    func testLegacyMissingOptionalsRemainAbsent() throws {
        let fixture = try TestSupport.fixture("canonical-legacy")
        let job: Canonical.Job = try TestSupport.field("job", from: fixture)

        XCTAssertNil(job.photos)
        XCTAssertNil(job.jobCosts)
        XCTAssertNil(try TestSupport.object(job)["photos"])
    }
}
