import EmbersData
import SwiftUI

extension View {
    /// Stops a name field at the longest name a category or group can have, so the field says where
    /// the limit is instead of the name being cut short after it is saved. From a change rather than
    /// a binding that refuses the extra characters: an alert's field ignores such a binding and keeps
    /// showing everything typed.
    func limitedToPlanName(_ text: Binding<String>) -> some View {
        onChange(of: text.wrappedValue) { _, name in
            if name.count > CategoryWriter.maximumNameLength {
                text.wrappedValue = String(name.prefix(CategoryWriter.maximumNameLength))
            }
        }
    }
}
