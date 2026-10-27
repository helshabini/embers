import Foundation

/// Turns a YNAB CSV export into a complete budget, inferring the things YNAB's export does not state.
///
/// The export omits three things this app needs, all recoverable from the data itself:
/// - **Account currency** — taken from a `(XXX)` suffix on the account name when it is a real ISO
///   4217 code. `Apartment (NW)` is a property, not a currency, so the suffix is validated first.
/// - **Which accounts are credit cards** — YNAB names each card's payment category exactly after the
///   account, so a payment category is an authoritative marker. Cards closed long ago have their
///   payment category parked in `Hidden Categories`, which also identifies them (and implies closed).
/// - **Which accounts are off-budget** — tracking accounts never carry categorised transactions.
public struct YNABImporter: Sendable {
    public let baseCurrency: Currency

    public init(baseCurrency: Currency = CurrencyRegistry.usd) {
        self.baseCurrency = baseCurrency
    }

    private static let creditNameKeywords = ["mastercard", "visa", "amex", "american express", "credit card"]
    private static let investmentNameKeywords = ["crypto", "ibkr", "thndr", "fidelity", "invest", "broker", "stock"]
    private static let creditCardPaymentsGroupName = "Credit Card Payments"
    private static let hiddenGroupName = "Hidden Categories"
    private static let inflowGroupName = "Inflow"
    private static let readyToAssignCategoryName = "Ready to Assign"
    private static let startingBalancePayee = "Starting Balance"

    public func makeBudget(planCSV: String, registerCSV: String) throws -> ImportedBudget {
        let parser = YNABExportParser(baseCurrency: baseCurrency)
        let planRows = try parser.parsePlan(planCSV)
        let registerRows = try parser.parseRegister(registerCSV)
        return build(planRows: planRows, registerRows: registerRows)
    }

    public func build(planRows: [YNABPlanRow], registerRows: [YNABRegisterRow]) -> ImportedBudget {
        var report = ImportReport()

        let accountNames = orderedUnique(registerRows.map(\.account))
        let creditCardNames = creditAccountNames(planRows: planRows, accountNames: accountNames)
        let closedCreditNames = closedCreditAccountNames(planRows: planRows, accountNames: accountNames)
        let categorizedCounts = categorizedTransactionCounts(registerRows)

        var accounts: [ImportedAccount] = []
        var accountIDsByName: [String: EntityID] = [:]
        for name in accountNames {
            let account = makeAccount(
                name: name,
                isCredit: creditCardNames.contains(name),
                isClosed: closedCreditNames.contains(name),
                categorizedCount: categorizedCounts[name] ?? 0
            )
            accounts.append(account)
            accountIDsByName[name] = account.id
        }

        let (groups, categories, groupIDsByName, categoryIDsByKey) = makeCategories(
            planRows: planRows,
            registerRows: registerRows,
            accountIDsByName: accountIDsByName,
            creditCardNames: creditCardNames
        )
        _ = groupIDsByName

        var payees: [ImportedPayee] = []
        var payeeIDsByName: [String: EntityID] = [:]
        for name in orderedUnique(registerRows.map(\.payee)) {
            guard !name.isEmpty,
                  YNABExportParser.transferCounterAccountName(fromPayee: name) == nil
            else { continue }
            let payee = ImportedPayee(id: UUID(), name: name)
            payees.append(payee)
            payeeIDsByName[name] = payee.id
        }

        let (transactions, transactionReport) = makeTransactions(
            registerRows: registerRows,
            accountIDsByName: accountIDsByName,
            payeeIDsByName: payeeIDsByName,
            categoryIDsByKey: categoryIDsByKey,
            report: &report
        )
        report = transactionReport

        var assignments: [ImportedAssignment] = []
        var expectations: [PlanExpectation] = []
        for row in planRows {
            let categoryID = categoryIDsByKey[Self.categoryKey(group: row.groupName, category: row.categoryName)]
            expectations.append(
                PlanExpectation(
                    month: row.month,
                    groupName: row.groupName,
                    categoryName: row.categoryName,
                    categoryID: categoryID,
                    assigned: row.assigned,
                    activity: row.activity,
                    available: row.available
                )
            )
            guard let categoryID, row.assigned != 0 else { continue }
            assignments.append(
                ImportedAssignment(categoryID: categoryID, month: row.month, amount: row.assigned)
            )
        }

        report.accountCount = accounts.count
        report.payeeCount = payees.count
        report.categoryGroupCount = groups.count
        report.categoryCount = categories.count
        report.assignmentCount = assignments.count
        report.earliestDate = registerRows.map(\.date).min()
        report.latestDate = registerRows.map(\.date).max()
        report.firstMonth = planRows.map(\.month).min()
        report.lastMonth = planRows.map(\.month).max()

        let unresolved = expectations.filter { $0.categoryID == nil }
        if !unresolved.isEmpty {
            report.warnings.append(
                "\(unresolved.count) plan rows reference a category that could not be matched."
            )
        }

        return ImportedBudget(
            baseCurrency: baseCurrency,
            accounts: accounts,
            payees: payees,
            categoryGroups: groups,
            categories: categories,
            transactions: transactions,
            assignments: assignments,
            expectations: expectations,
            report: report
        )
    }

