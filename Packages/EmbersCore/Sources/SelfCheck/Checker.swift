import Foundation

/// A minimal test harness.
///
/// Neither XCTest nor swift-testing ships with the Command Line Tools, so `swift test` cannot run
/// without Xcode installed. Running the checks as a plain executable keeps the suite usable in the
/// meantime; the assertions are ordinary code and port to swift-testing mechanically later.
final class Checker {
    private var suiteName = ""
    private var caseName = ""
    private(set) var assertions = 0
    private(set) var failures: [String] = []
    private var failedCases = Set<String>()
    private var caseCount = 0

    func suite(_ name: String, _ body: () -> Void) {
        suiteName = name
        print("\n\(name)")
        body()
    }

    func test(_ name: String, _ body: () throws -> Void) {
        caseName = name
        caseCount += 1
        let failuresBefore = failures.count
        do {
            try body()
        } catch {
            record("threw \(error)")
        }
        let symbol = failures.count == failuresBefore ? "✓" : "✗"
        print("  \(symbol) \(name)")
    }

    private func record(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
        failedCases.insert("\(suiteName)/\(caseName)")
        failures.append("\(suiteName) › \(caseName)\n      \(message)\n      at \(file):\(line)")
    }

    func expect<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String = "",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        assertions += 1
        guard actual != expected else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        record("\(prefix)expected \(expected), got \(actual)", file: file, line: line)
    }

    func expectTrue(
        _ value: Bool,
        _ label: String = "",
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        assertions += 1
        guard !value else { return }
        record(label.isEmpty ? "expected true" : "\(label): expected true", file: file, line: line)
    }

    func expectNil<T>(_ value: T?, _ label: String = "", file: StaticString = #fileID, line: UInt = #line) {
        assertions += 1
        guard let value else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        record("\(prefix)expected nil, got \(value)", file: file, line: line)
    }

    func unwrap<T>(
        _ value: T?,
        _ label: String = "",
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> T {
        assertions += 1
        guard let value else {
            record(label.isEmpty ? "unexpected nil" : "\(label): unexpected nil", file: file, line: line)
            throw CheckerError.unexpectedNil
        }
        return value
    }

    func expectThrows(
        _ label: String = "",
        file: StaticString = #fileID,
        line: UInt = #line,
        _ body: () throws -> some Any
    ) {
        assertions += 1
        do {
            _ = try body()
            record(label.isEmpty ? "expected an error" : "\(label): expected an error", file: file, line: line)
        } catch {
            return
        }
    }

    func summarize() -> Int32 {
        print("\n" + String(repeating: "─", count: 60))
        if failures.isEmpty {
            print("PASSED  \(caseCount) checks, \(assertions) assertions")
            return 0
        }
        print("FAILED  \(failedCases.count) of \(caseCount) checks, \(assertions) assertions\n")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}

enum CheckerError: Error {
    case unexpectedNil
}
