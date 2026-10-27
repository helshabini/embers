import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A glowing-ember palette: deep red through orange into a warm highlight.
///
/// Money keeps its own meaning separate from the theme — outflows read red and inflows green — so the
/// flame colours are reserved for chrome and emphasis and never used to state a number's sign.
///
/// Two kinds of colour live here, and the difference is what makes dark mode work:
///
/// - **The icon's own colours** (`iconDeep`, `iconEmber`, `iconGlow`) are fixed. They fill the
///   gradient cards, which are saturated blocks carrying white text in either scheme, so changing
///   them would only make the app stop matching its icon.
/// - **Everything drawn *on* a background** adapts. A colour dark enough to read against white is
///   too dark to read against near-black, so tints, badges and signed amounts resolve per scheme.
enum Flame {
    /// Resolves when it is drawn rather than when it is defined, so one token serves both schemes.
    private static func adaptive(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
        #endif
    }

    /// Taken from the app icon so the two read as one thing: the burning tree's outer flames are
    /// #EC3013 and its inner ones #FF7A1A. Fixed — these are the brand, not a foreground.
    static let iconDeep = Color(red: 0.70, green: 0.13, blue: 0.05)
    static let iconEmber = Color(red: 0.925, green: 0.188, blue: 0.075)
    static let iconGlow = Color(red: 1.00, green: 0.478, blue: 0.102)

    /// The accent: tints, checkmarks, selected state. Lightened on dark, where the icon's red is
    /// barely separable from the background behind it.
    static let ember = adaptive(light: iconEmber, dark: Color(red: 1.00, green: 0.416, blue: 0.239))
    /// The deepest flame, used for small text on a tinted fill. Inverts to a pale ember on dark.
    static let deep = adaptive(light: iconDeep, dark: Color(red: 1.00, green: 0.541, blue: 0.361))
    /// Bright enough to carry either background unchanged; also the "underfunded but coverable" amber.
    static let glow = iconGlow
    static let highlight = Color(red: 1.00, green: 0.70, blue: 0.40)

    /// The trunk of the burning tree on the launch screen, taken from the two icon variants: charred
    /// on the light one, near-white on the dark one.
    static let bark = adaptive(
        light: Color(red: 0.125, green: 0.118, blue: 0.114),
        dark: Color(red: 0.949, green: 0.949, blue: 0.949)
    )

    /// Outflows. Distinct from `deep` so a negative number never reads as decoration.
    static let outflow = adaptive(
        light: Color(red: 0.85, green: 0.18, blue: 0.16),
        dark: Color(red: 1.00, green: 0.420, blue: 0.388)
    )
    static let inflow = adaptive(
        light: Color(red: 0.12, green: 0.62, blue: 0.35),
        dark: Color(red: 0.243, green: 0.851, blue: 0.541)
    )

    /// The wash behind a badge or pill. A tint that reads on white disappears on near-black, so it
    /// carries more weight there.
    static let tintedFill = adaptive(
        light: iconEmber.opacity(0.14),
        dark: Color(red: 1.00, green: 0.478, blue: 0.102).opacity(0.24)
    )

    // MARK: - Chart series
    //
    // These are not brand colours and are not chosen by eye. A chart has to stay readable to someone
    // who cannot separate red from green, and the obvious pairing — our own inflow green against our
    // outflow red — fails exactly that: ΔE 5.9 for deuteranopia, well under the 8 floor. Each set
    // below was run through the palette validator in both schemes, and the dark column is the same
    // hues re-stepped for a dark surface rather than a flip.

    /// Money coming in. `#1baf7a` / `#199e70`.
    static let seriesIncome = adaptive(
        light: Color(red: 0.106, green: 0.686, blue: 0.478),
        dark: Color(red: 0.098, green: 0.620, blue: 0.439)
    )
    /// Money going out. `#eb6834` / `#d95926` — the brand's orange, so spending reads as the app's
    /// own colour while staying clear of the income green (ΔE 9.2 light, 9.4 dark).
    static let seriesSpending = adaptive(
        light: Color(red: 0.922, green: 0.408, blue: 0.204),
        dark: Color(red: 0.851, green: 0.349, blue: 0.149)
    )