    // MARK: - Accounts

    private func makeAccount(
        name: String,
        isCredit: Bool,
        isClosed: Bool,
        categorizedCount: Int
    ) -> ImportedAccount {
        let currencyCode = Self.currencyCode(fromAccountName: name) ?? baseCurrency.code
        let type: AccountType
        var note: String

        if isCredit {
            type = .creditCard
            note = String(localized: "Credit card: a payment category is named after this account.", bundle: .module)
        } else if categorizedCount == 0 {
            let lowercased = name.lowercased()
            type = Self.investmentNameKeywords.contains(where: lowercased.contains) ? .investment : .otherAsset
            note = String(localized: "Tracking account: no categorised transactions in the export.", bundle: .module)
        } else if name.lowercased().contains("cash") {
            type = .cash
            note = String(localized: "Cash account: the name says cash.", bundle: .module)
        } else if name.lowercased().contains("saving") || name.contains(" CD") {
            type = .savings
            note = String(localized: "Savings account: inferred from the name.", bundle: .module)
        } else {
            type = .checking
            note = String(localized: "Checking account: default for a budget account.", bundle: .module)
        }

        if currencyCode != baseCurrency.code {
            note += " " + String(localized: "Currency \(currencyCode) from the name suffix.", bundle: .module)
        }
        if isClosed {
            note += " " + String(localized: "Marked closed: its payment category is hidden.", bundle: .module)
        }

        return ImportedAccount(
            id: UUID(),
            name: name,
            type: type,
            currencyCode: currencyCode,
            onBudget: type.belongsOnBudgetByDefault,
            closed: isClosed,
            inferenceNote: note
        )
    }

    /// `Atlas Checking (EGP)` → `EGP`; `Apartment (NW)` → nil, because NW is not a currency.
    public static func currencyCode(fromAccountName name: String) -> String? {
        guard name.hasSuffix(")"), let openIndex = name.lastIndex(of: "(") else { return nil }
        let inner = name[name.index(after: openIndex)..<name.index(before: name.endIndex)]
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard inner.count == 3, CurrencyRegistry.isValidCode(inner) else { return nil }
        return inner
    }

    private func creditAccountNames(planRows: [YNABPlanRow], accountNames: [String]) -> Set<String> {
        let accountNameSet = Set(accountNames)
        var names = Set<String>()
        for row in planRows where row.groupName == Self.creditCardPaymentsGroupName {
            if accountNameSet.contains(row.categoryName) { names.insert(row.categoryName) }
        }
        for row in planRows where row.groupName == Self.hiddenGroupName {
            guard accountNameSet.contains(row.categoryName) else { continue }
            let lowercased = row.categoryName.lowercased()
            if Self.creditNameKeywords.contains(where: lowercased.contains) {
                names.insert(row.categoryName)
            }
        }
        return names
    }

    private func closedCreditAccountNames(planRows: [YNABPlanRow], accountNames: [String]) -> Set<String> {
        let accountNameSet = Set(accountNames)
        var names = Set<String>()
        for row in planRows where row.groupName == Self.hiddenGroupName {
            guard accountNameSet.contains(row.categoryName) else { continue }
            let lowercased = row.categoryName.lowercased()
            if Self.creditNameKeywords.contains(where: lowercased.contains) {
                names.insert(row.categoryName)
            }
        }
        return names
    }

