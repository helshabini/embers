import EmbersCore
import Foundation

extension YearMonth {
    /// "September 2026", for headings.
    public var displayName: String {
        let formatter = DateFormatter()
        formatter.locale = .display
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        // A template, not a pattern: the language decides the order and the month names.
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        return formatter.string(from: firstDay)
    }

    /// "Sep", for a grid of months where the year is already overhead.
    public var shortMonthName: String {
        let formatter = DateFormatter()
        formatter.locale = .display
        formatter.calendar = .gregorianUTC
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("LLL")
        return formatter.string(from: firstDay)
    }
}
