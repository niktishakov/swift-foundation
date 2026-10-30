// Local probe, not part of any PR: prints the first recurrences of many random rules so that two
// versions of Calendar_Recurrence.swift can be compared. Writes to $RRULE_PROBE_OUT.

import Testing
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if FOUNDATION_FRAMEWORK
@testable import Foundation
#else
@testable import FoundationInternationalization
@testable import FoundationEssentials
#endif

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }
    mutating func nonZero(_ limit: Int) -> Int {
        let v = int(1...limit)
        return chance(30) ? -v : v
    }
}

private let weekdays: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]

private struct Case: @unchecked Sendable {
    let calendarName: String
    let zone: String
    let start: Date
    let rule: Calendar.RecurrenceRule
    let range: Range<Date>
    let text: String
}

private func makeCase(_ rng: inout SplitMix64) -> Case {
    let zones = ["GMT", "America/Los_Angeles", "Europe/Paris", "Australia/Sydney", "Asia/Kolkata"]
    let zone = zones[rng.int(0...zones.count - 1)]
    let pick = rng.int(0...99)
    let calendarName = pick < 60 ? "gregorian" : pick < 85 ? "iso8601" : pick < 90 ? "gregorian-fw2" : pick < 95 ? "chinese" : "hebrew"
    var calendar: Calendar
    switch calendarName {
    case "iso8601": calendar = Calendar(identifier: .iso8601)
    case "chinese": calendar = Calendar(identifier: .chinese)
    case "hebrew": calendar = Calendar(identifier: .hebrew)
    default:
        calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        if calendarName == "gregorian-fw2" { calendar.firstWeekday = 2 }
    }
    calendar.timeZone = TimeZone(identifier: zone)!

    var start = Date(timeIntervalSince1970: Double(rng.int(1_577_836_800...1_893_456_000)))
    if rng.chance(40) {
        // Most real events start on a round time.
        var comps = calendar.dateComponents([.era, .year, .month, .day, .hour], from: start)
        comps.minute = rng.chance(50) ? 0 : 30
        comps.second = 0
        start = calendar.date(from: comps) ?? start
    }

    let frequencies: [Calendar.RecurrenceRule.Frequency] = [.minutely, .hourly, .daily, .daily, .weekly, .weekly, .monthly, .monthly, .yearly, .yearly]
    let frequency = frequencies[rng.int(0...frequencies.count - 1)]
    let policies: [(String, Calendar.MatchingPolicy)] = [
        ("strict", .strict), ("nextTime", .nextTime),
        ("prevPreserving", .previousTimePreservingSmallerComponents),
        ("nextPreserving", .nextTimePreservingSmallerComponents),
    ]
    let policy = policies[rng.int(0...3)]
    let repeated: Calendar.RepeatedTimePolicy = rng.chance(50) ? .first : .last
    var rule = Calendar.RecurrenceRule(calendar: calendar, frequency: frequency, interval: rng.chance(70) ? 1 : rng.int(2...3),
                                       matchingPolicy: policy.1, repeatedTimePolicy: repeated)
    var parts = ["\(calendarName)", zone, "\(frequency)", "i=\(rule.interval)", policy.0, repeated == .first ? "first" : "last"]

    if rng.chance(30) {
        let isLunar = calendarName == "chinese" || calendarName == "hebrew"
        rule.months = (0..<rng.int(1...2)).map { _ in
            let m = rng.int(1...(calendarName == "hebrew" ? 13 : 12))
            return Calendar.RecurrenceRule.Month(m, isLeap: isLunar && calendarName == "chinese" && rng.chance(30))
        }
        parts.append("months=" + rule.months.map { "\($0.index)\($0.isLeap ? "L" : "")" }.joined(separator: ","))
    }
    if rng.chance(30) {
        rule.daysOfTheMonth = (0..<rng.int(1...2)).map { _ in rng.nonZero(31) }
        parts.append("dom=" + rule.daysOfTheMonth.map(String.init).joined(separator: ","))
    }
    if frequency == .yearly && rng.chance(12) {
        rule.daysOfTheYear = (0..<rng.int(1...2)).map { _ in rng.nonZero(366) }
        parts.append("doy=" + rule.daysOfTheYear.map(String.init).joined(separator: ","))
    }
    if frequency == .yearly && rng.chance(15) {
        rule.weeks = (0..<rng.int(1...2)).map { _ in rng.nonZero(53) }
        parts.append("weeks=" + rule.weeks.map(String.init).joined(separator: ","))
    }
    if rng.chance(45) {
        rule.weekdays = (0..<rng.int(1...3)).map { _ in
            let day = weekdays[rng.int(0...6)]
            if (frequency == .monthly || frequency == .yearly) && rng.chance(40) {
                return .nth(rng.nonZero(5), day)
            }
            return .every(day)
        }
        parts.append("wd=" + rule.weekdays.map {
            switch $0 {
            case .every(let d): return "\(d)"
            case .nth(let n, let d): return "\(n)\(d)"
            }
        }.joined(separator: ","))
    }
    if frequency != .minutely && frequency != .hourly && rng.chance(30) {
        rule.hours = (0..<rng.int(1...2)).map { _ in rng.int(0...23) }
        parts.append("h=" + rule.hours.map(String.init).joined(separator: ","))
    }
    if frequency != .minutely && rng.chance(25) {
        rule.minutes = (0..<rng.int(1...2)).map { _ in rng.int(0...59) }
        parts.append("m=" + rule.minutes.map(String.init).joined(separator: ","))
    }
    if rng.chance(10) {
        rule.seconds = [rng.int(0...59)]
        parts.append("s=" + rule.seconds.map(String.init).joined(separator: ","))
    }
    if frequency != .minutely && rng.chance(8) {
        rule.setPositions = (0..<rng.int(1...2)).map { _ in rng.nonZero(3) }
        parts.append("pos=" + rule.setPositions.map(String.init).joined(separator: ","))
    }
    if rng.chance(15) {
        let n = rng.int(1...10)
        rule.end = .afterOccurrences(n)
        parts.append("count=\(n)")
    }

    // Search far enough for a rule that rarely matches, but not so far that a rule with no match takes long.
    let span: Double
    switch frequency {
    case .minutely: span = 3 * 86400
    case .hourly: span = 120 * 86400
    case .daily: span = 4 * 365 * 86400
    case .weekly: span = 8 * 365 * 86400
    case .monthly: span = 20 * 365 * 86400
    case .yearly: span = 60 * 365 * 86400
    }
    let range = start ..< start + span
    return Case(calendarName: calendarName, zone: zone, start: start, rule: rule, range: range,
                text: parts.joined(separator: " "))
}

