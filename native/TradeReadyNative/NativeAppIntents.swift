import AppIntents

// Task 11.04 (A1, A2): the App Shortcuts provider. App target only — Apple DTS:
// the `AppShortcutsProvider` and the intents it declares must be in the main
// app target, or the phrases never reach Siri (contract §5.4).
//
// Phrases and short titles: contract §5.2 (the RN phrases, each containing
// `\(.applicationName)`). Start/Stop Job Timer (`N/Widgets/Shared/WidgetIntents.swift`)
// are widget-button-only (`isDiscoverable = false`) and have no phrases.
// Single availability floor: iOS 17.0.

@available(iOS 17.0, *)
struct TradeReadyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextJobIntent(),
            phrases: [
                "What's my next job in \(.applicationName)",
                "What's next in \(.applicationName)",
            ],
            shortTitle: "Next Job",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: StartTripIntent(),
            phrases: [
                "Start a trip in \(.applicationName)",
                "Start tracking miles in \(.applicationName)",
            ],
            shortTitle: "Start Trip",
            systemImageName: "car"
        )
        AppShortcut(
            intent: StopTripIntent(),
            phrases: [
                "Stop my trip in \(.applicationName)",
                "Finish my trip in \(.applicationName)",
            ],
            shortTitle: "Stop Trip",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: OnMyWayIntent(),
            phrases: [
                "I'm on my way in \(.applicationName)",
                "Tell my customer I'm on my way in \(.applicationName)",
            ],
            shortTitle: "On My Way",
            systemImageName: "message"
        )
        AppShortcut(
            intent: ClockInIntent(),
            phrases: [
                "Clock in in \(.applicationName)",
                "Start the clock in \(.applicationName)",
            ],
            shortTitle: "Clock In",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: ClockOutIntent(),
            phrases: [
                "Clock out in \(.applicationName)",
                "Stop the clock in \(.applicationName)",
            ],
            shortTitle: "Clock Out",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "Log an expense in \(.applicationName)",
                "Add an expense in \(.applicationName)",
            ],
            shortTitle: "Log Expense",
            systemImageName: "dollarsign.circle"
        )
        AppShortcut(
            intent: OutstandingIntent(),
            phrases: [
                "How much am I owed in \(.applicationName)",
                "What's outstanding in \(.applicationName)",
            ],
            shortTitle: "Outstanding",
            systemImageName: "banknote"
        )
    }
}
