import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Task 11.10b (A24): RN `components/KeyboardDoneBar.tsx`. iOS pad keyboards
// (decimal, number, phone) have no return key and a multi-line field uses
// return for a new line, so neither can dismiss itself. RN mounts a "Done"
// accessory bar (`accessibilityLabel="Dismiss keyboard"`) for those inputs;
// native puts the same button above the keyboard on every screen that holds
// one. SwiftUI's keyboard toolbar belongs to the screen, not the field, so the
// bar also shows above that screen's text keyboards (a native difference
// recorded in contract §12.3; it only adds a way to dismiss).

extension View {
    /// Adds RN's keyboard "Done" bar. Apply once per screen, on the view that
    /// owns the fields (a nested one would show a second button).
    func nativeKeyboardDoneBar() -> some View {
        #if os(iOS)
        return toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                }
                .fontWeight(.semibold)
                .accessibilityLabel(NativeAccessibilityAudit.Label.dismissKeyboard)
            }
        }
        #else
        return self
        #endif
    }
}