@Test func recurrenceRuleDiffProbe() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["RRULE_PROBE_OUT"] else { return }
    var rng = SplitMix64(state: UInt64(env["RRULE_PROBE_SEED"] ?? "") ?? 20261029)
    let count = Int(env["RRULE_PROBE_CASES"] ?? "") ?? 2000
    let from = Int(env["RRULE_PROBE_FROM"] ?? "") ?? 0
    let to = min(Int(env["RRULE_PROBE_TO"] ?? "") ?? count, count)
    let limit = 30
    // Generate every case first with the seeded generator, so the cases don't depend on how they are run.
    let all = (0..<count).map { _ in makeCase(&rng) }
    // One case at a time, each line written as soon as it is done, so a crash names its case and the run can go on after it.
    guard let file = fopen(path, "a") else { return }
    defer { fclose(file) }
    for index in from..<to {
        let c = all[index]
        fputs("CASE\t\(index)\t\(c.text)\t\(Int(c.start.timeIntervalSince1970))\n", stderr)
        fflush(stderr)
        let clock = ContinuousClock()
        var dates: [Date] = []
        let elapsed = clock.measure {
            for date in c.rule.recurrences(of: c.start, in: c.range) {
                dates.append(date)
                if dates.count == limit { break }
            }
        }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let text = dates.isEmpty ? "none" : dates.map { String(Int($0.timeIntervalSince1970)) }.joined(separator: ",")
        fputs("\(index)\t\(c.text)\t\(Int(c.start.timeIntervalSince1970))\t\(text)\t\(Double(Int(ms * 10)) / 10)\n", file)
        fflush(file)
    }
}
