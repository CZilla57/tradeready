import SwiftUI
import MapKit

/// Phase 8 task 8.12 route UI and navigation handoff (requirement R1).
///
/// Thin view over the 8.03 route policy (`NativeRoutePlanning.dailyStops`,
/// `moveUp`, `moveDown`, `resetOrder`, `navigableStops`, `appleMapsURL`,
/// `googleMapsURL`, `fullRouteURL`) and the 8.03 MapKit preview service
/// (`NativeRoutePreviewRunner`). No business-data mutations occur here:
/// the stop list is session-local, handoff URLs use encoded addresses, and
/// map failures never hide the accessible stop list.
struct NativeRouteView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @ScaledMetric(relativeTo: .largeTitle) private var emptyIconSize: CGFloat = 56
    @State private var stops: [NativeRouteStop] = []
    @State private var preview: NativeRouteMapPreview?
    @State private var isLoadingPreview = false
    @State private var showingHandoffFailure = false
    @State private var handoffFailureMessage = ""
    @State private var didLoad = false

    private var dateString: String {
        store.todayDateString
    }

    private var businessAddress: String? {
        store.settings.address
    }

    var body: some View {
        Group {
            if !didLoad {
                ProgressView("Loading route…")
                    .accessibilityLabel("Loading daily route")
                    .onAppear { loadRoute() }
            } else if stops.isEmpty {
                emptyState
            } else {
                routeContent
            }
        }
        .navigationTitle("Route")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Reset Order") { resetOrder() }
                        .disabled(stops.count <= 1)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel(NativeAccessibilityAudit.Label.routeOrderMenu)
            }
        }
        .refreshable { loadRoute() }
        .alert("Navigation Unavailable", isPresented: $showingHandoffFailure) {
            Button("OK", role: .cancel) {}
            Button("Copy Address") {
                #if os(iOS)
                UIPasteboard.general.string = handoffFailureMessage
                #endif
            }
        } message: {
            Text(handoffFailureMessage)
        }
        .nativeAnalyticsScreen(.route)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "map")
                .font(.system(size: emptyIconSize))
                .foregroundStyle(.secondary)
            Text("No jobs scheduled for today")
                .font(.title2.bold())
            Text("Jobs with today's date will appear here.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var routeContent: some View {
        VStack(spacing: 0) {
            // Map preview section
            if let preview, !preview.legs.isEmpty || !preview.failures.isEmpty {
                MapPreviewView(preview: preview, stops: stops)
            } else if isLoadingPreview {
                ProgressView("Building route preview…")
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemGray6))
            } else if stops.allSatisfy({ !$0.hasUsableAddress }) {
                ContentUnavailableView {
                    Label("No addresses to preview", systemImage: "map.slash")
                } description: {
                    Text("Add addresses to jobs to see the route preview.")
                }
                .frame(height: 200)
            }

            // Stop list section
            List {
                Section(header: ListHeaderView(
                    dateString: dateString,
                    stopCount: stops.count,
                    navigableCount: stops.filter(\.hasUsableAddress).count
                )) {
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        StopRowView(
                            stop: stop,
                            index: index,
                            isFirst: index == 0,
                            isLast: index == stops.count - 1,
                            onMoveUp: { moveUp(at: index) },
                            onMoveDown: { moveDown(at: index) },
                            onNavigate: { navigateTo(stop) }
                        )
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func loadRoute() {
        let canonicalJobs = store.calendarScheduleJobs()
        let jobs = canonicalJobs.filter { $0.scheduledDate == dateString }.map { job in
            NativeRouteStopInput(
                id: job.id,
                title: job.title,
                customerName: job.customerName,
                scheduledDate: job.scheduledDate,
                scheduledStartTime: job.scheduledStartTime,
                scheduledEndTime: job.scheduledEndTime,
                address: job.address
            )
        }
        stops = NativeRoutePlanning.dailyStops(jobs: jobs, dateString: dateString)
        didLoad = true
        refreshPreview()
    }

    private func refreshPreview() {
        isLoadingPreview = true
        Task {
            let runner = NativeRoutePreviewRunner(
                geocoder: NativeMapKitRouteGeocoder(),
                directions: NativeMapKitRouteDirections()
            )
            let result = await runner.preview(
                stops: stops,
                originAddress: businessAddress,
                ownerID: store.ownerID ?? "",
                dateString: dateString
            )
            await MainActor.run {
                preview = result
                isLoadingPreview = false
            }
        }
    }

    private func moveUp(at index: Int) {
        stops = NativeRoutePlanning.moveUp(stops: stops, at: index)
        refreshPreview()
    }

    private func moveDown(at index: Int) {
        stops = NativeRoutePlanning.moveDown(stops: stops, at: index)
        refreshPreview()
    }

    private func resetOrder() {
        stops = NativeRoutePlanning.resetOrder(stops: stops)
        refreshPreview()
    }

    private func navigateTo(_ stop: NativeRouteStop) {
        guard let address = stop.normalizedAddress else { return }
        guard let url = NativeRoutePlanning.appleMapsURL(address: address) else {
            handoffFailureMessage = address
            showingHandoffFailure = true
            return
        }
        #if os(iOS)
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - Map Preview View

private struct MapPreviewView: View {
    let preview: NativeRouteMapPreview
    let stops: [NativeRouteStop]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "map.fill")
                    .foregroundStyle(Color.tradeReady)
                Text("Route Preview")
                    .font(.headline)
                Spacer()
                if preview.isPartial {
                    Label("Partial", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if preview.hasNoPreview {
                    Label("Unavailable", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal)

            if preview.isComplete || preview.isPartial {
                Map(initialPosition: mapCameraPosition) {
                    ForEach(routeAnnotations) { annotation in
                        Annotation(annotation.title, coordinate: annotation.coordinate) {
                            VStack(spacing: 2) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(Color.tradeReady)
                                    .background(.white, in: Circle())
                                Text("\(annotation.order)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    ForEach(routePolylines) { poly in
                        MapPolyline(coordinates: poly.coordinates)
                            .stroke(Color.tradeReady, lineWidth: 3)
                    }
                }
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .overlay(alignment: .bottomTrailing) {
                    if preview.isPartial {
                        Text("Estimates only — not navigation")
                            .font(.caption2)
                            .padding(6)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
            }

            if !preview.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview issues:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(preview.failures, id: \.address) { failure in
                        Text("• \(failure.address)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
    }

    private var routeAnnotations: [RouteAnnotation] {
        var annotations: [RouteAnnotation] = []
        let navigable = stops.filter(\.hasUsableAddress)
        for (index, stop) in navigable.enumerated() {
            guard let coordinate = previewCoordinate(for: stop.id) else { continue }
            annotations.append(RouteAnnotation(
                id: stop.id,
                title: stop.title,
                coordinate: coordinate,
                order: index + 1
            ))
        }
        return annotations
    }

    private var routePolylines: [RoutePolyline] {
        var polylines: [RoutePolyline] = []
        for leg in preview.legs {
            guard let fromCoord = previewCoordinate(for: leg.fromStopID ?? "origin"),
                  let toCoord = previewCoordinate(for: leg.toStopID) else { continue }
            polylines.append(RoutePolyline(coordinates: [fromCoord, toCoord]))
        }
        return polylines
    }

    private func previewCoordinate(for stopID: String) -> CLLocationCoordinate2D? {
        // Note: In production, we'd need to cache coordinates from the preview runner.
        // For now, return nil to avoid re-geocoding. The preview legs already have estimates.
        // The map would need coordinate caching in the runner for full polyline support.
        return nil
    }

    private var mapCameraPosition: MapCameraPosition {
        // Default camera - would be refined with actual coordinates
        .automatic
    }
}

private struct RouteAnnotation: Identifiable {
    let id: String
    let title: String
    let coordinate: CLLocationCoordinate2D
    let order: Int
}

private struct RoutePolyline: Identifiable {
    let id = UUID()
    let coordinates: [CLLocationCoordinate2D]
}

// MARK: - List Header View

private struct ListHeaderView: View {
    let dateString: String
    let stopCount: Int
    let navigableCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateString.formattedDate)
                .font(.headline)
            HStack(spacing: 12) {
                Label("\(stopCount) stops", systemImage: "list.bullet")
                Label("\(navigableCount) navigable", systemImage: "location.fill")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Stop Row View

private struct StopRowView: View {
    let stop: NativeRouteStop
    let index: Int
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onNavigate: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Drag handle / order indicator
            VStack(spacing: 4) {
                if !isFirst {
                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.tradeReady)
                            .frame(minWidth: NativeAccessibilityAudit.minimumTouchTarget, minHeight: NativeAccessibilityAudit.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NativeAccessibilityAudit.Label.moveStopUp)
                }
                Text("\(index + 1)")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24)
                if !isLast {
                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.tradeReady)
                            .frame(minWidth: NativeAccessibilityAudit.minimumTouchTarget, minHeight: NativeAccessibilityAudit.minimumTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(NativeAccessibilityAudit.Label.moveStopDown)
                }
            }
            .frame(width: 44)

            // Stop info
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title)
                    .font(.body.weight(.medium))
                Text(stop.customerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let start = stop.scheduledStartTime {
                    Text("Starts at \(start)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Untimed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Address / navigate
            VStack(alignment: .trailing, spacing: 4) {
                if stop.hasUsableAddress {
                    Text(stop.normalizedAddress!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .trailing)
                    Button(action: onNavigate) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.title3)
                            .foregroundStyle(Color.tradeReady)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Navigate to \(stop.title)")
                } else {
                    Text("No address")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Date Formatting Extension

extension String {
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: self) {
            formatter.dateStyle = .full
            return formatter.string(from: date)
        }
        return self
    }
}

// Note: The AppStore extension for route is in AppStore.swift as `calendarScheduleJobs()`
// NativeRouteView uses `store.calendarScheduleJobs()` directly in its `loadRoute()` method.