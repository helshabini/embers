import Foundation

/// What is typed on the assign keypad: an amount, or a sum that works one out.
///
/// Assigning is usually arithmetic on what is there already — "another 50", "half of it", "three
/// months of 120" — and the person should not need another app to do it. So the keypad has + − × ÷,
/// and it starts on the amount already assigned: a digit replaces it, an operator works on it.
///
/// Amounts are typed as they read, with a decimal point, not as minor units the way the transaction
/// keypad takes them: a sum of two amounts typed in cents would be unreadable.
public struct AssignmentCalculator: Sendable, Equatable {
    public enum Operator: Character, CaseIterable, Sendable {
        case add = "+"
        case subtract = "−"
        case multiply = "×"
        case divide = "÷"

        var precedence: Int { self == .add || self == .subtract ? 1 : 2 }
    }

    public let currency: Currency
    /// What has been typed: digits, at most one "." per number, and the operators' own characters.
    public private(set) var text: String
    /// Set while the text is the amount the keypad opened on, so the first digit starts afresh.
    public private(set) var isShowingStart: Bool

    public init(startingAt minorUnits: MinorUnits, currency: Currency) {
        self.currency = currency
        text = minorUnits == 0 ? "" : Self.plainText(minorUnits, currency: currency)
        isShowingStart = true
    }

    // MARK: - Typing

    public mutating func append(digit: Character) {
        guard digit.isASCII, digit.isNumber else { return }
        startAfresh()
        let number = currentNumber
        // No more decimals than the currency has.
        if let point = number.firstIndex(of: ".") {
            guard number[number.index(after: point)...].count < currency.minorUnitDigits else { return }
        }
        // "0" then "5" is 5, not 05.
        if number == "0" { text.removeLast() }
        text.append(digit)
    }

    public mutating func appendDecimalPoint() {
        guard currency.minorUnitDigits > 0 else { return }
        startAfresh()
        let number = currentNumber
        guard !number.contains(".") else { return }
        if number.isEmpty { text.append("0") }
        text.append(".")
    }

    /// Works on what is there. An operator straight after another replaces it. With nothing there,
    /// a minus starts a negative amount and anything else works on zero: "+10" on a category with
    /// nothing assigned is ten, not a key that did nothing.
    public mutating func append(_ op: Operator) {
        isShowingStart = false
        if let last = text.last, Operator(rawValue: last) != nil {
            text.removeLast()
        } else if text.last == "." {
            text.removeLast()
        }
        if text.isEmpty, op != .subtract { text = "0" }
        text.append(op.rawValue)
    }

    public mutating func deleteLast() {
        isShowingStart = false
        if !text.isEmpty { text.removeLast() }
    }

    public mutating func clear() {
        isShowingStart = false
        text = ""
    }

    private mutating func startAfresh() {
        if isShowingStart { text = "" }
        isShowingStart = false
    }

    /// The number being typed: everything after the last operator.
    private var currentNumber: Substring {
        let start = text.lastIndex { Operator(rawValue: $0) != nil }.map { text.index(after: $0) } ?? text.startIndex
        return text[start...]
    }

    // MARK: - Reading

    /// Whether there is any arithmetic left to do, as opposed to a plain amount.
    public var hasOperator: Bool {
        text.dropFirst().contains { Operator(rawValue: $0) != nil }
    }

    /// What it comes to, rounded to the currency; nil when it comes to nothing a number can be,
    /// such as a division by zero. Nothing typed is zero.
    public var result: MinorUnits? {
        Self.evaluate(text, currency: currency)
    }