    /// Categories in the spending breakdown, in fixed order — never cycled, never assigned by rank.
    /// Worst adjacent pair ΔE 9.1 light / 8.4 dark for colour-vision deficiency.
    static let categorical: [Color] = [
        adaptive(  // #2a78d6 / #3987e5
            light: Color(red: 0.165, green: 0.471, blue: 0.839),
            dark: Color(red: 0.224, green: 0.529, blue: 0.898)
        ),
        seriesSpending,  // #eb6834 / #d95926
        seriesIncome,    // #1baf7a / #199e70
        adaptive(  // #eda100 / #c98500
            light: Color(red: 0.929, green: 0.631, blue: 0.000),
            dark: Color(red: 0.788, green: 0.522, blue: 0.000)
        ),
        adaptive(  // #e87ba4 / #d55181
            light: Color(red: 0.910, green: 0.482, blue: 0.643),
            dark: Color(red: 0.835, green: 0.318, blue: 0.506)
        ),
    ]

    /// Everything past the top few. A neutral, because "the rest" is not an identity.
    static let categoricalRest = adaptive(
        light: Color(white: 0.78),
        dark: Color(white: 0.42)
    )

    /// The colour for the category in position `index`, folding the tail into the neutral.
    static func categoryColor(_ index: Int) -> Color {
        index < categorical.count ? categorical[index] : categoricalRest
    }

    static let gradient = LinearGradient(
        colors: [iconDeep, iconEmber, iconGlow],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Money coming in, so the card reads green before the number does.
    static let inflowGradient = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.42, blue: 0.24),
            Color(red: 0.12, green: 0.62, blue: 0.35),
            Color(red: 0.32, green: 0.78, blue: 0.45),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// More given out than there is.
    static let outflowGradient = LinearGradient(
        colors: [
            Color(red: 0.55, green: 0.08, blue: 0.08),
            Color(red: 0.78, green: 0.15, blue: 0.14),
            Color(red: 0.90, green: 0.30, blue: 0.26),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Every dollar has a job: nothing to do, so nothing to draw the eye.
    static let neutralGradient = LinearGradient(
        colors: [
            Color(white: 0.30),
            Color(white: 0.42),
            Color(white: 0.55),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Behind a page of cards, and the cards on it: the grouped backgrounds on the phone, the
    /// window and control backgrounds on the Mac.
    #if canImport(UIKit)
    static let groupedBackground = Color(.systemGroupedBackground)
    static let cardBackground = Color(.secondarySystemGroupedBackground)
    #else
    static let groupedBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    #endif

    static let softGradient = LinearGradient(
        colors: [ember.opacity(0.16), glow.opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Colour for a signed amount.
    static func amountColor(_ minorUnits: Int64) -> Color {
        if minorUnits < 0 { return outflow }
        return minorUnits > 0 ? inflow : .secondary
    }
}

/// The headline card at the top of a screen: a figure that deserves the glow.
struct FlameHeader<Content: View>: View {
    var title: String
    var subtitle: String?
    var background: LinearGradient = Flame.gradient
    /// The glow beneath the card. Matches the card, or a green card sits in an ember halo.
    var shadow: Color = Flame.iconEmber
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                if let subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // Beneath only. A plain `.shadow` haloed every edge, and with the card already inset in its
        // row the halo made it read as narrower than the sections under it. Pulling the glow in at
        // the sides keeps it from showing past either edge.
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(shadow.opacity(0.35))
                .padding(.horizontal, 14)
                .offset(y: 8)
                .blur(radius: 8)
        }
        // No side inset: the row is already inset by the list, so the card lines up with every
        // section below it. Its own 16 pt on top of that made it 32 pt narrower.
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 14, trailing: 0))
        .listRowBackground(Color.clear)
    }
}

/// The round (+) that starts a new transaction, floating over a screen's lower corner.
struct FloatingAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(Flame.gradient, in: Circle())
                .shadow(color: Flame.ember.opacity(0.45), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
        .padding(.bottom, 24)
        .accessibilityLabel("Add Transaction")
    }
}

/// A currency code shown beside an account's name, so the name need not carry it.
struct CurrencyBadge: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Flame.tintedFill, in: Capsule())
            .foregroundStyle(Flame.deep)
    }
}

extension View {
    /// Applies the app's accent throughout.
    func flameTinted() -> some View {
        tint(Flame.ember)
    }
}
