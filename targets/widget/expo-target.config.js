// Widget extension target, materialized into the Xcode project at prebuild by
// @bacons/apple-targets. Swift sources live alongside this file.
// iOS 17 floor: containerBackground is mandatory there anyway, and the Phase-3
// interactive timer widget requires 17 — older devices simply aren't offered
// the widget; the app itself still runs on the SDK minimum.
/** @type {import('@bacons/apple-targets/app.plugin').Config} */
module.exports = {
  type: "widget",
  name: "TradeReadyWidgets",
  displayName: "TradeReady",
  deploymentTarget: "17.0",
  bundleIdentifier: ".widgets",
  frameworks: ["SwiftUI", "WidgetKit", "AppIntents"],
  entitlements: {
    // Must match app.json ios.entitlements and WidgetBridgeModule.swift.
    "com.apple.security.application-groups": ["group.com.gettradereadyapp.tradeready"],
  },
};
