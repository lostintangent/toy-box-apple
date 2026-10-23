import Foundation

public enum CronScheduleError: Error, Equatable, LocalizedError, Sendable {
    case invalidExpression(String)
    case noOccurrence
    case invalidDate

    public var errorDescription: String? {
        switch self {
        case .invalidExpression(let reason): "Invalid cron schedule: \(reason)"
        case .noOccurrence: "No cron occurrence was found within the parser's search limit."
        case .invalidDate: "The cron schedule could not resolve a calendar date."
        }
    }
}

public func nextCronOccurrence(_ expression: String, from date: Date,
                               timeZone: TimeZone = .current, hashSeed: String? = nil) throws -> Date {
    try CronSchedule(expression, hashSeed: hashSeed).next(after: date, timeZone: timeZone)
}

public func cronSummary(_ expression: String, locale: Locale = .current) throws -> String {
    try CronSchedule(expression, hashSeed: nil).summary(locale: locale) ?? expression
}

private struct CronSchedule {
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
        var hasLast: Bool { raw.contains("L") }
        var isHashed: Bool { raw.firstMatch(of: /H(?:$|[^A-Za-z])/) != nil }
        var minimum: Int { values[0] }
        func contains(_ value: Int) -> Bool { values.contains(value) }
        func next(after value: Int) -> Int? { values.first { $0 > value } }
    }

    private let fields: [Field]
    private var second: Field { fields[0] }
    private var minute: Field { fields[1] }
    private var hour: Field { fields[2] }
    private var day: Field { fields[3] }
    private var month: Field { fields[4] }
    private var weekday: Field { fields[5] }

    init(_ expression: String, hashSeed: String?) throws {
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
        var random = CronRandom(seed: hashSeed)
        var parsed: [Unit: Field] = [:]
        for unit in [Unit.second, .minute, .hour, .month, .day, .weekday] {
            var values = try Self.parse(atoms[unit.rawValue], unit: unit, random: random.next())
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

    func summary(locale: Locale) -> String? {
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

    func next(after date: Date, timeZone: TimeZone) throws -> Date {
        guard date.timeIntervalSince1970.isFinite, abs(date.timeIntervalSince1970) <= 8_640_000_000_000 else {
            throw CronScheduleError.invalidDate
        }
        var cursor = CronCursor(date: date, timeZone: timeZone, hourCount: hour.values.count)
        let start = date.timeIntervalSince1970
        cursor.date = Date(timeIntervalSince1970: floor(start))
        if cursor.date < date { try cursor.advance(.second) }
        for _ in 0..<9999 {
            if try !matchesDay(cursor) { try cursor.advance(.day); continue }
            if !month.contains(cursor.component(.month)) { try cursor.advance(.month); continue }
            if !hour.contains(cursor.component(.hour)), !cursor.matchesSkippedHour(hour.values) {
                cursor.clearGap()
                if let next = hour.next(after: cursor.component(.hour)) {
                    if try cursor.isTransitionDay {
                        let steps = next - cursor.component(.hour)
                        for _ in 0..<steps {
                            try cursor.advance(.hour)
                            if cursor.component(.hour) >= next { break }
                        }
                    } else { try cursor.set(.hour, to: next) }
                    try cursor.set(.minute, to: minute.minimum)
                    try cursor.set(.second, to: second.minimum)
                } else { try cursor.advance(.day) }
                continue
            }
            if cursor.repeatedHour == cursor.component(.hour), !cursor.matchesSkippedHour(hour.values) {
                cursor.repeatedHour = nil
                try cursor.advance(.hour)
                continue
            }
            if !minute.contains(cursor.component(.minute)) {
                if let next = minute.next(after: cursor.component(.minute)) {
                    try cursor.set(.minute, to: next)
                } else {
                    try cursor.advance(.hour)
                    try cursor.set(.minute, to: minute.minimum)
                }
                try cursor.set(.second, to: second.minimum)
                continue
            }
            if !second.contains(cursor.component(.second)) {
                if let next = second.next(after: cursor.component(.second)) {
                    try cursor.set(.second, to: next)
                } else {
                    try cursor.advance(.minute)
                    try cursor.set(.second, to: second.minimum)
                }
                continue
            }
            if cursor.date.timeIntervalSince1970 == start {
                try cursor.advance(.second)
                continue
            }
            return cursor.date
        }
        throw CronScheduleError.noOccurrence
    }

    private func matchesDay(_ cursor: CronCursor) throws -> Bool {
        let date = cursor.component(.day)
        let weekdayNumber = cursor.component(.weekday) - 1
        let monthLength = try cursor.monthLength
        let matchesDate = day.contains(date) || (day.hasLast && date == monthLength)
        let matchesNth = weekday.nth.map { Double((date + 6) / 7) == $0 } ?? true
        let lastWeekday = weekday.hasLast && date > monthLength - 7
            && (weekday.values.map(String.init) + weekday.special).contains {
                $0.first?.wholeNumberValue.map { $0 % 7 == weekdayNumber } == true
            }
        let matchesWeekday = (weekday.contains(weekdayNumber) && matchesNth) || lastWeekday
        if !day.isWildcard && !weekday.isWildcard { return matchesDate || matchesWeekday }
        if !weekday.isWildcard { return matchesWeekday }
        return matchesDate
    }
}

private struct CronCursor {
    var date: Date
    let calendar: Calendar
    let hourCount: Int
    var repeatedHour: Int?
    private var skippedHour: Int?
    private var landingHour: Int?

    init(date: Date, timeZone: TimeZone, hourCount: Int) {
        self.date = date
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.hourCount = hourCount
    }

    func component(_ component: Calendar.Component) -> Int { calendar.component(component, from: date) }
    var monthLength: Int {
        get throws {
            guard let range = calendar.range(of: .day, in: .month, for: date) else {
                throw CronScheduleError.invalidDate
            }
            return range.count
        }
    }
    var isTransitionDay: Bool {
        get throws {
            guard let day = calendar.dateInterval(of: .day, for: date) else {
                throw CronScheduleError.invalidDate
            }
            return calendar.timeZone.secondsFromGMT(for: day.start)
                != calendar.timeZone.secondsFromGMT(for: day.end.addingTimeInterval(-1))
        }
    }

    mutating func clearGap() { skippedHour = nil; landingHour = nil }

    func matchesSkippedHour(_ values: [Int]) -> Bool {
        guard var skipped = skippedHour, landingHour == component(.hour) else { return false }
        for _ in 0..<24 {
            if skipped == landingHour { return false }
            if values.contains(skipped) { return true }
            skipped = (skipped + 1) % 24
        }
        return false
    }

    mutating func set(_ component: Calendar.Component, to value: Int) throws {
        let units: Set<Calendar.Component> = [.era, .year, .month, .day, .hour, .minute, .second]
        var desired = calendar.dateComponents(units, from: date)
        desired.setValue(value, for: component)
        guard let resolved = calendar.date(from: desired) else { throw CronScheduleError.invalidDate }
        let offset = calendar.timeZone.secondsFromGMT(for: resolved) - calendar.timeZone.secondsFromGMT(for: date)
        let sameOffset = resolved.addingTimeInterval(Double(offset))
        // Keep the current occurrence of an ambiguous wall time, matching Luxon's setters.
        date = calendar.dateComponents(units, from: sameOffset) == desired ? sameOffset : resolved
    }

    mutating func advance(_ unit: Calendar.Component) throws {
        if unit == .day || unit == .month {
            guard let next = calendar.date(byAdding: unit, value: 1, to: date),
                  let interval = calendar.dateInterval(of: unit, for: next) else {
                throw CronScheduleError.invalidDate
            }
            date = interval.start
            return
        }
        let previousHour = component(.hour)
        let previousOffset = calendar.timeZone.secondsFromGMT(for: date)
        let seconds = unit == .hour ? 3600.0 : unit == .minute ? 60.0 : 1.0
        date.addTimeInterval(seconds)
        if unit == .hour { try set(.minute, to: 0); try set(.second, to: 0) }
        if unit == .minute { try set(.second, to: 0) }
        let currentHour = component(.hour)
        let crossed = (currentHour - previousHour + 24) % 24
        if hourCount != 24 {
            if calendar.timeZone.secondsFromGMT(for: date) > previousOffset, crossed >= 2 {
                skippedHour = (previousHour + 1) % 24
                landingHour = currentHour
            } else if crossed == 0, component(.minute) == 0, component(.second) == 0 {
                repeatedHour = currentHour
            }
        }
    }
}

private struct CronRandom {
    private var state: UInt32

    init(seed: String?) {
        if let seed, !seed.isEmpty {
            state = seed.utf16.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        } else {
            state = UInt32(truncatingIfNeeded: UInt64.random(in: 0..<10_000_000_000))
        }
    }

    mutating func next() -> Double {
        state &+= 0x6d2b79f5
        var value = (state ^ (state >> 15)) &* (state | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return Double(value ^ (value >> 14)) / 4_294_967_296
    }
}
