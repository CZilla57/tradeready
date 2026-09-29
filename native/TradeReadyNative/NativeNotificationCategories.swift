import UserNotifications

/// One `UNNotificationCategory` per notification family (task 10.05, N1),
/// identified by the same `payloadType` string `NativeNotificationRoute.decode`
/// already switches on (`NativeEstimateFollowUpNotifications.swift`), so a
/// delivered notification's category always matches the family that can route
/// its tap. Every category exposes only a single non-destructive,
/// app-foregrounding "View" action — no category here can send anything to a
/// customer directly from the notification surface, and none is destructive.
///
/// Registration itself (`setNotificationCategories`, once per launch) is
/// driven by `NativeEstimateFollowUpNotificationCoordinator.registerCategoriesIfNeeded()`
/// through the injectable `NativeEstimateFollowUpNotificationCenter` protocol,
/// so host tests can assert "registered exactly once" without touching the
/// real OS notification center.
enum NativeNotificationCategories {
    static let viewActionIdentifier = "VIEW"

    static func makeAll() -> Set<UNNotificationCategory> {
        let viewAction = UNNotificationAction(
            identifier: viewActionIdentifier,
            title: "View",
            options: [.foreground]
        )
        return Set(NativeNotificationNamespace.allCases.map { namespace in
            UNNotificationCategory(
                identifier: namespace.payloadType,
                actions: [viewAction],
                intentIdentifiers: [],
                options: []
            )
        })
    }
}
