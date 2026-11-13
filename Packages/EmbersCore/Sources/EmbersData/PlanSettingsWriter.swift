import Foundation
import EmbersCore
import SwiftData

/// Changes to the plan as a whole.
///
/// The plan's currency is the unit of every stored amount — transactions, assignments, targets and
/// the converted side of each foreign entry are minor units in it — so it can only be chosen while
/// none of those exist. Relabelling a plan that holds money would make $12.34 read as ¥1234; converting
/// it would re-price years of history at one day's rate.
@MainActor
public enum PlanSettingsWriter {
    public enum Refusal: LocalizedError, Equatable {
        case unknownCurrency(String)
        case planHoldsFigures

        public var errorDescription: String? {
            switch self {
            case let .unknownCurrency(code):
                String(localized: "“\(code)” is not a currency.", bundle: .module)
            case .planHoldsFigures:
                String(
                    localized: "The plan already holds amounts recorded in its currency, so it can no longer change.",
                    bundle: .module
                )
            }
        }
    }

    /// Whether the plan holds nothing measured in its currency yet.
    ///
    /// Accounts and categories do not count: an account's own currency is separate, and an empty
    /// category holds no amount. Scheduled entries do — their amounts were typed in this currency.
    public static func mayChangeBaseCurrency(in context: ModelContext) throws -> Bool {
        guard try context.fetchCount(FetchDescriptor<LedgerTransaction>()) == 0,
              try context.fetchCount(FetchDescriptor<CategoryAssignment>()) == 0
        else { return false }
        let targeted = FetchDescriptor<BudgetCategoryModel>(
            predicate: #Predicate { $0.targetAmountMinor != nil }
        )
        return try context.fetchCount(targeted) == 0
    }

    /// Sets the plan's currency, refusing once anything has been recorded in it.
    public static func setBaseCurrency(_ code: String, in context: ModelContext) throws {
        let code = code.uppercased()
        guard CurrencyRegistry.isValidCode(code) else { throw Refusal.unknownCurrency(code) }
        let settings = try context.planSettings()
        guard settings.baseCurrencyCode != code else { return }
        guard try mayChangeBaseCurrency(in: context) else { throw Refusal.planHoldsFigures }
        settings.baseCurrencyCode = code
        try context.save()
    }
}
