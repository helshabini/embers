import Foundation

/// Names the app itself writes into a plan, shown in the reader's language.
///
/// They are **stored in English** and translated only when shown. Several are found again by name —
/// the credit card group, the inflow bucket, the starting-balance payee — and a YNAB export spells
/// them in English whatever language its owner reads, so storing a translation would break the
/// matching and make an imported "True Expenses" a different group from a seeded one. Anything the
/// person names, or renames, is theirs and is shown exactly as typed.
public enum ProvidedName {
    /// The group's name in the reader's language, if it is one the app provides.
    public static func group(_ stored: String) -> String? {
        groups[stored.lowercased()]
    }

    public static func category(_ stored: String) -> String? {
        categories[stored.lowercased()]
    }

    public static func payee(_ stored: String) -> String? {
        payees[stored.lowercased()]
    }

    // Each a literal of its own, so the build can find it to translate.
    //
    // `let`, built once. As computed properties every `displayName` rebuilt the whole table — 31
    // catalog lookups for one category name — and searching the register asks for two names per
    // row, which made every keystroke over 10,000 transactions several hundred thousand lookups.
    // The language cannot change under a running app: it is chosen in iOS, which relaunches it.

    private static let groups: [String: String] = [
        "credit card payments": String(localized: "Credit Card Payments", bundle: .module),
        "hidden categories": String(localized: "Hidden Categories", bundle: .module),
        "inflow": String(localized: "Inflow", bundle: .module),
        "immediate obligations": String(localized: "Immediate Obligations", bundle: .module),
        "true expenses": String(localized: "True Expenses", bundle: .module),
        "debt payments": String(localized: "Debt Payments", bundle: .module),
        "quality of life goals": String(localized: "Quality of Life Goals", bundle: .module),
        "rainy day funds": String(localized: "Rainy Day Funds", bundle: .module),
        "just for fun": String(localized: "Just for Fun", bundle: .module),
    ]

    private static let categories: [String: String] = [
        "ready to assign": String(localized: "Ready to Assign", bundle: .module),
        "rent": String(localized: "Rent", bundle: .module),
        "electricity": String(localized: "Electricity", bundle: .module),
        "water": String(localized: "Water", bundle: .module),
        "internet": String(localized: "Internet", bundle: .module),
        "phone": String(localized: "Phone", bundle: .module),
        "groceries": String(localized: "Groceries", bundle: .module),
        "transportation": String(localized: "Transportation", bundle: .module),
        "interest & fees": String(localized: "Interest & Fees", bundle: .module),
        "auto maintenance": String(localized: "Auto Maintenance", bundle: .module),
        "home maintenance": String(localized: "Home Maintenance", bundle: .module),
        "medical": String(localized: "Medical", bundle: .module),
        "clothing": String(localized: "Clothing", bundle: .module),
        "gifts": String(localized: "Gifts", bundle: .module),
        "schooling": String(localized: "Schooling", bundle: .module),
        "subscriptions": String(localized: "Subscriptions", bundle: .module),
        "stuff i forgot to budget for": String(
            localized: "Stuff I Forgot to Budget For", bundle: .module
        ),
        "mortgage": String(localized: "Mortgage", bundle: .module),
        "auto loan": String(localized: "Auto Loan", bundle: .module),
        "personal loan": String(localized: "Personal Loan", bundle: .module),
        "vacation": String(localized: "Vacation", bundle: .module),
        "fitness": String(localized: "Fitness", bundle: .module),
        "home improvement": String(localized: "Home Improvement", bundle: .module),
        "education": String(localized: "Education", bundle: .module),
        "emergency fund": String(localized: "Emergency Fund", bundle: .module),
        "savings": String(localized: "Savings", bundle: .module),
        "investments": String(localized: "Investments", bundle: .module),
        "dining out": String(localized: "Dining Out", bundle: .module),
        "entertainment": String(localized: "Entertainment", bundle: .module),
        "hobbies": String(localized: "Hobbies", bundle: .module),
        "fun money": String(localized: "Fun Money", bundle: .module),
    ]

    private static let payees: [String: String] = [
        "starting balance": String(localized: "Starting Balance", bundle: .module),
        "reconciliation balance adjustment": String(
            localized: "Reconciliation Balance Adjustment", bundle: .module
        ),
    ]
}

/// Counts, worded with the plural rules of the reader's language — Arabic has six forms where
/// English has two, so "\(n) transaction\(n == 1 ? "" : "s")" is right in one language only.
public enum Counted {
    public static func accounts(_ count: Int) -> String {
        String(localized: "\(count) accounts", bundle: .module, locale: .display)
    }

    public static func transactions(_ count: Int) -> String {
        String(localized: "\(count) transactions", bundle: .module, locale: .display)
    }

    public static func categories(_ count: Int) -> String {
        String(localized: "\(count) categories", bundle: .module, locale: .display)
    }

    public static func months(_ count: Int) -> String {
        String(localized: "\(count) months", bundle: .module, locale: .display)
    }

    /// "3 transactions and 2 months", joined the way the language joins a list.
    public static func list(_ parts: [String]) -> String {
        ListFormatter.localizedString(byJoining: parts)
    }
}

extension CategoryGroup {
    /// What to show for this group: translated if the app provided it, as typed otherwise.
    public var displayName: String { ProvidedName.group(name) ?? name }
}

extension BudgetCategoryModel {
    /// A starter category the person has not renamed is still the app's words, so it follows the
    /// language; once renamed it is theirs.
    public var displayName: String { ProvidedName.category(name) ?? name }
}

extension Payee {
    public var displayName: String { ProvidedName.payee(name) ?? name }
}
