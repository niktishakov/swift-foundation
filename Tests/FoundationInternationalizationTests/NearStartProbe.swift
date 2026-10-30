// Local probe, not part of any PR: nextDate with a start close to the answer, inside the same
// day, hour or minute, so that two versions can be compared. Writes to $NEAR_PROBE_OUT.

import Testing
import Dispatch

#if FOUNDATION_FRAMEWORK
@testable import Foundation
#else
@testable import FoundationInternationalization
@testable import FoundationEssentials
#endif

private struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
}

@Test func nearStartProbe() throws {
    guard let path = ProcessInfo.processInfo.environment["NEAR_PROBE_OUT"] else { return }
    let templates: [[Calendar.Component]] = [
        [.second], [.minute], [.minute, .second], [.hour, .second], [.hour, .minute, .second], [.hour, .minute],
        [.day, .hour, .minute, .second], [.weekday, .hour, .minute, .second], [.day, .minute, .second],
        [.month, .day, .hour, .minute, .second], [.weekday, .minute, .second], [.hour], [.day, .second],
    ]
    let zones = ["GMT", "Europe/Paris", "America/Los_Angeles", "Australia/Lord_Howe", "Asia/Kolkata"]
    let deltas: [Double] = [0, 0.5, 1, 7, 59, 60, 61, 3599, 3600, 3601, 86399, 86400]
    let policies: [Calendar.MatchingPolicy] = [.strict, .nextTime, .previousTimePreservingSmallerComponents, .nextTimePreservingSmallerComponents]
    var rng = Rng(state: 20261029)
    struct Case: Sendable { let id: Calendar.Identifier, zone: String, target: Date, fields: [Calendar.Component], ns: Int }
    var all: [Case] = []
    for _ in 0..<3000 {
        let pick = rng.int(0...9)
        let id: Calendar.Identifier = pick < 6 ? .gregorian : pick < 9 ? .iso8601 : .hebrew
        all.append(Case(id: id, zone: zones[rng.int(0...zones.count - 1)], target: Date(timeIntervalSince1970: Double(rng.int(1_577_836_800...1_924_991_999))),
                        fields: templates[rng.int(0...templates.count - 1)], ns: rng.int(0...9) == 0 ? 500_000_000 : 0))
    }
    let results = UnsafeMutableBufferPointer<String>.allocate(capacity: all.count)
    results.initialize(repeating: "")
    defer { results.deallocate() }
    DispatchQueue.concurrentPerform(iterations: all.count) { index in
        let c = all[index]
        var cal = Calendar(identifier: c.id)
        cal.timeZone = TimeZone(identifier: c.zone)!
        var comps = cal.dateComponents(Set(c.fields), from: c.target)
        if c.ns != 0 { comps.nanosecond = c.ns }
        var out: [String] = []
        for delta in deltas {
            for direction in [Calendar.SearchDirection.forward, .backward] {
                let start = direction == .forward ? c.target - delta : c.target + delta
                for policy in policies {
                    let r = cal.nextDate(after: start, matching: comps, matchingPolicy: policy, direction: direction)
                    out.append("\(index)\t\(c.id)\t\(c.zone)\t\(comps)\t\(start.timeIntervalSince1970)\t\(direction == .forward ? "fwd" : "back")\t\(policy)\t\(r.map { String($0.timeIntervalSince1970) } ?? "nil")")
                }
            }
        }
        results[index] = out.joined(separator: "\n")
    }
    try (Array(results).joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}
