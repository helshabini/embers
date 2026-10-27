import Foundation

public struct YNABPlanRow: Sendable {
    public var month: YearMonth
    public var groupName: String
    public var categoryName: String
    public var assigned: MinorUnits
    public var activity: MinorUnits
    public var available: MinorUnits
}

public struct YNABRegisterRow: Sendable {
    public var account: String
    public var flag: String
    public var date: Date
    public var payee: String
    public var groupName: String
    public var categoryName: String
    public var memo: String
    /// Signed: inflow minus outflow, so an outflow is negative.
    public var amount: MinorUnits
    public var cleared: ClearedStatus
    /// Position in the file, used to keep split siblings together.
    public var sourceIndex: Int
}

public enum YNABParseError: Error, CustomStringConvertible {
    case missingColumns(file: String, expected: [String], found: [String])

    public var description: String {
        switch self {
        case let .missingColumns(file, expected, found):
            "\(file) is missing expected columns. Expected \(expected), found \(found)."
        }
    }
}

/// Reads the two CSVs in a YNAB export ("… - Plan.csv" and "… - Register.csv").
///
/// YNAB prints every amount with a `$` symbol regardless of the account's real-world currency, so
/// amounts are parsed as plain numbers in the plan's base currency and never converted here.
public struct YNABExportParser: Sendable {
    public let baseCurrency: Currency

    public init(baseCurrency: Currency = CurrencyRegistry.usd) {
        self.baseCurrency = baseCurrency
    }

    public static let planColumns = ["Month", "Category Group", "Category", "Assigned", "Activity", "Available"]
    public static let registerColumns = [
        "Account", "Date", "Payee", "Category Group", "Category", "Memo", "Outflow", "Inflow", "Cleared",
    ]

    public func parsePlan(_ text: String) throws -> [YNABPlanRow] {
        let table = CSVParser.parse(text)
        guard table.hasColumns(Self.planColumns) else {
            throw YNABParseError.missingColumns(file: "Plan.csv", expected: Self.planColumns, found: table.columns)
        }

        return table.rows.compactMap { row in
            guard let month = YearMonth.parse(table.value("Month", in: row)) else { return nil }
            let categoryName = table.value("Category", in: row).trimmingCharacters(in: .whitespaces)
            guard !categoryName.isEmpty else { return nil }
            return YNABPlanRow(
                month: month,
                groupName: table.value("Category Group", in: row).trimmingCharacters(in: .whitespaces),
                categoryName: categoryName,
                assigned: money(table.value("Assigned", in: row)),
                activity: money(table.value("Activity", in: row)),
                available: money(table.value("Available", in: row))
            )
        }
    }

    public func parseRegister(_ text: String) throws -> [YNABRegisterRow] {
        let table = CSVParser.parse(text)
        guard table.hasColumns(Self.registerColumns) else {
            throw YNABParseError.missingColumns(
                file: "Register.csv", expected: Self.registerColumns, found: table.columns
            )
        }

        var rows: [YNABRegisterRow] = []
        rows.reserveCapacity(table.rows.count)
        for (index, row) in table.rows.enumerated() {
            let accountName = table.value("Account", in: row).trimmingCharacters(in: .whitespaces)
            guard !accountName.isEmpty, let date = Self.parseDate(table.value("Date", in: row)) else { continue }
            let outflow = money(table.value("Outflow", in: row))
            let inflow = money(table.value("Inflow", in: row))
            rows.append(
                YNABRegisterRow(
                    account: accountName,
                    flag: table.value("Flag", in: row).trimmingCharacters(in: .whitespaces),
                    date: date,
                    payee: table.value("Payee", in: row).trimmingCharacters(in: .whitespaces),
                    groupName: table.value("Category Group", in: row).trimmingCharacters(in: .whitespaces),
                    categoryName: table.value("Category", in: row).trimmingCharacters(in: .whitespaces),
                    memo: table.value("Memo", in: row),
                    amount: inflow - outflow,
                    cleared: Self.parseCleared(table.value("Cleared", in: row)),
                    sourceIndex: index
                )
            )
        }
        return rows
    }

    private func money(_ text: String) -> MinorUnits {
        Money.parse(text, currency: baseCurrency)?.minorUnits ?? 0
    }

    /// YNAB exports dates as MM/DD/YYYY. Parsed by hand so a device locale can't reinterpret it.
    public static func parseDate(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 3,
              let month = Int(parts[0]), let day = Int(parts[1]), let year = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return Calendar.gregorianUTC.date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        )
    }

    public static func parseCleared(_ text: String) -> ClearedStatus {
        switch text.trimmingCharacters(in: .whitespaces).lowercased() {
        case "reconciled": .reconciled
        case "cleared": .cleared
        default: .uncleared
        }
    }

    // MARK: - Row shapes

    public static let transferPayeePrefix = "Transfer : "

    /// `Transfer : Atlas Checking (EGP)` → `Atlas Checking (EGP)`
    public static func transferCounterAccountName(fromPayee payee: String) -> String? {
        guard payee.hasPrefix(transferPayeePrefix) else { return nil }
        return String(payee.dropFirst(transferPayeePrefix.count)).trimmingCharacters(in: .whitespaces)
    }

    public struct SplitMarker: Sendable {
        public var index: Int
        public var total: Int
        public var remainingMemo: String
    }

    /// `Split (1/2) iPad & Accessories` → index 1, total 2, memo "iPad & Accessories"
    public static func splitMarker(fromMemo memo: String) -> SplitMarker? {
        guard memo.hasPrefix("Split (") else { return nil }
        guard let closing = memo.firstIndex(of: ")") else { return nil }
        let inner = memo[memo.index(memo.startIndex, offsetBy: 7)..<closing]
        let parts = inner.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let total = Int(parts[1]), total > 0 else { return nil }
        let remainder = memo[memo.index(after: closing)...].trimmingCharacters(in: .whitespaces)
        return SplitMarker(index: index, total: total, remainingMemo: remainder)
    }
}
