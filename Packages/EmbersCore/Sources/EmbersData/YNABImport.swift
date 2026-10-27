import Foundation
import EmbersCore
import SwiftData

public struct ImportOutcome: Sendable {
    public var report: ImportReport
    public var reconciliation: BudgetReconciler.Outcome?
}

public enum ImportError: Error, CustomStringConvertible {
    case planCSVMissing
    case registerCSVMissing
    case planNotEmpty(accounts: Int, transactions: Int)

    public var description: String {
        switch self {
        case .planCSVMissing:
            String(localized: "The export is missing its Plan CSV.", bundle: .module)
        case .registerCSVMissing:
            String(localized: "The export is missing its Register CSV.", bundle: .module)
        case let .planNotEmpty(accounts, transactions):
            String(
                localized: "This budget already holds \(Counted.list([Counted.accounts(accounts), Counted.transactions(transactions)])).",
                bundle: .module
            )
        }
    }
}

/// Drives a YNAB import: read, preview, then commit.
///
/// Reading is kept separate from committing so the dry-run screen can show exactly what will land —
/// counts, inferred account types and currencies, warnings — before anything touches the store.
public enum YNABImport {
    public static func read(
        archiveAt url: URL,
        baseCurrency: Currency = CurrencyRegistry.usd
    ) throws -> ImportedBudget {
        try read(archiveData: try Data(contentsOf: url), baseCurrency: baseCurrency)
    }

    /// Reads an export already in memory, so a security-scoped file can be closed before parsing.
    public static func read(
        archiveData: Data,
        baseCurrency: Currency = CurrencyRegistry.usd
    ) throws -> ImportedBudget {
        let archive = try ZipArchive(data: archiveData)
        guard archive.entry(matchingSuffix: "Plan.csv") != nil else { throw ImportError.planCSVMissing }
        guard archive.entry(matchingSuffix: "Register.csv") != nil else { throw ImportError.registerCSVMissing }
        var budget = try YNABImporter(baseCurrency: baseCurrency).makeBudget(
            planCSV: try archive.text(matchingSuffix: "Plan.csv"),
            registerCSV: try archive.text(matchingSuffix: "Register.csv")
        )
        budget.report.sourceExportedAt = archive.writtenAt
        return budget
    }

    public static func read(
        planCSV: String,
        registerCSV: String,
        baseCurrency: Currency = CurrencyRegistry.usd
    ) throws -> ImportedBudget {
        try YNABImporter(baseCurrency: baseCurrency).makeBudget(
            planCSV: planCSV,
            registerCSV: registerCSV
        )
    }

    /// Writes an imported budget into the store.
    ///
    /// - Parameters:
    ///   - reconcileClosingBalances: Records adjusting assignments so the closing month opens on the
    ///     balances the export reported. Some of YNAB's internal credit-card movements cannot be
    ///     rederived from the register, and this keeps the starting point honest without editing
    ///     transactions.
    ///   - replaceExisting: Clears the current plan first. The caller is expected to have taken a
    ///     backup; an import that silently merged into a live budget would be unrecoverable.
    @discardableResult
    public static func commit(
        _ budget: ImportedBudget,
        into context: ModelContext,
        reconcileClosingBalances: Bool = true,
        replaceExisting: Bool = false
    ) throws -> ImportOutcome {
        let existingAccounts = try context.fetchCount(FetchDescriptor<Account>())
        let existingTransactions = try context.fetchCount(FetchDescriptor<LedgerTransaction>())
        if existingAccounts > 0 || existingTransactions > 0, !replaceExisting {
            throw ImportError.planNotEmpty(
                accounts: existingAccounts,
                transactions: existingTransactions
            )
        }
        // Cleared even when there is nothing to replace: a new plan holds its starter groups, the
        // import brings its own under the same names, and keeping both would make two of each.
        try ImportWriter.deleteAllPlanData(in: context)

        var toWrite = budget
        var reconciliation: BudgetReconciler.Outcome?
        if reconcileClosingBalances, let closingMonth = budget.report.lastMonth {
            let (adjusted, outcome) = BudgetReconciler().reconciled(
                budget,
                at: closingMonth,
                asOf: Self.reconciliationCutoff(
                    exportedAt: budget.report.sourceExportedAt,
                    closingMonth: closingMonth
                )
            )
            toWrite = adjusted
            reconciliation = outcome
        }

        try ImportWriter.write(toWrite, into: context)
        return ImportOutcome(report: toWrite.report, reconciliation: reconciliation)
    }

    /// The cutoff must match the one YNAB used, or the comparison is against a different question.
    ///
    /// An export's register runs past its closing month whenever scheduled transactions exist, and
    /// YNAB leaves those out of activity. Using the export's own timestamp keeps the two in step;
    /// without one, the end of the closing month is the closest safe guess.
    public static func reconciliationCutoff(exportedAt: Date?, closingMonth: YearMonth) -> Date {
        let endOfClosingMonth = closingMonth.next.firstDay.addingTimeInterval(-1)
        guard let exportedAt else { return endOfClosingMonth }
        return min(.endOfBudgetDay(containing: exportedAt), endOfClosingMonth)
    }
}
