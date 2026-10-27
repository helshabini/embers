import Foundation
import EmbersCore

/// Imports a real YNAB export, recomputes the budget with `BudgetEngine`, and diffs the result
/// against the Assigned / Activity / Available values YNAB itself exported.
///
/// This is the strongest correctness check available for the envelope math, credit-card handling,
/// split flattening, and transfer pairing: the expected output is ground truth from YNAB, not from
/// our own assumptions.
///
/// Usage: swift run validate-import <export.zip | directory> [--limit N] [--currency USD]

struct ExportFiles {
    var planCSV: String
    var registerCSV: String
    var planPath: String
    var registerPath: String
}

enum ValidationError: Error, CustomStringConvertible {
    case usage
    case notFound(String)
    case unzipFailed(Int32)
    case csvNotFound(directory: String)

    var description: String {
        switch self {
        case .usage:
            "Usage: validate-import <export.zip | directory> [--limit N] [--currency USD]"
        case let .notFound(path):
            "No such file or directory: \(path)"
        case let .unzipFailed(status):
            "unzip exited with status \(status)"
        case let .csvNotFound(directory):
            "Could not find both a Plan CSV and a Register CSV in \(directory)"
        }
    }
}

func loadExport(at path: String) throws -> ExportFiles {
    let fileManager = FileManager.default
    let expanded = (path as NSString).expandingTildeInPath
    guard fileManager.fileExists(atPath: expanded) else { throw ValidationError.notFound(expanded) }

    var searchDirectory = expanded
    var isDirectory: ObjCBool = false
    fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory)

    if !isDirectory.boolValue {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("embers-validate-\(UUID().uuidString)")
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", expanded, "-d", temporary.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ValidationError.unzipFailed(process.terminationStatus) }
        searchDirectory = temporary.path
    }

    let names = try fileManager.contentsOfDirectory(atPath: searchDirectory)
    guard let planName = names.first(where: { $0.hasSuffix("Plan.csv") }),
          let registerName = names.first(where: { $0.hasSuffix("Register.csv") })
    else { throw ValidationError.csvNotFound(directory: searchDirectory) }

    let planPath = (searchDirectory as NSString).appendingPathComponent(planName)
    let registerPath = (searchDirectory as NSString).appendingPathComponent(registerName)
    return ExportFiles(
        planCSV: try String(contentsOfFile: planPath, encoding: .utf8),
        registerCSV: try String(contentsOfFile: registerPath, encoding: .utf8),
        planPath: planPath,
        registerPath: registerPath
    )
}

struct Discrepancy {
    var month: YearMonth
    var group: String
    var category: String
    var field: String
    var expected: MinorUnits
    var actual: MinorUnits

    var delta: MinorUnits { actual - expected }
}

func formatted(_ minorUnits: MinorUnits, currency: Currency) -> String {
    Money(minorUnits: minorUnits, currency: currency).formatted(showCurrencySymbol: false)
}

// MARK: - Entry point

let arguments = Array(CommandLine.arguments.dropFirst())
guard let inputPath = arguments.first(where: { !$0.hasPrefix("--") }) else {
    FileHandle.standardError.write(Data((ValidationError.usage.description + "\n").utf8))
    exit(2)
}

var displayLimit = 25
if let limitIndex = arguments.firstIndex(of: "--limit"), limitIndex + 1 < arguments.count {
    displayLimit = Int(arguments[limitIndex + 1]) ?? displayLimit
}
var currencyCode = "USD"
if let currencyIndex = arguments.firstIndex(of: "--currency"), currencyIndex + 1 < arguments.count {
    currencyCode = arguments[currencyIndex + 1].uppercased()
}
let baseCurrency = CurrencyRegistry.currency(forCode: currencyCode)

/// YNAB excludes transactions dated after the export from category activity, so the diff has to use
/// the same cutoff. The export filename carries it: "… as of 2026-09-29 19-50.zip".
func endOfDay(_ text: String) -> Date? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    return Calendar.gregorianUTC.date(
        from: DateComponents(year: year, month: month, day: day, hour: 23, minute: 59, second: 59)
    )
}

func asOfDateFromFilename(_ path: String) -> Date? {
    guard let marker = path.range(of: "as of ") else { return nil }
    let remainder = path[marker.upperBound...]
    guard remainder.count >= 10 else { return nil }
    return endOfDay(String(remainder.prefix(10)))
}

