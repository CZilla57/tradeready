import Foundation
import MapKit

/// Driving-leg estimate between two resolved waypoints. Distances and times
/// come from MapKit and are **preview estimates**, never navigation truth:
/// the 8.12 route UI must label them as estimates. Actual navigation happens
/// exclusively through the handoff URLs built by `NativeRoutePlanning`.
public struct NativeRouteLegEstimate: Equatable, Sendable {
    public var distanceMeters: Double
    public var travelSeconds: Double

    public init(distanceMeters: Double, travelSeconds: Double) {
        self.distanceMeters = distanceMeters
        self.travelSeconds = travelSeconds
    }
}

/// Injectable address-resolution boundary. The MapKit implementation below is
/// the production adapter; tests inject fakes. No location permission is
/// required: stored addresses resolve without device location.
public protocol NativeRouteGeocoding: Sendable {
    func coordinate(for address: String) async throws -> CLLocationCoordinate2D
}

/// Injectable driving-directions boundary. Tests inject fakes; production
/// uses MapKit automobile routing.
public protocol NativeRouteDirectionsEstimating: Sendable {
    func estimate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async throws -> NativeRouteLegEstimate
}

public enum NativeRouteMapServiceError: Error, Equatable {
    case addressNotFound(String)
    case directionsUnavailable(String)
}

/// One previewed driving leg in the selected stop order. `fromStopID == nil`
/// means the leg starts at the handoff origin (business address or first
/// usable stop, per `NativeRoutePlanning.routeOrigin`).
public struct NativeRoutePreviewLeg: Equatable, Sendable {
    public var fromStopID: String?
    public var toStopID: String
    public var distanceMeters: Double
    public var travelSeconds: Double
    /// Always true: preview legs are estimates, not navigation.
    public var isPreviewEstimate: Bool

    public init(
        fromStopID: String?,
        toStopID: String,
        distanceMeters: Double,
        travelSeconds: Double,
        isPreviewEstimate: Bool = true
    ) {
        self.fromStopID = fromStopID
        self.toStopID = toStopID
        self.distanceMeters = distanceMeters
        self.travelSeconds = travelSeconds
        self.isPreviewEstimate = isPreviewEstimate
    }
}

/// A waypoint or leg the preview could not resolve. `stopID == nil`
/// identifies the origin address. Failures never remove rows from the stop
/// list: map state and stop-list data travel separately.
public struct NativeRoutePreviewFailure: Equatable, Sendable {
    public var stopID: String?
    public var address: String

    public init(stopID: String?, address: String) {
        self.stopID = stopID
        self.address = address
    }
}

/// Map preview state for one selected order. Kept separate from
/// `[NativeRouteStop]`: a failed or partial preview never hides the usable
/// stop list, and the stop list never implies map success.
public struct NativeRouteMapPreview: Equatable, Sendable {
    /// Request identity, for handoff/debugging. Stale requests return nil
    /// instead of a preview; they never overwrite a newer route.
    public var orderedStopIDs: [String]
    public var ownerID: String
    public var dateString: String
    public var legs: [NativeRoutePreviewLeg]
    public var failures: [NativeRoutePreviewFailure]

    public init(
        orderedStopIDs: [String],
        ownerID: String,
        dateString: String,
        legs: [NativeRoutePreviewLeg],
        failures: [NativeRoutePreviewFailure]
    ) {
        self.orderedStopIDs = orderedStopIDs
        self.ownerID = ownerID
        self.dateString = dateString
        self.legs = legs
        self.failures = failures
    }

    /// Every waypoint resolved and every leg estimated.
    public var isComplete: Bool { !legs.isEmpty && failures.isEmpty }
    /// At least one leg estimated, but something failed alongside it. The
    /// caller keeps the stop list and shows the failures inline.
    public var isPartial: Bool { !legs.isEmpty && !failures.isEmpty }
    /// Nothing could be previewed (origin unresolvable, or every leg
    /// failed). The stop list remains fully usable.
    public var hasNoPreview: Bool { legs.isEmpty }

    public init(
        orderedStopIDs: [String],
        ownerID: String,
        dateString: String
    ) {
        self.init(
            orderedStopIDs: orderedStopIDs,
            ownerID: ownerID,
            dateString: dateString,
            legs: [],
            failures: []
        )
    }
}

