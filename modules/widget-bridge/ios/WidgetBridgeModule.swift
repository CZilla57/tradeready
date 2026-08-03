import ExpoModulesCore
import WidgetKit

// The native half of the App Group widget bridge (docs/widget-plan.md).
// JS (utils/widgetBridge.ts) serializes the snapshot; this module only moves
// bytes into the shared container and pokes WidgetKit. Keep it dumb — the app
// stays the single writer of real data, and all selection logic lives in JS
// where it is unit-tested.
//
// The suite name must match app.json ios.entitlements
// "com.apple.security.application-groups" and targets/widget/expo-target.config.js.
public class WidgetBridgeModule: Module {
  private static let appGroupId = "group.com.gettradereadyapp.tradeready"

  public func definition() -> ModuleDefinition {
    Name("WidgetBridge")

    // Writes the JSON snapshot under `key`, then reloads widget timelines so
    // widgets never sit on stale data. Missing container (entitlement not yet
    // provisioned) is a silent no-op — JS treats the mirror as best-effort.
    AsyncFunction("setSharedItem") { (key: String, json: String) in
      guard let defaults = UserDefaults(suiteName: Self.appGroupId) else { return }
      defaults.set(json, forKey: key)
      WidgetCenter.shared.reloadAllTimelines()
    }

    // Wipes EVERYTHING in the shared container and refreshes widgets to their
    // empty state. Called from clearAllUserData at sign-out — the next account
    // on this device must not see the previous account's data in a widget.
    AsyncFunction("clearShared") {
      if let defaults = UserDefaults(suiteName: Self.appGroupId) {
        defaults.removePersistentDomain(forName: Self.appGroupId)
      }
      WidgetCenter.shared.reloadAllTimelines()
    }
  }
}
