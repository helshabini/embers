import Foundation

/// How often a scheduled transaction repeats.
///
/// Only the next occurrence is ever stored. A repeating transaction is one future-dated entry
/// carrying its rule; when its date arrives it becomes an ordinary past transaction and the next one
/// takes its place. That keeps a weekly grocery shop from filling the register with a hundred rows
/// nobody has confirmed yet.
public enum Recurrence: String, Codable, Sendable, CaseIterable {
    case daily
    case weekly
    case everyOtherWeek
    case everyFourWeeks
    case monthly
    case everyOtherMonth
    case everyThreeMonths
    case everySixMonths
    case yearly

    public var displayName: String {
        switch self {
        case .daily: String(localized: "Every day", bundle: .module)
        case .weekly: String(localized: "Every week", bundle: .module)
        case .everyOtherWeek: String(localized: "Every other week", bundle: .module)
        case .everyFourWeeks: String(localized: "Every four weeks", bundle: .module)
        case .monthly: String(localized: "Every month", bundle: .module)
        case .everyOtherMonth: String(localized: "Every other month", bundle: .module)
        case .everyThreeMonths: String(localized: "Every three months", bundle: .module)
        case .everySixMonths: String(localized: "Every six months", bundle: .module)
        case .yearly: String(localized: "Every year", bundle: .module)
        }
    }

    /// The same rule, short enough to sit beside an amount in a register row.
    ///
    /// "Every three months" truncates to "Every t…" in the width a row can spare, which says nothing.
    public var shortName: String {
        switch self {
        case .daily: String(localized: "Daily", bundle: .module)
        case .weekly: String(localized: "Weekly", bundle: .module)
        case .everyOtherWeek: String(localized: "Every 2 weeks", bundle: .module)
        case .everyFourWeeks: String(localized: "Every 4 weeks", bundle: .module)
        case .monthly: String(localized: "Monthly", bundle: .module)
        case .everyOtherMonth: String(localized: "Every 2 months", bundle: .module)
        case .everyThreeMonths: String(localized: "Every 3 months", bundle: .module)
        case .everySixMonths: String(localized: "Every 6 months", bundle: .module)
        case .yearly: String(localized: "Yearly", bundle: .module)
        }
    }

    /// The occurrence after `date`.
    ///
    /// Month-based rules keep the day of the month where they can: a payment due on the 31st falls
    /// back to the last day of a shorter month rather than drifting earlier for good.
    public func nextDate(after date: Date, calendar: Calendar = .gregorianUTC) -> Date {
        switch self {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        case .weekly:
            return calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .everyOtherWeek:
            return calendar.date(byAdding: .day, value: 14, to: date) ?? date
        case .everyFourWeeks:
            return calendar.date(byAdding: .day, value: 28, to: date) ?? date
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .everyOtherMonth:
            return calendar.date(byAdding: .month, value: 2, to: date) ?? date
        case .everyThreeMonths:
            return calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .everySixMonths:
            return calendar.date(byAdding: .month, value: 6, to: date) ?? date
        case .yearly:
            return calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    /// The first occurrence strictly after `cutoff`, stepping from `date`.
    ///
    /// Used when catching up a schedule that has been left alone for a while.
    public func nextDate(after date: Date, notBefore cutoff: Date, calendar: Calendar = .gregorianUTC) -> Date {
        var candidate = nextDate(after: date, calendar: calendar)
        // A daily rule left untouched for years would otherwise loop a very long time.
        var guardCount = 0
        while candidate <= cutoff, guardCount < 5_000 {
            candidate = nextDate(after: candidate, calendar: calendar)
            guardCount += 1
        }
        return candidate
    }
}