var asOf: Date?
if let index = arguments.firstIndex(of: "--as-of"), index + 1 < arguments.count {
    asOf = endOfDay(arguments[index + 1])
} else {
    asOf = asOfDateFromFilename(inputPath)
}

do {
    let files = try loadExport(at: inputPath)
    print("Plan:     \((files.planPath as NSString).lastPathComponent)")
    print("Register: \((files.registerPath as NSString).lastPathComponent)")
    print("Base currency: \(baseCurrency.code)")
    if let asOf {
        let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: asOf)
        print(String(format: "Activity as of: %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
    } else {
        print("Activity as of: all dates (no cutoff)")
    }
    print("")

    let clock = Date()
    let importer = YNABImporter(baseCurrency: baseCurrency)
    var budget = try importer.makeBudget(planCSV: files.planCSV, registerCSV: files.registerCSV)

    let shouldReconcile = arguments.contains("--reconcile")
    if shouldReconcile, let closingMonth = budget.report.lastMonth {
        let (adjusted, outcome) = BudgetReconciler().reconciled(budget, at: closingMonth, asOf: asOf)
        budget = adjusted
        print("== Reconciliation (\(closingMonth)) ==")
        if outcome.isClean {
            print("nothing to adjust\n")
        } else {
            for adjustment in outcome.adjustments {
                print(
                    "\("\(adjustment.groupName): \(adjustment.categoryName)".padding(toLength: 46, withPad: " ", startingAt: 0))"
                        + "reported \(formatted(adjustment.reportedAvailable, currency: baseCurrency).leftPadded(to: 12))"
                        + "  computed \(formatted(adjustment.computedAvailable, currency: baseCurrency).leftPadded(to: 12))"
                        + "  adjust \(formatted(adjustment.amount, currency: baseCurrency).leftPadded(to: 12))"
                )
            }
            print("total adjustment: \(formatted(outcome.totalAmount, currency: baseCurrency))\n")
        }
    }

    let input = budget.budgetInput()
    let result = BudgetEngine().compute(input, asOf: asOf, through: budget.report.lastMonth)
    let elapsed = Date().timeIntervalSince(clock)

    let report = budget.report
    print("== Import ==")
    print("accounts              \(report.accountCount)")
    print("payees                \(report.payeeCount)")
    print("category groups       \(report.categoryGroupCount)")
    print("categories            \(report.categoryCount)")
    print("transactions          \(report.transactionCount)")
    print("  of which splits     \(report.splitTransactionCount) (\(report.splitLineCount) lines)")
    print("transfer pairs        \(report.transferPairCount) (unmatched rows: \(report.unmatchedTransferCount))")
    print("assignments           \(report.assignmentCount)")
    print("engine entries        \(input.entries.count)")
    print("skipped rows          \(report.skippedRowCount)")
    if let first = report.firstMonth, let last = report.lastMonth {
        print("plan months           \(first) … \(last)")
    }
    print(String(format: "elapsed               %.2fs", elapsed))

    if !report.warnings.isEmpty {
        print("\n== Warnings ==")
        for warning in report.warnings.prefix(20) { print("- \(warning)") }
        if report.warnings.count > 20 { print("- … \(report.warnings.count - 20) more") }
    }

    print("\n== Accounts (inferred) ==")
    let onBudget = budget.accounts.filter(\.onBudget)
    let tracking = budget.accounts.filter { !$0.onBudget }
    for account in onBudget + tracking {
        let balance = result.accountBalances[account.id] ?? 0
        let flags = [
            account.onBudget ? "budget" : "tracking",
            account.currencyCode,
            account.closed ? "closed" : nil,
        ].compactMap { $0 }.joined(separator: ", ")
        print(
            "\(account.name.padding(toLength: 28, withPad: " ", startingAt: 0))"
                + "\(account.type.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0))"
                + "\(formatted(balance, currency: baseCurrency).leftPadded(to: 14))  [\(flags)]"
        )
    }
    print("net worth: \(formatted(result.netWorth, currency: baseCurrency))")

    // MARK: Diff against YNAB's own Plan.csv

    var discrepancies: [Discrepancy] = []
    var comparedCells = 0
    var assignedMismatches = 0
    var activityMismatches = 0
    var availableMismatches = 0

    for expectation in budget.expectations {
        guard let categoryID = expectation.categoryID else { continue }
        comparedCells += 1
        let state = result.state(of: categoryID, in: expectation.month)

        func check(_ field: String, expected: MinorUnits, actual: MinorUnits) {
            guard expected != actual else { return }
            discrepancies.append(
                Discrepancy(
                    month: expectation.month,
                    group: expectation.groupName,
                    category: expectation.categoryName,
                    field: field,
                    expected: expected,
                    actual: actual
                )
            )
        }

        if state.assigned != expectation.assigned { assignedMismatches += 1 }
        if state.activity != expectation.activity { activityMismatches += 1 }
        if state.available != expectation.available { availableMismatches += 1 }

        check("assigned", expected: expectation.assigned, actual: state.assigned)
        check("activity", expected: expectation.activity, actual: state.activity)
        check("available", expected: expectation.available, actual: state.available)
    }

    print("\n== Diff vs YNAB's Plan.csv ==")
    print("cells compared        \(comparedCells)")
    func line(_ label: String, _ mismatches: Int) {
        let matched = comparedCells - mismatches
        let percent = comparedCells == 0 ? 100.0 : Double(matched) / Double(comparedCells) * 100
        print(String(format: "%@ %6d mismatched  (%.3f%% match)", label.padding(toLength: 20, withPad: " ", startingAt: 0), mismatches, percent))
    }
    line("assigned", assignedMismatches)
    line("activity", activityMismatches)
    line("available", availableMismatches)

    // What the app would actually open with matters more than seven years of migrated history.
    if let closingMonth = budget.report.lastMonth {
        let closing = budget.expectations.filter { $0.month == closingMonth }
        var closingMismatches: [(PlanExpectation, CategoryMonthState, [String])] = []
        for expectation in closing {
            guard let categoryID = expectation.categoryID else { continue }
            let state = result.state(of: categoryID, in: closingMonth)
            var fields: [String] = []
            if state.assigned != expectation.assigned { fields.append("assigned") }
            if state.activity != expectation.activity { fields.append("activity") }
            if state.available != expectation.available { fields.append("available") }
            if !fields.isEmpty { closingMismatches.append((expectation, state, fields)) }
        }
        let availableMisses = closingMismatches.filter { $0.2.contains("available") }.count
        print("\nclosing month \(closingMonth): \(availableMisses) of \(closing.count) categories differ on available")
        for (expectation, state, fields) in closingMismatches {
            print(
                "  \("\(expectation.groupName): \(expectation.categoryName)".padding(toLength: 46, withPad: " ", startingAt: 0))"
                    + "YNAB available \(formatted(expectation.available, currency: baseCurrency).leftPadded(to: 12))"
                    + "  ours \(formatted(state.available, currency: baseCurrency).leftPadded(to: 12))"
                    + "  differs on: \(fields.joined(separator: ", "))"
            )
        }
        if let monthState = result.months[closingMonth] {
            print("  ready to assign: \(formatted(monthState.readyToAssign, currency: baseCurrency))")
        }
    }

    if !discrepancies.isEmpty {
        print("\n== Largest discrepancies ==")
        let sorted = discrepancies.sorted { abs($0.delta) > abs($1.delta) }
        for discrepancy in sorted.prefix(displayLimit) {
            print(
                "\(discrepancy.month)  \(discrepancy.field.padding(toLength: 10, withPad: " ", startingAt: 0))"
                    + "\("\(discrepancy.group): \(discrepancy.category)".padding(toLength: 46, withPad: " ", startingAt: 0))"
                    + "expected \(formatted(discrepancy.expected, currency: baseCurrency).leftPadded(to: 12))"
                    + "  actual \(formatted(discrepancy.actual, currency: baseCurrency).leftPadded(to: 12))"
                    + "  delta \(formatted(discrepancy.delta, currency: baseCurrency).leftPadded(to: 12))"
            )
        }
        if sorted.count > displayLimit { print("… \(sorted.count - displayLimit) more") }

        var byField: [String: Int] = [:]
        for discrepancy in discrepancies { byField[discrepancy.field, default: 0] += 1 }
        print("\nby field: " + byField.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        var byCategory: [String: Int] = [:]
        for discrepancy in discrepancies {
            byCategory["\(discrepancy.group): \(discrepancy.category)", default: 0] += 1
        }
        print("\n== Categories with the most mismatched cells ==")
        for (name, count) in byCategory.sorted(by: { $0.value > $1.value }).prefix(15) {
            print("\(count.description.leftPadded(to: 5))  \(name)")
        }
    }

    exit(discrepancies.isEmpty ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(2)
}

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
