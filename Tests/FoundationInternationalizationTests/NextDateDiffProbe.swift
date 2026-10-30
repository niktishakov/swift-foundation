// Local probe, not part of any PR: prints the results of many nextDate searches so that two
// versions of Calendar_Enumerate.swift can be compared. Writes to $NEXTDATE_PROBE_OUT.

import Testing
import Dispatch

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
}

private let templates: [[Calendar.Component]] = [
    [.month], [.day], [.month, .day], [.weekday], [.month, .weekday], [.day, .hour],
    [.weekday, .hour, .minute], [.month, .weekdayOrdinal, .weekday], [.weekdayOrdinal, .weekday],
    [.weekOfYear, .weekday], [.weekOfMonth, .weekday], [.month, .weekOfMonth, .weekday], [.hour],
    [.hour, .minute], [.month, .day, .hour], [.year, .month], [.yearForWeekOfYear, .weekOfYear],
    [.day, .weekday], [.month, .day, .weekday], [.minute], [.second], [.weekOfYear],
    [.weekOfMonth], [.month, .weekOfMonth], [.month, .hour], [.weekday, .hour],
    [.month, .weekday, .weekOfYear], [.month, .weekday, .weekOfMonth], [.year, .month, .day, .quarter],
    [.quarter, .day], [.month, .weekOfYear], [.weekOfYear, .weekday, .hour], [.weekOfMonth, .weekday, .hour],
    [.month, .weekdayOrdinal], [.weekdayOrdinal],
]

private func value(for component: Calendar.Component, rng: inout SplitMix64) -> Int {
    switch component {
    case .year, .yearForWeekOfYear: return rng.int(2018...2032)
    case .month: return rng.int(1...12)
    case .day: return rng.int(1...31)
    case .weekday: return rng.int(1...7)
    case .weekdayOrdinal: return rng.int(1...5)
    case .weekOfMonth: return rng.int(1...5)
    case .weekOfYear: return rng.int(1...53)
    case .quarter: return rng.int(1...4)
    case .hour: return rng.int(0...23)
    case .minute, .second: return rng.int(0...59)
    default: return 0
    }
}

@Test func nextDateDiffProbe() throws {
    guard let path = ProcessInfo.processInfo.environment["NEXTDATE_PROBE_OUT"] else { return }
    let zones = ["GMT", "America/Los_Angeles", "Europe/Paris", "Australia/Sydney", "Asia/Kolkata"]
    let policies: [(String, Calendar.MatchingPolicy)] = [
        ("strict", .strict), ("nextTime", .nextTime),
        ("prevPreserving", .previousTimePreservingSmallerComponents),
        ("nextPreserving", .nextTimePreservingSmallerComponents),
    ]
    var rng = SplitMix64(state: UInt64(ProcessInfo.processInfo.environment["NEXTDATE_PROBE_SEED"] ?? "") ?? 20261017)
    let cases = Int(ProcessInfo.processInfo.environment["NEXTDATE_PROBE_CASES"] ?? "") ?? 5000

    // Generate every case first with the seeded generator, so the cases don't depend on how they are run.
    struct Case: Sendable {
        let iso: Bool, zone: String, start: Date, fields: [Calendar.Component], wanted: [Calendar.Component: Int], components: DateComponents
    }
    var all: [Case] = []
    for _ in 0..<cases {
        let zone = zones[rng.int(0...zones.count - 1)]
        let iso = rng.int(0...2) == 0
        let start = Date(timeIntervalSince1970: Double(rng.int(1_577_836_800...1_924_991_999)))
        let fields = templates[rng.int(0...templates.count - 1)]
        var components = DateComponents()
        var wanted: [Calendar.Component: Int] = [:]
        for field in fields {
            let v = value(for: field, rng: &rng)
            wanted[field] = v
            components.setValue(v, for: field)
        }
        all.append(Case(iso: iso, zone: zone, start: start, fields: fields, wanted: wanted, components: components))
    }

    // Week 53 of a week-based year that has only 52 weeks makes the search walk through every year (a known slow path), so leave it out.
    let skipSlow = ProcessInfo.processInfo.environment["NEXTDATE_PROBE_KEEP_SLOW"] == nil
    let results = UnsafeMutableBufferPointer<String>.allocate(capacity: all.count)
    results.initialize(repeating: "")
    defer { results.deallocate() }
    DispatchQueue.concurrentPerform(iterations: all.count) { index in
        let c = all[index]
        var calendar = Calendar(identifier: c.iso ? .iso8601 : .gregorian)
        if !c.iso { calendar.locale = Locale(identifier: "en_US") }
        calendar.timeZone = TimeZone(identifier: c.zone)!
        let description = c.fields.map { "\($0)=\(c.wanted[$0]!)" }.joined(separator: ",")
        var out: [String] = []
        for direction in [Calendar.SearchDirection.backward, .forward] {
            for (policyName, policy) in policies {
                var resultText = "nil"
                var matches = "-"
                if skipSlow && c.fields.contains(.yearForWeekOfYear) && c.wanted[.weekOfYear] == 53 {
                    resultText = "skipped"
                } else if let result = calendar.nextDate(after: c.start, matching: c.components, matchingPolicy: policy, direction: direction) {
                    resultText = String(Int(result.timeIntervalSince1970))
                    let actual = calendar.dateComponents(Set(c.fields), from: result)
                    // A result must match, and must not keep a time of day that wasn't asked for.
                    let time = calendar.dateComponents([.hour, .minute, .second], from: result)
                    let exactPolicy = policy == .strict || policy == .nextTime
                    let aligned = (c.fields.contains(.hour) || time.hour == 0 || !exactPolicy) && (c.fields.contains(.minute) || time.minute == 0 || !exactPolicy) && (c.fields.contains(.second) || time.second == 0 || !exactPolicy)
                    matches = c.fields.allSatisfy { actual.value(for: $0) == c.wanted[$0] } && aligned ? "1" : "0"
                }
                out.append("\(index)\t\(c.iso ? "iso:" : "")\(c.zone)\t\(Int(c.start.timeIntervalSince1970))\t\(description)\t\(direction == .backward ? "back" : "fwd")\t\(policyName)\t\(resultText)\t\(matches)")
            }
        }
        results[index] = out.joined(separator: "\n")
    }
    let lines = Array(results)
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}
