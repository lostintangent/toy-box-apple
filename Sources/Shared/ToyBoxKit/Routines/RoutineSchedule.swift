import Foundation

enum CronScheduleError: Error, Equatable, LocalizedError {
    case invalidExpression(String)

    var errorDescription: String? {
        switch self {
        case .invalidExpression(let reason): "Invalid cron schedule: \(reason)"
        }
    }
}

public struct RoutineSchedule {
    private enum Unit: Int, CaseIterable {
        case second, minute, hour, day, month, weekday

        var bounds: ClosedRange<Int> {
            switch self {
            case .second, .minute: 0...59
            case .hour: 0...23
            case .day: 1...31
            case .month: 1...12
            case .weekday: 0...7
            }
        }
    }

    private enum Value: Hashable {
        case number(Int)
        case last(String)
    }

    private struct Field {
        var raw: String
        var values: [Int]
        var special: [String]
        var nth: Double?

        var isWildcard: Bool { raw == "*" || raw == "?" }
        var isHashed: Bool { raw.firstMatch(of: /H(?:$|[^A-Za-z])/) != nil }
        var minimum: Int { values[0] }
    }

    public let expression: String
    private let fields: [Field]
    private var second: Field { fields[0] }
    private var minute: Field { fields[1] }
    private var hour: Field { fields[2] }
    private var day: Field { fields[3] }
    private var month: Field { fields[4] }
    private var weekday: Field { fields[5] }

