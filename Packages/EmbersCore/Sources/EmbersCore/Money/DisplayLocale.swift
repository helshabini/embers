import Foundation

extension Locale {
    /// The reader's locale, writing numbers in the digits 0–9.
    ///
    /// Everything else stays theirs — language, month names, and the separators: 1,000.50 in
    /// English, 1.000,50 in German, 1 000,50 in French. Only the digits are pinned. Arabic's own
    /// digits come with a thousands mark (٬) and a decimal mark (٫) that the system font draws as
    /// the same comma, so ٣٬٧٦٧٫٨١ reads as "3,767,81"; Egyptian and Gulf banks write amounts in
    /// 0–9 for the same reason. Every number shown goes through this — a `.formatted()` without it
    /// writes the phone's own digits, and one stray figure in another script is worse than none.
    public static var display: Locale {
        var components = Locale.Components(locale: .current)
        components.numberingSystem = Locale.NumberingSystem("latn")
        return Locale(components: components)
    }
}