    private func categorizedTransactionCounts(_ rows: [YNABRegisterRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in rows where !row.categoryName.isEmpty {
            counts[row.account, default: 0] += 1
        }
        return counts
    }

    // MARK: - Categories

    static func categoryKey(group: String, category: String) -> String {
        "\(group)\u{1F}\(category)"
    }

    private func makeCategories(
        planRows: [YNABPlanRow],
        registerRows: [YNABRegisterRow],
        accountIDsByName: [String: EntityID],
        creditCardNames: Set<String>
    ) -> ([ImportedCategoryGroup], [ImportedCategory], [String: EntityID], [String: EntityID]) {
        var groups: [ImportedCategoryGroup] = []
        var groupIDsByName: [String: EntityID] = [:]
        var categories: [ImportedCategory] = []
        var categoryIDsByKey: [String: EntityID] = [:]

        func groupID(named name: String) -> EntityID {
            if let existing = groupIDsByName[name] { return existing }
            let group = ImportedCategoryGroup(
                id: UUID(),
                name: name,
                order: groups.count,
                hidden: name == Self.hiddenGroupName
            )
            groups.append(group)
            groupIDsByName[name] = group.id
            return group.id
        }

        func addCategory(group: String, name: String) {
            let key = Self.categoryKey(group: group, category: name)
            guard categoryIDsByKey[key] == nil else { return }
            let resolvedGroupID = groupID(named: group)

            let kind: CategoryKind
            var linkedAccountID: EntityID?
            if group == Self.inflowGroupName || name == Self.readyToAssignCategoryName {
                kind = .inflowReadyToAssign
            } else if creditCardNames.contains(name), let accountID = accountIDsByName[name] {
                kind = .creditCardPayment
                linkedAccountID = accountID
            } else {
                kind = .normal
            }

            let category = ImportedCategory(
                id: UUID(),
                name: name,
                groupID: resolvedGroupID,
                groupName: group,
                kind: kind,
                linkedAccountID: linkedAccountID,
                hidden: group == Self.hiddenGroupName,
                order: categories.count
            )
            categories.append(category)
            categoryIDsByKey[key] = category.id
        }

        // Plan.csv carries the authoritative group order and includes categories with no activity.
        for row in planRows {
            addCategory(group: row.groupName, name: row.categoryName)
        }
        // The register contributes internal categories Plan.csv omits, such as Inflow: Ready to Assign.
        for row in registerRows where !row.categoryName.isEmpty {
            addCategory(group: row.groupName, name: row.categoryName)
        }

        return (groups, categories, groupIDsByName, categoryIDsByKey)
    }

    // MARK: - Transactions

    /// Split lines share only their account, date, and line count — YNAB lets each line carry its
    /// own payee, so the payee cannot be part of the key.
    private struct SplitGroupKey: Hashable {
        var account: String
        var date: Date
        var total: Int
    }

    private struct TransferKey: Hashable {
        var accountA: String
        var accountB: String
        var date: Date
        var magnitude: MinorUnits

        init(_ first: String, _ second: String, date: Date, magnitude: MinorUnits) {
            let sorted = [first, second].sorted()
            self.accountA = sorted[0]
            self.accountB = sorted[1]
            self.date = date
            self.magnitude = magnitude
        }
    }

    private func makeTransactions(
        registerRows: [YNABRegisterRow],
        accountIDsByName: [String: EntityID],
        payeeIDsByName: [String: EntityID],
        categoryIDsByKey: [String: EntityID],
        report: inout ImportReport
    ) -> ([ImportedTransaction], ImportReport) {
        var transactions: [ImportedTransaction] = []
        var openSplits: [SplitGroupKey: [(row: YNABRegisterRow, index: Int)]] = [:]
        var splitOrder: [SplitGroupKey] = []
        var localReport = report

        func categoryID(for row: YNABRegisterRow) -> EntityID? {
            guard !row.categoryName.isEmpty else { return nil }
            return categoryIDsByKey[Self.categoryKey(group: row.groupName, category: row.categoryName)]
        }

        func transferAccountID(for row: YNABRegisterRow) -> EntityID? {
            YNABExportParser.transferCounterAccountName(fromPayee: row.payee)
                .flatMap { accountIDsByName[$0] }
        }

        func emitPlain(_ row: YNABRegisterRow, memoOverride: String? = nil) {
            guard let accountID = accountIDsByName[row.account] else { return }
            transactions.append(
                ImportedTransaction(
                    id: UUID(),
                    accountID: accountID,
                    date: row.date,
                    payeeID: payeeIDsByName[row.payee],
                    payeeName: row.payee,
                    categoryID: categoryID(for: row),
                    memo: memoOverride ?? row.memo,
                    amount: row.amount,
                    cleared: row.cleared,
                    flagName: row.flag.isEmpty ? nil : row.flag,
                    transferCounterAccountID: transferAccountID(for: row),
                    splits: []
                )
            )
        }

        func emitSplit(_ entries: [(row: YNABRegisterRow, index: Int)], key: SplitGroupKey) {
            let rows = entries.sorted { $0.index < $1.index }.map(\.row)
            guard let first = rows.first, let accountID = accountIDsByName[first.account] else { return }

            // The counter side of a split's transfer line inherits the "Split (i/n)" memo but stands
            // alone in its own account. A single line is not a split.
            if rows.count == 1 {
                emitPlain(first, memoOverride: YNABExportParser.splitMarker(fromMemo: first.memo)?.remainingMemo)
                return
            }

            var lines = rows.map { row in
                ImportedSplitLine(
                    id: UUID(),
                    categoryID: categoryID(for: row),
                    amount: row.amount,
                    memo: YNABExportParser.splitMarker(fromMemo: row.memo)?.remainingMemo ?? "",
                    payeeName: row.payee,
                    payeeID: payeeIDsByName[row.payee],
                    transferCounterAccountID: transferAccountID(for: row)
                )
            }
            // Siblings repeat the parent memo; when they all match, it belongs to the parent instead.
            let lineMemos = Set(lines.map(\.memo))
            let sharedMemo = lineMemos.count == 1 ? (lineMemos.first ?? "") : ""
            if !sharedMemo.isEmpty {
                for index in lines.indices { lines[index].memo = "" }
            }

            // Lines may disagree on payee; a real payee describes the transaction better than a
            // transfer marker does. Judged by the payee's form, since a transfer can name an account
            // that has no rows of its own.
            let parentPayee = rows.first {
                YNABExportParser.transferCounterAccountName(fromPayee: $0.payee) == nil
            }?.payee ?? first.payee

            transactions.append(
                ImportedTransaction(
                    id: UUID(),
                    accountID: accountID,
                    date: first.date,
                    payeeID: payeeIDsByName[parentPayee],
                    payeeName: parentPayee,
                    categoryID: nil,
                    memo: sharedMemo,
                    amount: rows.reduce(0) { $0 + $1.amount },
                    cleared: rows.contains { $0.cleared == .uncleared } ? .uncleared : first.cleared,
                    flagName: rows.first { !$0.flag.isEmpty }?.flag,
                    transferCounterAccountID: nil,
                    splits: lines
                )
            )
            localReport.splitTransactionCount += 1
            localReport.splitLineCount += rows.count
            if rows.count != key.total {
                localReport.warnings.append(
                    "Split on \(first.account) dated \(Self.dateText(first.date)) has \(rows.count) of \(key.total) lines."
                )
            }
        }

        for row in registerRows {
            guard accountIDsByName[row.account] != nil else {
                localReport.skippedRowCount += 1
                continue
            }

            if let marker = YNABExportParser.splitMarker(fromMemo: row.memo) {
                let key = SplitGroupKey(account: row.account, date: row.date, total: marker.total)
                // Two separate splits can share an account, date, and line count. A repeated line
                // number means the previous group ended.
                if let open = openSplits[key], open.contains(where: { $0.index == marker.index }) {
                    openSplits.removeValue(forKey: key)
                    splitOrder.removeAll { $0 == key }
                    emitSplit(open, key: key)
                }
                if openSplits[key] == nil { splitOrder.append(key) }
                openSplits[key, default: []].append((row, marker.index))
                if openSplits[key]?.count == marker.total, let complete = openSplits.removeValue(forKey: key) {
                    splitOrder.removeAll { $0 == key }
                    emitSplit(complete, key: key)
                }
                continue
            }

            emitPlain(row)
        }

        for key in splitOrder {
            if let rows = openSplits[key] { emitSplit(rows, key: key) }
        }

        localReport.transactionCount = transactions.count
        // Tie the two sides of each transfer together. Counting them was not enough: written as
        // unrelated rows, deleting one left the other behind and editing one did not move the other.
        localReport.transferPairCount = pairTransfers(&transactions)
        let unmatched = transactions.reduce(0) { total, transaction in
            guard !transaction.isSplit else {
                return total + transaction.splits.filter {
                    $0.transferCounterAccountID != nil && $0.transferPairIdentifier == nil
                }.count
            }
            let loose = transaction.transferCounterAccountID != nil
                && transaction.transferPairIdentifier == nil
            return total + (loose ? 1 : 0)
        }
        localReport.unmatchedTransferCount = unmatched
        if unmatched > 0 {
            localReport.warnings.append(
                "\(unmatched) transfer rows have no matching row in the counter account."
            )
        }

        return (transactions, localReport)
    }

    /// One end of a transfer: a plain transaction, or a single line of a split. A split's parent is
    /// not a side — its amount is the whole split, while only one line crosses accounts.
    private struct Side {
        let transaction: Int
        let line: Int?
        let account: EntityID
        let counter: EntityID
        let amount: MinorUnits
        let date: Date
    }

    /// Gives both rows of each transfer a shared identifier.
    ///
    /// Both rows are kept — each is a real entry in its own account's ledger — but they now know
    /// about one another. A row whose counterpart is missing from the export keeps no identifier and
    /// stays a one-sided entry rather than being paired with something it does not belong to.
    ///
    /// - Returns: how many pairs were matched.
    private func pairTransfers(_ transactions: inout [ImportedTransaction]) -> Int {
        /// What both sides of one transfer agree on.
        struct Key: Hashable {
            let accounts: [EntityID]
            let date: Date
            let magnitude: MinorUnits
        }

        var sides: [Side] = []
        for index in transactions.indices {
            let transaction = transactions[index]
            if transaction.isSplit {
                for line in transaction.splits.indices {
                    guard let counter = transaction.splits[line].transferCounterAccountID else { continue }
                    sides.append(Side(
                        transaction: index, line: line, account: transaction.accountID,
                        counter: counter, amount: transaction.splits[line].amount,
                        date: transaction.date
                    ))
                }
            } else if let counter = transaction.transferCounterAccountID {
                sides.append(Side(
                    transaction: index, line: nil, account: transaction.accountID,
                    counter: counter, amount: transaction.amount, date: transaction.date
                ))
            }
        }

        var waiting: [Key: [Int]] = [:]
        var paired = 0

        for position in sides.indices {
            let side = sides[position]
            let key = Key(
                accounts: [side.account, side.counter].sorted { $0.uuidString < $1.uuidString },
                date: side.date,
                magnitude: abs(side.amount)
            )

            if let match = waiting[key]?.firstIndex(where: {
                sides[$0].amount == -side.amount && sides[$0].account == side.counter
            }) {
                let other = sides[waiting[key]!.remove(at: match)]
                let identifier = UUID()
                assign(identifier, to: side, in: &transactions)
                assign(identifier, to: other, in: &transactions)
                paired += 1
            } else {
                waiting[key, default: []].append(position)
            }
        }
        return paired
    }

    /// Writes a pair identifier onto whichever end it belongs to.
    private func assign(
        _ identifier: UUID,
        to side: Side,
        in transactions: inout [ImportedTransaction]
    ) {
        if let line = side.line {
            transactions[side.transaction].splits[line].transferPairIdentifier = identifier
        } else {
            transactions[side.transaction].transferPairIdentifier = identifier
        }
    }


    private static func dateText(_ date: Date) -> String {
        let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values where !value.isEmpty {
        if seen.insert(value).inserted { result.append(value) }
    }
    return result
}