    public init(_ expression: String) throws {
        self.expression = expression
        let aliases = [
            "@yearly": "0 0 0 1 1 *", "@annually": "0 0 0 1 1 *",
            "@monthly": "0 0 0 1 * *", "@weekly": "0 0 0 * * 0",
            "@daily": "0 0 0 * * *", "@hourly": "0 0 * * * *",
            "@minutely": "0 * * * * *", "@secondly": "* * * * * *",
            "@weekdays": "0 0 0 * * 1-5", "@weekends": "0 0 0 * * 0,6",
        ]
        let expanded = aliases[expression] ?? (expression.isEmpty ? "0 * * * * *" : expression)
        guard expanded.utf16.count <= 1024 else { throw Self.invalid("expression exceeds 1024 characters") }
        var atoms = expanded.split(whereSeparator: \.isWhitespace).map(String.init)
        if atoms.isEmpty { atoms = [""] }
        guard atoms.count <= 6 else { throw Self.invalid("expected at most six fields") }
        atoms.insert(contentsOf: ["0", "*", "*", "*", "*", "*"].prefix(6 - atoms.count), at: 0)
        var parsed: [Unit: Field] = [:]
        for unit in [Unit.second, .minute, .hour, .month, .day, .weekday] {
            var values = try Self.parse(atoms[unit.rawValue], unit: unit, random: .random(in: 0..<1))
            if unit == .day, let months = parsed[.month]?.values, months.count == 1 {
                let maximum = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][months[0] - 1]
                let filtered = values.filter {
                    if case .number(let value) = $0 { return value <= maximum }
                    return true
                }
                if !filtered.isEmpty { values = filtered }
            }
            guard !values.isEmpty, Set(values).count == values.count else {
                throw Self.invalid("empty or duplicate \(unit) values")
            }
            let numbers = values.compactMap { if case .number(let value) = $0 { value } else { nil } }.sorted()
            let special = values.compactMap { if case .last(let value) = $0 { value } else { nil } }
            guard numbers.allSatisfy(unit.bounds.contains),
                  special.allSatisfy({ $0.wholeMatch(of: /\d{0,2}L/) != nil }),
                  unit != .weekday || !special.contains("L") else {
                throw Self.invalid("invalid \(unit) value")
            }
            let nth = unit == .weekday ? try Self.nthWeekday(atoms[5]) : nil
            parsed[unit] = Field(raw: atoms[unit.rawValue], values: numbers, special: special, nth: nth)
        }
        fields = try Unit.allCases.map {
            guard let field = parsed[$0] else { throw Self.invalid("missing \($0) field") }
            return field
        }
    }

    public func summary(locale: Locale = .current) -> String {
        plainSummary(locale: locale) ?? expression
    }

    private func plainSummary(locale: Locale) -> String? {
        guard !fields.contains(where: \.isHashed), second.values == [0],
              day.isWildcard, month.isWildcard, weekday.special.isEmpty, weekday.nth == nil else {
            return nil
        }
        if weekday.isWildcard, minute.values == [0], hour.isWildcard { return "Every hour" }
        guard minute.values.count == 1, hour.values.count == 1 else { return nil }
        let prefix: String
        let weekdays = Set(weekday.values.map { $0 % 7 })
        if weekday.isWildcard { prefix = "Every day" }
        else if weekdays == Set(1...5) { prefix = "Weekdays" }
        else if weekdays.count == 1, let index = weekdays.first {
            prefix = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"][index]
        } else { return nil }
        let time = Date(timeIntervalSince1970: TimeInterval(hour.minimum * 3600 + minute.minimum * 60))
        let format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: .gmt)
        return "\(prefix) at \(time.formatted(format))"
    }

    private static func invalid(_ reason: String) -> CronScheduleError { .invalidExpression(reason) }

    private static func nthWeekday(_ raw: String) throws -> Double? {
        let pieces = raw.split(separator: "#", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return nil }
        guard pieces.count == 2, !raw.contains(where: { ",-/".contains($0) }),
              let nth = Double(pieces[1]), (1...5).contains(nth) else {
            throw invalid("invalid weekday occurrence")
        }
        return nth
    }

    private static func parse(_ raw: String, unit: Unit, random: Double) throws -> [Value] {
        var text = raw
        if unit == .weekday {
            _ = try nthWeekday(raw)
            text = String(raw.prefix { $0 != "#" })
        }
        if unit == .month || unit == .weekday {
            let aliases = [
                "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12,
                "sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
            ]
            for match in text.matches(of: /[a-zA-Z]{3}/).reversed() {
                guard let value = aliases[String(match.output).lowercased()] else {
                    throw invalid("unknown calendar name")
                }
                text.replaceSubrange(match.range, with: String(value))
            }
        }
        let allowed = unit == .day || unit == .weekday ? "0123456789,*?LH/-" : "0123456789,*?H/-"
        let hasHashedRange = text.firstMatch(of: /H\(\d+-\d+\)/) != nil
        guard !text.isEmpty, text.allSatisfy({ allowed.contains($0) }) || hasHashedRange else {
            throw invalid("unsupported \(unit) character")
        }
        text = text.replacingOccurrences(of: "*", with: "\(unit.bounds.lowerBound)-\(unit.bounds.upperBound)")
            .replacingOccurrences(of: "?", with: "\(unit.bounds.lowerBound)-\(unit.bounds.upperBound)")
        var hashedCount = 0
        for match in text.matches(of: /H(?:\((\d+)-(\d+)\))?(?:\/(\d+))?/).reversed() {
            var lower = unit.bounds.lowerBound
            var upper = unit.bounds.upperBound
            if let rawLower = match.1, let rawUpper = match.2 {
                guard let requestedLower = Int(rawLower), let requestedUpper = Int(rawUpper),
                      requestedLower <= requestedUpper else { throw invalid("invalid hashed range") }
                lower = max(lower, requestedLower)
                upper = min(upper, requestedUpper)
                guard lower <= upper else { throw invalid("hashed range has no usable value") }
            }
            let replacement: String
            if let rawStep = match.3 {
                guard let step = Int(rawStep), step > 0 else { throw invalid("invalid hashed step") }
                hashedCount += (upper - lower) / step + 1
                guard hashedCount <= 256 else { throw invalid("too many hashed values") }
                let offset = Int((random * Double(step)).rounded(.down))
                var values: [Int] = []
                var value = (lower / step) * step + offset
                while value <= upper {
                    if value >= lower { values.append(value) }
                    guard value <= Int.max - step else { break }
                    value += step
                }
                replacement = values.isEmpty ? String(lower + Int(random * Double(upper - lower + 1)))
                    : values.map(String.init).joined(separator: ",")
            } else {
                replacement = String(lower + Int(random * Double(upper - lower + 1)))
            }
            text.replaceSubrange(match.range, with: replacement)
        }
        var result: [Value] = []
        for piece in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard result.count <= 256, !piece.isEmpty else { throw invalid("invalid or oversized list") }
            let repeatParts = piece.split(separator: "/", omittingEmptySubsequences: false)
            guard repeatParts.count <= 2 else { throw invalid("invalid repeat") }
            var rangeText = String(repeatParts[0])
            var step = 1
            if repeatParts.count == 2 {
                guard let interval = leadingInteger(String(repeatParts[1])), interval > 0 else {
                    throw invalid("repeat must be positive")
                }
                step = interval
                if !rangeText.contains("-") { rangeText += "-\(unit.bounds.upperBound)" }
            }
            let range = rangeText.split(separator: "-", omittingEmptySubsequences: false)
            if range.count > 1 {
                guard let lower = leadingInteger(String(range[0])), let upper = leadingInteger(String(range[1])),
                      lower <= upper, unit.bounds.contains(lower), unit.bounds.contains(upper) else {
                    throw invalid("range outside \(unit) bounds")
                }
                var values: [Int] = []
                if unit == .weekday, upper % 7 == 0, (upper - lower) % step == 0 { values.append(0) }
                var value = lower
                while value <= upper {
                    if !values.contains(value) { values.append(value) }
                    guard value <= Int.max - step else { break }
                    value += step
                }
                result += values.map(Value.number)
            } else if let value = Int(rangeText) {
                guard unit.bounds.contains(value) else { throw invalid("value outside \(unit) bounds") }
                result.append(.number(unit == .weekday ? value % 7 : value))
            } else if (unit == .day || unit == .weekday), rangeText.contains("L") {
                result.append(.last(rangeText))
            } else {
                throw invalid("invalid \(unit) value")
            }
        }
        return result
    }

    private static func leadingInteger(_ value: String) -> Int? {
        Int(value.prefix { $0.isASCII && $0.isNumber })
    }
}
