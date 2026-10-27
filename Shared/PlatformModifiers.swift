import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The phone-only touches the shared screens ask for, as nothing on the Mac.
///
/// A form shared between the two is the same form; what differs is a keyboard the Mac does not have
/// and a title style its windows do not use. Spelt once here rather than as an `#if` in every view.
extension View {
    /// A small title in the bar, on the phone. A Mac window titles itself.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Digits and a decimal point, on the phone.
    func decimalKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.decimalPad)
        #else
        self
        #endif
    }

    /// Digits with a minus sign within reach, on the phone: a statement can be overdrawn.
    func numbersKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
}

enum SystemSettings {
    /// Where notifications are allowed again once they have been refused.
    @MainActor
    static func openNotifications() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