    /// Evaluates a sum in the keypad's own notation. A trailing operator is ignored, so "100+" is
    /// 100 while the next number is still to come.
    public static func evaluate(_ text: String, currency: Currency) -> MinorUnits? {
        var tokens: [Token] = []
        var number = ""
        for character in text {
            if let op = Operator(rawValue: character) {
                if number.isEmpty, tokens.isEmpty, op == .subtract {
                    number = "-"
                    continue
                }
                guard let value = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
                tokens.append(.number(value))
                tokens.append(.op(op))
                number = ""
            } else {
                number.append(character)
            }
        }
        if number.isEmpty || number == "-" {
            if case .op = tokens.last { tokens.removeLast() }
        } else {
            guard let value = Decimal(string: number, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            tokens.append(.number(value))
        }
        guard !tokens.isEmpty else { return 0 }
        guard let value = reduce(tokens) else { return nil }
        return minorUnits(value, currency: currency)
    }

    // MARK: - Arithmetic

    private enum Token {
        case number(Decimal)
        case op(Operator)
    }

    /// × and ÷ before + and −, then left to right: "100 + 20 × 3" is 160, as it reads.
    private static func reduce(_ tokens: [Token]) -> Decimal? {
        var values: [Decimal] = []
        var operators: [Operator] = []

        func apply() -> Bool {
            guard let op = operators.popLast(), values.count >= 2 else { return false }
            let right = values.removeLast()
            let left = values.removeLast()
            switch op {
            case .add: values.append(left + right)
            case .subtract: values.append(left - right)
            case .multiply: values.append(left * right)
            case .divide:
                guard right != 0 else { return false }
                values.append(left / right)
            }
            return true
        }

        for token in tokens {
            switch token {
            case let .number(value):
                values.append(value)
            case let .op(op):
                while let top = operators.last, top.precedence >= op.precedence {
                    guard apply() else { return nil }
                }
                operators.append(op)
            }
        }
        while !operators.isEmpty {
            guard apply() else { return nil }
        }
        return values.count == 1 ? values[0] : nil
    }

    private static func minorUnits(_ value: Decimal, currency: Currency) -> MinorUnits? {
        var scaled = value * pow(10, currency.minorUnitDigits)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        // Past what a ledger could ever hold is a typing slip, not an amount.
        guard abs(rounded) < Decimal(Int64.max / 1_000) else { return nil }
        return MinorUnits(truncating: rounded as NSDecimalNumber)
    }

    /// An amount in the keypad's notation: no grouping, a "." for the decimal point, no trailing
    /// zeros past what the amount needs.
    static func plainText(_ minorUnits: MinorUnits, currency: Currency) -> String {
        let digits = currency.minorUnitDigits
        let negative = minorUnits < 0
        let magnitude = minorUnits.magnitude
        guard digits > 0 else { return (negative ? "-" : "") + String(magnitude) }
        let divisor = UInt64(pow(10, Double(digits)))
        var fraction = String(magnitude % divisor)
        fraction = String(repeating: "0", count: digits - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        let whole = String(magnitude / divisor)
        // The keypad's own minus, so typing on after it reads as a sum.
        return (negative ? "−" : "") + whole + (fraction.isEmpty ? "" : "." + fraction)
    }

    // MARK: - Typed by hand

    /// What a field's text turned out to be.
    public enum Typed: Equatable, Sendable {
        /// No arithmetic: an amount for the ordinary parser, which knows "(50)" and "50-".
        case plain
        case sum(MinorUnits)
        /// Arithmetic that comes to nothing — "100/0", "100*-2", "100+50-". Refused, never handed
        /// to the ordinary parser: it drops what it does not read, and saved 100/0 as 1,000.
        case malformed
    }

    /// A sum typed into a text field rather than on the keypad, as on the Mac: "100+50", "1,200/12".
    /// The reader's own decimal and grouping marks are understood, and * and / stand for × and ÷.
    public static func read(typed text: String, currency: Currency, locale: Locale) -> Typed {
        let decimal = locale.decimalSeparator ?? "."
        let grouping = locale.groupingSeparator ?? ","
        var normalized = ""
        for character in text where !character.isWhitespace {
            switch character {
            case "+": normalized.append(Operator.add.rawValue)
            case "-", "−": normalized.append(Operator.subtract.rawValue)
            case "*", "x", "X", "×": normalized.append(Operator.multiply.rawValue)
            case "/", "÷": normalized.append(Operator.divide.rawValue)
            case _ where String(character) == grouping: continue
            case _ where String(character) == decimal: normalized.append(".")
            case _ where character.isASCII && character.isNumber: normalized.append(character)
            default: continue  // a currency symbol, or anything else that is not arithmetic
            }
        }
        let operators = normalized.enumerated().filter { Operator(rawValue: $0.element) != nil }
        let isSign = { (offset: Int, character: Character) in
            character == Operator.subtract.rawValue && (offset == 0 || offset == normalized.count - 1)
        }
        // A leading minus, or the accountant's trailing one on its own, is a sign, not a sum.
        if operators.isEmpty || (operators.count == 1 && isSign(operators[0].offset, operators[0].element)) {
            return .plain
        }
        // Typed in a field a sum is finished, so one ending on an operator is not one.
        guard let last = normalized.last, Operator(rawValue: last) == nil,
              let result = evaluate(normalized, currency: currency)
        else { return .malformed }
        return .sum(result)
    }
}
