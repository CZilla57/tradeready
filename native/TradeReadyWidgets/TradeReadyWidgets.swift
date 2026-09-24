import SwiftUI
import WidgetKit

// Task 11.01 (W1): the TradeReadyWidgets extension entry point.
//
// Target membership (task 11.01 execution log, plan §7): every file in
// `native/TradeReadyWidgets/` compiles into the extension ONLY; every file in
// `native/TradeReadyNative/Widgets/Shared/` compiles into BOTH the extension
// and the app. Neither needs a project-file edit when a file is added.
//
// 11.02 replaced the 11.01 placeholder widget with `NextJobWidget`
// (`native/TradeReadyWidgets/NextJobWidget.swift`). 11.03 adds
// `JobTimerWidget` (`native/TradeReadyWidgets/JobTimerWidget.swift`) below.

@main
struct TradeReadyWidgets: WidgetBundle {
    var body: some Widget {
        NextJobWidget()
        JobTimerWidget()
    }
}
