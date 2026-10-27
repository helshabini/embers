import EmbersCore
import SwiftUI

/// The credit the rate provider asks for, wherever its rates are shown. Quiet, as their terms allow:
/// "in keeping with how the rest of your application looks".
struct RateAttribution: View {
    let providerName: String?

    var body: some View {
        if let providerName, let attribution = ExchangeRateAttribution.forProvider(named: providerName) {
            Text(Self.linked(attribution))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("rate-attribution")
        }
    }

    /// The credit as linked text, for joining onto a line that is already there.
    static func linked(_ attribution: ExchangeRateAttribution) -> AttributedString {
        var text = AttributedString(attribution.text)
        text.link = attribution.url
        return text
    }

    /// A note with the credit beneath it, as one piece of text, for a form's footer. Two views
    /// stacked there — the note, then the credit — stopped the phone's entry form scrolling from a
    /// swipe with the keypad up, whether the credit was a `Link` or plain text; one `Text` does not
    /// (`testDetailsBelowTheKeypadAreReachableByScrolling`).
    static func note(_ note: String, crediting providerName: String?) -> AttributedString {
        var text = AttributedString(note)
        if let providerName, let attribution = ExchangeRateAttribution.forProvider(named: providerName) {
            if !note.isEmpty { text += AttributedString("\n") }
            text += linked(attribution)
        }
        return text
    }
}
