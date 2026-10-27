import Foundation
import EmbersCore

func parsingChecks(_ check: Checker) {
    check.suite("CSV parsing") {
        check.test("reads quoted fields, a BOM, and CRLF line endings") {
            let text = "\u{FEFF}\"Account\",\"Flag\",\"Date\"\r\n\"Cash (EGP)\",\"\",\"08/10/2027\"\r\n"
            let table = CSVParser.parse(text)
            check.expect(table.columns, ["Account", "Flag", "Date"])
            check.expect(table.rows.count, 1)
            check.expect(table.value("Account", in: table.rows[0]), "Cash (EGP)")
            check.expect(table.value("Flag", in: table.rows[0]), "")
            check.expect(table.value("Date", in: table.rows[0]), "08/10/2027")
        }

        check.test("unescapes doubled quotes inside a memo") {
            let text = """
            "Memo"
            "Import Warning: previously categorized as ""Pre-YNAB Debt: Orbit Business (USD)"" -- "
            """
            let table = CSVParser.parse(text)
            check.expect(
                table.value("Memo", in: table.rows[0]),
                #"Import Warning: previously categorized as "Pre-YNAB Debt: Orbit Business (USD)" -- "#
            )
        }

        check.test("keeps commas and newlines inside quoted fields") {
            let table = CSVParser.parse("\"a\",\"b,c\",\"d\ne\"\n")
            check.expect(table.columns, ["a", "b,c", "d\ne"])
        }

        check.test("skips blank trailing rows") {
            check.expect(CSVParser.parse("\"a\",\"b\"\n\"1\",\"2\"\n\n").rows.count, 1)
        }

        check.test("reports missing columns") {
            let table = CSVParser.parse("\"a\",\"b\"\n")
            check.expectTrue(table.hasColumns(["a"]))
            check.expectTrue(!table.hasColumns(["a", "z"]))
        }
    }

    check.suite("YNAB export rows") {
        let parser = YNABExportParser()

        check.test("reads MM/DD/YYYY regardless of device locale") {
            let date = try check.unwrap(YNABExportParser.parseDate("05/30/2027"))
            let parts = Calendar.gregorianUTC.dateComponents([.year, .month, .day], from: date)
            check.expect(parts.year, 2027)
            check.expect(parts.month, 5)
            check.expect(parts.day, 30)
            check.expectNil(YNABExportParser.parseDate("2027-05-30"))
            check.expectNil(YNABExportParser.parseDate(""))
        }

        check.test("recognises transfer payees") {
            check.expect(
                YNABExportParser.transferCounterAccountName(fromPayee: "Transfer : Atlas Checking (EGP)"),
                "Atlas Checking (EGP)"
            )
            check.expectNil(YNABExportParser.transferCounterAccountName(fromPayee: "Game Store"))
            check.expectNil(YNABExportParser.transferCounterAccountName(fromPayee: "Starting Balance"))
        }

        check.test("splits out the Split (i/n) memo prefix") {
            let bare = YNABExportParser.splitMarker(fromMemo: "Split (1/2)")
            check.expect(bare?.index, 1)
            check.expect(bare?.total, 2)
            check.expect(bare?.remainingMemo, "")

            let withMemo = YNABExportParser.splitMarker(fromMemo: "Split (2/3) iPad & Accessories")
            check.expect(withMemo?.index, 2)
            check.expect(withMemo?.total, 3)
            check.expect(withMemo?.remainingMemo, "iPad & Accessories")

            check.expectNil(YNABExportParser.splitMarker(fromMemo: "Game subscription")?.total)
            check.expectNil(YNABExportParser.splitMarker(fromMemo: "Split (bad)")?.total)
        }

        check.test("signs the amount as inflow minus outflow") {
            let csv = """
            "Account","Flag","Date","Payee","Category Group/Category","Category Group","Category","Memo","Outflow","Inflow","Cleared"
            "Atlas MasterCard (EGP)","","08/10/2027","Game Store","True Expenses: Software","True Expenses","Software","Subscription",$90.00,$0.00,"Uncleared"
            "Cash (EGP)","","08/01/2019","Starting Balance","Inflow: Ready to Assign","Inflow","Ready to Assign","",$0.00,$1200.00,"Reconciled"
            """
            let rows = try parser.parseRegister(csv)
            check.expect(rows.count, 2)
            check.expect(rows[0].amount, -9000)
            check.expect(rows[0].cleared, .uncleared)
            check.expect(rows[0].categoryName, "Software")
            check.expect(rows[1].amount, 120_000)
            check.expect(rows[1].cleared, .reconciled)
            check.expect(rows[1].groupName, "Inflow")
        }

        check.test("reads plan rows including negative activity") {
            let csv = """
            "Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"
            "Aug 2019","Credit Card Payments: Atlas MasterCard (EGP)","Credit Card Payments","Atlas MasterCard (EGP)",$0.00,-$584.59,-$584.59
            """
            let rows = try parser.parsePlan(csv)
            check.expect(rows.count, 1)
            check.expect(rows[0].month, YearMonth(year: 2019, month: 8))
            check.expect(rows[0].groupName, "Credit Card Payments")
            check.expect(rows[0].assigned, 0)
            check.expect(rows[0].activity, -58459)
            check.expect(rows[0].available, -58459)
        }

        check.test("rejects a file missing required columns") {
            check.expectThrows { try parser.parseRegister("\"Account\",\"Date\"\n") }
        }

        check.test("reads an ISO currency suffix but not a location suffix") {
            check.expect(YNABImporter.currencyCode(fromAccountName: "Atlas Checking (EGP)"), "EGP")
            check.expect(YNABImporter.currencyCode(fromAccountName: "Cash (KES)"), "KES")
            check.expectNil(YNABImporter.currencyCode(fromAccountName: "Apartment (NW)"))
            check.expectNil(YNABImporter.currencyCode(fromAccountName: "Apartment (SE)"))
            check.expectNil(YNABImporter.currencyCode(fromAccountName: "Crypto"))
        }
    }
}
