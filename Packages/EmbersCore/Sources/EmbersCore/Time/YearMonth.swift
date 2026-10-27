import Foundation

/// A budget month. The envelope model assigns money to (category, month) pairs, so the month is a
/// first-class key rather than a truncated `Date`.
public struct YearMonth: Hashable, Comparable, Sendable, Codable {
    public let year: Int
    /// 1...12
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...12).contains(month), "Month out of range: \(month)")
        self.year = year
        self.month = month
    }

    public init(containing date: Date, calendar: Calendar = .gregorianUTC) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1)
    }

    /// The month it is where the person is.
    ///
    /// Not `YearMonth(containing: Date())`: budget dates live in UTC, and east of Greenwich the first
    /// hours of a month are still the previous month there. At UTC+4 on the 1st of October, that
    /// reading opens the plan on September and files the morning's shopping under it.
    public static func current(in timeZone: TimeZone = .current, now: Date = Date()) -> YearMonth {
        YearMonth(containing: .todayAsBudgetDay(in: timeZone, now: now))
    }

    /// Months since year 0, giving a total order and cheap arithmetic.
    public var ordinal: Int { year * 12 + (month - 1) }

    public init(ordinal: Int) {
        self.init(year: ordinal / 12, month: ordinal % 12 + 1)
    }

    public func adding(months: Int) -> YearMonth {
        YearMonth(ordinal: ordinal + months)
    }

    public var previous: YearMonth { adding(months: -1) }
    public var next: YearMonth { adding(months: 1) }

    public var firstDay: Date {
        Calendar.gregorianUTC.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    public static func < (lhs: YearMonth, rhs: YearMonth) -> Bool { lhs.ordinal < rhs.ordinal }

    /// Inclusive range of months, ascending.
    public static func range(from start: YearMonth, through end: YearMonth) -> [YearMonth] {
        guard start <= end else { return [] }
        return (start.ordinal...end.ordinal).map(YearMonth.init(ordinal:))
    }
}

extension YearMonth: CustomStringConvertible {
    /// Sortable and stable across locales: "2026-09".
    public var description: String { String(format: "%04d-%02d", year, month) }
}

extension YearMonth {
    private static let monthAbbreviations = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    /// Parses the forms this app ingests: YNAB's "Aug 2019" and its own "2019-08".
    public static func parse(_ text: String) -> YearMonth? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-")
            guard parts.count >= 2, let year = Int(parts[0]), let month = Int(parts[1]),
                  (1...12).contains(month)
            else { return nil }
            return YearMonth(year: year, month: month)
        }

        let parts = trimmed.split(separator: " ")
        guard parts.count == 2, let year = Int(parts[1]) else { return nil }
        let key = parts[0].prefix(3).lowercased()
        guard let month = monthAbbreviations[key] else { return nil }
        return YearMonth(year: year, month: month)
    }
}

extension Date {
    /// Budget dates are calendar days, stored at midday UTC so no timezone can shift them onto a
    /// neighbouring day.
    public static func budgetDay(year: Int, month: Int, day: Int) -> Date {
        Calendar.gregorianUTC.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ) ?? .distantPast
    }

    /// Today, as a budget day: the day it is locally, placed where budget dates live.
    ///
    /// A new entry is dated the day the person is having, not the instant they tapped Save. Those
    /// differ for anyone not on UTC — at UTC+4 the first four hours of every day are still yesterday
    /// in UTC, so `Date()` files them in the wrong day and, on the 1st, the wrong month.
    public static func todayAsBudgetDay(in timeZone: TimeZone = .current, now: Date = Date()) -> Date {
        now.asBudgetDay(in: timeZone)
    }

    /// The local day this instant fell in, placed where budget dates live.
    ///
    /// For anything that arrives as an instant rather than a day: a `DatePicker` hands back the
    /// picked day at the local time of the date it was given, and entries saved before the editor
    /// knew better hold the moment of saving.
    public func asBudgetDay(in timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: self)
        return .budgetDay(
            year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1
        )
    }

    /// Whether this already sits where budget dates live: midday UTC, to the second.
    public var isBudgetDay: Bool {
        let parts = Calendar.gregorianUTC.dateComponents([.hour, .minute, .second, .nanosecond], from: self)
        return parts.hour == 12 && parts.minute == 0 && parts.second == 0 && (parts.nanosecond ?? 0) < 1_000_000
    }

    /// The end of the calendar day containing `date`, for use as an activity cutoff.
    ///
    /// Activity is counted by date, not by the moment of asking: a transaction dated today belongs to
    /// this month's activity even at nine in the morning. The day is taken from the local calendar,
    /// since that is the day the person means, and the boundary is placed in UTC, where the dates
    /// themselves live.
    public static func endOfBudgetDay(containing date: Date = Date(), in timeZone: TimeZone = .current) -> Date {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = timeZone
        let parts = local.dateComponents([.year, .month, .day], from: date)
        return Calendar.gregorianUTC.date(
            from: DateComponents(
                year: parts.year, month: parts.month, day: parts.day,
                hour: 23, minute: 59, second: 59
            )
        ) ?? date
    }
}

extension Calendar {
    /// Budget months are calendar labels, not instants: a fixed UTC calendar keeps a transaction's
    /// month from shifting when the device timezone changes.
    public static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}
