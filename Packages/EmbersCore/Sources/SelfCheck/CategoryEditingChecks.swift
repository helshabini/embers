import Foundation
import EmbersCore
import EmbersData
import SwiftData

@MainActor
func categoryEditingChecks(_ check: Checker) {
    let march = Date.budgetDay(year: 2026, month: 3, day: 12)

    @MainActor func plan() throws -> (ModelContext, CategoryGroup) {
        let context = ModelContext(try EmbersStore.inMemoryContainer())
        let group = try CategoryWriter.addGroup(named: "Annual Bills", in: context)
        return (context, group)
    }

    check.suite("Editing the plan") {
        check.test("adds groups and categories, and keeps names apart") {
            let (context, group) = try plan()
            try CategoryWriter.add("Car Insurance", to: group, in: context)
            check.expect(group.categories?.count, 1)

            check.expectThrows("a second category of the same name") {
                try CategoryWriter.add("car insurance", to: group, in: context)
            }
            check.expectThrows("a nameless category") {
                try CategoryWriter.add("   ", to: group, in: context)
            }
            check.expectThrows("a second group of the same name") {
                try CategoryWriter.addGroup(named: "ANNUAL BILLS", in: context)
            }
        }

        check.test("renames, and trims what was typed") {
            let (context, group) = try plan()
            let category = try CategoryWriter.add("Car Insurence", to: group, in: context)
            try CategoryWriter.rename(category, to: "  Car Insurance  ", in: context)
            check.expect(category.name, "Car Insurance")

            try CategoryWriter.rename(group, to: "Annual Bills ", in: context)
            check.expect(group.name, "Annual Bills", "renaming to itself is not a clash")
        }

        check.test("an unused category can be deleted outright") {
            let (context, group) = try plan()
            let category = try CategoryWriter.add("Mistake", to: group, in: context)
            check.expectNil(try CategoryWriter.deletionRefusal(for: category, in: context))
            try CategoryWriter.delete(category, in: context)
            check.expect(try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()), 0)
        }

        check.test("one with transactions can only be hidden") {
            let (context, group) = try plan()
            let category = try CategoryWriter.add("Groceries", to: group, in: context)
            let account = Account(name: "Checking", type: .checking)
            context.insert(account)
            context.insert(
                LedgerTransaction(date: march, amountMinor: -8_000, account: account, category: category)
            )
            try context.save()

            check.expect(
                try CategoryWriter.deletionRefusal(for: category, in: context),
                .hasHistory(transactions: 1, assignments: 0)
            )
            check.expectThrows("deleting a category money has passed through") {
                try CategoryWriter.delete(category, in: context)
            }

            try CategoryWriter.setHidden(true, on: category, in: context)
            check.expectTrue(category.hidden)
            check.expect(
                try context.fetchCount(FetchDescriptor<LedgerTransaction>()), 1,
                "hiding changes no figure"
            )
        }

        check.test("one with money assigned can only be hidden too") {
            let (context, group) = try plan()
            let category = try CategoryWriter.add("Holiday", to: group, in: context)
            context.insert(
                CategoryAssignment(
                    month: YearMonth(year: 2026, month: 3), amountMinor: 50_000, category: category
                )
            )
            try context.save()
            check.expect(
                try CategoryWriter.deletionRefusal(for: category, in: context),
                .hasHistory(transactions: 0, assignments: 1),
                "deleting it would take back money that was budgeted in a month already closed"
            )
        }

        check.test("hiding a group takes its categories with it") {
            let (context, group) = try plan()
            let one = try CategoryWriter.add("A", to: group, in: context)
            let two = try CategoryWriter.add("B", to: group, in: context)
            try CategoryWriter.setHidden(true, on: group, in: context)
            check.expectTrue(one.hidden && two.hidden, "nothing should float loose in the plan")

            try CategoryWriter.setHidden(false, on: group, in: context)
            check.expectTrue(!one.hidden && !two.hidden)
        }

        check.test("the groups the app owns are not the user's to change") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            try CategoryWriter.syncCreditCardCategories(in: context)
            let cards = try check.unwrap(
                try context.fetch(FetchDescriptor<CategoryGroup>())
                    .first { $0.name == CategoryWriter.creditCardGroupName }
            )
            check.expectThrows("renaming the credit card group") {
                try CategoryWriter.rename(cards, to: "My Cards", in: context)
            }
            check.expectThrows("deleting it") { try CategoryWriter.delete(cards, in: context) }
            check.expectThrows("hiding it") {
                try CategoryWriter.setHidden(true, on: cards, in: context)
            }
            check.expectThrows("adding to it by hand") {
                try CategoryWriter.add("Another Card", to: cards, in: context)
            }
        }
    }

    check.suite("A new plan starts with groups to fill") {
        @MainActor func groupNames(_ context: ModelContext) throws -> [String] {
            try context.fetch(FetchDescriptor<CategoryGroup>(sortBy: [SortDescriptor(\.order)]))
                .filter { !CategoryWriter.isManaged($0) }
                .map(\.name)
        }

        check.test("seeds the starter groups and their categories, once") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            // Launch makes the credit card group before anything else; it must not count as a plan.
            try CategoryWriter.syncCreditCardCategories(in: context)
            check.expectTrue(try CategoryWriter.seedStarterPlan(in: context))
            check.expect(try groupNames(context), CategoryWriter.starterGroups.map(\.name))
            check.expect(
                try context.fetchCount(FetchDescriptor<BudgetCategoryModel>()),
                CategoryWriter.starterGroups.reduce(0) { $0 + $1.categories.count }
            )
            check.expectTrue(!(try CategoryWriter.seedStarterPlan(in: context)), "not twice")
        }

        check.test("leaves a plan that is already in use alone") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            try CategoryWriter.addGroup(named: "Annual Bills", in: context)
            check.expectTrue(!(try CategoryWriter.seedStarterPlan(in: context)), "a group of their own")

            let other = ModelContext(try EmbersStore.inMemoryContainer())
            other.insert(Account(name: "Checking", type: .checking))
            try other.save()
            check.expectTrue(!(try CategoryWriter.seedStarterPlan(in: other)), "an account")
        }

        check.test("a starter group keeps its name and place, but can be hidden and added to") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            try CategoryWriter.seedStarterPlan(in: context)
            let fun = try check.unwrap(
                try context.fetch(FetchDescriptor<CategoryGroup>()).first { $0.name == "Just for Fun" }
            )
            check.expectTrue(CategoryWriter.starter(fun)?.purpose.isEmpty == false)
            check.expectThrows("renaming it") {
                try CategoryWriter.rename(fun, to: "Fun", in: context)
            }
            check.expect(try CategoryWriter.deletionRefusal(for: fun, in: context), .starterGroup)

            try CategoryWriter.add("Concerts", to: fun, in: context)
            try CategoryWriter.setHidden(true, on: fun, in: context)
            check.expectTrue(fun.hidden)

            // The starter's categories are the person's own: plain, and free to rename or delete.
            let hobbies = try check.unwrap(fun.categories?.first { $0.name == "Hobbies" })
            try CategoryWriter.rename(hobbies, to: "Painting", in: context)
            check.expectNil(try CategoryWriter.deletionRefusal(for: hobbies, in: context))
        }

        check.test("every name the app seeds is one it can show translated") {
            // Stored in English and translated on display, so a starter name missing from
            // `ProvidedName` would be the one English word in an Arabic plan.
            for starter in CategoryWriter.starterGroups {
                check.expectTrue(ProvidedName.group(starter.name) != nil, starter.name)
                for name in starter.categories {
                    check.expectTrue(ProvidedName.category(name) != nil, name)
                }
            }
            for name in [
                CategoryWriter.creditCardGroupName, CategoryWriter.hiddenGroupName,
                CategoryWriter.inflowGroupName,
            ] {
                check.expectTrue(ProvidedName.group(name) != nil, name)
            }
            check.expectTrue(ProvidedName.category("Ready to Assign") != nil)

            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let mine = try CategoryWriter.addGroup(named: "Kids", in: context)
            check.expect(mine.displayName, "Kids", "what the person names is shown as typed")
        }

        check.test("only the starter groups are described") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let mine = try CategoryWriter.addGroup(named: "Annual Bills", in: context)
            check.expectNil(CategoryWriter.starter(mine))
            // An imported plan's own group of the same name is the same group.
            let imported = try CategoryWriter.addGroup(named: "true expenses", in: context)
            check.expect(CategoryWriter.starter(imported)?.name, "True Expenses")
        }

        check.test("an import replaces the starter groups instead of doubling them") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            try CategoryWriter.seedStarterPlan(in: context)
            let plan = """
            "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
            "Jan 2026","Immediate Obligations: Groceries","Immediate Obligations","Groceries",$100.00,-$70.00,$30.00
            """
            let register = """
            "Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
            "Cash","","01/05/2026","Paycheck","Inflow: Ready to Assign","Inflow","Ready to Assign","",$0.00,$500.00,"Cleared"
            "Cash","","01/10/2026","Carreta Market","Immediate Obligations: Groceries","Immediate Obligations","Groceries","",$70.00,$0.00,"Cleared"
            """
            try YNABImport.commit(
                try YNABImport.read(planCSV: plan, registerCSV: register), into: context,
                reconcileClosingBalances: false
            )
            check.expect(try groupNames(context), ["Immediate Obligations"])
            check.expect(
                try context.fetch(FetchDescriptor<BudgetCategoryModel>())
                    .filter { $0.kind == .normal }.map(\.name),
                ["Groceries"]
            )
        }
    }

    check.suite("Moving categories and groups") {
        @MainActor func twoGroups(
            _ context: ModelContext
        ) throws -> (CategoryGroup, CategoryGroup, [BudgetCategoryModel]) {
            let bills = try CategoryWriter.addGroup(named: "Bills", in: context)
            let fun = try CategoryWriter.addGroup(named: "Fun", in: context)
            let made = try ["Rent", "Power", "Water"].map {
                try CategoryWriter.add($0, to: bills, in: context)
            }
            try CategoryWriter.add("Games", to: fun, in: context)
            return (bills, fun, made)
        }

        @MainActor func names(_ group: CategoryGroup) -> [String] {
            CategoryWriter.editorOrder(group).map(\.name)
        }

        check.test("reorders a category within its group") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (bills, _, made) = try twoGroups(context)
            try CategoryWriter.move(made[2], to: bills, at: 0, in: context)
            check.expect(names(bills), ["Water", "Rent", "Power"])
        }

        check.test("moves a category to another group, and closes the gap it left") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (bills, fun, made) = try twoGroups(context)
            try CategoryWriter.move(made[0], to: fun, at: 1, in: context)
            check.expect(names(fun), ["Games", "Rent"])
            check.expect(names(bills), ["Power", "Water"])
            check.expect(CategoryWriter.editorOrder(bills).map(\.order), [0, 1])
        }

        check.test("refuses a move that would clash, or that goes into a group the app owns") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (bills, fun, made) = try twoGroups(context)
            try CategoryWriter.add("Rent", to: fun, in: context)
            check.expectThrows("a second Rent in Fun") {
                try CategoryWriter.move(made[0], to: fun, at: 0, in: context)
            }
            check.expect(made[0].group?.name, bills.name)

            try CategoryWriter.syncCreditCardCategories(in: context)
            let cards = try check.unwrap(
                try context.fetch(FetchDescriptor<CategoryGroup>())
                    .first { $0.name == CategoryWriter.creditCardGroupName }
            )
            check.expectThrows("into the credit card group") {
                try CategoryWriter.move(made[1], to: cards, at: 0, in: context)
            }
        }

        check.test("a category moved into a hidden group is hidden with it") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (_, fun, made) = try twoGroups(context)
            try CategoryWriter.setHidden(true, on: fun, in: context)
            try CategoryWriter.move(made[0], to: fun, at: 0, in: context)
            check.expectTrue(made[0].hidden, "nothing should float loose in the plan")
        }

        check.test("reorders groups and leaves the credit card group leading") {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let (bills, fun, _) = try twoGroups(context)
            try CategoryWriter.syncCreditCardCategories(in: context)
            let all = try context.fetch(FetchDescriptor<CategoryGroup>(sortBy: [SortDescriptor(\.order)]))
            try CategoryWriter.reorder([fun, bills], in: context)

            let after = try context.fetch(FetchDescriptor<CategoryGroup>(sortBy: [SortDescriptor(\.order)]))
            check.expect(after.map(\.name), [CategoryWriter.creditCardGroupName, "Fun", "Bills"])
            check.expect(all.count, after.count)
        }

        check.test("a move survives the store being closed and reopened") {
            let url = URL.temporaryDirectory.appending(path: "move-\(UUID().uuidString).store")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let context = ModelContext(
                    try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
                )
                let (_, fun, made) = try twoGroups(context)
                try CategoryWriter.move(made[1], to: fun, at: 0, in: context)
            }
            let reopened = ModelContext(
                try EmbersStore.container(cloudKitContainerIdentifier: nil, url: url)
            )
            let fun = try check.unwrap(
                try reopened.fetch(FetchDescriptor<CategoryGroup>()).first { $0.name == "Fun" }
            )
            let bills = try check.unwrap(
                try reopened.fetch(FetchDescriptor<CategoryGroup>()).first { $0.name == "Bills" }
            )
            check.expect(names(fun), ["Power", "Games"])
            check.expect(names(bills), ["Rent", "Water"])
        }
    }

    check.suite("The credit card group follows the accounts") {
        @MainActor func withCards() throws -> (ModelContext, Account, Account) {
            let context = ModelContext(try EmbersStore.inMemoryContainer())
            let visa = try AccountWriter.create(
                name: "Atlas Visa", type: .creditCard, currencyCode: "USD", in: context
            )
            let cib = try AccountWriter.create(
                name: "Harbor MasterCard", type: .creditCard, currencyCode: "EGP", in: context
            )
            return (context, visa, cib)
        }

        @MainActor func cardCategories(_ context: ModelContext) throws -> [BudgetCategoryModel] {
            try context.fetch(FetchDescriptor<BudgetCategoryModel>())
                .filter { $0.kind == .creditCardPayment }
        }

        check.test("one category per open card, named after it") {
            let (context, _, _) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            let shown = try cardCategories(context).filter { !$0.hidden }
            check.expect(Set(shown.map(\.name)), ["Atlas Visa", "Harbor MasterCard"])
            check.expectTrue(
                shown.allSatisfy { $0.group?.name == CategoryWriter.creditCardGroupName },
                "they belong to the card group"
            )
        }

        check.test("closing a card takes it off the plan without losing its history") {
            let (context, _, cib) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            let before = try check.unwrap(try cardCategories(context).first { $0.name == "Harbor MasterCard" })
            context.insert(
                CategoryAssignment(
                    month: YearMonth(year: 2026, month: 3), amountMinor: 20_000, category: before
                )
            )
            try context.save()

            cib.closed = true
            let change = try CategoryWriter.syncCreditCardCategories(in: context)
            check.expect(change.hidden, 1)

            let after = try check.unwrap(try cardCategories(context).first { $0.name == "Harbor MasterCard" })
            check.expectTrue(after.hidden, "a closed card drops off the plan")
            check.expect(after.group?.name, CategoryWriter.hiddenGroupName)
            check.expect(
                try context.fetchCount(FetchDescriptor<CategoryAssignment>()), 1,
                "but what was budgeted against it stands"
            )
        }

        check.test("reopening a card brings it back") {
            let (context, _, cib) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            cib.closed = true
            try CategoryWriter.syncCreditCardCategories(in: context)
            cib.closed = false
            let change = try CategoryWriter.syncCreditCardCategories(in: context)

            check.expect(change.restored, 1)
            let back = try check.unwrap(try cardCategories(context).first { $0.name == "Harbor MasterCard" })
            check.expectTrue(!back.hidden)
            check.expect(back.group?.name, CategoryWriter.creditCardGroupName)
        }

        check.test("renaming the card renames its category") {
            let (context, visa, _) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            visa.name = "Atlas Visa (EGP)"
            check.expect(try CategoryWriter.syncCreditCardCategories(in: context).renamed, 1)
            check.expectTrue(
                try cardCategories(context).contains { $0.name == "Atlas Visa (EGP)" },
                "the category is the card's name, not a copy of it"
            )
        }

        check.test("an account that stops being a card stops having one") {
            let (context, visa, _) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            visa.type = .checking
            try CategoryWriter.syncCreditCardCategories(in: context)
            let still = try check.unwrap(try cardCategories(context).first { $0.name == "Atlas Visa" })
            check.expectTrue(still.hidden)
        }

        check.test("running it again changes nothing") {
            let (context, _, _) = try withCards()
            try CategoryWriter.syncCreditCardCategories(in: context)
            let again = try CategoryWriter.syncCreditCardCategories(in: context)
            check.expect(again.added + again.hidden + again.restored + again.renamed, 0)
        }
    }
}