/// Cancellable sequential-leg preview over the caller-selected stop order.
///
/// - Resolves the origin first, then each usable stop in the given order,
///   then estimates one driving leg per consecutive resolved pair. No route
///   optimization: leg order always follows the selected order.
/// - A failed/ambiguous address is recorded in `failures` and skipped; later
///   legs bridge across it so one bad address cannot hide the rest of the
///   preview. The stop list is never mutated.
/// - Staleness: every call bumps the generation. After each suspension the
///   runner checks that its generation is still current; a superseded (or
///   explicitly cancelled, or owner/date-changed) request returns nil so
///   stale results cannot change a newer route. `cancel()` invalidates the
///   in-flight request without touching any delivered state.
public actor NativeRoutePreviewRunner {
    private let geocoder: any NativeRouteGeocoding
    private let directions: any NativeRouteDirectionsEstimating
    private var generation = 0

    public init(
        geocoder: any NativeRouteGeocoding,
        directions: any NativeRouteDirectionsEstimating
    ) {
        self.geocoder = geocoder
        self.directions = directions
    }

    public func cancel() {
        generation += 1
    }

    public func preview(
        stops: [NativeRouteStop],
        originAddress: String?,
        ownerID: String,
        dateString: String
    ) async -> NativeRouteMapPreview? {
        generation += 1
        let token = generation
        let orderedIDs = stops.map(\.id)

        func isCurrent() -> Bool {
            token == generation && !Task.isCancelled
        }

        var legs: [NativeRoutePreviewLeg] = []
        var failures: [NativeRoutePreviewFailure] = []

        // Origin first: without it no leg can start.
        let trimmedOrigin = (originAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let originText = trimmedOrigin.isEmpty ? nil : trimmedOrigin
        var previousCoordinate: CLLocationCoordinate2D?
        var previousStopID: String?
        if let originText {
            guard isCurrent() else { return nil }
            do {
                previousCoordinate = try await geocoder.coordinate(for: originText)
            } catch {
                guard isCurrent() else { return nil }
                return NativeRouteMapPreview(
                    orderedStopIDs: orderedIDs,
                    ownerID: ownerID,
                    dateString: dateString,
                    legs: [],
                    failures: [NativeRoutePreviewFailure(stopID: nil, address: originText)]
                )
            }
            guard isCurrent() else { return nil }
        }

        for stop in stops {
            guard let destination = stop.normalizedAddress else { continue }
            guard isCurrent() else { return nil }
            let coordinate: CLLocationCoordinate2D
            do {
                coordinate = try await geocoder.coordinate(for: destination)
            } catch {
                guard isCurrent() else { return nil }
                failures.append(NativeRoutePreviewFailure(stopID: stop.id, address: destination))
                continue
            }
            guard isCurrent() else { return nil }
            if let from = previousCoordinate {
                do {
                    let estimate = try await directions.estimate(from: from, to: coordinate)
                    guard isCurrent() else { return nil }
                    legs.append(
                        NativeRoutePreviewLeg(
                            fromStopID: previousStopID,
                            toStopID: stop.id,
                            distanceMeters: estimate.distanceMeters,
                            travelSeconds: estimate.travelSeconds
                        )
                    )
                } catch {
                    guard isCurrent() else { return nil }
                    failures.append(NativeRoutePreviewFailure(stopID: stop.id, address: destination))
                }
            }
            previousCoordinate = coordinate
            previousStopID = stop.id
        }

        guard isCurrent() else { return nil }
        return NativeRouteMapPreview(
            orderedStopIDs: orderedIDs,
            ownerID: ownerID,
            dateString: dateString,
            legs: legs,
            failures: failures
        )
    }
}

/// Production MapKit address resolver. Thin adapter over `MKLocalSearch`:
/// throws `NativeRouteMapServiceError.addressNotFound` when nothing matches.
public struct NativeMapKitRouteGeocoder: NativeRouteGeocoding {
    public init() {}

    public func coordinate(for address: String) async throws -> CLLocationCoordinate2D {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NativeRouteMapServiceError.addressNotFound(address)
        }
        // NOTE: `placemark` is deprecated in the iOS 26 SDK, but its
        // replacement (`MKMapItem.location`) requires iOS 26, while this
        // app targets iOS 17. The placemark path stays until the deployment
        // target allows the modern API.
        return item.placemark.coordinate
    }
}

/// Production MapKit directions adapter. Thin wrapper over `MKDirections`
/// automobile routing; throws `directionsUnavailable` when no route exists.
/// NOTE: `MKMapItem(placemark:)`/`MKPlacemark(coordinate:)` are deprecated in
/// the macOS 26 / iOS 26 SDK but are retained here because the app's
/// deployment target is iOS 17, which has no replacement constructor. Revisit
/// with an `@available`-gated `MKMapItem(location:address:)` path only when
/// the deployment target allows it.
public struct NativeMapKitRouteDirections: NativeRouteDirectionsEstimating {
    public init() {}

    public func estimate(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D
    ) async throws -> NativeRouteLegEstimate {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            throw NativeRouteMapServiceError.directionsUnavailable(
                "\(from.latitude),\(from.longitude)->\(to.latitude),\(to.longitude)"
            )
        }
        return NativeRouteLegEstimate(
            distanceMeters: route.distance,
            travelSeconds: route.expectedTravelTime
        )
    }
}
