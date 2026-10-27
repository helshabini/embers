import EmbersCore
import Foundation

extension AccountType {
    public var displayName: String {
        switch self {
        case .checking: String(localized: "Checking")
        case .savings: String(localized: "Savings")
        case .cash: String(localized: "Cash")
        case .creditCard: String(localized: "Credit Card")
        case .lineOfCredit: String(localized: "Line of Credit")
        case .otherAsset: String(localized: "Asset")
        case .otherLiability: String(localized: "Liability")
        case .investment: String(localized: "Investment")
        }
    }
}
