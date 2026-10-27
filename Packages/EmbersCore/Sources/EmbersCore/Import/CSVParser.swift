import Foundation

/// A parsed CSV file with its header row indexed by column name.
public struct CSVTable: Sendable {
    public let columns: [String]
    public let rows: [[String]]
    private let columnIndex: [String: Int]

    public init(columns: [String], rows: [[String]]) {
        self.columns = columns
        self.rows = rows
        self.columnIndex = Dictionary(columns.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func value(_ column: String, in row: [String]) -> String {
        guard let index = columnIndex[column], index < row.count else { return "" }
        return row[index]
    }

    public func hasColumns(_ required: [String]) -> Bool {
        required.allSatisfy { columnIndex[$0] != nil }
    }
}

/// RFC 4180 CSV reader.
///
/// YNAB exports need all of it: a UTF-8 BOM, quoted fields containing commas, and doubled quotes
/// inside memos (`... categorized as ""Pre-YNAB Debt"" -- `).
public enum CSVParser {
    public static func parse(_ text: String) -> CSVTable {
        var records = parseRecords(text)
        guard !records.isEmpty else { return CSVTable(columns: [], rows: []) }
        let header = records.removeFirst()
        // Trailing blank line is common; drop rows that carry no content at all.
        let rows = records.filter { row in row.contains { !$0.isEmpty } }
        return CSVTable(columns: header, rows: rows)
    }

    public static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        var isFirstScalar = true

        func endField() {
            fields.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            records.append(fields)
            fields = []
        }

        while true {
            let scalar: Unicode.Scalar?
            if let pendingScalar = pending {
                scalar = pendingScalar
                pending = nil
            } else {
                scalar = iterator.next()
            }
            guard let scalar else { break }

            if isFirstScalar {
                isFirstScalar = false
                if scalar == "\u{FEFF}" { continue }
            }

            if isQuoted {
                if scalar == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            isQuoted = false
                            pending = next
                        }
                    } else {
                        isQuoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }

            switch scalar {
            case "\"":
                isQuoted = true
            case ",":
                endField()
            case "\n":
                endRecord()
            case "\r":
                // Consume the LF of a CRLF pair.
                if let next = iterator.next(), next != "\n" { pending = next }
                endRecord()
            default:
                field.unicodeScalars.append(scalar)
            }
        }

        if !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        return records
    }
}
