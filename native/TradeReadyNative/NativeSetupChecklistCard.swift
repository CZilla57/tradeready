import SwiftUI
import UIKit

/// The "Finish setting up" card (task 10.12, requirements D4, D5). RN
/// `components/SetupChecklistCard.tsx` port: derives tasks from 10.03's pure
/// `NativeSetupChecklistInput.tasks(...)`, records done/dismissed through the
/// owner-bound `NativeSetupChecklistStore`, and routes each task to its exact
/// `SETTINGS_ROUTE_FOR_TASK` destination — except `notifications`, handled
/// in-card through the 10.05 permission API (request; on grant mark granted
/// + `synchronize()`; on refusal offer "Open device settings").
///
/// Fail-closed (brief step 5): the checklist is hidden entirely when the
/// store could not be read (`AppStore.setupChecklistState == nil`) — the
/// same value that also gates the insights card's "setup incomplete"
/// condition, per the shared `isSetupComplete` contract.
struct NativeSetupChecklistCardView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var followUpNotifications: NativeEstimateFollowUpNotificationCoordinator
    @Environment(\.openURL) private var openURL

    @State private var showingNotificationsDeniedAlert = false

    var body: some View {
        if let tasks = store.todaySetupTasks, !store.todaySetupComplete {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Finish setting up").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(tasks.filter(\.done).count) of \(tasks.count)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Button("Hide") { store.dismissSetupChecklist() }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Hide setup checklist")
                }
                .padding(.bottom, 6)

                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    Button {
                        handleTap(task)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.done ? Color.tradeSuccessText : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(task.done ? .secondary : .primary)
                                    .strikethrough(task.done)
                                if !task.done {
                                    Text(task.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !task.done { Text("›").font(.title3).foregroundStyle(.tertiary) }
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(task.done)
                    .overlay(alignment: .top) { if index > 0 { Divider() } }
                    .accessibilityLabel(task.title)
                    .accessibilityAddTraits(task.done ? [] : .isButton)
                }
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.quaternary) }
            .alert("Notifications are off", isPresented: $showingNotificationsDeniedAlert) {
                Button("Not now", role: .cancel) {}
                Button("Open device settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } message: {
                Text("Enable notifications for TradeReady in your device settings to get invoice reminders.")
            }
        }
    }

    private func handleTap(_ task: NativeSetupTask) {
        guard !task.done else { return }
        // Fix round 1 (minor): RN fires `setup_checklist_task_opened` for
        // every task tap, including `notifications` — it was previously
        // skipped here because of the early return below.
        store.trackSetupChecklistTaskOpened(task.id)
        if task.id == .notifications {
            Task { await handleNotificationsTask() }
            return
        }
        store.routeToTodaySettings(NativeSetupChecklist.route(for: task.id))
    }

    private func handleNotificationsTask() async {
        let granted = await followUpNotifications.requestAuthorization()
        if granted {
            await followUpNotifications.synchronize()
        } else {
            showingNotificationsDeniedAlert = true
        }
    }
}
