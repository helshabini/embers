import EmbersCore
import EmbersData
import Foundation

/// How a transaction is put into words, wherever it is listed: the phone's two-column row and the
/// Mac's table say the same things, and a rule changed in one place is changed in both.
///
/// Read only from a live row. Reading a deleted transaction is fatal, not a nil.
struct TransactionWording {
    let transaction: LedgerTransaction
    /// Stands for both sides of a transfer, in a list that holds them both. A register only ever
    /// holds one side, so there it stays false.
    var collapsesTransfer = false

    var title: String {
        // A collapsed transfer names where the money went; where it came from goes in the subtitle,
        // because two account names in one title truncate to "Atlas Checking (EGP) → …", losing the
        // half that says anything.
        if collapsesTransfer, let counter = transaction.transferCounterAccount?.name {
            return transaction.amountMinor < 0 ? String(localized: "Transfer to \(counter)") : String(localized: "Transfer from \(counter)")
        }
        if let payee = transaction.payee?.displayName, !payee.isEmpty { return payee }
        if let counter = transaction.transferCounterAccount?.name { return String(localized: "Transfer: \(counter)") }
        return String(localized: "(no payee)")
    }

    /// The category, or what stands in for one: a split's line count, or that it is a transfer.
    var categoryText: String? {
        if transaction.isSplitParent {
            return String(localized: "Split (\(transaction.splitLines?.count ?? 0))", locale: .display)
        }
        if let category = transaction.category?.displayName { return category }
        if transaction.isTransfer { return String(localized: "Transfer") }
        return nil
    }

    /// Money moved between two budget accounts is neither income nor spending, so it reads as a plain
    /// magnitude in a neutral colour. A transfer carrying a category has left the budget — a mortgage
    /// payment into a tracked apartment — and that is spending, so it keeps its sign and its red.
    var isPlainMove: Bool { collapsesTransfer && transaction.category == nil }

    /// A register spanning years needs the year whenever it is not this one, or an entry dated next
    /// August reads as though it already happened.
    var shortDate: String {
        let calendar = Calendar.gregorianUTC
        let sameYear = calendar.component(.year, from: transaction.date)
            == calendar.component(.year, from: .todayAsBudgetDay())
        return transaction.date.formatted(
            sameYear
                ? .dateTime.month(.abbreviated).day().locale(.display)
                : .dateTime.month(.abbreviated).day().year().locale(.display)
        )
    }

    /// What was actually typed, so a converted entry can be recognised months later.
    var conversionSummary: String? {
        guard let conversion = transaction.conversion else { return nil }
        let entered = Money(
            minorUnits: conversion.enteredAmount,
            currency: CurrencyRegistry.currency(forCode: conversion.enteredCurrencyCode)
        )
        var summary = entered.formatted()
        if conversion.appliedFee {
            summary += " + " + String(localized: "\(conversion.feePercent.formatted(.number.locale(.display)))% fee")
        }
        return summary
    }
}
